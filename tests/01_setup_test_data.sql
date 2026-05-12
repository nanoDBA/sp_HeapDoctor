/*
sp_HeapDoctor Test Harness - Step 1: Setup Test Data

Creates a test database with:
  - Heap tables with forwarded records
  - A table with a unique NC index (for CI swap testing)
  - A table with LOB columns (CI swap should be skipped)
  - Query Store enabled so CPU ranking can be tested

Run with:
  Windows auth:  sqlcmd -S YourServer -E -i 01_setup_test_data.sql
  SQL auth:      sqlcmd -S YourServer -U sa -P YourPassword -i 01_setup_test_data.sql
  Azure AD:      sqlcmd -S YourServer -G -i 01_setup_test_data.sql
*/

SET NOCOUNT ON;

RAISERROR(N'=== sp_HeapDoctor Test Setup ===', 10, 1) WITH NOWAIT;

------------------------------------------------------------------------
-- 1) Create test database
------------------------------------------------------------------------
IF DB_ID(N'HeapDoctorTest') IS NOT NULL
BEGIN
    RAISERROR(N'Dropping existing HeapDoctorTest database...', 10, 1) WITH NOWAIT;
    ALTER DATABASE [HeapDoctorTest] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [HeapDoctorTest];
END

RAISERROR(N'Creating HeapDoctorTest database...', 10, 1) WITH NOWAIT;
-- Log file sized at 300MB to accommodate multiple online heap rebuilds (each ~20MB log usage).
-- Without adequate log space, the LOG_SPACE_INSUFFICIENT guard will skip targets.
-- FILENAME must be specified on Linux SQL Server (/var/opt/mssql/data/ is the default data dir).
CREATE DATABASE [HeapDoctorTest]
    ON  PRIMARY (NAME = N'HeapDoctorTest',     FILENAME = N'/var/opt/mssql/data/HeapDoctorTest.mdf',     SIZE = 300MB, MAXSIZE = UNLIMITED, FILEGROWTH = 100MB)
    LOG ON      (NAME = N'HeapDoctorTest_log', FILENAME = N'/var/opt/mssql/data/HeapDoctorTest_log.ldf', SIZE = 300MB, MAXSIZE = UNLIMITED, FILEGROWTH = 100MB);
GO
-- Use SIMPLE recovery so log can be auto-truncated (no log backups needed for test DB).
ALTER DATABASE [HeapDoctorTest] SET RECOVERY SIMPLE;
GO

-- Enable Query Store
ALTER DATABASE [HeapDoctorTest] SET QUERY_STORE = ON;
ALTER DATABASE [HeapDoctorTest] SET QUERY_STORE
(
    OPERATION_MODE = READ_WRITE,
    INTERVAL_LENGTH_MINUTES = 1
);
GO

USE [HeapDoctorTest];
GO

------------------------------------------------------------------------
-- 2) Create CommandLog (Ola Hallengren pattern)
------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.CommandLog', N'U') IS NULL
BEGIN
    RAISERROR(N'Creating dbo.CommandLog table...', 10, 1) WITH NOWAIT;

    CREATE TABLE dbo.CommandLog
    (
        ID             int           IDENTITY(1,1) NOT NULL PRIMARY KEY,
        DatabaseName   sysname       NULL,
        SchemaName     sysname       NULL,
        ObjectName     sysname       NULL,
        ObjectType     char(2)       NULL,
        IndexName      sysname       NULL,
        IndexType      tinyint       NULL,
        StatisticsName sysname       NULL,
        PartitionNumber int          NULL,
        ExtendedInfo   xml           NULL,
        Command        nvarchar(max) NOT NULL,
        CommandType    nvarchar(60)  NOT NULL,
        StartTime      datetime2(3)  NOT NULL,
        EndTime        datetime2(3)  NULL,
        ErrorNumber    int           NULL,
        ErrorMessage   nvarchar(max) NULL
    );
END
ELSE
BEGIN
    RAISERROR(N'dbo.CommandLog already exists, skipping creation.', 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
-- 3) Create test heaps
------------------------------------------------------------------------

