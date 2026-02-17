SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

/*

sp_HeapDoctor - Heap Forwarded Record Mitigation

Copyright (c) 2026 Community Contribution

Purpose:    Find heaps with forwarded records, rank them by CPU impact, and rebuild
            them to eliminate forwarded records and reclaim space.

            Forwarded records occur when a variable-length row on a heap grows beyond
            its original page. SQL Server leaves a forwarding pointer on the old page
            and moves the row to a new page. This doubles the I/O cost for every read
            that hits the forwarding pointer. At scale, forwarded records silently
            degrade scan and seek performance on heaps.

            This procedure automates the detection-and-fix cycle that most DBAs do
            manually: find heaps with forwarded records, decide which matter most
            (by CPU cost), and rebuild them - with online operations where possible.

Based on:   Ola Hallengren's SQL Server Maintenance Solution (MIT License)
            https://ola.hallengren.com
            Patterns: @Databases parameter, CommandLog logging, @TimeLimit

            Erik Darling's sp_QuickieStore
            https://github.com/erikdarlingdata/DarlingData
            Integration: Optional CPU source via sp_QuickieStore output

License:    MIT License

            Permission is hereby granted, free of charge, to any person obtaining a copy
            of this software and associated documentation files (the "Software"), to deal
            in the Software without restriction, including without limitation the rights
            to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
            copies of the Software, and to permit persons to whom the Software is
            furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all
            copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
            FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
            AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
            LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
            OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
            SOFTWARE.

Version:    1.5.2026.0216

History:    1.5.2026.0216 - CI swap DROP failure handling, lock timeout restore
                          - CI swap DROP failure: skips post-rebuild verification, sets @post_fwd_count=0
                          - Lock timeout now restored in CATCH blocks (main rebuild + CI swap DROP)
                          - CI swap DROP INDEX now respects @Maxdop (was only on CREATE)
            1.3.2026.0216 - Input validation, SKIPPED logging, test hardening
                          - @LockTimeoutMs and @MaxRunSeconds reject negative values
                          - ExecLog output ordered by start_time (not target_id)
                          - SKIPPED targets (from @MaxRunSeconds) logged to CommandLog with ExtendedInfo
            1.2.2026.0216 - Test-driven bug fixes
                          - @Debug parameter now functional (database list, target details)
                          - @OnlinePreference='ON' warns when edition forces offline fallback
                          - SizeMB in CommandLog ExtendedInfo uses decimal instead of integer division
                          - QUICKIESTORE path re-ranks targets after CPU update
            1.1.2026.0216 - Pre-release hardening
                          - Azure SQL DB / Managed Instance edition detection via EngineEdition
                          - XPath filter: Table Scan RelOps only (no false CPU from index seeks)
                          - QS XML pre-filter: LIKE on plan text before TRY_CONVERT(xml)
                          - Mixed ranking: CPU + (forwarded_pct * page_count), NULL CPU no longer
                            penalized vs low CPU
                          - ranking_basis column in output (QS_CPU / QS_NO_DATA / FWD_PCT)
                          - nci_count column in output (warns about CI swap NCI rebuild cost)
                          - Post-rebuild verification via dm_db_index_physical_stats
                          - PostRebuildForwardedRecords in CommandLog ExtendedInfo XML
                          - Memory-optimized table guard (is_memory_optimized = 0)
                          - Columnstore index guard (skip heaps with NCI columnstore)
                          - @LogToTable case-insensitive (UPPER before compare)
                          - Version in target list result set
            1.0.2026.0216 - Initial release
                          - Query Store CPU ranking via showplan XML object mapping
                          - sp_QuickieStore integration as alternative CPU source
                          - CI swap: auto-detects safe unique NC key, LOB-aware guard
                          - Online/offline rebuild with edition detection
                          - Ola Hallengren @Databases parameter (USER_DATABASES, wildcards,
                            exclusions, comma-separated)
                          - CommandLog logging (HEAP_REBUILD_START/END bracketing,
                            per-rebuild ExtendedInfo XML)
                          - Per-rebuild LOCK_TIMEOUT (prepend/restore pattern)
                          - MAXDOP on all rebuild paths
                          - @MaxRunSeconds time limit with SKIPPED logging
                          - 3-part names on all generated commands
                          - RAISERROR WITH NOWAIT progress throughout

Key Features:
    - CPU-prioritized rebuilds via Query Store showplan XML
    - sp_QuickieStore integration as alternative CPU source
    - CI swap technique with auto key detection + LOB awareness
    - Online rebuild support (Enterprise/Developer edition detection)
    - Ola Hallengren @Databases parameter for multi-database targeting
    - CommandLog logging with HEAP_REBUILD_START/END bracketing
    - Per-rebuild lock timeout with session restore
    - @MaxRunSeconds time limit (remaining targets logged as SKIPPED)
    - @PlanOnly dry-run mode (default) with target list + command output

DROP-IN COMPATIBILITY with Ola Hallengren's SQL Server Maintenance Solution:
    https://ola.hallengren.com

    REQUIRED:
      - dbo.CommandLog table in the current database
        (https://ola.hallengren.com/scripts/CommandLog.sql)
        Set @LogToTable = 'N' if you don't have it.

    NOT REQUIRED:
      - dbo.CommandExecute - this proc handles its own command execution

Requirements:
    - SQL Server 2017+ or later (uses STRING_AGG which requires 2017+;
      also uses TRY_CONVERT, IIF, SYSDATETIME, sp_describe_first_result_set)
    - Enterprise or Developer edition for online rebuilds (Standard uses offline)

Limitations:
    - QUICKIESTORE CPU source works for the current database context only.
      Multi-database CPU ranking requires QUERY_STORE (per-database QS queries).
    - SAMPLED mode for dm_db_index_physical_stats: can be slow on databases with
      many tables/indexes. @MinPages helps skip small heaps.
    - CI swap is philosophically debated. Paul Randal warns that nonclustered
      indexes get rebuilt when a clustered index is created and again when dropped.
      Use @AllowCiSwap only when you understand the trade-off (the proc guards
      against LOB columns and requires a safe unique key).
    - AG secondary databases are automatically skipped (read-only, cannot rebuild).

===============================================================================
How to use it
===============================================================================

1) Plan-only for the current database (recommended starting point)

EXEC dbo.sp_HeapDoctor
    @PlanOnly          = 1;

2) Scan all user databases

EXEC dbo.sp_HeapDoctor
    @Databases         = 'USER_DATABASES',
    @PlanOnly          = 1;

3) Specific databases with exclusions

EXEC dbo.sp_HeapDoctor
    @Databases         = 'USER_DATABASES, -ReportingArchive',
    @MinPages          = 5000,
    @PlanOnly          = 1;

4) Execute online rebuilds with lock timeout

EXEC dbo.sp_HeapDoctor
    @PlanOnly          = 0,
    @OnlinePreference  = 'AUTO',
    @LockTimeoutMs     = 5000;

5) Use sp_QuickieStore as CPU source (single-database only)

EXEC dbo.sp_HeapDoctor
    @CpuSource           = 'QUICKIESTORE',
    @QuickieExecSql      = N'EXEC dbo.sp_QuickieStore @Top=200, @SortOrder=''cpu'';',
    @QuickiePlanIdColumn = N'plan_id',
    @QuickieCpuUsColumn  = N'avg_cpu_time',
    @QuickieCpuUnit      = 'us',
    @PlanOnly            = 1;

6) CI-swap when safe unique key exists (Enterprise/Developer only)

EXEC dbo.sp_HeapDoctor
    @AllowCiSwap       = 1,
    @PreferCiSwap      = 1,
    @OnlinePreference  = 'AUTO',
    @PlanOnly          = 1;

7) Execute with time limit and parallelism control

EXEC dbo.sp_HeapDoctor
    @PlanOnly          = 0,
    @MaxRunSeconds     = 3600,
    @Maxdop            = 2;

8) Skip CPU ranking entirely (just use forwarded_pct)

EXEC dbo.sp_HeapDoctor
    @CpuSource         = 'NONE',
    @Databases         = 'USER_DATABASES',
    @PlanOnly          = 1;

9) Execute without CommandLog logging

EXEC dbo.sp_HeapDoctor
    @PlanOnly          = 0,
    @LogToTable        = N'N';

10) Query CommandLog for rebuild history

SELECT *
FROM dbo.CommandLog
WHERE CommandType LIKE 'HEAP_REBUILD%'
ORDER BY StartTime DESC;

-- Recent run summaries:
SELECT CommandType, StartTime, EndTime, ExtendedInfo
FROM dbo.CommandLog
WHERE CommandType IN ('HEAP_REBUILD_START', 'HEAP_REBUILD_END')
ORDER BY StartTime DESC;

===============================================================================
Notes
===============================================================================

@Databases parameter (Ola Hallengren pattern):
  NULL            = current database only
  USER_DATABASES  = all user databases (excludes master, msdb, model, tempdb)
  ALL_DATABASES   = same as USER_DATABASES (excludes system DBs)
  SYSTEM_DATABASES = master, msdb, model only
  AVAILABILITY_GROUP_DATABASES = databases in AG
  Wildcards:      'Prod%' matches ProdDB, ProdArchive, etc.
  Exclusions:     'USER_DATABASES, -ReportingArchive' = all user DBs except one
  Comma-separated: 'DB1, DB2, DB3'

CI-swap path:
  Creates a temporary clustered index using a safe unique NC key, then drops it.
  This eliminates forwarded records by physically reordering the data. The DROP
  returns the table to heap structure. CI swap will NOT be attempted if:
  - No suitable unique, non-filtered, non-nullable NC index exists
  - The table contains LOB columns (text, ntext, image, xml, MAX types)
    because DROP INDEX WITH (ONLINE = ON) does not support LOB columns.

Lock timeout:
  @LockTimeoutMs is prepended to each rebuild command so the timeout applies
  within the same execution scope as the rebuild. The original session
  @@LOCK_TIMEOUT is restored after each command.

SAMPLED mode:
  The initial heap scan uses dm_db_index_physical_stats with SAMPLED mode
  per database. This can be slow on databases with many tables. @MinPages
  helps skip small tables.

Commands use 3-part names:
  All generated rebuild commands use [DatabaseName].[SchemaName].[TableName]
  so they execute correctly regardless of the session's current database context.

CommandLog (Ola Hallengren pattern):
  When @LogToTable = 'Y' (default) and dbo.CommandLog exists in the current
  database, each rebuild is logged with: DatabaseName, SchemaName, ObjectName,
  Command, CommandType (HEAP_REBUILD_ONLINE / HEAP_REBUILD_OFFLINE /
  CI_SWAP_ONLINE), StartTime, EndTime, ErrorNumber, ErrorMessage, and
  ExtendedInfo XML containing PageCount, SizeMB, ForwardedRecords, ForwardedPct,
  TotalCpuMs. A HEAP_REBUILD_START and HEAP_REBUILD_END entry bracket the
  overall run.
  Create the CommandLog table from: https://ola.hallengren.com/scripts/CommandLog.sql
*/

