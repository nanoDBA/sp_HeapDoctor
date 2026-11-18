/* Test 48 verifies that obfuscation covers CI commands and failure logs. */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;
GO

CREATE TABLE #M79CForbiddenPatterns (pattern nvarchar(128) NOT NULL);
INSERT INTO #M79CForbiddenPatterns (pattern)
VALUES
    (N'%M79CTestHeap%'),
    (N'%M79CFailureHeap%'),
    (N'%M79CSecretPatientNumber%'),
    (N'%M79CSecret,Key%'),
    (N'%M79CPrivateGroup%'),
    (N'%M79CPrivateGroupFile%'),
    (N'%M79CMismatchHeap%'),
    (N'%M79CMismatchSecretKey%'),
    (N'%M79CMismatchAlternateKey%'),
    (N'%UX_M79CMismatchKey%'),
    (N'%UX_M79CSecretKey%'),
    (N'%M79CTemporalParent%'),
    (N'%M79CTemporalHistory%');

/*#region 48A-FIXTURE*/
ALTER DATABASE HeapDoctorTest ADD FILEGROUP M79CTestHeap;
DECLARE
    @data_file_path nvarchar(4000),
    @data_directory nvarchar(4000),
    @path_separator_position int,
    @add_file_sql nvarchar(max);

SELECT TOP (1) @data_file_path = physical_name
FROM sys.database_files
WHERE file_id = 1;

