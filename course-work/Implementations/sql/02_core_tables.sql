/* =============================================================================
   02_core_tables.sql
   Core (normalised) tables - implements the logical model 1:1.
   Re-runnable: drops and recreates all core tables (all core data is lost).

   Conventions
     - Surrogate keys: INT IDENTITY; business keys get a UNIQUE constraint
       (the loader matches incoming rows on them).
     - Date ranges are half-open: [ValidFrom, ValidTo) and [StartDate, EndDate).
       NULL end = still open.
     - Timestamps are UTC unless the column name says otherwise.
     - Money: DECIMAL(10,2) in the local currency of the row.
   ============================================================================= */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;   -- required by the filtered unique index on Subscription
GO

USE NetflixDB;
GO

/* ---------- drop (children first) ---------- */
DROP TABLE IF EXISTS core.Rating, core.WatchSession, core.TitleCredit, core.TitleGenre,
                     core.Episode, core.Season, core.Person, core.Genre, core.Title,
                     core.Payment, core.Subscription, core.PlanPrice, core.[Plan],
                     core.Device, core.Profile, core.MaturityRating, core.Account,
                     core.ExchangeRate, core.Currency, core.Country, core.Region;
GO

/* ========================= Geography & currency ========================= */
CREATE TABLE core.Region
(
    RegionID    INT IDENTITY(1,1) NOT NULL,
    RegionCode  VARCHAR(10)       NOT NULL,   -- UCAN, EMEA, LATAM, APAC
    RegionName  NVARCHAR(50)      NOT NULL,
    CONSTRAINT PK_Region PRIMARY KEY (RegionID),
    CONSTRAINT UQ_Region_RegionCode UNIQUE (RegionCode)
);

CREATE TABLE core.Country
(
    CountryID   INT IDENTITY(1,1) NOT NULL,
    ISOCode     CHAR(2)           NOT NULL,   -- ISO 3166-1 alpha-2
    CountryName NVARCHAR(100)     NOT NULL,
    RegionID    INT               NOT NULL,
    CONSTRAINT PK_Country PRIMARY KEY (CountryID),
    CONSTRAINT UQ_Country_ISOCode UNIQUE (ISOCode),
    CONSTRAINT FK_Country_Region FOREIGN KEY (RegionID) REFERENCES core.Region (RegionID)
);
CREATE INDEX IX_Country_RegionID ON core.Country (RegionID);

CREATE TABLE core.Currency
(
    CurrencyCode CHAR(3)      NOT NULL,       -- ISO 4217
    CurrencyName NVARCHAR(50) NOT NULL,
    Symbol       NVARCHAR(5)  NOT NULL,
    MinorUnits   TINYINT      NOT NULL,       -- decimals used (JPY/KRW = 0)
    CONSTRAINT PK_Currency PRIMARY KEY (CurrencyCode),
    CONSTRAINT CK_Currency_MinorUnits CHECK (MinorUnits <= 4)
);

CREATE TABLE core.ExchangeRate
(
    CurrencyCode     CHAR(3)        NOT NULL,
    RateDate         DATE           NOT NULL,
    RateToUSD        DECIMAL(19,9)  NOT NULL, -- USD value of 1 unit of the currency
    IsCarriedForward BIT            NOT NULL CONSTRAINT DF_ExchangeRate_IsCarriedForward DEFAULT (0),
    CONSTRAINT PK_ExchangeRate PRIMARY KEY (CurrencyCode, RateDate),
    CONSTRAINT FK_ExchangeRate_Currency FOREIGN KEY (CurrencyCode) REFERENCES core.Currency (CurrencyCode),
    CONSTRAINT CK_ExchangeRate_RateToUSD CHECK (RateToUSD > 0)
);

/* ========================= Customers ========================= */
CREATE TABLE core.Account
(
    AccountID  INT IDENTITY(1,1) NOT NULL,
    Email      NVARCHAR(256)     NOT NULL,
    CountryID  INT               NOT NULL,
    SignupDate DATE              NOT NULL,    -- may be before the data window (existing members)
    CONSTRAINT PK_Account PRIMARY KEY (AccountID),
    CONSTRAINT UQ_Account_Email UNIQUE (Email),
    CONSTRAINT FK_Account_Country FOREIGN KEY (CountryID) REFERENCES core.Country (CountryID)
);
CREATE INDEX IX_Account_CountryID ON core.Account (CountryID);

