/* #233: large encrypted mappings can be revealed without loss. */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;
GO

DECLARE @i int = 1, @table_name sysname, @sql nvarchar(max);
WHILE @i <= 45
BEGIN
    SET @table_name = N'P2MapTarget_' + RIGHT(N'00' + CONVERT(nvarchar(10), @i), 2);
    SET @sql = N'CREATE TABLE dbo.' + QUOTENAME(@table_name) + N'(id int NOT NULL, pad varchar(1500) NOT NULL);'
        + N' INSERT dbo.' + QUOTENAME(@table_name) + N'(id,pad) VALUES (1,REPLICATE(''x'',1400));';
    EXEC sys.sp_executesql @sql;
    SET @i += 1;
END;
GO

SELECT TOP (0) * INTO #Results FROM dbo.ResultsTemplate;
DECLARE @run_error int = NULL;
BEGIN TRY
    INSERT INTO #Results
    EXEC dbo.sp_HeapDoctor
        @Databases = N'HeapDoctorTest',
        @Tables = N'dbo.P2MapTarget_%',
        @CpuSource = 'NONE',
        @PlanOnly = 1,
        @LogToTable = N'Y',
        @MinPages = 0,
        @MinForwardedPct = 0,
        @TopN = 100,
        @IncludeHealthyHeaps = 1,
        @ObfuscateKey = N'p2-map-key';
END TRY
BEGIN CATCH
    SET @run_error = ERROR_NUMBER();
END CATCH;

DECLARE
    @run_id uniqueidentifier,
    @mapping_chars int = 0,
    @version_match bit = 0,
    @result_count int = 0,
    @run_error_value int = @run_error,
    @reveal_error int = NULL,
    @revealed_targets int = 0,
    @held_locks int = 0;
SELECT TOP (1)
    @run_id = ExtendedInfo.value(N'(/ScanSummary/RunID)[1]', N'uniqueidentifier'),
    @mapping_chars = LEN(ExtendedInfo.value(N'(/ScanSummary/ObfuscatedMappingHex)[1]', N'nvarchar(max)'))
FROM dbo.CommandLog
WHERE CommandType = N'HEAP_SCAN_SUMMARY'
ORDER BY ID DESC;
SELECT @version_match = CASE WHEN EXISTS
    (SELECT 1 FROM #Results AS r JOIN dbo.ExpectedVersion AS e ON e.version = r.version)
    THEN 1 ELSE 0 END,
    @result_count = COUNT(*)
FROM #Results;

CREATE TABLE #Mapping
(
    pseudonym nvarchar(20),
    object_type varchar(10),
    real_name sysname
);
IF @run_id IS NOT NULL
BEGIN TRY
    INSERT INTO #Mapping
    EXEC dbo.sp_HeapDoctor @RevealKey = N'p2-map-key', @RevealRunID = @run_id;
END TRY
BEGIN CATCH
    SET @reveal_error = ERROR_NUMBER();
END CATCH;

SELECT @revealed_targets = COUNT(DISTINCT real_name)
FROM #Mapping
WHERE object_type = 'Table'
  AND real_name LIKE N'P2MapTarget[_]%';
SELECT @held_locks = COUNT(*)
FROM sys.dm_tran_locks
WHERE resource_type = N'APPLICATION'
  AND request_session_id = @@SPID;

IF @run_error_value IS NULL AND @version_match = 1 AND @result_count = 45 AND @run_id IS NOT NULL
   AND @mapping_chars > 8000 AND @reveal_error IS NULL
   AND @revealed_targets = 45 AND @held_locks = 0
    RAISERROR(N'PASS 53A: the large encrypted mapping round-tripped all 45 target names.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @failure nvarchar(500) = N'FAIL 53A: run=' + COALESCE(CONVERT(nvarchar(36), @run_id), N'NULL')
        + N' run_error=' + COALESCE(CONVERT(nvarchar(12), @run_error_value), N'NULL')
        + N' mapping_chars=' + CONVERT(nvarchar(12), @mapping_chars)
        + N' version_match=' + CONVERT(nvarchar(1), @version_match)
        + N' results=' + CONVERT(nvarchar(12), @result_count)
        + N' reveal_error=' + COALESCE(CONVERT(nvarchar(12), @reveal_error), N'NULL')
        + N' targets=' + CONVERT(nvarchar(12), @revealed_targets)
        + N' applocks=' + CONVERT(nvarchar(12), @held_locks) + N'.';
    RAISERROR(N'%s', 10, 1, @failure) WITH NOWAIT;
END;

IF @held_locks > 0
    EXEC sys.sp_releaseapplock @Resource = N'sp_HeapDoctor', @LockOwner = N'Session';
GO

DECLARE @i int = 1, @table_name sysname, @sql nvarchar(max);
WHILE @i <= 45
BEGIN
    SET @table_name = N'P2MapTarget_' + RIGHT(N'00' + CONVERT(nvarchar(10), @i), 2);
    SET @sql = N'DROP TABLE dbo.' + QUOTENAME(@table_name) + N';';
    EXEC sys.sp_executesql @sql;
    SET @i += 1;
END;
DELETE FROM dbo.CommandLog WHERE CommandType = N'HEAP_SCAN_SUMMARY';
GO
