<#
.SYNOPSIS
    Run sp_HeapDoctor test suite with parallel execution and database snapshot/backup optimization.

.DESCRIPTION
    Deploys sp_HeapDoctor, creates test data, then runs all test files in parallel
    (default) or sequentially with fast snapshot restore between tests.

    Parallel mode: BACKUP/RESTORE creates isolated database copies per test file,
    then runs all tests concurrently via PowerShell background jobs.

    Sequential mode (-Sequential): Database snapshot enables near-instant state
    reset between test files.

    Both modes eliminate the slow TRUNCATE+INSERT+UPDATE preambles in each test
    file by restoring to a known-good state before each test.

.PARAMETER Container
    Docker container name (default: sqltest)

.PARAMETER Password
    SA password. If omitted, resolved in this order:
      1. $env:HEAPDOCTOR_SQL_PASSWORD (session-scoped environment variable)
      2. BetterCredentials module (Windows Credential Manager, target: sp_HeapDoctor/<Container>)

    Set $env:HEAPDOCTOR_SQL_USER to override the default login 'sa'.

    One-time setup for BetterCredentials:
      Install-Module BetterCredentials
      BetterCredentials\Get-Credential -UserName sa -Target 'sp_HeapDoctor/sqltest' -Store

.PARAMETER Tests
    Specific test numbers to run, e.g., "02","05","09"
    Default: all tests (02, 03, 04, 05, 07, 08, 09, 10, 11)

.PARAMETER Sequential
    Use snapshot-based sequential mode instead of parallel

.PARAMETER SkipDeploy
    Skip deploying sp_HeapDoctor.sql (use existing deployment)

.PARAMETER SkipSetup
    Skip 01_setup_test_data.sql and snapshot/backup creation (reuse existing)

.PARAMETER LogDir
    Directory for log files. Creates timestamped subdirectory.

.PARAMETER JobTimeout
    Timeout in seconds for parallel jobs (default: 600)

.EXAMPLE
    .\Run-AllTests.ps1
    # Full parallel run: deploy, setup, backup, all tests concurrently

.EXAMPLE
    .\Run-AllTests.ps1 -Sequential
    # Sequential run with snapshot restore between tests

.EXAMPLE
    .\Run-AllTests.ps1 -SkipSetup -Tests "07","09"
    # Re-run specific tests using existing backup/snapshot

.EXAMPLE
    .\Run-AllTests.ps1 -Container sqltest2
    # Different container (credential retrieved from vault target 'sp_HeapDoctor/sqltest2')

.EXAMPLE
    # From Git Bash:
    powershell.exe -ExecutionPolicy Bypass -File "tests/Run-AllTests.ps1"
#>

# sqlcmd -P requires plaintext; credential is resolved securely via BetterCredentials or env var
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
[CmdletBinding()]
param(
    [string]$Container = "sqltest",
    [string]$Password,
    [string[]]$Tests,
    [switch]$Sequential,
    [switch]$SkipDeploy,
    [switch]$SkipSetup,
    [string]$LogDir,
    [int]$MaxJobs = 4,
    [int]$JobTimeout = 600
)

$ErrorActionPreference = "Continue"
$script:SqlCmdPath = "/opt/mssql-tools18/bin/sqlcmd"
$script:TotalPass = 0
$script:TotalFail = 0

# Resolve paths
$TestsDir = $PSScriptRoot
$RepoRoot = Split-Path $TestsDir -Parent
$ProcFile = Join-Path $RepoRoot "sp_HeapDoctor.sql"

# Available test files in execution order
$AllTests = [ordered]@{
    "02" = "02_test_planonly.sql"
    "03" = "03_test_execute.sql"
    "04" = "04_test_negative.sql"
    "05" = "05_test_batch6.sql"
    "07" = "07_test_batch7.sql"
    "08" = "08_test_batch8.sql"
    "09" = "09_test_batch9.sql"
    "10" = "10_test_batch10.sql"
    "11" = "11_test_batch11.sql"
    "12" = "12_test_batch12.sql"
}

