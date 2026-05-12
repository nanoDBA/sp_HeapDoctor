/*
sp_HeapDoctor concurrency demo - generates many heaps with forwarded records
so that multiple parallel workers actually overlap during queue drain.

Run AFTER 01_setup_test_data.sql to get baseline HeapDoctorTest + dbo.Queue + dbo.CommandLog.

Creates ConcurrencyHeap_001 through ConcurrencyHeap_050: each ~1300 pages,
~2500 forwarded records. Total rebuild time on test SQL is ~15-20 seconds
serial; with 2-4 workers expect ~5-10 seconds wall clock.
*/

SET NOCOUNT ON;
USE [HeapDoctorTest];
GO

RAISERROR(N'Creating 50 concurrency-demo heaps...', 10, 1) WITH NOWAIT;

/* Drop any leftover demo heaps from prior runs */
DECLARE @drop_sql nvarchar(max) = N'';
SELECT @drop_sql = STRING_AGG(N'DROP TABLE dbo.' + QUOTENAME(name) + N';', N' ')
FROM sys.tables WHERE name LIKE N'ConcurrencyHeap[_]%';
IF @drop_sql <> N''
    EXEC sys.sp_executesql @drop_sql;

/* Clear queue state from prior runs */
IF OBJECT_ID(N'dbo.QueueHeapRebuild', N'U') IS NOT NULL DROP TABLE dbo.QueueHeapRebuild;
DELETE FROM dbo.Queue;
GO

DECLARE @i int = 1;
DECLARE @sql nvarchar(max);
WHILE @i <= 50
BEGIN
    DECLARE @suffix nvarchar(10) = RIGHT(N'000' + CONVERT(nvarchar(10), @i), 3);
    DECLARE @tbl    sysname      = N'ConcurrencyHeap_' + @suffix;

    SET @sql = N'CREATE TABLE dbo.' + QUOTENAME(@tbl) + N' (
        ID int NOT NULL,
        Padding varchar(4000) NOT NULL,
        Padding2 varchar(4000) NULL
    );';
    EXEC sys.sp_executesql @sql;

    /* Narrow rows first, then UPDATE to widen -> forwarded records */
    SET @sql = N';WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
        INSERT dbo.' + QUOTENAME(@tbl) + N' (ID, Padding, Padding2)
        SELECT TOP (5000) n, REPLICATE(''A'', 10), NULL FROM N;
        UPDATE dbo.' + QUOTENAME(@tbl) + N'
        SET Padding = REPLICATE(''X'', 3000), Padding2 = REPLICATE(''Y'', 3000)
        WHERE ID <= 3500;';
    EXEC sys.sp_executesql @sql;

    SET @i = @i + 1;
END
GO

/* Quick verification */
SELECT
    HeapCount = COUNT_BIG(*),
    TotalForwarded = SUM(ips.forwarded_record_count),
    TotalPages = SUM(ips.page_count)
FROM sys.tables AS t
CROSS APPLY sys.dm_db_index_physical_stats(DB_ID(), t.object_id, 0, NULL, N'SAMPLED') AS ips
WHERE t.name LIKE N'ConcurrencyHeap[_]%' AND ips.index_id = 0;
GO

RAISERROR(N'Concurrency demo heaps ready. Launch N concurrent sp_HeapDoctor sessions with @HeapsInParallel=Y.', 10, 1) WITH NOWAIT;
