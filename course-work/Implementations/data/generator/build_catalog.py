"""Build the title catalog and exchange rates used by simulate.py.

Sources (downloaded into .cache/, not committed):
  - Netflix "What We Watched" engagement reports, H1 2023 - H1 2026
    (title, Netflix release date, hours viewed per half-year)
  - TMDB API: genres, maturity rating, cast/crew, seasons and episodes.
    This product uses the TMDB API but is not endorsed or certified by TMDB.
  - ECB euro foreign exchange reference rates (daily)

Outputs (committed, so the data can be regenerated without internet or API key):
  catalog.json             selected titles with metadata and hours viewed per half-year
  exchange_rates_usd.csv   USD value of 1 unit of each currency, for every calendar day

Usage:  py -3 build_catalog.py --token-file <path to TMDB read access token>
        (or set the TMDB_TOKEN environment variable)
"""
import argparse
import csv
import datetime as dt
import hashlib
import io
import json
import os
import re
import threading
import time
import urllib.parse
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor

import openpyxl

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".cache")
ASSETS = "https://assets.ctfassets.net/4cd45et68cgf/"
REPORTS = {  # half-year -> download path on Netflix's asset host
    "2023H1": "1HyknFM84ISQpeua6TjM7A/97a0a393098937a8f29c9d29c48dbfa8/What_We_Watched_A_Netflix_Engagement_Report_2023Jan-Jun.xlsx",
    "2023H2": "inuAnzotdsAEgbInGLzH5/1be323ba419b2af3a96bffa29acc31a3/What_We_Watched_A_Netflix_Engagement_Report_2023Jul-Dec.xlsx",
    "2024H1": "2PoZlfdc46dH2gQvI8eUzI/9db5840720c47acfcf7b89ffe2402860/What_We_Watched_A_Netflix_Engagement_Report_2024Jan-Jun.xlsx",
    "2024H2": "6XSmoEjBjVMPRtYybT9d1E/8c0b0b2645b8712d5597b0bdbe0d64e2/What_We_Watched_A_Netflix_Engagement_Report_2024Jul-Dec.xlsx",
    "2025H1": "mplcXj5ulHDfbCPCr0f0I/5dbb6ec09f03df89706476e380e9b8bd/What_We_Watched_A_Netflix_Engagement_Report_2025Jan-Jun.xlsx",
    "2025H2": "2vdDPGLKA0XX2cjF2APJFn/7f1c367b39ed73a6a588751d3c5d0252/What_We_Watched_A_Netflix_Engagement_Report_2025Jul-Dec__6_.xlsx",
    "2026H1": "40WGcHJa9vRua31kU6Gbz5/43b15c7fbd6924392fc80e885839e39f/Netflix-s_What_We_Watched_Report_2026Jan-Jun__1_.xlsx",
}
ECB_URL = "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist.zip"
TMDB = "https://api.themoviedb.org/3"

TOP_PER_HALF = 130            # top films and top series per half-year (union over all halves)
WINDOW_START = dt.date(2023, 1, 1)
WINDOW_END = dt.date(2026, 10, 26)
BEFORE_WINDOW = dt.date(2022, 12, 1)   # DateAdded for licensed titles already on Netflix in H1 2023
CURRENCIES = ["CAD", "GBP", "EUR", "BRL", "MXN", "INR", "JPY", "KRW", "AUD"]

GENRES = {"Action", "Adventure", "Animation", "Comedy", "Crime", "Documentary", "Drama", "Family",
          "Fantasy", "History", "Horror", "Kids", "Music", "Mystery", "Reality", "Romance",
          "Science Fiction", "Thriller", "War", "Western", "Talk", "News", "Soap"}
GENRE_SPLIT = {"Action & Adventure": ["Action", "Adventure"], "Sci-Fi & Fantasy": ["Science Fiction", "Fantasy"],
               "War & Politics": ["War"]}
US_RATINGS = {"TV-Y", "TV-G", "G", "TV-Y7", "TV-PG", "PG", "PG-13", "TV-14", "R", "NC-17", "TV-MA"}

SEASON_RE = re.compile(r"^(?P<base>.+?):\s*(?:Season|Series|Part|Volume|Vol\.|Chapter|Book)\s+(?P<num>\d+)\b", re.I)
LIMITED_RE = re.compile(r"^(?P<base>.+?):\s*(?:Limited Series|Miniseries|Mini-Series)\b", re.I)


def half_start(h):
    return dt.date(int(h[:4]), 1 if h[4:] == "H1" else 7, 1)


def half_end(h):
    return dt.date(int(h[:4]), 6, 30) if h[4:] == "H1" else dt.date(int(h[:4]), 12, 31)


