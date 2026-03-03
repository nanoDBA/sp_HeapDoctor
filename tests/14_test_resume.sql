/*
sp_HeapDoctor Test Harness - Step 14: @ResumeRunID Parameter Tests (v0302i)

Tests the plan-then-execute resume workflow: run @PlanOnly=1 first,
then use @ResumeRunID to execute the same targets without re-discovery.

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 14_test_resume.sql
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE [HeapDoctorTest];
GO

------------------------------------------------------------------------
-- Reusable capture table (matches first result set of sp_HeapDoctor)
------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
CREATE TABLE #Results
(
    version                nvarchar(20)  NULL,
    target_id              int           NOT NULL,
    sort_order             int           NOT NULL,
    database_name          sysname       NOT NULL,
    schema_name            sysname       NOT NULL,
    table_name             sysname       NOT NULL,
    page_count             bigint        NOT NULL,
    record_count           bigint        NULL,
    forwarded_record_count bigint        NOT NULL,
    forwarded_pct          decimal(6,2)  NOT NULL,
    forwarded_fetch_count  bigint        NULL,
    avg_page_space_pct     decimal(5,2)  NULL,
    avg_frag_pct           decimal(5,2)  NULL,
    ghost_record_count     bigint        NULL,
    total_cpu_ms           bigint        NULL,
    ranking_basis          varchar(20)   NOT NULL,
    nci_count              int           NOT NULL,
    key_source_index       sysname       NULL,
    action_chosen          varchar(32)   NOT NULL,
    est_pages_per_sec      float         NULL,
    est_seconds            int           NULL,
    est_duration           nvarchar(20)  NULL,
    qs_snapshot_time_utc   datetime2(3)  NULL,
    qs_total_logical_reads bigint        NULL,
    qs_total_physical_reads bigint       NULL,
    qs_total_duration_ms   bigint        NULL,
    qs_total_executions    bigint        NULL,
    qs_plan_count          int           NULL,
    qs_query_count         int           NULL,
    usage_hint             varchar(30)   NULL,
    ranking_score          decimal(8,4)  NULL,
    ranking_algo_version   nvarchar(10)  NULL,
    heap_compression       varchar(4)    NULL,
    replication_hint       varchar(20)   NULL,
    lock_escalation        varchar(10)   NULL,
    partition_count        int           NULL,
    has_schema_bound_views int           NULL,
    has_indexed_views      int           NULL,
    has_fk_references      int           NULL,
    fk_ref_count           int           NULL,
    filegroup_name         sysname       NULL,
    command_text           nvarchar(max) NULL,
    ci_drop_command        nvarchar(max) NULL,
    verify_command         nvarchar(max) NULL,
    prev_forwarded_pct     decimal(6,2)  NULL,
    rebuilds_in_90d        int           NULL,
    size_mb                decimal(18,2) NULL,
    est_space_savings_mb   decimal(18,2) NULL,
    est_ci_swap_overhead_mb decimal(18,2) NULL,
    est_log_mb             decimal(18,2) NULL,
    days_since_last_rebuild int           NULL,
    sqlserver_start_time   datetime      NULL,
    uptime_hours           decimal(10,1) NULL,
    page_io_latch_wait_count bigint      NULL,
    page_io_latch_wait_ms  bigint        NULL,
    is_temporal_history    bit           NULL
);
GO

------------------------------------------------------------------------
-- Setup: create a plan-only scan to resume from
------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' SETUP: Creating plan-only scan for resume tests', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Run plan-only to generate HEAP_SCAN_SUMMARY
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource  = 'NONE',
    @Tables     = N'dbo.HeapA, dbo.HeapB',
    @PlanOnly   = 1,
    @LogToTable = N'Y';

-- Capture the RunID from the most recent HEAP_SCAN_SUMMARY
DECLARE @PlanRunID uniqueidentifier;
SELECT TOP (1) @PlanRunID = ExtendedInfo.value(N'(/ScanSummary/RunID)[1]', N'uniqueidentifier')
FROM dbo.CommandLog
WHERE CommandType = N'HEAP_SCAN_SUMMARY'
ORDER BY ID DESC;

DECLARE @PlanTargetCount int = (SELECT COUNT(*) FROM #Results);

DECLARE @setup_msg nvarchar(400) = N'  Plan-only RunID: ' + ISNULL(CAST(@PlanRunID AS nvarchar(36)), N'NULL')
                                 + N', targets: ' + CAST(@PlanTargetCount AS nvarchar(10));
RAISERROR(@setup_msg, 10, 1) WITH NOWAIT;

IF @PlanRunID IS NULL
BEGIN
    RAISERROR(N'  *** SETUP FAILED: No HEAP_SCAN_SUMMARY found. Aborting resume tests.', 16, 1) WITH NOWAIT;
    -- Cannot continue without a valid RunID
END
GO

-- Re-capture RunID for subsequent batches (GO resets variables)
DECLARE @PlanRunID uniqueidentifier;
SELECT TOP (1) @PlanRunID = ExtendedInfo.value(N'(/ScanSummary/RunID)[1]', N'uniqueidentifier')
FROM dbo.CommandLog
WHERE CommandType = N'HEAP_SCAN_SUMMARY'
ORDER BY ID DESC;

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 14A: Basic resume with @PlanOnly=1 (re-view)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @ResumeRunID = @PlanRunID,
    @PlanOnly    = 1;

-- 14A-1: Should return same targets as the plan-only run (HeapA and HeapB)
DECLARE @14a_count int = (SELECT COUNT(*) FROM #Results);
IF @14a_count = 2
   AND EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapA')
   AND EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapB')
    RAISERROR(N'  PASS 14A-1: Resume returned HeapA and HeapB (%d targets).', 10, 1, @14a_count) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @14a_msg nvarchar(200) = N'  *** FAIL 14A-1: Expected HeapA+HeapB, found ' + CAST(@14a_count AS nvarchar(10)) + N' rows.';
    RAISERROR(@14a_msg, 10, 1) WITH NOWAIT;
END

-- 14A-2: command_text should be populated (not NULL)
IF NOT EXISTS (SELECT 1 FROM #Results WHERE command_text IS NULL)
    RAISERROR(N'  PASS 14A-2: All targets have command_text.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 14A-2: Some targets have NULL command_text.', 10, 1) WITH NOWAIT;

-- 14A-3: ranking_score should be populated
IF NOT EXISTS (SELECT 1 FROM #Results WHERE ranking_score IS NULL)
    RAISERROR(N'  PASS 14A-3: All targets have ranking_score.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 14A-3: Some targets have NULL ranking_score.', 10, 1) WITH NOWAIT;

-- 14A-4: size_mb should be populated
IF NOT EXISTS (SELECT 1 FROM #Results WHERE size_mb IS NULL)
    RAISERROR(N'  PASS 14A-4: All targets have size_mb.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 14A-4: Some targets have NULL size_mb.', 10, 1) WITH NOWAIT;

-- 14A-5: No duplicate HEAP_SCAN_SUMMARY should be written for a resume
DECLARE @14a_summary_count int;
SELECT @14a_summary_count = COUNT(*)
FROM dbo.CommandLog
WHERE CommandType = N'HEAP_SCAN_SUMMARY'
  AND ExtendedInfo.exist(N'/ScanSummary/RunID[text()=sql:variable("@PlanRunID")]') = 1;

IF @14a_summary_count = 1
    RAISERROR(N'  PASS 14A-5: No duplicate HEAP_SCAN_SUMMARY written for resume.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @14a5_msg nvarchar(200) = N'  *** FAIL 14A-5: Expected 1 HEAP_SCAN_SUMMARY, found ' + CAST(@14a_summary_count AS nvarchar(10));
    RAISERROR(@14a5_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 14B: Resume with @PlanOnly=0 (execute)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Re-capture RunID
DECLARE @PlanRunID uniqueidentifier;
SELECT TOP (1) @PlanRunID = ExtendedInfo.value(N'(/ScanSummary/RunID)[1]', N'uniqueidentifier')
FROM dbo.CommandLog
WHERE CommandType = N'HEAP_SCAN_SUMMARY'
ORDER BY ID DESC;

-- Cannot use INSERT...EXEC here: @PlanOnly=0 returns TWO result sets
-- (target list + #ExecLog), and the second doesn't match #Results.
-- Use plain EXEC and validate via CommandLog instead.
EXEC dbo.sp_HeapDoctor
    @ResumeRunID = @PlanRunID,
    @PlanOnly    = 0;

-- 14B-1: HEAP_REBUILD_START should have ResumedFromRunID
DECLARE @14b_resumed_from uniqueidentifier;
SELECT TOP (1) @14b_resumed_from = ExtendedInfo.value(N'(/Parameters/ResumedFromRunID)[1]', N'uniqueidentifier')
FROM dbo.CommandLog
WHERE CommandType = N'HEAP_REBUILD_START'
ORDER BY ID DESC;

IF @14b_resumed_from = @PlanRunID
    RAISERROR(N'  PASS 14B-1: HEAP_REBUILD_START has ResumedFromRunID matching plan-only RunID.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @14b1_msg nvarchar(400) = N'  *** FAIL 14B-1: ResumedFromRunID='
        + ISNULL(CAST(@14b_resumed_from AS nvarchar(36)), N'NULL')
        + N', expected=' + CAST(@PlanRunID AS nvarchar(36));
    RAISERROR(@14b1_msg, 10, 1) WITH NOWAIT;
END

-- 14B-2: Per-rebuild CommandLog entries should exist
DECLARE @14b_rebuild_count int;
SELECT @14b_rebuild_count = COUNT(*)
FROM dbo.CommandLog
WHERE CommandType IN (N'HEAP_REBUILD_ONLINE', N'HEAP_REBUILD_OFFLINE', N'CI_SWAP_ONLINE')
  AND StartTime >= (SELECT MAX(StartTime) FROM dbo.CommandLog WHERE CommandType = N'HEAP_REBUILD_START');

IF @14b_rebuild_count >= 1
    RAISERROR(N'  PASS 14B-2: %d per-rebuild CommandLog entries found.', 10, 1, @14b_rebuild_count) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 14B-2: No per-rebuild CommandLog entries found.', 10, 1) WITH NOWAIT;

-- 14B-3: HEAP_REBUILD_END should exist
IF EXISTS (
    SELECT 1 FROM dbo.CommandLog
    WHERE CommandType = N'HEAP_REBUILD_END'
      AND StartTime >= (SELECT MAX(StartTime) FROM dbo.CommandLog WHERE CommandType = N'HEAP_REBUILD_START')
)
    RAISERROR(N'  PASS 14B-3: HEAP_REBUILD_END entry found.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 14B-3: No HEAP_REBUILD_END entry found.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 14C: Invalid RunID', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

DECLARE @14c_err int = 0;
BEGIN TRY
    EXEC dbo.sp_HeapDoctor
        @ResumeRunID = '00000000-0000-0000-0000-000000000000',
        @PlanOnly    = 1;
END TRY
BEGIN CATCH
    SET @14c_err = ERROR_NUMBER();
END CATCH

IF @14c_err > 0
    RAISERROR(N'  PASS 14C-1: Invalid RunID raised error (error %d).', 10, 1, @14c_err) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 14C-1: Invalid RunID did not raise error.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 14D: Execution RunID (not plan-only)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Get a HEAP_REBUILD_START RunID
DECLARE @ExecRunID uniqueidentifier;
SELECT TOP (1) @ExecRunID = ExtendedInfo.value(N'(/Parameters/RunID)[1]', N'uniqueidentifier')
FROM dbo.CommandLog
WHERE CommandType = N'HEAP_REBUILD_START'
ORDER BY ID DESC;

DECLARE @14d_err int = 0;
IF @ExecRunID IS NOT NULL
BEGIN
    BEGIN TRY
        EXEC dbo.sp_HeapDoctor
            @ResumeRunID = @ExecRunID,
            @PlanOnly    = 1;
    END TRY
    BEGIN CATCH
        SET @14d_err = ERROR_NUMBER();
    END CATCH

    IF @14d_err > 0
        RAISERROR(N'  PASS 14D-1: Execution RunID raised error (error %d).', 10, 1, @14d_err) WITH NOWAIT;
    ELSE
        RAISERROR(N'  *** FAIL 14D-1: Execution RunID did not raise error.', 10, 1) WITH NOWAIT;
END
ELSE
    RAISERROR(N'  SKIP 14D-1: No HEAP_REBUILD_START found (test 14B may have failed).', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 14E: Obfuscated plan (resume blocked)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Insert a mock obfuscated HEAP_SCAN_SUMMARY directly into CommandLog.
-- (Running a real obfuscated plan-only after 14B is unreliable because the heaps were rebuilt.)
DECLARE @ObfuRunID uniqueidentifier = NEWID();
INSERT INTO dbo.CommandLog
    (DatabaseName, SchemaName, ObjectName, ObjectType, Command, CommandType,
     StartTime, EndTime, ErrorNumber, ErrorMessage, ExtendedInfo)
VALUES
(
    N'HeapDoctorTest', N'dbo', N'sp_HeapDoctor', N'P',
    N'EXECUTE dbo.sp_HeapDoctor @Databases = N''HeapDoctorTest'', @PlanOnly = 1...',
    N'HEAP_SCAN_SUMMARY',
    SYSDATETIME(), SYSDATETIME(), 0, NULL,
    CAST(N'<ScanSummary>
        <Version>1.0.2026.0302i</Version>
        <RunID>' + CAST(@ObfuRunID AS nvarchar(36)) + N'</RunID>
        <TargetCount>1</TargetCount>
        <ObfuscatedMappingHex>DEADBEEF0123456789</ObfuscatedMappingHex>
        <Targets>
            <Target DatabaseName="HeapDoctorTest" SchemaName="dbo" TableName="HeapA"
                    PageCount="1000" SizeMB="7.81" RecordCount="5000"
                    ForwardedRecordCount="2500" ForwardedPct="50.00"
                    RankingScore="1.50" RankingBasis="FWD_PCT"
                    ActionChosen="HEAP_REBUILD_ONLINE"
                    CommandText="ALTER TABLE [HeapDoctorTest].[dbo].[HeapA] REBUILD WITH (ONLINE = ON);"
                    SortOrder="1" HeapCompression="0" LockEscalation="0"
                    HasLobColumns="0" NciCount="0" />
        </Targets>
    </ScanSummary>' AS xml)
);

DECLARE @14e_err int = 0;
IF @ObfuRunID IS NOT NULL
BEGIN
    BEGIN TRY
        EXEC dbo.sp_HeapDoctor
            @ResumeRunID = @ObfuRunID,
            @PlanOnly    = 1;
    END TRY
    BEGIN CATCH
        SET @14e_err = ERROR_NUMBER();
    END CATCH

    IF @14e_err > 0
        RAISERROR(N'  PASS 14E-1: Obfuscated plan resume blocked (error %d).', 10, 1, @14e_err) WITH NOWAIT;
    ELSE
        RAISERROR(N'  *** FAIL 14E-1: Obfuscated plan resume was not blocked.', 10, 1) WITH NOWAIT;
END
ELSE
    RAISERROR(N'  SKIP 14E-1: Could not create obfuscated HEAP_SCAN_SUMMARY.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 14F: @ResumeRunID + @RevealKey (mutual exclusivity)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

DECLARE @14f_err int = 0;
BEGIN TRY
    EXEC dbo.sp_HeapDoctor
        @ResumeRunID = '11111111-1111-1111-1111-111111111111',
        @RevealKey   = N'SomeKey',
        @RevealRunID = '22222222-2222-2222-2222-222222222222',
        @PlanOnly    = 1;
END TRY
BEGIN CATCH
    SET @14f_err = ERROR_NUMBER();
END CATCH

IF @14f_err > 0
    RAISERROR(N'  PASS 14F-1: @ResumeRunID + @RevealKey raised error (error %d).', 10, 1, @14f_err) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 14F-1: @ResumeRunID + @RevealKey did not raise error.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 14G: Resume preserves all columns', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Get the plan-only RunID (the non-obfuscated one)
DECLARE @PlanRunID uniqueidentifier;
SELECT TOP (1) @PlanRunID = ExtendedInfo.value(N'(/ScanSummary/RunID)[1]', N'uniqueidentifier')
FROM dbo.CommandLog
WHERE CommandType = N'HEAP_SCAN_SUMMARY'
  AND ExtendedInfo.exist(N'/ScanSummary/ObfuscatedMappingHex[text()]') = 0
ORDER BY ID DESC;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @ResumeRunID = @PlanRunID,
    @PlanOnly    = 1;

-- 14G-1: action_chosen should be populated
IF NOT EXISTS (SELECT 1 FROM #Results WHERE action_chosen IS NULL OR action_chosen = '')
    RAISERROR(N'  PASS 14G-1: All targets have action_chosen.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 14G-1: Some targets have NULL/empty action_chosen.', 10, 1) WITH NOWAIT;

-- 14G-2: verify_command should be populated
IF NOT EXISTS (SELECT 1 FROM #Results WHERE verify_command IS NULL)
    RAISERROR(N'  PASS 14G-2: All targets have verify_command.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 14G-2: Some targets have NULL verify_command.', 10, 1) WITH NOWAIT;

-- 14G-3: page_count should be > 0
IF NOT EXISTS (SELECT 1 FROM #Results WHERE page_count <= 0)
    RAISERROR(N'  PASS 14G-3: All targets have positive page_count.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 14G-3: Some targets have page_count <= 0.', 10, 1) WITH NOWAIT;

-- 14G-4: forwarded_pct should be > 0
IF NOT EXISTS (SELECT 1 FROM #Results WHERE forwarded_pct <= 0)
    RAISERROR(N'  PASS 14G-4: All targets have positive forwarded_pct.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 14G-4: Some targets have forwarded_pct <= 0.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 14H: HEAP_SCAN_SUMMARY XML has enriched target data', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Check the most recent non-obfuscated HEAP_SCAN_SUMMARY for the new XML attributes
DECLARE @ScanXml xml;
SELECT TOP (1) @ScanXml = ExtendedInfo
FROM dbo.CommandLog
WHERE CommandType = N'HEAP_SCAN_SUMMARY'
  AND ExtendedInfo.exist(N'/ScanSummary/ObfuscatedMappingHex[text()]') = 0
ORDER BY ID DESC;

-- 14H-1: CommandText attribute should exist in first target
IF @ScanXml.exist(N'/ScanSummary/Targets/Target/@CommandText') = 1
    RAISERROR(N'  PASS 14H-1: CommandText attribute present in HEAP_SCAN_SUMMARY Target.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 14H-1: CommandText attribute missing from HEAP_SCAN_SUMMARY Target.', 10, 1) WITH NOWAIT;

-- 14H-2: SortOrder attribute
IF @ScanXml.exist(N'/ScanSummary/Targets/Target/@SortOrder') = 1
    RAISERROR(N'  PASS 14H-2: SortOrder attribute present.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 14H-2: SortOrder attribute missing.', 10, 1) WITH NOWAIT;

-- 14H-3: HeapCompression attribute
IF @ScanXml.exist(N'/ScanSummary/Targets/Target/@HeapCompression') = 1
    RAISERROR(N'  PASS 14H-3: HeapCompression attribute present.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 14H-3: HeapCompression attribute missing.', 10, 1) WITH NOWAIT;

-- 14H-4: RankingBasis attribute
IF @ScanXml.exist(N'/ScanSummary/Targets/Target/@RankingBasis') = 1
    RAISERROR(N'  PASS 14H-4: RankingBasis attribute present.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 14H-4: RankingBasis attribute missing.', 10, 1) WITH NOWAIT;

-- 14H-5: VerifyCommand attribute
IF @ScanXml.exist(N'/ScanSummary/Targets/Target/@VerifyCommand') = 1
    RAISERROR(N'  PASS 14H-5: VerifyCommand attribute present.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 14H-5: VerifyCommand attribute missing.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 14I: @Tables filters resumed targets; @Databases ignored', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Get the plan-only RunID (non-obfuscated, has HeapA + HeapB)
DECLARE @PlanRunID uniqueidentifier;
SELECT TOP (1) @PlanRunID = ExtendedInfo.value(N'(/ScanSummary/RunID)[1]', N'uniqueidentifier')
FROM dbo.CommandLog
WHERE CommandType = N'HEAP_SCAN_SUMMARY'
  AND ExtendedInfo.exist(N'/ScanSummary/ObfuscatedMappingHex[text()]') = 0
ORDER BY ID DESC;

-- 14I-1: @Tables should filter resumed targets to just HeapA
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @ResumeRunID = @PlanRunID,
    @Tables      = N'dbo.HeapA',
    @PlanOnly    = 1;

DECLARE @14i1_count int = (SELECT COUNT(*) FROM #Results);
IF @14i1_count = 1 AND EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapA')
    RAISERROR(N'  PASS 14I-1: @Tables filtered resumed targets to HeapA only (%d target).', 10, 1, @14i1_count) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @14i1_msg nvarchar(200) = N'  *** FAIL 14I-1: Expected 1 HeapA, found ' + CAST(@14i1_count AS nvarchar(10)) + N' rows.';
    RAISERROR(@14i1_msg, 10, 1) WITH NOWAIT;
END

-- 14I-2: @Databases with @ResumeRunID should be ignored (not error)
DECLARE @14i2_err int = 0;
BEGIN TRY
    TRUNCATE TABLE #Results;
    INSERT #Results
    EXEC dbo.sp_HeapDoctor
        @ResumeRunID = @PlanRunID,
        @Databases   = N'USER_DATABASES',
        @PlanOnly    = 1;
END TRY
BEGIN CATCH
    SET @14i2_err = ERROR_NUMBER();
END CATCH

IF @14i2_err = 0
    RAISERROR(N'  PASS 14I-2: @Databases with @ResumeRunID did not error (ignored gracefully).', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @14i2_msg nvarchar(200) = N'  *** FAIL 14I-2: @Databases with @ResumeRunID raised error ' + CAST(@14i2_err AS nvarchar(10));
    RAISERROR(@14i2_msg, 10, 1) WITH NOWAIT;
END

-- 14I-3: @Tables exclusion should work on resumed targets
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @ResumeRunID = @PlanRunID,
    @Tables      = N'-dbo.HeapA',
    @PlanOnly    = 1;

DECLARE @14i3_count int = (SELECT COUNT(*) FROM #Results);
IF @14i3_count = 1 AND EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapB')
    RAISERROR(N'  PASS 14I-3: @Tables exclusion removed HeapA, kept HeapB.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @14i3_msg nvarchar(200) = N'  *** FAIL 14I-3: Expected 1 HeapB, found ' + CAST(@14i3_count AS nvarchar(10)) + N' rows.';
    RAISERROR(@14i3_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 14J: @TopN filters resumed targets', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Get the plan-only RunID (non-obfuscated, has HeapA + HeapB)
DECLARE @PlanRunID uniqueidentifier;
SELECT TOP (1) @PlanRunID = ExtendedInfo.value(N'(/ScanSummary/RunID)[1]', N'uniqueidentifier')
FROM dbo.CommandLog
WHERE CommandType = N'HEAP_SCAN_SUMMARY'
  AND ExtendedInfo.exist(N'/ScanSummary/ObfuscatedMappingHex[text()]') = 0
ORDER BY ID DESC;

-- 14J-1: @TopN=1 should return only 1 target (plan had 2: HeapA + HeapB)
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @ResumeRunID = @PlanRunID,
    @TopN        = 1,
    @PlanOnly    = 1;

DECLARE @14j1_count int = (SELECT COUNT(*) FROM #Results);
IF @14j1_count = 1
    RAISERROR(N'  PASS 14J-1: @TopN=1 filtered resumed targets to 1 (from 2).', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @14j1_msg nvarchar(200) = N'  *** FAIL 14J-1: Expected 1 target, found ' + CAST(@14j1_count AS nvarchar(10));
    RAISERROR(@14j1_msg, 10, 1) WITH NOWAIT;
END

-- 14J-2: @TopN=1 combined with @Tables exclusion
--   Plan has HeapA (sort_order 1) + HeapB (sort_order 2).
--   @Tables = '-dbo.HeapA' removes HeapA first, leaving HeapB.
--   @TopN=1 then keeps only HeapB.
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @ResumeRunID = @PlanRunID,
    @Tables      = N'-dbo.HeapA',
    @TopN        = 1,
    @PlanOnly    = 1;

DECLARE @14j2_count int = (SELECT COUNT(*) FROM #Results);
IF @14j2_count = 1 AND EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapB')
    RAISERROR(N'  PASS 14J-2: @Tables exclusion + @TopN=1 returned HeapB only.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @14j2_msg nvarchar(200) = N'  *** FAIL 14J-2: Expected 1 HeapB, found ' + CAST(@14j2_count AS nvarchar(10));
    RAISERROR(@14j2_msg, 10, 1) WITH NOWAIT;
END

-- 14J-3: @TopN >= target count returns all (no trimming)
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @ResumeRunID = @PlanRunID,
    @TopN        = 25,
    @PlanOnly    = 1;

DECLARE @14j3_count int = (SELECT COUNT(*) FROM #Results);
IF @14j3_count = 2
    RAISERROR(N'  PASS 14J-3: @TopN=25 returned all 2 targets (no trimming).', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @14j3_msg nvarchar(200) = N'  *** FAIL 14J-3: Expected 2 targets, found ' + CAST(@14j3_count AS nvarchar(10));
    RAISERROR(@14j3_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' RESUME TESTS COMPLETE', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
GO
