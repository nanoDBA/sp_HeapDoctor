SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;
GO

CREATE OR ALTER PROCEDURE dbo.DirtyHeapForQueueRerun AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE dbo.HeapA;
    INSERT dbo.HeapA WITH (TABLOCK) (ID, Padding)
        SELECT TOP (5000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 'x'
        FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b;
    UPDATE dbo.HeapA SET Padding = REPLICATE('X', 3000) WHERE ID % 2 = 0;
END;
GO

SELECT TOP (0) * INTO #Plan FROM dbo.ResultsTemplate;
INSERT #Plan
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.HeapA',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @LogToTable = N'N';
IF EXISTS (SELECT 1 FROM #Plan AS p JOIN dbo.ExpectedVersion AS e ON e.version = p.version
           WHERE p.table_name = N'HeapA')
    RAISERROR(N'PASS 59A: positive control captured a version-matched HeapA plan.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 59A: positive control did not capture a version-matched HeapA plan.', 10, 1) WITH NOWAIT;
DROP TABLE #Plan;
GO

CREATE TABLE #FirstRun
(
    BeforeForwarded bigint NULL,
    AfterForwarded bigint NULL,
    TargetsFound int NULL,
    Succeeded int NULL,
    Failed int NULL,
    Skipped int NULL
);
EXEC dbo.DirtyHeapForQueueRerun;
DECLARE @before1 bigint = (SELECT SUM(forwarded_record_count)
    FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(N'dbo.HeapA'), 0, NULL, 'DETAILED')),
    @found1 int = NULL, @succeeded1 int = NULL, @failed1 int = NULL, @skipped1 int = NULL;
DELETE FROM dbo.CommandLog;
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.HeapA',
    @CpuSource = N'NONE',
    @LogToTable = N'Y',
    @MinPages = 10,
    @MinForwardedPct = 0,
    @PlanOnly = 0,
    @HeapsInParallel = N'Y',
    @TargetsFound = @found1 OUTPUT,
    @Succeeded = @succeeded1 OUTPUT,
    @Failed = @failed1 OUTPUT,
    @Skipped = @skipped1 OUTPUT;
DECLARE @after1 bigint = (SELECT SUM(forwarded_record_count)
    FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(N'dbo.HeapA'), 0, NULL, 'DETAILED'));
INSERT #FirstRun VALUES (@before1, @after1, @found1, @succeeded1, @failed1, @skipped1);
GO

EXEC dbo.DirtyHeapForQueueRerun;
DECLARE @before2 bigint = (SELECT SUM(forwarded_record_count)
    FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(N'dbo.HeapA'), 0, NULL, 'DETAILED')),
    @found2 int = NULL, @succeeded2 int = NULL, @failed2 int = NULL, @skipped2 int = NULL;
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.HeapA',
    @CpuSource = N'NONE',
    @LogToTable = N'Y',
    @MinPages = 10,
    @MinForwardedPct = 0,
    @PlanOnly = 0,
    @HeapsInParallel = N'Y',
    @TargetsFound = @found2 OUTPUT,
    @Succeeded = @succeeded2 OUTPUT,
    @Failed = @failed2 OUTPUT,
    @Skipped = @skipped2 OUTPUT;
DECLARE @after2 bigint = (SELECT SUM(forwarded_record_count)
    FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(N'dbo.HeapA'), 0, NULL, 'DETAILED'));
IF NOT EXISTS (SELECT 1 FROM #FirstRun
               WHERE ISNULL(BeforeForwarded, 0) > 0 AND ISNULL(AfterForwarded, -1) = 0
                 AND ISNULL(TargetsFound, 0) > 0 AND ISNULL(Succeeded, 0) > 0
                 AND ISNULL(Failed, 0) = 0 AND ISNULL(Skipped, 0) = 0)
   OR ISNULL(@before2, 0) = 0
    RAISERROR(N'FAIL 59B: fixture forwarding controls were not established.', 10, 1) WITH NOWAIT;
ELSE IF ISNULL(@found2, 0) > 0 AND ISNULL(@succeeded2, 0) > 0
     AND ISNULL(@failed2, 0) = 0 AND ISNULL(@skipped2, 0) = 0 AND ISNULL(@after2, -1) = 0
    RAISERROR(N'PASS 59B: identical parallel rerun rediscovered and rebuilt the dirty heap.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @report nvarchar(500) = N'FAIL 59B: second run found='
        + COALESCE(CONVERT(nvarchar(10), @found2), N'NULL') + N' succeeded='
        + COALESCE(CONVERT(nvarchar(10), @succeeded2), N'NULL') + N' failed='
        + COALESCE(CONVERT(nvarchar(10), @failed2), N'NULL') + N' skipped='
        + COALESCE(CONVERT(nvarchar(10), @skipped2), N'NULL') + N' forwarded_before='
        + CONVERT(nvarchar(30), @before2) + N' forwarded_after=' + CONVERT(nvarchar(30), @after2) + N'.';
    RAISERROR(N'%s', 10, 1, @report) WITH NOWAIT;
END;
DROP PROCEDURE dbo.DirtyHeapForQueueRerun;
GO