CREATE TABLE core.MaturityRating
(
    MaturityRatingID INT IDENTITY(1,1) NOT NULL,
    RatingCode       VARCHAR(10)       NOT NULL,   -- TV-Y, TV-PG, PG-13, TV-MA, NR ...
    MinAge           TINYINT           NOT NULL,   -- 0 / 7 / 13 / 16 / 18
    [Description]    NVARCHAR(200)     NOT NULL,
    CONSTRAINT PK_MaturityRating PRIMARY KEY (MaturityRatingID),
    CONSTRAINT UQ_MaturityRating_RatingCode UNIQUE (RatingCode),
    CONSTRAINT CK_MaturityRating_MinAge CHECK (MinAge <= 18)
);

CREATE TABLE core.Profile
(
    ProfileID           INT IDENTITY(1,1) NOT NULL,
    AccountID           INT               NOT NULL,
    ProfileName         NVARCHAR(50)      NOT NULL,
    IsKids              BIT               NOT NULL CONSTRAINT DF_Profile_IsKids DEFAULT (0),
    MaxMaturityRatingID INT               NOT NULL,   -- highest rating this profile may watch
    LanguageCode        VARCHAR(10)       NOT NULL,   -- e.g. en, bg, pt-BR
    CreatedAtUtc        DATETIME2(0)      NOT NULL,
    CONSTRAINT PK_Profile PRIMARY KEY (ProfileID),
    CONSTRAINT UQ_Profile_AccountID_ProfileName UNIQUE (AccountID, ProfileName),
    CONSTRAINT FK_Profile_Account FOREIGN KEY (AccountID) REFERENCES core.Account (AccountID),
    CONSTRAINT FK_Profile_MaturityRating FOREIGN KEY (MaxMaturityRatingID) REFERENCES core.MaturityRating (MaturityRatingID)
);
CREATE INDEX IX_Profile_MaxMaturityRatingID ON core.Profile (MaxMaturityRatingID);

CREATE TABLE core.Device
(
    DeviceID     INT IDENTITY(1,1) NOT NULL,
    DeviceGuid   UNIQUEIDENTIFIER  NOT NULL,
    AccountID    INT               NOT NULL,
    DeviceType   VARCHAR(20)       NOT NULL,
    [Platform]   VARCHAR(30)       NOT NULL,   -- Android, iOS, Tizen, webOS, PlayStation ...
    FirstSeenUtc DATETIME2(0)      NOT NULL,
    CONSTRAINT PK_Device PRIMARY KEY (DeviceID),
    CONSTRAINT UQ_Device_DeviceGuid UNIQUE (DeviceGuid),
    CONSTRAINT FK_Device_Account FOREIGN KEY (AccountID) REFERENCES core.Account (AccountID),
    CONSTRAINT CK_Device_DeviceType CHECK (DeviceType IN ('Smart TV', 'Mobile', 'Tablet', 'Web', 'Console', 'Streaming Stick'))
);
CREATE INDEX IX_Device_AccountID ON core.Device (AccountID);

/* ========================= Billing ========================= */
CREATE TABLE core.[Plan]
(
    PlanID          INT IDENTITY(1,1) NOT NULL,
    PlanName        NVARCHAR(50)      NOT NULL,
    MaxStreams      TINYINT           NOT NULL,
    MaxResolution   VARCHAR(10)       NOT NULL,
    HasAds          BIT               NOT NULL,
    DownloadDevices TINYINT           NOT NULL,
    CONSTRAINT PK_Plan PRIMARY KEY (PlanID),
    CONSTRAINT UQ_Plan_PlanName UNIQUE (PlanName),
    CONSTRAINT CK_Plan_MaxStreams CHECK (MaxStreams >= 1),
    CONSTRAINT CK_Plan_MaxResolution CHECK (MaxResolution IN ('480p', '720p', '1080p', '4K'))
);

