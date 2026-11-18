/* Test 46 verifies discovery metrics use weighted IN_ROW_DATA aggregates. */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;
GO

IF OBJECT_ID(N'dbo.UlqqLobHeapSmall') IS NOT NULL
    DROP TABLE dbo.UlqqLobHeapSmall;
IF OBJECT_ID(N'dbo.UlqqLobHeapLarge') IS NOT NULL
    DROP TABLE dbo.UlqqLobHeapLarge;
IF EXISTS (SELECT 1 FROM sys.partition_schemes WHERE name = N'ps_Ulqq')
    DROP PARTITION SCHEME ps_Ulqq;
IF EXISTS (SELECT 1 FROM sys.partition_functions WHERE name = N'pf_Ulqq')
    DROP PARTITION FUNCTION pf_Ulqq;

CREATE PARTITION FUNCTION pf_Ulqq (int)
AS RANGE RIGHT FOR VALUES (1000);
CREATE PARTITION SCHEME ps_Ulqq
AS PARTITION pf_Ulqq ALL TO ([PRIMARY]);

CREATE TABLE dbo.UlqqLobHeapSmall
(
    ID      int           NOT NULL,
    Padding varchar(4000) NULL,
    BigData varchar(max)  NULL
) ON ps_Ulqq(ID);

CREATE TABLE dbo.UlqqLobHeapLarge
(
    ID      int           NOT NULL,
    Padding varchar(4000) NULL,
    BigData varchar(max)  NULL
) ON ps_Ulqq(ID);

;WITH N AS
(
    SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
)
INSERT dbo.UlqqLobHeapSmall (ID, Padding, BigData)
SELECT TOP (4000) n, REPLICATE('A', 10), REPLICATE(CAST('L' AS varchar(max)), 16000)
FROM N;

;WITH N AS
(
    SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
)
INSERT dbo.UlqqLobHeapLarge (ID, Padding, BigData)
SELECT TOP (4000) n, REPLICATE('A', 10), REPLICATE(CAST('L' AS varchar(max)), 32000)
FROM N;

UPDATE dbo.UlqqLobHeapSmall
SET Padding = REPLICATE('X', 3000)
WHERE ID <= 3000;
UPDATE dbo.UlqqLobHeapLarge
SET Padding = REPLICATE('X', 3000)
WHERE ID <= 3000;
GO

DECLARE
    @small_pages bigint = NULL,
    @large_pages bigint = NULL,
    @small_lob_pages bigint = NULL,
    @large_lob_pages bigint = NULL,
    @small_records bigint = NULL,
    @large_records bigint = NULL,
    @small_forwarded bigint = NULL,
    @large_forwarded bigint = NULL,
    @small_pct decimal(6,2) = NULL,
    @large_pct decimal(6,2) = NULL,
    @small_density decimal(5,2) = NULL,
    @large_density decimal(5,2) = NULL,
    @small_fragmentation decimal(5,2) = NULL,
    @large_fragmentation decimal(5,2) = NULL,
    @reported_small_records bigint = NULL,
    @reported_large_records bigint = NULL,
    @reported_small_forwarded bigint = NULL,
    @reported_large_forwarded bigint = NULL,
    @reported_small_pages bigint = NULL,
    @reported_large_pages bigint = NULL,
    @reported_small_pct decimal(6,2) = NULL,
    @reported_large_pct decimal(6,2) = NULL,
    @reported_small_density decimal(5,2) = NULL,
    @reported_large_density decimal(5,2) = NULL,
    @reported_small_fragmentation decimal(5,2) = NULL,
    @reported_large_fragmentation decimal(5,2) = NULL,
    @failure_detail nvarchar(2048) = NULL;

SELECT
    @small_pages = SUM(page_count),
    @small_lob_pages = SUM(CASE WHEN alloc_unit_type_desc = N'LOB_DATA' THEN page_count ELSE 0 END),
    @small_records = SUM(CASE WHEN alloc_unit_type_desc = N'IN_ROW_DATA' THEN record_count ELSE 0 END),
    @small_forwarded = SUM(CASE WHEN alloc_unit_type_desc = N'IN_ROW_DATA' THEN forwarded_record_count ELSE 0 END),
    @small_pct = CONVERT
    (
        decimal(6,2),
        100.0 * SUM(CASE WHEN alloc_unit_type_desc = N'IN_ROW_DATA' THEN forwarded_record_count ELSE 0 END)
        / NULLIF(SUM(CASE WHEN alloc_unit_type_desc = N'IN_ROW_DATA' THEN record_count ELSE 0 END), 0)
    ),
    @small_density = CONVERT
    (
        decimal(5,2),
        SUM(CASE WHEN alloc_unit_type_desc = N'IN_ROW_DATA' THEN avg_page_space_used_in_percent * page_count END)
        / NULLIF(SUM(CASE WHEN alloc_unit_type_desc = N'IN_ROW_DATA' THEN page_count END), 0)
    ),
    @small_fragmentation = CONVERT
    (
        decimal(5,2),
        SUM(CASE WHEN alloc_unit_type_desc = N'IN_ROW_DATA' THEN avg_fragmentation_in_percent * page_count END)
        / NULLIF(SUM(CASE WHEN alloc_unit_type_desc = N'IN_ROW_DATA' THEN page_count END), 0)
    )
FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(N'dbo.UlqqLobHeapSmall'), 0, NULL, 'DETAILED');

