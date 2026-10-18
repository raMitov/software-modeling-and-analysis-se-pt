/* =============================================================================
   07_procedures.sql
   stg.usp_ImportBatch      - CSV files of one batch folder -> staging (stg)
   core.usp_LoadFromStaging - raw (stg) -> normalised model (core)
   dw.usp_LoadWarehouse     - core -> star schema (dw)

   The two load procedures
     - run as one transaction (all or nothing), XACT_ABORT ON, TRY/CATCH + THROW
     - are idempotent: rows already loaded are skipped (matched on business keys),
       so running the same batch twice changes nothing
     - fail fast with a clear message instead of silently dropping rows
     - return one result set: rows inserted / updated per table
   Re-runnable (CREATE OR ALTER).
   ============================================================================= */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE NetflixDB;
GO

/* =============================================================================
   stg.usp_ImportBatch
   Empties staging and bulk-loads the 14 CSV files of one batch folder
   (data/batches/history/YYYY-MM or data/batches/daily/YYYY-MM-DD).
   Files: UTF-8, header row, comma separated, quoted when needed, empty = NULL.
   The SQL Server service account needs read access to the folder.
   ============================================================================= */
CREATE OR ALTER PROCEDURE stg.usp_ImportBatch
    @Folder NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Files TABLE (FileName SYSNAME, TableName SYSNAME);
    INSERT INTO @Files VALUES
        (N'exchange_rates', N'ExchangeRate'), (N'titles', N'Title'), (N'title_genres', N'TitleGenre'),
        (N'seasons', N'Season'), (N'episodes', N'Episode'), (N'persons', N'Person'),
        (N'title_credits', N'TitleCredit'), (N'accounts', N'Account'), (N'profiles', N'Profile'),
        (N'devices', N'Device'), (N'subscriptions', N'Subscription'), (N'payments', N'Payment'),
        (N'watch_sessions', N'WatchSession'), (N'ratings', N'Rating');

    DECLARE @Result TABLE (TableName SYSNAME, RowsStaged INT);
    DECLARE @file SYSNAME, @table SYSNAME, @sql NVARCHAR(MAX), @rows INT;
    DECLARE @path NVARCHAR(400) = REPLACE(@Folder, N'''', N'''''');   -- path goes into a string literal
    IF RIGHT(@path, 1) <> N'\' SET @path += N'\';

    BEGIN TRY
        DECLARE files CURSOR LOCAL FAST_FORWARD FOR SELECT FileName, TableName FROM @Files;
        OPEN files;
        FETCH NEXT FROM files INTO @file, @table;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @sql = N'TRUNCATE TABLE stg.' + QUOTENAME(@table) + N';
                         BULK INSERT stg.' + QUOTENAME(@table) + N' FROM ''' + @path + @file + N'.csv''
                         WITH (FORMAT = ''CSV'', FIRSTROW = 2, CODEPAGE = ''65001'', ROWTERMINATOR = ''0x0a'',
                               KEEPNULLS, TABLOCK);
                         SELECT @rows = COUNT(*) FROM stg.' + QUOTENAME(@table) + N';';
            EXEC sys.sp_executesql @sql, N'@rows INT OUTPUT', @rows = @rows OUTPUT;
            INSERT INTO @Result VALUES (@table, @rows);
            FETCH NEXT FROM files INTO @file, @table;
        END;
        CLOSE files;
        DEALLOCATE files;

        SELECT TableName, RowsStaged FROM @Result;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local', 'files') >= 0 BEGIN CLOSE files; DEALLOCATE files; END;
        THROW;
    END CATCH;
END;
GO

/* =============================================================================
   core.usp_LoadFromStaging
   Moves the current batch from stg into core in dependency order. Business keys
   in the files (Email, SourceKey, Guid ...) are resolved to core IDs. Triggers on
   core validate the cross-table rules; rule 3 (viewing only during an active
   subscription) is checked here with core.fn_ActiveSubscriptions.
   ============================================================================= */
CREATE OR ALTER PROCEDURE core.usp_LoadFromStaging
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Result TABLE (TableName SYSNAME, RowsInserted INT, RowsUpdated INT);
    DECLARE @ins INT, @upd INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        /* ---------- ExchangeRate (upsert: a real rate replaces a carried-forward one) ---------- */
        IF EXISTS (SELECT 1 FROM stg.ExchangeRate AS s
                   WHERE NOT EXISTS (SELECT 1 FROM core.Currency AS c WHERE c.CurrencyCode = s.CurrencyCode))
            THROW 50101, N'Load rejected: exchange_rates.csv references an unknown currency.', 1;

        UPDATE er
        SET    er.RateToUSD = s.RateToUSD, er.IsCarriedForward = s.IsCarriedForward
        FROM   core.ExchangeRate AS er
        JOIN   stg.ExchangeRate  AS s ON s.CurrencyCode = er.CurrencyCode AND s.RateDate = er.RateDate
        WHERE  er.RateToUSD <> s.RateToUSD OR er.IsCarriedForward <> s.IsCarriedForward;
        SET @upd = @@ROWCOUNT;

        INSERT INTO core.ExchangeRate (CurrencyCode, RateDate, RateToUSD, IsCarriedForward)
        SELECT s.CurrencyCode, s.RateDate, s.RateToUSD, s.IsCarriedForward
        FROM   stg.ExchangeRate AS s
        WHERE  NOT EXISTS (SELECT 1 FROM core.ExchangeRate AS er
                           WHERE er.CurrencyCode = s.CurrencyCode AND er.RateDate = s.RateDate);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'ExchangeRate', @ins, @upd);

        /* ---------- Title ---------- */
        IF EXISTS (SELECT 1 FROM stg.Title AS s
                   WHERE NOT EXISTS (SELECT 1 FROM core.MaturityRating AS m WHERE m.RatingCode = s.RatingCode))
            THROW 50102, N'Load rejected: titles.csv references an unknown maturity rating.', 1;

        INSERT INTO core.Title (SourceKey, TitleType, TitleName, ReleaseYear, DateAdded, MaturityRatingID,
                                RuntimeMinutes, IsOriginal, OriginalLanguage, [Description])
        SELECT s.SourceKey, s.TitleType, s.TitleName, s.ReleaseYear, s.DateAdded, m.MaturityRatingID,
               s.RuntimeMinutes, s.IsOriginal, s.OriginalLanguage, s.[Description]
        FROM   stg.Title AS s
        JOIN   core.MaturityRating AS m ON m.RatingCode = s.RatingCode
        WHERE  NOT EXISTS (SELECT 1 FROM core.Title AS t WHERE t.SourceKey = s.SourceKey);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'Title', @ins, 0);

        /* ---------- Season ---------- */
        IF EXISTS (SELECT 1 FROM stg.Season AS s
                   WHERE NOT EXISTS (SELECT 1 FROM core.Title AS t WHERE t.SourceKey = s.TitleSourceKey))
            THROW 50103, N'Load rejected: seasons.csv references an unknown title.', 1;

        INSERT INTO core.Season (TitleID, SeasonNumber, ReleaseDate)
        SELECT t.TitleID, s.SeasonNumber, s.ReleaseDate
        FROM   stg.Season AS s
        JOIN   core.Title AS t ON t.SourceKey = s.TitleSourceKey
        WHERE  NOT EXISTS (SELECT 1 FROM core.Season AS x WHERE x.TitleID = t.TitleID AND x.SeasonNumber = s.SeasonNumber);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'Season', @ins, 0);

        /* ---------- Episode ---------- */
        IF EXISTS (SELECT 1 FROM stg.Episode AS s
                   WHERE NOT EXISTS (SELECT 1 FROM core.Title AS t
                                     JOIN core.Season AS se ON se.TitleID = t.TitleID
                                     WHERE t.SourceKey = s.TitleSourceKey AND se.SeasonNumber = s.SeasonNumber))
            THROW 50104, N'Load rejected: episodes.csv references an unknown season.', 1;

        INSERT INTO core.Episode (SeasonID, EpisodeNumber, EpisodeName, RuntimeMinutes)
        SELECT se.SeasonID, s.EpisodeNumber, s.EpisodeName, s.RuntimeMinutes
        FROM   stg.Episode AS s
        JOIN   core.Title  AS t  ON t.SourceKey = s.TitleSourceKey
        JOIN   core.Season AS se ON se.TitleID = t.TitleID AND se.SeasonNumber = s.SeasonNumber
        WHERE  NOT EXISTS (SELECT 1 FROM core.Episode AS e WHERE e.SeasonID = se.SeasonID AND e.EpisodeNumber = s.EpisodeNumber);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'Episode', @ins, 0);

        /* ---------- TitleGenre ---------- */
        IF EXISTS (SELECT 1 FROM stg.TitleGenre AS s
                   WHERE NOT EXISTS (SELECT 1 FROM core.Title AS t WHERE t.SourceKey = s.TitleSourceKey)
                      OR NOT EXISTS (SELECT 1 FROM core.Genre AS g WHERE g.GenreName = s.GenreName))
            THROW 50105, N'Load rejected: title_genres.csv references an unknown title or genre.', 1;

        INSERT INTO core.TitleGenre (TitleID, GenreID)
        SELECT t.TitleID, g.GenreID
        FROM   stg.TitleGenre AS s
        JOIN   core.Title AS t ON t.SourceKey = s.TitleSourceKey
        JOIN   core.Genre AS g ON g.GenreName = s.GenreName
        WHERE  NOT EXISTS (SELECT 1 FROM core.TitleGenre AS x WHERE x.TitleID = t.TitleID AND x.GenreID = g.GenreID);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'TitleGenre', @ins, 0);

        /* ---------- Person ---------- */
        INSERT INTO core.Person (SourceKey, FullName)
        SELECT s.SourceKey, s.FullName
        FROM   stg.Person AS s
        WHERE  NOT EXISTS (SELECT 1 FROM core.Person AS p WHERE p.SourceKey = s.SourceKey);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'Person', @ins, 0);

        /* ---------- TitleCredit ---------- */
        IF EXISTS (SELECT 1 FROM stg.TitleCredit AS s
                   WHERE NOT EXISTS (SELECT 1 FROM core.Title  AS t WHERE t.SourceKey = s.TitleSourceKey)
                      OR NOT EXISTS (SELECT 1 FROM core.Person AS p WHERE p.SourceKey = s.PersonSourceKey))
            THROW 50106, N'Load rejected: title_credits.csv references an unknown title or person.', 1;

        INSERT INTO core.TitleCredit (TitleID, PersonID, [Role], BillingOrder)
        SELECT t.TitleID, p.PersonID, s.[Role], s.BillingOrder
        FROM   stg.TitleCredit AS s
        JOIN   core.Title  AS t ON t.SourceKey = s.TitleSourceKey
        JOIN   core.Person AS p ON p.SourceKey = s.PersonSourceKey
        WHERE  NOT EXISTS (SELECT 1 FROM core.TitleCredit AS x WHERE x.TitleID = t.TitleID AND x.PersonID = p.PersonID);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'TitleCredit', @ins, 0);

        /* ---------- Account ---------- */
        IF EXISTS (SELECT 1 FROM stg.Account AS s
                   WHERE NOT EXISTS (SELECT 1 FROM core.Country AS c WHERE c.ISOCode = s.CountryISO))
            THROW 50107, N'Load rejected: accounts.csv references an unknown country.', 1;

        INSERT INTO core.Account (Email, CountryID, SignupDate)
        SELECT s.Email, c.CountryID, s.SignupDate
        FROM   stg.Account AS s
        JOIN   core.Country AS c ON c.ISOCode = s.CountryISO
        WHERE  NOT EXISTS (SELECT 1 FROM core.Account AS a WHERE a.Email = s.Email);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'Account', @ins, 0);

        /* ---------- Profile ---------- */
        IF EXISTS (SELECT 1 FROM stg.Profile AS s
                   WHERE NOT EXISTS (SELECT 1 FROM core.Account AS a WHERE a.Email = s.AccountEmail)
                      OR NOT EXISTS (SELECT 1 FROM core.MaturityRating AS m WHERE m.RatingCode = s.MaxRatingCode))
            THROW 50108, N'Load rejected: profiles.csv references an unknown account or maturity rating.', 1;

        INSERT INTO core.Profile (AccountID, ProfileName, IsKids, MaxMaturityRatingID, LanguageCode, CreatedAtUtc)
        SELECT a.AccountID, s.ProfileName, s.IsKids, m.MaturityRatingID, s.LanguageCode, s.CreatedAtUtc
        FROM   stg.Profile AS s
        JOIN   core.Account        AS a ON a.Email = s.AccountEmail
        JOIN   core.MaturityRating AS m ON m.RatingCode = s.MaxRatingCode
        WHERE  NOT EXISTS (SELECT 1 FROM core.Profile AS p WHERE p.AccountID = a.AccountID AND p.ProfileName = s.ProfileName);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'Profile', @ins, 0);

        /* ---------- Device ---------- */
        IF EXISTS (SELECT 1 FROM stg.Device AS s
                   WHERE NOT EXISTS (SELECT 1 FROM core.Account AS a WHERE a.Email = s.AccountEmail))
            THROW 50109, N'Load rejected: devices.csv references an unknown account.', 1;

        INSERT INTO core.Device (DeviceGuid, AccountID, DeviceType, [Platform], FirstSeenUtc)
        SELECT s.DeviceGuid, a.AccountID, s.DeviceType, s.[Platform], s.FirstSeenUtc
        FROM   stg.Device AS s
        JOIN   core.Account AS a ON a.Email = s.AccountEmail
        WHERE  NOT EXISTS (SELECT 1 FROM core.Device AS d WHERE d.DeviceGuid = s.DeviceGuid);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'Device', @ins, 0);

        /* ---------- Subscription (close ended ones first, then insert new ones,
                      so a plan change never has two open periods at once) ---------- */
        IF EXISTS (SELECT 1 FROM stg.Subscription AS s
                   WHERE NOT EXISTS (SELECT 1 FROM core.Account AS a WHERE a.Email = s.AccountEmail)
                      OR NOT EXISTS (SELECT 1 FROM core.[Plan] AS p WHERE p.PlanName = s.PlanName))
            THROW 50110, N'Load rejected: subscriptions.csv references an unknown account or plan.', 1;

        UPDATE sub
        SET    sub.EndDate = s.EndDate, sub.EndReason = s.EndReason, sub.CancellationReason = s.CancellationReason
        FROM   core.Subscription AS sub
        JOIN   core.Account      AS a ON a.AccountID = sub.AccountID
        JOIN   stg.Subscription  AS s ON s.AccountEmail = a.Email AND s.StartDate = sub.StartDate
        WHERE  sub.EndDate IS NULL AND s.EndDate IS NOT NULL;
        SET @upd = @@ROWCOUNT;

        INSERT INTO core.Subscription (AccountID, PlanID, StartDate, EndDate, EndReason, CancellationReason)
        SELECT a.AccountID, p.PlanID, s.StartDate, s.EndDate, s.EndReason, s.CancellationReason
        FROM   stg.Subscription AS s
        JOIN   core.Account AS a ON a.Email = s.AccountEmail
        JOIN   core.[Plan]  AS p ON p.PlanName = s.PlanName
        WHERE  NOT EXISTS (SELECT 1 FROM core.Subscription AS x WHERE x.AccountID = a.AccountID AND x.StartDate = s.StartDate);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'Subscription', @ins, @upd);

        /* ---------- Payment ---------- */
        IF EXISTS (SELECT 1 FROM stg.Payment AS s
                   WHERE NOT EXISTS (SELECT 1 FROM core.Subscription AS sub
                                     JOIN core.Account AS a ON a.AccountID = sub.AccountID
                                     WHERE a.Email = s.AccountEmail AND sub.StartDate = s.SubscriptionStartDate)
                      OR NOT EXISTS (SELECT 1 FROM core.Currency AS c WHERE c.CurrencyCode = s.CurrencyCode))
            THROW 50111, N'Load rejected: payments.csv references an unknown subscription or currency.', 1;

        INSERT INTO core.Payment (TransactionRef, SubscriptionID, BillingPeriodStart, Amount, CurrencyCode,
                                  AttemptedAtUtc, [Status], PaymentMethod)
        SELECT s.TransactionRef, sub.SubscriptionID, s.BillingPeriodStart, s.Amount, s.CurrencyCode,
               s.AttemptedAtUtc, s.[Status], s.PaymentMethod
        FROM   stg.Payment AS s
        JOIN   core.Account      AS a   ON a.Email = s.AccountEmail
        JOIN   core.Subscription AS sub ON sub.AccountID = a.AccountID AND sub.StartDate = s.SubscriptionStartDate
        WHERE  NOT EXISTS (SELECT 1 FROM core.Payment AS x WHERE x.TransactionRef = s.TransactionRef);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'Payment', @ins, 0);

        /* ---------- WatchSession ---------- */
        IF EXISTS (SELECT 1
                   FROM stg.WatchSession AS s
                   LEFT JOIN core.Account AS a  ON a.Email = s.AccountEmail
                   LEFT JOIN core.Profile AS p  ON p.AccountID = a.AccountID AND p.ProfileName = s.ProfileName
                   LEFT JOIN core.Device  AS d  ON d.DeviceGuid = s.DeviceGuid
                   LEFT JOIN core.Title   AS t  ON t.SourceKey = s.TitleSourceKey
                   LEFT JOIN core.Season  AS se ON se.TitleID = t.TitleID AND se.SeasonNumber = s.SeasonNumber
                   LEFT JOIN core.Episode AS e  ON e.SeasonID = se.SeasonID AND e.EpisodeNumber = s.EpisodeNumber
                   WHERE p.ProfileID IS NULL OR d.DeviceID IS NULL OR t.TitleID IS NULL
                      OR (s.EpisodeNumber IS NOT NULL AND e.EpisodeID IS NULL))
            THROW 50112, N'Load rejected: watch_sessions.csv references an unknown profile, device, title or episode.', 1;

        -- Rule 3: viewing only while the account has an active subscription (local viewing date)
        IF EXISTS (SELECT 1
                   FROM stg.WatchSession AS s
                   JOIN core.Account AS a ON a.Email = s.AccountEmail
                   WHERE NOT EXISTS (SELECT 1
                                     FROM core.fn_ActiveSubscriptions(CAST(s.StartedAtLocal AS DATE)) AS act
                                     WHERE act.AccountID = a.AccountID))
            THROW 50113, N'Load rejected: watch_sessions.csv contains viewing without an active subscription.', 1;

        INSERT INTO core.WatchSession (SessionGuid, ProfileID, DeviceID, TitleID, EpisodeID, StartedAtUtc,
                                       StartedAtLocal, WatchedSeconds, ProgressPct)
        SELECT s.SessionGuid, p.ProfileID, d.DeviceID, t.TitleID, e.EpisodeID, s.StartedAtUtc,
               s.StartedAtLocal, s.WatchedSeconds, s.ProgressPct
        FROM   stg.WatchSession AS s
        JOIN   core.Account AS a ON a.Email = s.AccountEmail
        JOIN   core.Profile AS p ON p.AccountID = a.AccountID AND p.ProfileName = s.ProfileName
        JOIN   core.Device  AS d ON d.DeviceGuid = s.DeviceGuid
        JOIN   core.Title   AS t ON t.SourceKey = s.TitleSourceKey
        LEFT JOIN core.Season  AS se ON se.TitleID = t.TitleID AND se.SeasonNumber = s.SeasonNumber
        LEFT JOIN core.Episode AS e  ON e.SeasonID = se.SeasonID AND e.EpisodeNumber = s.EpisodeNumber
        WHERE  NOT EXISTS (SELECT 1 FROM core.WatchSession AS x WHERE x.SessionGuid = s.SessionGuid);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'WatchSession', @ins, 0);

        /* ---------- Rating (upsert: a profile can change its rating; if a batch holds
                      several ratings of the same title by the same profile, the latest wins) ---------- */
        IF EXISTS (SELECT 1
                   FROM stg.Rating AS s
                   LEFT JOIN core.Account AS a ON a.Email = s.AccountEmail
                   LEFT JOIN core.Profile AS p ON p.AccountID = a.AccountID AND p.ProfileName = s.ProfileName
                   LEFT JOIN core.Title   AS t ON t.SourceKey = s.TitleSourceKey
                   WHERE p.ProfileID IS NULL OR t.TitleID IS NULL)
            THROW 50114, N'Load rejected: ratings.csv references an unknown profile or title.', 1;

        UPDATE r
        SET    r.RatingValue = s.RatingValue, r.RatedAtUtc = s.RatedAtUtc
        FROM   core.Rating  AS r
        JOIN   core.Profile AS p ON p.ProfileID = r.ProfileID
        JOIN   core.Account AS a ON a.AccountID = p.AccountID
        JOIN   core.Title   AS t ON t.TitleID = r.TitleID
        JOIN   (SELECT x.AccountEmail, x.ProfileName, x.TitleSourceKey, x.RatingValue, x.RatedAtUtc
                FROM (SELECT r.AccountEmail, r.ProfileName, r.TitleSourceKey, r.RatingValue, r.RatedAtUtc,
                             ROW_NUMBER() OVER (PARTITION BY r.AccountEmail, r.ProfileName, r.TitleSourceKey
                                                ORDER BY r.RatedAtUtc DESC) AS rn
                      FROM stg.Rating AS r) AS x
                WHERE x.rn = 1) AS s
               ON s.AccountEmail = a.Email AND s.ProfileName = p.ProfileName AND s.TitleSourceKey = t.SourceKey
        WHERE  r.RatingValue <> s.RatingValue OR r.RatedAtUtc <> s.RatedAtUtc;
        SET @upd = @@ROWCOUNT;

        INSERT INTO core.Rating (ProfileID, TitleID, RatingValue, RatedAtUtc)
        SELECT p.ProfileID, t.TitleID, s.RatingValue, s.RatedAtUtc
        FROM   (SELECT x.AccountEmail, x.ProfileName, x.TitleSourceKey, x.RatingValue, x.RatedAtUtc
                FROM (SELECT r.AccountEmail, r.ProfileName, r.TitleSourceKey, r.RatingValue, r.RatedAtUtc,
                             ROW_NUMBER() OVER (PARTITION BY r.AccountEmail, r.ProfileName, r.TitleSourceKey
                                                ORDER BY r.RatedAtUtc DESC) AS rn
                      FROM stg.Rating AS r) AS x
                WHERE x.rn = 1) AS s
        JOIN   core.Account AS a ON a.Email = s.AccountEmail
        JOIN   core.Profile AS p ON p.AccountID = a.AccountID AND p.ProfileName = s.ProfileName
        JOIN   core.Title   AS t ON t.SourceKey = s.TitleSourceKey
        WHERE  NOT EXISTS (SELECT 1 FROM core.Rating AS x WHERE x.ProfileID = p.ProfileID AND x.TitleID = t.TitleID);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'Rating', @ins, @upd);

        COMMIT TRANSACTION;

        SELECT TableName, RowsInserted, RowsUpdated FROM @Result;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* =============================================================================
   dw.usp_LoadWarehouse
   Refreshes the star schema from core: dimensions first (type 1 - new rows
   inserted, changed attributes overwritten), then facts incrementally (only
   core rows not yet in the fact table). A final reconciliation guarantees no
   core row was skipped.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dw.usp_LoadWarehouse
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Result TABLE (TableName SYSNAME, RowsInserted INT, RowsUpdated INT);
    DECLARE @ins INT, @upd INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        /* ---------- DimAccount ---------- */
        SELECT a.AccountID, a.SignupDate, CONVERT(CHAR(7), a.SignupDate, 126) AS SignupMonth,
               c.ISOCode AS CountryISO, c.CountryName, r.RegionCode, r.RegionName
        INTO   #Account
        FROM   core.Account AS a
        JOIN   core.Country AS c ON c.CountryID = a.CountryID
        JOIN   core.Region  AS r ON r.RegionID = c.RegionID;

        UPDATE d
        SET    d.SignupDate = s.SignupDate, d.SignupMonth = s.SignupMonth, d.CountryISO = s.CountryISO,
               d.CountryName = s.CountryName, d.RegionCode = s.RegionCode, d.RegionName = s.RegionName
        FROM   dw.DimAccount AS d
        JOIN   #Account      AS s ON s.AccountID = d.AccountID
        WHERE  EXISTS (SELECT s.SignupDate, s.CountryISO, s.CountryName, s.RegionCode, s.RegionName
                       EXCEPT
                       SELECT d.SignupDate, d.CountryISO, d.CountryName, d.RegionCode, d.RegionName);
        SET @upd = @@ROWCOUNT;

        INSERT INTO dw.DimAccount (AccountID, SignupDate, SignupMonth, CountryISO, CountryName, RegionCode, RegionName)
        SELECT s.AccountID, s.SignupDate, s.SignupMonth, s.CountryISO, s.CountryName, s.RegionCode, s.RegionName
        FROM   #Account AS s
        WHERE  NOT EXISTS (SELECT 1 FROM dw.DimAccount AS d WHERE d.AccountID = s.AccountID);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'DimAccount', @ins, @upd);

        /* ---------- DimProfile ---------- */
        SELECT p.ProfileID, p.ProfileName,
               CAST(CASE WHEN p.IsKids = 1 THEN 'Kids' ELSE 'Standard' END AS VARCHAR(10)) AS ProfileType,
               m.RatingCode AS MaxMaturityRating, p.LanguageCode
        INTO   #Profile
        FROM   core.Profile        AS p
        JOIN   core.MaturityRating AS m ON m.MaturityRatingID = p.MaxMaturityRatingID;

        UPDATE d
        SET    d.ProfileName = s.ProfileName, d.ProfileType = s.ProfileType,
               d.MaxMaturityRating = s.MaxMaturityRating, d.LanguageCode = s.LanguageCode
        FROM   dw.DimProfile AS d
        JOIN   #Profile      AS s ON s.ProfileID = d.ProfileID
        WHERE  EXISTS (SELECT s.ProfileName, s.ProfileType, s.MaxMaturityRating, s.LanguageCode
                       EXCEPT
                       SELECT d.ProfileName, d.ProfileType, d.MaxMaturityRating, d.LanguageCode);
        SET @upd = @@ROWCOUNT;

        INSERT INTO dw.DimProfile (ProfileID, ProfileName, ProfileType, MaxMaturityRating, LanguageCode)
        SELECT s.ProfileID, s.ProfileName, s.ProfileType, s.MaxMaturityRating, s.LanguageCode
        FROM   #Profile AS s
        WHERE  NOT EXISTS (SELECT 1 FROM dw.DimProfile AS d WHERE d.ProfileID = s.ProfileID);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'DimProfile', @ins, @upd);

        /* ---------- DimTitle ---------- */
        SELECT t.TitleID, t.TitleName, t.TitleType, t.ReleaseYear, t.DateAdded,
               CAST(CASE WHEN t.IsOriginal = 1 THEN 'Netflix Original' ELSE 'Licensed' END AS VARCHAR(20)) AS ContentOrigin,
               t.OriginalLanguage, m.RatingCode AS MaturityRating, m.MinAge,
               g.Genres, t.RuntimeMinutes
        INTO   #Title
        FROM   core.Title          AS t
        JOIN   core.MaturityRating AS m ON m.MaturityRatingID = t.MaturityRatingID
        OUTER APPLY (SELECT CAST(STRING_AGG(gn.GenreName, N', ') WITHIN GROUP (ORDER BY gn.GenreName) AS NVARCHAR(400)) AS Genres
                     FROM core.TitleGenre AS tg
                     JOIN core.Genre      AS gn ON gn.GenreID = tg.GenreID
                     WHERE tg.TitleID = t.TitleID) AS g;

        UPDATE d
        SET    d.TitleName = s.TitleName, d.TitleType = s.TitleType, d.ReleaseYear = s.ReleaseYear,
               d.DateAdded = s.DateAdded, d.ContentOrigin = s.ContentOrigin, d.OriginalLanguage = s.OriginalLanguage,
               d.MaturityRating = s.MaturityRating, d.MinAge = s.MinAge, d.Genres = s.Genres,
               d.RuntimeMinutes = s.RuntimeMinutes
        FROM   dw.DimTitle AS d
        JOIN   #Title      AS s ON s.TitleID = d.TitleID
        WHERE  EXISTS (SELECT s.TitleName, s.TitleType, s.ReleaseYear, s.DateAdded, s.ContentOrigin,
                              s.OriginalLanguage, s.MaturityRating, s.MinAge, s.Genres, s.RuntimeMinutes
                       EXCEPT
                       SELECT d.TitleName, d.TitleType, d.ReleaseYear, d.DateAdded, d.ContentOrigin,
                              d.OriginalLanguage, d.MaturityRating, d.MinAge, d.Genres, d.RuntimeMinutes);
        SET @upd = @@ROWCOUNT;

        INSERT INTO dw.DimTitle (TitleID, TitleName, TitleType, ReleaseYear, DateAdded, ContentOrigin,
                                 OriginalLanguage, MaturityRating, MinAge, Genres, RuntimeMinutes)
        SELECT s.TitleID, s.TitleName, s.TitleType, s.ReleaseYear, s.DateAdded, s.ContentOrigin,
               s.OriginalLanguage, s.MaturityRating, s.MinAge, s.Genres, s.RuntimeMinutes
        FROM   #Title AS s
        WHERE  NOT EXISTS (SELECT 1 FROM dw.DimTitle AS d WHERE d.TitleID = s.TitleID);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'DimTitle', @ins, @upd);

        /* ---------- DimGenre + BridgeTitleGenre ---------- */
        UPDATE d SET d.GenreName = g.GenreName
        FROM   dw.DimGenre AS d JOIN core.Genre AS g ON g.GenreID = d.GenreID
        WHERE  d.GenreName <> g.GenreName;
        SET @upd = @@ROWCOUNT;

        INSERT INTO dw.DimGenre (GenreID, GenreName)
        SELECT g.GenreID, g.GenreName
        FROM   core.Genre AS g
        WHERE  NOT EXISTS (SELECT 1 FROM dw.DimGenre AS d WHERE d.GenreID = g.GenreID);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'DimGenre', @ins, @upd);

        INSERT INTO dw.BridgeTitleGenre (TitleKey, GenreKey)
        SELECT dt.TitleKey, dg.GenreKey
        FROM   core.TitleGenre AS tg
        JOIN   dw.DimTitle     AS dt ON dt.TitleID = tg.TitleID
        JOIN   dw.DimGenre     AS dg ON dg.GenreID = tg.GenreID
        WHERE  NOT EXISTS (SELECT 1 FROM dw.BridgeTitleGenre AS b WHERE b.TitleKey = dt.TitleKey AND b.GenreKey = dg.GenreKey);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'BridgeTitleGenre', @ins, 0);

        /* ---------- DimPlan ---------- */
        SELECT p.PlanID, p.PlanName, p.MaxStreams, p.MaxResolution,
               CAST(CASE WHEN p.HasAds = 1 THEN 'With ads' ELSE 'Ad-free' END AS VARCHAR(10)) AS AdSupport
        INTO   #Plan
        FROM   core.[Plan] AS p;

        UPDATE d
        SET    d.PlanName = s.PlanName, d.MaxStreams = s.MaxStreams, d.MaxResolution = s.MaxResolution, d.AdSupport = s.AdSupport
        FROM   dw.DimPlan AS d
        JOIN   #Plan      AS s ON s.PlanID = d.PlanID
        WHERE  EXISTS (SELECT s.PlanName, s.MaxStreams, s.MaxResolution, s.AdSupport
                       EXCEPT
                       SELECT d.PlanName, d.MaxStreams, d.MaxResolution, d.AdSupport);
        SET @upd = @@ROWCOUNT;

        INSERT INTO dw.DimPlan (PlanID, PlanName, MaxStreams, MaxResolution, AdSupport)
        SELECT s.PlanID, s.PlanName, s.MaxStreams, s.MaxResolution, s.AdSupport
        FROM   #Plan AS s
        WHERE  NOT EXISTS (SELECT 1 FROM dw.DimPlan AS d WHERE d.PlanID = s.PlanID);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'DimPlan', @ins, @upd);

        /* ---------- DimDevice ---------- */
        UPDATE d
        SET    d.DeviceType = s.DeviceType, d.[Platform] = s.[Platform]
        FROM   dw.DimDevice AS d
        JOIN   core.Device  AS s ON s.DeviceID = d.DeviceID
        WHERE  d.DeviceType <> s.DeviceType OR d.[Platform] <> s.[Platform];
        SET @upd = @@ROWCOUNT;

        INSERT INTO dw.DimDevice (DeviceID, DeviceType, [Platform])
        SELECT s.DeviceID, s.DeviceType, s.[Platform]
        FROM   core.Device AS s
        WHERE  NOT EXISTS (SELECT 1 FROM dw.DimDevice AS d WHERE d.DeviceID = s.DeviceID);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'DimDevice', @ins, @upd);

        /* ---------- FactViewing (new sessions only) ---------- */
        INSERT INTO dw.FactViewing (WatchSessionID, DateKey, StartHourLocal, AccountKey, ProfileKey, TitleKey,
                                    PlanKey, DeviceKey, SeasonNumber, EpisodeNumber, WatchedSeconds,
                                    ContentRuntimeMinutes, ProgressPct, IsCompleted)
        SELECT ws.WatchSessionID,
               CONVERT(INT, CONVERT(CHAR(8), CAST(ws.StartedAtLocal AS DATE), 112)),
               DATEPART(HOUR, ws.StartedAtLocal),
               da.AccountKey, dp.ProfileKey, dt.TitleKey, dpl.PlanKey, dd.DeviceKey,
               se.SeasonNumber, e.EpisodeNumber, ws.WatchedSeconds,
               COALESCE(e.RuntimeMinutes, t.RuntimeMinutes),
               ws.ProgressPct,
               CASE WHEN ws.ProgressPct >= 90 THEN 1 ELSE 0 END
        FROM   core.WatchSession AS ws
        JOIN   core.Profile      AS p   ON p.ProfileID = ws.ProfileID
        JOIN   core.Title        AS t   ON t.TitleID = ws.TitleID
        LEFT JOIN core.Episode   AS e   ON e.EpisodeID = ws.EpisodeID
        LEFT JOIN core.Season    AS se  ON se.SeasonID = e.SeasonID
        CROSS APPLY (SELECT act.PlanID
                     FROM core.fn_ActiveSubscriptions(CAST(ws.StartedAtLocal AS DATE)) AS act
                     WHERE act.AccountID = p.AccountID) AS sub
        JOIN   dw.DimAccount     AS da  ON da.AccountID = p.AccountID
        JOIN   dw.DimProfile     AS dp  ON dp.ProfileID = ws.ProfileID
        JOIN   dw.DimTitle       AS dt  ON dt.TitleID = ws.TitleID
        JOIN   dw.DimPlan        AS dpl ON dpl.PlanID = sub.PlanID
        JOIN   dw.DimDevice      AS dd  ON dd.DeviceID = ws.DeviceID
        WHERE  NOT EXISTS (SELECT 1 FROM dw.FactViewing AS f WHERE f.WatchSessionID = ws.WatchSessionID);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'FactViewing', @ins, 0);

        /* ---------- FactPayment (new payments only) ---------- */
        INSERT INTO dw.FactPayment (PaymentID, DateKey, AccountKey, PlanKey, BillingPeriodStart, CurrencyCode,
                                    AmountLocal, AmountUSD, PaymentStatus, PaymentMethod)
        SELECT pay.PaymentID,
               CONVERT(INT, CONVERT(CHAR(8), CAST(pay.AttemptedAtUtc AS DATE), 112)),
               da.AccountKey, dpl.PlanKey, pay.BillingPeriodStart, pay.CurrencyCode,
               pay.Amount,
               core.fn_ConvertToUSD(pay.Amount, pay.CurrencyCode, CAST(pay.AttemptedAtUtc AS DATE)),
               pay.[Status], pay.PaymentMethod
        FROM   core.Payment      AS pay
        JOIN   core.Subscription AS sub ON sub.SubscriptionID = pay.SubscriptionID
        JOIN   dw.DimAccount     AS da  ON da.AccountID = sub.AccountID
        JOIN   dw.DimPlan        AS dpl ON dpl.PlanID = sub.PlanID
        WHERE  NOT EXISTS (SELECT 1 FROM dw.FactPayment AS f WHERE f.PaymentID = pay.PaymentID);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'FactPayment', @ins, 0);

        /* ---------- FactRating (new ratings inserted, changed ratings updated) ---------- */
        UPDATE f
        SET    f.RatingValue = r.RatingValue,
               f.DateKey     = CONVERT(INT, CONVERT(CHAR(8), CAST(r.RatedAtUtc AS DATE), 112))
        FROM   dw.FactRating AS f
        JOIN   dw.DimProfile AS dp ON dp.ProfileKey = f.ProfileKey
        JOIN   dw.DimTitle   AS dt ON dt.TitleKey = f.TitleKey
        JOIN   core.Rating   AS r  ON r.ProfileID = dp.ProfileID AND r.TitleID = dt.TitleID
        WHERE  f.RatingValue <> r.RatingValue
           OR  f.DateKey <> CONVERT(INT, CONVERT(CHAR(8), CAST(r.RatedAtUtc AS DATE), 112));
        SET @upd = @@ROWCOUNT;

        INSERT INTO dw.FactRating (ProfileKey, TitleKey, DateKey, AccountKey, RatingValue)
        SELECT dp.ProfileKey, dt.TitleKey,
               CONVERT(INT, CONVERT(CHAR(8), CAST(r.RatedAtUtc AS DATE), 112)),
               da.AccountKey, r.RatingValue
        FROM   core.Rating   AS r
        JOIN   core.Profile  AS p  ON p.ProfileID = r.ProfileID
        JOIN   dw.DimProfile AS dp ON dp.ProfileID = r.ProfileID
        JOIN   dw.DimTitle   AS dt ON dt.TitleID = r.TitleID
        JOIN   dw.DimAccount AS da ON da.AccountID = p.AccountID
        WHERE  NOT EXISTS (SELECT 1 FROM dw.FactRating AS f WHERE f.ProfileKey = dp.ProfileKey AND f.TitleKey = dt.TitleKey);
        SET @ins = @@ROWCOUNT;
        INSERT INTO @Result VALUES (N'FactRating', @ins, @upd);

        /* ---------- Reconciliation: every core row must be in its fact table ---------- */
        IF (SELECT COUNT(*) FROM core.WatchSession) <> (SELECT COUNT(*) FROM dw.FactViewing)
            THROW 50201, N'Warehouse load failed: FactViewing does not match core.WatchSession.', 1;
        IF (SELECT COUNT(*) FROM core.Payment) <> (SELECT COUNT(*) FROM dw.FactPayment)
            THROW 50202, N'Warehouse load failed: FactPayment does not match core.Payment.', 1;
        IF (SELECT COUNT(*) FROM core.Rating) <> (SELECT COUNT(*) FROM dw.FactRating)
            THROW 50203, N'Warehouse load failed: FactRating does not match core.Rating.', 1;

        COMMIT TRANSACTION;

        SELECT TableName, RowsInserted, RowsUpdated FROM @Result;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
