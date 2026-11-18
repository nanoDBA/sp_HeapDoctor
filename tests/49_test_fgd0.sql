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
