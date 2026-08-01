# Obfuscation for external sharing

Full walkthrough for `@ObfuscateKey`, `@ObfuscateSeed`, `@RevealKey` and `@RevealRunID`.
A short summary lives in the [README](../README.md#obfuscation-for-external-sharing);
this is the detail: reveal workflows, cross-environment comparison, joining the mapping
back to CommandLog history, and the end-to-end example.

## Basic usage

```sql
-- Plan-only with obfuscated names (safe to share)
EXEC dbo.sp_HeapDoctor
    @Databases    = 'USER_DATABASES',
    @ObfuscateKey = 'my secret passphrase',
    @PlanOnly     = 1;
```

Output columns `database_name`, `schema_name`, `table_name`, `key_source_index`, `command_text`, `ci_drop_command`, and `verify_command` all show pseudonyms instead of real names.  The pseudonym format is `PREFIX_` + 8 hex characters (SHA2_256 derived), where prefixes are `DB_` (database), `S_` (schema), `T_` (table), and `I_` (index).

## Execute with obfuscation

```sql
-- Execute rebuilds; CommandLog entries use pseudonyms
EXEC dbo.sp_HeapDoctor
    @Databases    = 'USER_DATABASES',
    @ObfuscateKey = 'my secret passphrase',
    @PlanOnly     = 0;

-- Output includes:
-- "Obfuscation applied to 5 targets.
--  RunID=153ACF40-D520-4472-ABE1-8A9BC99203A7
--  (provide with @RevealKey to decrypt)."
```

Save the RunID.  You'll need it to reveal the mapping later.

## Revealing the real names

```sql
-- Decrypt the mapping from a previous obfuscated run
EXEC dbo.sp_HeapDoctor
    @RevealKey   = 'my secret passphrase',
    @RevealRunID = '153ACF40-D520-4472-ABE1-8A9BC99203A7';
```

Returns a result set mapping each pseudonym back to the real object name:

| pseudonym | object_type | real_name |
|-----------|-------------|-----------|
| DB_AA92F53B | DB | ProductionDB |
| S_9F96C397 | Schema | dbo |
| T_43306ED0 | Table | Orders |
| T_8B2F1A77 | Table | Customers |

## Cross-environment comparison

When comparing obfuscated reports from multiple servers (dev, staging, prod), use `@ObfuscateSeed` to ensure the same tables get the same pseudonyms:

```sql
-- Same key + seed = same pseudonyms across environments
-- Run on Server A:
EXEC dbo.sp_HeapDoctor
    @ObfuscateKey  = 'shared passphrase',
    @ObfuscateSeed = 'Q1-2026-audit',
    @PlanOnly      = 1;

-- Run on Server B with same key and seed:
EXEC dbo.sp_HeapDoctor
    @ObfuscateKey  = 'shared passphrase',
    @ObfuscateSeed = 'Q1-2026-audit',
    @PlanOnly      = 1;
```

Tables with the same name on both servers will have identical pseudonyms, enabling side-by-side comparison without exposing real names.  Without `@ObfuscateSeed`, each run auto-seeds with its unique RunID, producing different pseudonyms even with the same key.

## Finding available RunIDs

If you lost the RunID from the session output, query CommandLog to find obfuscated runs:

```sql
-- List all obfuscated sp_HeapDoctor runs with their RunIDs
-- (checks both execution runs and plan-only scan summaries)
SELECT
    ID,
    StartTime,
    CommandType,
    COALESCE(
        ExtendedInfo.value('(/Parameters/RunID)[1]', 'uniqueidentifier'),
        ExtendedInfo.value('(/ScanSummary/RunID)[1]', 'uniqueidentifier')
    ) AS RunID,
    COALESCE(
        ExtendedInfo.value('(/Parameters/ObfuscateSeed)[1]', 'nvarchar(128)'),
        ExtendedInfo.value('(/ScanSummary/ObfuscateSeed)[1]', 'nvarchar(128)')
    ) AS Seed,
    Command AS DatabasesScanned
FROM dbo.CommandLog
WHERE CommandType IN ('HEAP_REBUILD_START', 'HEAP_SCAN_SUMMARY')
  AND CAST(ExtendedInfo AS nvarchar(max)) LIKE '%ObfuscatedMappingHex%'
ORDER BY StartTime DESC;
```

## Joining reveal mapping to CommandLog history

After reveal, you can decode your full rebuild history by joining the mapping back to CommandLog:

```sql
-- Step 1: Reveal the mapping into a temp table
IF OBJECT_ID('tempdb..#Mapping') IS NOT NULL DROP TABLE #Mapping;
CREATE TABLE #Mapping (pseudonym nvarchar(20), object_type varchar(10), real_name sysname);

INSERT #Mapping
EXEC dbo.sp_HeapDoctor
    @RevealKey   = 'my secret passphrase',
    @RevealRunID = '153ACF40-D520-4472-ABE1-8A9BC99203A7';

-- Step 2: Join to CommandLog to see real names alongside rebuild results
SELECT
    c.StartTime,
    c.EndTime,
    DATEDIFF(SECOND, c.StartTime, c.EndTime) AS duration_sec,
    c.CommandType,
    ISNULL(m.real_name, c.DatabaseName) AS real_database,
    ISNULL(t.real_name, c.ObjectName) AS real_table,
    c.ErrorNumber,
    c.ErrorMessage
FROM dbo.CommandLog c
LEFT JOIN #Mapping m ON m.pseudonym = c.DatabaseName AND m.object_type = 'DB'
LEFT JOIN #Mapping t ON t.pseudonym = c.ObjectName  AND t.object_type = 'Table'
WHERE c.CommandType IN ('HEAP_REBUILD_ONLINE','HEAP_REBUILD_OFFLINE','CI_SWAP_ONLINE')
  AND CAST(c.ExtendedInfo AS nvarchar(max)) LIKE '%<RunID>153ACF40-D520-4472-ABE1-8A9BC99203A7</RunID>%'
ORDER BY c.StartTime;
```

## End-to-end workflow: cross-environment analysis

This workflow lets you analyze heap performance on a company server and safely bring the results to a non-company machine for analysis, then map findings back to real objects.

```sql
-- STEP 1: On your company server, generate an obfuscated plan-only report.
--         Use @ObfuscateSeed for consistent pseudonyms across servers.
EXEC dbo.sp_HeapDoctor
    @Databases     = 'USER_DATABASES',
    @ObfuscateKey  = 'acme-2026-audit',
    @ObfuscateSeed = 'prod-q1',
    @PlanOnly      = 1;
-- Output includes:
-- "Obfuscation applied to 5 targets.
--  RunID=153ACF40-D520-4472-ABE1-8A9BC99203A7"
-- Save this RunID! You'll need it to reveal later.

-- STEP 2: Copy the obfuscated result set to your analysis machine.
--         Use SSMS "Copy with Headers" or bcp. All object names are pseudonyms
--         (DB_AA92F53B, T_43306ED0, etc.) but metrics are real:
--         page_count, forwarded_pct, ranking_score, size_mb, total_cpu_ms, etc.

-- STEP 3: Analyze on your non-company machine.
--         Identify highest-impact heaps by ranking_score, size_mb, forwarded_pct.
--         Write notes like: "T_43306ED0 (rank 7.45, 1.2 GB, 48% forwarded) - rebuild first"
--         "T_8B2F1A77 (rank 3.12, 200 MB) - low priority, write-heavy"

-- STEP 4: Back on company server, reveal the mapping.
EXEC dbo.sp_HeapDoctor
    @RevealKey   = 'acme-2026-audit',
    @RevealRunID = '153ACF40-D520-4472-ABE1-8A9BC99203A7';
-- Returns: T_43306ED0 = Orders, T_8B2F1A77 = AuditLog, etc.
-- Now apply your recommendations using real names.
```

**Multi-server comparison with consistent pseudonyms:**

```sql
-- Run on Server A (dev):
EXEC dbo.sp_HeapDoctor
    @ObfuscateKey = 'compare-key', @ObfuscateSeed = 'env-compare', @PlanOnly = 1;

-- Run on Server B (prod):
EXEC dbo.sp_HeapDoctor
    @ObfuscateKey = 'compare-key', @ObfuscateSeed = 'env-compare', @PlanOnly = 1;

-- Tables with the same name produce identical pseudonyms on both servers.
-- Compare forwarded_pct, ranking_score, size_mb side by side in a spreadsheet.
```

**Tips for the cross-environment workflow:**

- Always use `@ObfuscateSeed` when comparing multiple servers (without it, each run uses a unique seed)
- `@LogToTable = 'Y'` (default) is required for plan-only reveal to work
- The RunID appears in session output and is also queryable from CommandLog (see "Finding available RunIDs" above)
- Numeric columns (page_count, forwarded_pct, total_cpu_ms, size_mb, est_log_mb, ranking_score) are never obfuscated
- To track trends over time, run periodic plan-only scans; each creates a HEAP_SCAN_SUMMARY entry in CommandLog

## Important notes

- **Plan-only support**: Plan-only runs store the encrypted mapping in the HEAP_SCAN_SUMMARY CommandLog entry when `@LogToTable = 'Y'` (default). Reveal mode checks both HEAP_REBUILD_START (execution runs) and HEAP_SCAN_SUMMARY (plan-only runs). If `@LogToTable = 'N'`, no mapping is stored and a warning is emitted.
- **Wrong key**: If you provide the wrong `@RevealKey`, the decryption fails with an error rather than returning wrong data.
- **RAISERROR messages**: Progress messages in the session always show real names (they are ephemeral and not captured in result sets or logs).  This is by design; you need to see real names to monitor the session.
- **Existing columns**: Physical stats, CPU metrics, ranking scores, and all numeric columns remain unobfuscated.  Only object name columns and generated command strings are pseudonymized.
