/* #228: ALL_DATABASES includes system and user databases. */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;
GO

SELECT TOP (0) * INTO #AllDatabases FROM dbo.ResultsTemplate;
SELECT TOP (0) * INTO #SystemDatabases FROM dbo.ResultsTemplate;
SELECT TOP (0) * INTO #UserDatabases FROM dbo.ResultsTemplate;
GO

INSERT INTO #AllDatabases
EXEC dbo.sp_HeapDoctor
    @Databases = N'ALL_DATABASES',
    @Tables = N'dbo.HeapA,dbo.MSreplication_options',
    @CpuSource = 'NONE',
    @PlanOnly = 1,
    @LogToTable = N'Y',
    @MinPages = 0,
    @MinForwardedPct = 0,
    @TopN = 1,
    @IncludeHealthyHeaps = 1;

DECLARE @all_summary xml =
(
    SELECT TOP (1) ExtendedInfo
    FROM dbo.CommandLog
    WHERE CommandType = N'HEAP_SCAN_SUMMARY'
    ORDER BY ID DESC
);
DECLARE
    @all_master bit = CASE WHEN @all_summary.exist(N'/ScanSummary/Databases/Database[@Name="master"]') = 1 THEN 1 ELSE 0 END,
    @all_model bit = CASE WHEN @all_summary.exist(N'/ScanSummary/Databases/Database[@Name="model"]') = 1 THEN 1 ELSE 0 END,
    @all_msdb bit = CASE WHEN @all_summary.exist(N'/ScanSummary/Databases/Database[@Name="msdb"]') = 1 THEN 1 ELSE 0 END,
    @all_version bit = CASE WHEN EXISTS
        (SELECT 1 FROM #AllDatabases AS r JOIN dbo.ExpectedVersion AS e ON e.version = r.version) THEN 1 ELSE 0 END,
    @all_current_db bit = CASE WHEN EXISTS
        (SELECT 1 FROM #AllDatabases WHERE database_name = N'HeapDoctorTest') THEN 1 ELSE 0 END;

IF @all_master = 1 AND @all_model = 1 AND @all_msdb = 1 AND @all_version = 1 AND @all_current_db = 1
    RAISERROR(N'PASS 52A: ALL_DATABASES includes all system databases and a version-matched user database.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @failure_52a nvarchar(500) = N'FAIL 52A: ALL_DATABASES master/model/msdb/version/user='
        + CONVERT(nvarchar(1), @all_master) + N'/' + CONVERT(nvarchar(1), @all_model) + N'/'
        + CONVERT(nvarchar(1), @all_msdb) + N'/' + CONVERT(nvarchar(1), @all_version) + N'/'
        + CONVERT(nvarchar(1), @all_current_db) + N'.';
    RAISERROR(N'%s', 10, 1, @failure_52a) WITH NOWAIT;
END
GO

DELETE FROM dbo.CommandLog;
TRUNCATE TABLE #SystemDatabases;
INSERT INTO #SystemDatabases
EXEC dbo.sp_HeapDoctor
    @Databases = N'SYSTEM_DATABASES',
    @Tables = N'dbo.HeapA,dbo.MSreplication_options',
    @CpuSource = 'NONE',
    @PlanOnly = 1,
    @LogToTable = N'Y',
    @MinPages = 0,
    @MinForwardedPct = 0,
    @TopN = 1,
    @IncludeHealthyHeaps = 1;

DECLARE @system_summary xml =
(
    SELECT TOP (1) ExtendedInfo
    FROM dbo.CommandLog
    WHERE CommandType = N'HEAP_SCAN_SUMMARY'
    ORDER BY ID DESC
);
DECLARE
    @system_master bit = CASE WHEN @system_summary.exist(N'/ScanSummary/Databases/Database[@Name="master"]') = 1 THEN 1 ELSE 0 END,
    @system_model bit = CASE WHEN @system_summary.exist(N'/ScanSummary/Databases/Database[@Name="model"]') = 1 THEN 1 ELSE 0 END,
    @system_msdb bit = CASE WHEN @system_summary.exist(N'/ScanSummary/Databases/Database[@Name="msdb"]') = 1 THEN 1 ELSE 0 END;

DELETE FROM dbo.CommandLog;
TRUNCATE TABLE #UserDatabases;
INSERT INTO #UserDatabases
EXEC dbo.sp_HeapDoctor
    @Databases = N'USER_DATABASES',
    @Tables = N'dbo.HeapA,dbo.MSreplication_options',
    @CpuSource = 'NONE',
    @PlanOnly = 1,
    @LogToTable = N'Y',
    @MinPages = 0,
    @MinForwardedPct = 0,
    @TopN = 1,
    @IncludeHealthyHeaps = 1;

DECLARE @user_summary xml =
(
    SELECT TOP (1) ExtendedInfo
    FROM dbo.CommandLog
    WHERE CommandType = N'HEAP_SCAN_SUMMARY'
    ORDER BY ID DESC
);
DECLARE
    @user_system bit = CASE WHEN @user_summary.exist(N'/ScanSummary/Databases/Database[@Name="master"]') = 1
                                  OR @user_summary.exist(N'/ScanSummary/Databases/Database[@Name="model"]') = 1
                                  OR @user_summary.exist(N'/ScanSummary/Databases/Database[@Name="msdb"]') = 1
                            THEN 1 ELSE 0 END,
    @user_current_db bit = CASE WHEN EXISTS
        (SELECT 1 FROM #UserDatabases WHERE database_name = N'HeapDoctorTest') THEN 1 ELSE 0 END;

IF @system_master = 1 AND @system_model = 1 AND @system_msdb = 1
AND @user_system = 0 AND @user_current_db = 1
    RAISERROR(N'PASS 52B: SYSTEM_DATABASES includes the system set; USER_DATABASES includes user databases only.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @failure_52b nvarchar(500) = N'FAIL 52B: SYSTEM_DATABASES master/model/msdb='
        + CONVERT(nvarchar(1), @system_master) + N'/' + CONVERT(nvarchar(1), @system_model) + N'/'
        + CONVERT(nvarchar(1), @system_msdb) + N'; USER_DATABASES system/current='
        + CONVERT(nvarchar(1), @user_system) + N'/' + CONVERT(nvarchar(1), @user_current_db) + N'.';
    RAISERROR(N'%s', 10, 1, @failure_52b) WITH NOWAIT;
END
GO
