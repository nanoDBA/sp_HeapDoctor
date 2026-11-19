SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;
GO

/* Remove leftovers from an interrupted prior run. */
DECLARE @query_id bigint, @plan_id bigint;
DECLARE cleanup_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT p.query_id, p.plan_id
    FROM sys.query_store_plan AS p
    JOIN sys.query_store_query AS q ON q.query_id = p.query_id
    JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
    WHERE qt.query_sql_text LIKE N'%P2_Order_Items%';
OPEN cleanup_cursor;
FETCH NEXT FROM cleanup_cursor INTO @query_id, @plan_id;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC sys.sp_query_store_unforce_plan @query_id = @query_id, @plan_id = @plan_id;
    FETCH NEXT FROM cleanup_cursor INTO @query_id, @plan_id;
END;
CLOSE cleanup_cursor;
DEALLOCATE cleanup_cursor;
IF OBJECT_ID(N'dbo.P2_Order_Items', N'U') IS NOT NULL DROP TABLE dbo.P2_Order_Items;
IF OBJECT_ID(N'dbo.P2_OrderXItems', N'U') IS NOT NULL DROP TABLE dbo.P2_OrderXItems;
IF OBJECT_ID(N'p2other.P2_Order_Items', N'U') IS NOT NULL DROP TABLE p2other.P2_Order_Items;
IF SCHEMA_ID(N'p2other') IS NOT NULL DROP SCHEMA p2other;
GO

ALTER DATABASE HeapDoctorTest SET QUERY_STORE (QUERY_CAPTURE_MODE = ALL);
GO
CREATE SCHEMA p2other;
GO
CREATE TABLE dbo.P2_Order_Items (id int NOT NULL, pad varchar(4000) NOT NULL);
CREATE UNIQUE NONCLUSTERED INDEX UQ_P2_Order_Items ON dbo.P2_Order_Items(id);
CREATE TABLE dbo.P2_OrderXItems (id int NOT NULL, pad varchar(4000) NOT NULL);
CREATE UNIQUE NONCLUSTERED INDEX UQ_P2_OrderXItems ON dbo.P2_OrderXItems(id);
CREATE TABLE p2other.P2_Order_Items (id int NOT NULL, pad varchar(4000) NOT NULL);
CREATE UNIQUE NONCLUSTERED INDEX UQ_P2_Other_Order_Items ON p2other.P2_Order_Items(id);
GO

