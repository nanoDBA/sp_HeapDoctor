/* #214: a blocked CI-swap cleanup must be reported as recovery required. */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;
GO

CREATE TABLE dbo.FGD0Heap
(
    ID int NOT NULL,
    Padding varchar(4000) NOT NULL
);

;WITH N AS
(
    SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
)
INSERT dbo.FGD0Heap (ID, Padding)
SELECT TOP (10000) n, REPLICATE('A', 10)
FROM N;

UPDATE dbo.FGD0Heap
SET Padding = REPLICATE('X', 1500)
WHERE ID <= 5000;

CREATE UNIQUE NONCLUSTERED INDEX UX_FGD0Heap_ID ON dbo.FGD0Heap (ID);
GO

CREATE TRIGGER trFGD0_BlockTempDrop ON DATABASE
FOR DROP_INDEX
AS
BEGIN
    SET NOCOUNT ON;
    IF EVENTDATA().value(N'(/EVENT_INSTANCE/ObjectName)[1]', N'sysname') = N'CX__Temp__FGD0Heap'
    BEGIN
        RAISERROR(N'FGD0 simulated temp-index drop failure.', 16, 1);
        ROLLBACK;
    END;
END;
GO

DECLARE
    @return_code int = NULL,
    @targets_found int = NULL,
    @succeeded int = NULL,
    @failed int = NULL,
    @skipped int = NULL,
    @status varchar(10) = NULL,
    @status_message nvarchar(1000) = NULL,
    @execution_returned bit = 0,
    @run_id uniqueidentifier = NULL,
    @drop_rows int = 0,
    @recovery_events int = 0,
    @queue_status nvarchar(30) = NULL,
    @stop_reason nvarchar(50) = NULL,
    @clustered_index sysname = NULL,
    @remediation nvarchar(max) = NULL;

BEGIN TRY
    EXEC @return_code = dbo.sp_HeapDoctor
        @Databases = N'HeapDoctorTest',
        @Tables = N'dbo.FGD0Heap',
        @CpuSource = N'NONE',
        @Execute = N'Y',
        @LogToTable = N'Y',
        @MinPages = 10,
        @MinForwardedPct = 0,
        @AllowCiSwap = 1,
        @PreferCiSwap = 1,
        @OnlinePreference = N'ON',
        @HeapsInParallel = N'Y',
        @TargetsFound = @targets_found OUTPUT,
        @Succeeded = @succeeded OUTPUT,
        @Failed = @failed OUTPUT,
        @Skipped = @skipped OUTPUT,
        @Status = @status OUTPUT,
        @StatusMessage = @status_message OUTPUT;
    SET @execution_returned = 1;
END TRY
BEGIN CATCH
    SET @status_message = ERROR_MESSAGE();
END CATCH;

SELECT TOP (1)
    @run_id = cl.ExtendedInfo.value('(/TargetEvent/RunID/text())[1]', 'uniqueidentifier')
FROM dbo.CommandLog AS cl
WHERE cl.CommandType = N'HEAP_TARGET_EVENT'
ORDER BY cl.ID DESC;

SELECT
    @drop_rows = COUNT(*),
    @remediation = MAX(cl.ExtendedInfo.value('(/ExtendedInfo/RemediationDDL/text())[1]', 'nvarchar(max)'))
FROM dbo.CommandLog AS cl
WHERE cl.CommandType = N'CI_SWAP_DROP_FAILED'
  AND cl.ObjectName = N'FGD0Heap';

SELECT @recovery_events = COUNT(*)
FROM dbo.CommandLog AS cl
WHERE cl.CommandType = N'HEAP_TARGET_EVENT'
  AND cl.ExtendedInfo.value('(/TargetEvent/OutcomeCode/text())[1]', 'nvarchar(50)') = N'RECOVERY_REQUIRED'
  AND cl.ExtendedInfo.value('(/TargetEvent/Detail/RecoveryRequired/text())[1]', 'bit') = 1;

IF OBJECT_ID(N'dbo.QueueHeapRebuild', N'U') IS NOT NULL
BEGIN
    SELECT TOP (1) @queue_status = Status
    FROM dbo.QueueHeapRebuild
    WHERE TableName = N'FGD0Heap'
    ORDER BY QueueID DESC;
END;

SELECT TOP (1)
    @stop_reason = cl.ExtendedInfo.value('(/Summary/StopReason/text())[1]', 'nvarchar(50)')