-- Heap A: simple heap with varchar columns (will create forwarded records)
RAISERROR(N'Creating dbo.HeapA (simple varchar heap)...', 10, 1) WITH NOWAIT;
CREATE TABLE dbo.HeapA
(
    ID       int          NOT NULL,
    Padding  varchar(4000) NOT NULL,
    MoreData varchar(4000) NULL
);

-- Heap B: heap with unique NC index (CI swap candidate)
RAISERROR(N'Creating dbo.HeapB (heap with unique NC index)...', 10, 1) WITH NOWAIT;
CREATE TABLE dbo.HeapB
(
    ID       int           NOT NULL,
    Code     varchar(50)   NOT NULL,
    Padding  varchar(4000) NOT NULL,
    MoreData varchar(4000) NULL
);
CREATE UNIQUE NONCLUSTERED INDEX UX_HeapB_ID ON dbo.HeapB(ID);

-- Heap C: heap with LOB column (CI swap should be skipped)
RAISERROR(N'Creating dbo.HeapC (heap with LOB column)...', 10, 1) WITH NOWAIT;
CREATE TABLE dbo.HeapC
(
    ID       int           NOT NULL,
    Padding  varchar(4000) NOT NULL,
    BigData  varchar(max)  NULL
);

-- Heap D: tiny heap (should be filtered out by @MinPages)
RAISERROR(N'Creating dbo.HeapD (tiny heap, should be filtered out)...', 10, 1) WITH NOWAIT;
CREATE TABLE dbo.HeapD
(
    ID       int           NOT NULL,
    Padding  varchar(200)  NOT NULL
);
GO

------------------------------------------------------------------------
-- 4) Populate tables and create forwarded records
------------------------------------------------------------------------
RAISERROR(N'Inserting rows into HeapA (short initial rows)...', 10, 1) WITH NOWAIT;

-- Insert rows with short padding first
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapA (ID, Padding, MoreData)
SELECT TOP (20000)
    n,
    REPLICATE('A', 10),  -- short initial padding
    NULL
FROM N;

RAISERROR(N'Updating HeapA to create forwarded records...', 10, 1) WITH NOWAIT;

-- Expand rows to create forwarded records
UPDATE dbo.HeapA
SET Padding = REPLICATE('X', 3000),
    MoreData = REPLICATE('Y', 3000)
WHERE ID <= 15000;

RAISERROR(N'Inserting rows into HeapB...', 10, 1) WITH NOWAIT;

;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapB (ID, Code, Padding, MoreData)
SELECT TOP (20000)
    n,
    'CODE-' + CAST(n AS varchar(10)),
    REPLICATE('B', 10),
    NULL
FROM N;

RAISERROR(N'Updating HeapB to create forwarded records...', 10, 1) WITH NOWAIT;

UPDATE dbo.HeapB
SET Padding = REPLICATE('X', 3000),
    MoreData = REPLICATE('Y', 3000)
WHERE ID <= 15000;

RAISERROR(N'Inserting rows into HeapC...', 10, 1) WITH NOWAIT;

;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapC (ID, Padding, BigData)
SELECT TOP (20000)
    n,
    REPLICATE('C', 10),
    NULL
FROM N;

RAISERROR(N'Updating HeapC to create forwarded records...', 10, 1) WITH NOWAIT;

UPDATE dbo.HeapC
SET Padding = REPLICATE('X', 3000),
    BigData = REPLICATE(CAST('Z' AS varchar(max)), 500)
WHERE ID <= 15000;

RAISERROR(N'Inserting rows into HeapD (tiny heap)...', 10, 1) WITH NOWAIT;

INSERT dbo.HeapD (ID, Padding)
SELECT TOP (50) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), REPLICATE('D', 50)
FROM sys.all_objects;
GO

------------------------------------------------------------------------
-- 5) Batch 6: Create additional test objects
------------------------------------------------------------------------

