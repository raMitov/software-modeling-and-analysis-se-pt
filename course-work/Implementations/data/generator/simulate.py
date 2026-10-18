"""Simulate Netflix members day by day and write the load batches (CSV).

Input : catalog.json, exchange_rates_usd.csv (built by build_catalog.py)
Output: ../batches/history/YYYY-MM/*.csv   2023-01-01 .. 2026-10-18 (one folder per month)
        ../batches/daily/YYYY-MM-DD/*.csv  2026-10-19 .. 2026-10-26 (one folder per day, live-load demo)

All accounts, subscriptions, payments, viewing and ratings are SYNTHETIC. Title popularity
follows Netflix's published hours viewed per half-year; prices match sql/08_reference_data.sql.
Deterministic: the same seed always produces the same files.

Usage:  py -3 simulate.py
"""
import csv
import functools
import datetime as dt
import json
import math
import os
import random
import shutil
import uuid

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "batches"))
SEED = 20231
START, BASELINE_END, END = dt.date(2023, 1, 1), dt.date(2026, 10, 18), dt.date(2026, 10, 26)
DAYS = [START + dt.timedelta(days=i) for i in range((END - START).days + 1)]

INITIAL_ACCOUNTS = 560        # members already subscribed on 2023-01-01
SIGNUPS_PER_DAY = 0.33        # base rate for new accounts (before seasonality / events)
WATCH_PROBABILITY = 0.30      # base chance that a profile watches on a given day
MONTHLY_CHURN = 0.021         # base voluntary churn

# ------------------------------------------------------------------ countries
# share of members, UTC offsets (minutes, standard time - no DST) with weights, profile languages
COUNTRIES = {
    "US": (27, [(-300, 40), (-360, 30), (-420, 8), (-480, 22)], [("en", 1)]),
    "CA": (3, [(-300, 60), (-360, 15), (-480, 25)], [("en", 80), ("fr", 20)]),
    "GB": (8, [(0, 1)], [("en", 1)]),
    "DE": (7, [(60, 1)], [("de", 1)]),
    "FR": (7, [(60, 1)], [("fr", 1)]),
    "ES": (5, [(60, 1)], [("es", 1)]),
    "BG": (1.5, [(120, 1)], [("bg", 1)]),
    "BR": (9, [(-180, 1)], [("pt-BR", 1)]),
    "MX": (7, [(-360, 1)], [("es-MX", 1)]),
    "IN": (7, [(330, 1)], [("hi", 40), ("en", 60)]),
    "JP": (4, [(540, 1)], [("ja", 1)]),
    "KR": (4, [(540, 1)], [("ko", 1)]),
    "AU": (4, [(600, 85), (480, 15)], [("en", 1)]),
}
AD_MARKETS = {"US", "CA", "GB", "DE", "FR", "ES", "BR", "MX", "JP", "KR", "AU"}
# share of viewing that goes to local-language titles
LOCAL_TASTE = {"KR": ({"ko"}, 0.45), "JP": ({"ja"}, 0.40), "IN": ({"hi", "ta", "te", "ml", "kn", "bn", "mr"}, 0.40),
               "BR": ({"pt"}, 0.12), "MX": ({"es"}, 0.18), "ES": ({"es"}, 0.18), "FR": ({"fr"}, 0.12), "DE": ({"de"}, 0.10)}
NAMES = {
    "en": ["James", "Olivia", "Liam", "Emma", "Noah", "Ava", "Ethan", "Mia", "Lucas", "Sophia", "Jack", "Grace"],
    "fr": ["Louis", "Chloé", "Hugo", "Léa", "Jules", "Manon", "Arthur", "Camille", "Nathan", "Inès"],
    "de": ["Lukas", "Mia", "Leon", "Hannah", "Finn", "Emilia", "Paul", "Lea", "Jonas", "Clara"],
    "es": ["Mateo", "Lucía", "Hugo", "Sofía", "Daniel", "Martina", "Pablo", "Paula", "Álvaro", "Elena"],
    "bg": ["Ivan", "Maria", "Georgi", "Elena", "Dimitar", "Ivana", "Nikolay", "Desislava", "Petar", "Yana"],
    "pt": ["Miguel", "Helena", "Arthur", "Alice", "Gael", "Laura", "Heitor", "Valentina", "Davi", "Beatriz"],
    "hi": ["Aarav", "Ananya", "Vivaan", "Diya", "Arjun", "Saanvi", "Rohan", "Isha", "Kabir", "Meera"],
    "ja": ["Haruto", "Yui", "Sota", "Hina", "Yuto", "Mei", "Riku", "Aoi", "Kaito", "Sakura"],
    "ko": ["Minjun", "Seoyeon", "Jiho", "Jiwoo", "Dohyun", "Hayoon", "Juwon", "Seoa", "Yejun", "Jimin"],
}