CREATE OR ALTER PROCEDURE dbo.sp_HeapDoctor
(
    @Help                    bit            = 0,               -- 1 = print parameter documentation and return

    -- Target selection
    @Databases               nvarchar(max)  = NULL,            -- NULL = current DB. Supports: USER_DATABASES, ALL_DATABASES,
                                                                -- SYSTEM_DATABASES, AVAILABILITY_GROUP_DATABASES,
                                                                -- wildcards (%), exclusions (-), comma-separated
    @LookbackDays            int            = 7,
    @TopN                    int            = 25,               -- per database
    @MinPages                bigint         = 1000,
    @MaxPages                bigint         = NULL,            -- NULL = no cap; else only heaps with page_count <= @MaxPages
    @MinForwardedPct         decimal(6,2)   = 2.00,

    -- CPU source
    @CpuSource               varchar(20)    = 'QUERY_STORE',   -- QUERY_STORE | QUICKIESTORE | NONE
    @QuickieExecSql          nvarchar(max)  = NULL,            -- e.g. N'EXEC dbo.sp_QuickieStore @Top=50, @SortOrder=''cpu'';'
    @QuickiePlanIdColumn     sysname        = N'plan_id',      -- column name in Quickie output
    @QuickieCpuUsColumn      sysname        = N'avg_cpu_time', -- OR cpu_us / cpu_ms etc; see @QuickieCpuUnit
    @QuickieCpuUnit          varchar(10)    = 'us',            -- us | ms  (unit of @QuickieCpuUsColumn)

    -- Actions
    @OnlinePreference        varchar(10)    = 'AUTO',          -- AUTO (use edition), ON (require), OFF (force offline)
    @AllowCiSwap             bit            = 0,               -- enable CI swap path at all
    @PreferCiSwap            bit            = 0,               -- if 1, use CI swap when safe key exists + online allowed

    -- Execution
    @PlanOnly                bit            = 1,               -- 1 = print commands only, 0 = execute
    @Maxdop                  int            = NULL,            -- optional MAXDOP on index ops (NULL = omit)
    @LockTimeoutMs           int            = NULL,            -- NULL = don't set; milliseconds for SET LOCK_TIMEOUT per rebuild
    @MaxRunSeconds           int            = NULL,            -- when PlanOnly=0, stop after N seconds (NULL = no limit)

    -- Logging
    @LogToTable              nvarchar(1)    = N'Y',            -- Y = log to dbo.CommandLog (current DB), N = no logging

    -- Output verbosity
    @Debug                   bit            = 0,

    -- Throughput estimation
    @EstimateTime            bit            = 0,               -- 1 = show estimated rebuild time per target
    @EstimateLookbackDays    int            = 90               -- CommandLog history window for throughput rates
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Version nvarchar(20) = N'1.6.2026.0216';

    ----------------------------------------------------------------------------
    -- @Help: print parameter documentation and return
    ----------------------------------------------------------------------------
    IF @Help = 1
    BEGIN
        RAISERROR(N'
sp_HeapDoctor v%s

Find heaps with forwarded records, rank by CPU impact, rebuild.

PARAMETERS:
  @Help              bit     = 0       Print this help and return.
  @Databases         nvarchar(max) = NULL  NULL=current DB. USER_DATABASES, ALL_DATABASES,
                                        SYSTEM_DATABASES, AVAILABILITY_GROUP_DATABASES,
                                        wildcards (%%), exclusions (-), comma-separated.
  @LookbackDays      int     = 7       Query Store lookback window in days.
  @TopN              int     = 25      Max targets per database.
  @MinPages          bigint  = 1000    Skip heaps smaller than this (page_count).
  @MaxPages          bigint  = NULL    Skip heaps larger than this (NULL=no cap).
  @MinForwardedPct   decimal = 2.00    Min forwarded record %% to qualify.

  @CpuSource         varchar = QUERY_STORE  QUERY_STORE | QUICKIESTORE | NONE
  @QuickieExecSql    nvarchar(max) = NULL   EXEC statement for sp_QuickieStore.
  @QuickiePlanIdColumn sysname = plan_id    Column name in Quickie output.
  @QuickieCpuUsColumn  sysname = avg_cpu_time  CPU column in Quickie output.
  @QuickieCpuUnit    varchar = us       Unit of CPU column: us | ms

  @OnlinePreference  varchar = AUTO     AUTO (edition-based) | ON (require) | OFF (force offline)
  @AllowCiSwap       bit     = 0       Allow CI swap path at all.
  @PreferCiSwap      bit     = 0       Prefer CI swap when safe key exists + online allowed.

  @PlanOnly          bit     = 1       1=print commands only, 0=execute.
  @Maxdop            int     = NULL    MAXDOP on index ops (NULL=omit, 0=unlimited).
  @LockTimeoutMs     int     = NULL    Per-rebuild lock timeout in ms (NULL=don''t set).
  @MaxRunSeconds     int     = NULL    Stop after N seconds (NULL=no limit).

  @LogToTable        nvarchar(1) = Y   Y=log to dbo.CommandLog, N=no logging.
  @Debug             bit     = 0       Extra diagnostic output.
  @EstimateTime      bit     = 0       Show estimated rebuild time per target.
  @EstimateLookbackDays int  = 90      CommandLog history window for throughput rates (days).

REQUIREMENTS: SQL Server 2017+ (STRING_AGG). Enterprise/Developer for ONLINE.
COMMANDLOG:   Expects dbo.CommandLog in the current database (Ola Hallengren pattern).
              https://ola.hallengren.com/scripts/CommandLog.sql
', 10, 1, @Version) WITH NOWAIT;
        RETURN;
    END

    /*
    Capture original LOCK_TIMEOUT to restore after each rebuild command.
    @@LOCK_TIMEOUT returns -1 for infinite wait, or timeout in milliseconds.
    */
    DECLARE @OriginalLockTimeout int = @@LOCK_TIMEOUT;

    ----------------------------------------------------------------------------
    -- Input validation
    ----------------------------------------------------------------------------
    DECLARE @Msg nvarchar(4000);
    DECLARE @CpuSourceUpper varchar(20) = UPPER(@CpuSource);
    SET @OnlinePreference = UPPER(@OnlinePreference);

    IF @CpuSourceUpper NOT IN ('QUERY_STORE', 'QUICKIESTORE', 'NONE')
    BEGIN
        RAISERROR(N'Invalid @CpuSource. Use QUERY_STORE, QUICKIESTORE, or NONE.', 16, 1);
        RETURN;
    END

    IF @CpuSourceUpper = 'QUICKIESTORE' AND @QuickieExecSql IS NULL
    BEGIN
        RAISERROR(N'CpuSource=QUICKIESTORE requires @QuickieExecSql.', 16, 1);
        RETURN;
    END

    IF @OnlinePreference NOT IN ('AUTO', 'ON', 'OFF')
    BEGIN
        RAISERROR(N'Invalid @OnlinePreference. Use AUTO, ON, or OFF.', 16, 1);
        RETURN;
    END

    IF @Maxdop IS NOT NULL AND @Maxdop < 0
    BEGIN
        RAISERROR(N'@Maxdop cannot be negative.', 16, 1);
        RETURN;
    END

    IF @LockTimeoutMs IS NOT NULL AND @LockTimeoutMs < 0
    BEGIN
        RAISERROR(N'@LockTimeoutMs cannot be negative. Use NULL for no timeout.', 16, 1);
        RETURN;
    END

    IF @MaxRunSeconds IS NOT NULL AND @MaxRunSeconds < 0
    BEGIN
        RAISERROR(N'@MaxRunSeconds cannot be negative.', 16, 1);
        RETURN;
    END

    ----------------------------------------------------------------------------
    -- Environment / capability gating
    ----------------------------------------------------------------------------
    DECLARE @Edition nvarchar(128) = CONVERT(nvarchar(128), SERVERPROPERTY('Edition'));
    DECLARE @EngineEdition int = CONVERT(int, SERVERPROPERTY('EngineEdition'));
    /*
    EngineEdition: 3 = Enterprise/Developer, 5 = Azure SQL Database, 8 = Managed Instance.
    All support online index operations. Edition string check is kept as fallback.
    */
    DECLARE @CanOnline bit = CASE
        WHEN @EngineEdition IN (3, 5, 8) THEN 1
        WHEN @Edition LIKE '%Enterprise%' OR @Edition LIKE '%Developer%' THEN 1
        ELSE 0
    END;

    DECLARE @Online bit =
        CASE
            WHEN @OnlinePreference = 'ON'  THEN IIF(@CanOnline = 1, 1, 0)
            WHEN @OnlinePreference = 'OFF' THEN 0
            ELSE IIF(@CanOnline = 1, 1, 0)  -- AUTO
        END;

    IF @OnlinePreference = 'ON' AND @CanOnline = 0
    BEGIN
        RAISERROR(N'WARNING: @OnlinePreference = ON but this edition does not support online index operations. Falling back to offline rebuilds.', 10, 1) WITH NOWAIT;
    END

    DECLARE @start_time datetime2(3) = SYSDATETIME();

    /*
    CommandLog integration (Ola Hallengren pattern).
    Logs to dbo.CommandLog in the current database if it exists and @LogToTable = 'Y'.
    */
    DECLARE @commandlog_exists bit = 0;
    SET @LogToTable = UPPER(@LogToTable);

    IF @LogToTable = N'Y'
    BEGIN
        IF EXISTS
        (
            SELECT 1
            FROM sys.objects AS o
            JOIN sys.schemas AS s ON s.schema_id = o.schema_id
            WHERE o.type = N'U'
            AND   s.name = N'dbo'
            AND   o.name = N'CommandLog'
        )
        BEGIN
            SET @commandlog_exists = 1;
        END
        ELSE
        BEGIN
            RAISERROR(N'WARNING: dbo.CommandLog does not exist in the current database. Set @LogToTable = N''N'' or create the table. Logging disabled for this run.', 10, 1) WITH NOWAIT;
            SET @commandlog_exists = 0;
        END
    END

    RAISERROR(N'===============================================================================', 10, 1) WITH NOWAIT;
    RAISERROR(N' sp_HeapDoctor - Heap Forwarded Record Mitigation', 10, 1) WITH NOWAIT;
    RAISERROR(N'===============================================================================', 10, 1) WITH NOWAIT;
    RAISERROR(N'', 10, 1) WITH NOWAIT;

    SET @Msg = N'Version:     ' + @Version;
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    SET @Msg = N'Edition:     ' + @Edition;
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    SET @Msg = N'Online ops:  ' + CASE WHEN @Online = 1 THEN N'YES' ELSE N'NO' END;
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    SET @Msg = N'CPU source:  ' + @CpuSourceUpper;
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    SET @Msg = N'Mode:        ' + CASE WHEN @PlanOnly = 1 THEN N'PLAN ONLY' ELSE N'EXECUTE' END;
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

    ----------------------------------------------------------------------------
    -- Parse @Databases (Ola Hallengren pattern)
    -- Supports: USER_DATABASES, ALL_DATABASES, SYSTEM_DATABASES,
    --           AVAILABILITY_GROUP_DATABASES, wildcards (%), exclusions (-),
    --           comma-separated list
    ----------------------------------------------------------------------------
    DECLARE @SelectedDatabases TABLE
    (
        DatabaseItem          nvarchar(256) NOT NULL,
        DatabaseType          char(1)       NULL,      -- S=system, U=user
        AvailabilityGroup     bit           NULL,
        StartPosition         int           NOT NULL,
        Selected              bit           NOT NULL
    );

    DECLARE @tmpDatabases TABLE
    (
        ID                    int           IDENTITY(1,1) NOT NULL PRIMARY KEY,
        DatabaseName          sysname       NOT NULL,
        DatabaseType          char(1)       NOT NULL,
        AvailabilityGroup     bit           NOT NULL DEFAULT 0,
        Selected              bit           NOT NULL DEFAULT 0,
        Completed             bit           NOT NULL DEFAULT 0
    );

    IF @Databases IS NOT NULL
    BEGIN
        SELECT @Databases = LTRIM(RTRIM(REPLACE(REPLACE(@Databases, CHAR(10), N''), CHAR(13), N'')));

        ;WITH DatabaseSplitter AS
        (
            SELECT
                DatabaseItem = LTRIM(RTRIM(
                    CASE
                        WHEN CHARINDEX(N',', @Databases) > 0
                        THEN SUBSTRING(@Databases, 1, CHARINDEX(N',', @Databases) - 1)
                        ELSE @Databases
                    END
                )),
                Remainder =
                    CASE
                        WHEN CHARINDEX(N',', @Databases) > 0
                        THEN SUBSTRING(@Databases, CHARINDEX(N',', @Databases) + 1, LEN(@Databases))
                        ELSE N''
                    END,
                StartPosition = 1

            UNION ALL

            SELECT
                DatabaseItem = LTRIM(RTRIM(
                    CASE
                        WHEN CHARINDEX(N',', Remainder) > 0
                        THEN SUBSTRING(Remainder, 1, CHARINDEX(N',', Remainder) - 1)
                        ELSE Remainder
                    END
                )),
                Remainder =
                    CASE
                        WHEN CHARINDEX(N',', Remainder) > 0
                        THEN SUBSTRING(Remainder, CHARINDEX(N',', Remainder) + 1, LEN(Remainder))
                        ELSE N''
                    END,
                StartPosition = StartPosition + 1
            FROM DatabaseSplitter
            WHERE LEN(Remainder) > 0
        ),
        Databases2 AS
        (
            SELECT
                DatabaseItem =
                    CASE
                        WHEN DatabaseItem LIKE N'-%'
                        THEN LTRIM(STUFF(DatabaseItem, 1, 1, N''))
                        ELSE DatabaseItem
                    END,
                StartPosition,
                Selected =
                    CASE
                        WHEN DatabaseItem LIKE N'-%'
                        THEN CONVERT(bit, 0)
                        ELSE CONVERT(bit, 1)
                    END
            FROM DatabaseSplitter
            WHERE DatabaseItem <> N''
        ),
        Databases3 AS
        (
            SELECT
                DatabaseItem =
                    CASE
                        WHEN DatabaseItem IN (N'ALL_DATABASES', N'SYSTEM_DATABASES',
                                              N'USER_DATABASES', N'AVAILABILITY_GROUP_DATABASES')
                        THEN N'%'
                        ELSE DatabaseItem
                    END,
                DatabaseType =
                    CASE
                        WHEN DatabaseItem = N'SYSTEM_DATABASES' THEN 'S'
                        WHEN DatabaseItem = N'USER_DATABASES' THEN 'U'
                        WHEN DatabaseItem = N'ALL_DATABASES' THEN 'U'
                        ELSE NULL
                    END,
                AvailabilityGroup =
                    CASE
                        WHEN DatabaseItem = N'AVAILABILITY_GROUP_DATABASES'
                        THEN CONVERT(bit, 1)
                        ELSE NULL
                    END,
                StartPosition,
                Selected
            FROM Databases2
        )
        INSERT INTO @SelectedDatabases
            (DatabaseItem, DatabaseType, AvailabilityGroup, StartPosition, Selected)
        SELECT DatabaseItem, DatabaseType, AvailabilityGroup, StartPosition, Selected
        FROM Databases3
        OPTION (MAXRECURSION 500);
    END

    INSERT INTO @tmpDatabases (DatabaseName, DatabaseType, AvailabilityGroup, Selected, Completed)
    SELECT
        d.name,
        CASE
            WHEN d.name IN (N'master', N'msdb', N'model') OR d.is_distributor = 1
            THEN 'S'
            ELSE 'U'
        END,
        CASE
            WHEN EXISTS
            (
                SELECT 1
                FROM sys.dm_hadr_database_replica_states AS drs
                WHERE drs.database_id = d.database_id
                AND   drs.is_local = 1
            )
            THEN CONVERT(bit, 1)
            ELSE CONVERT(bit, 0)
        END,
        0, -- Selected
        0  -- Completed
    FROM sys.databases AS d
    WHERE d.name <> N'tempdb'
    AND   d.source_database_id IS NULL
    AND   d.state = 0
    AND   d.is_read_only = 0
    AND   NOT EXISTS
    (
        -- Exclude AG secondary replicas (cannot rebuild on secondary)
        SELECT 1
        FROM sys.dm_hadr_database_replica_states AS drs
        WHERE drs.database_id = d.database_id
        AND   drs.is_local = 1
        AND   drs.is_primary_replica = 0
    );

    -- Apply inclusions
    UPDATE td
    SET td.Selected = sd.Selected
    FROM @tmpDatabases AS td
    INNER JOIN @SelectedDatabases AS sd
        ON td.DatabaseName LIKE REPLACE(sd.DatabaseItem, N'_', N'[_]')
        AND (td.DatabaseType = sd.DatabaseType OR sd.DatabaseType IS NULL)
        AND (td.AvailabilityGroup = sd.AvailabilityGroup OR sd.AvailabilityGroup IS NULL)
    WHERE sd.Selected = 1;

    -- Apply exclusions (must come after inclusions)
    UPDATE td
    SET td.Selected = sd.Selected
    FROM @tmpDatabases AS td
    INNER JOIN @SelectedDatabases AS sd
        ON td.DatabaseName LIKE REPLACE(sd.DatabaseItem, N'_', N'[_]')
        AND (td.DatabaseType = sd.DatabaseType OR sd.DatabaseType IS NULL)
        AND (td.AvailabilityGroup = sd.AvailabilityGroup OR sd.AvailabilityGroup IS NULL)
    WHERE sd.Selected = 0;

    -- Default to current database if @Databases is NULL
    IF @Databases IS NULL
    BEGIN
        UPDATE @tmpDatabases SET Selected = 1 WHERE DatabaseName = DB_NAME();
    END

    DECLARE @DatabaseCount int;
    SELECT @DatabaseCount = COUNT(*) FROM @tmpDatabases WHERE Selected = 1;

    IF @DatabaseCount = 0
    BEGIN
        RAISERROR(N'No databases matched the @Databases pattern.', 16, 1);
        RETURN;
    END

    SET @Msg = N'Databases:   ' + CAST(@DatabaseCount AS nvarchar(10)) + N' selected';
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

    IF @Debug = 1
    BEGIN
        RAISERROR(N'', 10, 1) WITH NOWAIT;
        RAISERROR(N'[DEBUG] EngineEdition = %d, CanOnline = %d, Online = %d', 10, 1, @EngineEdition, @CanOnline, @Online) WITH NOWAIT;
        RAISERROR(N'[DEBUG] Selected databases:', 10, 1) WITH NOWAIT;

        DECLARE @dbg_cursor sysname;
        DECLARE dbg_db CURSOR LOCAL FAST_FORWARD FOR
            SELECT DatabaseName FROM @tmpDatabases WHERE Selected = 1 ORDER BY ID;
        OPEN dbg_db;
        FETCH NEXT FROM dbg_db INTO @dbg_cursor;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @Msg = N'[DEBUG]   ' + @dbg_cursor;
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            FETCH NEXT FROM dbg_db INTO @dbg_cursor;
        END
        CLOSE dbg_db;
        DEALLOCATE dbg_db;
    END

    RAISERROR(N'', 10, 1) WITH NOWAIT;

    ----------------------------------------------------------------------------
    -- Temp tables (shared across database iterations)
    ----------------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#Targets') IS NOT NULL DROP TABLE #Targets;

    CREATE TABLE #Targets
    (
        target_id                int            IDENTITY(1,1) NOT NULL PRIMARY KEY,
        database_name            sysname        NOT NULL,
        object_id                int            NOT NULL,
        schema_name              sysname        NOT NULL,
        table_name               sysname        NOT NULL,
        page_count               bigint         NOT NULL,
        record_count             bigint         NULL,
        forwarded_record_count   bigint         NOT NULL,
        forwarded_pct            decimal(6,2)   NOT NULL,
        total_cpu_ms             bigint         NULL,
        ranking_basis            varchar(20)    NOT NULL DEFAULT 'FWD_PCT',
        nci_count                int            NOT NULL DEFAULT 0,
        key_source_index         sysname        NULL,
        temp_key_cols            nvarchar(max)  NULL,
        has_lob_columns          bit            NOT NULL DEFAULT 0,
        action_chosen            varchar(32)    NOT NULL,
        command_text             nvarchar(max)  NOT NULL,
        ci_drop_command          nvarchar(max)  NULL,
        est_pages_per_sec        float          NULL,
        est_seconds              int            NULL,
        est_duration             nvarchar(20)   NULL,
        sort_order               int            NOT NULL DEFAULT 0
    );

    DECLARE @ExecLog TABLE
    (
        target_id     int           NOT NULL,
        database_name sysname       NOT NULL,
        full_name     nvarchar(512) NOT NULL,
        action        varchar(32)   NOT NULL,
        start_time    datetime2(3)  NOT NULL,
        end_time      datetime2(3)  NULL,
        succeeded     bit           NULL,
        error_number  int           NULL,
        error_message nvarchar(4000) NULL
    );

    ----------------------------------------------------------------------------
    -- Per-database discovery loop
    ----------------------------------------------------------------------------
    DECLARE
        @CurrentDatabaseName sysname,
        @CurrentDatabaseID   int,
        @discovery_sql       nvarchar(max),
        @discovery_errors    int = 0;

    WHILE EXISTS (SELECT 1 FROM @tmpDatabases WHERE Selected = 1 AND Completed = 0)
    BEGIN
        SELECT TOP (1)
            @CurrentDatabaseID = ID,
            @CurrentDatabaseName = DatabaseName
        FROM @tmpDatabases
        WHERE Selected = 1 AND Completed = 0
        ORDER BY ID;

        SET @Msg = N'Scanning database: ' + @CurrentDatabaseName;
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;

        /*
        Build per-database discovery SQL.
        This runs inside the target database context via USE [db] and inserts
        results directly into #Targets (visible from parent scope).

        The discovery query:
        1) Finds heaps with forwarded records via dm_db_index_physical_stats
        2) Optionally reads CPU data from Query Store
        3) Maps plan CPU to heap objects via showplan XML
        4) Finds safe CI swap keys
        5) Checks for LOB columns
        6) Ranks and selects top N targets
        7) Generates rebuild commands
        */
        SET @discovery_sql = N'
USE ' + QUOTENAME(@CurrentDatabaseName) + N';

-- Per-database temp tables (scoped to this sp_executesql call)
CREATE TABLE #Heaps
(
    object_id              int           NOT NULL PRIMARY KEY,
    schema_name            sysname       NOT NULL,
    table_name             sysname       NOT NULL,
    page_count             bigint        NOT NULL,
    record_count           bigint        NULL,
    forwarded_record_count bigint        NOT NULL,
    forwarded_pct          decimal(6,2)  NOT NULL
);

CREATE TABLE #CpuByPlan
(
    plan_id       bigint NOT NULL PRIMARY KEY,
    total_cpu_ms  bigint NOT NULL
);

CREATE TABLE #CpuByObject
(
    object_id    int    NOT NULL PRIMARY KEY,
    total_cpu_ms bigint NOT NULL
);

-- 1) Find heaps with forwarded records
INSERT #Heaps (object_id, schema_name, table_name, page_count, record_count, forwarded_record_count, forwarded_pct)
SELECT
    o.object_id,
    s.name,
    o.name,
    ips.page_count,
    ips.record_count,
    ips.forwarded_record_count,
    CAST(100.0 * ips.forwarded_record_count / NULLIF(ips.record_count,0) AS decimal(6,2))
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, ''SAMPLED'') ips
JOIN sys.objects o ON ips.object_id = o.object_id
JOIN sys.schemas s ON o.schema_id = s.schema_id
WHERE o.type = ''U''
  AND o.is_memory_optimized = 0
  AND ips.index_id = 0
  AND ips.forwarded_record_count > 0
  AND ips.page_count >= @MinPages_param
  AND (@MaxPages_param IS NULL OR ips.page_count <= @MaxPages_param)
  AND (100.0 * ips.forwarded_record_count / NULLIF(ips.record_count,0)) >= @MinForwardedPct_param
  AND NOT EXISTS (SELECT 1 FROM sys.indexes ci WHERE ci.object_id = o.object_id AND ci.type IN (5,6));

