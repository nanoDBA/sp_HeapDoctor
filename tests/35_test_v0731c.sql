/*
sp_HeapDoctor Test Harness - per-target disposition stream (#187)

Tests:
  35A - HEAP_TARGET_EVENT rows are written for a run
  35B - EXACTLY ONE terminal event per disposed target (the core invariant)
  35C - RunID and TargetId are present at the fixed path in EVERY event (no NULLs)
  35D - Skips persist as SKIPPED without any message parsing
  35E - Success persists as SUCCEEDED
  35F - The shredding query returns one row per event with no XPath by the caller
  35G - @LogToTable = N writes no events and does not error
  35H - HEAP_REBUILD_END is still written (remains the authoritative summary)

  -- Version --
  35V - Version matches dbo.ExpectedVersion

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -U sa -P YourPassword -d HeapDoctorTest -i 35_test_v0731c.sql
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE [HeapDoctorTest];
GO

RAISERROR(N'=== Batch 35: (#187 target disposition stream) ===', 10, 1) WITH NOWAIT;

/*#region 35A*/
RAISERROR(N'Test 35A: HEAP_TARGET_EVENT rows written (#187)...', 10, 1) WITH NOWAIT;

DELETE FROM dbo.CommandLog;

EXEC dbo.sp_HeapDoctor
    @Databases  = N'HeapDoctorTest',
    @CpuSource  = N'NONE',
    @PlanOnly   = 0,
    @LogToTable = N'Y';
GO

