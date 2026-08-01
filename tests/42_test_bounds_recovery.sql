/*
sp_HeapDoctor Test Harness - bounded discovery (#200) and dead-worker recovery (#201)

Tests:
  42A - Discovery scans in batches with a time check between them
  42B - A truncated scan reports that the target list is a subset
  42C - Truncation reaches the verdict, including the zero-target path
  42D - Dead-worker liveness pairs SessionID with ClaimLoginTime
  42E - A row stranded by a dead worker is reclaimed on the next run
  42V - Version matches dbo.ExpectedVersion

42E is the behavioural one. The rest are the structural regression net for code
whose live path needs either a very large database or a killed session.

Prerequisite: 01_setup_test_data.sql (and dbo.Queue for 42E)
*/

SET NOCOUNT ON;
/* The filtered index on dbo.QueueHeapRebuild requires these for any UPDATE. */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 42: bounded discovery (#200), dead-worker recovery (#201) ===', 10, 1) WITH NOWAIT;
RAISERROR(N'', 10, 1) WITH NOWAIT;
GO

/*#region 42-DEFINITION*/
IF OBJECT_ID('tempdb..#Def42') IS NOT NULL DROP TABLE #Def42;
CREATE TABLE #Def42 (definition nvarchar(max) NULL);

INSERT INTO #Def42 (definition)
SELECT definition FROM master.sys.sql_modules WHERE object_id = OBJECT_ID(N'master.dbo.sp_HeapDoctor');

IF NOT EXISTS (SELECT 1 FROM #Def42)
    INSERT INTO #Def42 (definition)
    SELECT definition FROM sys.sql_modules WHERE object_id = OBJECT_ID(N'dbo.sp_HeapDoctor');
GO
/*#endregion*/

/*#region 42A-CHUNKED-SCAN*/
------------------------------------------------------------------------
-- 42A: @MaxRunSeconds was checked only BETWEEN databases and BETWEEN targets,
-- never inside either -- so one large database could not be interrupted, and in
-- single-database mode there is no between-database boundary at all.
------------------------------------------------------------------------
RAISERROR(N'Test 42A: discovery scans in batches with a time check (#200)...', 10, 1) WITH NOWAIT;

IF EXISTS (SELECT 1 FROM #Def42
           WHERE definition LIKE N'%@scan_batch%'
             AND definition LIKE N'%#ScanBatch%'
             AND definition LIKE N'%DATEDIFF(SECOND, @RunStart_param, SYSDATETIME()) >= @MaxRunSeconds_param%')
    RAISERROR(N'  PASS 42A: the scan is batched and checks elapsed time between batches.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 42A: discovery is a single unbounded statement; @MaxRunSeconds cannot interrupt it.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 42B-TRUNCATION-REPORTED*/
RAISERROR(N'Test 42B: a truncated scan says the results are a subset (#200)...', 10, 1) WITH NOWAIT;

IF EXISTS (SELECT 1 FROM #Def42
           WHERE definition LIKE N'%SCAN TRUNCATED%'
             AND definition LIKE N'%not yet scanned in this database%'
             AND definition LIKE N'%@ScanTruncated_param%')
    RAISERROR(N'  PASS 42B: truncation is reported and flagged back to the caller.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 42B: a truncated scan returns a short list without saying so.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 42C-TRUNCATION-IN-VERDICT*/
------------------------------------------------------------------------
-- 42C: the zero-target path matters most here. A truncated scan that happens to
-- find nothing took the early exit, which reported SUCCESS -- "no targets" read
-- as healthy when the scan had not finished looking. Caught in testing.
------------------------------------------------------------------------
RAISERROR(N'Test 42C: truncation reaches the verdict on both paths (#200/#203)...', 10, 1) WITH NOWAIT;

DECLARE @trunc_hits integer = 0;
SELECT @trunc_hits = (LEN(definition) - LEN(REPLACE(definition, N'@scans_truncated > 0', N''))) / LEN(N'@scans_truncated > 0')
FROM #Def42;

IF @trunc_hits >= 3
BEGIN
    DECLARE @m42c nvarchar(200) = N'  PASS 42C: truncation is tested in the verdict in ' + CONVERT(nvarchar(10), @trunc_hits) + N' places (normal and zero-target).';
    RAISERROR(@m42c, 10, 1) WITH NOWAIT;
END
ELSE
BEGIN
    DECLARE @m42c_f nvarchar(300) = N'  FAIL 42C: @scans_truncated appears in only ' + CONVERT(nvarchar(10), @trunc_hits)
        + N' verdict test(s); the zero-target path can still report SUCCESS after a truncated scan.';
    RAISERROR(@m42c_f, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 42D-LIVENESS-PAIRS-LOGINTIME*/
------------------------------------------------------------------------
-- 42D: session_id alone is not a liveness test. SPIDs are reused, so a live
-- unrelated session would make a genuinely dead claim look alive. login_time
-- pins the claim to one specific session -- which is why Phase A recorded it.
------------------------------------------------------------------------
RAISERROR(N'Test 42D: dead-worker liveness pairs SessionID with ClaimLoginTime (#201)...', 10, 1) WITH NOWAIT;

IF EXISTS (SELECT 1 FROM #Def42
           WHERE definition LIKE N'%dm_exec_sessions%des.session_id = qhr.SessionID%'
             AND definition LIKE N'%des.login_time = qhr.ClaimLoginTime%')
    RAISERROR(N'  PASS 42D: reclaim requires both session_id and login_time to be absent.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 42D: liveness does not pair session_id with login_time; SPID reuse can hide a dead worker.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 42E-RECLAIM-BEHAVIOUR*/
------------------------------------------------------------------------
-- 42E: the behavioural proof.
--
-- A worker killed mid-rebuild leaves TableStartTime set and TableEndTime NULL.
-- READPAST skips locked rows and nothing examined claimed-but-unfinished ones,
-- so the row was never picked up again by any worker on any later run -- while
-- the run still reported success.
--
-- The dead worker is simulated rather than killed: the row is stamped with a
-- session_id and login_time that cannot match any live session. That is exactly
-- what the liveness test looks at, and it needs no second session.
------------------------------------------------------------------------
RAISERROR(N'Test 42E: a row stranded by a dead worker is reclaimed (#201)...', 10, 1) WITH NOWAIT;

IF OBJECT_ID(N'dbo.Queue') IS NULL
    RAISERROR(N'  SKIP 42E: dbo.Queue is absent, so parallel mode cannot run here.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    EXEC dbo.sp_HeapDoctor
        @Databases = N'HeapDoctorTest', @CpuSource = N'NONE',
        @PlanOnly = 0, @HeapsInParallel = N'Y';

    /* Strand one row: claimed by a session that does not exist. */
    UPDATE TOP (1) qhr
    SET qhr.TableStartTime = SYSDATETIME(),
        qhr.TableEndTime   = NULL,
        qhr.Status         = NULL,
        qhr.SessionID      = 31000,
        qhr.ClaimLoginTime = '1999-01-01T00:00:00'
    FROM dbo.QueueHeapRebuild AS qhr;

    DECLARE @before42 integer = (SELECT COUNT_BIG(*) FROM dbo.QueueHeapRebuild
                                 WHERE TableStartTime IS NOT NULL AND TableEndTime IS NULL);

    EXEC dbo.sp_HeapDoctor
        @Databases = N'HeapDoctorTest', @CpuSource = N'NONE',
        @PlanOnly = 0, @HeapsInParallel = N'Y';

    DECLARE @after42 integer = (SELECT COUNT_BIG(*) FROM dbo.QueueHeapRebuild
                                WHERE TableStartTime IS NOT NULL AND TableEndTime IS NULL);

    IF @before42 >= 1 AND @after42 = 0
    BEGIN
        DECLARE @m42e nvarchar(300) = N'  PASS 42E: ' + CONVERT(nvarchar(10), @before42)
            + N' stranded row(s) before the re-run, ' + CONVERT(nvarchar(10), @after42) + N' after.';
        RAISERROR(@m42e, 10, 1) WITH NOWAIT;
    END
    ELSE IF @before42 = 0
        RAISERROR(N'  FAIL 42E: could not strand a row, so the reclaim path was never exercised.', 10, 1) WITH NOWAIT;
    ELSE
    BEGIN
        DECLARE @m42e_f nvarchar(300) = N'  FAIL 42E: ' + CONVERT(nvarchar(10), @after42)
            + N' row(s) still stranded after the re-run; a dead worker''s row is not being reclaimed.';
        RAISERROR(@m42e_f, 10, 1) WITH NOWAIT;
    END
END
GO
/*#endregion*/

/*#region 42V-VERSION*/
RAISERROR(N'Test 42V: Version check...', 10, 1) WITH NOWAIT;

IF OBJECT_ID('tempdb..#R42v') IS NOT NULL DROP TABLE #R42v;
SELECT * INTO #R42v FROM dbo.ResultsTemplate WHERE 1 = 0;

/* @IncludeHealthyHeaps so this does not depend on 42E leaving forwarded records
   behind. 42E rebuilds every heap, so a plain plan-only run returns no rows here
   and the version comes back NULL -- a test failing for a reason unrelated to
   what it checks. */
INSERT INTO #R42v
EXEC dbo.sp_HeapDoctor
    @Databases           = N'HeapDoctorTest',
    @CpuSource           = N'NONE',
    @PlanOnly            = 1,
    @IncludeHealthyHeaps = 1,
    @MinPages            = 0;

DECLARE @ver42 nvarchar(20);
SELECT TOP (1) @ver42 = version FROM #R42v;

IF @ver42 = (SELECT version FROM dbo.ExpectedVersion)
    RAISERROR(N'  PASS 42V: Version matches dbo.ExpectedVersion (%s).', 10, 1, @ver42) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 42V: Version is %s and does not match dbo.ExpectedVersion.', 10, 1, @ver42) WITH NOWAIT;

IF OBJECT_ID('tempdb..#R42v') IS NOT NULL DROP TABLE #R42v;
IF OBJECT_ID('tempdb..#Def42') IS NOT NULL DROP TABLE #Def42;
GO
/*#endregion*/

/*#region 42-SUMMARY*/
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 42 tests complete. Review results above. ===', 10, 1) WITH NOWAIT;
GO
/*#endregion*/