CREATE TABLE core.PlanPrice
(
    PlanPriceID  INT IDENTITY(1,1) NOT NULL,
    PlanID       INT               NOT NULL,
    CountryID    INT               NOT NULL,
    CurrencyCode CHAR(3)           NOT NULL,   -- on the price row: a country's currency can change (BG -> EUR, 2026)
    MonthlyPrice DECIMAL(10,2)     NOT NULL,
    ValidFrom    DATE              NOT NULL,
    ValidTo      DATE              NULL,       -- exclusive; NULL = current price
    CONSTRAINT PK_PlanPrice PRIMARY KEY (PlanPriceID),
    CONSTRAINT UQ_PlanPrice_PlanID_CountryID_ValidFrom UNIQUE (PlanID, CountryID, ValidFrom),
    CONSTRAINT FK_PlanPrice_Plan FOREIGN KEY (PlanID) REFERENCES core.[Plan] (PlanID),
    CONSTRAINT FK_PlanPrice_Country FOREIGN KEY (CountryID) REFERENCES core.Country (CountryID),
    CONSTRAINT FK_PlanPrice_Currency FOREIGN KEY (CurrencyCode) REFERENCES core.Currency (CurrencyCode),
    CONSTRAINT CK_PlanPrice_MonthlyPrice CHECK (MonthlyPrice >= 0),
    CONSTRAINT CK_PlanPrice_ValidRange CHECK (ValidTo IS NULL OR ValidTo > ValidFrom)
);
CREATE INDEX IX_PlanPrice_CountryID ON core.PlanPrice (CountryID);
CREATE INDEX IX_PlanPrice_CurrencyCode ON core.PlanPrice (CurrencyCode);

CREATE TABLE core.Subscription
(
    SubscriptionID     INT IDENTITY(1,1) NOT NULL,
    AccountID          INT               NOT NULL,
    PlanID             INT               NOT NULL,
    StartDate          DATE              NOT NULL,
    EndDate            DATE              NULL,      -- exclusive; NULL = active
    EndReason          VARCHAR(20)       NULL,
    CancellationReason NVARCHAR(100)     NULL,
    CONSTRAINT PK_Subscription PRIMARY KEY (SubscriptionID),
    CONSTRAINT UQ_Subscription_AccountID_StartDate UNIQUE (AccountID, StartDate),
    CONSTRAINT FK_Subscription_Account FOREIGN KEY (AccountID) REFERENCES core.Account (AccountID),
    CONSTRAINT FK_Subscription_Plan FOREIGN KEY (PlanID) REFERENCES core.[Plan] (PlanID),
    CONSTRAINT CK_Subscription_DateRange CHECK (EndDate IS NULL OR EndDate > StartDate),
    CONSTRAINT CK_Subscription_EndReason CHECK (EndReason IN ('PlanChange', 'Cancelled', 'PaymentFailed')),
    CONSTRAINT CK_Subscription_EndConsistency CHECK ((EndDate IS NULL AND EndReason IS NULL) OR (EndDate IS NOT NULL AND EndReason IS NOT NULL)),
    CONSTRAINT CK_Subscription_CancellationReason CHECK (CancellationReason IS NULL OR (EndReason IS NOT NULL AND EndReason = 'Cancelled'))   -- rule 8 (NULL-safe)
);
CREATE INDEX IX_Subscription_PlanID ON core.Subscription (PlanID);
-- Rule 2 (part): at most one open subscription per account. Overlaps of closed periods -> trigger.
CREATE UNIQUE INDEX UX_Subscription_OpenPerAccount ON core.Subscription (AccountID) WHERE EndDate IS NULL;

CREATE TABLE core.Payment
(
    PaymentID          INT IDENTITY(1,1) NOT NULL,
    TransactionRef     VARCHAR(40)       NOT NULL,   -- payment provider reference
    SubscriptionID     INT               NOT NULL,
    BillingPeriodStart DATE              NOT NULL,
    Amount             DECIMAL(10,2)     NOT NULL,   -- local currency (historical fact, not looked up)
    CurrencyCode       CHAR(3)           NOT NULL,
    AttemptedAtUtc     DATETIME2(0)      NOT NULL,
    [Status]           VARCHAR(10)       NOT NULL,
    PaymentMethod      VARCHAR(20)       NOT NULL,
    CONSTRAINT PK_Payment PRIMARY KEY (PaymentID),
    CONSTRAINT UQ_Payment_TransactionRef UNIQUE (TransactionRef),
    CONSTRAINT FK_Payment_Subscription FOREIGN KEY (SubscriptionID) REFERENCES core.Subscription (SubscriptionID),
    CONSTRAINT FK_Payment_Currency FOREIGN KEY (CurrencyCode) REFERENCES core.Currency (CurrencyCode),
    CONSTRAINT CK_Payment_Amount CHECK (Amount >= 0),
    CONSTRAINT CK_Payment_Status CHECK ([Status] IN ('Succeeded', 'Failed', 'Refunded')),
    CONSTRAINT CK_Payment_PaymentMethod CHECK (PaymentMethod IN ('Card', 'PayPal', 'Gift Card', 'Partner Billing'))
);
CREATE INDEX IX_Payment_SubscriptionID ON core.Payment (SubscriptionID);
CREATE INDEX IX_Payment_CurrencyCode ON core.Payment (CurrencyCode);