if (-not $Tests -or $Tests.Count -eq 0) {
    # Default: all tests that exist on disk
    $Tests = @($AllTests.Keys | Where-Object {
        Test-Path (Join-Path $TestsDir $AllTests[$_])
    })
}

# Create log directory if specified
if ($LogDir) {
    $LogDir = Join-Path $LogDir (Get-Date -Format "yyyyMMdd_HHmmss")
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

#region Helper Functions

function Invoke-SqlQuery {
    param(
        [Parameter(Mandatory)]
        [string]$Query,
        [string]$Database = "master"
    )
    $output = docker exec $Container $script:SqlCmdPath `
        -S localhost -U $script:SqlUser -P $Password -C `
        -d $Database -W -Q $Query 2>&1
    return $output
}

function Invoke-SqlFile {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [string]$Database = "master",
        [switch]$StopOnError
    )
    $fileName = Split-Path $FilePath -Leaf
    $tempPath = Join-Path $env:TEMP $fileName

    # Copy to temp first (avoids Google Drive path issues with docker cp)
    Copy-Item -LiteralPath $FilePath -Destination $tempPath -Force
    docker cp $tempPath "${Container}:/tmp/$fileName" 2>&1 | Out-Null

    if ($StopOnError) {
        $output = docker exec $Container $script:SqlCmdPath `
            -S localhost -U $script:SqlUser -P $Password -C `
            -d $Database -i "/tmp/$fileName" -W -b 2>&1
    }
    else {
        $output = docker exec $Container $script:SqlCmdPath `
            -S localhost -U $script:SqlUser -P $Password -C `
            -d $Database -i "/tmp/$fileName" -W 2>&1
    }
    return $output
}

function Format-Duration {
    param([double]$Seconds)
    if ($Seconds -ge 60) {
        return "{0}m {1:N0}s" -f [math]::Floor($Seconds / 60), ($Seconds % 60)
    }
    return "{0:N1}s" -f $Seconds
}

function Write-StepResult {
    param(
        [string]$Message,
        [string]$Result,
        [double]$Seconds,
        [ConsoleColor]$Color = [ConsoleColor]::Green
    )
    $padded = $Message.PadRight(52)
    $duration = if ($Seconds -gt 0) { " ($(Format-Duration $Seconds))" } else { "" }
    Write-Host "  $padded" -NoNewline
    Write-Host "$Result$duration" -ForegroundColor $Color
}

#endregion

#region Preflight Check

# Verify container is running
$containerCheck = docker inspect -f '{{.State.Running}}' $Container 2>&1
if ($containerCheck -ne 'true') {
    Write-Host "ERROR: Container '$Container' is not running." -ForegroundColor Red
    Write-Host "  Start it with: docker start $Container" -ForegroundColor Yellow
    exit 1
}

#endregion

#region Credential Resolution

