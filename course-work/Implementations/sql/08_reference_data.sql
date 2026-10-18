/* =============================================================================
   08_reference_data.sql
   Static reference data: regions, countries, currencies, maturity ratings,
   genres, plans and plan prices. Re-runnable: inserts only missing rows
   (matched on business keys), never deletes.

   Plan prices (monthly, local currency) - sources and accuracy
     US  real history:
         - Basic closed to new members Jul 2023, retired for existing members
           from Jul 2024 (end date 2024-10-01 is approximate)
         - increases 2023-10-18 (Basic, Premium), 2025-01-21 (all),
           2026-03-26 (all; date approximate)
     BG  real: Netflix bills Bulgaria in EUR; price cut in Feb 2023
         (effective date 2023-02-16 approximate). No ads plan in Bulgaria.
     IN  real: prices unchanged since the Dec 2021 cut. Mobile plan; no ads plan.
     Other countries: ONE approximate price level (2025-26 public price lists)
         for the whole period - not their exact price history.
     The ads plan is called "Standard with ads" for the whole period (it was
     "Basic with ads" until late 2023).
   ============================================================================= */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE NetflixDB;
GO

/* ---------- Region ---------- */
INSERT INTO core.Region (RegionCode, RegionName)
SELECT v.RegionCode, v.RegionName
FROM (VALUES ('UCAN',  N'United States & Canada'),
             ('EMEA',  N'Europe, Middle East & Africa'),
             ('LATAM', N'Latin America'),
             ('APAC',  N'Asia-Pacific')) AS v (RegionCode, RegionName)
WHERE NOT EXISTS (SELECT 1 FROM core.Region AS r WHERE r.RegionCode = v.RegionCode);

/* ---------- Country ---------- */
INSERT INTO core.Country (ISOCode, CountryName, RegionID)
SELECT v.ISOCode, v.CountryName, r.RegionID
FROM (VALUES ('US', N'United States',  'UCAN'),
             ('CA', N'Canada',         'UCAN'),
             ('GB', N'United Kingdom', 'EMEA'),
             ('DE', N'Germany',        'EMEA'),
             ('FR', N'France',         'EMEA'),
             ('ES', N'Spain',          'EMEA'),
             ('BG', N'Bulgaria',       'EMEA'),
             ('BR', N'Brazil',         'LATAM'),
             ('MX', N'Mexico',         'LATAM'),
             ('IN', N'India',          'APAC'),
             ('JP', N'Japan',          'APAC'),
             ('KR', N'South Korea',    'APAC'),
             ('AU', N'Australia',      'APAC')) AS v (ISOCode, CountryName, RegionCode)
JOIN core.Region AS r ON r.RegionCode = v.RegionCode
WHERE NOT EXISTS (SELECT 1 FROM core.Country AS c WHERE c.ISOCode = v.ISOCode);

/* ---------- Currency ---------- */
INSERT INTO core.Currency (CurrencyCode, CurrencyName, Symbol, MinorUnits)
SELECT v.CurrencyCode, v.CurrencyName, v.Symbol, v.MinorUnits
FROM (VALUES ('USD', N'US dollar',          N'$',   2),
             ('CAD', N'Canadian dollar',    N'C$',  2),
             ('GBP', N'Pound sterling',     N'£',   2),
             ('EUR', N'Euro',               N'€',   2),
             ('BRL', N'Brazilian real',     N'R$',  2),
             ('MXN', N'Mexican peso',       N'MX$', 2),
             ('INR', N'Indian rupee',       N'₹',   2),
             ('JPY', N'Japanese yen',       N'¥',   0),
             ('KRW', N'South Korean won',   N'₩',   0),
             ('AUD', N'Australian dollar',  N'A$',  2)) AS v (CurrencyCode, CurrencyName, Symbol, MinorUnits)
WHERE NOT EXISTS (SELECT 1 FROM core.Currency AS c WHERE c.CurrencyCode = v.CurrencyCode);