FROM dbo.CommandLog AS cl
WHERE cl.CommandType = N'HEAP_REBUILD_END'
ORDER BY cl.ID DESC;

SELECT @clustered_index = name
FROM sys.indexes
WHERE object_id = OBJECT_ID(N'dbo.FGD0Heap')
  AND index_id = 1;

IF @execution_returned = 1 AND @targets_found = 1 AND @return_code = 1
   AND @succeeded = 0 AND @failed = 1 AND @status = 'ERROR'
   AND @status_message LIKE N'%MANUAL RECOVERY%'
    RAISERROR(N'PASS 49A: blocked CI cleanup returns an error verdict and does not count a completed target.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 49A: blocked CI cleanup has the wrong return code, counters, or status.', 10, 1) WITH NOWAIT;

IF @drop_rows = 1
   AND @remediation = N'DROP INDEX [CX__Temp__FGD0Heap] ON [HeapDoctorTest].[dbo].[FGD0Heap];'
    RAISERROR(N'PASS 49B: the dedicated drop-failure row retains executable remediation DDL.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 49B: the dedicated drop-failure row or remediation DDL is missing.', 10, 1) WITH NOWAIT;

IF @recovery_events = 1 AND @run_id IS NOT NULL
    RAISERROR(N'PASS 49C: the terminal target event is RECOVERY_REQUIRED.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 49C: the terminal target event does not report RECOVERY_REQUIRED.', 10, 1) WITH NOWAIT;

IF @queue_status = N'RECOVERY_REQUIRED'
    RAISERROR(N'PASS 49D: the parallel queue row retains the recovery-required state.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 49D: the parallel queue row does not retain the recovery-required state.', 10, 1) WITH NOWAIT;

IF @stop_reason = N'COMPLETED_WITH_ERRORS'
    RAISERROR(N'PASS 49E: HEAP_REBUILD_END records the error stop reason.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 49E: HEAP_REBUILD_END reports the wrong stop reason.', 10, 1) WITH NOWAIT;

IF @clustered_index = N'CX__Temp__FGD0Heap'
    RAISERROR(N'PASS 49F: the blocked drop leaves the temporary clustered index for manual recovery.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 49F: the expected clustered index is not left for manual recovery.', 10, 1) WITH NOWAIT;
GO

DROP TRIGGER trFGD0_BlockTempDrop ON DATABASE;
DECLARE @drop_index sysname =
(
    SELECT name
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.FGD0Heap')
      AND index_id = 1
      AND name = N'CX__Temp__FGD0Heap'
);
IF @drop_index IS NOT NULL
BEGIN
    DECLARE @cleanup_sql nvarchar(1000) = N'DROP INDEX ' + QUOTENAME(@drop_index) + N' ON dbo.FGD0Heap;';
    EXECUTE sys.sp_executesql @cleanup_sql;
END;
DROP TABLE dbo.FGD0Heap;

/*#region 49G-SERIAL-TARGET-STATE*/
CREATE TABLE dbo.FGD0SerialDrop
(
    ID int NOT NULL,
    Padding varchar(4000) NOT NULL
);
CREATE TABLE dbo.FGD0SerialRebuild
(
    ID int NOT NULL,
    Padding varchar(4000) NOT NULL
);
;WITH N AS
(
    SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
)
INSERT dbo.FGD0SerialDrop (ID, Padding)
SELECT TOP (10000) n, REPLICATE('A', 10) FROM N;
UPDATE dbo.FGD0SerialDrop SET Padding = REPLICATE('X', 1500) WHERE ID <= 5000;
CREATE UNIQUE NONCLUSTERED INDEX UX_FGD0SerialDrop_ID ON dbo.FGD0SerialDrop (ID);
;WITH N AS
(
    SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
)
INSERT dbo.FGD0SerialRebuild (ID, Padding)
SELECT TOP (10000) n, REPLICATE('A', 10) FROM N;
UPDATE dbo.FGD0SerialRebuild SET Padding = REPLICATE('X', 1500) WHERE ID <= 5000;
GO

CREATE TRIGGER trFGD0_BlockSerialTempDrop ON DATABASE
FOR DROP_INDEX
AS
BEGIN
    SET NOCOUNT ON;
    IF EVENTDATA().value(N'(/EVENT_INSTANCE/ObjectName)[1]', N'sysname') = N'CX__Temp__FGD0SerialDrop'
    BEGIN
        RAISERROR(N'FGD0 serial simulated temp-index drop failure.', 16, 1);
        ROLLBACK;
    END;