;WITH N AS
(
    SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT dbo.P2_Order_Items (id, pad) SELECT TOP (6000) n, 'x' FROM N;
;WITH N AS
(
    SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT dbo.P2_OrderXItems (id, pad) SELECT TOP (6000) n, 'x' FROM N;
;WITH N AS
(
    SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT p2other.P2_Order_Items (id, pad) SELECT TOP (6000) n, 'x' FROM N;
UPDATE dbo.P2_Order_Items SET pad = REPLICATE('x', 1500) WHERE id % 2 = 0;
UPDATE dbo.P2_OrderXItems SET pad = REPLICATE('x', 1500) WHERE id % 2 = 0;
UPDATE p2other.P2_Order_Items SET pad = REPLICATE('x', 1500) WHERE id % 2 = 0;
GO

DECLARE @iteration int = 0, @sink bigint, @forced int = 0;
WHILE @iteration < 25
BEGIN
    SELECT @sink = COUNT_BIG(*) FROM dbo.P2_Order_Items WHERE pad LIKE '%q%' OPTION (MAXDOP 1);
    SET @iteration += 1;
END;
EXEC sys.sp_query_store_flush_db;
DECLARE @query_id bigint, @plan_id bigint;
DECLARE force_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT p.query_id, p.plan_id
    FROM sys.query_store_plan AS p
    JOIN sys.query_store_query AS q ON q.query_id = p.query_id
    JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
    WHERE qt.query_sql_text LIKE N'%FROM dbo.P2_Order_Items WHERE%';
OPEN force_cursor;
FETCH NEXT FROM force_cursor INTO @query_id, @plan_id;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC sys.sp_query_store_force_plan @query_id = @query_id, @plan_id = @plan_id;
    SET @forced += 1;
    FETCH NEXT FROM force_cursor INTO @query_id, @plan_id;
END;
CLOSE force_cursor;
DEALLOCATE force_cursor;
EXEC sys.sp_query_store_flush_db;
IF @forced > 0
    RAISERROR(N'PASS 62A: forced-plan fixture was recorded.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 62A: no forced plan was recorded for the target.', 10, 1) WITH NOWAIT;
GO

SELECT TOP (0) * INTO #QueryStore FROM dbo.ResultsTemplate;
INSERT #QueryStore
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.P2_Order_Items, dbo.P2_OrderXItems, p2other.P2_Order_Items',
    @CpuSource = 'QUERY_STORE', @PlanOnly = 1, @LogToTable = N'N',
    @MinPages = 10, @MinForwardedPct = 0, @AllowCiSwap = 1, @PreferCiSwap = 1;

SELECT TOP (0) * INTO #None FROM dbo.ResultsTemplate;
INSERT #None
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.P2_Order_Items, dbo.P2_OrderXItems, p2other.P2_Order_Items',
    @CpuSource = 'NONE', @PlanOnly = 1, @LogToTable = N'N',
    @MinPages = 10, @MinForwardedPct = 0, @AllowCiSwap = 1, @PreferCiSwap = 1;

IF EXISTS (SELECT 1 FROM #QueryStore r JOIN dbo.ExpectedVersion e ON e.version = r.version
           WHERE r.schema_name = N'dbo' AND r.table_name = N'P2_Order_Items'
             AND r.action_chosen = N'HEAP_REBUILD_ONLINE')
   AND EXISTS (SELECT 1 FROM #None r JOIN dbo.ExpectedVersion e ON e.version = r.version
               WHERE r.schema_name = N'dbo' AND r.table_name = N'P2_Order_Items'
                 AND r.action_chosen = N'HEAP_REBUILD_ONLINE')
    RAISERROR(N'PASS 62B: forced target avoids CI swap with QUERY_STORE and NONE.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 62B: forced target was offered CI swap for a CPU source.', 10, 1) WITH NOWAIT;

IF EXISTS (SELECT 1 FROM #QueryStore r JOIN dbo.ExpectedVersion e ON e.version = r.version
           WHERE r.schema_name = N'dbo' AND r.table_name = N'P2_OrderXItems'
             AND r.action_chosen = N'CI_SWAP_ONLINE')
   AND EXISTS (SELECT 1 FROM #QueryStore r JOIN dbo.ExpectedVersion e ON e.version = r.version
               WHERE r.schema_name = N'p2other' AND r.table_name = N'P2_Order_Items'
                 AND r.action_chosen = N'CI_SWAP_ONLINE')
    RAISERROR(N'PASS 62C: underscore wildcard and same-name other-schema decoys remain eligible.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 62C: forced plan matched a decoy table.', 10, 1) WITH NOWAIT;
GO

SELECT TOP (0) * INTO #CollationScan FROM dbo.ResultsTemplate;
INSERT #CollationScan
EXEC master.dbo.sp_HeapDoctor
    @Databases=N'HeapDoctorCollationTest', @Tables=N'dbo.CollationHeap',
    @CpuSource=N'NONE', @PlanOnly=1, @LogToTable=N'N',
    @MinPages=1, @MinForwardedPct=0;
DECLARE @collation_targets int =
(
    SELECT COUNT(*) FROM #CollationScan r
    JOIN dbo.ExpectedVersion e ON e.version=r.version
    WHERE r.database_name=N'HeapDoctorCollationTest'
      AND r.table_name=N'CollationHeap'
      AND r.action_chosen IS NOT NULL
);
IF @collation_targets=1
    RAISERROR(N'PASS 62D: target collation selected only the requested case-sensitive heap.',10,1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 62D: the wrong collation selected a case-insensitive decoy or skipped the requested database.',10,1) WITH NOWAIT;
GO

/* Remove forced-plan state and fixtures so later tests start clean. */
DECLARE @query_id bigint, @plan_id bigint;
DECLARE cleanup_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT p.query_id, p.plan_id
    FROM sys.query_store_plan AS p
    JOIN sys.query_store_query AS q ON q.query_id = p.query_id
    JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
    WHERE qt.query_sql_text LIKE N'%P2_Order_Items%';
OPEN cleanup_cursor;
FETCH NEXT FROM cleanup_cursor INTO @query_id, @plan_id;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC sys.sp_query_store_unforce_plan @query_id = @query_id, @plan_id = @plan_id;
    FETCH NEXT FROM cleanup_cursor INTO @query_id, @plan_id;
END;
CLOSE cleanup_cursor;
DEALLOCATE cleanup_cursor;
DROP TABLE dbo.P2_Order_Items;
DROP TABLE dbo.P2_OrderXItems;
DROP TABLE p2other.P2_Order_Items;
DROP SCHEMA p2other;
ALTER DATABASE HeapDoctorTest SET QUERY_STORE (QUERY_CAPTURE_MODE = AUTO);
GO