SET @path_separator_position = CASE
    WHEN CHARINDEX(N'/', REVERSE(@data_file_path)) > 0
        THEN CHARINDEX(N'/', REVERSE(@data_file_path))
    ELSE CHARINDEX(N'\', REVERSE(@data_file_path))
END;
SET @data_directory = LEFT(@data_file_path, LEN(@data_file_path) - @path_separator_position + 1);
SET @add_file_sql = N'ALTER DATABASE [HeapDoctorTest] ADD FILE
    (NAME = N''M79CPrivateGroupFile'', FILENAME = N'''
    + REPLACE(@data_directory + N'M79CPrivateGroup.ndf', N'''', N'''''')
    + N''', SIZE = 8MB) TO FILEGROUP [M79CTestHeap];';
EXECUTE sys.sp_executesql @add_file_sql;
SET @add_file_sql = N'ALTER DATABASE [HeapDoctorTest] ADD FILE
    (NAME = N''M79CPrivateGroupFile2'', FILENAME = N'''
    + REPLACE(@data_directory + N'M79CPrivateGroup2.ndf', N'''', N'''''')
    + N''', SIZE = 8MB) TO FILEGROUP [M79CTestHeap];';
EXECUTE sys.sp_executesql @add_file_sql;

CREATE TABLE dbo.M79CTestHeap
(
    M79CTestHeap int NOT NULL,
    M79CSecretPatientNumber int NOT NULL,
    [M79CSecret,Key] int NOT NULL,
    Padding varchar(4000) NOT NULL
) ON M79CTestHeap;

CREATE UNIQUE NONCLUSTERED INDEX UX_M79CSecretKey
    ON dbo.M79CTestHeap (M79CTestHeap, M79CSecretPatientNumber, [M79CSecret,Key]);

;WITH N AS
(
    SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
)
INSERT dbo.M79CTestHeap (M79CTestHeap, M79CSecretPatientNumber, [M79CSecret,Key], Padding)
SELECT TOP (6000) n, n, n, REPLICATE('A', 10)
FROM N;

UPDATE dbo.M79CTestHeap
SET Padding = REPLICATE('X', 3000)
WHERE M79CSecretPatientNumber <= 4000;
GO
/*#endregion*/

/*#region 48B-OBFUSCATED-PLAN*/
SELECT *
INTO #PlanResults
FROM dbo.ResultsTemplate
WHERE 1 = 0;

DECLARE
    @plan_log_start int,
    @plan_run_id uniqueidentifier,
    @plan_action varchar(32),
    @plan_rows int,
    @plan_command nvarchar(max),
    @plan_filegroup sysname,
    @expected_filegroup sysname,
    @expected_key_cols nvarchar(max),
    @plan_invocation_command nvarchar(max);

SELECT @plan_log_start = COALESCE(MAX(ID), 0)
FROM dbo.CommandLog;

INSERT INTO #PlanResults
EXECUTE dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.M79CTestHeap',
    @ExcludeDatabases = N'NeverMatchDatabase%',
    @ExcludeTables = N'dbo.NeverMatchTable',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @LogToTable = N'Y',
    @MinPages = 10,
    @MinForwardedPct = 0,
    @AllowCiSwap = 1,
    @PreferCiSwap = 1,
    @OnlinePreference = N'ON',
    @OutputTable = N'dbo.M79CPlanOutput',
    @ObfuscateKey = N'regression-obfuscation-key',
    @ObfuscateSeed = N'fixed-obfuscation-seed-a';

SELECT
    @plan_rows = COUNT(*),
    @plan_action = MAX(action_chosen),
    @plan_command = MAX(command_text),
    @plan_filegroup = MAX(filegroup_name)
FROM #PlanResults;

SET @expected_filegroup = N'FG_' + LEFT(CONVERT(nvarchar(64), HASHBYTES
    (N'SHA2_256', N'regression-obfuscation-keyfixed-obfuscation-seed-aM79CTestHeap'), 2), 8);
SET @expected_key_cols = QUOTENAME(N'C_' + LEFT(CONVERT(nvarchar(64), HASHBYTES
    (N'SHA2_256', N'regression-obfuscation-keyfixed-obfuscation-seed-aM79CTestHeap'), 2), 8))
    + N',' + QUOTENAME(N'C_' + LEFT(CONVERT(nvarchar(64), HASHBYTES
    (N'SHA2_256', N'regression-obfuscation-keyfixed-obfuscation-seed-aM79CSecretPatientNumber'), 2), 8))
    + N',' + QUOTENAME(N'C_' + LEFT(CONVERT(nvarchar(64), HASHBYTES
    (N'SHA2_256', N'regression-obfuscation-keyfixed-obfuscation-seed-aM79CSecret,Key'), 2), 8));

SELECT TOP (1) @plan_run_id = run_id
FROM dbo.M79CPlanOutput
ORDER BY captured_at DESC;

IF @plan_rows = 1
AND @plan_action LIKE N'CI_SWAP%'
AND EXISTS
(
    SELECT 1
    FROM #PlanResults AS r
    INNER JOIN dbo.ExpectedVersion AS e
        ON e.version = r.version
)
AND @plan_run_id IS NOT NULL
AND @plan_command IS NOT NULL
AND @plan_filegroup = @expected_filegroup
AND CHARINDEX(N'(' + @expected_key_cols + N')', @plan_command) > 0
AND EXISTS
(
    SELECT 1
    FROM dbo.CommandLog AS cl
    WHERE cl.CommandType = N'HEAP_SCAN_SUMMARY'
      AND cl.ExtendedInfo.exist(N'/ScanSummary/RunID[text()=sql:variable("@plan_run_id")]') = 1
)
    RAISERROR(N'PASS 48A: obfuscated CI-swap fixture has the expected version and a persisted run ID.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 48A: expected one versioned CI-swap plan and its persisted run ID.', 10, 1) WITH NOWAIT;

IF EXISTS
(
    SELECT 1
    FROM #PlanResults AS r
    CROSS APPLY (VALUES
        (CONVERT(nvarchar(max), r.database_name)),
        (CONVERT(nvarchar(max), r.schema_name)),
        (CONVERT(nvarchar(max), r.table_name)),
        (CONVERT(nvarchar(max), r.key_source_index)),
        (CONVERT(nvarchar(max), r.filegroup_name)),
        (r.command_text),
        (r.ci_drop_command),
        (r.verify_command)
    ) AS output_value(value)
    INNER JOIN #M79CForbiddenPatterns AS forbidden
        ON output_value.value LIKE forbidden.pattern
)
OR EXISTS
(
    SELECT 1
    FROM dbo.M79CPlanOutput AS r
    CROSS APPLY (VALUES
        (CONVERT(nvarchar(max), r.database_name)),
        (CONVERT(nvarchar(max), r.schema_name)),
        (CONVERT(nvarchar(max), r.table_name)),
        (CONVERT(nvarchar(max), r.key_source_index)),
        (CONVERT(nvarchar(max), r.filegroup_name)),
        (r.command_text)
    ) AS output_value(value)
    INNER JOIN #M79CForbiddenPatterns AS forbidden
        ON output_value.value LIKE forbidden.pattern
    WHERE r.run_id = @plan_run_id
)
    RAISERROR(N'FAIL 48B: the obfuscated result set or @OutputTable exposes a real object, column, index, or filegroup name.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'PASS 48B: the obfuscated result set and @OutputTable hide real object, column, index, and filegroup names.', 10, 1) WITH NOWAIT;

IF EXISTS
(
    SELECT 1
    FROM dbo.CommandLog AS cl
    CROSS APPLY (VALUES
        (CONVERT(nvarchar(max), cl.DatabaseName)),
        (CONVERT(nvarchar(max), cl.SchemaName)),
        (CONVERT(nvarchar(max), cl.ObjectName)),
        (CONVERT(nvarchar(max), cl.IndexName)),
        (cl.Command),
        (cl.ErrorMessage),
        (CONVERT(nvarchar(max), cl.ExtendedInfo))
    ) AS logged_value(value)
    INNER JOIN #M79CForbiddenPatterns AS forbidden
        ON logged_value.value LIKE forbidden.pattern
    WHERE cl.ID > @plan_log_start
)
    RAISERROR(N'FAIL 48C: a plan-only CommandLog row exposes a real object, column, index, or filegroup name.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'PASS 48C: all plan-only CommandLog rows hide real object, column, index, and filegroup names.', 10, 1) WITH NOWAIT;

SELECT TOP (1) @plan_invocation_command = cl.Command
FROM dbo.CommandLog AS cl
WHERE cl.CommandType = N'HEAP_SCAN_SUMMARY'
  AND cl.ExtendedInfo.exist(N'/ScanSummary/RunID[text()=sql:variable("@plan_run_id")]') = 1
ORDER BY cl.ID DESC;

IF @plan_invocation_command LIKE N'%@AllowCiSwap = 1%'
AND @plan_invocation_command LIKE N'%@PreferCiSwap = 1%'
AND @plan_invocation_command LIKE N'%@OnlinePreference = N''ON''%'
AND @plan_invocation_command LIKE N'%@MinPages = 10%'
AND CHARINDEX(N'@Databases = N''[obfuscated]''', @plan_invocation_command) > 0
AND CHARINDEX(N'@ExcludeDatabases = N''[obfuscated]''', @plan_invocation_command) > 0
AND CHARINDEX(N'@Tables = N''[obfuscated]''', @plan_invocation_command) > 0
AND CHARINDEX(N'@ExcludeTables = N''[obfuscated]''', @plan_invocation_command) > 0
AND CHARINDEX(N'@OutputTable = N''[obfuscated]''', @plan_invocation_command) > 0
AND CHARINDEX(N'@ObfuscateKey = N''***''', @plan_invocation_command) > 0
AND CHARINDEX(N'@ObfuscateSeed = N''***''', @plan_invocation_command) > 0
    RAISERROR(N'PASS 48K: invocation logging preserves safe options and masks names and secrets.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 48K: invocation logging omits safe options or exposes a name or secret.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 48K-MISMATCHED-KEY-METADATA*/
CREATE TABLE dbo.M79CMismatchHeap
(
    ID int NOT NULL,
    M79CMismatchSecretKey int NOT NULL,
    M79CMismatchAlternateKey int NOT NULL,
    Padding varchar(4000) NOT NULL
) ON M79CTestHeap;

;WITH N AS
(
    SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
)
INSERT dbo.M79CMismatchHeap (ID, M79CMismatchSecretKey, M79CMismatchAlternateKey, Padding)
SELECT TOP (6000) n, n, n, REPLICATE('A', 10) FROM N;
UPDATE dbo.M79CMismatchHeap SET Padding = REPLICATE('X', 3000) WHERE ID <= 4000;
CREATE UNIQUE NONCLUSTERED INDEX UX_M79CMismatchKey
    ON dbo.M79CMismatchHeap (ID, M79CMismatchSecretKey);
GO

SELECT * INTO #MismatchPlan
FROM dbo.ResultsTemplate
WHERE 1 = 0;

DECLARE
    @mismatch_run_id uniqueidentifier,
    @mismatch_original_command nvarchar(max),
    @mismatch_tampered_command nvarchar(max),
    @mismatch_action varchar(32),
    @mismatch_command nvarchar(max),
    @mismatch_forced bit = 0;

INSERT INTO #MismatchPlan
EXECUTE dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.M79CMismatchHeap',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @LogToTable = N'Y',
    @MinPages = 10,
    @MinForwardedPct = 0,
    @IncludeHealthyHeaps = 1,
    @AllowCiSwap = 1,
    @PreferCiSwap = 1,
    @OnlinePreference = N'ON';

SELECT TOP (1)
    @mismatch_original_command = command_text
FROM #MismatchPlan;

SELECT TOP (1)
    @mismatch_run_id = TRY_CONVERT(uniqueidentifier,
        ExtendedInfo.value(N'(/ScanSummary/RunID/text())[1]', N'nvarchar(36)'))
FROM dbo.CommandLog
WHERE CommandType = N'HEAP_SCAN_SUMMARY'
  AND ExtendedInfo.exist(N'/ScanSummary/RunID[1]') = 1
ORDER BY ID DESC;

SET @mismatch_tampered_command = REPLACE
(
    @mismatch_original_command,
    N'[M79CMismatchSecretKey]',
    N'[M79CMismatchSecretKey], [M79CMismatchAlternateKey]'
);
IF @mismatch_tampered_command <> @mismatch_original_command
    SET @mismatch_forced = 1;

UPDATE dbo.CommandLog
SET ExtendedInfo.modify
(
    'replace value of (/ScanSummary/Targets/Target/@CommandText)[1]
     with sql:variable("@mismatch_tampered_command")'
)
WHERE CommandType = N'HEAP_SCAN_SUMMARY'
  AND ExtendedInfo.exist(N'/ScanSummary/RunID[text()=sql:variable("@mismatch_run_id")]') = 1;

SELECT * INTO #MismatchResults
FROM dbo.ResultsTemplate
WHERE 1 = 0;

INSERT INTO #MismatchResults
EXECUTE dbo.sp_HeapDoctor
    @ResumeRunID = @mismatch_run_id,
    @PlanOnly = 1,
    @LogToTable = N'Y',
    @OutputTable = N'dbo.M79CMismatchOutput',
    @ObfuscateKey = N'regression-obfuscation-key',
    @ObfuscateSeed = N'fixed-obfuscation-seed-m';

SELECT @mismatch_action = MAX(action_chosen), @mismatch_command = MAX(command_text)
FROM #MismatchResults;

IF (SELECT COUNT_BIG(*) FROM #MismatchResults) = 1
AND @mismatch_forced = 1
AND @mismatch_action LIKE N'CI_SWAP%'
AND @mismatch_command LIKE N'-- Obfuscated command omitted%'
AND NOT EXISTS
(
    SELECT 1
    FROM #MismatchResults AS r
    CROSS APPLY (VALUES (r.command_text), (r.ci_drop_command), (r.verify_command)) AS commands(value)
    INNER JOIN #M79CForbiddenPatterns AS forbidden ON commands.value LIKE forbidden.pattern
)
AND NOT EXISTS
(
    SELECT 1
    FROM dbo.M79CMismatchOutput AS r
    CROSS APPLY (VALUES (r.command_text)) AS commands(value)
    INNER JOIN #M79CForbiddenPatterns AS forbidden ON commands.value LIKE forbidden.pattern
)
    RAISERROR(N'PASS 48L: stale key metadata causes an omitted, pseudonym-safe command.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @failure_48l nvarchar(2048) = N'FAIL 48L: action='
        + ISNULL(@mismatch_action, N'NULL') + N' command='
        + LEFT(ISNULL(@mismatch_command, N'NULL'), 1500)
        + N' mismatch_forced=' + CONVERT(nvarchar(1), @mismatch_forced) + N'.';
    RAISERROR(N'%s', 10, 1, @failure_48l) WITH NOWAIT;
END

DROP TABLE dbo.M79CMismatchHeap;
DROP TABLE dbo.M79CMismatchOutput;
GO
/*#endregion*/

/*#region 48C-CONTROLLED-FAILURE*/
CREATE TABLE dbo.M79CFailureHeap
(
    ID int NOT NULL,
    Padding varchar(4000) NOT NULL
) ON M79CTestHeap;

;WITH N AS
(
    SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
)
INSERT dbo.M79CFailureHeap (ID, Padding)
SELECT TOP (6000) n, REPLICATE('A', 10)
FROM N;

UPDATE dbo.M79CFailureHeap
SET Padding = REPLICATE('Y', 3000)
WHERE ID <= 4000;
GO

CREATE TRIGGER trg_M79CFailRebuild
ON DATABASE
FOR ALTER_TABLE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @event xml = EVENTDATA();
    IF @event.value('(/EVENT_INSTANCE/ObjectName)[1]', 'sysname') = N'M79CFailureHeap'
        RAISERROR(N'M79CFailureHeap M79CSecretPatientNumber M79CPrivateGroup', 16, 1);
END;
GO

DECLARE
    @failure_log_start int,
    @failure_count int,
    @failure_run_id uniqueidentifier,
    @failure_status varchar(10);

SELECT @failure_log_start = COALESCE(MAX(ID), 0)
FROM dbo.CommandLog;

EXECUTE dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.M79CFailureHeap',
    @CpuSource = N'NONE',
    @PlanOnly = 0,
    @LogToTable = N'Y',
    @MinPages = 10,
    @MinForwardedPct = 0,
    @OutputTable = N'dbo.M79CFailureOutput',
    @ObfuscateKey = N'regression-obfuscation-key',
    @ObfuscateSeed = N'fixed-obfuscation-seed-b',
    @Failed = @failure_count OUTPUT,
    @Status = @failure_status OUTPUT;

SELECT TOP (1) @failure_run_id = run_id
FROM dbo.M79CFailureOutput
ORDER BY captured_at DESC;

IF @failure_count = 1
AND @failure_run_id IS NOT NULL
AND EXISTS
(
    SELECT 1
    FROM dbo.CommandLog AS cl
    WHERE cl.ID > @failure_log_start
      AND cl.ErrorNumber IS NOT NULL
      AND cl.CommandType = N'HEAP_TARGET_EVENT'
)
    RAISERROR(N'PASS 48D: the controlled rebuild failure is retained with an error number and target event.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 48D: the controlled rebuild failure was not retained with an error number and target event.', 10, 1) WITH NOWAIT;

IF EXISTS
(
    SELECT 1
    FROM dbo.M79CFailureOutput AS r
    CROSS APPLY (VALUES
        (CONVERT(nvarchar(max), r.database_name)),
        (CONVERT(nvarchar(max), r.schema_name)),
        (CONVERT(nvarchar(max), r.table_name)),
        (CONVERT(nvarchar(max), r.key_source_index)),
        (CONVERT(nvarchar(max), r.filegroup_name)),
        (r.command_text)
    ) AS output_value(value)
    INNER JOIN #M79CForbiddenPatterns AS forbidden
        ON output_value.value LIKE forbidden.pattern
    WHERE r.run_id = @failure_run_id
)
    RAISERROR(N'FAIL 48E: the failed target row in @OutputTable exposes a real object, column, index, or filegroup name.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'PASS 48E: the failed target row in @OutputTable hides real object, column, index, and filegroup names.', 10, 1) WITH NOWAIT;

IF EXISTS
(
    SELECT 1
    FROM dbo.CommandLog AS cl
    CROSS APPLY (VALUES
        (CONVERT(nvarchar(max), cl.DatabaseName)),
        (CONVERT(nvarchar(max), cl.SchemaName)),
        (CONVERT(nvarchar(max), cl.ObjectName)),
        (CONVERT(nvarchar(max), cl.IndexName)),
        (cl.Command),
        (cl.ErrorMessage),
        (CONVERT(nvarchar(max), cl.ExtendedInfo))
    ) AS logged_value(value)
    INNER JOIN #M79CForbiddenPatterns AS forbidden
        ON logged_value.value LIKE forbidden.pattern
    WHERE cl.ID > @failure_log_start
)
    RAISERROR(N'FAIL 48F: a rebuild-failure CommandLog row exposes a real object, column, index, or filegroup name.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'PASS 48F: failure and target-event CommandLog rows hide real object, column, index, and filegroup names.', 10, 1) WITH NOWAIT;

DROP TRIGGER trg_M79CFailRebuild ON DATABASE;
DROP TABLE dbo.M79CFailureHeap;
DROP TABLE dbo.M79CTestHeap;
GO

/*#region 48G-TEMPORAL-RECOVERY*/
CREATE TABLE dbo.M79CTemporalParent
(
    ID int NOT NULL CONSTRAINT PK_M79CTemporalParent PRIMARY KEY CLUSTERED,
    Payload varchar(2000) NOT NULL,
    ValidFrom datetime2(7) GENERATED ALWAYS AS ROW START NOT NULL,
    ValidTo datetime2(7) GENERATED ALWAYS AS ROW END NOT NULL,
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
);

CREATE TABLE dbo.M79CTemporalHistory
(
    ID int NOT NULL,
    Payload varchar(2000) NOT NULL,
    ValidFrom datetime2(7) NOT NULL,
    ValidTo datetime2(7) NOT NULL
);

ALTER TABLE dbo.M79CTemporalParent
SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.M79CTemporalHistory));

;WITH N AS
(
    SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
)
INSERT dbo.M79CTemporalParent (ID, Payload)
SELECT TOP (6000) n, REPLICATE('A', 10)
FROM N;

UPDATE dbo.M79CTemporalParent
SET Payload = REPLICATE('X', 2000);
GO

DECLARE
    @temporal_log_start int,
    @temporal_targets int,
    @temporal_succeeded int,
    @temporal_failed int,
    @temporal_status varchar(10),
    @temporal_run_id uniqueidentifier,
    @temporal_recovery_hex nvarchar(max),
    @temporal_recovery_ddl nvarchar(max);

SELECT @temporal_log_start = COALESCE(MAX(ID), 0)
FROM dbo.CommandLog;

EXECUTE dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.M79CTemporalHistory',
    @CpuSource = N'NONE',
    @PlanOnly = 0,
    @LogToTable = N'Y',
    @MinPages = 10,
    @MinForwardedPct = 0,
    @IncludeTemporalHistory = 1,
    @IncludeHealthyHeaps = 1,
    @OutputTable = N'dbo.M79CTemporalOutput',
    @ObfuscateKey = N'regression-obfuscation-key',
    @ObfuscateSeed = N'fixed-obfuscation-seed-c',
    @TargetsFound = @temporal_targets OUTPUT,
    @Succeeded = @temporal_succeeded OUTPUT,
    @Failed = @temporal_failed OUTPUT,
    @Status = @temporal_status OUTPUT;

SELECT TOP (1) @temporal_run_id = run_id
FROM dbo.M79CTemporalOutput
ORDER BY captured_at DESC;

IF @temporal_targets = 1
AND @temporal_succeeded = 1
AND @temporal_failed = 0
AND @temporal_run_id IS NOT NULL
AND EXISTS
(
    SELECT 1
    FROM sys.tables
    WHERE object_id = OBJECT_ID(N'dbo.M79CTemporalParent')
      AND temporal_type_desc = N'SYSTEM_VERSIONED_TEMPORAL_TABLE'
)
    RAISERROR(N'PASS 48G: an obfuscated temporal-history rebuild completed and restored system versioning.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 48G: temporal history was not rebuilt successfully or system versioning was not restored.', 10, 1) WITH NOWAIT;

SELECT TOP (1)
    @temporal_recovery_hex = cl.ExtendedInfo.value
        (N'(/ExtendedInfo/RecoveryDdlHex)[1]', N'nvarchar(max)')
FROM dbo.CommandLog AS cl
WHERE cl.ID > @temporal_log_start
  AND cl.CommandType = N'HEAP_TEMPORAL_VERSIONING_DISABLED'
  AND cl.ExtendedInfo.exist(N'/ExtendedInfo/RunID[text()=sql:variable("@temporal_run_id")]') = 1
ORDER BY cl.ID DESC;

SET @temporal_recovery_ddl = CONVERT(nvarchar(max), DECRYPTBYPASSPHRASE
(
    N'regression-obfuscation-keyfixed-obfuscation-seed-c',
    CONVERT(varbinary(max), @temporal_recovery_hex, 2)
));

IF @temporal_recovery_ddl LIKE N'%M79CTemporalParent%'
AND @temporal_recovery_ddl LIKE N'%M79CTemporalHistory%'
    RAISERROR(N'PASS 48H: the recovery breadcrumb protects DDL that can be decrypted with the run key.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 48H: the recovery breadcrumb did not preserve decryptable temporal recovery DDL.', 10, 1) WITH NOWAIT;

IF EXISTS
(
    SELECT 1
    FROM dbo.CommandLog AS cl
    CROSS APPLY (VALUES
        (CONVERT(nvarchar(max), cl.DatabaseName)),
        (CONVERT(nvarchar(max), cl.SchemaName)),
        (CONVERT(nvarchar(max), cl.ObjectName)),
        (CONVERT(nvarchar(max), cl.IndexName)),
        (cl.Command),
        (cl.ErrorMessage),
        (CONVERT(nvarchar(max), cl.ExtendedInfo))
    ) AS logged_value(value)
    INNER JOIN #M79CForbiddenPatterns AS forbidden
        ON logged_value.value LIKE forbidden.pattern
    WHERE cl.ID > @temporal_log_start
)
    RAISERROR(N'FAIL 48I: a temporal-run CommandLog row exposes a real object name.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'PASS 48I: temporal recovery, start, target, and end CommandLog rows hide real names.', 10, 1) WITH NOWAIT;

IF EXISTS
(
    SELECT 1
    FROM dbo.M79CTemporalOutput AS r
    CROSS APPLY (VALUES
        (CONVERT(nvarchar(max), r.database_name)),
        (CONVERT(nvarchar(max), r.schema_name)),
        (CONVERT(nvarchar(max), r.table_name)),
        (CONVERT(nvarchar(max), r.key_source_index)),
        (CONVERT(nvarchar(max), r.filegroup_name)),
        (r.command_text)
    ) AS output_value(value)
    INNER JOIN #M79CForbiddenPatterns AS forbidden
        ON output_value.value LIKE forbidden.pattern
    WHERE r.run_id = @temporal_run_id
)
    RAISERROR(N'FAIL 48J: the temporal @OutputTable row exposes a real object name.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'PASS 48J: the temporal @OutputTable row hides real names.', 10, 1) WITH NOWAIT;

ALTER TABLE dbo.M79CTemporalParent SET (SYSTEM_VERSIONING = OFF);
DROP TABLE dbo.M79CTemporalParent;
DROP TABLE dbo.M79CTemporalHistory;
DROP TABLE dbo.M79CPlanOutput;
DROP TABLE dbo.M79CFailureOutput;
DROP TABLE dbo.M79CTemporalOutput;
DBCC SHRINKFILE (N'M79CPrivateGroupFile', EMPTYFILE);
ALTER DATABASE HeapDoctorTest REMOVE FILE M79CPrivateGroupFile;
DBCC SHRINKFILE (N'M79CPrivateGroupFile2', 1);
ALTER DATABASE HeapDoctorTest REMOVE FILE M79CPrivateGroupFile2;
ALTER DATABASE HeapDoctorTest REMOVE FILEGROUP M79CTestHeap;
GO
/*#endregion*/
