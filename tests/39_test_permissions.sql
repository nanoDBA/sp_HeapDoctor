/*
sp_HeapDoctor Test Harness - @CheckPermissionsOnly as a non-sysadmin caller (#196)

Tests:
  39A - A low-privilege caller gets at least one DENIED permission
  39B - ALTER TRACE (server level) is reported denied for that caller
  39C - sysadmin still sees everything granted (the check is not simply always-N)
  39D - The low-privilege fixture was cleaned up
  39V - Version matches dbo.ExpectedVersion

Why this file exists
--------------------
@CheckPermissionsOnly (#18) exists to say NO when a permission is missing. Every
previous test ran as sa, where HAS_PERMS_BY_NAME returns granted for everything,
so the assertions only checked the SHAPE of the output. An implementation that
unconditionally reported "granted" would have passed all of them -- the feature's
entire purpose was untested.

39A and 39B assert a DENIED result from a principal that genuinely lacks the
permission. 39C then asserts the opposite direction from sa, so a broken
implementation that always answers "N" cannot pass either. Together they pin the
check to the caller rather than to a constant.

Prerequisite: 01_setup_test_data.sql
Requires: sysadmin (CREATE LOGIN + IMPERSONATE).
*/

SET NOCOUNT ON;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 39: @CheckPermissionsOnly as a non-sysadmin caller (#196) ===', 10, 1) WITH NOWAIT;
RAISERROR(N'', 10, 1) WITH NOWAIT;
GO

/*#region 39-SETUP*/
------------------------------------------------------------------------
-- Build a principal that holds nothing beyond the ability to run the
-- procedure. CHECK_POLICY = OFF so the fixture does not depend on the host's
-- password policy.
------------------------------------------------------------------------
USE master;
GO

IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'heapdoctor_lowpriv')
BEGIN
    IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'heapdoctor_lowpriv')
        DROP USER heapdoctor_lowpriv;
    DROP LOGIN heapdoctor_lowpriv;
END
GO

CREATE LOGIN heapdoctor_lowpriv WITH PASSWORD = N'Lp#2026_HeapDoctor!', CHECK_POLICY = OFF;
GO
CREATE USER heapdoctor_lowpriv FOR LOGIN heapdoctor_lowpriv;
GO
/* EXECUTE on the procedure only -- deliberately nothing else. */
GRANT EXECUTE ON dbo.sp_HeapDoctor TO heapdoctor_lowpriv;
GO

USE HeapDoctorTest;
GO
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'heapdoctor_lowpriv')
    DROP USER heapdoctor_lowpriv;
GO
CREATE USER heapdoctor_lowpriv FOR LOGIN heapdoctor_lowpriv;
GO
/*#endregion*/

/*#region 39A-DENIED-FOR-LOWPRIV*/
------------------------------------------------------------------------
-- 39A: the low-privilege caller must get at least one 'N'.
--
-- This is the assertion that an always-granted implementation fails.
------------------------------------------------------------------------
RAISERROR(N'Test 39A: low-privilege caller sees a denied permission (#196)...', 10, 1) WITH NOWAIT;

IF OBJECT_ID('tempdb..#Perm39') IS NOT NULL DROP TABLE #Perm39;
CREATE TABLE #Perm39
(
    database_name   sysname       NOT NULL,
    permission_name nvarchar(128) NOT NULL,
    granted         nvarchar(1)   NOT NULL
);

DECLARE @impersonated bit = 0;
DECLARE @err39 nvarchar(4000) = NULL;

BEGIN TRY
    EXECUTE AS LOGIN = N'heapdoctor_lowpriv';
    SET @impersonated = 1;

    INSERT INTO #Perm39 (database_name, permission_name, granted)
    EXEC dbo.sp_HeapDoctor
        @CheckPermissionsOnly = 1,
        @Databases            = N'HeapDoctorTest';

    REVERT;
    SET @impersonated = 0;
END TRY
BEGIN CATCH
    SET @err39 = ERROR_MESSAGE();
    /* REVERT unconditionally: leaving the session impersonating would corrupt
       every test that follows in this file. */
    IF @impersonated = 1
    BEGIN
        REVERT;
        SET @impersonated = 0;
    END
END CATCH;