/* ========================= Catalog ========================= */
CREATE TABLE core.Title
(
    TitleID          INT IDENTITY(1,1) NOT NULL,
    SourceKey        VARCHAR(40)       NOT NULL,   -- external id, e.g. tmdb:tv:93405
    TitleType        VARCHAR(10)       NOT NULL,
    TitleName        NVARCHAR(300)     NOT NULL,
    ReleaseYear      SMALLINT          NULL,
    DateAdded        DATE              NOT NULL,   -- date it became available on Netflix
    MaturityRatingID INT               NOT NULL,
    RuntimeMinutes   SMALLINT          NULL,       -- movies only
    IsOriginal       BIT               NOT NULL,
    OriginalLanguage VARCHAR(10)       NOT NULL,
    [Description]    NVARCHAR(1000)    NULL,
    CONSTRAINT PK_Title PRIMARY KEY (TitleID),
    CONSTRAINT UQ_Title_SourceKey UNIQUE (SourceKey),
    CONSTRAINT FK_Title_MaturityRating FOREIGN KEY (MaturityRatingID) REFERENCES core.MaturityRating (MaturityRatingID),
    CONSTRAINT CK_Title_TitleType CHECK (TitleType IN ('Movie', 'Series')),
    CONSTRAINT CK_Title_ReleaseYear CHECK (ReleaseYear BETWEEN 1900 AND 2100),
    CONSTRAINT CK_Title_Runtime CHECK ((TitleType = 'Movie' AND RuntimeMinutes IS NOT NULL AND RuntimeMinutes > 0) OR (TitleType = 'Series' AND RuntimeMinutes IS NULL))   -- rule 5 (NULL-safe)
);
CREATE INDEX IX_Title_MaturityRatingID ON core.Title (MaturityRatingID);

CREATE TABLE core.Season
(
    SeasonID     INT IDENTITY(1,1) NOT NULL,
    TitleID      INT               NOT NULL,
    SeasonNumber SMALLINT          NOT NULL,
    ReleaseDate  DATE              NOT NULL,
    CONSTRAINT PK_Season PRIMARY KEY (SeasonID),
    CONSTRAINT UQ_Season_TitleID_SeasonNumber UNIQUE (TitleID, SeasonNumber),
    CONSTRAINT FK_Season_Title FOREIGN KEY (TitleID) REFERENCES core.Title (TitleID),
    CONSTRAINT CK_Season_SeasonNumber CHECK (SeasonNumber >= 1)
);

CREATE TABLE core.Episode
(
    EpisodeID      INT IDENTITY(1,1) NOT NULL,
    SeasonID       INT               NOT NULL,
    EpisodeNumber  SMALLINT          NOT NULL,
    EpisodeName    NVARCHAR(300)     NOT NULL,
    RuntimeMinutes SMALLINT          NOT NULL,
    CONSTRAINT PK_Episode PRIMARY KEY (EpisodeID),
    CONSTRAINT UQ_Episode_SeasonID_EpisodeNumber UNIQUE (SeasonID, EpisodeNumber),
    CONSTRAINT FK_Episode_Season FOREIGN KEY (SeasonID) REFERENCES core.Season (SeasonID),
    CONSTRAINT CK_Episode_EpisodeNumber CHECK (EpisodeNumber >= 1),
    CONSTRAINT CK_Episode_RuntimeMinutes CHECK (RuntimeMinutes > 0)
);

CREATE TABLE core.Genre
(
    GenreID   INT IDENTITY(1,1) NOT NULL,
    GenreName NVARCHAR(50)      NOT NULL,
    CONSTRAINT PK_Genre PRIMARY KEY (GenreID),
    CONSTRAINT UQ_Genre_GenreName UNIQUE (GenreName)
);

CREATE TABLE core.TitleGenre
(
    TitleID INT NOT NULL,
    GenreID INT NOT NULL,
    CONSTRAINT PK_TitleGenre PRIMARY KEY (TitleID, GenreID),
    CONSTRAINT FK_TitleGenre_Title FOREIGN KEY (TitleID) REFERENCES core.Title (TitleID),
    CONSTRAINT FK_TitleGenre_Genre FOREIGN KEY (GenreID) REFERENCES core.Genre (GenreID)
);
CREATE INDEX IX_TitleGenre_GenreID ON core.TitleGenre (GenreID);