/* ---------- MaturityRating (US ratings; MinAge = youngest age the rating allows) ---------- */
INSERT INTO core.MaturityRating (RatingCode, MinAge, [Description])
SELECT v.RatingCode, v.MinAge, v.[Description]
FROM (VALUES ('TV-Y',  0,  N'All children'),
             ('TV-G',  0,  N'General audience'),
             ('G',     0,  N'General audiences'),
             ('TV-Y7', 7,  N'Directed to children 7 and older'),
             ('TV-PG', 7,  N'Parental guidance suggested'),
             ('PG',    7,  N'Parental guidance suggested'),
             ('PG-13', 13, N'Parents strongly cautioned'),
             ('TV-14', 14, N'Parents strongly cautioned (14+)'),
             ('R',     17, N'Restricted (under 17 with a parent)'),
             ('NC-17', 18, N'Adults only'),
             ('TV-MA', 18, N'Mature audience only'),
             ('NR',    18, N'Not rated - treated as adult')) AS v (RatingCode, MinAge, [Description])
WHERE NOT EXISTS (SELECT 1 FROM core.MaturityRating AS m WHERE m.RatingCode = v.RatingCode);

/* ---------- Genre (TMDB movie + TV genres, combined TV genres split) ---------- */
INSERT INTO core.Genre (GenreName)
SELECT v.GenreName
FROM (VALUES (N'Action'), (N'Adventure'), (N'Animation'), (N'Comedy'), (N'Crime'), (N'Documentary'),
             (N'Drama'), (N'Family'), (N'Fantasy'), (N'History'), (N'Horror'), (N'Kids'), (N'Music'),
             (N'Mystery'), (N'Reality'), (N'Romance'), (N'Science Fiction'), (N'Thriller'), (N'War'),
             (N'Western'), (N'Talk'), (N'News'), (N'Soap')) AS v (GenreName)
WHERE NOT EXISTS (SELECT 1 FROM core.Genre AS g WHERE g.GenreName = v.GenreName);

/* ---------- Plan ---------- */
INSERT INTO core.[Plan] (PlanName, MaxStreams, MaxResolution, HasAds, DownloadDevices)
SELECT v.PlanName, v.MaxStreams, v.MaxResolution, v.HasAds, v.DownloadDevices
FROM (VALUES (N'Mobile',            1, '480p',  0, 1),
             (N'Basic',             1, '720p',  0, 1),
             (N'Standard with ads', 2, '1080p', 1, 2),
             (N'Standard',          2, '1080p', 0, 2),
             (N'Premium',           4, '4K',    0, 6)) AS v (PlanName, MaxStreams, MaxResolution, HasAds, DownloadDevices)
WHERE NOT EXISTS (SELECT 1 FROM core.[Plan] AS p WHERE p.PlanName = v.PlanName);

/* ---------- PlanPrice ---------- */
DECLARE @Start DATE = '2023-01-01';