END;
GO

CREATE TRIGGER trFGD0_BlockSerialRebuild ON DATABASE
FOR ALTER_TABLE
AS
BEGIN
    SET NOCOUNT ON;
    IF EVENTDATA().value(N'(/EVENT_INSTANCE/ObjectName)[1]', N'sysname') = N'FGD0SerialRebuild'
    BEGIN
        RAISERROR(N'FGD0 serial simulated rebuild failure.', 16, 1);
        ROLLBACK;
    END;
END;
GO

DECLARE
    @serial_targets int = NULL,
    @serial_succeeded int = NULL,
    @serial_failed int = NULL,
    @serial_skipped int = NULL,
    @serial_run_id uniqueidentifier = NULL,
    @serial_drop_outcome nvarchar(50) = NULL,
    @serial_rebuild_outcome nvarchar(50) = NULL,
    @serial_rebuild_recovery bit = NULL,
    @serial_rebuild_error nvarchar(1000) = NULL;

EXECUTE dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.FGD0SerialDrop,dbo.FGD0SerialRebuild',
    @CpuSource = N'NONE',
    @PlanOnly = 0,
    @LogToTable = N'Y',
    @MinPages = 10,
    @MinForwardedPct = 0,
    @AllowCiSwap = 1,
    @PreferCiSwap = 1,
    @OnlinePreference = N'ON',
    @HeapsInParallel = N'N',
    @TargetsFound = @serial_targets OUTPUT,
    @Succeeded = @serial_succeeded OUTPUT,
    @Failed = @serial_failed OUTPUT,
    @Skipped = @serial_skipped OUTPUT;

SELECT TOP (1)
    @serial_run_id = cl.ExtendedInfo.value('(/TargetEvent/RunID/text())[1]', 'uniqueidentifier')
FROM dbo.CommandLog AS cl
WHERE cl.CommandType = N'HEAP_TARGET_EVENT'
  AND cl.ObjectName = N'FGD0SerialDrop'
ORDER BY cl.ID DESC;

SELECT
    @serial_drop_outcome = MAX(CASE WHEN cl.ObjectName = N'FGD0SerialDrop'
        THEN cl.ExtendedInfo.value('(/TargetEvent/OutcomeCode/text())[1]', 'nvarchar(50)') END),
    @serial_rebuild_outcome = MAX(CASE WHEN cl.ObjectName = N'FGD0SerialRebuild'
        THEN cl.ExtendedInfo.value('(/TargetEvent/OutcomeCode/text())[1]', 'nvarchar(50)') END),
    @serial_rebuild_recovery = MAX(CASE WHEN cl.ObjectName = N'FGD0SerialRebuild'
        THEN CONVERT(int, cl.ExtendedInfo.value('(/TargetEvent/Detail/RecoveryRequired/text())[1]', 'bit')) END),
    @serial_rebuild_error = MAX(CASE WHEN cl.ObjectName = N'FGD0SerialRebuild'
        THEN cl.ErrorMessage END)
FROM dbo.CommandLog AS cl
WHERE cl.CommandType = N'HEAP_TARGET_EVENT'
  AND cl.ExtendedInfo.value('(/TargetEvent/RunID/text())[1]', 'uniqueidentifier') = @serial_run_id;

IF @serial_targets = 2
AND @serial_drop_outcome = N'RECOVERY_REQUIRED'
AND @serial_rebuild_outcome = N'FAILED'
AND @serial_rebuild_recovery = 0
AND @serial_rebuild_error LIKE N'%FGD0 serial simulated rebuild failure%'
    RAISERROR(N'PASS 49G: serial target failures retain their own error and recovery state.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 49G: serial target outcome or error state leaked from the earlier CI drop failure.', 10, 1) WITH NOWAIT;
GO

DROP TRIGGER trFGD0_BlockSerialTempDrop ON DATABASE;
DROP TRIGGER trFGD0_BlockSerialRebuild ON DATABASE;
DECLARE @serial_temp_index sysname =
(
    SELECT name FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.FGD0SerialDrop')
      AND index_id = 1 AND name = N'CX__Temp__FGD0SerialDrop'
);
IF @serial_temp_index IS NOT NULL
    EXECUTE sys.sp_executesql N'DROP INDEX [CX__Temp__FGD0SerialDrop] ON dbo.FGD0SerialDrop;';
