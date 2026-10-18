/* =============================================================================
   09_load_history.sql
   Loads the history: every monthly batch 2023-01 .. 2026-10 (up to 2026-10-18)
   into core, then builds the warehouse once.
   Set @DataRoot to the data\batches folder of your clone before running.
   Re-runnable: batches already loaded are skipped row by row (business keys).
   ============================================================================= */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE NetflixDB;
GO

DECLARE @DataRoot NVARCHAR(300) =
    N'C:\Users\chizm\Desktop\Uni_Projects\modeling fold 7 pro\software-modeling-and-analysis-se-pt\course-work\Implementations\data\batches';

DECLARE @Month DATE = '2023-01-01', @Folder NVARCHAR(400), @Started DATETIME2 = SYSDATETIME();

WHILE @Month <= '2026-10-01'
BEGIN
    SET @Folder = @DataRoot + N'\history\' + CONVERT(CHAR(7), @Month, 126);
    RAISERROR(N'Loading %s ...', 0, 1, @Folder) WITH NOWAIT;

    EXEC stg.usp_ImportBatch @Folder = @Folder;
    EXEC core.usp_LoadFromStaging;

    SET @Month = DATEADD(MONTH, 1, @Month);
END;

RAISERROR(N'Building the warehouse ...', 0, 1) WITH NOWAIT;
EXEC dw.usp_LoadWarehouse;

DECLARE @Seconds INT = DATEDIFF(SECOND, @Started, SYSDATETIME());
RAISERROR(N'History loaded in %d s.', 0, 1, @Seconds) WITH NOWAIT;
GO
