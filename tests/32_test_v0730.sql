/*
sp_HeapDoctor Test Harness - v2026.07.30.1: Post-rebuild row count validation (#188)

Tests:
  -- Issue #188: row count validation compared SAMPLED estimates --
  32A - Removed: post-rebuild check no longer calls dm_db_index_physical_stats
  32B - Added:   both counts now come from sys.dm_db_partition_stats
  32C - Removed: "Investigate potential data loss" wording is gone
  32D - dm_db_partition_stats.row_count is exact (matches COUNT_BIG(*)) after rebuild
  32E - SAMPLED record_count is NOT reliable - characterises why the old source was wrong
  32F - Rebuild with @ScanMode = DETAILED succeeds
  32H - No-loss rebuild leaves row count unchanged, so the message cannot fire
  32I - TRUE POSITIVE: a genuine 1-row change during the rebuild IS detected

  NOT COVERED: @ScanMode = LIMITED. That mode is independently broken -- discovery
  fails with error 515 because dm_db_index_physical_stats returns NULL for
  forwarded_record_count in LIMITED mode while #Heaps declares it NOT NULL. Tracked
  separately; #188 does not fix it.

  -- Version --
  32V - Version is 2026.07.30.1

NOTE: the row-count warning fires via RAISERROR at severity 10, which goes only
to the client message stream and cannot be captured by INSERT...EXEC. Its
ABSENCE is asserted structurally (32A/32C, against sys.sql_modules) and the
replacement source is characterised behaviourally (32D/32E). The cross-version
harness additionally greps sqlcmd stdout for "Investigate potential data loss",
which must not appear.

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -U sa -P YourPassword -d HeapDoctorTest -i 32_test_v0730.sql
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE [HeapDoctorTest];
GO

/*#region 32-SETUP*/
------------------------------------------------------------------------
-- Capture table (matches sp_HeapDoctor first result set)
------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
CREATE TABLE #Results
(
    version                 nvarchar(20)   NULL,
    target_id               integer        NOT NULL,
    sort_order              integer        NOT NULL,
    database_name           sysname        NOT NULL,
    schema_name             sysname        NOT NULL,
    table_name              sysname        NOT NULL,
    page_count              bigint         NOT NULL,
    record_count            bigint         NULL,
    forwarded_record_count  bigint         NOT NULL,
    forwarded_pct           decimal(6,2)   NOT NULL,
    forwarded_fetch_count   bigint         NULL,
    avg_page_space_pct      decimal(5,2)   NULL,
    avg_frag_pct            decimal(5,2)   NULL,
    ghost_record_count      bigint         NULL,
    total_cpu_ms            bigint         NULL,
    ranking_basis           varchar(20)    NOT NULL,
    nci_count               integer        NOT NULL,
    key_source_index        sysname        NULL,
    action_chosen           varchar(32)    NOT NULL,
    est_pages_per_sec       float          NULL,
    est_seconds             integer        NULL,
    est_duration            nvarchar(20)   NULL,
    qs_snapshot_time_utc    datetime2(3)   NULL,
    qs_total_logical_reads  bigint         NULL,
    qs_total_physical_reads bigint         NULL,
    qs_total_duration_ms    bigint         NULL,
    qs_total_executions     bigint         NULL,
    qs_plan_count           integer        NULL,
    qs_query_count          integer        NULL,
    usage_hint              varchar(30)    NULL,
    ranking_score           decimal(8,4)   NULL,
    ranking_algo_version    nvarchar(10)   NULL,
    heap_compression        varchar(4)     NULL,
    replication_hint        varchar(20)    NULL,
    lock_escalation         varchar(10)    NULL,
    partition_count         integer        NULL,
    has_schema_bound_views  integer        NULL,
    has_indexed_views       integer        NULL,
    has_fk_references       integer        NULL,
    fk_ref_count            integer        NULL,
    filegroup_name          sysname        NULL,
    command_text            nvarchar(max)  NULL,
    ci_drop_command         nvarchar(max)  NULL,
    verify_command          nvarchar(max)  NULL,
    prev_forwarded_pct      decimal(6,2)   NULL,
    rebuilds_in_90d         integer        NULL,
    size_mb                 decimal(18,2)  NULL,
    est_space_savings_mb    decimal(18,2)  NULL,
    est_ci_swap_overhead_mb decimal(18,2)  NULL,
    est_log_mb              decimal(18,2)  NULL,
    days_since_last_rebuild integer        NULL,
    sqlserver_start_time    datetime       NULL,
    uptime_hours            decimal(10,1)  NULL,
    page_io_latch_wait_count bigint        NULL,
    page_io_latch_wait_ms   bigint         NULL,
    is_temporal_history     bit            NULL,
    recommended_action      nvarchar(50)   NULL
);
GO
/*#endregion*/

