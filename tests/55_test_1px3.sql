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
EXEC dbo.sp_HeapDoctor @CheckPermissionsOnly=1,@Databases=N'HeapDoctorTest,NoSuchDatabase_1px3',
    @ExcludeDatabases=N'NoSuchDatabase_1px3',
    @TargetsFound=@found OUTPUT,@Succeeded=@succeeded OUTPUT,@Failed=@failed OUTPUT,
    @Skipped=@skipped OUTPUT,@Status=@status OUTPUT,@StatusMessage=@status_message OUTPUT;
IF EXISTS (SELECT 1 FROM #Permissions WHERE database_name=N'HeapDoctorTest') AND NOT EXISTS (SELECT 1 FROM #Permissions WHERE database_name=N'NoSuchDatabase_1px3')
    RAISERROR(N'PASS 55B positive selection: HeapDoctorTest has permission rows.',10,1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 55B positive selection: HeapDoctorTest was not checked.',10,1) WITH NOWAIT;

DELETE FROM #Permissions;
SET @found=NULL; SET @succeeded=NULL; SET @failed=NULL; SET @skipped=NULL;
SET @status=NULL; SET @status_message=NULL;
INSERT INTO #Permissions
EXEC dbo.sp_HeapDoctor @CheckPermissionsOnly=1,@Databases=N'NoSuchDatabase_1px3',
    @TargetsFound=@found OUTPUT,@Succeeded=@succeeded OUTPUT,@Failed=@failed OUTPUT,
    @Skipped=@skipped OUTPUT,@Status=@status OUTPUT,@StatusMessage=@status_message OUTPUT;

IF @status='SUCCESS' AND @status_message LIKE N'Informational mode:%'
   AND NOT EXISTS (SELECT 1 FROM #Permissions WHERE database_name=N'NoSuchDatabase_1px3')
    RAISERROR(N'FAIL 55C: nonexistent database produced SUCCESS with no per-database permission row.',10,1) WITH NOWAIT;
ELSE
    RAISERROR(N'PASS 55C: nonexistent database was reported as an incomplete permission check.',10,1) WITH NOWAIT;

