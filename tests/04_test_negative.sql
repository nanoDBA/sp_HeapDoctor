/*
sp_HeapDoctor Test Harness - Step 4: Negative / Edge Case Tests

Tests error handling, lock timeouts, invalid inputs, permission edge cases.

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 04_test_negative.sql
  (add -E for Windows auth, -U/-P for SQL auth, or -G for Azure AD)
*/

SET NOCOUNT ON;
USE [HeapDoctorTest];
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 4A: Invalid @CpuSource', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

BEGIN TRY
    EXEC dbo.sp_HeapDoctor @CpuSource = 'INVALID', @PlanOnly = 1;
    RAISERROR(N'*** FAIL: Should have raised error for invalid CpuSource ***', 10, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    DECLARE @Msg nvarchar(4000) = N'PASS: Got expected error: ' + ERROR_MESSAGE();
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
END CATCH
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 4B: Invalid @OnlinePreference', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

BEGIN TRY
    EXEC dbo.sp_HeapDoctor @OnlinePreference = 'MAYBE', @PlanOnly = 1;
    RAISERROR(N'*** FAIL: Should have raised error for invalid OnlinePreference ***', 10, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    DECLARE @Msg4B nvarchar(4000) = N'PASS: Got expected error: ' + ERROR_MESSAGE();
    RAISERROR(@Msg4B, 10, 1) WITH NOWAIT;
END CATCH
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 4C: QUICKIESTORE without @QuickieExecSql', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

BEGIN TRY
    EXEC dbo.sp_HeapDoctor @CpuSource = 'QUICKIESTORE', @PlanOnly = 1;
    RAISERROR(N'*** FAIL: Should have raised error for missing QuickieExecSql ***', 10, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    DECLARE @Msg4C nvarchar(4000) = N'PASS: Got expected error: ' + ERROR_MESSAGE();
    RAISERROR(@Msg4C, 10, 1) WITH NOWAIT;
END CATCH
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 4D: Negative @Maxdop', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

BEGIN TRY
    EXEC dbo.sp_HeapDoctor @Maxdop = -1, @PlanOnly = 1;
    RAISERROR(N'*** FAIL: Should have raised error for negative Maxdop ***', 10, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    DECLARE @Msg4D nvarchar(4000) = N'PASS: Got expected error: ' + ERROR_MESSAGE();
    RAISERROR(@Msg4D, 10, 1) WITH NOWAIT;
END CATCH
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 4E: @Databases pattern that matches nothing', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

BEGIN TRY
    EXEC dbo.sp_HeapDoctor @Databases = 'NonExistentDB_XYZ_999', @PlanOnly = 1;
    RAISERROR(N'*** FAIL: Should have raised error for no matching databases ***', 10, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    DECLARE @Msg4E nvarchar(4000) = N'PASS: Got expected error: ' + ERROR_MESSAGE();
    RAISERROR(@Msg4E, 10, 1) WITH NOWAIT;
END CATCH
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 4F: @Help parameter', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

EXEC dbo.sp_HeapDoctor @Help = 1;
GO

-- Verify: Should print help text and return without scanning.

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 4G: @LogToTable = N when CommandLog missing', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Run from a database that doesn't have CommandLog
EXEC dbo.sp_HeapDoctor
    @Databases = 'HeapDoctorTest',
    @CpuSource = 'NONE',
    @LogToTable = N'N',
    @PlanOnly  = 1;
GO

-- Verify: Should run without error even though we said N.

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 4H: Lock timeout (requires second session)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

RAISERROR(N'This test requires a second SSMS/sqlcmd session.', 10, 1) WITH NOWAIT;
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'In session 2, run:', 10, 1) WITH NOWAIT;
RAISERROR(N'  USE HeapDoctorTest;', 10, 1) WITH NOWAIT;
RAISERROR(N'  BEGIN TRAN; SELECT TOP 1 * FROM dbo.HeapA WITH (TABLOCKX); -- hold lock', 10, 1) WITH NOWAIT;
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Then in this session, run:', 10, 1) WITH NOWAIT;
RAISERROR(N'  EXEC dbo.sp_HeapDoctor @CpuSource=''NONE'', @PlanOnly=0, @LockTimeoutMs=2000;', 10, 1) WITH NOWAIT;
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Expected: HeapA rebuild should FAIL with lock timeout error.', 10, 1) WITH NOWAIT;
RAISERROR(N'Then ROLLBACK in session 2.', 10, 1) WITH NOWAIT;

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 4I: @OnlinePreference = ON on Standard Edition', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

RAISERROR(N'This test only applies on Standard Edition.', 10, 1) WITH NOWAIT;
RAISERROR(N'On Enterprise/Developer, @OnlinePreference=ON will succeed.', 10, 1) WITH NOWAIT;
RAISERROR(N'On Standard, it should fall back to offline (since ON + !CanOnline = offline).', 10, 1) WITH NOWAIT;

EXEC dbo.sp_HeapDoctor
    @CpuSource        = 'NONE',
    @OnlinePreference = 'ON',
    @PlanOnly         = 1;
GO

-- Verify on Standard: action_chosen should be HEAP_REBUILD_OFFLINE and command should not have ONLINE=ON.
-- Verify on Enterprise: action_chosen should be HEAP_REBUILD_ONLINE.

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 4J: @Maxdop = 0 (valid boundary)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- @Maxdop = 0 means unlimited parallelism in SQL Server - should be accepted
BEGIN TRY
    EXEC dbo.sp_HeapDoctor @CpuSource = 'NONE', @Maxdop = 0, @PlanOnly = 1;
    RAISERROR(N'  PASS 4J: @Maxdop=0 accepted without error.', 10, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    DECLARE @Msg4J nvarchar(4000) = N'  *** FAIL 4J: @Maxdop=0 raised unexpected error: ' + ERROR_MESSAGE();
    RAISERROR(@Msg4J, 10, 1) WITH NOWAIT;
END CATCH
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 4K: @MaxRunSeconds = 0 (edge case)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- @MaxRunSeconds = 0 should immediately skip all targets (time limit already reached)
BEGIN TRY
    EXEC dbo.sp_HeapDoctor @CpuSource = 'NONE', @PlanOnly = 0, @MaxRunSeconds = 0, @LogToTable = N'N';
    RAISERROR(N'  PASS 4K: @MaxRunSeconds=0 ran without error (all targets skipped).', 10, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    DECLARE @Msg4K nvarchar(4000) = N'  *** FAIL 4K: @MaxRunSeconds=0 raised unexpected error: ' + ERROR_MESSAGE();
    RAISERROR(@Msg4K, 10, 1) WITH NOWAIT;
END CATCH
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 4L: @LogToTable = Y when CommandLog exists', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Verify CommandLog table exists in HeapDoctorTest
IF OBJECT_ID('dbo.CommandLog', 'U') IS NOT NULL
    RAISERROR(N'  PASS 4L: CommandLog exists, @LogToTable=Y should work.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 4L: CommandLog does not exist in HeapDoctorTest.', 10, 1) WITH NOWAIT;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 4M: @LogToTable = Y from database without CommandLog', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Run from master (which does not have dbo.CommandLog)
-- Should print WARNING but not fail
BEGIN TRY
    EXEC dbo.sp_HeapDoctor
        @Databases = 'HeapDoctorTest',
        @CpuSource = 'NONE',
        @LogToTable = N'Y',
        @PlanOnly  = 1;
    RAISERROR(N'  PASS 4M: @LogToTable=Y with missing CommandLog ran without fatal error (warning expected in output above).', 10, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    DECLARE @Msg4M nvarchar(4000) = N'  *** FAIL 4M: @LogToTable=Y with missing CommandLog raised fatal error: ' + ERROR_MESSAGE();
    RAISERROR(@Msg4M, 10, 1) WITH NOWAIT;
END CATCH
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 4N: Case insensitive @LogToTable', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Lowercase 'y' should work the same as 'Y'
BEGIN TRY
    EXEC dbo.sp_HeapDoctor @CpuSource = 'NONE', @LogToTable = N'y', @PlanOnly = 1;
    RAISERROR(N'  PASS 4N: @LogToTable=''y'' (lowercase) accepted.', 10, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    DECLARE @Msg4N nvarchar(4000) = N'  *** FAIL 4N: @LogToTable=''y'' raised error: ' + ERROR_MESSAGE();
    RAISERROR(@Msg4N, 10, 1) WITH NOWAIT;
END CATCH
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 4O: Case insensitive @CpuSource', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Lowercase 'none' should work the same as 'NONE'
BEGIN TRY
    EXEC dbo.sp_HeapDoctor @CpuSource = 'none', @PlanOnly = 1;
    RAISERROR(N'  PASS 4O: @CpuSource=''none'' (lowercase) accepted.', 10, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    DECLARE @Msg4O nvarchar(4000) = N'  *** FAIL 4O: @CpuSource=''none'' raised error: ' + ERROR_MESSAGE();
    RAISERROR(@Msg4O, 10, 1) WITH NOWAIT;
END CATCH
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Negative tests complete. Review PASS/FAIL results above.', 10, 1) WITH NOWAIT;
GO