# ------------------------------------------------------------------ plans & prices (= sql/08_reference_data.sql)
D = dt.date.fromisoformat
NOW_OPEN = dt.date(9999, 12, 31)
PRICES = {  # (country, plan) -> [(valid_from, valid_to_exclusive, price, currency)]
    ("US", "Basic"): [(START, D("2023-10-18"), 9.99, "USD"), (D("2023-10-18"), D("2024-10-01"), 11.99, "USD")],
    ("US", "Standard with ads"): [(START, D("2025-01-21"), 6.99, "USD"), (D("2025-01-21"), D("2026-03-26"), 7.99, "USD"), (D("2026-03-26"), NOW_OPEN, 8.99, "USD")],
    ("US", "Standard"): [(START, D("2025-01-21"), 15.49, "USD"), (D("2025-01-21"), D("2026-03-26"), 17.99, "USD"), (D("2026-03-26"), NOW_OPEN, 19.99, "USD")],
    ("US", "Premium"): [(START, D("2023-10-18"), 19.99, "USD"), (D("2023-10-18"), D("2025-01-21"), 22.99, "USD"), (D("2025-01-21"), D("2026-03-26"), 24.99, "USD"), (D("2026-03-26"), NOW_OPEN, 26.99, "USD")],
    ("BG", "Basic"): [(START, D("2023-02-16"), 7.99, "EUR"), (D("2023-02-16"), NOW_OPEN, 4.99, "EUR")],
    ("BG", "Standard"): [(START, D("2023-02-16"), 9.99, "EUR"), (D("2023-02-16"), NOW_OPEN, 7.99, "EUR")],
    ("BG", "Premium"): [(START, D("2023-02-16"), 11.99, "EUR"), (D("2023-02-16"), NOW_OPEN, 9.99, "EUR")],
    ("IN", "Mobile"): [(START, NOW_OPEN, 149.00, "INR")], ("IN", "Basic"): [(START, NOW_OPEN, 199.00, "INR")],
    ("IN", "Standard"): [(START, NOW_OPEN, 499.00, "INR")], ("IN", "Premium"): [(START, NOW_OPEN, 649.00, "INR")],
}
for iso, cur, ads, std, prem in [("CA", "CAD", 7.99, 18.99, 23.99), ("GB", "GBP", 5.99, 12.99, 18.99), ("DE", "EUR", 4.99, 13.99, 19.99),
                                 ("FR", "EUR", 7.99, 14.99, 21.99), ("ES", "EUR", 6.99, 13.99, 19.99), ("BR", "BRL", 20.90, 44.90, 59.90),
                                 ("MX", "MXN", 119, 249, 329), ("JP", "JPY", 890, 1590, 2290), ("KR", "KRW", 5500, 13500, 17000),
                                 ("AU", "AUD", 7.99, 18.99, 25.99)]:
    for plan, p in (("Standard with ads", ads), ("Standard", std), ("Premium", prem)):
        PRICES[(iso, plan)] = [(START, NOW_OPEN, float(p), cur)]
ADS_LAUNCH = D("2022-11-03")                                     # ads plan launch
US_BASIC_CLOSED = D("2023-07-01")                               # no new Basic members after this date
US_BASIC_MIGRATION = (D("2024-07-18"), D("2024-09-30"))         # existing Basic members moved off the plan
PRICE_INCREASES = [("US", D("2023-10-18"), {"Basic", "Premium"}),
                   ("US", D("2025-01-21"), {"Standard with ads", "Standard", "Premium"}),
                   ("US", D("2026-03-26"), {"Standard with ads", "Standard", "Premium"})]
SIGNUP_EVENTS = [  # (countries, from, days, multiplier) - paid-sharing crackdown, Bulgarian price cut
    ({"CA"}, D("2023-02-08"), 60, 1.8), ({"US", "GB", "FR", "DE", "ES", "AU", "BR", "MX"}, D("2023-05-23"), 75, 2.2),
    ({"IN"}, D("2023-07-20"), 60, 1.6), ({"BG"}, D("2023-02-16"), 60, 2.0)]
CANCEL_REASONS = ["Too expensive", "Not watching enough", "Finished the show I wanted", "Switching to another service", "Other"]

