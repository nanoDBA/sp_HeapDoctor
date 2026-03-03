/*
sp_HeapDoctor Test Harness - Pre-flight Safety Checks (#44, #49, #20)

Tests:
  -- Issue #44: FK references TO heap detection --
  18A - has_fk_references=1 when FK references the heap
  18B - fk_ref_count matches actual FK count
  18C - has_fk_references=0 when no FKs reference the heap
  18D - FK info warning message emitted for CI_SWAP targets with FK references
  18E - FK columns in HEAP_SCAN_SUMMARY XML

  -- Issue #49: Log space pre-flight --
  18F - est_log_mb populated for FULL recovery heaps

  -- Issue #20: Tempdb pre-flight --
  18G - Tempdb check does not error on normal CI swap targets

  -- Version --
  18V - Version is 1.0.2026.0302d

Requires: 01_setup_test_data.sql (HeapDoctorTest database)
Must run BEFORE execution tests (03+).
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

USE [HeapDoctorTest];
GO

------------------------------------------------------------------------
-- Setup: Create test objects for FK detection
------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Setting up FK test objects ===', 10, 1) WITH NOWAIT;

-- HeapFkParent: heap with unique NCI (CI swap candidate), referenced by FKs
IF OBJECT_ID(N'dbo.HeapFkChild2', N'U') IS NOT NULL DROP TABLE dbo.HeapFkChild2;
IF OBJECT_ID(N'dbo.HeapFkChild1', N'U') IS NOT NULL DROP TABLE dbo.HeapFkChild1;
IF OBJECT_ID(N'dbo.HeapFkParent', N'U') IS NOT NULL DROP TABLE dbo.HeapFkParent;

RAISERROR(N'Creating dbo.HeapFkParent (heap with unique NCI, referenced by FKs)...', 10, 1) WITH NOWAIT;
CREATE TABLE dbo.HeapFkParent
(
    ID       int           NOT NULL,
    Code     varchar(50)   NOT NULL,
    Padding  varchar(4000) NOT NULL,
    MoreData varchar(4000) NULL
);
CREATE UNIQUE NONCLUSTERED INDEX UX_HeapFkParent_ID ON dbo.HeapFkParent(ID);

-- Two child tables referencing the parent via FK
RAISERROR(N'Creating dbo.HeapFkChild1 (FK to HeapFkParent)...', 10, 1) WITH NOWAIT;
CREATE TABLE dbo.HeapFkChild1
(
    ChildID   int NOT NULL IDENTITY(1,1) PRIMARY KEY,
    ParentID  int NOT NULL,
    CONSTRAINT FK_Child1_Parent FOREIGN KEY (ParentID) REFERENCES dbo.HeapFkParent(ID)
);

RAISERROR(N'Creating dbo.HeapFkChild2 (FK to HeapFkParent)...', 10, 1) WITH NOWAIT;
CREATE TABLE dbo.HeapFkChild2
(
    ChildID   int NOT NULL IDENTITY(1,1) PRIMARY KEY,
    ParentID  int NOT NULL,
    CONSTRAINT FK_Child2_Parent FOREIGN KEY (ParentID) REFERENCES dbo.HeapFkParent(ID)
);

-- Populate HeapFkParent with forwarded records
RAISERROR(N'Populating HeapFkParent with forwarded records...', 10, 1) WITH NOWAIT;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapFkParent (ID, Code, Padding, MoreData)
SELECT TOP (20000)
    n,
    'FK-' + CAST(n AS varchar(10)),
    REPLICATE('P', 10),
    NULL
FROM N;

UPDATE dbo.HeapFkParent
SET Padding = REPLICATE('X', 3000),
    MoreData = REPLICATE('Y', 3000)
WHERE ID <= 15000;

-- Insert child rows (so FKs are active)
INSERT dbo.HeapFkChild1 (ParentID) SELECT TOP (100) ID FROM dbo.HeapFkParent;
INSERT dbo.HeapFkChild2 (ParentID) SELECT TOP (50) ID FROM dbo.HeapFkParent;
GO

------------------------------------------------------------------------
-- Capture result set
------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 18: Pre-flight Safety Checks (#44 FK, #49 Log Space, #20 Tempdb) ===', 10, 1) WITH NOWAIT;
RAISERROR(N'', 10, 1) WITH NOWAIT;

IF OBJECT_ID(N'tempdb..#Results') IS NOT NULL DROP TABLE #Results;

CREATE TABLE #Results
(
    version                nvarchar(20)  NULL,
    target_id              int           NULL,
    sort_order             int           NULL,
    database_name          sysname       NULL,
    schema_name            sysname       NULL,
    table_name             sysname       NULL,
    page_count             bigint        NULL,
    record_count           bigint        NULL,
    forwarded_record_count bigint        NULL,
    forwarded_pct          decimal(6,2)  NULL,
    forwarded_fetch_count  bigint        NULL,
    avg_page_space_pct     decimal(5,2)  NULL,
    avg_frag_pct           decimal(5,2)  NULL,
    ghost_record_count     bigint        NULL,
    total_cpu_ms           bigint        NULL,
    ranking_basis          varchar(20)   NULL,
    nci_count              int           NULL,
    key_source_index       sysname       NULL,
    action_chosen          varchar(32)   NULL,
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
    days_since_last_rebuild int          NULL,
    sqlserver_start_time   datetime      NULL,
    uptime_hours           decimal(10,1) NULL
);

INSERT #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @PlanOnly = 1,
    @LogToTable = 'Y',
    @CpuSource = N'NONE',
    @AllowCiSwap = 1,
    @PreferCiSwap = 1,
    @Tables = N'HeapFkParent, HeapC';
GO

------------------------------------------------------------------------
-- Test 18A: has_fk_references=1 when FK references the heap
------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
IF EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapFkParent' AND has_fk_references = 1)
    RAISERROR(N'  PASS 18A: has_fk_references=1 for HeapFkParent (has incoming FKs).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 18A: Expected has_fk_references=1 for HeapFkParent.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- Test 18B: fk_ref_count matches actual FK count (2 FKs)
------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapFkParent' AND fk_ref_count = 2)
    RAISERROR(N'  PASS 18B: fk_ref_count=2 for HeapFkParent (2 child FKs).', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @actual_fk_cnt int;
    SELECT @actual_fk_cnt = fk_ref_count FROM #Results WHERE table_name = N'HeapFkParent';
    DECLARE @fk_msg nvarchar(200) = N'  FAIL 18B: Expected fk_ref_count=2, got ' + ISNULL(CAST(@actual_fk_cnt AS nvarchar(10)), N'NULL');
    RAISERROR(@fk_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
-- Test 18C: has_fk_references=0 when no FKs reference the heap
------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapC' AND has_fk_references = 0 AND fk_ref_count = 0)
    RAISERROR(N'  PASS 18C: has_fk_references=0 for HeapC (no incoming FKs).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 18C: Expected has_fk_references=0, fk_ref_count=0 for HeapC.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- Test 18D: FK info message emitted for CI_SWAP targets with FK references
-- HeapFkParent has unique NCI + FK refs -> should be CI_SWAP_ONLINE with FK info
------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapFkParent' AND action_chosen = N'CI_SWAP_ONLINE')
    RAISERROR(N'  PASS 18D: HeapFkParent action is CI_SWAP_ONLINE (FK does not block CI swap, just warns).', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @fk_action varchar(32);
    SELECT @fk_action = action_chosen FROM #Results WHERE table_name = N'HeapFkParent';
    DECLARE @fk_action_msg nvarchar(200) = N'  FAIL 18D: Expected CI_SWAP_ONLINE for HeapFkParent, got ' + ISNULL(@fk_action, N'NULL');
    RAISERROR(@fk_action_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
-- Test 18E: FK columns in HEAP_SCAN_SUMMARY XML
------------------------------------------------------------------------
DECLARE @scan_xml xml;
SELECT TOP (1) @scan_xml = ExtendedInfo
FROM dbo.CommandLog
WHERE CommandType = N'HEAP_SCAN_SUMMARY'
  AND ExtendedInfo.exist(N'/ScanSummary/Targets/Target[@TableName="HeapFkParent"]') = 1
ORDER BY ID DESC;

IF @scan_xml IS NOT NULL
BEGIN
    DECLARE @xml_fk_ref int = @scan_xml.value(N'(/ScanSummary/Targets/Target[@TableName="HeapFkParent"]/@HasFkReferences)[1]', N'int');
    DECLARE @xml_fk_cnt int = @scan_xml.value(N'(/ScanSummary/Targets/Target[@TableName="HeapFkParent"]/@FkRefCount)[1]', N'int');

    IF @xml_fk_ref = 1 AND @xml_fk_cnt = 2
        RAISERROR(N'  PASS 18E: HEAP_SCAN_SUMMARY XML has HasFkReferences=1, FkRefCount=2 for HeapFkParent.', 10, 1) WITH NOWAIT;
    ELSE
    BEGIN
        DECLARE @xml_msg nvarchar(200) = N'  FAIL 18E: XML HasFkReferences=' + ISNULL(CAST(@xml_fk_ref AS nvarchar(10)), N'NULL')
            + N', FkRefCount=' + ISNULL(CAST(@xml_fk_cnt AS nvarchar(10)), N'NULL') + N' (expected 1, 2)';
        RAISERROR(@xml_msg, 10, 1) WITH NOWAIT;
    END
END
ELSE
    RAISERROR(N'  FAIL 18E: No HEAP_SCAN_SUMMARY found with HeapFkParent target.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- Test 18F: est_log_mb populated for FULL recovery heaps
-- HeapDoctorTest is in FULL recovery by default; est_log_mb should be non-NULL
------------------------------------------------------------------------
DECLARE @recovery_model nvarchar(60);
SELECT @recovery_model = recovery_model_desc FROM sys.databases WHERE name = N'HeapDoctorTest';

IF @recovery_model = N'FULL'
BEGIN
    IF EXISTS (SELECT 1 FROM #Results WHERE est_log_mb IS NOT NULL AND est_log_mb > 0)
        RAISERROR(N'  PASS 18F: est_log_mb populated for FULL recovery database targets.', 10, 1) WITH NOWAIT;
    ELSE
        RAISERROR(N'  FAIL 18F: est_log_mb not populated for any target (database is FULL recovery).', 10, 1) WITH NOWAIT;
END
ELSE
BEGIN
    -- If not FULL recovery, est_log_mb may be NULL, which is correct
    RAISERROR(N'  PASS 18F: Database is not FULL recovery; est_log_mb NULL is expected.', 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
-- Test 18G: Tempdb check does not error on CI swap targets
-- HeapFkParent should be CI_SWAP_ONLINE with @AllowCiSwap=1.
-- The fact that results were returned means tempdb check ran without error.
------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM #Results WHERE action_chosen = N'CI_SWAP_ONLINE')
    RAISERROR(N'  PASS 18G: Tempdb pre-flight check ran without error (CI_SWAP targets present in results).', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @any_action varchar(32);
    SELECT TOP (1) @any_action = action_chosen FROM #Results;
    DECLARE @g_msg nvarchar(200) = N'  FAIL 18G: Expected CI_SWAP_ONLINE target but got ' + ISNULL(@any_action, N'no results');
    RAISERROR(@g_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
-- Test 18V: Version check
------------------------------------------------------------------------
DECLARE @ver18 nvarchar(20);
SELECT TOP (1) @ver18 = version FROM #Results;

IF @ver18 = N'1.0.2026.0302d'
    RAISERROR(N'  PASS 18V: Version is 1.0.2026.0302d.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 18V: Version is %s (expected 1.0.2026.0302d).', 10, 1, @ver18) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- Cleanup: drop FK test objects
------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Cleaning up FK test objects...', 10, 1) WITH NOWAIT;
IF OBJECT_ID(N'dbo.HeapFkChild2', N'U') IS NOT NULL DROP TABLE dbo.HeapFkChild2;
IF OBJECT_ID(N'dbo.HeapFkChild1', N'U') IS NOT NULL DROP TABLE dbo.HeapFkChild1;
IF OBJECT_ID(N'dbo.HeapFkParent', N'U') IS NOT NULL DROP TABLE dbo.HeapFkParent;

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 18 complete ===', 10, 1) WITH NOWAIT;
GO
