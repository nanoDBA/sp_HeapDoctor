/*
sp_HeapDoctor Test Harness - Step 2: Plan-Only Tests

Tests @PlanOnly = 1 across all CPU source modes and action preferences.
Validates that targets are found, commands are generated, nothing is executed.

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 02_test_planonly.sql
  (add -E for Windows auth, -U/-P for SQL auth, or -G for Azure AD)
*/

SET NOCOUNT ON;
USE [HeapDoctorTest];
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 2A: PlanOnly, CpuSource=NONE (baseline)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @PlanOnly  = 1;
GO

-- Verify: HeapA, HeapB, HeapC should appear. HeapD should NOT (too small).
-- Verify: total_cpu_ms should be NULL for all targets.
-- Verify: action_chosen should be HEAP_REBUILD_ONLINE (Enterprise) or HEAP_REBUILD_OFFLINE (Standard).

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 2B: PlanOnly, CpuSource=QUERY_STORE', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

EXEC dbo.sp_HeapDoctor
    @CpuSource = 'QUERY_STORE',
    @PlanOnly  = 1;
GO

-- Verify: Same targets as 2A.
-- Verify: total_cpu_ms should be populated for HeapA, HeapB, HeapC (we ran queries in setup).
-- Verify: Targets should be ordered by CPU (highest first).

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 2C: PlanOnly, CI swap enabled', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

EXEC dbo.sp_HeapDoctor
    @CpuSource     = 'NONE',
    @AllowCiSwap   = 1,
    @PreferCiSwap  = 1,
    @PlanOnly      = 1;
GO

-- Verify: HeapB should have action_chosen = CI_SWAP_ONLINE (has unique NC index, no LOB).
-- Verify: HeapA should have HEAP_REBUILD_ONLINE (no suitable key).
-- Verify: HeapC should have HEAP_REBUILD_ONLINE (has LOB column, CI swap guarded).
-- Verify: HeapB command_text should be CREATE CLUSTERED INDEX, ci_drop_command should be DROP INDEX.

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 2D: PlanOnly, @MinPages filter', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @MinPages  = 100000,
    @PlanOnly  = 1;
GO

-- Verify: Should return 0 targets (all test heaps are smaller than 100K pages).

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 2E: PlanOnly, @OnlinePreference = OFF', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

EXEC dbo.sp_HeapDoctor
    @CpuSource        = 'NONE',
    @OnlinePreference = 'OFF',
    @PlanOnly         = 1;
GO

-- Verify: action_chosen should be HEAP_REBUILD_OFFLINE for all targets.
-- Verify: command_text should NOT contain "ONLINE = ON".

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 2F: PlanOnly with @Maxdop', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @Maxdop    = 2,
    @PlanOnly  = 1;
GO

-- Verify: command_text should contain "MAXDOP = 2" for all targets.

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 2G: PlanOnly, multi-database (USER_DATABASES)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

EXEC dbo.sp_HeapDoctor
    @Databases = 'USER_DATABASES',
    @CpuSource = 'NONE',
    @PlanOnly  = 1;
GO

-- Verify: Should scan all user databases. HeapDoctorTest targets should appear.
-- Verify: database_name column should show HeapDoctorTest for our targets.

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Plan-only tests complete. Review output above.', 10, 1) WITH NOWAIT;
GO