-- HeapE: heap with PAGE compression (CI swap should preserve compression)
RAISERROR(N'Creating dbo.HeapE (PAGE compressed heap for CI swap test)...', 10, 1) WITH NOWAIT;
CREATE TABLE dbo.HeapE
(
    ID       int           NOT NULL,
    Code     varchar(50)   NOT NULL,
    Padding  varchar(4000) NOT NULL,
    MoreData varchar(4000) NULL
) WITH (DATA_COMPRESSION = PAGE);
CREATE UNIQUE NONCLUSTERED INDEX UX_HeapE_ID ON dbo.HeapE(ID);

;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapE (ID, Code, Padding, MoreData)
SELECT TOP (20000) n, 'CODE-' + CAST(n AS varchar(10)), REPLICATE('E', 10), NULL FROM N;

UPDATE dbo.HeapE
SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000)
WHERE ID <= 15000;

-- HeapF: heap with ROW compression (ALTER TABLE REBUILD should preserve compression)
RAISERROR(N'Creating dbo.HeapF (ROW compressed heap for rebuild test)...', 10, 1) WITH NOWAIT;
CREATE TABLE dbo.HeapF
(
    ID       int           NOT NULL,
    Padding  varchar(4000) NOT NULL,
    MoreData varchar(4000) NULL
) WITH (DATA_COMPRESSION = ROW);

;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapF (ID, Padding, MoreData)
SELECT TOP (20000) n, REPLICATE('F', 10), NULL FROM N;

UPDATE dbo.HeapF
SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000)
WHERE ID <= 15000;

-- HeapTemporal: system-versioned temporal heap (should be EXCLUDED from discovery)
RAISERROR(N'Creating dbo.HeapTemporal (temporal table, should be excluded)...', 10, 1) WITH NOWAIT;
CREATE TABLE dbo.HeapTemporal
(
    ID        int           NOT NULL PRIMARY KEY NONCLUSTERED,
    Padding   varchar(4000) NOT NULL,
    SysStart  datetime2     GENERATED ALWAYS AS ROW START NOT NULL,
    SysEnd    datetime2     GENERATED ALWAYS AS ROW END   NOT NULL,
    PERIOD FOR SYSTEM_TIME (SysStart, SysEnd)
) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.HeapTemporalHistory));

;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapTemporal (ID, Padding)
SELECT TOP (20000) n, REPLICATE('T', 10) FROM N;

UPDATE dbo.HeapTemporal
SET Padding = REPLICATE('X', 3000)
WHERE ID <= 15000;
GO

------------------------------------------------------------------------
-- 6) Generate Query Store CPU data by running queries
------------------------------------------------------------------------
RAISERROR(N'Running queries to populate Query Store CPU data...', 10, 1) WITH NOWAIT;

-- Run scans to build QS stats
DECLARE @sink int;
DECLARE @iter int = 1;
WHILE @iter <= 20
BEGIN
    SELECT @sink = COUNT(*) FROM dbo.HeapA WHERE Padding LIKE '%X%';
    SELECT @sink = COUNT(*) FROM dbo.HeapB WHERE Padding LIKE '%X%';
    SELECT @sink = COUNT(*) FROM dbo.HeapC WHERE Padding LIKE '%X%';
    SELECT @sink = COUNT(*) FROM dbo.HeapE WHERE Padding LIKE '%X%';
    SELECT @sink = COUNT(*) FROM dbo.HeapF WHERE Padding LIKE '%X%';
    SET @iter += 1;
END

-- Force QS flush
EXEC sys.sp_query_store_flush_db;
GO

------------------------------------------------------------------------
-- 6) Verify setup
------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Verification ===', 10, 1) WITH NOWAIT;

SELECT
    t.name AS table_name,
    ips.page_count,
    ips.record_count,
    ips.forwarded_record_count,
    CAST(100.0 * ips.forwarded_record_count / NULLIF(ips.record_count, 0) AS decimal(6,2)) AS forwarded_pct
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'SAMPLED') ips
JOIN sys.objects t ON ips.object_id = t.object_id
WHERE ips.index_id = 0
  AND t.type = 'U'
ORDER BY t.name;

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Setup complete. Run the test scripts next.', 10, 1) WITH NOWAIT;
GO