# ------------------------------------------------------------------ viewing behaviour
HOURS_ADULT = [2, 1, .5, .3, .2, .2, .4, .8, 1, 1.2, 1.3, 1.5, 2, 2, 2, 2.2, 2.6, 3.2, 4.5, 6, 7, 7, 5.5, 3.5]
HOURS_KIDS_WEEKDAY = [0, 0, 0, 0, 0, 0, .3, 1, .6, .3, .3, .4, .6, .8, 1.2, 2.5, 3, 3, 2.6, 2, 1.2, .4, .1, 0]
HOURS_KIDS_WEEKEND = [0, 0, 0, 0, 0, 0, .5, 1.8, 2.6, 2.6, 2.2, 1.8, 1.4, 1.4, 1.6, 2, 2.2, 2.2, 2, 1.6, 1, .4, .1, 0]
DOW = [0.92, 0.92, 0.92, 0.95, 1.08, 1.22, 1.18]
MONTH = [1.10, 1.05, 1.00, 0.97, 0.95, 0.90, 0.90, 0.92, 0.97, 1.00, 1.05, 1.12]
DEVICE_TYPES = {  # type -> (platforms, preferred local hours, boost)
    "Smart TV": (["Tizen", "webOS", "Android TV", "Roku TV"], range(18, 24), 3.0),
    "Mobile": (["Android", "iOS"], [6, 7, 8, 12, 13, 22, 23, 0], 2.5),
    "Web": (["Chrome", "Safari", "Edge", "Firefox"], range(9, 18), 2.0),
    "Tablet": (["iPadOS", "Android"], range(14, 21), 2.0),
    "Console": (["PlayStation", "Xbox"], range(18, 24), 2.5),
    "Streaming Stick": (["Fire TV", "Chromecast", "Roku", "Apple TV"], range(18, 24), 2.5),
}
DEVICE_MIX = {"default": [("Smart TV", 45), ("Mobile", 25), ("Web", 10), ("Tablet", 8), ("Console", 7), ("Streaming Stick", 5)],
              "IN": [("Mobile", 55), ("Smart TV", 25), ("Web", 10), ("Tablet", 5), ("Streaming Stick", 5)],
              "JP": [("Smart TV", 40), ("Mobile", 35), ("Web", 10), ("Tablet", 8), ("Console", 7)],
              "KR": [("Smart TV", 40), ("Mobile", 35), ("Web", 12), ("Tablet", 8), ("Console", 5)]}
KID_SAFE = {"TV-Y", "TV-G", "G", "TV-Y7", "TV-PG", "PG"}

FILES = {  # file -> header (same order as the stg tables in sql/03_staging_tables.sql)
    "exchange_rates": ["CurrencyCode", "RateDate", "RateToUSD", "IsCarriedForward"],
    "titles": ["SourceKey", "TitleType", "TitleName", "ReleaseYear", "DateAdded", "RatingCode", "RuntimeMinutes", "IsOriginal", "OriginalLanguage", "Description"],
    "title_genres": ["TitleSourceKey", "GenreName"],
    "seasons": ["TitleSourceKey", "SeasonNumber", "ReleaseDate"],
    "episodes": ["TitleSourceKey", "SeasonNumber", "EpisodeNumber", "EpisodeName", "RuntimeMinutes"],
    "persons": ["SourceKey", "FullName"],
    "title_credits": ["TitleSourceKey", "PersonSourceKey", "Role", "BillingOrder"],
    "accounts": ["Email", "CountryISO", "SignupDate"],
    "profiles": ["AccountEmail", "ProfileName", "IsKids", "MaxRatingCode", "LanguageCode", "CreatedAtUtc"],
    "devices": ["DeviceGuid", "AccountEmail", "DeviceType", "Platform", "FirstSeenUtc"],
    "subscriptions": ["AccountEmail", "PlanName", "StartDate", "EndDate", "EndReason", "CancellationReason"],
    "payments": ["TransactionRef", "AccountEmail", "SubscriptionStartDate", "BillingPeriodStart", "Amount", "CurrencyCode", "AttemptedAtUtc", "Status", "PaymentMethod"],
    "watch_sessions": ["SessionGuid", "AccountEmail", "ProfileName", "DeviceGuid", "TitleSourceKey", "SeasonNumber", "EpisodeNumber", "StartedAtUtc", "StartedAtLocal", "WatchedSeconds", "ProgressPct"],
    "ratings": ["AccountEmail", "ProfileName", "TitleSourceKey", "RatingValue", "RatedAtUtc"],
}

rnd = random.Random(SEED)


def weighted(pairs):
    return rnd.choices([p for p, _ in pairs], weights=[w for _, w in pairs])[0]


def batch_of(day):
    return f"daily/{day.isoformat()}" if day > BASELINE_END else f"history/{day:%Y-%m}"


