/*
sp_HeapDoctor Test Harness - version source of truth (#191)

Tests:
  37A - dbo.ExpectedVersion holds exactly one well-formed CalVer value
  37B - The procedure's header comment agrees with its DECLARE @Version
  37V - Version matches dbo.ExpectedVersion

Nineteen test files used to hardcode the version and assert equality, so every
release meant sweeping all of them. That lapsed twice, and a stale value is not
inert: 14_test_resume embeds the version as a FUNCTIONAL INPUT, and when it
drifted the resume was rejected for version mismatch and never reached the
obfuscation guard test 14E is named for -- a vacuous pass.

Every file now reads dbo.ExpectedVersion, which 01_setup_test_data.sql derives
from the deployed procedure. A release edits zero test files.

That makes the per-file checks self-consistent by construction, so this file
carries the one comparison that can still fail: the procedure states its version
in TWO places -- the header comment and DECLARE @Version -- and those can drift
apart. 37B is what catches a half-finished version bump.

Prerequisite: 01_setup_test_data.sql (creates dbo.ExpectedVersion).
*/

SET NOCOUNT ON;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 37: version source of truth (#191) ===', 10, 1) WITH NOWAIT;
RAISERROR(N'', 10, 1) WITH NOWAIT;
GO

/*#region 37A-EXPECTEDVERSION-POPULATED*/
------------------------------------------------------------------------
-- 37A: dbo.ExpectedVersion holds exactly one well-formed CalVer value.
--
-- Every version assertion in the suite reads this table. If it were empty the
-- comparisons would go NULL and quietly stop asserting, so this guards the
-- guard.
------------------------------------------------------------------------
RAISERROR(N'Test 37A: dbo.ExpectedVersion is populated and well-formed...', 10, 1) WITH NOWAIT;

DECLARE @row_count integer = (SELECT COUNT_BIG(*) FROM dbo.ExpectedVersion);
DECLARE @ver37a nvarchar(20) = (SELECT TOP (1) version FROM dbo.ExpectedVersion);

IF @row_count = 1
   AND @ver37a LIKE N'[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]%'
BEGIN
    DECLARE @msg37a nvarchar(200) = N'  PASS 37A: dbo.ExpectedVersion holds one CalVer value (' + @ver37a + N').';
    RAISERROR(@msg37a, 10, 1) WITH NOWAIT;
END
ELSE
BEGIN
    DECLARE @msg37a_f nvarchar(300) = N'  FAIL 37A: expected exactly one CalVer row, found '
        + CONVERT(nvarchar(10), @row_count) + N' row(s), value '
        + ISNULL(N'''' + @ver37a + N'''', N'NULL') + N'.';
    RAISERROR(@msg37a_f, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 37B-HEADER-MATCHES-DECLARE*/
------------------------------------------------------------------------
-- 37B: the header comment agrees with DECLARE @Version.
--
-- The procedure carries its version twice: "Version:    X" in the header block
-- and DECLARE @Version = N'X'. dbo.ExpectedVersion is read from the DECLARE, so
-- this is the one version comparison in the suite that is not self-referential.
-- A bump applied to one and not the other fails here.
------------------------------------------------------------------------
RAISERROR(N'Test 37B: header comment matches DECLARE @Version...', 10, 1) WITH NOWAIT;

DECLARE @def nvarchar(max);

/* sp_ prefixed procedures resolve to master from any database. Fall back to the
   current database so a locally-deployed copy still works. */
SELECT @def = definition
FROM   master.sys.sql_modules
WHERE  object_id = OBJECT_ID(N'master.dbo.sp_HeapDoctor');

IF @def IS NULL
    SELECT @def = definition
    FROM   sys.sql_modules
    WHERE  object_id = OBJECT_ID(N'dbo.sp_HeapDoctor');

DECLARE @hdr_pos integer = CHARINDEX(N'Version:', ISNULL(@def, N''));
DECLARE @hdr_ver nvarchar(40) = NULL;

IF @hdr_pos > 0
BEGIN
    /* The header reads "Version:    2026.07.31.4 (CalVer: ...)", so trim the
       padding and take everything up to the next space. */
    DECLARE @tail nvarchar(200) = LTRIM(SUBSTRING(@def, @hdr_pos + LEN(N'Version:'), 60));
    SET @hdr_ver = LEFT(@tail, CHARINDEX(N' ', @tail + N' ') - 1);
END

DECLARE @declared nvarchar(20) = (SELECT TOP (1) version FROM dbo.ExpectedVersion);

IF @hdr_ver IS NOT NULL AND @hdr_ver = @declared
BEGIN
    DECLARE @msg37b nvarchar(200) = N'  PASS 37B: header and DECLARE @Version agree (' + @declared + N').';
    RAISERROR(@msg37b, 10, 1) WITH NOWAIT;
END
ELSE
BEGIN
    DECLARE @msg37b_f nvarchar(300) = N'  FAIL 37B: header says '
        + ISNULL(N'''' + @hdr_ver + N'''', N'(not found)')
        + N' but DECLARE @Version says ''' + ISNULL(@declared, N'NULL') + N'''. A version bump was applied to only one of them.';
    RAISERROR(@msg37b_f, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 37V-VERSION*/
------------------------------------------------------------------------
-- 37V: the running procedure reports the expected version.
------------------------------------------------------------------------
RAISERROR(N'Test 37V: Version check...', 10, 1) WITH NOWAIT;

IF OBJECT_ID('tempdb..#R37v') IS NOT NULL DROP TABLE #R37v;
SELECT * INTO #R37v FROM dbo.ResultsTemplate WHERE 1 = 0;

INSERT INTO #R37v
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly  = 1;

DECLARE @ver37 nvarchar(20);
SELECT TOP (1) @ver37 = version FROM #R37v;

IF @ver37 = (SELECT version FROM dbo.ExpectedVersion)
    RAISERROR(N'  PASS 37V: Version matches dbo.ExpectedVersion (%s).', 10, 1, @ver37) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 37V: Version is %s and does not match dbo.ExpectedVersion.', 10, 1, @ver37) WITH NOWAIT;

IF OBJECT_ID('tempdb..#R37v') IS NOT NULL DROP TABLE #R37v;
GO
/*#endregion*/

/*#region 37-SUMMARY*/
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 37 tests complete. Review results above. ===', 10, 1) WITH NOWAIT;
GO
/*#endregion*/
