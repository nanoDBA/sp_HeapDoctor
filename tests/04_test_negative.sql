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
    SET @Msg = N'PASS: Got expected error: ' + ERROR_MESSAGE();
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
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
    SET @Msg = N'PASS: Got expected error: ' + ERROR_MESSAGE();
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
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
    SET @Msg = N'PASS: Got expected error: ' + ERROR_MESSAGE();
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
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
    SET @Msg = N'PASS: Got expected error: ' + ERROR_MESSAGE();
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
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
RAISERROR(N'Negative tests complete. Review output above.', 10, 1) WITH NOWAIT;
GO