DROP TABLE dbo.FGD0SerialDrop;
DROP TABLE dbo.FGD0SerialRebuild;
GO
/*#endregion*/

/*#region 49H-TEMPORAL-RESTORE-FAILURE-COUNTS*/
CREATE TABLE dbo.FGD0TemporalParent
(
    ID int NOT NULL CONSTRAINT PK_FGD0TemporalParent PRIMARY KEY CLUSTERED,
    Payload varchar(2000) NOT NULL,
    ValidFrom datetime2(7) GENERATED ALWAYS AS ROW START NOT NULL,
    ValidTo datetime2(7) GENERATED ALWAYS AS ROW END NOT NULL,
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
);
CREATE TABLE dbo.FGD0TemporalHistory
(
    ID int NOT NULL,
    Payload varchar(2000) NOT NULL,
    ValidFrom datetime2(7) NOT NULL,
    ValidTo datetime2(7) NOT NULL
);
ALTER TABLE dbo.FGD0TemporalParent
SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.FGD0TemporalHistory));
;WITH N AS
(
    SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
)
INSERT dbo.FGD0TemporalParent (ID, Payload)
SELECT TOP (6000) n, REPLICATE('A', 10) FROM N;
UPDATE dbo.FGD0TemporalParent SET Payload = REPLICATE('X', 1500);
GO

CREATE TRIGGER trFGD0_BlockTemporalRestore ON DATABASE
FOR ALTER_TABLE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @command nvarchar(max) = EVENTDATA().value(N'(/EVENT_INSTANCE/TSQLCommand/CommandText)[1]', N'nvarchar(max)');
    IF @command LIKE N'%SYSTEM_VERSIONING = ON%'
       AND @command LIKE N'%FGD0TemporalParent%'
    BEGIN
        RAISERROR(N'FGD0 simulated SYSTEM_VERSIONING restore failure.', 16, 1);
        ROLLBACK;
    END;
END;
GO

DECLARE
    @temporal_targets int = NULL,
    @temporal_succeeded int = NULL,
    @temporal_failed int = NULL,
    @temporal_skipped int = NULL,
    @temporal_status varchar(10) = NULL;

EXECUTE dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.FGD0TemporalHistory',
    @CpuSource = N'NONE',
    @PlanOnly = 0,
    @LogToTable = N'Y',
    @MinPages = 10,
    @MinForwardedPct = 0,
    @IncludeTemporalHistory = 1,
    @IncludeHealthyHeaps = 1,
    @TargetsFound = @temporal_targets OUTPUT,
    @Succeeded = @temporal_succeeded OUTPUT,
    @Failed = @temporal_failed OUTPUT,
    @Skipped = @temporal_skipped OUTPUT,
    @Status = @temporal_status OUTPUT;

IF @temporal_targets = 1
AND @temporal_succeeded + @temporal_failed + @temporal_skipped = @temporal_targets
AND @temporal_succeeded = 0
AND @temporal_failed = 1
AND @temporal_status = N'ERROR'
    RAISERROR(N'PASS 49H: temporal restore failure is counted once as a failed target.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @failure_49h nvarchar(1000) = N'FAIL 49H: targets='
        + ISNULL(CONVERT(nvarchar(10), @temporal_targets), N'NULL')
        + N' succeeded=' + ISNULL(CONVERT(nvarchar(10), @temporal_succeeded), N'NULL')
        + N' failed=' + ISNULL(CONVERT(nvarchar(10), @temporal_failed), N'NULL')
        + N' skipped=' + ISNULL(CONVERT(nvarchar(10), @temporal_skipped), N'NULL')
        + N' status=' + ISNULL(@temporal_status, N'NULL') + N'.';
    RAISERROR(N'%s', 10, 1, @failure_49h) WITH NOWAIT;
END
GO

DROP TRIGGER trFGD0_BlockTemporalRestore ON DATABASE;
ALTER TABLE dbo.FGD0TemporalParent
SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.FGD0TemporalHistory));
ALTER TABLE dbo.FGD0TemporalParent SET (SYSTEM_VERSIONING = OFF);
DROP TABLE dbo.FGD0TemporalParent;
DROP TABLE dbo.FGD0TemporalHistory;
GO
/*#endregion*/
