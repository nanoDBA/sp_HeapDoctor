/* #237: a caller-caught error releases the procedure session applock. */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;
GO

SELECT * INTO #Results FROM dbo.ResultsTemplate WHERE 1 = 0;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.HeapA',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @LogToTable = N'N';
IF EXISTS (SELECT 1 FROM #Results AS r JOIN dbo.ExpectedVersion AS e ON e.version = r.version
           WHERE r.table_name = N'HeapA')
    RAISERROR(N'PASS 60A: positive control captured a version-matched plan.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 60A: positive control did not capture a version-matched plan.', 10, 1) WITH NOWAIT;
GO

DECLARE
    @caught bit = 0,
    @error_number integer = NULL,
    @error_message nvarchar(500) = NULL,
    @locks_before_cleanup integer = 0;
BEGIN TRY
    EXEC dbo.sp_HeapDoctor
        @Databases = N'NoSuchDatabase_ugbl',
        @CpuSource = N'NONE',
        @LogToTable = N'N';
END TRY
BEGIN CATCH
    SET @caught = 1;
    SET @error_number = ERROR_NUMBER();
    SET @error_message = LEFT(ERROR_MESSAGE(), 500);
END CATCH;

SELECT @locks_before_cleanup = COUNT_BIG(*)
FROM sys.dm_tran_locks
WHERE request_session_id = @@SPID
  AND resource_type = N'APPLICATION'
  AND request_status = N'GRANT';
IF @locks_before_cleanup > 0
    EXECUTE sys.sp_releaseapplock @Resource = N'sp_HeapDoctor', @LockOwner = N'Session';

IF @caught = 1 AND @locks_before_cleanup = 0
    RAISERROR(N'PASS 60B: caller-caught validation error released the session applock.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @report nvarchar(1000) = N'FAIL 60B: caught=' + CONVERT(nvarchar(1), @caught)
        + N' error=' + COALESCE(CONVERT(nvarchar(10), @error_number), N'NULL')
        + N' locks_before_cleanup=' + CONVERT(nvarchar(10), @locks_before_cleanup)
        + N' message=' + COALESCE(@error_message, N'none') + N'.';
    RAISERROR(N'%s', 10, 1, @report) WITH NOWAIT;
END;
GO
