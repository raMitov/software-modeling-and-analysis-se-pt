/* =============================================================================
   06_triggers.sql
   Business rules that a CHECK or FOREIGN KEY cannot express (they span rows
   or tables). Both triggers are set-based: they validate every row of the
   statement at once (inserted can hold 1 or 100 000 rows) and THROW, which
   rolls back the whole statement - a bad batch never loads partially.
   Re-runnable (CREATE OR ALTER).
   ============================================================================= */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE NetflixDB;
GO

/* Rules 4 and 6:
   - the title's maturity rating is within the profile's limit
   - series need an episode of that same title; movies have no episode
   - the device belongs to the profile's account */
CREATE OR ALTER TRIGGER core.TR_WatchSession_Validate
ON core.WatchSession
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inserted)
        RETURN;

    IF EXISTS
    (
        SELECT 1
        FROM inserted AS i
        JOIN core.Profile        AS p  ON p.ProfileID         = i.ProfileID
        JOIN core.MaturityRating AS pm ON pm.MaturityRatingID = p.MaxMaturityRatingID
        JOIN core.Title          AS t  ON t.TitleID           = i.TitleID
        JOIN core.MaturityRating AS tm ON tm.MaturityRatingID = t.MaturityRatingID
        WHERE tm.MinAge > pm.MinAge
    )
        THROW 50001, N'WatchSession rejected: title is above the profile''s maturity limit.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM inserted AS i
        JOIN core.Title        AS t ON t.TitleID  = i.TitleID
        LEFT JOIN core.Episode AS e ON e.EpisodeID = i.EpisodeID
        LEFT JOIN core.Season  AS s ON s.SeasonID  = e.SeasonID
        WHERE (t.TitleType = 'Movie'  AND i.EpisodeID IS NOT NULL)
           OR (t.TitleType = 'Series' AND (i.EpisodeID IS NULL OR s.TitleID <> i.TitleID))
    )
        THROW 50002, N'WatchSession rejected: episode does not match the title (series need an episode of that title, movies none).', 1;

    IF EXISTS
    (
        SELECT 1
        FROM inserted AS i
        JOIN core.Profile AS p ON p.ProfileID = i.ProfileID
        JOIN core.Device  AS d ON d.DeviceID  = i.DeviceID
        WHERE d.AccountID <> p.AccountID
    )
        THROW 50003, N'WatchSession rejected: device does not belong to the profile''s account.', 1;
END;
GO

/* Rule 2: an account's subscription periods never overlap.
   Half-open periods [StartDate, EndDate) overlap when A.Start < B.End AND B.Start < A.End;
   back-to-back periods (plan change: old EndDate = new StartDate) are allowed. */
CREATE OR ALTER TRIGGER core.TR_Subscription_NoOverlap
ON core.Subscription
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inserted)
        RETURN;

    IF EXISTS
    (
        SELECT 1
        FROM inserted AS i
        JOIN core.Subscription AS s
          ON  s.AccountID       = i.AccountID
          AND s.SubscriptionID <> i.SubscriptionID
        WHERE s.StartDate < ISNULL(i.EndDate, '9999-12-31')
          AND i.StartDate < ISNULL(s.EndDate, '9999-12-31')
    )
        THROW 50010, N'Subscription rejected: periods of the same account must not overlap.', 1;
END;
GO
