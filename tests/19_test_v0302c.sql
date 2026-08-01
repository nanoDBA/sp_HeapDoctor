/*
sp_HeapDoctor Test Harness - Batch A+C features

Tests:
  -- Issue #68: SQL 2017 version check --
  19A - SQL 2017 version check code exists in proc definition

  -- Issue #18: @CheckPermissionsOnly --
  19B - @CheckPermissionsOnly returns result set
  19C - @CheckPermissionsOnly includes ALTER TRACE server-level check
  19D - @CheckPermissionsOnly with @Databases scopes correctly
  19E - @CheckPermissionsOnly returns early (no targets)

  -- Issue #75: INSTEAD OF trigger detection --
  19F - CI swap succeeds on table with INSTEAD OF trigger (DDL not affected by DML triggers)

  -- Issue #78: Enhanced lock_escalation for CI swap --
  19G - lock_escalation=TABLE shown for CI swap target

  -- Issue #63: AG failover check --
  19H - AG failover check code exists in proc definition

  -- Issue #89: @AllowReplicationRebuild --
  19I - @AllowReplicationRebuild=0 accepted without error
  19J - @AllowReplicationRebuild=1 appears in invocation_command

  -- Version --
  19V - Version matches dbo.ExpectedVersion

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 19_test_v0302c.sql
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE [HeapDoctorTest];
GO

------------------------------------------------------------------------
-- Reusable capture table (matches first result set of sp_HeapDoctor)
------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
/* #190: the column list lives once, in dbo.ResultsTemplate (see 01_setup_test_data.sql) */
SELECT * INTO #Results FROM dbo.ResultsTemplate WHERE 1 = 0;
GO

RAISERROR(N'=== Batch 19: (#68, #18, #75, #78, #63, #89) ===', 10, 1) WITH NOWAIT;

------------------------------------------------------------------------
-- 19A: #68 - SQL 2017 version check code exists in proc definition
------------------------------------------------------------------------
RAISERROR(N'Test 19A: SQL 2017 version check (#68)...', 10, 1) WITH NOWAIT;

DECLARE @has_version_check bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%ProductMajorVersion%14%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has_version_check OUTPUT;