DECLARE @ev35 integer = (SELECT COUNT_BIG(*) FROM dbo.CommandLog WHERE CommandType = N'HEAP_TARGET_EVENT');
IF @ev35 >= 1
    RAISERROR(N'  PASS 35A: target disposition events written.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 35A: no HEAP_TARGET_EVENT rows found.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 35B*/
------------------------------------------------------------------------
-- 35B: the core invariant - exactly one TERMINAL event per disposed target.
-- Not "at least one": duplicates would corrupt any downstream aggregation.
------------------------------------------------------------------------
RAISERROR(N'Test 35B: exactly one terminal event per target (#187)...', 10, 1) WITH NOWAIT;

/* XML data type methods cannot appear in GROUP BY (Msg 4148), so shred first. */
IF OBJECT_ID('tempdb..#term35') IS NOT NULL DROP TABLE #term35;
SELECT ExtendedInfo.value('(/TargetEvent/TargetId)[1]','integer') AS tid
INTO #term35
FROM dbo.CommandLog
WHERE CommandType = N'HEAP_TARGET_EVENT'
  AND ExtendedInfo.value('(/TargetEvent/IsTerminalEvent)[1]','bit') = 1;

DECLARE @dupes35 integer =
(
    SELECT COUNT_BIG(*) FROM (
        SELECT tid FROM #term35 GROUP BY tid HAVING COUNT_BIG(*) <> 1
    ) AS d
);

IF @dupes35 = 0
    RAISERROR(N'  PASS 35B: every target has exactly one terminal event.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @m35b nvarchar(200) = N'  FAIL 35B: ' + CONVERT(nvarchar(10), @dupes35)
        + N' target(s) have a terminal-event count other than 1.';
    RAISERROR(@m35b, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 35C*/
------------------------------------------------------------------------
-- 35C: identity lives in XML, so the shape must be rigid. Every event row
-- must yield a non-NULL RunID and TargetId from the SAME path.
------------------------------------------------------------------------
RAISERROR(N'Test 35C: RunID + TargetId present in every event (#187)...', 10, 1) WITH NOWAIT;

DECLARE @nulls35 integer =
(
    SELECT COUNT_BIG(*)
    FROM dbo.CommandLog
    WHERE CommandType = N'HEAP_TARGET_EVENT'
      AND (ExtendedInfo.value('(/TargetEvent/RunID)[1]','uniqueidentifier') IS NULL
        OR ExtendedInfo.value('(/TargetEvent/TargetId)[1]','integer') IS NULL)
);

IF @nulls35 = 0
    RAISERROR(N'  PASS 35C: no event is missing RunID or TargetId.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @m35c nvarchar(200) = N'  FAIL 35C: ' + CONVERT(nvarchar(10), @nulls35)
        + N' event(s) lack RunID or TargetId at the fixed path.';
    RAISERROR(@m35c, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 35D*/
------------------------------------------------------------------------
-- 35D: a skip persists as SKIPPED, discoverable without parsing messages.
-- @MaxRunSeconds = 0 forces the time-limit skip branch.
------------------------------------------------------------------------
RAISERROR(N'Test 35D: skips persist as SKIPPED (#187)...', 10, 1) WITH NOWAIT;

DELETE FROM dbo.CommandLog;

/*
Re-pack rather than shrink-then-grow: after a rebuild the heap holds roughly one
large row per page, so shrinking frees space and growing fits back in place with
no forwarding. Only dense short rows that are then grown produce forwarded records.
*/
TRUNCATE TABLE dbo.HeapA;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapA (ID, Padding, MoreData)
SELECT TOP (20000) n, REPLICATE('S', 10), NULL FROM N;
UPDATE dbo.HeapA SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000) WHERE ID <= 15000;

EXEC dbo.sp_HeapDoctor
    @Databases     = N'HeapDoctorTest',
    @CpuSource     = N'NONE',
    @PlanOnly      = 0,
    @MaxRunSeconds = 0,
    @LogToTable    = N'Y';
GO

DECLARE @skips35 integer =
(
    SELECT COUNT_BIG(*)
    FROM dbo.CommandLog
    WHERE CommandType = N'HEAP_TARGET_EVENT'
      AND ExtendedInfo.value('(/TargetEvent/OutcomeCode)[1]','nvarchar(30)') = N'SKIPPED'
);

IF @skips35 >= 1
    RAISERROR(N'  PASS 35D: SKIPPED outcomes present without message parsing.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 35D: no SKIPPED outcome recorded despite @MaxRunSeconds = 0.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 35E*/
RAISERROR(N'Test 35E: success persists as SUCCEEDED (#187)...', 10, 1) WITH NOWAIT;

DELETE FROM dbo.CommandLog;

/*
Re-pack rather than shrink-then-grow: after a rebuild the heap holds roughly one
large row per page, so shrinking frees space and growing fits back in place with
no forwarding. Only dense short rows that are then grown produce forwarded records.
*/
TRUNCATE TABLE dbo.HeapB;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapB (ID, Code, Padding, MoreData)   /* HeapB has a NOT NULL Code column */
SELECT TOP (20000) n, 'CODE-' + CONVERT(varchar(10), n), REPLICATE('S', 10), NULL FROM N;
UPDATE dbo.HeapB SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000) WHERE ID <= 15000;

EXEC dbo.sp_HeapDoctor
    @Databases  = N'HeapDoctorTest',
    @Tables     = N'dbo.HeapB',
    @CpuSource  = N'NONE',
    @PlanOnly   = 0,
    @LogToTable = N'Y';
GO

DECLARE @succ35 integer =
(
    SELECT COUNT_BIG(*)
    FROM dbo.CommandLog
    WHERE CommandType = N'HEAP_TARGET_EVENT'
      AND ExtendedInfo.value('(/TargetEvent/OutcomeCode)[1]','nvarchar(30)') = N'SUCCEEDED'
);

IF @succ35 >= 1
    RAISERROR(N'  PASS 35E: SUCCEEDED outcome recorded.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 35E: no SUCCEEDED outcome recorded.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 35F*/
------------------------------------------------------------------------
-- 35F: the documented shredding query works, so consumers join on columns
-- rather than writing XPath.
------------------------------------------------------------------------
RAISERROR(N'Test 35F: shredding query returns relational rows (#187)...', 10, 1) WITH NOWAIT;

DECLARE @shred35 integer =
(
    SELECT COUNT_BIG(*)
    FROM (
        SELECT
            cl.ExtendedInfo.value('(/TargetEvent/RunID)[1]','uniqueidentifier') AS RunID,
            cl.ExtendedInfo.value('(/TargetEvent/TargetId)[1]','integer')       AS TargetId,
            cl.ExtendedInfo.value('(/TargetEvent/OutcomeCode)[1]','nvarchar(30)') AS OutcomeCode
        FROM dbo.CommandLog AS cl
        WHERE cl.CommandType = N'HEAP_TARGET_EVENT'
    ) AS v
    WHERE v.RunID IS NOT NULL AND v.TargetId IS NOT NULL AND v.OutcomeCode IS NOT NULL
);

IF @shred35 >= 1
    RAISERROR(N'  PASS 35F: shredded rows are fully populated.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 35F: shredding produced no complete rows.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 35G*/
RAISERROR(N'Test 35G: @LogToTable = N writes no events (#187)...', 10, 1) WITH NOWAIT;

DELETE FROM dbo.CommandLog;

/*
Re-pack rather than shrink-then-grow: after a rebuild the heap holds roughly one
large row per page, so shrinking frees space and growing fits back in place with
no forwarding. Only dense short rows that are then grown produce forwarded records.
*/
TRUNCATE TABLE dbo.HeapC;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapC (ID, Padding, BigData)          /* HeapC's LOB column is BigData */
SELECT TOP (20000) n, REPLICATE('S', 10), NULL FROM N;
UPDATE dbo.HeapC SET Padding = REPLICATE('X', 3000), BigData = REPLICATE('Y', 3000) WHERE ID <= 15000;

DECLARE @e35g integer = 0;
BEGIN TRY
    EXEC dbo.sp_HeapDoctor
        @Databases  = N'HeapDoctorTest',
        @Tables     = N'dbo.HeapC',
        @CpuSource  = N'NONE',
        @PlanOnly   = 0,
        @LogToTable = N'N';
END TRY BEGIN CATCH SET @e35g = ERROR_NUMBER(); END CATCH

DECLARE @ev35g integer = (SELECT COUNT_BIG(*) FROM dbo.CommandLog WHERE CommandType = N'HEAP_TARGET_EVENT');

IF @e35g = 0 AND @ev35g = 0
    RAISERROR(N'  PASS 35G: no events written and no error with @LogToTable = N.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @m35g nvarchar(200) = N'  FAIL 35G: err=' + CONVERT(nvarchar(10), @e35g)
        + N' events=' + CONVERT(nvarchar(10), @ev35g) + N' (expected 0 and 0).';
    RAISERROR(@m35g, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 35H*/
RAISERROR(N'Test 35H: HEAP_REBUILD_END still authoritative (#187)...', 10, 1) WITH NOWAIT;

DELETE FROM dbo.CommandLog;

/*
Re-pack rather than shrink-then-grow: after a rebuild the heap holds roughly one
large row per page, so shrinking frees space and growing fits back in place with
no forwarding. Only dense short rows that are then grown produce forwarded records.
*/
TRUNCATE TABLE dbo.HeapB;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapB (ID, Code, Padding, MoreData)   /* HeapB has a NOT NULL Code column */
SELECT TOP (20000) n, 'CODE-' + CONVERT(varchar(10), n), REPLICATE('S', 10), NULL FROM N;
UPDATE dbo.HeapB SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000) WHERE ID <= 15000;

EXEC dbo.sp_HeapDoctor
    @Databases  = N'HeapDoctorTest',
    @Tables     = N'dbo.HeapB',
    @CpuSource  = N'NONE',
    @PlanOnly   = 0,
    @LogToTable = N'Y';
GO

IF EXISTS (SELECT 1 FROM dbo.CommandLog WHERE CommandType = N'HEAP_REBUILD_END')
    RAISERROR(N'  PASS 35H: HEAP_REBUILD_END still written alongside the event stream.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 35H: HEAP_REBUILD_END missing.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 35V*/
RAISERROR(N'Test 35V: Version check...', 10, 1) WITH NOWAIT;

SELECT * INTO #Results FROM dbo.ResultsTemplate WHERE 1 = 0;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor @Databases = N'HeapDoctorTest', @CpuSource = N'NONE', @PlanOnly = 1;

DECLARE @ver35 nvarchar(20);
SELECT TOP (1) @ver35 = version FROM #Results;

IF @ver35 = (SELECT version FROM dbo.ExpectedVersion)
    RAISERROR(N'  PASS 35V: Version matches dbo.ExpectedVersion.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 35V: Version is %s and does not match dbo.ExpectedVersion.', 10, 1, @ver35) WITH NOWAIT;

IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
GO
/*#endregion*/

/*#region 35-SUMMARY*/
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 35 tests complete. Review results above. ===', 10, 1) WITH NOWAIT;
GO
/*#endregion*/
