/* =============================================================================
   03_staging_tables.sql
   Staging (stg) tables - one per CSV file, same column order as the file.
   Rows reference each other by business keys (Email, SourceKey, Guid ...);
   core.usp_LoadFromStaging resolves them to core IDs.

   Design choices
     - Typed columns: the source is our own generator, so a bad value should
       fail the load immediately instead of being converted silently.
     - No keys or constraints: staging is truncated and refilled per batch;
       all rules are enforced when the data moves into core.
   Re-runnable: drops and recreates all staging tables.
   ============================================================================= */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE NetflixDB;
GO

DROP TABLE IF EXISTS stg.ExchangeRate, stg.Title, stg.TitleGenre, stg.Season, stg.Episode,
                     stg.Person, stg.TitleCredit, stg.Account, stg.Profile, stg.Device,
                     stg.Subscription, stg.Payment, stg.WatchSession, stg.Rating;
GO

/* exchange_rates.csv */
CREATE TABLE stg.ExchangeRate
(
    CurrencyCode     CHAR(3)       NOT NULL,
    RateDate         DATE          NOT NULL,
    RateToUSD        DECIMAL(19,9) NOT NULL,
    IsCarriedForward BIT           NOT NULL
);

/* titles.csv */
CREATE TABLE stg.Title
(
    SourceKey        VARCHAR(40)    NOT NULL,
    TitleType        VARCHAR(10)    NOT NULL,
    TitleName        NVARCHAR(300)  NOT NULL,
    ReleaseYear      SMALLINT       NULL,
    DateAdded        DATE           NOT NULL,
    RatingCode       VARCHAR(10)    NOT NULL,
    RuntimeMinutes   SMALLINT       NULL,
    IsOriginal       BIT            NOT NULL,
    OriginalLanguage VARCHAR(10)    NOT NULL,
    [Description]    NVARCHAR(1000) NULL
);

/* title_genres.csv */
CREATE TABLE stg.TitleGenre
(
    TitleSourceKey VARCHAR(40)  NOT NULL,
    GenreName      NVARCHAR(50) NOT NULL
);

/* seasons.csv */
CREATE TABLE stg.Season
(
    TitleSourceKey VARCHAR(40) NOT NULL,
    SeasonNumber   SMALLINT    NOT NULL,
    ReleaseDate    DATE        NOT NULL
);

/* episodes.csv */
CREATE TABLE stg.Episode
(
    TitleSourceKey VARCHAR(40)   NOT NULL,
    SeasonNumber   SMALLINT      NOT NULL,
    EpisodeNumber  SMALLINT      NOT NULL,
    EpisodeName    NVARCHAR(300) NOT NULL,
    RuntimeMinutes SMALLINT      NOT NULL
);

/* persons.csv */
CREATE TABLE stg.Person
(
    SourceKey VARCHAR(40)   NOT NULL,
    FullName  NVARCHAR(200) NOT NULL
);

/* title_credits.csv */
CREATE TABLE stg.TitleCredit
(
    TitleSourceKey  VARCHAR(40) NOT NULL,
    PersonSourceKey VARCHAR(40) NOT NULL,
    [Role]          VARCHAR(20) NOT NULL,
    BillingOrder    SMALLINT    NULL
);

/* accounts.csv */
CREATE TABLE stg.Account
(
    Email      NVARCHAR(256) NOT NULL,
    CountryISO CHAR(2)       NOT NULL,
    SignupDate DATE          NOT NULL
);

/* profiles.csv */
CREATE TABLE stg.Profile
(
    AccountEmail  NVARCHAR(256) NOT NULL,
    ProfileName   NVARCHAR(50)  NOT NULL,
    IsKids        BIT           NOT NULL,
    MaxRatingCode VARCHAR(10)   NOT NULL,
    LanguageCode  VARCHAR(10)   NOT NULL,
    CreatedAtUtc  DATETIME2(0)  NOT NULL
);

/* devices.csv */
CREATE TABLE stg.Device
(
    DeviceGuid   UNIQUEIDENTIFIER NOT NULL,
    AccountEmail NVARCHAR(256)    NOT NULL,
    DeviceType   VARCHAR(20)      NOT NULL,
    [Platform]   VARCHAR(30)      NOT NULL,
    FirstSeenUtc DATETIME2(0)     NOT NULL
);

/* subscriptions.csv - new subscriptions AND updates (a subscription that ended) */
CREATE TABLE stg.Subscription
(
    AccountEmail       NVARCHAR(256) NOT NULL,
    PlanName           NVARCHAR(50)  NOT NULL,
    StartDate          DATE          NOT NULL,
    EndDate            DATE          NULL,
    EndReason          VARCHAR(20)   NULL,
    CancellationReason NVARCHAR(100) NULL
);

/* payments.csv */
CREATE TABLE stg.Payment
(
    TransactionRef        VARCHAR(40)   NOT NULL,
    AccountEmail          NVARCHAR(256) NOT NULL,
    SubscriptionStartDate DATE          NOT NULL,
    BillingPeriodStart    DATE          NOT NULL,
    Amount                DECIMAL(10,2) NOT NULL,
    CurrencyCode          CHAR(3)       NOT NULL,
    AttemptedAtUtc        DATETIME2(0)  NOT NULL,
    [Status]              VARCHAR(10)   NOT NULL,
    PaymentMethod         VARCHAR(20)   NOT NULL
);

/* watch_sessions.csv - SeasonNumber/EpisodeNumber empty for movies */
CREATE TABLE stg.WatchSession
(
    SessionGuid    UNIQUEIDENTIFIER NOT NULL,
    AccountEmail   NVARCHAR(256)    NOT NULL,
    ProfileName    NVARCHAR(50)     NOT NULL,
    DeviceGuid     UNIQUEIDENTIFIER NOT NULL,
    TitleSourceKey VARCHAR(40)      NOT NULL,
    SeasonNumber   SMALLINT         NULL,
    EpisodeNumber  SMALLINT         NULL,
    StartedAtUtc   DATETIME2(0)     NOT NULL,
    StartedAtLocal DATETIME2(0)     NOT NULL,
    WatchedSeconds INT              NOT NULL,
    ProgressPct    DECIMAL(5,2)     NOT NULL
);

/* ratings.csv */
CREATE TABLE stg.Rating
(
    AccountEmail   NVARCHAR(256) NOT NULL,
    ProfileName    NVARCHAR(50)  NOT NULL,
    TitleSourceKey VARCHAR(40)   NOT NULL,
    RatingValue    SMALLINT      NOT NULL,
    RatedAtUtc     DATETIME2(0)  NOT NULL
);
GO