def ts(x):
    return x.strftime("%Y-%m-%d %H:%M:%S")


def new_guid():
    return str(uuid.UUID(int=rnd.getrandbits(128), version=4))


def price_on(country, plan, day):
    for frm, to, p, cur in PRICES.get((country, plan), []):
        if frm <= day < to:
            return p, cur
    return None


@functools.lru_cache(maxsize=None)
def offered_plans(country, day, new_member=True):
    plans = [p for (c, p) in PRICES if c == country and price_on(c, p, day)]
    if new_member and country == "US" and day >= US_BASIC_CLOSED:
        plans = [p for p in plans if p != "Basic"]
    return tuple(sorted(plans, key=lambda p: price_on(country, p, day)[0]))


def choose_plan(country, day, initial=False):
    plans = offered_plans(country, day)
    if country == "IN":
        w = {"Mobile": 40, "Basic": 22, "Standard": 25, "Premium": 13}
    elif country == "BG":
        w = {"Basic": 30, "Standard": 48, "Premium": 22}
    else:
        progress = (day - START).days / (END - START).days
        ads = 0.06 if initial else 0.30 + 0.25 * progress        # ads plan share of new members grows
        w = {"Standard with ads": ads * 100, "Standard": 62 * (1 - ads), "Premium": 30 * (1 - ads), "Basic": 8 * (1 - ads)}
    pairs = [(p, w.get(p, 0)) for p in plans if w.get(p, 0) > 0]
    return weighted(pairs)


# ------------------------------------------------------------------ catalog & popularity
def load_catalog():
    with open(os.path.join(HERE, "catalog.json"), encoding="utf-8") as f:
        titles = json.load(f)["titles"]
    items = []          # one item per movie or per series season
    for ti, t in enumerate(titles):
        if t["type"] == "Movie":
            items.append({"title": ti, "season": None, "release": D(t["date_added"]), "hours": t["hours"],
                          "unit": t["runtime"] / 60, "kid": t["rating"] in KID_SAFE, "lang": t["language"]})
        else:
            for si, s in enumerate(t["seasons"]):
                avg = sum(e[2] for e in s["episodes"]) / len(s["episodes"])
                items.append({"title": ti, "season": si, "release": D(s["release_date"]), "hours": s["hours"],
                              "unit": avg / 60, "kid": t["rating"] in KID_SAFE, "lang": t["language"]})
    return titles, items


def popularity(items):
    """Daily 'views' rate per item: hours viewed per half-year spread over the half
    (premiere spike + decay for items released inside the half), divided by runtime."""
    halves = ["2023H1", "2023H2", "2024H1", "2024H2", "2025H1", "2025H2", "2026H1", "2026H2"]
    W = np.zeros((len(items), len(DAYS)), dtype=np.float32)
    idx = {d: i for i, d in enumerate(DAYS)}
    for k, it in enumerate(items):
        for h in halves:
            hs = dt.date(int(h[:4]), 1 if h.endswith("H1") else 7, 1)
            he = dt.date(int(h[:4]), 6, 30) if h.endswith("H1") else dt.date(int(h[:4]), 12, 31)
            hours = it["hours"].get(h)
            if h == "2026H2":                       # no report yet: last known half, slightly lower
                hours = it["hours"].get("2026H1", 0) * 0.9
            if not hours:
                continue
            days = [hs + dt.timedelta(days=i) for i in range((he - hs).days + 1)]
            r = it["release"]
            if hs <= r <= he:
                shape = [0.0 if d < r else math.exp(-(d - r).days / 28) + 0.08 for d in days]
            else:
                shape = [0.0 if d < r else 1.0 for d in days]      # never watchable before release
            total = sum(shape)
            if not total:
                continue
            for d, s in zip(days, shape):
                if d in idx and s:
                    W[k, idx[d]] = hours * s / total / it["unit"]
    return W


# ------------------------------------------------------------------ simulation
class Out:
    """Collects CSV rows per batch folder and file."""
    def __init__(self):
        self.rows = {}

    def add(self, day, file, row):
        self.rows.setdefault(batch_of(day), {}).setdefault(file, []).append(row)

    def write(self):
        for sub in ("history", "daily"):                 # start clean, keep the batches folder itself
            shutil.rmtree(os.path.join(OUT, sub), ignore_errors=True)
        batches = sorted({batch_of(d) for d in DAYS})
        for b in batches:
            folder = os.path.join(OUT, *b.split("/"))
            os.makedirs(folder)
            for file, header in FILES.items():
                with open(os.path.join(folder, file + ".csv"), "w", newline="", encoding="utf-8") as f:
                    w = csv.writer(f, lineterminator="\n")
                    w.writerow(header)
                    w.writerows(["" if v is None else v for v in r] for r in self.rows.get(b, {}).get(file, []))
        return batches