INSERT INTO core.PlanPrice (PlanID, CountryID, CurrencyCode, MonthlyPrice, ValidFrom, ValidTo)
SELECT p.PlanID, c.CountryID, v.CurrencyCode, v.MonthlyPrice, v.ValidFrom, v.ValidTo
FROM (VALUES
    -- United States (real history)
    ('US', N'Basic',             'USD',  9.99, @Start,       '2023-10-18'),
    ('US', N'Basic',             'USD', 11.99, '2023-10-18', '2024-10-01'),
    ('US', N'Standard with ads', 'USD',  6.99, @Start,       '2025-01-21'),
    ('US', N'Standard with ads', 'USD',  7.99, '2025-01-21', '2026-03-26'),
    ('US', N'Standard with ads', 'USD',  8.99, '2026-03-26', NULL),
    ('US', N'Standard',          'USD', 15.49, @Start,       '2025-01-21'),
    ('US', N'Standard',          'USD', 17.99, '2025-01-21', '2026-03-26'),
    ('US', N'Standard',          'USD', 19.99, '2026-03-26', NULL),
    ('US', N'Premium',           'USD', 19.99, @Start,       '2023-10-18'),
    ('US', N'Premium',           'USD', 22.99, '2023-10-18', '2025-01-21'),
    ('US', N'Premium',           'USD', 24.99, '2025-01-21', '2026-03-26'),
    ('US', N'Premium',           'USD', 26.99, '2026-03-26', NULL),
    -- Bulgaria (real; EUR; Feb 2023 price cut)
    ('BG', N'Basic',             'EUR',  7.99, @Start,       '2023-02-16'),
    ('BG', N'Basic',             'EUR',  4.99, '2023-02-16', NULL),
    ('BG', N'Standard',          'EUR',  9.99, @Start,       '2023-02-16'),
    ('BG', N'Standard',          'EUR',  7.99, '2023-02-16', NULL),
    ('BG', N'Premium',           'EUR', 11.99, @Start,       '2023-02-16'),
    ('BG', N'Premium',           'EUR',  9.99, '2023-02-16', NULL),
    -- India (real; unchanged since Dec 2021)
    ('IN', N'Mobile',            'INR', 149.00, @Start, NULL),
    ('IN', N'Basic',             'INR', 199.00, @Start, NULL),
    ('IN', N'Standard',          'INR', 499.00, @Start, NULL),
    ('IN', N'Premium',           'INR', 649.00, @Start, NULL),
    -- Other countries (approximate single level)
    ('CA', N'Standard with ads', 'CAD',     7.99, @Start, NULL),
    ('CA', N'Standard',          'CAD',    18.99, @Start, NULL),
    ('CA', N'Premium',           'CAD',    23.99, @Start, NULL),
    ('GB', N'Standard with ads', 'GBP',     5.99, @Start, NULL),
    ('GB', N'Standard',          'GBP',    12.99, @Start, NULL),
    ('GB', N'Premium',           'GBP',    18.99, @Start, NULL),
    ('DE', N'Standard with ads', 'EUR',     4.99, @Start, NULL),
    ('DE', N'Standard',          'EUR',    13.99, @Start, NULL),
    ('DE', N'Premium',           'EUR',    19.99, @Start, NULL),
    ('FR', N'Standard with ads', 'EUR',     7.99, @Start, NULL),
    ('FR', N'Standard',          'EUR',    14.99, @Start, NULL),
    ('FR', N'Premium',           'EUR',    21.99, @Start, NULL),
    ('ES', N'Standard with ads', 'EUR',     6.99, @Start, NULL),
    ('ES', N'Standard',          'EUR',    13.99, @Start, NULL),
    ('ES', N'Premium',           'EUR',    19.99, @Start, NULL),
    ('BR', N'Standard with ads', 'BRL',    20.90, @Start, NULL),
    ('BR', N'Standard',          'BRL',    44.90, @Start, NULL),
    ('BR', N'Premium',           'BRL',    59.90, @Start, NULL),
    ('MX', N'Standard with ads', 'MXN',   119.00, @Start, NULL),
    ('MX', N'Standard',          'MXN',   249.00, @Start, NULL),
    ('MX', N'Premium',           'MXN',   329.00, @Start, NULL),
    ('JP', N'Standard with ads', 'JPY',   890.00, @Start, NULL),
    ('JP', N'Standard',          'JPY',  1590.00, @Start, NULL),
    ('JP', N'Premium',           'JPY',  2290.00, @Start, NULL),
    ('KR', N'Standard with ads', 'KRW',  5500.00, @Start, NULL),
    ('KR', N'Standard',          'KRW', 13500.00, @Start, NULL),
    ('KR', N'Premium',           'KRW', 17000.00, @Start, NULL),
    ('AU', N'Standard with ads', 'AUD',     7.99, @Start, NULL),
    ('AU', N'Standard',          'AUD',    18.99, @Start, NULL),
    ('AU', N'Premium',           'AUD',    25.99, @Start, NULL)
) AS v (ISOCode, PlanName, CurrencyCode, MonthlyPrice, ValidFrom, ValidTo)
JOIN core.Country AS c ON c.ISOCode = v.ISOCode
JOIN core.[Plan]  AS p ON p.PlanName = v.PlanName
WHERE NOT EXISTS (SELECT 1 FROM core.PlanPrice AS x
                  WHERE x.PlanID = p.PlanID AND x.CountryID = c.CountryID AND x.ValidFrom = v.ValidFrom);
GO

/* ---------- Rule 7 check: price periods of the same plan and country never overlap ---------- */
IF EXISTS (SELECT 1
           FROM core.PlanPrice AS a
           JOIN core.PlanPrice AS b
             ON  b.PlanID = a.PlanID AND b.CountryID = a.CountryID AND b.PlanPriceID <> a.PlanPriceID
           WHERE a.ValidFrom < ISNULL(b.ValidTo, '9999-12-31')
             AND b.ValidFrom < ISNULL(a.ValidTo, '9999-12-31'))
    THROW 50301, N'Reference data invalid: overlapping PlanPrice periods.', 1;
GO