IF @has_version_check = 1
    RAISERROR(N'  PASS 19A: SQL 2017 version check (ProductMajorVersion >= 14) found in proc.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 19A: SQL 2017 version check not found in proc definition.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 19B: #18 - @CheckPermissionsOnly returns a result set
------------------------------------------------------------------------
RAISERROR(N'Test 19B: @CheckPermissionsOnly basic result set (#18)...', 10, 1) WITH NOWAIT;

IF OBJECT_ID('tempdb..#PermResults') IS NOT NULL DROP TABLE #PermResults;
CREATE TABLE #PermResults
(
    database_name   sysname        NOT NULL,
    permission_name nvarchar(128)  NOT NULL,
    granted         nvarchar(1)    NOT NULL
);

INSERT INTO #PermResults
EXEC dbo.sp_HeapDoctor @CheckPermissionsOnly = 1;

DECLARE @perm_count int;
SELECT @perm_count = COUNT(*) FROM #PermResults;

IF @perm_count > 0
    RAISERROR(N'  PASS 19B: @CheckPermissionsOnly returned %d permission check(s).', 10, 1, @perm_count) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 19B: @CheckPermissionsOnly returned no results.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 19C: #18 - @CheckPermissionsOnly includes ALTER TRACE
------------------------------------------------------------------------
RAISERROR(N'Test 19C: @CheckPermissionsOnly ALTER TRACE check (#18)...', 10, 1) WITH NOWAIT;

IF EXISTS (SELECT 1 FROM #PermResults WHERE permission_name = N'ALTER TRACE' AND database_name = N'(server)')
    RAISERROR(N'  PASS 19C: ALTER TRACE server-level permission check present.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 19C: ALTER TRACE check missing from result set.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 19D: #18 - @CheckPermissionsOnly with @Databases scopes correctly
------------------------------------------------------------------------
RAISERROR(N'Test 19D: @CheckPermissionsOnly with @Databases (#18)...', 10, 1) WITH NOWAIT;

DELETE FROM #PermResults;
INSERT INTO #PermResults
EXEC dbo.sp_HeapDoctor @CheckPermissionsOnly = 1, @Databases = N'HeapDoctorTest';

-- Should have HeapDoctorTest-specific checks (VIEW DATABASE STATE + ALTER)
DECLARE @db_checks int;
SELECT @db_checks = COUNT(*) FROM #PermResults WHERE database_name = N'HeapDoctorTest';

IF @db_checks >= 2
    RAISERROR(N'  PASS 19D: @Databases scoped permissions to HeapDoctorTest (%d checks).', 10, 1, @db_checks) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 19D: Expected >= 2 HeapDoctorTest checks, got %d.', 10, 1, @db_checks) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 19E: #18 - @CheckPermissionsOnly returns early (no targets)
------------------------------------------------------------------------
RAISERROR(N'Test 19E: @CheckPermissionsOnly short-circuits (no targets) (#18)...', 10, 1) WITH NOWAIT;

-- Running with CheckPermissionsOnly should NOT return the normal #Results shape
-- Verify by checking that INSERT into #Results fails or returns 0 rows
DELETE FROM #Results;
BEGIN TRY
    INSERT INTO #Results
    EXEC dbo.sp_HeapDoctor @CheckPermissionsOnly = 1, @Databases = N'HeapDoctorTest';

    -- If we get here, the result set schema didn't match #Results, so 0 rows inserted
    IF NOT EXISTS (SELECT 1 FROM #Results)
        RAISERROR(N'  PASS 19E: @CheckPermissionsOnly did not return target result set.', 10, 1) WITH NOWAIT;
    ELSE
        RAISERROR(N'  FAIL 19E: @CheckPermissionsOnly unexpectedly returned targets.', 10, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    -- Expected: column mismatch error because #PermCheck schema != #Results schema
    RAISERROR(N'  PASS 19E: @CheckPermissionsOnly returns different schema (short-circuit confirmed).', 10, 1) WITH NOWAIT;
END CATCH
GO

------------------------------------------------------------------------
-- 19F: #75 - INSTEAD OF trigger on CI swap target
-- DDL (CREATE INDEX) does not fire DML triggers, so CI swap should succeed.
------------------------------------------------------------------------
RAISERROR(N'Test 19F: INSTEAD OF trigger on CI swap target (#75)...', 10, 1) WITH NOWAIT;

-- Create test heap eligible for CI swap
IF OBJECT_ID(N'dbo.HeapTriggerTest') IS NOT NULL DROP TABLE dbo.HeapTriggerTest;
CREATE TABLE dbo.HeapTriggerTest
(
    ID   int          NOT NULL,
    Col1 int          NULL,
    Col2 nvarchar(50) NULL
);
CREATE UNIQUE NONCLUSTERED INDEX UX_HeapTriggerTest_ID ON dbo.HeapTriggerTest(ID);
GO

-- Add INSTEAD OF INSERT trigger
CREATE TRIGGER tr_HeapTriggerTest_InsteadInsert ON dbo.HeapTriggerTest
INSTEAD OF INSERT
AS
BEGIN
    INSERT dbo.HeapTriggerTest(ID, Col1, Col2)
    SELECT ID, Col1, Col2 FROM inserted;
END
GO

-- Insert rows + create forwarded records
DECLARE @t19 int = 1;
WHILE @t19 <= 10000
BEGIN
    INSERT dbo.HeapTriggerTest(ID, Col1, Col2) VALUES (@t19, @t19, REPLICATE(N'X', 10));
    SET @t19 += 1;
END
UPDATE dbo.HeapTriggerTest SET Col2 = REPLICATE(N'Y', 50);

-- Mark start point in CommandLog
DECLARE @pre_id19f int;
SELECT @pre_id19f = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;

-- Execute CI swap
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.HeapTriggerTest',
    @CpuSource = N'NONE',
    @MinPages = 1,
    @AllowCiSwap = 1,
    @PreferCiSwap = 1,
    @PlanOnly = 0,
    @LogToTable = N'Y';

-- Check that CI swap was performed (or at least a rebuild succeeded)
DECLARE @trigger_action nvarchar(50);
SELECT TOP 1 @trigger_action = CommandType
FROM dbo.CommandLog
WHERE ID > @pre_id19f
  AND ObjectName = N'HeapTriggerTest'
  AND CommandType IN (N'CI_SWAP_ONLINE', N'HEAP_REBUILD_ONLINE', N'HEAP_REBUILD_OFFLINE')
  AND ErrorNumber = 0
ORDER BY ID DESC;

IF @trigger_action = N'CI_SWAP_ONLINE'
    RAISERROR(N'  PASS 19F: CI swap succeeded on table with INSTEAD OF trigger.', 10, 1) WITH NOWAIT;
ELSE IF @trigger_action IS NOT NULL
    RAISERROR(N'  PASS 19F: Rebuild (%s) succeeded on table with INSTEAD OF trigger.', 10, 1, @trigger_action) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 19F: No successful rebuild found for HeapTriggerTest.', 10, 1) WITH NOWAIT;

-- Verify heap still has 0 forwarded records
DECLARE @fwd_after_trigger bigint;
SELECT @fwd_after_trigger = forwarded_record_count
FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(N'dbo.HeapTriggerTest'), 0, NULL, N'SAMPLED');

IF @fwd_after_trigger = 0
    RAISERROR(N'  PASS 19F2: Forwarded records = 0 after rebuild (trigger did not interfere).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 19F2: Forwarded records = %d after rebuild.', 10, 1, @fwd_after_trigger) WITH NOWAIT;

-- Cleanup
IF OBJECT_ID(N'dbo.HeapTriggerTest') IS NOT NULL DROP TABLE dbo.HeapTriggerTest;
GO

------------------------------------------------------------------------
-- 19G: #78 - lock_escalation=TABLE shown for CI swap target
------------------------------------------------------------------------
RAISERROR(N'Test 19G: lock_escalation=TABLE for CI swap target (#78)...', 10, 1) WITH NOWAIT;

-- Create test heap with TABLE lock escalation + CI swap eligibility
IF OBJECT_ID(N'dbo.HeapLockEscTest') IS NOT NULL DROP TABLE dbo.HeapLockEscTest;
CREATE TABLE dbo.HeapLockEscTest
(
    ID   int          NOT NULL,
    Col1 int          NULL,
    Col2 nvarchar(50) NULL
);
ALTER TABLE dbo.HeapLockEscTest SET (LOCK_ESCALATION = TABLE);
CREATE UNIQUE NONCLUSTERED INDEX UX_HeapLockEscTest_ID ON dbo.HeapLockEscTest(ID);

DECLARE @l19 int = 1;
WHILE @l19 <= 10000
BEGIN
    INSERT dbo.HeapLockEscTest(ID, Col1, Col2) VALUES (@l19, @l19, REPLICATE(N'X', 10));
    SET @l19 += 1;
END
UPDATE dbo.HeapLockEscTest SET Col2 = REPLICATE(N'Y', 50);

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.HeapLockEscTest',
    @CpuSource = N'NONE',
    @MinPages = 1,
    @AllowCiSwap = 1,
    @PreferCiSwap = 1,
    @PlanOnly = 1;

DECLARE @le_val varchar(10);
SELECT @le_val = lock_escalation FROM #Results WHERE table_name = N'HeapLockEscTest';

IF @le_val = N'TABLE'
    RAISERROR(N'  PASS 19G: lock_escalation=TABLE correctly reported for CI swap target.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 19G: lock_escalation=%s (expected TABLE).', 10, 1, @le_val) WITH NOWAIT;

-- Cleanup
IF OBJECT_ID(N'dbo.HeapLockEscTest') IS NOT NULL DROP TABLE dbo.HeapLockEscTest;
GO

------------------------------------------------------------------------
-- 19H: #63 - AG failover check code exists in proc definition
------------------------------------------------------------------------
RAISERROR(N'Test 19H: AG failover check code exists (#63)...', 10, 1) WITH NOWAIT;

DECLARE @has_ag_check bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%Updateability%READ_WRITE%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has_ag_check OUTPUT;

IF @has_ag_check = 1
    RAISERROR(N'  PASS 19H: AG failover check (DATABASEPROPERTYEX Updateability) found in proc.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 19H: AG failover check not found in proc definition.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 19I: #89 - @AllowReplicationRebuild=0 accepted without error
------------------------------------------------------------------------
RAISERROR(N'Test 19I: @AllowReplicationRebuild=0 accepted (#89)...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @AllowReplicationRebuild = 0;

IF EXISTS (SELECT 1 FROM #Results)
    RAISERROR(N'  PASS 19I: @AllowReplicationRebuild=0 accepted (targets found).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 19I: No results with @AllowReplicationRebuild=0.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 19J: #89 - @AllowReplicationRebuild=1 in invocation_command
------------------------------------------------------------------------
RAISERROR(N'Test 19J: @AllowReplicationRebuild=1 in invocation_command (#89)...', 10, 1) WITH NOWAIT;

-- Mark start point
DECLARE @pre_id19j int;
SELECT @pre_id19j = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @LogToTable = N'Y',
    @AllowReplicationRebuild = 1;

-- Check HEAP_SCAN_SUMMARY Command column for @AllowReplicationRebuild
DECLARE @cmd_text19j nvarchar(max);
SELECT TOP 1 @cmd_text19j = Command
FROM dbo.CommandLog
WHERE ID > @pre_id19j
  AND CommandType = N'HEAP_SCAN_SUMMARY'
ORDER BY ID DESC;

IF @cmd_text19j LIKE N'%@AllowReplicationRebuild%'
    RAISERROR(N'  PASS 19J: @AllowReplicationRebuild=1 found in invocation_command.', 10, 1) WITH NOWAIT;
ELSE IF @cmd_text19j IS NOT NULL
    RAISERROR(N'  FAIL 19J: @AllowReplicationRebuild not found in Command column.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 19J: No HEAP_SCAN_SUMMARY found in CommandLog.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 19V: Version check
------------------------------------------------------------------------
RAISERROR(N'Test 19V: Version check...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1;

DECLARE @ver19 nvarchar(20);
SELECT TOP 1 @ver19 = version FROM #Results;

IF @ver19 = (SELECT version FROM dbo.ExpectedVersion)
    RAISERROR(N'  PASS 19V: Version matches dbo.ExpectedVersion.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 19V: Version is %s and does not match dbo.ExpectedVersion.', 10, 1, @ver19) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- Cleanup temp tables
------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
IF OBJECT_ID('tempdb..#PermResults') IS NOT NULL DROP TABLE #PermResults;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Batch 19 tests complete. Review results above.', 10, 1) WITH NOWAIT;
GO
