/* #222: a skipped parallel target receives a terminal queue status. */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;
GO

IF OBJECT_ID(N'dbo.P2QueueSkipHeap', N'U') IS NOT NULL
    DROP TABLE dbo.P2QueueSkipHeap;

CREATE TABLE dbo.P2QueueSkipHeap
(
    ID integer NOT NULL,
    Payload varchar(4000) NOT NULL
);
;WITH N AS
(
    SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
)
INSERT dbo.P2QueueSkipHeap (ID, Payload)
SELECT TOP (100000) n, 'x' FROM N;
UPDATE dbo.P2QueueSkipHeap SET Payload = REPLICATE('X', 1500);
GO

CHECKPOINT;
DBCC SHRINKFILE (N'HeapDoctorTest_log', 1);
ALTER DATABASE HeapDoctorTest MODIFY FILE (NAME = N'HeapDoctorTest_log', FILEGROWTH = 0);
ALTER DATABASE HeapDoctorTest SET RECOVERY FULL;
GO

SELECT * INTO #Results FROM dbo.ResultsTemplate WHERE 1 = 0;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.P2QueueSkipHeap',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @LogToTable = N'N',
    @IncludeHealthyHeaps = 1,
    @MinPages = 1,
    @MinForwardedPct = 0;
DECLARE @estimated_log_mb decimal(18,2), @free_log_mb decimal(18,2);
SELECT @estimated_log_mb = MAX(est_log_mb) FROM #Results WHERE table_name = N'P2QueueSkipHeap';
SELECT @free_log_mb = SUM(CONVERT(decimal(18,2), size) * 8.0 / 1024.0
                         - CONVERT(decimal(18,2), FILEPROPERTY(name, N'SpaceUsed')) * 8.0 / 1024.0)
FROM sys.database_files WHERE type = 1;
IF EXISTS (SELECT 1 FROM #Results AS r JOIN dbo.ExpectedVersion AS e ON e.version = r.version WHERE r.table_name = N'P2QueueSkipHeap')
   AND @estimated_log_mb IS NOT NULL AND @estimated_log_mb > @free_log_mb
    RAISERROR(N'PASS 57A: the skip fixture is a version-matched target.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @precondition_failure nvarchar(300) = N'FAIL 57A: expected log=' + COALESCE(CONVERT(nvarchar(30), @estimated_log_mb), N'NULL')
        + N' MB, free log=' + COALESCE(CONVERT(nvarchar(30), @free_log_mb), N'NULL') + N' MB or version mismatch.';
    RAISERROR(N'%s', 10, 1, @precondition_failure) WITH NOWAIT;
END;
GO

DECLARE
    @skipped integer = NULL,
    @succeeded integer = NULL,
    @failed integer = NULL,
    @status varchar(10) = NULL;
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.P2QueueSkipHeap',
    @CpuSource = N'NONE',
    @PlanOnly = 0,
    @LogToTable = N'Y',
    @IncludeHealthyHeaps = 1,
    @MinPages = 1,
    @MinForwardedPct = 0,
    @HeapsInParallel = N'Y',
    @Succeeded = @succeeded OUTPUT,
    @Failed = @failed OUTPUT,
    @Skipped = @skipped OUTPUT,
    @Status = @status OUTPUT;

DECLARE @queue_status nvarchar(30), @queue_end datetime2(7), @queue_reason nvarchar(2000);
SELECT TOP (1)
    @queue_status = Status,
    @queue_end = TableEndTime,
    @queue_reason = ErrorMessage
FROM dbo.QueueHeapRebuild
WHERE DatabaseName = N'HeapDoctorTest'
  AND SchemaName = N'dbo'
  AND TableName = N'P2QueueSkipHeap'
ORDER BY QueueID DESC;
IF @skipped = 1 AND ISNULL(@succeeded, 0) = 0 AND ISNULL(@failed, 0) = 0
   AND @queue_status = N'SKIPPED' AND @queue_end IS NOT NULL
   AND @queue_reason LIKE N'%LOG_SPACE_INSUFFICIENT%'
    RAISERROR(N'PASS 57B: a skipped parallel target closes its queue row with the skip reason.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @failure nvarchar(400) = N'FAIL 57B: succeeded=' + COALESCE(CONVERT(nvarchar(12), @succeeded), N'NULL')
        + N' failed=' + COALESCE(CONVERT(nvarchar(12), @failed), N'NULL')
        + N' skipped=' + COALESCE(CONVERT(nvarchar(12), @skipped), N'NULL')
        + N' queue_status=' + COALESCE(@queue_status, N'NULL')
        + N' queue_end=' + COALESCE(CONVERT(nvarchar(30), @queue_end, 126), N'NULL')
        + N' queue_reason=' + COALESCE(@queue_reason, N'NULL') + N'.';
    RAISERROR(N'%s', 10, 1, @failure) WITH NOWAIT;
END;
GO

DROP TABLE dbo.P2QueueSkipHeap;
ALTER DATABASE HeapDoctorTest SET RECOVERY SIMPLE;
ALTER DATABASE HeapDoctorTest MODIFY FILE (NAME = N'HeapDoctorTest_log', FILEGROWTH = 100MB);
CHECKPOINT;
DBCC SHRINKFILE (N'HeapDoctorTest_log', 300);
GO
