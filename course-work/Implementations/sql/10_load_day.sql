/* =============================================================================
   10_load_day.sql
   Live-load demo: loads ONE daily batch (2026-10-19 .. 2026-10-26) end to end:
   CSV files -> stg -> core -> dw. Then refresh the Power BI report.
   Set @DataRoot (as in 09) and @Day before running.
   Running the same day twice is safe: nothing is loaded twice.
   ============================================================================= */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE NetflixDB;
GO

DECLARE @DataRoot NVARCHAR(300) =
    N'C:\Users\chizm\Desktop\Uni_Projects\modeling fold 7 pro\software-modeling-and-analysis-se-pt\course-work\Implementations\data\batches';
DECLARE @Day DATE = '2026-10-19';

DECLARE @Folder NVARCHAR(400) = @DataRoot + N'\daily\' + CONVERT(CHAR(10), @Day, 23);
RAISERROR(N'Loading %s ...', 0, 1, @Folder) WITH NOWAIT;

EXEC stg.usp_ImportBatch @Folder = @Folder;    -- 1. files -> staging   (rows staged per table)
EXEC core.usp_LoadFromStaging;                 -- 2. staging -> core     (rows inserted / updated)
EXEC dw.usp_LoadWarehouse;                     -- 3. core -> warehouse   (rows inserted / updated)

SELECT MAX(d.[Date]) AS DataAsOf
FROM dw.FactViewing AS f
JOIN dw.DimDate     AS d ON d.DateKey = f.DateKey;
GO
