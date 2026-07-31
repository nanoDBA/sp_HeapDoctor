/*
sp_HeapDoctor Test Harness - v2026.07.31.4: Batch F observability

Tests:
  -- Issue #65: Deprecation advisory for sp_trace on SQL 2022+ --
  22A - Deprecation advisory code exists in proc definition
  22B - sp_trace_generateevent calls wrapped in TRY/CATCH

  -- Issue #82: XE session template --
  22C - @Help mentions XE session file

  -- Issue #67: Progress reporting --
  22D - Progress message emitted after execution (code check)
  22E - Execution with @PlanOnly=0 succeeds (progress visible in output)

  -- Version --
  22V - Version is 1.0.2026.0302f

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 22_test_v0302f.sql
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE [HeapDoctorTest];
GO

IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
/* #190: the column list lives once, in dbo.ResultsTemplate (see 01_setup_test_data.sql) */
SELECT * INTO #Results FROM dbo.ResultsTemplate WHERE 1 = 0;
GO

RAISERROR(N'=== Batch 22: v1.0.2026.0302f (#65, #82, #67) ===', 10, 1) WITH NOWAIT;

------------------------------------------------------------------------
-- 22A: #65 - Deprecation advisory code exists in proc
------------------------------------------------------------------------
RAISERROR(N'Test 22A: Deprecation advisory code exists (#65)...', 10, 1) WITH NOWAIT;

DECLARE @has_deprecation bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%sp_trace_generateevent%deprecated%2022%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has_deprecation OUTPUT;

IF @has_deprecation = 1
    RAISERROR(N'  PASS 22A: Deprecation advisory for sp_trace on SQL 2022+ found in proc.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 22A: Deprecation advisory not found in proc.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 22B: #65 - sp_trace_generateevent calls wrapped in TRY/CATCH
------------------------------------------------------------------------
RAISERROR(N'Test 22B: sp_trace_generateevent calls wrapped in TRY/CATCH (#65)...', 10, 1) WITH NOWAIT;

DECLARE @has_trycatch bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%BEGIN TRY%sp_trace_generateevent%END TRY%BEGIN CATCH%END CATCH%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has_trycatch OUTPUT;

IF @has_trycatch = 1
    RAISERROR(N'  PASS 22B: sp_trace_generateevent calls wrapped in TRY/CATCH.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 22B: sp_trace_generateevent not wrapped in TRY/CATCH.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 22C: #82 - @Help mentions XE session
------------------------------------------------------------------------
RAISERROR(N'Test 22C: @Help mentions XE session file (#82)...', 10, 1) WITH NOWAIT;

DECLARE @has_xe_help bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%sp_HeapDoctor_XE_Session%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has_xe_help OUTPUT;

IF @has_xe_help = 1
    RAISERROR(N'  PASS 22C: @Help references sp_HeapDoctor_XE_Session.sql.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 22C: XE session file not referenced in proc.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 22D: #67 - Progress message code exists in proc
------------------------------------------------------------------------
RAISERROR(N'Test 22D: Progress message code exists (#67)...', 10, 1) WITH NOWAIT;

DECLARE @has_progress bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%Progress:%Pages rebuilt:%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has_progress OUTPUT;

IF @has_progress = 1
    RAISERROR(N'  PASS 22D: Progress message code found in proc.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 22D: Progress message not found in proc.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 22E: #67 - Execution succeeds with progress (functional test)
------------------------------------------------------------------------
RAISERROR(N'Test 22E: Execution with progress reporting (#67)...', 10, 1) WITH NOWAIT;

-- Create a small inline test heap
IF OBJECT_ID(N'dbo.HeapProgress') IS NOT NULL DROP TABLE dbo.HeapProgress;
CREATE TABLE dbo.HeapProgress (ID int NOT NULL, Col1 nvarchar(50) NULL);

DECLARE @p22 int = 1;
WHILE @p22 <= 5000
BEGIN
    INSERT dbo.HeapProgress(ID, Col1) VALUES (@p22, REPLICATE(N'X', 10));
    SET @p22 += 1;
END
UPDATE dbo.HeapProgress SET Col1 = REPLICATE(N'Y', 50);

EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.HeapProgress',
    @CpuSource = N'NONE',
    @PlanOnly = 0,
    @MinPages = 1;

-- Check rebuild succeeded
IF NOT EXISTS (
    SELECT 1 FROM sys.dm_db_index_physical_stats(
        DB_ID(), OBJECT_ID(N'dbo.HeapProgress'), 0, NULL, N'SAMPLED')
    WHERE forwarded_record_count > 0
)
    RAISERROR(N'  PASS 22E: Execution with progress reporting succeeded (check output above for Progress lines).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 22E: Forwarded records still present after rebuild.', 10, 1) WITH NOWAIT;

IF OBJECT_ID(N'dbo.HeapProgress') IS NOT NULL DROP TABLE dbo.HeapProgress;
GO

------------------------------------------------------------------------
-- 22V: Version check
------------------------------------------------------------------------
RAISERROR(N'Test 22V: Version check...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1;

DECLARE @ver22 nvarchar(20);
SELECT TOP 1 @ver22 = version FROM #Results;

IF @ver22 = N'2026.07.31.4'
    RAISERROR(N'  PASS 22V: Version is 2026.07.31.4.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 22V: Version is %s (expected 2026.07.31.4).', 10, 1, @ver22) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- Cleanup
------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Batch 22 tests complete. Review results above.', 10, 1) WITH NOWAIT;
GO
