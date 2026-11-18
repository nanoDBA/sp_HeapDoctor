/* Test 44 verifies that execution refuses caller-owned transactions. */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;
GO

/*#region 44A-VERSION*/
SELECT *
INTO #Results
FROM dbo.ResultsTemplate
WHERE 1 = 0;

INSERT INTO #Results
EXECUTE dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.HeapA',
    @CpuSource = 'NONE',
    @PlanOnly = 1,
    @LogToTable = N'N';

IF (SELECT COUNT_BIG(*) FROM #Results WHERE table_name = N'HeapA') = 1
AND EXISTS
(
    SELECT
        1
    FROM #Results AS r
    JOIN dbo.ExpectedVersion AS e
      ON e.version = r.version
    WHERE r.table_name = N'HeapA'
)
    RAISERROR(N'PASS 44A: the procedure returned one version-matched HeapA row.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 44A: the plan-only version control did not return one matching HeapA row.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 44B-PLAN-ONLY-TRANSACTION*/
CREATE TABLE dbo.NLFHTransactionMarker
(
    marker_id integer NOT NULL
);

DECLARE
    @plan_returned bit = 0,
    @plan_error nvarchar(2048) = NULL,
    @plan_trancount integer = 0,
    @plan_xact_state integer = 0,
    @marker_rows bigint = 0,
    @plan_targets_found integer = NULL,
    @plan_status varchar(10) = NULL;

BEGIN TRANSACTION;

BEGIN TRY
    INSERT INTO dbo.NLFHTransactionMarker
    (
        marker_id
    )
    VALUES
    (
        1
    );

    BEGIN TRY
        EXECUTE dbo.sp_HeapDoctor
            @Databases = N'HeapDoctorTest',
            @Tables = N'dbo.HeapA',
            @CpuSource = 'NONE',
            @PlanOnly = 1,
            @LogToTable = N'N',
            @TargetsFound = @plan_targets_found OUTPUT,
            @Status = @plan_status OUTPUT;

        SET @plan_returned = 1;
    END TRY
    BEGIN CATCH
        SET @plan_error = ERROR_MESSAGE();
    END CATCH;

    SET @plan_trancount = @@TRANCOUNT;
    SET @plan_xact_state = XACT_STATE();

    SELECT
        @marker_rows = COUNT_BIG(*)
    FROM dbo.NLFHTransactionMarker;

    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    SET @plan_error = ISNULL(@plan_error, ERROR_MESSAGE());
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;
END CATCH;

IF @plan_returned = 1
AND @plan_error IS NULL
AND @plan_trancount = 1
AND @plan_xact_state = 1
AND @marker_rows = 1
AND @plan_targets_found = 1
AND @plan_status = 'SUCCESS'
    RAISERROR(N'PASS 44B: plan-only completed without changing the caller transaction.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @failure_44b nvarchar(2048) = N'FAIL 44B: returned='
        + CONVERT(nvarchar(10), @plan_returned)
        + N' error=' + ISNULL(@plan_error, N'NULL')
        + N' trancount=' + CONVERT(nvarchar(10), @plan_trancount)
        + N' xact_state=' + CONVERT(nvarchar(10), @plan_xact_state)
        + N' marker_rows=' + CONVERT(nvarchar(20), @marker_rows)
        + N' targets=' + ISNULL(CONVERT(nvarchar(10), @plan_targets_found), N'NULL')
        + N' status=' + ISNULL(@plan_status, N'NULL') + N'.';
    RAISERROR(N'%s', 10, 1, @failure_44b) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 44C-EXPLICIT-TRANSACTION*/
CREATE TABLE dbo.NLFHTestHeap
(
    ID integer NOT NULL,
    Padding varchar(4000) NOT NULL
);

WITH
    row_numbers
AS
(
    SELECT
        n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
)
INSERT INTO dbo.NLFHTestHeap
(
    ID,
    Padding
)
SELECT TOP (10000)
    n,
    REPLICATE('A', 10)
FROM row_numbers;

UPDATE dbo.NLFHTestHeap
SET Padding = REPLICATE('X', 3000)
WHERE ID <= 5000;

DECLARE
    @before bigint = NULL,
    @during bigint = NULL,
    @after bigint = NULL,
    @started datetime2(3) = SYSDATETIME(),
    @rc integer = -999,
    @returned bit = 0,
    @caught nvarchar(2048) = NULL,
    @trancount integer = 0,
    @xact_state integer = 0,
    @marker_count bigint = 0,
    @schema_modification_locks bigint = 0,
    @command_rows bigint = 0,
    @probe_error nvarchar(2048) = NULL;

SELECT
    @before = SUM(ps.forwarded_record_count)
FROM sys.dm_db_index_physical_stats
(
    DB_ID(),
    OBJECT_ID(N'dbo.NLFHTestHeap'),
    0,
    NULL,
    'DETAILED'
) AS ps
WHERE ps.index_id = 0
AND ps.alloc_unit_type_desc = N'IN_ROW_DATA';

BEGIN TRANSACTION;

BEGIN TRY
    INSERT INTO dbo.NLFHTransactionMarker
    (
        marker_id
    )
    VALUES
    (
        2
    );

    BEGIN TRY
        EXECUTE @rc = dbo.sp_HeapDoctor
            @Databases = N'HeapDoctorTest',
            @Tables = N'dbo.NLFHTestHeap',
            @CpuSource = 'NONE',
            @PlanOnly = 1,
            @Execute = N'Y',
            @LogToTable = N'Y',
            @MinPages = 10,
            @MinForwardedPct = 0;

        SET @returned = 1;
    END TRY
    BEGIN CATCH
        SET @caught = ERROR_MESSAGE();
    END CATCH;

    SET @trancount = @@TRANCOUNT;
    SET @xact_state = XACT_STATE();

    SELECT
        @marker_count = COUNT_BIG(*)
    FROM dbo.NLFHTransactionMarker
    WHERE marker_id = 2;

    SELECT
        @schema_modification_locks = COUNT_BIG(*)
    FROM sys.dm_tran_locks AS l
    WHERE l.request_session_id = @@SPID
    AND l.resource_database_id = DB_ID()
    AND l.request_mode = N'Sch-M'
    AND l.request_status = N'GRANT';

    SELECT
        @command_rows = COUNT_BIG(*)
    FROM dbo.CommandLog AS cl
    WHERE cl.StartTime >= @started
    AND cl.ObjectName = N'NLFHTestHeap';

    SELECT
        @during = SUM(ps.forwarded_record_count)
    FROM sys.dm_db_index_physical_stats
    (
        DB_ID(),
        OBJECT_ID(N'dbo.NLFHTestHeap'),
        0,
        NULL,
        'DETAILED'
    ) AS ps
    WHERE ps.index_id = 0
    AND ps.alloc_unit_type_desc = N'IN_ROW_DATA';

    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    SET @probe_error = ERROR_MESSAGE();
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;
END CATCH;

SELECT
    @after = SUM(ps.forwarded_record_count)
FROM sys.dm_db_index_physical_stats
(
    DB_ID(),
    OBJECT_ID(N'dbo.NLFHTestHeap'),
    0,
    NULL,
    'DETAILED'
) AS ps
WHERE ps.index_id = 0
AND ps.alloc_unit_type_desc = N'IN_ROW_DATA';

IF @returned = 0
AND @caught LIKE N'%cannot execute while a caller transaction is active%'
AND @probe_error IS NULL
AND @trancount = 1
AND @xact_state = 1
AND @marker_count = 1
AND @schema_modification_locks = 0
AND @command_rows = 0
AND @before > 0
AND @during = @before
AND @after = @before
    RAISERROR(N'PASS 44C: execution refused before DDL and preserved the caller transaction.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @failure_44c nvarchar(2048) = N'FAIL 44C: returned='
        + CONVERT(nvarchar(10), @returned)
        + N' error=' + ISNULL(@caught, N'NULL')
        + N' trancount=' + CONVERT(nvarchar(10), @trancount)
        + N' xact_state=' + CONVERT(nvarchar(10), @xact_state)
        + N' marker=' + CONVERT(nvarchar(20), @marker_count)
        + N' SchM=' + CONVERT(nvarchar(20), @schema_modification_locks)
        + N' command_rows=' + CONVERT(nvarchar(20), @command_rows)
        + N' before=' + ISNULL(CONVERT(nvarchar(20), @before), N'NULL')
        + N' during=' + ISNULL(CONVERT(nvarchar(20), @during), N'NULL')
        + N' after=' + ISNULL(CONVERT(nvarchar(20), @after), N'NULL') + N'.';
    RAISERROR(N'%s', 10, 1, @failure_44c) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 44D-IMPLICIT-TRANSACTION*/
DECLARE
    @before bigint = NULL,
    @after bigint = NULL,
    @started datetime2(3) = SYSDATETIME(),
    @returned bit = 0,
    @caught nvarchar(2048) = NULL,
    @trancount integer = 0,
    @xact_state integer = 0,
    @command_rows bigint = 0;

SELECT
    @before = SUM(ps.forwarded_record_count)
FROM sys.dm_db_index_physical_stats
(
    DB_ID(),
    OBJECT_ID(N'dbo.NLFHTestHeap'),
    0,
    NULL,
    'DETAILED'
) AS ps
WHERE ps.index_id = 0
AND ps.alloc_unit_type_desc = N'IN_ROW_DATA';

SET IMPLICIT_TRANSACTIONS ON;

BEGIN TRY
    EXECUTE dbo.sp_HeapDoctor
        @Databases = N'HeapDoctorTest',
        @Tables = N'dbo.NLFHTestHeap',
        @CpuSource = 'NONE',
        @PlanOnly = 0,
        @LogToTable = N'Y',
        @MinPages = 10,
        @MinForwardedPct = 0;

    SET @returned = 1;
END TRY
BEGIN CATCH
    SET @caught = ERROR_MESSAGE();
END CATCH;

SET @trancount = @@TRANCOUNT;
SET @xact_state = XACT_STATE();
SET IMPLICIT_TRANSACTIONS OFF;

IF @@TRANCOUNT > 0
    ROLLBACK TRANSACTION;

SELECT
    @after = SUM(ps.forwarded_record_count)
FROM sys.dm_db_index_physical_stats
(
    DB_ID(),
    OBJECT_ID(N'dbo.NLFHTestHeap'),
    0,
    NULL,
    'DETAILED'
) AS ps
WHERE ps.index_id = 0
AND ps.alloc_unit_type_desc = N'IN_ROW_DATA';

SELECT
    @command_rows = COUNT_BIG(*)
FROM dbo.CommandLog AS cl
WHERE cl.StartTime >= @started
AND cl.ObjectName = N'NLFHTestHeap';

IF @returned = 0
AND @caught LIKE N'%cannot execute while a caller transaction is active%'
AND @trancount = 0
AND @xact_state = 0
AND @command_rows = 0
AND @before > 0
AND @after = @before
    RAISERROR(N'PASS 44D: execution refused before opening an implicit transaction.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @failure_44d nvarchar(2048) = N'FAIL 44D: returned='
        + CONVERT(nvarchar(10), @returned)
        + N' error=' + ISNULL(@caught, N'NULL')
        + N' trancount=' + CONVERT(nvarchar(10), @trancount)
        + N' xact_state=' + CONVERT(nvarchar(10), @xact_state)
        + N' command_rows=' + CONVERT(nvarchar(20), @command_rows)
        + N' before=' + ISNULL(CONVERT(nvarchar(20), @before), N'NULL')
        + N' after=' + ISNULL(CONVERT(nvarchar(20), @after), N'NULL') + N'.';
    RAISERROR(N'%s', 10, 1, @failure_44d) WITH NOWAIT;
END

GO
/*#endregion*/

/*#region 44E-AUTOCOMMIT-CONTROL*/
DECLARE
    @before bigint = NULL,
    @after bigint = NULL,
    @started datetime2(3) = SYSDATETIME(),
    @returned bit = 0,
    @caught nvarchar(2048) = NULL,
    @successful_events bigint = 0,
    @trancount integer = 0,
    @xact_state integer = 0;

SELECT
    @before = SUM(ps.forwarded_record_count)
FROM sys.dm_db_index_physical_stats
(
    DB_ID(),
    OBJECT_ID(N'dbo.NLFHTestHeap'),
    0,
    NULL,
    'DETAILED'
) AS ps
WHERE ps.index_id = 0
AND ps.alloc_unit_type_desc = N'IN_ROW_DATA';

BEGIN TRY
    EXECUTE dbo.sp_HeapDoctor
        @Databases = N'HeapDoctorTest',
        @Tables = N'dbo.NLFHTestHeap',
        @CpuSource = 'NONE',
        @PlanOnly = 0,
        @LogToTable = N'Y',
        @MinPages = 10,
        @MinForwardedPct = 0;

    SET @returned = 1;
END TRY
BEGIN CATCH
    SET @caught = ERROR_MESSAGE();
END CATCH;

SET @trancount = @@TRANCOUNT;
SET @xact_state = XACT_STATE();

IF @@TRANCOUNT > 0
    ROLLBACK TRANSACTION;

SELECT
    @successful_events = COUNT_BIG(*)
FROM dbo.CommandLog AS cl
WHERE cl.StartTime >= @started
AND cl.ObjectName = N'NLFHTestHeap'
AND cl.CommandType = N'HEAP_TARGET_EVENT'
AND cl.ExtendedInfo.value('(/TargetEvent/OutcomeCode)[1]', 'nvarchar(30)') = N'SUCCEEDED';

SELECT
    @after = SUM(ps.forwarded_record_count)
FROM sys.dm_db_index_physical_stats
(
    DB_ID(),
    OBJECT_ID(N'dbo.NLFHTestHeap'),
    0,
    NULL,
    'DETAILED'
) AS ps
WHERE ps.index_id = 0
AND ps.alloc_unit_type_desc = N'IN_ROW_DATA';

IF @returned = 1
AND @caught IS NULL
AND @successful_events >= 1
AND @before > 0
AND @trancount = 0
AND @xact_state = 0
AND @after < @before
    RAISERROR(N'PASS 44E: autocommit execution rebuilt the heap and recorded success.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @failure_44e nvarchar(2048) = N'FAIL 44E: returned='
        + CONVERT(nvarchar(10), @returned)
        + N' error=' + ISNULL(@caught, N'NULL')
        + N' successful_events=' + CONVERT(nvarchar(20), @successful_events)
        + N' before=' + ISNULL(CONVERT(nvarchar(20), @before), N'NULL')
        + N' trancount=' + CONVERT(nvarchar(10), @trancount)
        + N' xact_state=' + CONVERT(nvarchar(10), @xact_state)
        + N' after=' + ISNULL(CONVERT(nvarchar(20), @after), N'NULL') + N'.';
    RAISERROR(N'%s', 10, 1, @failure_44e) WITH NOWAIT;
END
GO
/*#endregion*/

DROP TABLE dbo.NLFHTestHeap;
DROP TABLE dbo.NLFHTransactionMarker;
GO
