/* =============================================================================
   04_dw_tables.sql
   Data warehouse (dw) - fact constellation: 3 fact tables sharing dimensions.

     Fact          Grain (one row = ...)          Dimensions
     FactViewing   one watch session              Date, Account, Profile, Title, Plan, Device
     FactPayment   one payment attempt            Date, Account, Plan
     FactRating    one rating (profile x title)   Date, Account, Profile, Title
     Genre is many-to-many with Title -> DimGenre + BridgeTitleGenre.

   Conventions
     - Dimensions: surrogate key (xxxKey, IDENTITY) + core business key (xxxID, UNIQUE).
       Slowly changing type 1: attributes are overwritten when they change.
     - Facts: the core row ID is kept as a degenerate key and is the primary key,
       which makes incremental loads simple and every fact row traceable.
     - Filled by dw.usp_LoadWarehouse (07_procedures.sql); DimDate is static and filled here.
   Re-runnable: drops and recreates all dw tables (all dw data is lost).
   ============================================================================= */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE NetflixDB;
GO

DROP TABLE IF EXISTS dw.FactViewing, dw.FactPayment, dw.FactRating, dw.BridgeTitleGenre,
                     dw.DimDate, dw.DimAccount, dw.DimProfile, dw.DimTitle, dw.DimGenre,
                     dw.DimPlan, dw.DimDevice;
GO

/* ========================= Dimensions ========================= */
CREATE TABLE dw.DimDate
(
    DateKey         INT         NOT NULL,   -- YYYYMMDD
    [Date]          DATE        NOT NULL,
    [Year]          SMALLINT    NOT NULL,
    [Quarter]       TINYINT     NOT NULL,
    MonthNumber     TINYINT     NOT NULL,
    [MonthName]     VARCHAR(10) NOT NULL,
    YearMonth       CHAR(7)     NOT NULL,   -- 2024-03
    DayOfMonth      TINYINT     NOT NULL,
    DayOfWeekNumber TINYINT     NOT NULL,   -- ISO: 1 = Monday ... 7 = Sunday
    [DayName]       VARCHAR(10) NOT NULL,
    IsWeekend       BIT         NOT NULL,
    CONSTRAINT PK_DimDate PRIMARY KEY (DateKey),
    CONSTRAINT UQ_DimDate_Date UNIQUE ([Date])
);

CREATE TABLE dw.DimAccount
(
    AccountKey  INT IDENTITY(1,1) NOT NULL,
    AccountID   INT               NOT NULL,
    SignupDate  DATE              NOT NULL,
    SignupMonth CHAR(7)           NOT NULL,   -- cohort, e.g. 2023-05
    CountryISO  CHAR(2)           NOT NULL,
    CountryName NVARCHAR(100)     NOT NULL,
    RegionCode  VARCHAR(10)       NOT NULL,
    RegionName  NVARCHAR(50)      NOT NULL,
    CONSTRAINT PK_DimAccount PRIMARY KEY (AccountKey),
    CONSTRAINT UQ_DimAccount_AccountID UNIQUE (AccountID)
);

CREATE TABLE dw.DimProfile
(
    ProfileKey        INT IDENTITY(1,1) NOT NULL,
    ProfileID         INT               NOT NULL,
    ProfileName       NVARCHAR(50)      NOT NULL,
    ProfileType       VARCHAR(10)       NOT NULL,   -- Kids / Standard
    MaxMaturityRating VARCHAR(10)       NOT NULL,
    LanguageCode      VARCHAR(10)       NOT NULL,
    CONSTRAINT PK_DimProfile PRIMARY KEY (ProfileKey),
    CONSTRAINT UQ_DimProfile_ProfileID UNIQUE (ProfileID)
);

CREATE TABLE dw.DimTitle
(
    TitleKey         INT IDENTITY(1,1) NOT NULL,
    TitleID          INT               NOT NULL,
    TitleName        NVARCHAR(300)     NOT NULL,
    TitleType        VARCHAR(10)       NOT NULL,   -- Movie / Series
    ReleaseYear      SMALLINT          NULL,
    DateAdded        DATE              NOT NULL,
    ContentOrigin    VARCHAR(20)       NOT NULL,   -- Netflix Original / Licensed
    OriginalLanguage VARCHAR(10)       NOT NULL,
    MaturityRating   VARCHAR(10)       NOT NULL,
    MinAge           TINYINT           NOT NULL,
    Genres           NVARCHAR(400)     NULL,       -- display list, e.g. "Drama, Thriller"
    RuntimeMinutes   SMALLINT          NULL,       -- movies only
    CONSTRAINT PK_DimTitle PRIMARY KEY (TitleKey),
    CONSTRAINT UQ_DimTitle_TitleID UNIQUE (TitleID)
);