def main():
    titles, items = load_catalog()
    W = popularity(items)
    out = Out()

    # catalog rows, each in the batch of the day it became available
    item_of = {}
    for k, it in enumerate(items):
        item_of[(it["title"], it["season"])] = k
    seen_people = set()
    for t in titles:
        added = max(D(t["date_added"]), START)
        key = t["source_key"]
        out.add(added, "titles", [key, t["type"], t["name"][:300], t["release_year"], t["date_added"], t["rating"],
                                  t["runtime"], int(t["is_original"]), t["language"][:10], t["description"]])
        for g in t["genres"]:
            out.add(added, "title_genres", [key, g])
        for pid, name, role, order in t["credits"]:
            pkey = f"tmdb:person:{pid}"
            if pkey not in seen_people:
                seen_people.add(pkey)
                out.add(added, "persons", [pkey, name[:200]])
            out.add(added, "title_credits", [key, pkey, role, order])
        for s in t.get("seasons") or []:
            sday = max(D(s["release_date"]), added)
            out.add(sday, "seasons", [key, s["number"], s["release_date"]])
            for n, name, runtime in s["episodes"]:
                out.add(sday, "episodes", [key, s["number"], n, " ".join(name.split())[:300] or f"Episode {n}", max(int(runtime or 45), 1)])

    with open(os.path.join(HERE, "exchange_rates_usd.csv"), encoding="utf-8") as f:
        for r in csv.DictReader(f):
            out.add(D(r["RateDate"]), "exchange_rates", [r["CurrencyCode"], r["RateDate"], r["RateToUSD"], r["IsCarriedForward"]])

    # biggest premieres -> signup and reactivation boosts
    peak = W.max(axis=1)
    big_releases = sorted({items[k]["release"] for k in np.argsort(-peak)[:15] if START <= items[k]["release"] <= END})

    accounts, n_accounts, n_payments = [], 0, 0

    def new_account(country, signup, initial):
        nonlocal n_accounts
        n_accounts += 1
        email = f"member{n_accounts:05d}@example.com"
        acc = {"email": email, "country": country, "tz": weighted(COUNTRIES[country][1]), "signup": signup,
               "eng": rnd.lognormvariate(0, 0.45), "method": weighted([("Card", 75), ("PayPal", 12), ("Gift Card", 5), ("Partner Billing", 8)]
                                                                       if country != "IN" else [("Card", 50), ("Partner Billing", 30), ("Gift Card", 15), ("PayPal", 5)]),
               "profiles": [], "devices": [], "sub": None, "subs": [], "last_view": signup, "retry": None, "ended": None}
        created = dt.datetime.combine(signup, dt.time(rnd.randrange(8, 23), rnd.randrange(60)))
        out.add(max(signup, START), "accounts", [email, country, signup.isoformat()])
        lang = weighted(COUNTRIES[country][2])
        names = list(NAMES.get(lang.split("-")[0], NAMES["en"]))
        rnd.shuffle(names)
        n_prof = weighted([(1, 22), (2, 30), (3, 25), (4, 14), (5, 9)])
        kids = n_prof >= 2 and rnd.random() < 0.35
        for i in range(n_prof):
            is_kids = kids and i == n_prof - 1
            prof = {"name": "Kids" if is_kids else names[i], "kids": is_kids, "eng": acc["eng"] * rnd.lognormvariate(0, 0.5),
                    "state": None, "rated": {}}
            acc["profiles"].append(prof)
            out.add(max(signup, START), "profiles", [email, prof["name"], int(is_kids), "TV-PG" if is_kids else "TV-MA", lang, ts(created)])
        for _ in range(weighted([(1, 30), (2, 40), (3, 20), (4, 10)])):
            add_device(acc, created)
        start = signup
        if initial:  # current subscription started some time before 2023 (earlier history is out of scope)
            start = signup + dt.timedelta(days=rnd.randrange(max(1, (dt.date(2022, 12, 31) - max(signup, dt.date(2021, 7, 1))).days + 1))) \
                if signup < dt.date(2021, 7, 1) else signup
            start = max(start, signup)
        plan = choose_plan(country, max(start, START), initial)
        if initial and plan == "Standard with ads" and start < ADS_LAUNCH:
            start = ADS_LAUNCH + dt.timedelta(days=rnd.randrange((dt.date(2022, 12, 31) - ADS_LAUNCH).days + 1))
        start_subscription(acc, plan, start, first_payment=not initial)
        accounts.append(acc)
        return acc

    def add_device(acc, first_seen):
        mix = DEVICE_MIX.get(acc["country"], DEVICE_MIX["default"])
        dtype = weighted(mix)
        platforms = DEVICE_TYPES[dtype][0]
        platform = ("Android" if rnd.random() < 0.85 else "iOS") if (dtype == "Mobile" and acc["country"] == "IN") else rnd.choice(platforms)
        dev = {"guid": new_guid(), "type": dtype}
        acc["devices"].append(dev)
        out.add(max(first_seen.date(), START), "devices", [dev["guid"], acc["email"], dtype, platform, ts(first_seen)])

    def start_subscription(acc, plan, day, first_payment=True):
        sub = {"plan": plan, "start": day, "end": None, "reason": None, "cancel": None, "anchor": min(day.day, 28),
               "migrate": None}
        if acc["country"] == "US" and plan == "Basic":
            a, b = US_BASIC_MIGRATION
            sub["migrate"] = a + dt.timedelta(days=rnd.randrange((b - a).days + 1))
        acc["sub"] = sub
        acc["subs"].append(sub)
        sub["next_bill"] = day if first_payment else next_anchor(sub, START)

    def next_anchor(sub, frm):
        d = frm
        while d.day != sub["anchor"]:
            d += dt.timedelta(days=1)
        return d

    def end_subscription(acc, day, reason, cancel=None):
        sub = acc["sub"]
        sub["end"], sub["reason"], sub["cancel"] = day, reason, cancel
        acc["sub"], acc["retry"], acc["ended"] = None, None, day

    def pay(acc, day, period_start, status):
        nonlocal n_payments
        sub = acc["sub"]
        p = price_on(acc["country"], sub["plan"], period_start)
        if p is None:
            raise RuntimeError(f"no price for {acc['country']} {sub['plan']} on {period_start}")
        n_payments += 1
        at = dt.datetime.combine(day, dt.time(rnd.randrange(5, 10), rnd.randrange(60), rnd.randrange(60)))
        if status == "Succeeded" and rnd.random() < 0.003:
            status = "Refunded"
        out.add(day, "payments", [f"PAY-{n_payments:08d}", acc["email"], sub["start"].isoformat(), period_start.isoformat(),
                                  f"{p[0]:.2f}", p[1], ts(at), status, acc["method"]])

    # members on 2023-01-01: signup 2015-2022, weighted to recent years
    for _ in range(INITIAL_ACCOUNTS):
        year = weighted([(2015, 4), (2016, 5), (2017, 7), (2018, 9), (2019, 11), (2020, 16), (2021, 18), (2022, 20)])
        signup = dt.date(year, 1, 1) + dt.timedelta(days=rnd.randrange(365))
        new_account(weighted([(c, v[0]) for c, v in COUNTRIES.items()]), signup, initial=True)

    country_list = list(COUNTRIES)
    local_masks = {c: np.array([it["lang"] in langs for it in items]) for c, (langs, _) in LOCAL_TASTE.items()}
    kid_mask = np.array([it["kid"] for it in items])
    n_sessions = 0
    nprng = np.random.default_rng(SEED)

    for j, day in enumerate(DAYS):
        col = W[:, j].astype(np.float64)
        cum_all = np.cumsum(col)
        cum_kid = np.cumsum(col * kid_mask)
        cum_local = {c: np.cumsum(col * m) for c, m in local_masks.items()}
        boost = any(0 <= (day - r).days < 10 for r in big_releases)
        season = MONTH[day.month - 1]

        # --- new members
        trend = 1 + 0.12 * (day - START).days / 365
        for c in country_list:
            lam = SIGNUPS_PER_DAY * COUNTRIES[c][0] / 100 * season * trend * (1.6 if boost else 1)
            for countries, frm, days, mult in SIGNUP_EVENTS:
                if c in countries and 0 <= (day - frm).days < days:
                    lam *= mult
            n = nprng.poisson(lam)
            for _ in range(n):
                new_account(c, day, initial=False)

        for acc in accounts:
            sub = acc["sub"]
            # --- former members coming back
            if sub is None:
                if not (acc["ended"] and day > acc["ended"] and rnd.random() < 0.0012 * (3 if boost else 1)):
                    continue
                start_subscription(acc, choose_plan(acc["country"], day), day)   # comes back today: billed today
                sub = acc["sub"]

            # --- billing (first attempt, then retries on +3 and +7 days)
            if acc["retry"] and acc["retry"][0] == day:
                _, period, attempt = acc["retry"]
                if rnd.random() < 0.6:
                    pay(acc, day, period, "Succeeded")
                    acc["retry"] = None
                else:
                    pay(acc, day, period, "Failed")
                    if attempt == 3:
                        end_subscription(acc, day + dt.timedelta(days=1), "PaymentFailed")
                        continue
                    acc["retry"] = (day + dt.timedelta(days=4), period, attempt + 1)
            if sub["next_bill"] <= day:
                if sub.get("cancel_at") is not None and sub["cancel_at"] <= day:
                    end_subscription(acc, day, "Cancelled", sub["cancel_reason"])
                    continue
                if rnd.random() < 0.035:
                    pay(acc, day, day, "Failed")
                    acc["retry"] = (day + dt.timedelta(days=3), day, 2)
                else:
                    pay(acc, day, day, "Succeeded")
                sub["next_bill"] = next_anchor(sub, day + dt.timedelta(days=1))

            # --- plan changes (US Basic retirement, upgrades, downgrades)
            plans = offered_plans(acc["country"], day)
            hike = any(c == acc["country"] and 0 <= (day - d0).days < 60 and sub["plan"] in pl for c, d0, pl in PRICE_INCREASES)
            target = None
            if sub["migrate"] and day >= sub["migrate"]:
                target = "Standard with ads" if rnd.random() < 0.65 else "Standard"
            elif sub["start"] < day and "cancel_at" not in sub and sub["plan"] in plans:
                i = plans.index(sub["plan"])
                if i + 1 < len(plans) and rnd.random() < 0.006 / 30:
                    target = plans[i + 1]
                elif i > 0 and rnd.random() < 0.005 / 30 * (4 if hike else 1):
                    target = plans[0] if hike and "Standard with ads" in plans else plans[i - 1]
            if target and target != sub["plan"] and sub["start"] < day:
                end_subscription(acc, day, "PlanChange")
                start_subscription(acc, target, day)
                sub = acc["sub"]

            # --- voluntary cancellation: decided today, effective at the next billing date
            if "cancel_at" not in sub and sub["start"] < day:
                h = MONTHLY_CHURN / 30
                h *= 2.2 if (day - acc["signup"]).days < 90 else 1
                h *= 1.3 if sub["plan"] == "Standard with ads" else 1.4 if sub["plan"] == "Mobile" else 1
                h *= 2.0 if (day - acc["last_view"]).days > 21 else 1
                h *= 2.0 if hike else 1
                h *= {"IN": 1.4, "BR": 1.2, "MX": 1.2}.get(acc["country"], 1)
                if rnd.random() < h:
                    reason = weighted([(CANCEL_REASONS[0], 45 if hike else 20), (CANCEL_REASONS[1], 40 if (day - acc["last_view"]).days > 21 else 15),
                                       (CANCEL_REASONS[2], 25), (CANCEL_REASONS[3], 20), (CANCEL_REASONS[4], 10)])
                    sub["cancel_at"], sub["cancel_reason"] = sub["next_bill"], reason

            # --- occasionally a new device
            if rnd.random() < 0.015 / 30:
                add_device(acc, dt.datetime.combine(day, dt.time(rnd.randrange(8, 23), rnd.randrange(60))))

            # --- viewing
            weekend = day.weekday() >= 5
            for prof in acc["profiles"]:
                p_watch = min(0.95, WATCH_PROBABILITY * prof["eng"] * DOW[day.weekday()] * season * (1.1 if boost else 1))
                if rnd.random() >= p_watch:
                    continue
                hours = (HOURS_KIDS_WEEKEND if weekend else HOURS_KIDS_WEEKDAY) if prof["kids"] else HOURS_ADULT
                local_start = dt.datetime.combine(day, dt.time(rnd.choices(range(24), weights=hours)[0], rnd.randrange(60), rnd.randrange(60)))
                n_sessions += watch(acc, prof, local_start, cum_all, cum_kid, cum_local.get(acc["country"]), titles, items, item_of, out)
                acc["last_view"] = day

    # subscriptions: start row in the batch of the start; end row in the batch of the end
    for acc in accounts:
        for sub in acc["subs"]:
            end = sub["end"] if sub["end"] and sub["end"] <= END else None
            start_day = max(sub["start"], START)
            row = [acc["email"], sub["plan"], sub["start"].isoformat()]
            if end and batch_of(end) == batch_of(start_day):
                out.add(start_day, "subscriptions", row + [end.isoformat(), sub["reason"], sub["cancel"]])
            else:
                out.add(start_day, "subscriptions", row + [None, None, None])
                if end:
                    out.add(end, "subscriptions", row + [end.isoformat(), sub["reason"], sub["cancel"]])

    batches = out.write()
    active = sum(1 for a in accounts if a["sub"])
    print(f"batches: {len(batches)}  accounts: {len(accounts)} (active at end: {active})  "
          f"sessions: {n_sessions}  payments: {n_payments}  subscriptions: {sum(len(a['subs']) for a in accounts)}")


