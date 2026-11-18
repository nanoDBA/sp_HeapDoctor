/* Test 45 verifies temporal history rebuilds restore SYSTEM_VERSIONING. */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;
GO

IF OBJECT_ID(N'dbo.CufbTemporal') IS NOT NULL
BEGIN
    IF EXISTS
    (
        SELECT 1
        FROM sys.tables
        WHERE object_id = OBJECT_ID(N'dbo.CufbTemporal')
          AND temporal_type = 2
    )
        ALTER TABLE dbo.CufbTemporal SET (SYSTEM_VERSIONING = OFF);

    DROP TABLE dbo.CufbTemporal;
END
DROP TABLE IF EXISTS dbo.CufbTemporalHistory;
GO

CREATE TABLE dbo.CufbTemporalHistory
(
    ID           int          NOT NULL,
    Col1         varchar(4000) NULL,
    SysStartTime datetime2     NOT NULL,
    SysEndTime   datetime2     NOT NULL
);

CREATE TABLE dbo.CufbTemporal
(
    ID           int          NOT NULL PRIMARY KEY CLUSTERED,
    Col1         varchar(4000) NULL,
    SysStartTime datetime2 GENERATED ALWAYS AS ROW START NOT NULL,
    SysEndTime   datetime2 GENERATED ALWAYS AS ROW END   NOT NULL,
    PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.CufbTemporalHistory));

DECLARE @id integer = 1;
BEGIN TRANSACTION;
WHILE @id <= 5000
BEGIN
    INSERT dbo.CufbTemporal (ID, Col1)
    VALUES (@id, REPLICATE('A', 10));
    SET @id += 1;
END
COMMIT TRANSACTION;
GO

UPDATE dbo.CufbTemporal
SET Col1 = REPLICATE('B', 10);
GO

ALTER TABLE dbo.CufbTemporal SET (SYSTEM_VERSIONING = OFF);
GO

UPDATE dbo.CufbTemporalHistory
SET Col1 = REPLICATE('Z', 3000);
GO

ALTER TABLE dbo.CufbTemporal SET
(
    SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.CufbTemporalHistory)
);
GO

DECLARE @forwarded_records bigint = 0;

SELECT @forwarded_records = COALESCE(SUM(forwarded_record_count), 0)
FROM sys.dm_db_index_physical_stats
(
    DB_ID(),
    OBJECT_ID(N'dbo.CufbTemporalHistory'),
    0,
    NULL,
    'DETAILED'
);

IF @forwarded_records > 0
    RAISERROR(N'PASS 45A: temporal history heap has forwarded records (%I64d).', 10, 1, @forwarded_records) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 45A: temporal history fixture has no forwarded records.', 10, 1) WITH NOWAIT;
GO

DECLARE
    @targets_found integer = NULL,
    @succeeded integer = NULL,
    @failed integer = NULL,
    @skipped integer = NULL,
    @status varchar(10) = NULL,
    @failure_detail nvarchar(2048) = NULL,
    @procedure_error nvarchar(2048) = NULL,
    @temporal_type tinyint = NULL,
    @run_started_at datetime2(7) = NULL,
    @forwarded_after bigint = NULL,
    @breadcrumb_command nvarchar(max) = NULL,
    @breadcrumb_end_time datetime = NULL,
    @breadcrumb_error_number integer = NULL;

SET @run_started_at = SYSDATETIME();

BEGIN TRY
    EXECUTE dbo.sp_HeapDoctor
        @Databases = N'HeapDoctorTest',
        @Tables = N'dbo.CufbTemporalHistory',
        @CpuSource = N'NONE',
        @PlanOnly = 0,
        @MinPages = 1,
        @IncludeTemporalHistory = 1,
        @LogToTable = N'Y',
        @TargetsFound = @targets_found OUTPUT,
        @Succeeded = @succeeded OUTPUT,
        @Failed = @failed OUTPUT,
        @Skipped = @skipped OUTPUT,
        @Status = @status OUTPUT;
END TRY
BEGIN CATCH
    SET @procedure_error = ERROR_MESSAGE();
END CATCH;

SELECT @temporal_type = temporal_type
FROM sys.tables
WHERE object_id = OBJECT_ID(N'dbo.CufbTemporal');

SELECT @forwarded_after = COALESCE(SUM(forwarded_record_count), 0)
FROM sys.dm_db_index_physical_stats
(
    DB_ID(),
    OBJECT_ID(N'dbo.CufbTemporalHistory'),
    0,
    NULL,
    'DETAILED'
);

SELECT TOP (1)
    @breadcrumb_command = Command,
    @breadcrumb_end_time = EndTime,
    @breadcrumb_error_number = ErrorNumber
FROM dbo.CommandLog
WHERE CommandType = N'HEAP_TEMPORAL_VERSIONING_DISABLED'
  AND DatabaseName = N'HeapDoctorTest'
  AND SchemaName = N'dbo'
  AND ObjectName = N'CufbTemporal'
  AND StartTime >= @run_started_at
ORDER BY ID DESC;

IF @temporal_type = 2
AND @targets_found = 1
AND @succeeded = 1
AND @failed = 0
AND @skipped = 0
AND @forwarded_after = 0
AND @status = 'SUCCESS'
    RAISERROR(N'PASS 45B: the history heap rebuilt, forwarded records cleared, and SYSTEM_VERSIONING restored.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    SET @failure_detail = N'FAIL 45B: temporal_type='
        + COALESCE(CONVERT(nvarchar(10), @temporal_type), N'<NULL>')
        + N' targets=' + COALESCE(CONVERT(nvarchar(10), @targets_found), N'<NULL>')
        + N' succeeded=' + COALESCE(CONVERT(nvarchar(10), @succeeded), N'<NULL>')
        + N' failed=' + COALESCE(CONVERT(nvarchar(10), @failed), N'<NULL>')
        + N' skipped=' + COALESCE(CONVERT(nvarchar(10), @skipped), N'<NULL>')
        + N' forwarded_after=' + COALESCE(CONVERT(nvarchar(10), @forwarded_after), N'<NULL>')
        + N' status=' + COALESCE(@status, N'<NULL>')
        + N' error=' + COALESCE(@procedure_error, N'<none>') + N'.';
    RAISERROR(@failure_detail, 10, 1) WITH NOWAIT;
END

IF @breadcrumb_command = N'USE [HeapDoctorTest]; ALTER TABLE [dbo].[CufbTemporal] SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = [dbo].[CufbTemporalHistory]));'
AND @breadcrumb_end_time IS NOT NULL
AND @breadcrumb_error_number = 0
    RAISERROR(N'PASS 45C: CommandLog stores the valid target-context recovery DDL and marks it complete.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 45C: CommandLog recovery DDL is missing, invalid, or incomplete.', 10, 1) WITH NOWAIT;

/* Restore and remove the fixture even when the procedure left it unversioned. */
IF EXISTS
(
    SELECT 1
    FROM sys.tables
    WHERE object_id = OBJECT_ID(N'dbo.CufbTemporal')
      AND temporal_type = 2
)
    ALTER TABLE dbo.CufbTemporal SET (SYSTEM_VERSIONING = OFF);

DROP TABLE dbo.CufbTemporal;
DROP TABLE dbo.CufbTemporalHistory;
GO