CREATE TABLE dw.DimGenre
(
    GenreKey  INT IDENTITY(1,1) NOT NULL,
    GenreID   INT               NOT NULL,
    GenreName NVARCHAR(50)      NOT NULL,
    CONSTRAINT PK_DimGenre PRIMARY KEY (GenreKey),
    CONSTRAINT UQ_DimGenre_GenreID UNIQUE (GenreID)
);

CREATE TABLE dw.BridgeTitleGenre
(
    TitleKey INT NOT NULL,
    GenreKey INT NOT NULL,
    CONSTRAINT PK_BridgeTitleGenre PRIMARY KEY (TitleKey, GenreKey),
    CONSTRAINT FK_BridgeTitleGenre_DimTitle FOREIGN KEY (TitleKey) REFERENCES dw.DimTitle (TitleKey),
    CONSTRAINT FK_BridgeTitleGenre_DimGenre FOREIGN KEY (GenreKey) REFERENCES dw.DimGenre (GenreKey)
);

CREATE TABLE dw.DimPlan
(
    PlanKey       INT IDENTITY(1,1) NOT NULL,
    PlanID        INT               NOT NULL,
    PlanName      NVARCHAR(50)      NOT NULL,
    MaxStreams    TINYINT           NOT NULL,
    MaxResolution VARCHAR(10)       NOT NULL,
    AdSupport     VARCHAR(10)       NOT NULL,   -- With ads / Ad-free
    CONSTRAINT PK_DimPlan PRIMARY KEY (PlanKey),
    CONSTRAINT UQ_DimPlan_PlanID UNIQUE (PlanID)
);

CREATE TABLE dw.DimDevice
(
    DeviceKey  INT IDENTITY(1,1) NOT NULL,
    DeviceID   INT               NOT NULL,
    DeviceType VARCHAR(20)       NOT NULL,
    [Platform] VARCHAR(30)       NOT NULL,
    CONSTRAINT PK_DimDevice PRIMARY KEY (DeviceKey),
    CONSTRAINT UQ_DimDevice_DeviceID UNIQUE (DeviceID)
);

/* ========================= Facts ========================= */
CREATE TABLE dw.FactViewing
(
    WatchSessionID        INT          NOT NULL,   -- degenerate key (core.WatchSession)
    DateKey               INT          NOT NULL,   -- local viewing date
    StartHourLocal        TINYINT      NOT NULL,   -- 0-23, viewer's local time
    AccountKey            INT          NOT NULL,
    ProfileKey            INT          NOT NULL,
    TitleKey              INT          NOT NULL,
    PlanKey               INT          NOT NULL,   -- plan active on the viewing date
    DeviceKey             INT          NOT NULL,
    SeasonNumber          SMALLINT     NULL,       -- series only
    EpisodeNumber         SMALLINT     NULL,       -- series only
    WatchedSeconds        INT          NOT NULL,
    ContentRuntimeMinutes SMALLINT     NOT NULL,   -- runtime of the movie / episode watched
    ProgressPct           DECIMAL(5,2) NOT NULL,
    IsCompleted           BIT          NOT NULL,   -- ProgressPct >= 90
    CONSTRAINT PK_FactViewing PRIMARY KEY (WatchSessionID),
    CONSTRAINT FK_FactViewing_DimDate    FOREIGN KEY (DateKey)    REFERENCES dw.DimDate (DateKey),
    CONSTRAINT FK_FactViewing_DimAccount FOREIGN KEY (AccountKey) REFERENCES dw.DimAccount (AccountKey),
    CONSTRAINT FK_FactViewing_DimProfile FOREIGN KEY (ProfileKey) REFERENCES dw.DimProfile (ProfileKey),
    CONSTRAINT FK_FactViewing_DimTitle   FOREIGN KEY (TitleKey)   REFERENCES dw.DimTitle (TitleKey),
    CONSTRAINT FK_FactViewing_DimPlan    FOREIGN KEY (PlanKey)    REFERENCES dw.DimPlan (PlanKey),
    CONSTRAINT FK_FactViewing_DimDevice  FOREIGN KEY (DeviceKey)  REFERENCES dw.DimDevice (DeviceKey)
);

