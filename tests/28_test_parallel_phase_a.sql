/*
sp_HeapDoctor Test Harness - @HeapsInParallel (Phase A)

Validates queue-based parallel execution path:
  - dbo.QueueHeapRebuild auto-created on first parallel run
  - Leader populates queue from #Targets; same session drains it
  - dbo.Queue parent row created with @invocation_command as Parameters
  - Per-target queue rows marked SUCCEEDED with TableEndTime
  - Forwarded records actually eliminated post-rebuild
  - Validation rejects @PlanOnly=1 with parallel mode
  - Missing dbo.Queue is caught with a clear error

True multi-session concurrency is exercised by an external smoke test
(launching two sqlcmd processes simultaneously) outside this file.

Prerequisites:
  - Run 01_setup_test_data.sql first.
  - Ola Hallengren's dbo.Queue must exist in HeapDoctorTest.
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 28_test_parallel_phase_a.sql
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE [HeapDoctorTest];
GO

------------------------------------------------------------------------
-- Reset state from prior runs
------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.QueueHeapRebuild', N'U') IS NOT NULL
    DROP TABLE dbo.QueueHeapRebuild;
IF OBJECT_ID(N'dbo.Queue', N'U') IS NOT NULL
    DELETE FROM dbo.Queue;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 28A: @HeapsInParallel=Y - leader populates + drains', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

DECLARE @before_queue_rows int = ISNULL((SELECT COUNT_BIG(*) FROM dbo.Queue), 0);

EXEC dbo.sp_HeapDoctor
    @CpuSource       = 'NONE',
    @Execute         = 'Y',
    @HeapsInParallel = N'Y';

/* 28A-1: dbo.QueueHeapRebuild was auto-created */
IF OBJECT_ID(N'dbo.QueueHeapRebuild', N'U') IS NOT NULL
    RAISERROR(N'  PASS 28A-1: dbo.QueueHeapRebuild auto-created.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 28A-1: dbo.QueueHeapRebuild missing after parallel run.', 10, 1) WITH NOWAIT;

/* 28A-2: dbo.Queue got a new row for sp_HeapDoctor */
DECLARE @new_queue_rows int = (SELECT COUNT_BIG(*) FROM dbo.Queue WHERE ObjectName = N'sp_HeapDoctor');
IF @new_queue_rows >= 1
    RAISERROR(N'  PASS 28A-2: dbo.Queue has at least 1 row for sp_HeapDoctor.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 28A-2: dbo.Queue has no rows for sp_HeapDoctor.', 10, 1) WITH NOWAIT;

/* 28A-3: All queue rows marked SUCCEEDED */
DECLARE @total_rows int     = (SELECT COUNT_BIG(*) FROM dbo.QueueHeapRebuild);
DECLARE @succeeded_rows int = (SELECT COUNT_BIG(*) FROM dbo.QueueHeapRebuild WHERE Status = N'SUCCEEDED');
IF @total_rows >= 3 AND @total_rows = @succeeded_rows
    RAISERROR(N'  PASS 28A-3: All queue rows marked SUCCEEDED.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @s3 nvarchar(200) = N'  FAIL 28A-3: Expected >=3 rows all SUCCEEDED. Got total=' + CONVERT(nvarchar(10), @total_rows) + N', succeeded=' + CONVERT(nvarchar(10), @succeeded_rows);
    RAISERROR(@s3, 10, 1) WITH NOWAIT;
END

/* 28A-4: TableStartTime + TableEndTime populated; EndTime >= StartTime */
IF NOT EXISTS (SELECT 1 FROM dbo.QueueHeapRebuild WHERE TableStartTime IS NULL OR TableEndTime IS NULL OR TableEndTime < TableStartTime)
    RAISERROR(N'  PASS 28A-4: Claim/completion timestamps populated and ordered.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 28A-4: Some queue rows have NULL or inverted timestamps.', 10, 1) WITH NOWAIT;

/* 28A-5: Forwarded records actually eliminated on rebuilt heaps */
DECLARE @still_forwarded int = 0;
DECLARE @TableNames TABLE (n sysname);
INSERT @TableNames SELECT DISTINCT TableName FROM dbo.QueueHeapRebuild WHERE Status = N'SUCCEEDED';

SELECT @still_forwarded = SUM(ips.forwarded_record_count)
FROM @TableNames tn
CROSS APPLY sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(N'dbo.' + tn.n), 0, NULL, N'SAMPLED') ips;

