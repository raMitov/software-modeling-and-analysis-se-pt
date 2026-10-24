/* 
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