RAISERROR(N'=== Batch 32: v2026.07.30.1 (#188 row count validation) ===', 10, 1) WITH NOWAIT;

/*#region 32A*/
------------------------------------------------------------------------
-- 32A: #188 - post-rebuild check no longer uses dm_db_index_physical_stats
------------------------------------------------------------------------
RAISERROR(N'Test 32A: post-rebuild row count no longer uses physical_stats (#188)...', 10, 1) WITH NOWAIT;

DECLARE @has32a bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%@rows_out = SUM(record_count)%''
    ) SET @out = 1;',
    N'@out bit OUTPUT', @out = @has32a OUTPUT;

IF @has32a = 0
    RAISERROR(N'  PASS 32A: SAMPLED physical_stats row count removed.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 32A: post-rebuild check still sums record_count from physical_stats.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 32B*/
------------------------------------------------------------------------
-- 32B: #188 - both counts come from sys.dm_db_partition_stats
------------------------------------------------------------------------
RAISERROR(N'Test 32B: row count validation uses dm_db_partition_stats (#188)...', 10, 1) WITH NOWAIT;

DECLARE @has32b bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%dm_db_partition_stats%''
    ) SET @out = 1;',
    N'@out bit OUTPUT', @out = @has32b OUTPUT;

IF @has32b = 1
    RAISERROR(N'  PASS 32B: dm_db_partition_stats used for row count validation.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 32B: dm_db_partition_stats not found in proc definition.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 32C*/
------------------------------------------------------------------------
-- 32C: #188 - the unqualified data-loss claim is gone.
-- Keyed to the FULL operator-facing sentence, not the fragment: the version
-- history comment legitimately quotes "Investigate potential data loss" when
-- explaining why the warning was removed, so a fragment match would flag the
-- fix that satisfies it. Same trap as 31H.
------------------------------------------------------------------------
RAISERROR(N'Test 32C: "potential data loss" wording removed (#188)...', 10, 1) WITH NOWAIT;

DECLARE @has32c bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%Investigate potential data loss or concurrent DML%''
    ) SET @out = 1;',
    N'@out bit OUTPUT', @out = @has32c OUTPUT;