def watch(acc, prof, local_start, cum_all, cum_kid, cum_local, titles, items, item_of, out):
    """One viewing occasion: a movie, or one or more episodes in a row. Returns sessions written."""
    def pick(cum):
        if cum is None or cum[-1] <= 0:
            return None
        return int(np.searchsorted(cum, rnd.random() * cum[-1], side="right"))

    sub = acc["sub"]
    if prof["state"] and rnd.random() < 0.62:
        k, ep = prof["state"]
    else:
        k = pick(cum_kid) if prof["kids"] else None
        if k is None and not prof["kids"]:
            local = LOCAL_TASTE.get(acc["country"])
            k = pick(cum_local) if local and rnd.random() < local[1] else None
            k = pick(cum_all) if k is None else k
        if k is None:
            return 0
        ep = 0
    it, t = items[k], titles[items[k]["title"]]
    written, start = 0, local_start
    while True:
        if start.date() >= (sub["end"] or sub.get("cancel_at") or NOW_OPEN) or start.date() > END:
            break
        if it["season"] is None:
            runtime, season_no, ep_no = t["runtime"], None, None
            u = rnd.random()
            pct = rnd.uniform(92, 100) if u < 0.55 else rnd.uniform(15, 80) if u < 0.85 else rnd.uniform(2, 12)
        else:
            season = t["seasons"][it["season"]]
            ep_no_, _, runtime = season["episodes"][ep]
            season_no, ep_no = season["number"], ep_no_
            u = rnd.random()
            pct = rnd.uniform(93, 100) if u < 0.72 else rnd.uniform(20, 85) if u < 0.92 else rnd.uniform(2, 15)
        runtime = max(int(runtime or 45), 1)
        seconds = max(60, round(runtime * 60 * pct / 100 * rnd.uniform(0.95, 1.0)))
        dev = rnd.choices(acc["devices"], weights=[(DEVICE_TYPES[d["type"]][2] if start.hour in DEVICE_TYPES[d["type"]][1] else 1)
                                                   * (2 if prof["kids"] and d["type"] in ("Smart TV", "Tablet") else 1) for d in acc["devices"]])[0]
        utc = start - dt.timedelta(minutes=acc["tz"])
        out.add(start.date(), "watch_sessions", [new_guid(), acc["email"], prof["name"], dev["guid"], t["source_key"], season_no, ep_no,
                                                 ts(utc), ts(start), seconds, f"{pct:.2f}"])
        written += 1
        end_utc = utc + dt.timedelta(seconds=seconds)
        done = pct >= 90

        if it["season"] is None:                                   # movie
            prof["state"] = None
            if (done and rnd.random() < 0.10) or (pct < 15 and rnd.random() < 0.04):
                rate(acc, prof, t, end_utc, 2 if done and rnd.random() < 0.32 else (-1 if not done or rnd.random() < 0.12 else 1), out)
            break
        episodes = t["seasons"][it["season"]]["episodes"]
        if not done:                                               # stopped mid-episode: resume next time
            prof["state"] = (k, ep)
            break
        if ep + 1 < len(episodes):
            prof["state"] = (k, ep + 1)
            if written < 6 and rnd.random() < (0.40 if prof["kids"] else 0.55):
                ep += 1
                start = start + dt.timedelta(seconds=seconds + rnd.randrange(30, 300))
                continue
            break
        # finished the season
        prof["state"] = None
        if rnd.random() < 0.14:
            rate(acc, prof, t, end_utc, weighted([(2, 30), (1, 60), (-1, 10)]), out)
        nxt = item_of.get((it["title"], it["season"] + 1))
        if nxt is not None and items[nxt]["release"] <= start.date() and rnd.random() < 0.5:
            prof["state"] = (nxt, 0)
        break
    return written


def rate(acc, prof, t, when_utc, value, out):
    key = t["source_key"]
    old = prof["rated"].get(key)
    if old is not None and (old == value or rnd.random() >= 0.15):
        return
    prof["rated"][key] = value
    out.add(when_utc.date(), "ratings", [acc["email"], prof["name"], key, value, ts(when_utc)])


if __name__ == "__main__":
    main()