DECLARE @HeapCount_inner int = (SELECT COUNT(*) FROM #Heaps);
DECLARE @Msg_inner nvarchar(4000);
SET @Msg_inner = N''  Found '' + CAST(@HeapCount_inner AS nvarchar(10)) + N'' heap(s) with forwarded records.'';
RAISERROR(@Msg_inner, 10, 1) WITH NOWAIT;

IF @HeapCount_inner = 0 RETURN;
';

        -- 2) CPU source (conditional)
        IF @CpuSourceUpper = 'QUERY_STORE'
        BEGIN
            SET @discovery_sql += N'
-- 2) CPU from Query Store
DECLARE @QsRw bit =
    CASE WHEN EXISTS (SELECT 1 FROM sys.database_query_store_options WHERE actual_state_desc = ''READ_WRITE'')
         THEN 1 ELSE 0 END;

IF @QsRw = 1
BEGIN
    ;WITH CpuByPlan AS
    (
        SELECT
            rs.plan_id,
            total_cpu_us = SUM(CONVERT(bigint, rs.count_executions) * CONVERT(bigint, rs.avg_cpu_time))
        FROM sys.query_store_runtime_stats rs
        JOIN sys.query_store_runtime_stats_interval rsi
          ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
        WHERE rsi.start_time >= DATEADD(DAY, -@LookbackDays_param, SYSUTCDATETIME())
        GROUP BY rs.plan_id
    )
    INSERT #CpuByPlan(plan_id, total_cpu_ms)
    SELECT plan_id, CONVERT(bigint, total_cpu_us / 1000)
    FROM CpuByPlan
    WHERE total_cpu_us > 0;

    -- 3) Map plan CPU to heap objects via showplan XML
    IF EXISTS (SELECT 1 FROM #CpuByPlan)
    BEGIN
        ;WITH XMLNAMESPACES (DEFAULT ''http://schemas.microsoft.com/sqlserver/2004/07/showplan''),
        HeapPlans AS
        (
            -- Pre-filter: only parse plans whose text contains a heap table name
            SELECT p.plan_id, TRY_CONVERT(xml, p.query_plan) AS plan_xml
            FROM sys.query_store_plan p
            JOIN #CpuByPlan cp ON cp.plan_id = p.plan_id
            WHERE EXISTS (SELECT 1 FROM #Heaps h WHERE p.query_plan LIKE N''%'' + h.table_name + N''%'')
        ),
        PlanObj AS
        (
            -- Filter to Table Scan RelOps only. These are the operations that traverse
            -- forwarded record pointers. Index Seeks/Scans on NCIs don''t hit them.
            SELECT DISTINCT
                hp.plan_id,
                REPLACE(REPLACE(obj.value(''@Schema'',''sysname''), N''['', N''''), N'']'', N'''') AS schema_name,
                REPLACE(REPLACE(obj.value(''@Table'', ''sysname''), N''['', N''''), N'']'', N'''') AS table_name
            FROM HeapPlans hp
            CROSS APPLY hp.plan_xml.nodes(''//RelOp[@PhysicalOp="Table Scan"]/*/Object[@Schema and @Table]'') AS n(obj)
            WHERE hp.plan_xml IS NOT NULL
        ),
        CpuByObj AS
        (
            SELECT h.object_id, SUM(cp.total_cpu_ms) AS total_cpu_ms
            FROM #Heaps h
            JOIN PlanObj po ON po.schema_name = h.schema_name AND po.table_name = h.table_name
            JOIN #CpuByPlan cp ON cp.plan_id = po.plan_id
            GROUP BY h.object_id
        )
        INSERT #CpuByObject(object_id, total_cpu_ms)
        SELECT object_id, total_cpu_ms FROM CpuByObj;
    END
END
ELSE
BEGIN
    RAISERROR(N''  Query Store not READ_WRITE; ranking by forwarded_pct only.'', 10, 1) WITH NOWAIT;
END
';
        END
        ELSE IF @CpuSourceUpper = 'NONE'
        BEGIN
            SET @discovery_sql += N'
-- 2) No CPU source; ranking by forwarded_pct only
';
        END
        -- QUICKIESTORE is handled separately below (not per-database dynamic SQL)

        -- 4-7) Key finder, LOB check, ranking, target generation
        SET @discovery_sql += N'
-- 4) Build target list: key finder + LOB check + ranking + command generation
;WITH LobTables AS
(
    SELECT DISTINCT c.object_id
    FROM sys.columns c
    JOIN sys.types t ON c.user_type_id = t.user_type_id
    WHERE t.name IN (N''text'', N''ntext'', N''image'', N''xml'')
       OR c.max_length = -1
),
CandidateKeys AS
(
    SELECT
        i.object_id,
        i.name AS index_name,
        STRING_AGG(QUOTENAME(c.name), N'','') WITHIN GROUP (ORDER BY ic.key_ordinal) AS key_cols,
        SUM(CASE WHEN c.max_length < 0 THEN 99999 ELSE c.max_length END) AS key_bytes,
        COUNT(*) AS key_col_count
    FROM sys.indexes i
    JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id AND ic.is_included_column = 0
    JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    JOIN sys.types t ON c.user_type_id = t.user_type_id
    WHERE i.type = 2
      AND i.is_unique = 1
      AND i.has_filter = 0
      AND i.is_disabled = 0
      AND i.is_hypothetical = 0
      AND ic.key_ordinal > 0
      AND c.is_nullable = 0
      AND c.max_length <> -1
      AND t.name NOT IN (N''text'',N''ntext'',N''image'',N''xml'')
    GROUP BY i.object_id, i.name
    HAVING SUM(CASE WHEN c.max_length < 0 THEN 99999 ELSE c.max_length END) <= 900
),
BestKey AS
(
    SELECT *, ROW_NUMBER() OVER (PARTITION BY object_id ORDER BY key_col_count ASC, key_bytes ASC, index_name ASC) AS rn
    FROM CandidateKeys
),
NciCounts AS
(
    SELECT object_id, COUNT(*) AS nci_count
    FROM sys.indexes
    WHERE type = 2
    GROUP BY object_id
),
Ranked AS
(
    SELECT
        h.object_id, h.schema_name, h.table_name,
        h.page_count, h.record_count, h.forwarded_record_count, h.forwarded_pct,
        cbo.total_cpu_ms,
        CASE
            WHEN @CpuSource_param = ''NONE'' THEN ''FWD_PCT''
            WHEN cbo.total_cpu_ms IS NOT NULL THEN ''QS_CPU''
            ELSE ''QS_NO_DATA''
        END AS ranking_basis,
        ISNULL(nc.nci_count, 0) AS nci_count,
        bk.index_name AS key_source_index,
        bk.key_cols AS temp_key_cols,
        CASE WHEN lt.object_id IS NOT NULL THEN 1 ELSE 0 END AS has_lob_columns,
        ROW_NUMBER() OVER (ORDER BY
            -- Mixed ranking: use CPU when available, fall back to forwarded_pct.
            -- NULL CPU no longer penalized vs low CPU.
            COALESCE(cbo.total_cpu_ms, 0) + CAST(h.forwarded_pct * h.page_count AS bigint) DESC
        ) AS target_rank
    FROM #Heaps h
    LEFT JOIN #CpuByObject cbo ON h.object_id = cbo.object_id
    LEFT JOIN BestKey bk ON h.object_id = bk.object_id AND bk.rn = 1
    LEFT JOIN LobTables lt ON h.object_id = lt.object_id
    LEFT JOIN NciCounts nc ON h.object_id = nc.object_id
)
INSERT #Targets
(
    database_name, object_id, schema_name, table_name, page_count, record_count,
    forwarded_record_count, forwarded_pct, total_cpu_ms, ranking_basis, nci_count,
    key_source_index, temp_key_cols, has_lob_columns,
    action_chosen, command_text, ci_drop_command
)
SELECT TOP (@TopN_param)
    DB_NAME(),
    r.object_id, r.schema_name, r.table_name,
    r.page_count, r.record_count, r.forwarded_record_count, r.forwarded_pct, r.total_cpu_ms,
    r.ranking_basis, r.nci_count,
    r.key_source_index, r.temp_key_cols, r.has_lob_columns,
    -- action_chosen
    CASE
        WHEN @AllowCiSwap_param = 1 AND @PreferCiSwap_param = 1 AND @Online_param = 1
             AND r.temp_key_cols IS NOT NULL AND r.has_lob_columns = 0
            THEN ''CI_SWAP_ONLINE''
        WHEN @Online_param = 1 THEN ''HEAP_REBUILD_ONLINE''
        ELSE ''HEAP_REBUILD_OFFLINE''
    END,
    -- command_text
    CASE
        WHEN @AllowCiSwap_param = 1 AND @PreferCiSwap_param = 1 AND @Online_param = 1
             AND r.temp_key_cols IS NOT NULL AND r.has_lob_columns = 0
        THEN
            N''CREATE CLUSTERED INDEX '' +
            QUOTENAME(N''CX__Temp__'' + LEFT(r.table_name, 108)) +
            N'' ON '' + QUOTENAME(DB_NAME()) + N''.'' + QUOTENAME(r.schema_name) + N''.'' + QUOTENAME(r.table_name) +
            N'' ('' + r.temp_key_cols + N'') WITH (ONLINE = ON'' +
            COALESCE(N'', MAXDOP = '' + CAST(@Maxdop_param AS nvarchar(10)), N'''') + N'');''
        WHEN @Online_param = 1
        THEN
            N''ALTER TABLE '' + QUOTENAME(DB_NAME()) + N''.'' + QUOTENAME(r.schema_name) + N''.'' + QUOTENAME(r.table_name) +
            N'' REBUILD WITH (ONLINE = ON'' +
            COALESCE(N'', MAXDOP = '' + CAST(@Maxdop_param AS nvarchar(10)), N'''') + N'');''
        ELSE
            N''ALTER TABLE '' + QUOTENAME(DB_NAME()) + N''.'' + QUOTENAME(r.schema_name) + N''.'' + QUOTENAME(r.table_name) +
            N'' REBUILD'' +
            COALESCE(N'' WITH (MAXDOP = '' + CAST(@Maxdop_param AS nvarchar(10)) + N'')'', N'''') + N'';''
    END,
    -- ci_drop_command
    CASE
        WHEN @AllowCiSwap_param = 1 AND @PreferCiSwap_param = 1 AND @Online_param = 1
             AND r.temp_key_cols IS NOT NULL AND r.has_lob_columns = 0
        THEN
            N''DROP INDEX '' +
            QUOTENAME(N''CX__Temp__'' + LEFT(r.table_name, 108)) +
            N'' ON '' + QUOTENAME(DB_NAME()) + N''.'' + QUOTENAME(r.schema_name) + N''.'' + QUOTENAME(r.table_name) +
            N'' WITH (ONLINE = ON'' +
            COALESCE(N'', MAXDOP = '' + CAST(@Maxdop_param AS nvarchar(10)), N'''') + N'');''
        ELSE NULL
    END
FROM Ranked r
ORDER BY r.target_rank;

SET @Msg_inner = N''  Selected '' + CAST(@@ROWCOUNT AS nvarchar(10)) + N'' target(s).'';
RAISERROR(@Msg_inner, 10, 1) WITH NOWAIT;
';

        /*
        Execute the per-database discovery.
        All parameters are passed in to avoid SQL injection from @Databases input.
        */
        BEGIN TRY
            EXEC sys.sp_executesql
                @discovery_sql,
                N'@MinPages_param bigint, @MaxPages_param bigint, @MinForwardedPct_param decimal(6,2),
                  @LookbackDays_param int, @TopN_param int,
                  @AllowCiSwap_param bit, @PreferCiSwap_param bit, @Online_param bit,
                  @Maxdop_param int, @CpuSource_param varchar(20)',
                @MinPages_param = @MinPages,
                @MaxPages_param = @MaxPages,
                @MinForwardedPct_param = @MinForwardedPct,
                @LookbackDays_param = @LookbackDays,
                @TopN_param = @TopN,
                @AllowCiSwap_param = @AllowCiSwap,
                @PreferCiSwap_param = @PreferCiSwap,
                @Online_param = @Online,
                @Maxdop_param = @Maxdop,
                @CpuSource_param = @CpuSourceUpper;
        END TRY
        BEGIN CATCH
            SET @discovery_errors += 1;
            SET @Msg = N'  ERROR scanning ' + @CurrentDatabaseName + N': '
                     + CAST(ERROR_NUMBER() AS nvarchar(10)) + N' - ' + LEFT(ERROR_MESSAGE(), 300);
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END CATCH;

        -- Set sort_order = target_id for newly inserted rows
        UPDATE #Targets SET sort_order = target_id WHERE sort_order = 0;

        -- Mark database as completed
        UPDATE @tmpDatabases SET Completed = 1 WHERE ID = @CurrentDatabaseID;
    END

    /*
    QUICKIESTORE: handled outside the database loop because sp_QuickieStore
    typically runs in the current database context and returns cross-database results.
    TODO: This path needs design thought for multi-database scenarios.
    For now, it only works with single-database mode.
    */
    IF @CpuSourceUpper = 'QUICKIESTORE'
    BEGIN
        RAISERROR(N'Reading CPU data from sp_QuickieStore...', 10, 1) WITH NOWAIT;

        IF @DatabaseCount > 1
        BEGIN
            RAISERROR(N'WARNING: QUICKIESTORE CPU source only applies to the current database context. Multi-database CPU ranking not available.', 10, 1) WITH NOWAIT;
        END

        /*
        Build the CREATE TABLE DDL from sp_describe_first_result_set metadata.
        */
        IF OBJECT_ID('tempdb..#CpuByPlan') IS NOT NULL DROP TABLE #CpuByPlan;

        CREATE TABLE #CpuByPlan
        (
            plan_id       bigint NOT NULL PRIMARY KEY,
            total_cpu_ms  bigint NOT NULL
        );

        DECLARE @ddl nvarchar(max) = N'CREATE TABLE #Quickie(';
        DECLARE @ColCount int = 0;

        ;WITH meta AS
        (
            SELECT column_ordinal, name, system_type_name, is_nullable, error_number
            FROM sys.sp_describe_first_result_set(@QuickieExecSql, NULL, 0)
        )
        SELECT
            @ddl = @ddl + QUOTENAME(name) + N' ' + system_type_name + N' ' +
                   CASE WHEN is_nullable = 1 THEN N'NULL' ELSE N'NOT NULL' END + N',' + CHAR(10),
            @ColCount = @ColCount + 1
        FROM meta
        WHERE error_number IS NULL
          AND name IS NOT NULL
        ORDER BY column_ordinal;

        IF @ColCount = 0
        BEGIN
            RAISERROR(N'sp_describe_first_result_set returned no columns for @QuickieExecSql. Cannot proceed.', 16, 1);
            RETURN;
        END

        SET @ddl = LEFT(@ddl, DATALENGTH(@ddl) / 2 - 2) + N');';

        IF CHARINDEX(QUOTENAME(@QuickiePlanIdColumn), @ddl) = 0
        OR CHARINDEX(QUOTENAME(@QuickieCpuUsColumn), @ddl) = 0
        BEGIN
            RAISERROR(N'Quickie output metadata does not contain required columns. Check @QuickiePlanIdColumn / @QuickieCpuUsColumn.', 16, 1);
            RETURN;
        END

        DECLARE @QuickieBatch nvarchar(max) =
            @ddl + N'
INSERT #Quickie EXEC sys.sp_executesql @InnerSql;

INSERT #CpuByPlan(plan_id, total_cpu_ms)
SELECT
    CONVERT(bigint, ' + QUOTENAME(@QuickiePlanIdColumn) + N') AS plan_id,
    CONVERT(bigint,
        CASE
            WHEN @Unit = ''ms'' THEN ' + QUOTENAME(@QuickieCpuUsColumn) + N'
            ELSE ' + QUOTENAME(@QuickieCpuUsColumn) + N' / 1000.0
        END
    ) AS total_cpu_ms
FROM #Quickie
WHERE ' + QUOTENAME(@QuickiePlanIdColumn) + N' IS NOT NULL;
';

        EXEC sys.sp_executesql
            @QuickieBatch,
            N'@InnerSql nvarchar(max), @Unit varchar(10)',
            @InnerSql = @QuickieExecSql,
            @Unit = @QuickieCpuUnit;

        SET @Msg = N'Loaded ' + CAST((SELECT COUNT(*) FROM #CpuByPlan) AS nvarchar(10)) + N' plan(s) with CPU data from QuickieStore.';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;

        -- Update #Targets with CPU data for the current database
        -- (QuickieStore CPU mapping via plan XML)
        DECLARE @QueryStoreRW bit =
            CASE WHEN EXISTS (SELECT 1 FROM sys.database_query_store_options WHERE actual_state_desc = 'READ_WRITE')
                 THEN 1 ELSE 0 END;

        IF @QueryStoreRW = 1 AND EXISTS (SELECT 1 FROM #CpuByPlan)
        BEGIN
            ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'),
            HeapPlans AS
            (
                -- Pre-filter: only parse plans whose text contains a target table name
                SELECT p.plan_id, TRY_CONVERT(xml, p.query_plan) AS plan_xml
                FROM sys.query_store_plan p
                JOIN #CpuByPlan cp ON cp.plan_id = p.plan_id
                WHERE EXISTS (SELECT 1 FROM #Targets t2 WHERE t2.database_name = DB_NAME()
                              AND p.query_plan LIKE N'%' + t2.table_name + N'%')
            ),
            PlanObj AS
            (
                -- Filter to Table Scan RelOps only
                SELECT DISTINCT
                    hp.plan_id,
                    REPLACE(REPLACE(obj.value('@Schema','sysname'), N'[', N''), N']', N'') AS schema_name,
                    REPLACE(REPLACE(obj.value('@Table','sysname'),  N'[', N''), N']', N'') AS table_name
                FROM HeapPlans hp
                CROSS APPLY hp.plan_xml.nodes('//RelOp[@PhysicalOp="Table Scan"]/*/Object[@Schema and @Table]') AS n(obj)
                WHERE hp.plan_xml IS NOT NULL
            )
            UPDATE t
            SET t.total_cpu_ms = sub.total_cpu_ms,
                t.ranking_basis = 'QS_CPU'
            FROM #Targets t
            JOIN (
                SELECT t2.target_id, SUM(cp.total_cpu_ms) AS total_cpu_ms
                FROM #Targets t2
                JOIN PlanObj po ON po.schema_name = t2.schema_name AND po.table_name = t2.table_name
                JOIN #CpuByPlan cp ON cp.plan_id = po.plan_id
                WHERE t2.database_name = DB_NAME()
                GROUP BY t2.target_id
            ) sub ON t.target_id = sub.target_id;
        END

        DROP TABLE #CpuByPlan;

        /*
        Re-rank targets after QUICKIESTORE CPU update. The execution loop iterates
        by sort_order, so we reassign sort_order to reflect the updated ranking.
        */
        ;WITH Reranked AS
        (
            SELECT
                target_id,
                sort_order,
                ROW_NUMBER() OVER (
                    ORDER BY COALESCE(total_cpu_ms, 0) + CAST(forwarded_pct * page_count AS bigint) DESC
                ) AS new_rank
            FROM #Targets
        )
        UPDATE Reranked SET sort_order = new_rank;
    END

    ----------------------------------------------------------------------------
    -- Final target count
    ----------------------------------------------------------------------------
    DECLARE @TargetCount int = (SELECT COUNT(*) FROM #Targets);

    RAISERROR(N'', 10, 1) WITH NOWAIT;
    SET @Msg = N'Total targets across all databases: ' + CAST(@TargetCount AS nvarchar(10));
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

    IF @discovery_errors > 0
    BEGIN
        SET @Msg = N'WARNING: ' + CAST(@discovery_errors AS nvarchar(10))
                 + N' database(s) had errors during discovery scan. Check messages above.';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END

    RAISERROR(N'', 10, 1) WITH NOWAIT;

    IF @TargetCount = 0
    BEGIN
        RAISERROR(N'No heaps met thresholds in any database. Nothing to do.', 10, 1) WITH NOWAIT;
        RETURN;
    END

    IF @Debug = 1
    BEGIN
        RAISERROR(N'[DEBUG] Target details:', 10, 1) WITH NOWAIT;
        DECLARE @dbg_tid int, @dbg_db sysname, @dbg_tbl sysname, @dbg_action varchar(32),
                @dbg_pages bigint, @dbg_fwd decimal(6,2), @dbg_cpu bigint, @dbg_basis varchar(20);
        DECLARE dbg_tgt CURSOR LOCAL FAST_FORWARD FOR
            SELECT target_id, database_name, table_name, action_chosen,
                   page_count, forwarded_pct, total_cpu_ms, ranking_basis
            FROM #Targets ORDER BY sort_order;
        OPEN dbg_tgt;
        FETCH NEXT FROM dbg_tgt INTO @dbg_tid, @dbg_db, @dbg_tbl, @dbg_action,
                                     @dbg_pages, @dbg_fwd, @dbg_cpu, @dbg_basis;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @Msg = N'[DEBUG]   #' + CAST(@dbg_tid AS nvarchar(10))
                     + N' ' + @dbg_db + N'.' + @dbg_tbl
                     + N' | ' + @dbg_action
                     + N' | pages=' + CAST(@dbg_pages AS nvarchar(20))
                     + N' fwd=' + CAST(@dbg_fwd AS nvarchar(10)) + N'%'
                     + N' cpu=' + ISNULL(CAST(@dbg_cpu AS nvarchar(20)), N'NULL')
                     + N' basis=' + @dbg_basis;
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            FETCH NEXT FROM dbg_tgt INTO @dbg_tid, @dbg_db, @dbg_tbl, @dbg_action,
                                         @dbg_pages, @dbg_fwd, @dbg_cpu, @dbg_basis;
        END
        CLOSE dbg_tgt;
        DEALLOCATE dbg_tgt;
    END

    ----------------------------------------------------------------------------
    -- Throughput estimation (history-based)
    ----------------------------------------------------------------------------
    DECLARE @hist_online_pps    float = NULL;
    DECLARE @hist_offline_pps   float = NULL;
    DECLARE @hist_ciswap_pps    float = NULL;
    DECLARE @hist_any_pps       float = NULL;
    DECLARE @hist_source        varchar(20) = 'NONE';

    IF @EstimateTime = 1 AND @commandlog_exists = 1
    BEGIN
        ;WITH HistRates AS
        (
            SELECT
                CommandType,
                AVG(
                    CAST(ExtendedInfo.value('(/ExtendedInfo/PageCount)[1]', 'bigint') AS float)
                    / NULLIF(DATEDIFF(MILLISECOND, StartTime, EndTime) / 1000.0, 0)
                ) AS avg_pps,
                COUNT(*) AS sample_count
            FROM dbo.CommandLog
            WHERE CommandType IN ('HEAP_REBUILD_ONLINE', 'HEAP_REBUILD_OFFLINE', 'CI_SWAP_ONLINE')
              AND ISNULL(ErrorNumber, 0) = 0
              AND EndTime IS NOT NULL
              AND DATEDIFF(MILLISECOND, StartTime, EndTime) > 500
              AND DATEDIFF(DAY, StartTime, SYSDATETIME()) <= @EstimateLookbackDays
            GROUP BY CommandType
        )
        SELECT
            @hist_online_pps  = MAX(CASE WHEN CommandType = 'HEAP_REBUILD_ONLINE'  THEN avg_pps END),
            @hist_offline_pps = MAX(CASE WHEN CommandType = 'HEAP_REBUILD_OFFLINE' THEN avg_pps END),
            @hist_ciswap_pps  = MAX(CASE WHEN CommandType = 'CI_SWAP_ONLINE'       THEN avg_pps END),
            @hist_any_pps     = AVG(avg_pps)
        FROM HistRates;

        IF @hist_any_pps IS NOT NULL
            SET @hist_source = 'HISTORY';
    END

    IF @EstimateTime = 1
    BEGIN
        IF @hist_source = 'NONE'
        BEGIN
            RAISERROR(N'EstimateTime: No historical rebuild data found in CommandLog. Estimates unavailable until first execution with @LogToTable=''Y''.', 10, 1) WITH NOWAIT;
        END
        ELSE
        BEGIN
            SET @Msg = N'EstimateTime: Historical throughput (pages/sec):'
                     + CASE WHEN @hist_online_pps  IS NOT NULL THEN N'  ONLINE='  + CAST(CAST(@hist_online_pps  AS int) AS nvarchar(20)) ELSE N'' END
                     + CASE WHEN @hist_offline_pps IS NOT NULL THEN N'  OFFLINE=' + CAST(CAST(@hist_offline_pps AS int) AS nvarchar(20)) ELSE N'' END
                     + CASE WHEN @hist_ciswap_pps  IS NOT NULL THEN N'  CI_SWAP=' + CAST(CAST(@hist_ciswap_pps  AS int) AS nvarchar(20)) ELSE N'' END;
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;

            -- Populate estimate columns on #Targets
            UPDATE #Targets
            SET est_pages_per_sec = CASE action_chosen
                    WHEN 'HEAP_REBUILD_ONLINE'  THEN COALESCE(@hist_online_pps,  @hist_any_pps)
                    WHEN 'HEAP_REBUILD_OFFLINE' THEN COALESCE(@hist_offline_pps, @hist_any_pps)
                    WHEN 'CI_SWAP_ONLINE'       THEN COALESCE(@hist_ciswap_pps,  @hist_any_pps)
                    ELSE @hist_any_pps
                END;

            UPDATE #Targets
            SET est_seconds = CEILING(page_count / NULLIF(est_pages_per_sec, 0))
            WHERE est_pages_per_sec IS NOT NULL;

            UPDATE #Targets
            SET est_duration = RIGHT('00' + CAST(est_seconds / 3600 AS varchar(10)), 2) + ':'
                             + RIGHT('00' + CAST((est_seconds % 3600) / 60 AS varchar(2)), 2) + ':'
                             + RIGHT('00' + CAST(est_seconds % 60 AS varchar(2)), 2)
            WHERE est_seconds IS NOT NULL;

            -- Print total estimate summary
            DECLARE @total_est_sec int;
            SELECT @total_est_sec = SUM(est_seconds) FROM #Targets WHERE est_seconds IS NOT NULL;

            IF @total_est_sec IS NOT NULL
            BEGIN
                SET @Msg = N'EstimateTime: Total estimated remediation: '
                         + RIGHT('00' + CAST(@total_est_sec / 3600 AS varchar(10)), 2) + ':'
                         + RIGHT('00' + CAST((@total_est_sec % 3600) / 60 AS varchar(2)), 2) + ':'
                         + RIGHT('00' + CAST(@total_est_sec % 60 AS varchar(2)), 2)
                         + N' (' + CAST(@total_est_sec AS nvarchar(20)) + N's) based on '
                         + CAST(@EstimateLookbackDays AS nvarchar(10)) + N'-day history';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END
        END
        RAISERROR(N'', 10, 1) WITH NOWAIT;
    END

    ----------------------------------------------------------------------------
    -- Output: target list (always shown)
    ----------------------------------------------------------------------------
    SELECT
        @Version AS version,
        target_id,
        sort_order,
        database_name,
        schema_name,
        table_name,
        page_count,
        record_count,
        forwarded_record_count,
        forwarded_pct,
        total_cpu_ms,
        ranking_basis,
        nci_count,
        key_source_index,
        action_chosen,
        est_pages_per_sec,
        est_seconds,
        est_duration
    FROM #Targets
    ORDER BY sort_order;

    ----------------------------------------------------------------------------
    -- Output: commands (always shown)
    ----------------------------------------------------------------------------
    SELECT
        target_id,
        sort_order,
        database_name,
        action_chosen,
        command_text,
        ci_drop_command
    FROM #Targets
    ORDER BY sort_order;

    ----------------------------------------------------------------------------
    -- Execute if requested
    ----------------------------------------------------------------------------
    IF @PlanOnly = 0
    BEGIN
        RAISERROR(N'===============================================================================', 10, 1) WITH NOWAIT;
        RAISERROR(N' Executing Rebuilds', 10, 1) WITH NOWAIT;
        RAISERROR(N'===============================================================================', 10, 1) WITH NOWAIT;
        RAISERROR(N'', 10, 1) WITH NOWAIT;

        DECLARE
            @i              int = 0,
            @cur_sort       int,
            @tid            int,
            @db             sysname,
            @schema         sysname,
            @tbl            sysname,
            @full           nvarchar(512),
            @action         varchar(32),
            @cmd            nvarchar(max),
            @ci_drop        nvarchar(max),
            @exec_cmd       nvarchar(max),
            @start          datetime2(3),
            @end            datetime2(3),
            @RunStart       datetime2(3) = SYSDATETIME(),
            @succeeded_cnt  int = 0,
            @failed_cnt     int = 0,
            @skipped_cnt    int = 0,
            @elapsed_sec    int,
            @cur_page_count      bigint,
            @cur_fwd_count       bigint,
            @cur_fwd_pct         decimal(6,2),
            @cur_cpu_ms          bigint,
            @extended_info       xml,
            @err_number          int,
            @err_message         nvarchar(4000),
            @verify_sql          nvarchar(max),
            @post_fwd_count      bigint,
            @ci_drop_failed      bit,
            -- Live calibration for throughput estimation
            @live_pages_rebuilt   bigint = 0,
            @live_elapsed_ms     bigint = 0,
            @live_pps            float  = NULL,
            @remaining_pages     bigint,
            @remaining_est_sec   int,
            @rebuild_elapsed_ms  bigint;

        /*
        Build LOCK_TIMEOUT prefix/suffix to prepend/append to each command.
        Ensures the timeout applies within the same sp_executesql scope as the
        rebuild, and restores the original session value afterward.
        */
        DECLARE @LockPrefix nvarchar(200) = N'';
        DECLARE @LockSuffix nvarchar(200) = N'';

        IF @LockTimeoutMs IS NOT NULL
        BEGIN
            SET @LockPrefix = N'SET LOCK_TIMEOUT ' + CONVERT(nvarchar(20), @LockTimeoutMs) + N'; ';
            SET @LockSuffix = N' SET LOCK_TIMEOUT ' + CONVERT(nvarchar(20), @OriginalLockTimeout) + N';';

            SET @Msg = N'Lock timeout: ' + CAST(@LockTimeoutMs AS nvarchar(20)) + N' ms per rebuild.';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END

        /*
        Log run START to CommandLog
        */
        IF @commandlog_exists = 1
        BEGIN
            INSERT INTO dbo.CommandLog
                (DatabaseName, SchemaName, ObjectName, ObjectType, Command, CommandType, StartTime, ExtendedInfo)
            VALUES
            (
                ISNULL(@Databases, DB_NAME()),
                N'dbo',
                N'sp_HeapDoctor',
                N'P',
                N'EXECUTE dbo.sp_HeapDoctor @Databases = N''' + REPLACE(ISNULL(@Databases, DB_NAME()), N'''', N'''''') + N'''...',
                N'HEAP_REBUILD_START',
                @start_time,
                (
                    SELECT
                        @Version AS Version,
                        @TargetCount AS TargetCount,
                        @CpuSourceUpper AS CpuSource,
                        CASE WHEN @Online = 1 THEN N'ON' ELSE N'OFF' END AS OnlineMode,
                        @Maxdop AS Maxdop,
                        @LockTimeoutMs AS LockTimeoutMs,
                        @MaxRunSeconds AS MaxRunSeconds
                    FOR XML RAW(N'Parameters'), ELEMENTS
                )
            );
        END

        /*
        WHILE loop - iterate by sort_order.
        Commands already use 3-part names (db.schema.table) so no USE statement needed.
        */
        WHILE 1 = 1
        BEGIN
            -- Get next target
            SELECT TOP (1)
                @cur_sort       = sort_order,
                @tid            = target_id,
                @db             = database_name,
                @schema         = schema_name,
                @tbl            = table_name,
                @full           = QUOTENAME(database_name) + N'.' + QUOTENAME(schema_name) + N'.' + QUOTENAME(table_name),
                @action         = action_chosen,
                @cmd            = command_text,
                @ci_drop        = ci_drop_command,
                @cur_page_count = page_count,
                @cur_fwd_count  = forwarded_record_count,
                @cur_fwd_pct    = forwarded_pct,
                @cur_cpu_ms     = total_cpu_ms
            FROM #Targets
            WHERE sort_order > @i
            ORDER BY sort_order;

            IF @@ROWCOUNT = 0 BREAK;

            SET @i = @cur_sort;

            /*
            Time limit check
            */
            IF @MaxRunSeconds IS NOT NULL
               AND DATEDIFF(SECOND, @RunStart, SYSDATETIME()) >= @MaxRunSeconds
            BEGIN
                RAISERROR(N'', 10, 1) WITH NOWAIT;
                SET @Msg = N'Time limit (' + CAST(@MaxRunSeconds AS nvarchar(10)) + N' seconds) reached. Stopping gracefully.';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;

                -- Log all remaining targets as SKIPPED (both in-memory and CommandLog)
                INSERT @ExecLog(target_id, database_name, full_name, action, start_time, end_time, succeeded, error_message)
                SELECT
                    target_id,
                    database_name,
                    QUOTENAME(database_name) + N'.' + QUOTENAME(schema_name) + N'.' + QUOTENAME(table_name),
                    action_chosen,
                    SYSDATETIME(),
                    SYSDATETIME(),
                    NULL,
                    N'SKIPPED: @MaxRunSeconds reached.'
                FROM #Targets
                WHERE sort_order >= @cur_sort;

                SET @skipped_cnt += (SELECT COUNT(*) FROM #Targets WHERE sort_order >= @cur_sort);

                -- Persist SKIPPED entries to CommandLog
                IF @commandlog_exists = 1
                BEGIN
                    INSERT INTO dbo.CommandLog
                        (DatabaseName, SchemaName, ObjectName, ObjectType, Command, CommandType,
                         StartTime, EndTime, ErrorNumber, ErrorMessage, ExtendedInfo)
                    SELECT
                        database_name,
                        schema_name,
                        table_name,
                        N'U',
                        command_text,
                        action_chosen,
                        SYSDATETIME(),
                        SYSDATETIME(),
                        NULL,
                        N'SKIPPED: @MaxRunSeconds reached.',
                        (
                            SELECT
                                page_count AS PageCount,
                                CAST(page_count AS decimal(18,2)) / 128.0 AS SizeMB,
                                forwarded_record_count AS ForwardedRecords,
                                forwarded_pct AS ForwardedPct,
                                total_cpu_ms AS TotalCpuMs
                            FOR XML RAW(N'ExtendedInfo'), ELEMENTS
                        )
                    FROM #Targets
                    WHERE sort_order >= @cur_sort;
                END

                BREAK;
            END

            /*
            Progress message
            */
            SET @Msg = N'[' + CAST(@succeeded_cnt + @failed_cnt + 1 AS nvarchar(10)) + N'/' + CAST(@TargetCount AS nvarchar(10)) + N'] '
                     + @action + N' on ' + @full;

            -- Append per-target estimate if available
            IF @EstimateTime = 1
            BEGIN
                SET @remaining_est_sec = NULL;
                SELECT @remaining_est_sec = est_seconds FROM #Targets WHERE target_id = @tid;

                IF @remaining_est_sec IS NOT NULL
                    SET @Msg = @Msg + N'  (est: ' + CAST(@remaining_est_sec AS nvarchar(10)) + N's)';
            END

            RAISERROR(@Msg, 10, 1) WITH NOWAIT;

            SET @start = SYSDATETIME();
            INSERT @ExecLog(target_id, database_name, full_name, action, start_time)
            VALUES (@tid, @db, @full, @action, @start);

            /*
            Execute the main command (with lock timeout prefix/suffix)
            */
            SET @exec_cmd = @LockPrefix + @cmd + @LockSuffix;

            BEGIN TRY
                EXEC sys.sp_executesql @exec_cmd;

                SET @end = SYSDATETIME();
                SET @elapsed_sec = DATEDIFF(SECOND, @start, @end);

                UPDATE @ExecLog
                  SET end_time = @end, succeeded = 1
                WHERE target_id = @tid;

                SET @Msg = N'  OK (' + CAST(@elapsed_sec AS nvarchar(10)) + N's)';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;

                /*
                CI swap step 2: DROP the temp clustered index to return to heap.
                If DROP fails, the table is left as a clustered table (not a heap).
                We log success for the forwarded-record fix (the CREATE did the work)
                but warn loudly so the DBA can manually drop the temp CI.
                */
                SET @ci_drop_failed = 0;
                IF @ci_drop IS NOT NULL
                BEGIN
                    SET @Msg = N'  Dropping temp clustered index on ' + @full + N'...';
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

                    BEGIN TRY
                        SET @exec_cmd = @LockPrefix + @ci_drop + @LockSuffix;
                        EXEC sys.sp_executesql @exec_cmd;

                        SET @Msg = N'  DROP OK';
                        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                    END TRY
                    BEGIN CATCH
                        SET @ci_drop_failed = 1;

                        SET @Msg = N'  WARNING: CI swap CREATE succeeded but DROP FAILED on ' + @full
                                 + N'. Error ' + CAST(ERROR_NUMBER() AS nvarchar(10))
                                 + N': ' + LEFT(ERROR_MESSAGE(), 300)
                                 + N'. The table is now a clustered table, NOT a heap.'
                                 + N' Forwarded records are eliminated, but you must manually drop the temp index.';
                        RAISERROR(@Msg, 16, 1) WITH NOWAIT;

                        -- Restore lock timeout (prefix ran but suffix did not due to error)
                        IF @LockTimeoutMs IS NOT NULL
                            EXEC sys.sp_executesql @LockSuffix;
                    END CATCH
                END

                SET @succeeded_cnt += 1;

                /*
                Post-rebuild verification: confirm forwarded records are gone.
                Uses SAMPLED mode for speed. This is a spot-check, not a guarantee.
                Skipped when CI swap DROP failed (table is now clustered, index_id = 1 not 0).
                */
                SET @post_fwd_count = NULL;
                IF @ci_drop_failed = 1
                BEGIN
                    -- CI DROP failed; table is now clustered (index_id=1), not heap.
                    -- Forwarded records are eliminated by the CREATE, but we can't verify via index_id=0.
                    SET @Msg = N'  Skipping post-rebuild verification (table is now clustered due to DROP failure).';
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                    SET @post_fwd_count = 0; -- forwarded records ARE gone (CREATE eliminated them)
                END
                ELSE
                BEGIN
                    BEGIN TRY
                        SET @verify_sql = N'SELECT @fwd_out = forwarded_record_count
                            FROM sys.dm_db_index_physical_stats(DB_ID(@db_param), OBJECT_ID(@full_param), 0, NULL, ''SAMPLED'')
                            WHERE index_id = 0;';
                        EXEC sys.sp_executesql @verify_sql,
                            N'@db_param sysname, @full_param nvarchar(512), @fwd_out bigint OUTPUT',
                            @db_param = @db, @full_param = @full, @fwd_out = @post_fwd_count OUTPUT;
                    END TRY
                    BEGIN CATCH
                        SET @post_fwd_count = NULL; -- verification failed, don't block
                    END CATCH

                    IF @post_fwd_count IS NOT NULL AND @post_fwd_count > 0
                    BEGIN
                        SET @Msg = N'  WARNING: Post-rebuild check found ' + CAST(@post_fwd_count AS nvarchar(20))
                                 + N' forwarded records still present on ' + @full + N'.';
                        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                    END
                    ELSE IF @post_fwd_count = 0
                    BEGIN
                        SET @Msg = N'  Verified: 0 forwarded records.';
                        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                    END
                END

                /*
                Live calibration: accumulate throughput data from this rebuild.
                Only counts rebuilds that took > 500ms (sub-500ms are too fast for meaningful rate).
                */
                IF @EstimateTime = 1
                BEGIN
                    SET @rebuild_elapsed_ms = DATEDIFF(MILLISECOND, @start, @end);

                    IF @rebuild_elapsed_ms > 500
                    BEGIN
                        SET @live_pages_rebuilt += @cur_page_count;
                        SET @live_elapsed_ms   += @rebuild_elapsed_ms;
                        SET @live_pps = CAST(@live_pages_rebuilt AS float)
                                      / NULLIF(@live_elapsed_ms / 1000.0, 0);

                        -- Update remaining targets with live rate
                        UPDATE #Targets
                        SET est_pages_per_sec = @live_pps,
                            est_seconds       = CEILING(page_count / NULLIF(@live_pps, 0))
                        WHERE sort_order > @i;

                        UPDATE #Targets
                        SET est_duration = RIGHT('00' + CAST(est_seconds / 3600 AS varchar(10)), 2) + ':'
                                         + RIGHT('00' + CAST((est_seconds % 3600) / 60 AS varchar(2)), 2) + ':'
                                         + RIGHT('00' + CAST(est_seconds % 60 AS varchar(2)), 2)
                        WHERE sort_order > @i AND est_seconds IS NOT NULL;

                        -- Compute and display remaining time estimate
                        SELECT @remaining_pages = SUM(page_count) FROM #Targets WHERE sort_order > @i;

                        IF @remaining_pages IS NOT NULL AND @remaining_pages > 0
                        BEGIN
                            SET @remaining_est_sec = CEILING(@remaining_pages / NULLIF(@live_pps, 0));

                            SET @Msg = N'  Live rate: ' + CAST(CAST(@live_pps AS int) AS nvarchar(20)) + N' pages/sec'
                                     + N'  |  Remaining: ~'
                                     + RIGHT('00' + CAST(@remaining_est_sec / 3600 AS varchar(10)), 2) + ':'
                                     + RIGHT('00' + CAST((@remaining_est_sec % 3600) / 60 AS varchar(2)), 2) + ':'
                                     + RIGHT('00' + CAST(@remaining_est_sec % 60 AS varchar(2)), 2);
                            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                        END
                    END
                END

                /*
                Log success to CommandLog
                */
                IF @commandlog_exists = 1
                BEGIN
                    SET @extended_info = (
                        SELECT
                            @cur_page_count AS PageCount,
                            CAST(@cur_page_count AS decimal(18,2)) / 128.0 AS SizeMB,
                            @cur_fwd_count AS ForwardedRecords,
                            @cur_fwd_pct AS ForwardedPct,
                            @cur_cpu_ms AS TotalCpuMs,
                            @post_fwd_count AS PostRebuildForwardedRecords
                        FOR XML RAW(N'ExtendedInfo'), ELEMENTS
                    );

                    INSERT INTO dbo.CommandLog
                        (DatabaseName, SchemaName, ObjectName, ObjectType, Command, CommandType,
                         StartTime, EndTime, ErrorNumber, ErrorMessage, ExtendedInfo)
                    VALUES
                        (@db, @schema, @tbl, N'U', @cmd, @action,
                         @start, @end, 0, NULL, @extended_info);
                END
            END TRY
            BEGIN CATCH
                SET @end = SYSDATETIME();
                SET @elapsed_sec = DATEDIFF(SECOND, @start, @end);

                SET @err_number = ERROR_NUMBER();
                SET @err_message = ERROR_MESSAGE();

                -- Restore lock timeout (prefix ran but suffix did not due to error)
                IF @LockTimeoutMs IS NOT NULL
                    EXEC sys.sp_executesql @LockSuffix;

                UPDATE @ExecLog
                  SET end_time = @end,
                      succeeded = 0,
                      error_number = @err_number,
                      error_message = @err_message
                WHERE target_id = @tid;

                SET @Msg = N'  FAILED (' + CAST(@elapsed_sec AS nvarchar(10)) + N's): '
                         + N'Error ' + CAST(@err_number AS nvarchar(10)) + N' - '
                         + LEFT(@err_message, 300);
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;

                SET @failed_cnt += 1;

                /*
                Log failure to CommandLog
                */
                IF @commandlog_exists = 1
                BEGIN
                    SET @extended_info = (
                        SELECT
                            @cur_page_count AS PageCount,
                            CAST(@cur_page_count AS decimal(18,2)) / 128.0 AS SizeMB,
                            @cur_fwd_count AS ForwardedRecords,
                            @cur_fwd_pct AS ForwardedPct,
                            @cur_cpu_ms AS TotalCpuMs
                        FOR XML RAW(N'ExtendedInfo'), ELEMENTS
                    );

                    INSERT INTO dbo.CommandLog
                        (DatabaseName, SchemaName, ObjectName, ObjectType, Command, CommandType,
                         StartTime, EndTime, ErrorNumber, ErrorMessage, ExtendedInfo)
                    VALUES
                        (@db, @schema, @tbl, N'U', @cmd, @action,
                         @start, @end, @err_number, @err_message, @extended_info);
                END
            END CATCH;
        END

        /*
        Summary
        */
        RAISERROR(N'', 10, 1) WITH NOWAIT;
        RAISERROR(N'===============================================================================', 10, 1) WITH NOWAIT;
        SET @Msg = N' Done. Succeeded: ' + CAST(@succeeded_cnt AS nvarchar(10))
                 + N'  Failed: ' + CAST(@failed_cnt AS nvarchar(10))
                 + N'  Skipped: ' + CAST(@skipped_cnt AS nvarchar(10))
                 + CASE WHEN @discovery_errors > 0
                        THEN N'  ScanErrors: ' + CAST(@discovery_errors AS nvarchar(10))
                        ELSE N'' END
                 + N'  Elapsed: ' + CAST(DATEDIFF(SECOND, @RunStart, SYSDATETIME()) AS nvarchar(10)) + N's'
                 + CASE WHEN @EstimateTime = 1 AND @live_pps IS NOT NULL
                        THEN N'  AvgRate: ' + CAST(CAST(@live_pps AS int) AS nvarchar(20)) + N' pages/sec'
                        ELSE N'' END;
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        RAISERROR(N'===============================================================================', 10, 1) WITH NOWAIT;

        /*
        Log run END to CommandLog
        */
        IF @commandlog_exists = 1
        BEGIN
            INSERT INTO dbo.CommandLog
                (DatabaseName, SchemaName, ObjectName, ObjectType, Command, CommandType,
                 StartTime, EndTime, ErrorNumber, ErrorMessage, ExtendedInfo)
            VALUES
            (
                ISNULL(@Databases, DB_NAME()),
                N'dbo',
                N'sp_HeapDoctor',
                N'P',
                N'EXECUTE dbo.sp_HeapDoctor @Databases = N''' + REPLACE(ISNULL(@Databases, DB_NAME()), N'''', N'''''') + N'''...',
                N'HEAP_REBUILD_END',
                @start_time,
                SYSDATETIME(),
                0,
                NULL,
                (
                    SELECT
                        @succeeded_cnt AS Succeeded,
                        @failed_cnt AS Failed,
                        @skipped_cnt AS Skipped,
                        @discovery_errors AS ScanErrors,
                        @TargetCount AS TotalTargets,
                        DATEDIFF(SECOND, @RunStart, SYSDATETIME()) AS ElapsedSeconds,
                        CASE
                            WHEN @failed_cnt > 0 THEN N'COMPLETED_WITH_ERRORS'
                            WHEN @discovery_errors > 0 THEN N'COMPLETED_WITH_SCAN_ERRORS'
                            WHEN @skipped_cnt > 0 THEN N'COMPLETED_WITH_SKIPS'
                            ELSE N'SUCCESS'
                        END AS StopReason,
                        CASE WHEN @EstimateTime = 1 THEN @live_pages_rebuilt END AS TotalPagesRebuilt,
                        CASE WHEN @EstimateTime = 1 THEN CAST(@live_pps AS int) END AS AvgPagesPerSec
                    FOR XML RAW(N'Summary'), ELEMENTS
                )
            );
        END

        SELECT * FROM @ExecLog ORDER BY start_time, target_id;
    END
END
GO
