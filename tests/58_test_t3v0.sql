/* #221: parallel queue claims preserve disabled-index safety inputs. */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;
GO

SELECT TOP (0) * INTO #Plan FROM dbo.ResultsTemplate;
INSERT INTO #Plan
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.HeapB',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @LogToTable = N'Y',
    @IncludeHealthyHeaps = 1,
    @MinPages = 10,
    @MinForwardedPct = 0,
    @AllowCiSwap = 1,
    @PreferCiSwap = 1,
    @OnlinePreference = N'ON';

DECLARE @run_id uniqueidentifier, @planned_action varchar(32), @version_match bit = 0;
SELECT TOP (1)
    @run_id = ExtendedInfo.value(N'(/ScanSummary/RunID)[1]', N'uniqueidentifier')
FROM dbo.CommandLog WHERE CommandType = N'HEAP_SCAN_SUMMARY' ORDER BY ID DESC;
SELECT TOP (1)
    @planned_action = action_chosen,
    @version_match = CASE WHEN EXISTS
        (SELECT 1 FROM dbo.ExpectedVersion AS e WHERE e.version = p.version) THEN 1 ELSE 0 END
FROM #Plan AS p WHERE p.table_name = N'HeapB';
IF @planned_action = N'CI_SWAP_ONLINE' AND @version_match = 1 AND @run_id IS NOT NULL
    RAISERROR(N'PASS 58A: HeapB has a version-matched CI swap plan to resume.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 58A: expected a version-matched CI_SWAP_ONLINE plan and scan RunID.', 10, 1) WITH NOWAIT;
GO

ALTER INDEX UX_HeapB_ID ON dbo.HeapB DISABLE;
GO

DECLARE
    @succeeded int = NULL,
    @failed int = NULL,
    @skipped int = NULL,
    @resume_run_id uniqueidentifier,
    @rebuild_rows int = 0,
    @ci_swap_rows int = 0,
    @run_status varchar(10) = NULL;
SELECT TOP (1) @resume_run_id = ExtendedInfo.value(N'(/ScanSummary/RunID)[1]', N'uniqueidentifier')
FROM dbo.CommandLog WHERE CommandType = N'HEAP_SCAN_SUMMARY' ORDER BY ID DESC;
EXEC dbo.sp_HeapDoctor
    @ResumeRunID = @resume_run_id,
    @PlanOnly = 0,
    @LogToTable = N'Y',
    @HeapsInParallel = N'Y',
    @IncludeHealthyHeaps = 1,
    @MinPages = 10,
    @MinForwardedPct = 0,
    @AllowCiSwap = 1,
    @PreferCiSwap = 1,
    @OnlinePreference = N'ON',
    @Succeeded = @succeeded OUTPUT,
    @Failed = @failed OUTPUT,
    @Skipped = @skipped OUTPUT,
    @Status = @run_status OUTPUT;

SELECT
    @rebuild_rows = SUM(CASE WHEN CommandType = N'HEAP_REBUILD_ONLINE' THEN 1 ELSE 0 END),
    @ci_swap_rows = SUM(CASE WHEN CommandType LIKE N'CI_SWAP_%' THEN 1 ELSE 0 END)
FROM dbo.CommandLog
WHERE ObjectName = N'HeapB'
  AND CommandType IN (N'HEAP_REBUILD_ONLINE', N'CI_SWAP_ONLINE');
IF @succeeded = 1 AND ISNULL(@failed, 0) = 0 AND ISNULL(@skipped, 0) = 0
   AND @rebuild_rows = 1 AND ISNULL(@ci_swap_rows, 0) = 0
    RAISERROR(N'PASS 58B: the disabled key-source index fell back to a heap rebuild in parallel mode.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @failure nvarchar(300) = N'FAIL 58B: succeeded=' + COALESCE(CONVERT(nvarchar(12), @succeeded), N'NULL')
        + N' failed=' + COALESCE(CONVERT(nvarchar(12), @failed), N'NULL')
        + N' skipped=' + COALESCE(CONVERT(nvarchar(12), @skipped), N'NULL')
        + N' rebuild_rows=' + CONVERT(nvarchar(12), ISNULL(@rebuild_rows, 0))
        + N' ci_swap_rows=' + CONVERT(nvarchar(12), ISNULL(@ci_swap_rows, 0))
        + N' status=' + COALESCE(@run_status, N'NULL') + N'.';
    RAISERROR(N'%s', 10, 1, @failure) WITH NOWAIT;
END;
GO
