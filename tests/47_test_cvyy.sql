/* Test 47 verifies post-rebuild forwarded-record verification on all heap allocation layouts. */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;
GO

/*#region 47A-VERSION*/
SELECT *
INTO #Results
FROM dbo.ResultsTemplate
WHERE 1 = 0;

INSERT INTO #Results
EXECUTE dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.HeapA',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @LogToTable = N'N';

IF EXISTS
(
    SELECT 1
    FROM #Results AS r
    INNER JOIN dbo.ExpectedVersion AS e
        ON e.version = r.version
    WHERE r.table_name = N'HeapA'
)
    RAISERROR(N'PASS 47A: plan-only version matches dbo.ExpectedVersion.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 47A: plan-only result did not match dbo.ExpectedVersion.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 47B-FIXTURES*/
CREATE PARTITION FUNCTION pf_CvyyTest (int)
AS RANGE RIGHT FOR VALUES (2);
GO

CREATE PARTITION SCHEME ps_CvyyTest
AS PARTITION pf_CvyyTest ALL TO ([PRIMARY]);
GO

CREATE TABLE dbo.CvyyPartitionedHeap
(
    ID int NOT NULL,
    PartKey int NOT NULL,
    Padding varchar(4000) NOT NULL,
    Trailer char(200) NOT NULL DEFAULT REPLICATE('T', 200)
) ON ps_CvyyTest(PartKey);

;WITH N AS
(
    SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
)
INSERT dbo.CvyyPartitionedHeap (ID, PartKey, Padding)
SELECT TOP (20000)
    n,
    CASE WHEN n <= 10000 THEN 1 ELSE 2 END,
    REPLICATE('A', 10)
FROM N;

UPDATE dbo.CvyyPartitionedHeap
SET Padding = REPLICATE('P', 3000);

CREATE TABLE dbo.CvyyOffrowHeap
(
    ID int NOT NULL,
    Padding varchar(4000) NOT NULL,
    Payload varchar(max) NULL
);

;WITH N AS
(
    SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
)
INSERT dbo.CvyyOffrowHeap (ID, Padding, Payload)
SELECT TOP (20000)
    n,
    REPLICATE('A', 10),
    NULL
FROM N;

UPDATE dbo.CvyyOffrowHeap
SET Padding = REPLICATE('O', 3000),
    Payload = REPLICATE(CONVERT(varchar(max), 'B'), 10000)
WHERE ID <= 15000;
GO

CREATE TRIGGER trg_CvyyAfterRebuild ON DATABASE
FOR ALTER_TABLE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @event xml = EVENTDATA(),
            @object_name sysname,
            @schema_name sysname;

    SET @object_name = @event.value('(/EVENT_INSTANCE/ObjectName)[1]', 'sysname');
    SET @schema_name = @event.value('(/EVENT_INSTANCE/SchemaName)[1]', 'sysname');

    IF @schema_name = N'dbo' AND @object_name = N'CvyyPartitionedHeap'
        UPDATE dbo.CvyyPartitionedHeap
        SET Padding = REPLICATE('X', 4000)
        WHERE PartKey IN (1, 2)
          AND Padding <> REPLICATE('X', 4000);

    IF @schema_name = N'dbo' AND @object_name = N'CvyyOffrowHeap'
        UPDATE dbo.CvyyOffrowHeap
        SET Padding = REPLICATE('Y', 4000)
        WHERE ID <= 15000
          AND Padding <> REPLICATE('Y', 4000);
END;
GO

DECLARE
    @partitioned_before bigint,
    @partitioned_before_1 bigint,
    @partitioned_before_2 bigint,
    @offrow_before bigint,
    @offrow_lob_pages bigint;

SELECT
    @partitioned_before = COALESCE(SUM(forwarded_record_count), 0),
    @partitioned_before_1 = COALESCE(SUM(CASE WHEN partition_number = 1 THEN forwarded_record_count END), 0),
    @partitioned_before_2 = COALESCE(SUM(CASE WHEN partition_number = 2 THEN forwarded_record_count END), 0)
FROM sys.dm_db_index_physical_stats
(
    DB_ID(), OBJECT_ID(N'dbo.CvyyPartitionedHeap'), 0, NULL, N'DETAILED'
)
WHERE index_id = 0
  AND alloc_unit_type_desc = N'IN_ROW_DATA';

SELECT @offrow_before = COALESCE(SUM(forwarded_record_count), 0)
FROM sys.dm_db_index_physical_stats
(
    DB_ID(), OBJECT_ID(N'dbo.CvyyOffrowHeap'), 0, NULL, N'DETAILED'
)
WHERE index_id = 0
  AND alloc_unit_type_desc = N'IN_ROW_DATA';

SELECT @offrow_lob_pages = COALESCE(SUM(page_count), 0)
FROM sys.dm_db_index_physical_stats
(
    DB_ID(), OBJECT_ID(N'dbo.CvyyOffrowHeap'), 0, NULL, N'DETAILED'
)
WHERE index_id = 0
  AND alloc_unit_type_desc = N'LOB_DATA';

IF @partitioned_before > 0
AND @partitioned_before_1 > 0
AND @partitioned_before_2 > 0
AND @offrow_before > 0
AND @offrow_lob_pages > 0
    RAISERROR(N'PASS 47B: both partitions have forwarded records and the off-row fixture has forwarded rows and LOB pages.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @fixture_failure nvarchar(400) = N'FAIL 47B: initial forwarded rows partitioned='
        + COALESCE(CONVERT(nvarchar(20), @partitioned_before), N'NULL')
        + N' (partitions ' + COALESCE(CONVERT(nvarchar(20), @partitioned_before_1), N'NULL')
        + N'/' + COALESCE(CONVERT(nvarchar(20), @partitioned_before_2), N'NULL') + N')'
        + N', off-row=' + COALESCE(CONVERT(nvarchar(20), @offrow_before), N'NULL')
        + N', LOB pages=' + COALESCE(CONVERT(nvarchar(20), @offrow_lob_pages), N'NULL') + N'.';
    RAISERROR(@fixture_failure, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 47C-PARTITIONED-HEAP*/
DECLARE
    @procedure_rc int,
    @targets_found int,
    @succeeded int,
    @failed int,
    @status varchar(10),
    @max_commandlog_id int,
    @actual_forwarded bigint,
    @actual_partition_1 bigint,
    @actual_partition_2 bigint,
    @logged_forwarded bigint,
    @logged_scan_mode nvarchar(20);

SELECT @max_commandlog_id = COALESCE(MAX(ID), 0)
FROM dbo.CommandLog;

EXECUTE @procedure_rc = dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.CvyyPartitionedHeap',
    @CpuSource = N'NONE',
    @PlanOnly = 0,
    @MinPages = 10,
    @MinForwardedPct = 0,
    @ScanMode = N'DETAILED',
    @LogToTable = N'Y',
    @TargetsFound = @targets_found OUTPUT,
    @Succeeded = @succeeded OUTPUT,
    @Failed = @failed OUTPUT,
    @Status = @status OUTPUT;

SELECT
    @actual_forwarded = COALESCE(SUM(forwarded_record_count), 0),
    @actual_partition_1 = COALESCE(SUM(CASE WHEN partition_number = 1 THEN forwarded_record_count END), 0),
    @actual_partition_2 = COALESCE(SUM(CASE WHEN partition_number = 2 THEN forwarded_record_count END), 0)
FROM sys.dm_db_index_physical_stats
(
    DB_ID(), OBJECT_ID(N'dbo.CvyyPartitionedHeap'), 0, NULL, N'DETAILED'
)
WHERE index_id = 0
  AND alloc_unit_type_desc = N'IN_ROW_DATA';

SELECT TOP (1)
    @logged_forwarded = ExtendedInfo.value
        ('(/ExtendedInfo/PostRebuildForwardedRecords/text())[1]', 'bigint'),
    @logged_scan_mode = ExtendedInfo.value
        ('(/ExtendedInfo/RequestedPostRebuildScanMode/text())[1]', 'nvarchar(20)')
FROM dbo.CommandLog
WHERE ObjectName = N'CvyyPartitionedHeap'
  AND CommandType LIKE N'HEAP_REBUILD%'
  AND ID > @max_commandlog_id
ORDER BY ID DESC;

IF @procedure_rc = 0
AND @targets_found = 1
AND @succeeded = 1
AND @failed = 0
AND @actual_forwarded > 0
AND @actual_partition_1 > 0
AND @actual_partition_2 > 0
AND @logged_forwarded = @actual_forwarded
AND @logged_scan_mode = N'DETAILED'
    RAISERROR(N'PASS 47C: partitioned heap verification matches the detailed IN_ROW_DATA total (%I64d).', 10, 1, @actual_forwarded) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @partitioned_failure nvarchar(500) = N'FAIL 47C: rc='
        + COALESCE(CONVERT(nvarchar(10), @procedure_rc), N'NULL')
        + N' targets=' + COALESCE(CONVERT(nvarchar(10), @targets_found), N'NULL')
        + N' succeeded=' + COALESCE(CONVERT(nvarchar(10), @succeeded), N'NULL')
        + N' failed=' + COALESCE(CONVERT(nvarchar(10), @failed), N'NULL')
        + N' status=' + COALESCE(@status, N'NULL')
        + N' verifier=' + COALESCE(CONVERT(nvarchar(20), @logged_forwarded), N'NULL')
        + N' actual=' + COALESCE(CONVERT(nvarchar(20), @actual_forwarded), N'NULL')
        + N' partitions=' + COALESCE(CONVERT(nvarchar(20), @actual_partition_1), N'NULL')
        + N'/' + COALESCE(CONVERT(nvarchar(20), @actual_partition_2), N'NULL')
        + N' scan=' + COALESCE(@logged_scan_mode, N'NULL')
        + N'.';
    RAISERROR(@partitioned_failure, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 47D-OFFROW-HEAP*/
DECLARE
    @procedure_rc int,
    @targets_found int,
    @succeeded int,
    @failed int,
    @status varchar(10),
    @max_commandlog_id int,
    @actual_forwarded bigint,
    @actual_partition_1 bigint,
    @actual_partition_2 bigint,
    @logged_forwarded bigint,
    @logged_scan_mode nvarchar(20);

SELECT @max_commandlog_id = COALESCE(MAX(ID), 0)
FROM dbo.CommandLog;

EXECUTE @procedure_rc = dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.CvyyOffrowHeap',
    @CpuSource = N'NONE',
    @PlanOnly = 0,
    @MinPages = 10,
    @MinForwardedPct = 0,
    @ScanMode = N'DETAILED',
    @LogToTable = N'Y',
    @TargetsFound = @targets_found OUTPUT,
    @Succeeded = @succeeded OUTPUT,
    @Failed = @failed OUTPUT,
    @Status = @status OUTPUT;

SELECT
    @actual_forwarded = COALESCE(SUM(forwarded_record_count), 0),
    @actual_partition_1 = COALESCE(SUM(CASE WHEN partition_number = 1 THEN forwarded_record_count END), 0),
    @actual_partition_2 = COALESCE(SUM(CASE WHEN partition_number = 2 THEN forwarded_record_count END), 0)
FROM sys.dm_db_index_physical_stats
(
    DB_ID(), OBJECT_ID(N'dbo.CvyyOffrowHeap'), 0, NULL, N'DETAILED'
)
WHERE index_id = 0
  AND alloc_unit_type_desc = N'IN_ROW_DATA';

SELECT TOP (1)
    @logged_forwarded = ExtendedInfo.value
        ('(/ExtendedInfo/PostRebuildForwardedRecords/text())[1]', 'bigint'),
    @logged_scan_mode = ExtendedInfo.value
        ('(/ExtendedInfo/RequestedPostRebuildScanMode/text())[1]', 'nvarchar(20)')
FROM dbo.CommandLog
WHERE ObjectName = N'CvyyOffrowHeap'
  AND CommandType LIKE N'HEAP_REBUILD%'
  AND ID > @max_commandlog_id
ORDER BY ID DESC;

IF @procedure_rc = 0
AND @targets_found = 1
AND @succeeded = 1
AND @failed = 0
AND @actual_forwarded > 0
AND @actual_partition_1 > 0
AND @actual_partition_2 = 0
AND @logged_forwarded = @actual_forwarded
AND @logged_scan_mode = N'DETAILED'
    RAISERROR(N'PASS 47D: off-row heap verification matches the detailed IN_ROW_DATA total (%I64d).', 10, 1, @actual_forwarded) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @offrow_failure nvarchar(500) = N'FAIL 47D: rc='
        + COALESCE(CONVERT(nvarchar(10), @procedure_rc), N'NULL')
        + N' targets=' + COALESCE(CONVERT(nvarchar(10), @targets_found), N'NULL')
        + N' succeeded=' + COALESCE(CONVERT(nvarchar(10), @succeeded), N'NULL')
        + N' failed=' + COALESCE(CONVERT(nvarchar(10), @failed), N'NULL')
        + N' status=' + COALESCE(@status, N'NULL')
        + N' verifier=' + COALESCE(CONVERT(nvarchar(20), @logged_forwarded), N'NULL')
        + N' actual=' + COALESCE(CONVERT(nvarchar(20), @actual_forwarded), N'NULL')
        + N' partitions=' + COALESCE(CONVERT(nvarchar(20), @actual_partition_1), N'NULL')
        + N'/' + COALESCE(CONVERT(nvarchar(20), @actual_partition_2), N'NULL')
        + N' scan=' + COALESCE(@logged_scan_mode, N'NULL')
        + N'.';
    RAISERROR(@offrow_failure, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 47E-SCAN-MODE-MESSAGE*/
DECLARE
    @procedure_definition nvarchar(max),
    @warning_start int,
    @warning_scan_label int,
    @warning_scan_parameter int,
    @zero_message_start int,
    @zero_scan_label int,
    @zero_scan_parameter int;

SELECT @procedure_definition = definition
FROM master.sys.sql_modules
WHERE object_id = OBJECT_ID(N'master.dbo.sp_HeapDoctor');

SET @warning_start = CHARINDEX(N'WARNING: Post-rebuild check found', @procedure_definition);
SET @warning_scan_label = CHARINDEX(N'(scan mode:', @procedure_definition, @warning_start);
SET @warning_scan_parameter = CHARINDEX(N'@ScanMode', @procedure_definition, @warning_scan_label);
SET @zero_message_start = CHARINDEX(N'Verified: 0 forwarded records', @procedure_definition);
SET @zero_scan_label = CHARINDEX(N'(scan mode:', @procedure_definition, @zero_message_start);
SET @zero_scan_parameter = CHARINDEX(N'@ScanMode', @procedure_definition, @zero_scan_label);

IF @warning_start > 0
AND @warning_scan_label > @warning_start
AND @warning_scan_parameter > @warning_scan_label
AND @warning_scan_parameter < @zero_message_start
AND @zero_scan_label > @zero_message_start
AND @zero_scan_parameter > @zero_scan_label
    RAISERROR(N'PASS 47E: both post-rebuild verification messages name the requested scan mode.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 47E: one or more post-rebuild verification messages omit the scan mode.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 47F-SCAN-MODE-ARGUMENT*/
DECLARE @procedure_definition nvarchar(max);

SELECT @procedure_definition = definition
FROM master.sys.sql_modules
WHERE object_id = OBJECT_ID(N'master.dbo.sp_HeapDoctor');

IF CHARINDEX(N'@scan_mode_param)', @procedure_definition) > 0
AND CHARINDEX(N'@scan_mode_param = @ScanMode', @procedure_definition) > 0
AND CHARINDEX(N'@scan_mode_param nvarchar(20)', @procedure_definition) > 0
    RAISERROR(N'PASS 47F: the post-rebuild DMV call receives the requested scan mode.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 47F: the post-rebuild DMV call does not receive @ScanMode.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 47Z-CLEANUP*/
DROP TRIGGER trg_CvyyAfterRebuild ON DATABASE;
DROP TABLE dbo.CvyyPartitionedHeap;
DROP TABLE dbo.CvyyOffrowHeap;
DROP PARTITION SCHEME ps_CvyyTest;
DROP PARTITION FUNCTION pf_CvyyTest;
GO
/*#endregion*/
