/* #224: NULL @TopN means no per-database limit and is logged as a literal. */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;
GO

SELECT TOP (0) * INTO #Results FROM dbo.ResultsTemplate;
GO

INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.HeapA',
    @CpuSource = 'NONE',
    @PlanOnly = 1,
    @LogToTable = N'N',
    @MinPages = 10,
    @MinForwardedPct = 0,
    @IncludeHealthyHeaps = 1,
    @TopN = 25;

IF EXISTS
(
    SELECT 1
    FROM #Results AS r
    JOIN dbo.ExpectedVersion AS e ON e.version = r.version
    WHERE r.table_name = N'HeapA'
)
    RAISERROR(N'PASS 51A: the positive control captured HeapA at dbo.ExpectedVersion.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 51A: the positive control did not capture a version-matched HeapA.', 10, 1) WITH NOWAIT;
GO

DELETE FROM dbo.CommandLog;
GO

DECLARE
    @return_code int = NULL,
    @targets_found int = NULL,
    @succeeded int = NULL,
    @failed int = NULL,
    @skipped int = NULL,
    @status varchar(10) = NULL,
    @status_message nvarchar(1000) = NULL,
    @call_returned bit = 0,
    @call_caught bit = 0,
    @summary_rows int = 0,
    @summary_command nvarchar(max) = NULL,
    @summary_version nvarchar(20) = NULL,
    @application_locks int = 0;

BEGIN TRY
    EXEC @return_code = dbo.sp_HeapDoctor
        @Databases = N'HeapDoctorTest',
        @TopN = NULL,
        @CpuSource = 'NONE',
        @LogToTable = N'Y',
        @TargetsFound = @targets_found OUTPUT,
        @Succeeded = @succeeded OUTPUT,
        @Failed = @failed OUTPUT,
        @Skipped = @skipped OUTPUT,
        @Status = @status OUTPUT,
        @StatusMessage = @status_message OUTPUT;
    SET @call_returned = 1;
END TRY
BEGIN CATCH
    SET @call_caught = 1;
    DECLARE @caught_number int = ERROR_NUMBER(), @caught_message nvarchar(2048) = ERROR_MESSAGE();
    RAISERROR(N'51B caught procedure exception: Msg %d: %s', 10, 1, @caught_number, @caught_message) WITH NOWAIT;
END CATCH;

SELECT
    @summary_rows = COUNT(*),
    @summary_command = MAX(Command),
    @summary_version = MAX(ExtendedInfo.value(N'(/ScanSummary/Version/text())[1]', N'nvarchar(20)'))
FROM dbo.CommandLog
WHERE CommandType = N'HEAP_SCAN_SUMMARY';

SELECT @application_locks = COUNT(*)
FROM sys.dm_tran_locks
WHERE request_session_id = @@SPID
  AND resource_type = N'APPLICATION'
  AND request_status = N'GRANT';

IF @application_locks > 0
    EXECUTE sys.sp_releaseapplock @Resource = N'sp_HeapDoctor', @LockOwner = N'Session';

IF @call_returned = 1
AND @call_caught = 0
AND @return_code = 0
AND @targets_found IS NOT NULL
AND @status IS NOT NULL
AND @succeeded IS NOT NULL
AND @failed IS NOT NULL
AND @skipped IS NOT NULL
AND @summary_rows = 1
AND @summary_version = (SELECT TOP (1) version FROM dbo.ExpectedVersion)
AND @summary_command LIKE N'%@TopN = NULL%'
AND @application_locks = 0
    RAISERROR(N'PASS 51B: NULL @TopN completed, populated outputs, logged NULL, and released its session lock.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @failure_51b nvarchar(1800) = N'FAIL 51B: returned=' + CONVERT(nvarchar(1), @call_returned)
        + N' caught=' + CONVERT(nvarchar(1), @call_caught)
        + N' rc=' + ISNULL(CONVERT(nvarchar(10), @return_code), N'NULL')
        + N' found=' + ISNULL(CONVERT(nvarchar(10), @targets_found), N'NULL')
        + N' status=' + ISNULL(@status, N'NULL')
        + N' outputs=' + ISNULL(CONVERT(nvarchar(10), @succeeded), N'NULL') + N'/'
        + ISNULL(CONVERT(nvarchar(10), @failed), N'NULL') + N'/'
        + ISNULL(CONVERT(nvarchar(10), @skipped), N'NULL')
        + N' summaries=' + CONVERT(nvarchar(10), @summary_rows)
        + N' command=' + ISNULL(LEFT(@summary_command, 180), N'NULL')
        + N' version=' + ISNULL(@summary_version, N'NULL')
        + N' application_locks=' + CONVERT(nvarchar(10), @application_locks) + N'.';
    RAISERROR(N'%s', 10, 1, @failure_51b) WITH NOWAIT;
END
GO