DECLARE @denied39 integer = (SELECT COUNT_BIG(*) FROM #Perm39 WHERE granted = N'N');
DECLARE @rows39   integer = (SELECT COUNT_BIG(*) FROM #Perm39);

IF @err39 IS NOT NULL
BEGIN
    DECLARE @m39a_e nvarchar(600) = N'  FAIL 39A: impersonated run errored: ' + @err39;
    RAISERROR(@m39a_e, 10, 1) WITH NOWAIT;
END
ELSE IF @rows39 = 0
    RAISERROR(N'  FAIL 39A: impersonated run returned no permission rows at all.', 10, 1) WITH NOWAIT;
ELSE IF @denied39 > 0
BEGIN
    DECLARE @m39a nvarchar(300) = N'  PASS 39A: low-privilege caller got ' + CONVERT(nvarchar(10), @denied39)
        + N' denied permission(s) out of ' + CONVERT(nvarchar(10), @rows39) + N' checked.';
    RAISERROR(@m39a, 10, 1) WITH NOWAIT;
END
ELSE
    RAISERROR(N'  FAIL 39A: every permission reported granted for a principal holding none. The check is not caller-sensitive.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 39B-ALTER-TRACE-DENIED*/
------------------------------------------------------------------------
-- 39B: ALTER TRACE is server-level and was never granted, so it must come back
-- denied specifically. Naming the permission stops 39A passing on some
-- unrelated 'N'.
------------------------------------------------------------------------
RAISERROR(N'Test 39B: ALTER TRACE reported denied for the low-privilege caller (#196)...', 10, 1) WITH NOWAIT;

IF EXISTS (SELECT 1 FROM #Perm39 WHERE permission_name = N'ALTER TRACE' AND granted = N'N')
    RAISERROR(N'  PASS 39B: ALTER TRACE correctly reported as denied.', 10, 1) WITH NOWAIT;
ELSE IF EXISTS (SELECT 1 FROM #Perm39 WHERE permission_name = N'ALTER TRACE')
    RAISERROR(N'  FAIL 39B: ALTER TRACE reported granted for a principal that was never granted it.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 39B: ALTER TRACE was not checked at all.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 39C-SYSADMIN-STILL-GRANTED*/
------------------------------------------------------------------------
-- 39C: the opposite direction. As sa every permission is held, so nothing may
-- be denied. Without this, an implementation that always answered 'N' would
-- satisfy 39A and 39B.
------------------------------------------------------------------------
RAISERROR(N'Test 39C: sysadmin still sees everything granted (#196)...', 10, 1) WITH NOWAIT;

IF OBJECT_ID('tempdb..#Perm39sa') IS NOT NULL DROP TABLE #Perm39sa;
CREATE TABLE #Perm39sa
(
    database_name   sysname       NOT NULL,
    permission_name nvarchar(128) NOT NULL,
    granted         nvarchar(1)   NOT NULL
);

INSERT INTO #Perm39sa (database_name, permission_name, granted)
EXEC dbo.sp_HeapDoctor
    @CheckPermissionsOnly = 1,
    @Databases            = N'HeapDoctorTest';

DECLARE @sa_denied integer = (SELECT COUNT_BIG(*) FROM #Perm39sa WHERE granted = N'N');
DECLARE @sa_rows   integer = (SELECT COUNT_BIG(*) FROM #Perm39sa);

IF @sa_rows > 0 AND @sa_denied = 0
BEGIN
    DECLARE @m39c nvarchar(300) = N'  PASS 39C: sysadmin sees all ' + CONVERT(nvarchar(10), @sa_rows)
        + N' permission(s) granted, so the denials in 39A are caller-specific.';
    RAISERROR(@m39c, 10, 1) WITH NOWAIT;
END
ELSE
BEGIN
    DECLARE @m39c_f nvarchar(300) = N'  FAIL 39C: sysadmin saw ' + CONVERT(nvarchar(10), @sa_denied)
        + N' denied of ' + CONVERT(nvarchar(10), @sa_rows) + N'; expected 0 denied and >0 checked.';
    RAISERROR(@m39c_f, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 39-CLEANUP*/
------------------------------------------------------------------------
-- 39D: the fixture must not outlive the test. A stray login on a shared rig is
-- exactly the kind of residue that makes later runs non-reproducible.
------------------------------------------------------------------------
RAISERROR(N'Test 39D: fixture cleanup...', 10, 1) WITH NOWAIT;

USE HeapDoctorTest;
GO
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'heapdoctor_lowpriv')
    DROP USER heapdoctor_lowpriv;
GO

USE master;
GO
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'heapdoctor_lowpriv')
    DROP USER heapdoctor_lowpriv;
GO
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'heapdoctor_lowpriv')
    DROP LOGIN heapdoctor_lowpriv;
GO

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'heapdoctor_lowpriv')
    RAISERROR(N'  PASS 39D: low-privilege login and users removed.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 39D: heapdoctor_lowpriv login still exists after cleanup.', 10, 1) WITH NOWAIT;
GO

USE HeapDoctorTest;
GO
/*#endregion*/

/*#region 39V-VERSION*/
RAISERROR(N'Test 39V: Version check...', 10, 1) WITH NOWAIT;

IF OBJECT_ID('tempdb..#R39v') IS NOT NULL DROP TABLE #R39v;
SELECT * INTO #R39v FROM dbo.ResultsTemplate WHERE 1 = 0;

INSERT INTO #R39v
EXEC dbo.sp_HeapDoctor @Databases = N'HeapDoctorTest', @CpuSource = N'NONE', @PlanOnly = 1;

DECLARE @ver39 nvarchar(20);
SELECT TOP (1) @ver39 = version FROM #R39v;

IF @ver39 = (SELECT version FROM dbo.ExpectedVersion)
    RAISERROR(N'  PASS 39V: Version matches dbo.ExpectedVersion (%s).', 10, 1, @ver39) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 39V: Version is %s and does not match dbo.ExpectedVersion.', 10, 1, @ver39) WITH NOWAIT;

IF OBJECT_ID('tempdb..#R39v') IS NOT NULL DROP TABLE #R39v;
GO
/*#endregion*/

/*#region 39-SUMMARY*/
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 39 tests complete. Review results above. ===', 10, 1) WITH NOWAIT;
GO
/*#endregion*/