function Resolve-SqlPassword {
    param(
        [string]$ExplicitPassword,
        [string]$ContainerName
    )

    # Priority 1: -Password parameter (explicit override)
    if ($ExplicitPassword) { return $ExplicitPassword }

    # Priority 2: Environment variables (session-scoped, CI-friendly)
    if ($env:HEAPDOCTOR_SQL_PASSWORD) {
        return $env:HEAPDOCTOR_SQL_PASSWORD
    }

    # Priority 3: BetterCredentials module (Windows Credential Manager)
    $credTarget = "sp_HeapDoctor/$ContainerName"
    $bcModule = Get-Module -ListAvailable -Name BetterCredentials
    if ($bcModule) {
        Import-Module BetterCredentials -ErrorAction SilentlyContinue
        try {
            $cred = BetterCredentials\Find-Credential -Filter $credTarget
            if ($cred) {
                $script:SqlUser = $cred.UserName
                return $cred.GetNetworkCredential().Password
            }
        } catch {
            # Credential not found in vault - fall through to error
        }
    }

    # No credential found - show all three options
    Write-Host "ERROR: No SQL credential found." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Option 1: Environment variables (session-scoped)" -ForegroundColor Yellow
    Write-Host "    `$env:HEAPDOCTOR_SQL_USER = 'sa'" -ForegroundColor Gray
    Write-Host "    `$env:HEAPDOCTOR_SQL_PASSWORD = 'YourPassword'" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Option 2: BetterCredentials (Windows Credential Manager)" -ForegroundColor Yellow
    if (-not $bcModule) {
        Write-Host "    Install-Module BetterCredentials" -ForegroundColor Gray
    }
    Write-Host "    BetterCredentials\Get-Credential -UserName sa -Target '$credTarget' -Store" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Option 3: Pass directly" -ForegroundColor Yellow
    Write-Host "    .\Run-AllTests.ps1 -Password 'YourPassword'" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

$script:SqlUser = if ($env:HEAPDOCTOR_SQL_USER) { $env:HEAPDOCTOR_SQL_USER } else { "sa" }
$Password = Resolve-SqlPassword -ExplicitPassword $Password -ContainerName $Container
# Note: Resolve-SqlPassword may update $script:SqlUser from the vault credential

#endregion

#region Main Execution

$suiteStart = Get-Date
$mode = if ($Sequential) { "SEQUENTIAL (snapshot)" } else { "PARALLEL (backup/restore)" }

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " sp_HeapDoctor Test Runner" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Container:  $Container"
Write-Host "  Mode:       $mode"
Write-Host "  Tests:      $($Tests -join ', ')"
if ($LogDir) { Write-Host "  Log dir:    $LogDir" }
Write-Host ""

# --- Deploy ---
if (-not $SkipDeploy) {
    $stepStart = Get-Date
    Write-Host "  Deploying sp_HeapDoctor..." -NoNewline
    $deployOutput = Invoke-SqlFile -FilePath $ProcFile -Database master -StopOnError
    if ($LASTEXITCODE -ne 0) {
        Write-Host " FAILED" -ForegroundColor Red
        $deployOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        exit 1
    }
    Invoke-SqlQuery "EXEC sp_MS_marksystemobject 'sp_HeapDoctor'" | Out-Null
    $elapsed = ((Get-Date) - $stepStart).TotalSeconds
    Write-Host " OK ($(Format-Duration $elapsed))" -ForegroundColor Green
}

# --- Setup ---
if (-not $SkipSetup) {
    $stepStart = Get-Date
    Write-Host "  Running 01_setup_test_data.sql..." -NoNewline
    $setupOutput = Invoke-SqlFile -FilePath (Join-Path $TestsDir "01_setup_test_data.sql") -Database master
    $elapsed = ((Get-Date) - $stepStart).TotalSeconds
    Write-Host " OK ($(Format-Duration $elapsed))" -ForegroundColor Green

    if ($Sequential) {
        # Create snapshot for sequential mode
        $stepStart = Get-Date
        Write-Host "  Creating database snapshot..." -NoNewline
        $snapshotSql = @"
IF DB_ID('HeapDoctorTest_Snapshot') IS NOT NULL
BEGIN
    ALTER DATABASE HeapDoctorTest_Snapshot SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE HeapDoctorTest_Snapshot;
END
DECLARE @name sysname, @sql nvarchar(max);
SELECT @name = name FROM sys.master_files
WHERE database_id = DB_ID('HeapDoctorTest') AND type_desc = 'ROWS';
SET @sql = N'CREATE DATABASE HeapDoctorTest_Snapshot ON (NAME = '
    + QUOTENAME(@name) + N', FILENAME = ''/var/opt/mssql/data/HeapDoctorTest_Snap.ss'')'
    + N' AS SNAPSHOT OF HeapDoctorTest';
EXEC sp_executesql @sql;
"@
        Invoke-SqlQuery $snapshotSql | Out-Null
        $elapsed = ((Get-Date) - $stepStart).TotalSeconds
        Write-Host " OK ($(Format-Duration $elapsed))" -ForegroundColor Green
    }
    else {
        # Create backup for parallel mode
        $stepStart = Get-Date
        Write-Host "  Creating database backup..." -NoNewline
        $backupSql = "BACKUP DATABASE HeapDoctorTest TO DISK = '/var/opt/mssql/data/HeapDoctorTest.bak' WITH INIT, COMPRESSION;"
        Invoke-SqlQuery $backupSql | Out-Null
        $elapsed = ((Get-Date) - $stepStart).TotalSeconds
        Write-Host " OK ($(Format-Duration $elapsed))" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "--- Running Tests ($mode) ---" -ForegroundColor Yellow
Write-Host ""

# ============================================================
# SEQUENTIAL MODE (snapshot-based)
# ============================================================
if ($Sequential) {
    foreach ($testNum in $Tests) {
        $testFile = $AllTests[$testNum]
        if (-not $testFile) {
            Write-Host "  [$testNum] Unknown test number, skipping." -ForegroundColor Yellow
            continue
        }
        if (-not (Test-Path (Join-Path $TestsDir $testFile))) {
            Write-Host "  [$testNum] File $testFile not found, skipping." -ForegroundColor Yellow
            continue
        }

        # Restore snapshot
        $stepStart = Get-Date
        Write-Host "  [$testNum] Restoring snapshot..." -NoNewline
        $restoreSql = @"
USE master;
ALTER DATABASE HeapDoctorTest SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
RESTORE DATABASE HeapDoctorTest FROM DATABASE_SNAPSHOT = 'HeapDoctorTest_Snapshot';
ALTER DATABASE HeapDoctorTest SET MULTI_USER;
"@
        $restoreOutput = Invoke-SqlQuery $restoreSql
        $elapsed = ((Get-Date) - $stepStart).TotalSeconds
        if ($LASTEXITCODE -ne 0) {
            Write-Host " FAILED" -ForegroundColor Red
            $restoreOutput | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
            continue
        }
        Write-Host " OK ($(Format-Duration $elapsed))" -ForegroundColor Green

        # Run test
        $stepStart = Get-Date
        Write-Host "  [$testNum] Running $testFile..." -NoNewline
        $testOutput = Invoke-SqlFile -FilePath (Join-Path $TestsDir $testFile) -Database HeapDoctorTest
        $elapsed = ((Get-Date) - $stepStart).TotalSeconds

        # Save log if requested
        if ($LogDir) {
            $testOutput | Out-File (Join-Path $LogDir "${testNum}_output.log") -Encoding UTF8
        }

        # Parse PASS/FAIL
        $passLines = @($testOutput | Select-String "^\s*(\*+\s+)?(PASS: |PASS \d)")
        $failLines = @($testOutput | Select-String "^\s*(\*+\s+)?(FAIL: |FAIL \d)")
        $passCount = $passLines.Count
        $failCount = $failLines.Count
        $script:TotalPass += $passCount
        $script:TotalFail += $failCount

        if ($failCount -gt 0) {
            Write-Host " $passCount PASS  $failCount FAIL ($(Format-Duration $elapsed))" -ForegroundColor Red
            $failLines | ForEach-Object { Write-Host "      $($_.Line.Trim())" -ForegroundColor Red }
        }
        else {
            Write-Host " $passCount PASS  0 FAIL ($(Format-Duration $elapsed))" -ForegroundColor Green
        }
        Write-Host ""
    }

    # Cleanup snapshot
    Write-Host "  Cleaning up snapshot..." -NoNewline
    Invoke-SqlQuery "IF DB_ID('HeapDoctorTest_Snapshot') IS NOT NULL BEGIN DROP DATABASE HeapDoctorTest_Snapshot; END" | Out-Null
    Write-Host " OK" -ForegroundColor Green
}
# ============================================================
# PARALLEL MODE (backup/restore + concurrent jobs)
# ============================================================
else {
    # Validate test files exist
    $validTests = @()
    foreach ($testNum in $Tests) {
        $testFile = $AllTests[$testNum]
        if (-not $testFile) {
            Write-Host "  [$testNum] Unknown test number, skipping." -ForegroundColor Yellow
            continue
        }
        if (-not (Test-Path (Join-Path $TestsDir $testFile))) {
            Write-Host "  [$testNum] File $testFile not found, skipping." -ForegroundColor Yellow
            continue
        }
        $validTests += $testNum
    }

    # Prepare test files (copy to temp with database name replacement)
    Write-Host "  Preparing $($validTests.Count) test files for parallel execution..." -ForegroundColor Gray
    foreach ($testNum in $validTests) {
        $testFile = $AllTests[$testNum]
        $dbName = "HeapDoctorTest_$testNum"
        $testFilePath = Join-Path $TestsDir $testFile
        $content = Get-Content -LiteralPath $testFilePath -Raw
        $content = $content -replace 'HeapDoctorTest', $dbName
        $tempFileName = "heaptest_${testNum}.sql"
        $tempPath = Join-Path $env:TEMP $tempFileName
        $content | Set-Content -LiteralPath $tempPath -Encoding UTF8
        docker cp $tempPath "${Container}:/tmp/$tempFileName" 2>&1 | Out-Null
    }

    # Launch parallel jobs in batches of $MaxJobs
    $allJobs = @()
    $batches = @()
    for ($i = 0; $i -lt $validTests.Count; $i += $MaxJobs) {
        $batches += ,@($validTests[$i..([math]::Min($i + $MaxJobs - 1, $validTests.Count - 1))])
    }

    $batchNum = 0
    foreach ($batch in $batches) {
        $batchNum++
        if ($batches.Count -gt 1) {
            Write-Host "  Batch $batchNum of $($batches.Count) ($($batch.Count) tests)..." -ForegroundColor Gray
        }

        $jobs = @()
        foreach ($testNum in $batch) {
            $testFile = $AllTests[$testNum]
            $dbName = "HeapDoctorTest_$testNum"
            $tempFileName = "heaptest_${testNum}.sql"

            $jobs += Start-Job -Name "Test_$testNum" -ScriptBlock {
                param($Container, $Password, $SqlUser, $SqlCmdPath, $TestNum, $TestFile, $DbName, $TempFileName)

                $sw = [System.Diagnostics.Stopwatch]::StartNew()

                try {
                    # 1. Restore database from backup
                    $restoreSql = @"
RESTORE DATABASE [$DbName] FROM DISK = '/var/opt/mssql/data/HeapDoctorTest.bak'
WITH MOVE 'HeapDoctorTest' TO '/var/opt/mssql/data/${DbName}.mdf',
     MOVE 'HeapDoctorTest_log' TO '/var/opt/mssql/data/${DbName}_log.ldf',
     REPLACE;
"@
                    $restoreOut = docker exec $Container $SqlCmdPath `
                        -S localhost -U $SqlUser -P $Password -C `
                        -d master -Q $restoreSql -W 2>&1

                    if ($LASTEXITCODE -ne 0) {
                        throw "Restore failed: $($restoreOut -join ' ')"
                    }

                    # 2. Run test (file already copied to container)
                    $output = docker exec $Container $SqlCmdPath `
                        -S localhost -U $SqlUser -P $Password -C `
                        -d $DbName -i "/tmp/$TempFileName" -W 2>&1

                    $sw.Stop()

                    # 3. Parse results
                    $passLines = @($output | Select-String "^\s*(\*+\s+)?(PASS: |PASS \d)")
                    $failLines = @($output | Select-String "^\s*(\*+\s+)?(FAIL: |FAIL \d)")

                    [PSCustomObject]@{
                        TestNum     = $TestNum
                        TestFile    = $TestFile
                        PassCount   = $passLines.Count
                        FailCount   = $failLines.Count
                        FailDetails = @($failLines | ForEach-Object { $_.Line.Trim() })
                        Duration    = $sw.Elapsed.TotalSeconds
                        Output      = ($output -join "`n")
                        Error       = $null
                    }
                }
                catch {
                    $sw.Stop()
                    [PSCustomObject]@{
                        TestNum     = $TestNum
                        TestFile    = $TestFile
                        PassCount   = 0
                        FailCount   = 0
                        FailDetails = @()
                        Duration    = $sw.Elapsed.TotalSeconds
                        Output      = ""
                        Error       = $_.Exception.Message
                    }
                }
            } -ArgumentList @($Container, $Password, $script:SqlUser, $script:SqlCmdPath, $testNum, $testFile, $dbName, $tempFileName)
        }

        Write-Host "  Launched $($jobs.Count) parallel jobs. Waiting..." -ForegroundColor Gray

        # Wait for batch to complete
        $completedJobs = $jobs | Wait-Job -Timeout $JobTimeout

        # Check for timed-out jobs
        $timedOut = $jobs | Where-Object { $_.State -eq 'Running' }
        if ($timedOut) {
            $timedOut | Stop-Job
            Write-Host "  WARNING: $($timedOut.Count) jobs timed out after ${JobTimeout}s" -ForegroundColor Yellow
        }

        # Collect and display results
        $results = $jobs | Receive-Job

        foreach ($result in $results | Sort-Object TestNum) {
            if ($result.Error) {
                Write-Host "  [$($result.TestNum)] ERROR ($([math]::Round($result.Duration, 1))s)" -ForegroundColor Red
                Write-Host "      $($result.Error)" -ForegroundColor Red
                $script:TotalFail += 1
            }
            elseif ($result.FailCount -gt 0) {
                Write-Host "  [$($result.TestNum)] $($result.PassCount) PASS  $($result.FailCount) FAIL ($(Format-Duration $result.Duration))" -ForegroundColor Red
                foreach ($detail in $result.FailDetails) {
                    Write-Host "      $detail" -ForegroundColor Red
                }
                $script:TotalPass += $result.PassCount
                $script:TotalFail += $result.FailCount
            }
            else {
                Write-Host "  [$($result.TestNum)] $($result.PassCount) PASS  0 FAIL ($(Format-Duration $result.Duration))" -ForegroundColor Green
                $script:TotalPass += $result.PassCount
            }

            # Save log if requested
            if ($LogDir -and $result.Output) {
                $result.Output | Out-File (Join-Path $LogDir "$($result.TestNum)_output.log") -Encoding UTF8
            }
        }

        # Clean up batch jobs
        $jobs | Remove-Job -Force
        Write-Host ""
    }

    # Clean up parallel databases
    Write-Host ""
    Write-Host "  Cleaning up parallel databases..." -NoNewline
    foreach ($testNum in $validTests) {
        $dbName = "HeapDoctorTest_$testNum"
        Invoke-SqlQuery "IF DB_ID('$dbName') IS NOT NULL BEGIN ALTER DATABASE [$dbName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$dbName]; END" | Out-Null
    }
    # Remove backup file
    docker exec $Container rm -f /var/opt/mssql/data/HeapDoctorTest.bak 2>&1 | Out-Null
    Write-Host " OK" -ForegroundColor Green
}

#endregion

#region Summary

$suiteElapsed = ((Get-Date) - $suiteStart).TotalSeconds
$summaryColor = if ($script:TotalFail -gt 0) { [ConsoleColor]::Red } else { [ConsoleColor]::Green }

Write-Host ""
Write-Host "================================================================" -ForegroundColor $summaryColor
Write-Host (" TOTAL: {0} PASSED  {1} FAILED  ({2})" -f $script:TotalPass, $script:TotalFail, (Format-Duration $suiteElapsed)) -ForegroundColor $summaryColor
Write-Host "================================================================" -ForegroundColor $summaryColor
Write-Host ""

if ($LogDir) {
    @"
sp_HeapDoctor Test Results
Date:      $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Mode:      $mode
Container: $Container
Total:     $($script:TotalPass) PASSED  $($script:TotalFail) FAILED
Time:      $(Format-Duration $suiteElapsed)
"@ | Out-File (Join-Path $LogDir "00_SUMMARY.txt") -Encoding UTF8
    Write-Host "  Logs saved to: $LogDir" -ForegroundColor Gray
}

if ($script:TotalFail -gt 0) { exit 1 } else { exit 0 }

#endregion
