SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;

SELECT TOP (0) * INTO #Results FROM dbo.ResultsTemplate;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor @Databases=N'HeapDoctorTest',@Tables=N'dbo.HeapA',
    @CpuSource='NONE',@PlanOnly=1,@LogToTable=N'N';
IF EXISTS (SELECT 1 FROM #Results r JOIN dbo.ExpectedVersion e ON e.version=r.version WHERE r.table_name=N'HeapA')
    RAISERROR(N'PASS 55A version: positive control captured HeapA at dbo.ExpectedVersion.',10,1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 55A version: positive control did not capture a version-matched HeapA.',10,1) WITH NOWAIT;
DROP TABLE #Results;

CREATE TABLE #Permissions(database_name sysname,permission_name nvarchar(128),granted nvarchar(1));
DECLARE @found int=NULL,@succeeded int=NULL,@failed int=NULL,@skipped int=NULL,
        @status varchar(10)=NULL,@status_message nvarchar(1000)=NULL;
INSERT INTO #Permissions
EXEC dbo.sp_HeapDoctor @CheckPermissionsOnly=1,@Databases=N'HeapDoctorTest, HeapDoctorCollationTest',
    @ExcludeDatabases=N'HeapDoctorCollationTest',
    @TargetsFound=@found OUTPUT,@Succeeded=@succeeded OUTPUT,@Failed=@failed OUTPUT,
    @Skipped=@skipped OUTPUT,@Status=@status OUTPUT,@StatusMessage=@status_message OUTPUT;
IF EXISTS (SELECT 1 FROM #Permissions WHERE database_name=N'HeapDoctorTest') AND NOT EXISTS (SELECT 1 FROM #Permissions WHERE database_name=N'HeapDoctorCollationTest')
    RAISERROR(N'PASS 55B: an existing database is excluded from a spaced multi-database selection.',10,1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 55B: the existing database exclusion or spaced database list was ignored.',10,1) WITH NOWAIT;

DELETE FROM #Permissions;
SET @found=NULL; SET @succeeded=NULL; SET @failed=NULL; SET @skipped=NULL;
SET @status=NULL; SET @status_message=NULL;
DECLARE @permission_error int=NULL;
BEGIN TRY
INSERT INTO #Permissions
EXEC dbo.sp_HeapDoctor @CheckPermissionsOnly=1,@Databases=N'NoSuchDatabase_1px3',
    @TargetsFound=@found OUTPUT,@Succeeded=@succeeded OUTPUT,@Failed=@failed OUTPUT,
    @Skipped=@skipped OUTPUT,@Status=@status OUTPUT,@StatusMessage=@status_message OUTPUT;
END TRY
BEGIN CATCH
    SET @permission_error=ERROR_NUMBER();
END CATCH;

IF @permission_error IS NOT NULL
    RAISERROR(N'FAIL 55C: permissions-only selection threw an unexpected error.',10,1) WITH NOWAIT;
ELSE IF @status='SUCCESS' AND @status_message LIKE N'Informational mode:%'
   AND NOT EXISTS (SELECT 1 FROM #Permissions WHERE database_name=N'NoSuchDatabase_1px3')
    RAISERROR(N'FAIL 55C: nonexistent database produced SUCCESS with no per-database permission row.',10,1) WITH NOWAIT;
ELSE
    RAISERROR(N'PASS 55C: nonexistent database was reported as an incomplete permission check.',10,1) WITH NOWAIT;

DELETE FROM #Permissions;
INSERT INTO #Permissions
EXEC dbo.sp_HeapDoctor @CheckPermissionsOnly=1,@Databases=NULL,
    @ExcludeDatabases=N'HeapDoctorTest';
IF EXISTS (SELECT 1 FROM #Permissions WHERE database_name=N'HeapDoctorCollationTest')
   AND NOT EXISTS (SELECT 1 FROM #Permissions WHERE database_name=N'HeapDoctorTest')
    RAISERROR(N'PASS 55D: NULL database selection uses user databases and applies exclusions.',10,1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 55D: NULL database selection did not match the regular scan selection.',10,1) WITH NOWAIT;

DELETE FROM #Permissions;
INSERT INTO #Permissions
EXEC dbo.sp_HeapDoctor @CheckPermissionsOnly=1,@Databases=N'HeapDoctorTest, HeapDoctorCollationTest';
IF EXISTS (SELECT 1 FROM #Permissions WHERE database_name=N'HeapDoctorTest')
   AND EXISTS (SELECT 1 FROM #Permissions WHERE database_name=N'HeapDoctorCollationTest')
    RAISERROR(N'PASS 55E: a spaced multi-database list checks every requested database.',10,1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 55E: a spaced multi-database list omitted a requested database.',10,1) WITH NOWAIT;

DELETE FROM #Permissions;
INSERT INTO #Permissions
EXEC dbo.sp_HeapDoctor @CheckPermissionsOnly=1,@Databases=N'ALL_DATABASES';
IF EXISTS (SELECT 1 FROM #Permissions WHERE database_name=N'master')
   AND EXISTS (SELECT 1 FROM #Permissions WHERE database_name=N'model')
   AND EXISTS (SELECT 1 FROM #Permissions WHERE database_name=N'msdb')
   AND NOT EXISTS (SELECT 1 FROM #Permissions WHERE database_name=N'tempdb')
    RAISERROR(N'PASS 55F: ALL_DATABASES checks system databases and excludes tempdb.',10,1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 55F: ALL_DATABASES does not match the regular database selection.',10,1) WITH NOWAIT;

DELETE FROM #Permissions;
INSERT INTO #Permissions
EXEC dbo.sp_HeapDoctor @CheckPermissionsOnly=1,@Databases=N'SYSTEM_DATABASES';
IF EXISTS (SELECT 1 FROM #Permissions WHERE database_name=N'master')
   AND EXISTS (SELECT 1 FROM #Permissions WHERE database_name=N'model')
   AND EXISTS (SELECT 1 FROM #Permissions WHERE database_name=N'msdb')
   AND NOT EXISTS (SELECT 1 FROM #Permissions WHERE database_name=N'tempdb')
    RAISERROR(N'PASS 55G: SYSTEM_DATABASES excludes tempdb.',10,1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 55G: SYSTEM_DATABASES does not match the regular database selection.',10,1) WITH NOWAIT;