def to_date(v):
    if isinstance(v, dt.datetime):
        return v.date()
    if isinstance(v, str) and re.match(r"\d{4}-\d{2}-\d{2}", v.strip()):
        return dt.date.fromisoformat(v.strip()[:10])
    return None


def download(url, path):
    if not os.path.exists(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        urllib.request.urlretrieve(url, path)
    return path


# ---------------------------------------------------------------- reports
def parse_title(raw, sheet_kind):
    """-> (kind, base name, season number or None). sheet_kind is None for the mixed 2023H1 sheet."""
    name = raw.split(" // ")[0].strip()
    m = SEASON_RE.match(name)
    if m:
        return "Series", m["base"].strip(), int(m["num"])
    m = LIMITED_RE.match(name)
    if m:
        return "Series", m["base"].strip(), 1
    if sheet_kind == "Series":
        return "Series", name, None          # e.g. "Stranger Things 5": season resolved via TMDB air dates
    return "Movie", name, None


def read_reports():
    rows = []
    for half, path in REPORTS.items():
        wb = openpyxl.load_workbook(download(ASSETS + path, os.path.join(CACHE, "reports", half + ".xlsx")), read_only=True)
        sheets = wb.worksheets
        kinds = [None] if len(sheets) == 1 else ["Series", "Movie"]
        for ws, sheet_kind in zip(sheets, kinds):
            data = list(ws.iter_rows(values_only=True))
            hdr = next(i for i, r in enumerate(data[:10]) if r and "Title" in r)
            cols = {c: i for i, c in enumerate(data[hdr]) if c}
            for r in data[hdr + 1:]:
                if not r or not r[cols["Title"]] or not isinstance(r[cols["Hours Viewed"]], (int, float)):
                    continue
                kind, base, season = parse_title(str(r[cols["Title"]]), sheet_kind)
                rows.append({"half": half, "kind": kind, "base": base, "season": season,
                             "release": to_date(r[cols["Release Date"]]), "hours": float(r[cols["Hours Viewed"]])})

    # H1 2023 mixes films and series in one sheet: a name listed as a series in any later report is a series.
    later_series = {r["base"] for r in rows if r["kind"] == "Series" and r["half"] != "2023H1"}
    for r in rows:
        if r["half"] == "2023H1" and r["kind"] == "Movie" and r["base"] in later_series:
            r["kind"] = "Series"
    # Netflix names some seasons "<Show> <n>" (e.g. "Stranger Things 4"): the number is the season.
    series_bases = {r["base"] for r in rows if r["kind"] == "Series"}
    for r in rows:
        if r["kind"] == "Series" and r["season"] is None:
            m = re.match(r"^(.*\S)\s+(\d{1,2})$", r["base"])
            if m and m[1] in series_bases:
                r["base"], r["season"] = m[1], int(m[2])
    return rows


def select(rows):
    """Union of the top films and top series of every half-year."""
    keep = set()
    for half in REPORTS:
        for kind in ("Movie", "Series"):
            totals = {}
            for r in rows:
                if r["half"] == half and r["kind"] == kind:
                    totals[r["base"]] = totals.get(r["base"], 0) + r["hours"]
            keep.update((kind, b) for b, _ in sorted(totals.items(), key=lambda x: -x[1])[:TOP_PER_HALF])
    return keep


# ---------------------------------------------------------------- TMDB (cached)
class Tmdb:
    def __init__(self, token):
        self.token = token
        self.lock = threading.Lock()
        self.last = 0.0

    def get(self, path, **params):
        params.setdefault("language", "en-US")
        url = f"{TMDB}{path}?{urllib.parse.urlencode(params)}"
        cache = os.path.join(CACHE, "tmdb", hashlib.sha1(url.encode()).hexdigest() + ".json")
        if os.path.exists(cache):
            with open(cache, encoding="utf-8") as f:
                return json.load(f)
        for attempt in range(5):
            with self.lock:                      # stay well under TMDB's rate limit (~40 req/s)
                wait = self.last + 0.03 - time.time()
                if wait > 0:
                    time.sleep(wait)
                self.last = time.time()
            req = urllib.request.Request(url, headers={"Authorization": f"Bearer {self.token}", "accept": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    data = json.loads(resp.read())
                break
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    data = None
                    break
                time.sleep(2 ** attempt)
        else:
            raise RuntimeError(f"TMDB request failed: {path}")
        os.makedirs(os.path.dirname(cache), exist_ok=True)
        with open(cache, "w", encoding="utf-8") as f:
            json.dump(data, f)
        return data


def year_of(s):
    return int(s[:4]) if s and len(s) >= 4 else None


def genres_of(details):
    out = []
    for g in details.get("genres", []):
        for name in GENRE_SPLIT.get(g["name"], [g["name"]]):
            if name in GENRES and name not in out:
                out.append(name)
    return out


def credits_of(details, kind):
    out, seen = [], set()
    crew = details.get("credits", {}).get("crew", [])
    lead = details.get("created_by", []) if kind == "Series" else [c for c in crew if c.get("job") == "Director"]
    for p in lead[:2]:
        if p["id"] not in seen:
            seen.add(p["id"])
            out.append([p["id"], p["name"], "Creator" if kind == "Series" else "Director", None])
    for order, p in enumerate(details.get("credits", {}).get("cast", [])[:5], start=1):
        if p["id"] not in seen:
            seen.add(p["id"])
            out.append([p["id"], p["name"], "Actor", order])
    return out


def build_movie(api, base, rows):
    release = min((r["release"] for r in rows if r["release"]), default=None)
    found = api.get("/search/movie", query=base, include_adult="false")
    cand = [c for c in (found or {}).get("results", [])[:5]
            if release is None or (year_of(c.get("release_date")) and abs(year_of(c["release_date"]) - release.year) <= 1)]
    if not cand:
        return None
    d = api.get(f"/movie/{cand[0]['id']}", append_to_response="credits,release_dates")
    if not d or not genres_of(d):
        return None
    cert = next((x["certification"] for c in d.get("release_dates", {}).get("results", []) if c["iso_3166_1"] == "US"
                 for x in c["release_dates"] if x.get("certification")), "")
    if release:
        rows = [r for r in rows if half_end(r["half"]) >= release]
    first_half = min(r["half"] for r in rows)
    return {
        "source_key": f"tmdb:movie:{d['id']}", "type": "Movie", "name": base,
        "release_year": year_of(d.get("release_date")),
        "date_added": (release or (BEFORE_WINDOW if first_half == "2023H1" else half_start(first_half))).isoformat(),
        "rating": cert if cert in US_RATINGS else "NR",
        "runtime": d.get("runtime") or 100,
        "is_original": release is not None,
        "language": d.get("original_language") or "en",
        "description": " ".join((d.get("overview") or "").split())[:1000] or None,
        "genres": genres_of(d), "credits": credits_of(d, "Movie"),
        "hours": {h: sum(r["hours"] for r in rows if r["half"] == h) for h in sorted({r["half"] for r in rows})},
    }


def build_series(api, base, rows):
    release = min((r["release"] for r in rows if r["release"]), default=None)
    found = api.get("/search/tv", query=base, include_adult="false")
    cand = [c for c in (found or {}).get("results", [])[:5]
            if release is None or (year_of(c.get("first_air_date")) and year_of(c["first_air_date"]) <= release.year + 1)]
    if not cand:
        return None
    tv_id = cand[0]["id"]
    d = api.get(f"/tv/{tv_id}", append_to_response="credits,content_ratings")
    if not d or not genres_of(d):
        return None
    tmdb_seasons = {s["season_number"]: s for s in d.get("seasons", []) if s.get("season_number", 0) >= 1}

    # rows without a season label -> TMDB season whose air date is closest to the row's release (or half end)
    by_season = {}
    for r in rows:
        n = r["season"]
        if n is None:
            ref = r["release"] or half_end(r["half"])
            dated = [(abs((dt.date.fromisoformat(s["air_date"]) - ref).days), k)
                     for k, s in tmdb_seasons.items() if s.get("air_date")]
            n = min(dated)[1] if dated else None
        if n in tmdb_seasons:
            by_season.setdefault(n, []).append(r)
    if not by_season:
        return None

    first_half = min(r["half"] for r in rows)
    date_added = release or (BEFORE_WINDOW if first_half == "2023H1" else half_start(first_half))
    seasons = []
    for n in sorted(by_season):
        srows = by_season[n]
        sd = api.get(f"/tv/{tv_id}/season/{n}")
        eps = [[e["episode_number"], (e.get("name") or f"Episode {e['episode_number']}")[:300],
                e.get("runtime") or (d.get("episode_run_time") or [45])[0]]
               for e in (sd or {}).get("episodes", []) if e.get("episode_number", 0) >= 1]
        if not eps:
            continue
        s_release = min((r["release"] for r in srows if r["release"]), default=None)
        if s_release:
            srows = [r for r in srows if half_end(r["half"]) >= s_release]
        s_first = min(r["half"] for r in srows)
        if s_release is None:
            s_release = date_added if s_first == first_half else max(date_added, half_start(s_first))
        seasons.append({"number": n, "release_date": s_release.isoformat(), "episodes": eps,
                        "hours": {h: sum(r["hours"] for r in srows if r["half"] == h) for h in sorted({r["half"] for r in srows})}})
    if not seasons:
        return None
    rating = next((c["rating"] for c in d.get("content_ratings", {}).get("results", []) if c["iso_3166_1"] == "US"), "")
    return {
        "source_key": f"tmdb:tv:{tv_id}", "type": "Series", "name": base,
        "release_year": year_of(d.get("first_air_date")),
        "date_added": min(date_added, dt.date.fromisoformat(seasons[0]["release_date"])).isoformat(),
        "rating": rating if rating in US_RATINGS else "NR",
        "runtime": None,
        "is_original": release is not None,
        "language": d.get("original_language") or "en",
        "description": " ".join((d.get("overview") or "").split())[:1000] or None,
        "genres": genres_of(d), "credits": credits_of(d, "Series"),
        "seasons": seasons,
    }


def merge(titles):
    """Two report names can map to the same TMDB title: merge their hours/seasons."""
    out = {}
    for t in titles:
        k = t["source_key"]
        if k not in out:
            out[k] = t
            continue
        o = out[k]
        o["date_added"] = min(o["date_added"], t["date_added"])
        o["is_original"] = o["is_original"] or t["is_original"]
        if t["type"] == "Movie":
            for h, v in t["hours"].items():
                o["hours"][h] = o["hours"].get(h, 0) + v
        else:
            have = {s["number"]: s for s in o["seasons"]}
            for s in t["seasons"]:
                if s["number"] in have:
                    for h, v in s["hours"].items():
                        have[s["number"]]["hours"][h] = have[s["number"]]["hours"].get(h, 0) + v
                else:
                    o["seasons"].append(s)
            o["seasons"].sort(key=lambda s: s["number"])
    return list(out.values())


# ---------------------------------------------------------------- exchange rates
def build_rates(path_out):
    z = zipfile.ZipFile(download(ECB_URL, os.path.join(CACHE, "ecb", "eurofxref-hist.zip")))
    text = z.read(z.namelist()[0]).decode("utf-8")
    known = {}
    for r in csv.DictReader(io.StringIO(text)):
        d = dt.date.fromisoformat(r["Date"])
        if d < WINDOW_START - dt.timedelta(days=10):
            continue
        try:
            usd = float(r["USD"])
            rates = {"EUR": usd}
            for c in CURRENCIES:
                if c != "EUR":
                    rates[c] = usd / float(r[c])
            known[d] = rates
        except (ValueError, KeyError):
            continue
    rows, last, day = [], None, WINDOW_START - dt.timedelta(days=10)
    while day <= WINDOW_END:
        if day in known:
            last, carried = known[day], 0
        else:
            carried = 1
        if last and day >= WINDOW_START:
            rows.extend((c, day.isoformat(), f"{last[c]:.9f}", carried) for c in CURRENCIES)
        day += dt.timedelta(days=1)
    with open(path_out, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["CurrencyCode", "RateDate", "RateToUSD", "IsCarriedForward"])
        w.writerows(rows)
    return max(known)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--token-file")
    args = ap.parse_args()
    token = os.environ.get("TMDB_TOKEN")
    if args.token_file:
        with open(args.token_file, encoding="utf-8") as f:
            token = f.read().strip()
    if not token:
        raise SystemExit("TMDB token missing: pass --token-file or set TMDB_TOKEN")

    rows = read_reports()
    keep = select(rows)
    groups = {}
    for r in rows:
        if (r["kind"], r["base"]) in keep:
            groups.setdefault((r["kind"], r["base"]), []).append(r)
    print(f"report rows: {len(rows)}  selected titles: {len(groups)}")

    api = Tmdb(token)
    work = lambda item: (build_movie if item[0][0] == "Movie" else build_series)(api, item[0][1], item[1])
    with ThreadPoolExecutor(max_workers=6) as pool:
        built = list(pool.map(work, groups.items()))
    titles = merge([t for t in built if t])
    titles.sort(key=lambda t: (t["date_added"], t["source_key"]))
    with open(os.path.join(HERE, "catalog.json"), "w", encoding="utf-8") as f:
        json.dump({"generated": dt.date.today().isoformat(), "titles": titles}, f, ensure_ascii=False, indent=1)
    movies = sum(t["type"] == "Movie" for t in titles)
    print(f"catalog: {len(titles)} titles ({movies} movies, {len(titles) - movies} series), "
          f"{sum(len(s['episodes']) for t in titles if t['type'] == 'Series' for s in t['seasons'])} episodes, "
          f"dropped {len(groups) - sum(1 for t in built if t)} unmatched")

    last = build_rates(os.path.join(HERE, "exchange_rates_usd.csv"))
    print(f"exchange rates: last ECB publication {last}, carried forward to {WINDOW_END}")


if __name__ == "__main__":
    main()
