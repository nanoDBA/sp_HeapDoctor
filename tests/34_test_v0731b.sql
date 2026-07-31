/*
sp_HeapDoctor Test Harness - v2026.07.31.2: @ScanMode = LIMITED rejected (#189)

Tests:
  34A - @ScanMode = LIMITED is rejected at validation
  34B - The rejection explains WHY (forwarded records are invisible in LIMITED)
  34C - The failure is a validation error, never error 515 from discovery
  34D - @ScanMode = SAMPLED still accepted
  34E - @ScanMode = DETAILED still accepted
  34F - @Help no longer offers LIMITED as a choice

  -- Version --
  34V - Version is 2026.07.31.2

WHY REJECT RATHER THAN SUPPORT: verified directly against
sys.dm_db_index_physical_stats -- in LIMITED mode record_count,
forwarded_record_count, ghost_record_count and avg_page_space_used_in_percent
all come back NULL; only page_count and avg_fragmentation_in_percent are
populated. This procedure ranks heaps BY forwarded records, so LIMITED cannot
serve its purpose. Previously the parameter was accepted and then failed deep
in discovery with error 515 (NOT NULL violation on #Heaps.forwarded_record_count),
presenting as "no heaps qualify".

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -U sa -P YourPassword -d HeapDoctorTest -i 34_test_v0731b.sql
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE [HeapDoctorTest];
GO

RAISERROR(N'=== Batch 34: v2026.07.31.2 (#189 LIMITED scan mode) ===', 10, 1) WITH NOWAIT;

/*#region 34A*/
------------------------------------------------------------------------
-- 34A/34B/34C: LIMITED is rejected, explains why, and never reaches discovery
------------------------------------------------------------------------
RAISERROR(N'Test 34A: @ScanMode = LIMITED is rejected (#189)...', 10, 1) WITH NOWAIT;

DECLARE @err34 integer = 0, @msg34 nvarchar(1000) = N'';
BEGIN TRY
    EXEC dbo.sp_HeapDoctor
        @Databases = N'HeapDoctorTest',
        @CpuSource = N'NONE',
        @PlanOnly  = 1,
        @ScanMode  = N'LIMITED';
END TRY
BEGIN CATCH
    SET @err34 = ERROR_NUMBER();
    SET @msg34 = LEFT(ERROR_MESSAGE(), 900);
END CATCH

IF @err34 <> 0
    RAISERROR(N'  PASS 34A: LIMITED rejected.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 34A: LIMITED was accepted.', 10, 1) WITH NOWAIT;

IF @msg34 LIKE N'%forwarded%'
    RAISERROR(N'  PASS 34B: the message explains that forwarded records are invisible in LIMITED.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @m34b nvarchar(1100) = N'  FAIL 34B: message does not explain why: ' + @msg34;
    RAISERROR(@m34b, 10, 1) WITH NOWAIT;
END

IF @err34 <> 515
    RAISERROR(N'  PASS 34C: not error 515 - rejected before discovery.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 34C: still failing with error 515 inside discovery.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 34D*/
------------------------------------------------------------------------
-- 34D / 34E: the modes that CAN see forwarded records still work
------------------------------------------------------------------------
RAISERROR(N'Test 34D: @ScanMode = SAMPLED still accepted (#189)...', 10, 1) WITH NOWAIT;

DECLARE @f34d integer, @e34d integer = 0;
BEGIN TRY
    EXEC dbo.sp_HeapDoctor
        @Databases = N'HeapDoctorTest', @CpuSource = N'NONE', @PlanOnly = 1,
        @ScanMode = N'SAMPLED', @TargetsFound = @f34d OUTPUT;
END TRY BEGIN CATCH SET @e34d = ERROR_NUMBER(); END CATCH

IF @e34d = 0 AND @f34d >= 1
    RAISERROR(N'  PASS 34D: SAMPLED accepted and found targets.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 34D: SAMPLED regressed.', 10, 1) WITH NOWAIT;
GO

RAISERROR(N'Test 34E: @ScanMode = DETAILED still accepted (#189)...', 10, 1) WITH NOWAIT;

DECLARE @f34e integer, @e34e integer = 0;
BEGIN TRY
    EXEC dbo.sp_HeapDoctor
        @Databases = N'HeapDoctorTest', @CpuSource = N'NONE', @PlanOnly = 1,
        @ScanMode = N'DETAILED', @TargetsFound = @f34e OUTPUT;
END TRY BEGIN CATCH SET @e34e = ERROR_NUMBER(); END CATCH

IF @e34e = 0 AND @f34e >= 1
    RAISERROR(N'  PASS 34E: DETAILED accepted and found targets.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 34E: DETAILED regressed.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 34F*/
------------------------------------------------------------------------
-- 34F: @Help must not advertise a mode the proc rejects
------------------------------------------------------------------------
RAISERROR(N'Test 34F: @Help no longer offers LIMITED (#189)...', 10, 1) WITH NOWAIT;

DECLARE @has34f bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%LIMITED: allocation pages only%''
    ) SET @out = 1;',
    N'@out bit OUTPUT', @out = @has34f OUTPUT;

IF @has34f = 0
    RAISERROR(N'  PASS 34F: @Help no longer advertises LIMITED.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 34F: @Help still offers LIMITED as a valid choice.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 34V*/
RAISERROR(N'Test 34V: Version check...', 10, 1) WITH NOWAIT;

SELECT * INTO #Results FROM dbo.ResultsTemplate WHERE 1 = 0;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor @Databases = N'HeapDoctorTest', @CpuSource = N'NONE', @PlanOnly = 1;

DECLARE @ver34 nvarchar(20);
SELECT TOP (1) @ver34 = version FROM #Results;

IF @ver34 = N'2026.07.31.2'
    RAISERROR(N'  PASS 34V: Version is 2026.07.31.2.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 34V: Version is %s (expected 2026.07.31.2).', 10, 1, @ver34) WITH NOWAIT;

IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
GO
/*#endregion*/

/*#region 34-SUMMARY*/
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 34 tests complete. Review results above. ===', 10, 1) WITH NOWAIT;
GO
/*#endregion*/
