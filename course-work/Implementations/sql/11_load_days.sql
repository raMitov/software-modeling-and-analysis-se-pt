/* =============================================================================
   11_load_days.sql
   Live-load demo for several days at once: loads every daily batch from
   @FromDay to @ToDay (2026-10-19 .. 2026-10-26) in date order into core,
   then refreshes the warehouse once. Then refresh the Power BI report.
   Days must be loaded in order (a day can refer to rows created the day before);
   days already loaded are skipped row by row, so overlapping ranges are safe.
   Set @DataRoot (as in 09) and the two dates before running.
   ============================================================================= */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE NetflixDB;
GO

DECLARE @DataRoot NVARCHAR(300) =
    N'C:\Users\chizm\Desktop\Uni_Projects\modeling fold 7 pro\software-modeling-and-analysis-se-pt\course-work\Implementations\data\batches';
DECLARE @FromDay DATE = '2026-10-20';
DECLARE @ToDay   DATE = '2026-10-24';

IF @ToDay < @FromDay
    THROW 50401, N'@ToDay must be on or after @FromDay.', 1;

DECLARE @Day DATE = @FromDay, @Folder NVARCHAR(400);

WHILE @Day <= @ToDay
BEGIN
    SET @Folder = @DataRoot + N'\daily\' + CONVERT(CHAR(10), @Day, 23);
    RAISERROR(N'Loading %s ...', 0, 1, @Folder) WITH NOWAIT;

    EXEC stg.usp_ImportBatch @Folder = @Folder;   -- files -> staging
    EXEC core.usp_LoadFromStaging;                -- staging -> core

    SET @Day = DATEADD(DAY, 1, @Day);
END;

EXEC dw.usp_LoadWarehouse;                        -- core -> warehouse, once for all days

SELECT MAX(d.[Date]) AS DataAsOf
FROM dw.FactViewing AS f
JOIN dw.DimDate     AS d ON d.DateKey = f.DateKey;
GO
