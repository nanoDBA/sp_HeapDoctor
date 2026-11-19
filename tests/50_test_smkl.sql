/* #236: generated verification SQL resolves its target database from any context. */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;
GO

SELECT * INTO #Results FROM dbo.ResultsTemplate WHERE 1 = 0;
CREATE TABLE #Verification
(
    forwarded_record_count bigint NULL
);
GO

DECLARE
    @expected_version nvarchar(20) = (SELECT TOP (1) version FROM dbo.ExpectedVersion),
    @observed_version nvarchar(20) = NULL,
    @target_count int = 0,
    @verify_command nvarchar(max) = NULL,
    @verification_rows int = 0,
    @verification_error nvarchar(2048) = NULL;

INSERT #Results
EXEC master.dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.HeapA',
    @CpuSource = 'NONE',
    @PlanOnly = 1,
    @MinPages = 10,
    @MinForwardedPct = 0,
    @IncludeHealthyHeaps = 1;

SELECT
    @target_count = COUNT(*),
    @observed_version = MAX(version),
    @verify_command = MAX(verify_command)
FROM #Results
WHERE table_name = N'HeapA';

IF @target_count = 1 AND @observed_version = @expected_version AND @verify_command IS NOT NULL
    RAISERROR(N'PASS 50A: the version-matched plan includes HeapA verification SQL.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 50A: the version-matched plan did not include exactly one HeapA verification command.', 10, 1) WITH NOWAIT;

BEGIN TRY
    INSERT #Verification (forwarded_record_count)
    EXEC sys.sp_executesql @verify_command;
    SELECT @verification_rows = COUNT(*) FROM #Verification;
END TRY
BEGIN CATCH
    SET @verification_error = ERROR_MESSAGE();
END CATCH;

IF @verification_rows > 0 AND @verification_error IS NULL
    RAISERROR(N'PASS 50B: the verification command runs from HeapDoctorTest.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @failure_50b nvarchar(2048) = N'FAIL 50B: verification from HeapDoctorTest returned '
        + ISNULL(CONVERT(nvarchar(10), @verification_rows), N'NULL') + N' rows; '
        + ISNULL(@verification_error, N'no SQL error');
    RAISERROR(N'%s', 10, 1, @failure_50b) WITH NOWAIT;
END

TRUNCATE TABLE #Verification;
SET @verification_rows = 0;
SET @verification_error = NULL;
USE master;

BEGIN TRY
    INSERT #Verification (forwarded_record_count)
    EXEC sys.sp_executesql @verify_command;
    SELECT @verification_rows = COUNT(*) FROM #Verification;
END TRY
BEGIN CATCH
    SET @verification_error = ERROR_MESSAGE();
END CATCH;

IF @verification_rows > 0 AND @verification_error IS NULL
    RAISERROR(N'PASS 50C: the verification command runs from master.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @failure_50c nvarchar(2048) = N'FAIL 50C: verification from master returned '
        + ISNULL(CONVERT(nvarchar(10), @verification_rows), N'NULL') + N' rows; '
        + ISNULL(@verification_error, N'no SQL error');
    RAISERROR(N'%s', 10, 1, @failure_50c) WITH NOWAIT;
END
GO