SELECT
    @large_pages = SUM(page_count),
    @large_lob_pages = SUM(CASE WHEN alloc_unit_type_desc = N'LOB_DATA' THEN page_count ELSE 0 END),
    @large_records = SUM(CASE WHEN alloc_unit_type_desc = N'IN_ROW_DATA' THEN record_count ELSE 0 END),
    @large_forwarded = SUM(CASE WHEN alloc_unit_type_desc = N'IN_ROW_DATA' THEN forwarded_record_count ELSE 0 END),
    @large_pct = CONVERT
    (
        decimal(6,2),
        100.0 * SUM(CASE WHEN alloc_unit_type_desc = N'IN_ROW_DATA' THEN forwarded_record_count ELSE 0 END)
        / NULLIF(SUM(CASE WHEN alloc_unit_type_desc = N'IN_ROW_DATA' THEN record_count ELSE 0 END), 0)
    ),
    @large_density = CONVERT
    (
        decimal(5,2),
        SUM(CASE WHEN alloc_unit_type_desc = N'IN_ROW_DATA' THEN avg_page_space_used_in_percent * page_count END)
        / NULLIF(SUM(CASE WHEN alloc_unit_type_desc = N'IN_ROW_DATA' THEN page_count END), 0)
    ),
    @large_fragmentation = CONVERT
    (
        decimal(5,2),
        SUM(CASE WHEN alloc_unit_type_desc = N'IN_ROW_DATA' THEN avg_fragmentation_in_percent * page_count END)
        / NULLIF(SUM(CASE WHEN alloc_unit_type_desc = N'IN_ROW_DATA' THEN page_count END), 0)
    )
FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(N'dbo.UlqqLobHeapLarge'), 0, NULL, 'DETAILED');

IF @small_forwarded > 0
AND @large_forwarded > 0
AND @small_lob_pages > 0
AND @large_lob_pages > @small_lob_pages
    RAISERROR(N'PASS 46A: partitioned heaps have forwarded rows and different off-row LOB sizes.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 46A: partitioned LOB fixtures do not have the expected shape.', 10, 1) WITH NOWAIT;

SELECT *
INTO #Results
FROM dbo.ResultsTemplate
WHERE 1 = 0;

INSERT INTO #Results
EXECUTE dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.UlqqLobHeapSmall, dbo.UlqqLobHeapLarge',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @MinPages = 1,
    @MinForwardedPct = 0,
    @ScanMode = N'DETAILED',
    @LogToTable = N'N';

SELECT
    @reported_small_records = record_count,
    @reported_small_forwarded = forwarded_record_count,
    @reported_small_pages = page_count,
    @reported_small_pct = forwarded_pct,
    @reported_small_density = avg_page_space_pct,
    @reported_small_fragmentation = avg_frag_pct
FROM #Results
WHERE table_name = N'UlqqLobHeapSmall';

SELECT
    @reported_large_records = record_count,
    @reported_large_forwarded = forwarded_record_count,
    @reported_large_pages = page_count,
    @reported_large_pct = forwarded_pct,
    @reported_large_density = avg_page_space_pct,
    @reported_large_fragmentation = avg_frag_pct
FROM #Results
WHERE table_name = N'UlqqLobHeapLarge';

IF @reported_small_records = @small_records
AND @reported_small_forwarded = @small_forwarded
AND @reported_small_pages = @small_pages
AND @reported_small_pct = @small_pct
AND @reported_small_density = @small_density
AND @reported_small_fragmentation = @small_fragmentation
AND @reported_large_records = @large_records
AND @reported_large_forwarded = @large_forwarded
AND @reported_large_pages = @large_pages
AND @reported_large_pct = @large_pct
AND @reported_large_density = @large_density
AND @reported_large_fragmentation = @large_fragmentation
    RAISERROR(N'PASS 46B: discovery row metrics and density match weighted IN_ROW_DATA, while page count includes all units.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 46B: discovery metrics do not match the expected allocation-unit aggregates.', 10, 1) WITH NOWAIT;

IF @large_lob_pages > @small_lob_pages
AND @reported_small_pct = @small_pct
AND @reported_large_pct = @large_pct
AND @reported_small_density = @small_density
AND @reported_large_density = @large_density
    RAISERROR(N'PASS 46C: increasing off-row LOB pages does not distort either IN_ROW_DATA percentage or density.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    SET @failure_detail = N'FAIL 46C: LOB pages '
        + COALESCE(CONVERT(nvarchar(20), @small_lob_pages), N'<NULL>')
        + N'/' + COALESCE(CONVERT(nvarchar(20), @large_lob_pages), N'<NULL>')
        + N'; expected pct '
        + COALESCE(CONVERT(nvarchar(20), @small_pct), N'<NULL>')
        + N'/' + COALESCE(CONVERT(nvarchar(20), @large_pct), N'<NULL>')
        + N'; reported pct '
        + COALESCE(CONVERT(nvarchar(20), @reported_small_pct), N'<NULL>')
        + N'/' + COALESCE(CONVERT(nvarchar(20), @reported_large_pct), N'<NULL>')
        + N'; expected density '
        + COALESCE(CONVERT(nvarchar(20), @small_density), N'<NULL>')
        + N'/' + COALESCE(CONVERT(nvarchar(20), @large_density), N'<NULL>')
        + N'; reported density '
        + COALESCE(CONVERT(nvarchar(20), @reported_small_density), N'<NULL>')
        + N'/' + COALESCE(CONVERT(nvarchar(20), @reported_large_density), N'<NULL>') + N'.';
    RAISERROR(@failure_detail, 10, 1) WITH NOWAIT;
END

DROP TABLE dbo.UlqqLobHeapSmall;
DROP TABLE dbo.UlqqLobHeapLarge;
DROP PARTITION SCHEME ps_Ulqq;
DROP PARTITION FUNCTION pf_Ulqq;
GO