CREATE TABLE dw.FactPayment
(
    PaymentID          INT           NOT NULL,   -- degenerate key (core.Payment)
    DateKey            INT           NOT NULL,   -- attempt date (UTC)
    AccountKey         INT           NOT NULL,
    PlanKey            INT           NOT NULL,
    BillingPeriodStart DATE          NOT NULL,
    CurrencyCode       CHAR(3)       NOT NULL,
    AmountLocal        DECIMAL(10,2) NOT NULL,
    AmountUSD          DECIMAL(12,2) NOT NULL,   -- converted on the attempt date
    PaymentStatus      VARCHAR(10)   NOT NULL,
    PaymentMethod      VARCHAR(20)   NOT NULL,
    CONSTRAINT PK_FactPayment PRIMARY KEY (PaymentID),
    CONSTRAINT FK_FactPayment_DimDate    FOREIGN KEY (DateKey)    REFERENCES dw.DimDate (DateKey),
    CONSTRAINT FK_FactPayment_DimAccount FOREIGN KEY (AccountKey) REFERENCES dw.DimAccount (AccountKey),
    CONSTRAINT FK_FactPayment_DimPlan    FOREIGN KEY (PlanKey)    REFERENCES dw.DimPlan (PlanKey)
);

CREATE TABLE dw.FactRating
(
    ProfileKey  INT      NOT NULL,
    TitleKey    INT      NOT NULL,
    DateKey     INT      NOT NULL,   -- rating date (UTC)
    AccountKey  INT      NOT NULL,
    RatingValue SMALLINT NOT NULL,   -- -1 / 1 / 2
    CONSTRAINT PK_FactRating PRIMARY KEY (ProfileKey, TitleKey),
    CONSTRAINT FK_FactRating_DimProfile FOREIGN KEY (ProfileKey) REFERENCES dw.DimProfile (ProfileKey),
    CONSTRAINT FK_FactRating_DimTitle   FOREIGN KEY (TitleKey)   REFERENCES dw.DimTitle (TitleKey),
    CONSTRAINT FK_FactRating_DimDate    FOREIGN KEY (DateKey)    REFERENCES dw.DimDate (DateKey),
    CONSTRAINT FK_FactRating_DimAccount FOREIGN KEY (AccountKey) REFERENCES dw.DimAccount (AccountKey)
);
GO

/* ========================= DimDate: static calendar 2023-01-01 .. 2026-12-31 =========================
   Language-independent: names via CHOOSE, ISO weekday from a known Monday (1900-01-01). */
DECLARE @From DATE = '2023-01-01', @To DATE = '2026-12-31';

WITH n AS
(
    SELECT TOP (DATEDIFF(DAY, @From, @To) + 1)
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
    FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
),
d AS
(
    SELECT DATEADD(DAY, i, @From) AS dt FROM n
)
INSERT INTO dw.DimDate (DateKey, [Date], [Year], [Quarter], MonthNumber, [MonthName], YearMonth,
                        DayOfMonth, DayOfWeekNumber, [DayName], IsWeekend)
SELECT CONVERT(INT, CONVERT(CHAR(8), d.dt, 112)),
       d.dt,
       YEAR(d.dt),
       DATEPART(QUARTER, d.dt),
       MONTH(d.dt),
       CHOOSE(MONTH(d.dt), 'January', 'February', 'March', 'April', 'May', 'June',
                           'July', 'August', 'September', 'October', 'November', 'December'),
       CONVERT(CHAR(7), d.dt, 126),
       DAY(d.dt),
       w.dow,
       CHOOSE(w.dow, 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'),
       CASE WHEN w.dow IN (6, 7) THEN 1 ELSE 0 END
FROM d
CROSS APPLY (SELECT DATEDIFF(DAY, '19000101', d.dt) % 7 + 1 AS dow) AS w;
GO