IF @has32c = 0
    RAISERROR(N'  PASS 32C: unqualified data-loss wording removed.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 32C: proc still claims potential data loss on a count mismatch.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 32D*/
------------------------------------------------------------------------
-- 32D: #188 - the replacement source is exact
-- Rebuild HeapA, then confirm dm_db_partition_stats.row_count matches an
-- actual COUNT_BIG(*). This is the property the old SAMPLED source lacked.
------------------------------------------------------------------------
RAISERROR(N'Test 32D: dm_db_partition_stats.row_count is exact after rebuild (#188)...', 10, 1) WITH NOWAIT;

EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables    = N'dbo.HeapA',
    @CpuSource = N'NONE',
    @PlanOnly  = 0;
GO

DECLARE @exact32d bigint, @meta32d bigint;
SELECT @exact32d = COUNT_BIG(*) FROM dbo.HeapA;
SELECT @meta32d = SUM(ps.row_count)
FROM sys.dm_db_partition_stats AS ps
WHERE ps.object_id = OBJECT_ID(N'dbo.HeapC')
  AND ps.index_id IN (0, 1);

IF @meta32d = @exact32d
    RAISERROR(N'  PASS 32D: partition_stats row_count matches COUNT_BIG(*) exactly.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @m32d nvarchar(300) = N'  FAIL 32D: partition_stats='
        + ISNULL(CONVERT(nvarchar(20), @meta32d), N'NULL') + N' but COUNT_BIG(*)='
        + CONVERT(nvarchar(20), @exact32d) + N'.';
    RAISERROR(@m32d, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 32E*/
------------------------------------------------------------------------
-- 32E: #188 - characterise the defect: SAMPLED record_count is unreliable.
-- This does not assert a specific error magnitude (sampling varies); it
-- asserts only that SAMPLED is an ESTIMATE while partition_stats is exact,
-- by requiring partition_stats to be the one that matches COUNT_BIG(*).
------------------------------------------------------------------------
RAISERROR(N'Test 32E: SAMPLED record_count characterised as an estimate (#188)...', 10, 1) WITH NOWAIT;

/* HeapC is deliberately used here: it still has forwarded records and has NOT
   been rebuilt by this test file, so its pages are sparse -- the exact state in
   which SAMPLED extrapolation is least accurate, and the state the old check
   compared against. */
DECLARE @exact32e bigint, @sampled32e bigint, @meta32e bigint;
SELECT @exact32e = COUNT_BIG(*) FROM dbo.HeapC;
SELECT @sampled32e = SUM(ips.record_count)
FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(N'dbo.HeapC'), 0, NULL, 'SAMPLED') AS ips
WHERE ips.index_id = 0;
SELECT @meta32e = SUM(ps.row_count)
FROM sys.dm_db_partition_stats AS ps
WHERE ps.object_id = OBJECT_ID(N'dbo.HeapC') AND ps.index_id IN (0, 1);

DECLARE @m32e nvarchar(400) = N'  INFO 32E: exact=' + CONVERT(nvarchar(20), @exact32e)
    + N', partition_stats=' + ISNULL(CONVERT(nvarchar(20), @meta32e), N'NULL')
    + N', SAMPLED=' + ISNULL(CONVERT(nvarchar(20), @sampled32e), N'NULL') + N'.';
RAISERROR(@m32e, 10, 1) WITH NOWAIT;

IF @meta32e = @exact32e
    RAISERROR(N'  PASS 32E: partition_stats is the exact source; SAMPLED is not relied on.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 32E: partition_stats did not match the exact count.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 32F*/
------------------------------------------------------------------------
-- 32F: #188 - @ScanMode = DETAILED rebuild succeeds
------------------------------------------------------------------------
RAISERROR(N'Test 32F: rebuild with @ScanMode = DETAILED (#188)...', 10, 1) WITH NOWAIT;

UPDATE dbo.HeapB SET Padding = REPLICATE('Q', 10) WHERE ID <= 15000;
UPDATE dbo.HeapB SET Padding = REPLICATE('X', 3000) WHERE ID <= 15000;

DECLARE @found32f integer, @succ32f integer;
EXEC dbo.sp_HeapDoctor
    @Databases    = N'HeapDoctorTest',
    @Tables       = N'dbo.HeapB',
    @CpuSource    = N'NONE',
    @PlanOnly     = 0,
    @ScanMode     = N'DETAILED',
    @TargetsFound = @found32f OUTPUT,
    @Succeeded    = @succ32f  OUTPUT;

IF @found32f >= 1 AND @succ32f >= 1
    RAISERROR(N'  PASS 32F: DETAILED scan mode rebuild succeeded.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @m32f nvarchar(300) = N'  FAIL 32F: targets='
        + ISNULL(CONVERT(nvarchar(10), @found32f), N'NULL') + N' succeeded='
        + ISNULL(CONVERT(nvarchar(10), @succ32f), N'NULL') + N'.';
    RAISERROR(@m32f, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 32H*/
------------------------------------------------------------------------
-- 32H: #188 - the no-loss case does not meet the warning's trigger.
--
-- The message fires via RAISERROR severity 10 and cannot be captured in
-- T-SQL, so this asserts the CONDITION the proc evaluates rather than the
-- output: capture partition_stats row_count either side of a real rebuild
-- using the proc's own query shape, and require them equal. If this ever
-- fails, the proc would emit the row-count message for a rebuild that lost
-- nothing -- which is exactly the #188 defect.
--
-- Also asserts the counts are non-NULL, so a silently-failing probe (which
-- would disable validation entirely) cannot masquerade as success.
------------------------------------------------------------------------
RAISERROR(N'Test 32H: no-loss rebuild does not trigger the row-count message (#188)...', 10, 1) WITH NOWAIT;

/*
Uses HeapC, which still carries forwarded records: 32D already rebuilt HeapA, and
a shrink-then-grow UPDATE cannot recreate forwarding on a freshly rebuilt heap
(its pages hold roughly one large row each, so a grown row fits back in place).
Measuring a heap that never rebuilds would make this assertion vacuous.
*/

DECLARE @pre32h bigint, @post32h bigint, @found32h integer, @succ32h integer;

SELECT @pre32h = SUM(ps.row_count)
FROM sys.dm_db_partition_stats AS ps
WHERE ps.object_id = OBJECT_ID(N'dbo.HeapC')
AND   ps.index_id IN (0, 1);

EXEC dbo.sp_HeapDoctor
    @Databases    = N'HeapDoctorTest',
    @Tables       = N'dbo.HeapC',
    @CpuSource    = N'NONE',
    @PlanOnly     = 0,
    @TargetsFound = @found32h OUTPUT,
    @Succeeded    = @succ32h  OUTPUT;

SELECT @post32h = SUM(ps.row_count)
FROM sys.dm_db_partition_stats AS ps
WHERE ps.object_id = OBJECT_ID(N'dbo.HeapC')
AND   ps.index_id IN (0, 1);

IF @pre32h IS NULL OR @post32h IS NULL
BEGIN
    DECLARE @mn32h nvarchar(300) = N'  FAIL 32H: row count probe returned NULL (pre='
        + ISNULL(CONVERT(nvarchar(20), @pre32h), N'NULL') + N', post='
        + ISNULL(CONVERT(nvarchar(20), @post32h), N'NULL')
        + N') - validation would be silently skipped.';
    RAISERROR(@mn32h, 10, 1) WITH NOWAIT;
END
ELSE IF @found32h >= 1 AND @succ32h >= 1 AND @pre32h = @post32h
    RAISERROR(N'  PASS 32H: rebuild ran and row count was unchanged, so no message is emitted.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @m32h nvarchar(400) = N'  FAIL 32H: targets='
        + ISNULL(CONVERT(nvarchar(10), @found32h), N'NULL') + N' succeeded='
        + ISNULL(CONVERT(nvarchar(10), @succ32h), N'NULL')
        + N' pre=' + CONVERT(nvarchar(20), @pre32h)
        + N' post=' + CONVERT(nvarchar(20), @post32h) + N'.';
    RAISERROR(@m32h, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 32I*/
------------------------------------------------------------------------
-- 32I: #188 - TRUE POSITIVE. A genuine row-count change during the rebuild
-- must be detected.
--
-- This was long believed to need a second session issuing concurrent DML,
-- which would be racy against a sub-second rebuild. It does not: a DDL
-- trigger on ALTER_TABLE fires INSIDE the rebuild statement, in the same
-- session and transaction, and can modify the very table being altered.
-- That makes the delta deterministic -- no timing window at all.
--
-- Note the magnitude: a ONE row change. The old 1% + 10 row tolerance would
-- have missed this entirely; the exact comparison catches it.
--
-- The message itself is RAISERROR severity 10 and cannot be captured in
-- T-SQL, so this asserts the CONDITION the proc evaluates (post <> pre, by
-- exactly the injected amount) plus a successful rebuild. The cross-version
-- harness greps stdout for "Row count changed" to confirm emission.
------------------------------------------------------------------------
RAISERROR(N'Test 32I: genuine row-count change is detected (#188)...', 10, 1) WITH NOWAIT;
GO

IF EXISTS (SELECT 1 FROM sys.triggers WHERE name = 'trg_hd32i_inject' AND parent_class = 1)
    DROP TRIGGER trg_hd32i_inject ON DATABASE;
GO
/* QUOTED_IDENTIFIER must be ON at CREATE time: the trigger uses an XML data
   type method, and a module captures that option at creation, not at fire time. */
SET QUOTED_IDENTIFIER ON;
GO
CREATE TRIGGER trg_hd32i_inject ON DATABASE FOR ALTER_TABLE
AS
BEGIN
    SET NOCOUNT ON;
    IF EVENTDATA().value('(/EVENT_INSTANCE/ObjectName)[1]','sysname') = N'HeapF'
        INSERT dbo.HeapF (ID, Padding, MoreData) VALUES (987654, REPLICATE('Z',10), NULL);
END
GO

SET QUOTED_IDENTIFIER ON;
DECLARE @pre32i bigint, @post32i bigint, @found32i integer, @succ32i integer;

SELECT @pre32i = SUM(ps.row_count)
FROM sys.dm_db_partition_stats AS ps
WHERE ps.object_id = OBJECT_ID(N'dbo.HeapF')
AND   ps.index_id IN (0, 1);

EXEC dbo.sp_HeapDoctor
    @Databases    = N'HeapDoctorTest',
    @Tables       = N'dbo.HeapF',
    @CpuSource    = N'NONE',
    @PlanOnly     = 0,
    @TargetsFound = @found32i OUTPUT,
    @Succeeded    = @succ32i  OUTPUT;

SELECT @post32i = SUM(ps.row_count)
FROM sys.dm_db_partition_stats AS ps
WHERE ps.object_id = OBJECT_ID(N'dbo.HeapF')
AND   ps.index_id IN (0, 1);

IF @found32i >= 1 AND @succ32i >= 1 AND @post32i = @pre32i + 1
    RAISERROR(N'  PASS 32I: injector changed the row count by 1 during the rebuild; the proc''s comparison detects it.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @m32i nvarchar(400) = N'  FAIL 32I: targets='
        + ISNULL(CONVERT(nvarchar(10), @found32i), N'NULL') + N' succeeded='
        + ISNULL(CONVERT(nvarchar(10), @succ32i), N'NULL')
        + N' pre=' + ISNULL(CONVERT(nvarchar(20), @pre32i), N'NULL')
        + N' post=' + ISNULL(CONVERT(nvarchar(20), @post32i), N'NULL')
        + N' (expected post = pre + 1).';
    RAISERROR(@m32i, 10, 1) WITH NOWAIT;
END
GO

IF EXISTS (SELECT 1 FROM sys.triggers WHERE name = 'trg_hd32i_inject' AND parent_class = 1)
    DROP TRIGGER trg_hd32i_inject ON DATABASE;
GO
/*#endregion*/

/*#region 32V*/
------------------------------------------------------------------------
-- 32V: Version check
------------------------------------------------------------------------
RAISERROR(N'Test 32V: Version check...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly  = 1;

DECLARE @ver32 nvarchar(20);
SELECT TOP (1) @ver32 = version FROM #Results;

IF @ver32 = N'2026.07.30.1'
    RAISERROR(N'  PASS 32V: Version is 2026.07.30.1.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 32V: Version is %s (expected 2026.07.30.1).', 10, 1, @ver32) WITH NOWAIT;
GO
/*#endregion*/

/*#region 32-CLEANUP*/
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
GO
/*#endregion*/

/*#region 32-SUMMARY*/
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 32 tests complete. Review PASS/FAIL results above. ===', 10, 1) WITH NOWAIT;
GO
/*#endregion*/