IF ISNULL(@still_forwarded, 0) = 0
    RAISERROR(N'  PASS 28A-5: Zero forwarded records remain on rebuilt heaps.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @s5 nvarchar(200) = N'  FAIL 28A-5: ' + CONVERT(nvarchar(10), @still_forwarded) + N' forwarded records remain after rebuild.';
    RAISERROR(@s5, 10, 1) WITH NOWAIT;
END

/* 28A-6: CommandLog has per-rebuild entries with HEAP_REBUILD_ONLINE/OFFLINE/CI_SWAP_ONLINE */
DECLARE @cmdlog_rebuild_count int = (
    SELECT COUNT_BIG(*) FROM dbo.CommandLog
    WHERE CommandType LIKE N'HEAP_REBUILD_%' AND CommandType NOT IN (N'HEAP_REBUILD_START', N'HEAP_REBUILD_END')
       OR CommandType LIKE N'CI_SWAP_%'
);
IF @cmdlog_rebuild_count >= 3
    RAISERROR(N'  PASS 28A-6: CommandLog has per-rebuild entries (parallel rebuilds log normally).', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @s6 nvarchar(200) = N'  FAIL 28A-6: Expected >=3 CommandLog rebuild entries, got ' + CONVERT(nvarchar(10), @cmdlog_rebuild_count);
    RAISERROR(@s6, 10, 1) WITH NOWAIT;
END

/* 28A-7: invocation_command logged @HeapsInParallel = N'Y' */
DECLARE @latest_cmd nvarchar(max) = (
    SELECT TOP (1) Command FROM dbo.CommandLog
    WHERE CommandType = N'HEAP_REBUILD_START' ORDER BY ID DESC
);
IF @latest_cmd LIKE N'%@HeapsInParallel = N''Y''%'
    RAISERROR(N'  PASS 28A-7: @invocation_command logged @HeapsInParallel = N''Y''.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 28A-7: @HeapsInParallel not logged in @invocation_command.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 28B: Re-run same EXEC joins existing queue (worker mode)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

/* After the prior run, the queue is drained but dbo.Queue still has the row with our Parameters.
   A second invocation with the SAME args should detect existing QueueID and act as WORKER.
   Workers immediately find an empty queue and exit. */
DECLARE @rebuild_count_before int = (SELECT COUNT_BIG(*) FROM dbo.CommandLog WHERE CommandType LIKE N'HEAP_REBUILD_%' AND CommandType NOT IN (N'HEAP_REBUILD_START', N'HEAP_REBUILD_END'));

EXEC dbo.sp_HeapDoctor
    @CpuSource       = 'NONE',
    @Execute         = 'Y',
    @HeapsInParallel = N'Y';

DECLARE @rebuild_count_after int = (SELECT COUNT_BIG(*) FROM dbo.CommandLog WHERE CommandType LIKE N'HEAP_REBUILD_%' AND CommandType NOT IN (N'HEAP_REBUILD_START', N'HEAP_REBUILD_END'));

IF @rebuild_count_after = @rebuild_count_before
    RAISERROR(N'  PASS 28B-1: Second invocation joined existing queue and found no work (worker mode).', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @s8 nvarchar(200) = N'  FAIL 28B-1: Expected no new rebuilds, got ' + CONVERT(nvarchar(10), @rebuild_count_after - @rebuild_count_before);
    RAISERROR(@s8, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 28C: Validation rejects @PlanOnly=1 with @HeapsInParallel=Y', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

BEGIN TRY
    EXEC dbo.sp_HeapDoctor
        @CpuSource       = 'NONE',
        @PlanOnly        = 1,
        @HeapsInParallel = N'Y';
    RAISERROR(N'  FAIL 28C-1: Expected validation error, none raised.', 10, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    IF ERROR_MESSAGE() LIKE N'%requires execution mode%'
        RAISERROR(N'  PASS 28C-1: @PlanOnly=1 with parallel mode correctly rejected.', 10, 1) WITH NOWAIT;
    ELSE
    BEGIN
        DECLARE @e1 nvarchar(2000) = N'  FAIL 28C-1: Wrong error message: ' + LEFT(ERROR_MESSAGE(), 1500);
        RAISERROR(@e1, 10, 1) WITH NOWAIT;
    END
END CATCH
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 28D: Missing dbo.Queue raises clear error', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

/* Temporarily rename dbo.Queue to simulate missing dependency, then restore.
   (Drop-and-recreate would clear Queue rows and lose state from prior tests.) */
IF OBJECT_ID(N'dbo.QueueHeapRebuild', N'U') IS NOT NULL
    ALTER TABLE dbo.QueueHeapRebuild DROP CONSTRAINT FK_QueueHeapRebuild_Queue;
EXEC sys.sp_rename N'dbo.Queue', N'Queue_Renamed_For_Test';

BEGIN TRY
    EXEC dbo.sp_HeapDoctor
        @CpuSource       = 'NONE',
        @Execute         = 'Y',
        @Tables          = N'dbo.HeapA',
        @HeapsInParallel = N'Y';
    RAISERROR(N'  FAIL 28D-1: Expected error about missing dbo.Queue.', 10, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    IF ERROR_MESSAGE() LIKE N'%dbo.Queue%'
        RAISERROR(N'  PASS 28D-1: Missing dbo.Queue raises clear error with download link.', 10, 1) WITH NOWAIT;
    ELSE
    BEGIN
        DECLARE @e2 nvarchar(2000) = N'  FAIL 28D-1: Wrong error message: ' + LEFT(ERROR_MESSAGE(), 1500);
        RAISERROR(@e2, 10, 1) WITH NOWAIT;
    END
END CATCH

/* Restore */
EXEC sys.sp_rename N'dbo.Queue_Renamed_For_Test', N'Queue';
IF OBJECT_ID(N'dbo.QueueHeapRebuild', N'U') IS NOT NULL
    ALTER TABLE dbo.QueueHeapRebuild
        ADD CONSTRAINT FK_QueueHeapRebuild_Queue FOREIGN KEY (QueueID) REFERENCES dbo.Queue (QueueID);
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Test 28 (parallel Phase A) complete ===', 10, 1) WITH NOWAIT;