CREATE TABLE core.Person
(
    PersonID  INT IDENTITY(1,1) NOT NULL,
    SourceKey VARCHAR(40)       NOT NULL,   -- external id, e.g. tmdb:person:1245
    FullName  NVARCHAR(200)     NOT NULL,
    CONSTRAINT PK_Person PRIMARY KEY (PersonID),
    CONSTRAINT UQ_Person_SourceKey UNIQUE (SourceKey)
);

CREATE TABLE core.TitleCredit
(
    TitleID      INT         NOT NULL,
    PersonID     INT         NOT NULL,
    [Role]       VARCHAR(20) NOT NULL,      -- one credited role per person per title
    BillingOrder SMALLINT    NULL,          -- cast order; NULL for crew
    CONSTRAINT PK_TitleCredit PRIMARY KEY (TitleID, PersonID),
    CONSTRAINT FK_TitleCredit_Title FOREIGN KEY (TitleID) REFERENCES core.Title (TitleID),
    CONSTRAINT FK_TitleCredit_Person FOREIGN KEY (PersonID) REFERENCES core.Person (PersonID),
    CONSTRAINT CK_TitleCredit_Role CHECK ([Role] IN ('Actor', 'Director', 'Writer', 'Creator'))
);
CREATE INDEX IX_TitleCredit_PersonID ON core.TitleCredit (PersonID);

/* ========================= Activity ========================= */
CREATE TABLE core.WatchSession
(
    WatchSessionID INT IDENTITY(1,1) NOT NULL,
    SessionGuid    UNIQUEIDENTIFIER  NOT NULL,
    ProfileID      INT               NOT NULL,
    DeviceID       INT               NOT NULL,
    TitleID        INT               NOT NULL,
    EpisodeID      INT               NULL,      -- required for series, NULL for movies (trigger)
    StartedAtUtc   DATETIME2(0)      NOT NULL,
    StartedAtLocal DATETIME2(0)      NOT NULL,  -- viewer's local time (for hour-of-day analysis)
    WatchedSeconds INT               NOT NULL,
    ProgressPct    DECIMAL(5,2)      NOT NULL,  -- position reached in the movie/episode
    CONSTRAINT PK_WatchSession PRIMARY KEY (WatchSessionID),
    CONSTRAINT UQ_WatchSession_SessionGuid UNIQUE (SessionGuid),
    CONSTRAINT FK_WatchSession_Profile FOREIGN KEY (ProfileID) REFERENCES core.Profile (ProfileID),
    CONSTRAINT FK_WatchSession_Device FOREIGN KEY (DeviceID) REFERENCES core.Device (DeviceID),
    CONSTRAINT FK_WatchSession_Title FOREIGN KEY (TitleID) REFERENCES core.Title (TitleID),
    CONSTRAINT FK_WatchSession_Episode FOREIGN KEY (EpisodeID) REFERENCES core.Episode (EpisodeID),
    CONSTRAINT CK_WatchSession_WatchedSeconds CHECK (WatchedSeconds > 0),
    CONSTRAINT CK_WatchSession_ProgressPct CHECK (ProgressPct BETWEEN 0 AND 100)
);
CREATE INDEX IX_WatchSession_ProfileID ON core.WatchSession (ProfileID);
CREATE INDEX IX_WatchSession_DeviceID ON core.WatchSession (DeviceID);
CREATE INDEX IX_WatchSession_TitleID ON core.WatchSession (TitleID);
CREATE INDEX IX_WatchSession_EpisodeID ON core.WatchSession (EpisodeID);
CREATE INDEX IX_WatchSession_StartedAtUtc ON core.WatchSession (StartedAtUtc);

CREATE TABLE core.Rating
(
    ProfileID   INT          NOT NULL,
    TitleID     INT          NOT NULL,
    RatingValue SMALLINT     NOT NULL,      -- -1 thumbs down, 1 thumbs up, 2 love this
    RatedAtUtc  DATETIME2(0) NOT NULL,
    CONSTRAINT PK_Rating PRIMARY KEY (ProfileID, TitleID),
    CONSTRAINT FK_Rating_Profile FOREIGN KEY (ProfileID) REFERENCES core.Profile (ProfileID),
    CONSTRAINT FK_Rating_Title FOREIGN KEY (TitleID) REFERENCES core.Title (TitleID),
    CONSTRAINT CK_Rating_RatingValue CHECK (RatingValue IN (-1, 1, 2))
);
CREATE INDEX IX_Rating_TitleID ON core.Rating (TitleID);
GO
