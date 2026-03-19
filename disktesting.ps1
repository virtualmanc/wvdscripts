#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Runs a series of DiskSpd benchmark tests and outputs results to CSV.

.DESCRIPTION
    Runs a comprehensive set of DiskSpd tests covering random IOPS, sequential
    throughput, mixed workloads, and queue depth scaling. Results are saved to
    a CSV for easy comparison across VM generations (e.g. v6 vs v7).

.PARAMETER TestDrive
    Drive letter / path to test. Defaults to C:\

.PARAMETER DiskSpdPath
    Full path to diskspd.exe. Defaults to C:\DiskSpd\diskspd.exe

.PARAMETER OutputPath
    Folder to save results. Defaults to C:\DiskSpdResults\

.PARAMETER WarmupSeconds
    Warmup duration before each test in seconds. Defaults to 60.
    Use 300 for more accurate results (5 min warmup).

.PARAMETER DurationSeconds
    Test duration in seconds. Defaults to 60.

.PARAMETER SkipTestFileCreation
    Skip recreating the test file if it already exists.

.EXAMPLE
    .\Invoke-DiskSpdBenchmark.ps1 -TestDrive "D:\" -WarmupSeconds 300

.EXAMPLE
    .\Invoke-DiskSpdBenchmark.ps1 -TestDrive "C:\" -DiskSpdPath "C:\Tools\diskspd.exe" -OutputPath "C:\Results\"

.NOTES
    Requires DiskSpd.exe - download from https://github.com/microsoft/diskspd/releases
    Run as Administrator.
    For accurate results, ensure no other significant disk activity during tests.
#>

[CmdletBinding()]
param (
    [string]$TestDrive      = "C:\",
    [string]$DiskSpdPath    = "C:\DiskSpd\diskspd.exe",
    [string]$OutputPath     = "C:\DiskSpdResults\",
    [int]$WarmupSeconds     = 60,
    [int]$DurationSeconds   = 60,
    [switch]$SkipTestFileCreation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region --- Helpers -----------------------------------------------------------

function Write-Banner {
    param([string]$Message)
    $line = "=" * 60
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Message)
    Write-Host "[*] $Message" -ForegroundColor Yellow
}

function Write-OK {
    param([string]$Message)
    Write-Host "[+] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[!] $Message" -ForegroundColor Red
}

# Parse a DiskSpd output text block and return a PSCustomObject with key metrics
function Parse-DiskSpdOutput {
    param(
        [string]$RawOutput,
        [string]$TestName
    )

    $result = [PSCustomObject]@{
        TestName        = $TestName
        IOPS            = $null
        ThroughputMBs   = $null
        AvgLatencyMs    = $null
        P99LatencyMs    = $null
        P999LatencyMs   = $null
        ThreadCount     = $null
        QueueDepth      = $null
        BlockSizeKB     = $null
        WritePercent    = $null
        DurationSec     = $null
        TotalIOCount    = $null
    }

    try {
        # Total IOPS - from the "total" summary line
        if ($RawOutput -match "total:\s+[\d.]+\s+\|\s+[\d.]+\s+\|\s+([\d.]+)\s+\|\s+([\d.]+)") {
            $result.ThroughputMBs = [math]::Round([double]$Matches[1], 2)
            $result.IOPS          = [math]::Round([double]$Matches[2], 0)
        }

        # Average latency from the latency summary section
        if ($RawOutput -match "avg\.\s*:\s*([\d.]+)") {
            $result.AvgLatencyMs = [math]::Round([double]$Matches[1], 3)
        }

        # Percentile latencies
        if ($RawOutput -match "99th\s*:\s*([\d.]+)") {
            $result.P99LatencyMs = [math]::Round([double]$Matches[1], 3)
        }
        if ($RawOutput -match "99\.9th\s*:\s*([\d.]+)") {
            $result.P999LatencyMs = [math]::Round([double]$Matches[1], 3)
        }

        # Test parameters from the command line echo in output
        if ($RawOutput -match "-t(\d+)") { $result.ThreadCount  = $Matches[1] }
        if ($RawOutput -match "-o(\d+)") { $result.QueueDepth   = $Matches[1] }
        if ($RawOutput -match "-b(\d+[KkMmGg]?)") {
            $raw = $Matches[1]
            if ($raw -match "(\d+)[Kk]") { $result.BlockSizeKB = $Matches[1] }
            elseif ($raw -match "(\d+)[Mm]") { $result.BlockSizeKB = [int]$Matches[1] * 1024 }
            else { $result.BlockSizeKB = $raw }
        }
        if ($RawOutput -match "-w(\d+)") { $result.WritePercent = $Matches[1] }
        else { $result.WritePercent = 0 }

        if ($RawOutput -match "-d(\d+)") { $result.DurationSec = $Matches[1] }

        # Total I/O count
        if ($RawOutput -match "I/Os\s*:\s*([\d,]+)") {
            $result.TotalIOCount = ($Matches[1] -replace ",", "")
        }
    }
    catch {
        Write-Fail "Warning: Could not fully parse output for '$TestName': $_"
    }

    return $result
}

#endregion

#region --- Preflight Checks --------------------------------------------------

Write-Banner "DiskSpd Benchmark Suite — Azure VM Disk Testing"
Write-Host "  VM Hostname  : $env:COMPUTERNAME"
Write-Host "  Test Drive   : $TestDrive"
Write-Host "  Warmup       : $WarmupSeconds seconds"
Write-Host "  Duration     : $DurationSeconds seconds"
Write-Host "  Output Path  : $OutputPath"

# Check DiskSpd exists
if (-not (Test-Path $DiskSpdPath)) {
    Write-Fail "diskspd.exe not found at: $DiskSpdPath"
    Write-Host ""
    Write-Host "Download DiskSpd from:" -ForegroundColor Yellow
    Write-Host "  https://github.com/microsoft/diskspd/releases" -ForegroundColor Yellow
    Write-Host "Extract diskspd.exe to: $([System.IO.Path]::GetDirectoryName($DiskSpdPath))" -ForegroundColor Yellow
    exit 1
}
Write-OK "DiskSpd found: $DiskSpdPath"

# Check test drive exists
if (-not (Test-Path $TestDrive)) {
    Write-Fail "Test drive path not found: $TestDrive"
    exit 1
}

# Create output folder
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    Write-OK "Created output folder: $OutputPath"
}

# Check available disk space (need at least 25GB for test file)
$drive     = Split-Path $TestDrive -Qualifier
$diskInfo  = Get-PSDrive ($drive.TrimEnd(":")) -ErrorAction SilentlyContinue
if ($diskInfo) {
    $freeGB = [math]::Round($diskInfo.Free / 1GB, 1)
    if ($freeGB -lt 22) {
        Write-Fail "Insufficient free space on $drive (${freeGB}GB free, need ~22GB for test file)"
        exit 1
    }
    Write-OK "Disk space OK: ${freeGB}GB free on $drive"
}

#endregion

#region --- Test File ---------------------------------------------------------

$testFile = Join-Path $TestDrive "diskspd_testfile.dat"

if (-not $SkipTestFileCreation) {
    Write-Step "Creating 20GB test file at $testFile (this may take a few minutes)..."
    # Let DiskSpd create/recreate the file as part of the first test run
    # -c flag handles this automatically — we pass it in every command
} else {
    if (Test-Path $testFile) {
        Write-OK "Using existing test file: $testFile"
    } else {
        Write-Fail "-SkipTestFileCreation specified but no test file found at $testFile"
        exit 1
    }
}

#endregion

#region --- Test Definitions --------------------------------------------------

# Each test: Name, Description, and the DiskSpd arguments (excluding file path)
# -c20G  : 20GB test file
# -Sh    : bypass software + hardware cache
# -L     : capture latency stats
# -W     : warmup seconds
# -d     : duration seconds

$baseFlags = "-c20G -Sh -L -W$WarmupSeconds -d$DurationSeconds"

$tests = @(
    @{
        Name        = "Random_4K_Read_100pct"
        Description = "Random 4K 100% Read — peak IOPS baseline"
        Args        = "$baseFlags -b4K -r -t4 -o32 -w0"
    },
    @{
        Name        = "Random_4K_Write_100pct"
        Description = "Random 4K 100% Write — peak write IOPS"
        Args        = "$baseFlags -b4K -r -t4 -o32 -w100"
    },
    @{
        Name        = "Random_8K_Mixed_70R30W"
        Description = "Random 8K 70% Read / 30% Write — AVD realistic workload"
        Args        = "$baseFlags -b8K -r -t4 -o32 -w30"
    },
    @{
        Name        = "Sequential_64K_Read"
        Description = "Sequential 64K Read — throughput test (FSLogix / large files)"
        Args        = "$baseFlags -b64K -si -t4 -o32 -w0"
    },
    @{
        Name        = "Sequential_64K_Write"
        Description = "Sequential 64K Write — throughput test"
        Args        = "$baseFlags -b64K -si -t4 -o32 -w100"
    },
    @{
        Name        = "QueueDepth_4K_QD8"
        Description = "Queue Depth Scaling — 4K Read QD8"
        Args        = "$baseFlags -b4K -r -t4 -o8 -w0"
    },
    @{
        Name        = "QueueDepth_4K_QD32"
        Description = "Queue Depth Scaling — 4K Read QD32"
        Args        = "$baseFlags -b4K -r -t4 -o32 -w0"
    },
    @{
        Name        = "QueueDepth_4K_QD64"
        Description = "Queue Depth Scaling — 4K Read QD64"
        Args        = "$baseFlags -b4K -r -t4 -o64 -w0"
    },
    @{
        Name        = "QueueDepth_4K_QD128"
        Description = "Queue Depth Scaling — 4K Read QD128"
        Args        = "$baseFlags -b4K -r -t4 -o128 -w0"
    }
)

#endregion

#region --- Run Tests ---------------------------------------------------------

$allResults   = @()
$timestamp    = Get-Date -Format "yyyyMMdd_HHmmss"
$rawOutputDir = Join-Path $OutputPath "RawOutput_$timestamp"
New-Item -ItemType Directory -Path $rawOutputDir -Force | Out-Null

$totalTests = $tests.Count
$testNum    = 0

foreach ($test in $tests) {
    $testNum++
    Write-Banner "Test $testNum of $totalTests : $($test.Description)"

    $rawFile  = Join-Path $rawOutputDir "$($test.Name).txt"
    $fullCmd  = "$($test.Args) `"$testFile`""

    Write-Step "Running: diskspd $fullCmd"
    Write-Step "Warmup: ${WarmupSeconds}s | Duration: ${DurationSeconds}s — please wait..."

    try {
        $startTime  = Get-Date
        $rawOutput  = & $DiskSpdPath $($test.Args -split " ") "$testFile" 2>&1
        $elapsed    = ((Get-Date) - $startTime).TotalSeconds

        # Save raw output
        $rawOutput | Out-File -FilePath $rawFile -Encoding UTF8
        Write-OK "Raw output saved: $rawFile"

        # Parse results
        $parsed = Parse-DiskSpdOutput -RawOutput ($rawOutput -join "`n") -TestName $test.Name
        $parsed | Add-Member -NotePropertyName "Description" -NotePropertyValue $test.Description
        $parsed | Add-Member -NotePropertyName "Hostname"    -NotePropertyValue $env:COMPUTERNAME
        $parsed | Add-Member -NotePropertyName "Timestamp"   -NotePropertyValue (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        $parsed | Add-Member -NotePropertyName "ElapsedSec"  -NotePropertyValue ([math]::Round($elapsed, 1))

        $allResults += $parsed

        # Print quick summary to console
        Write-OK "IOPS         : $($parsed.IOPS)"
        Write-OK "Throughput   : $($parsed.ThroughputMBs) MB/s"
        Write-OK "Avg Latency  : $($parsed.AvgLatencyMs) ms"
        Write-OK "P99 Latency  : $($parsed.P99LatencyMs) ms"
    }
    catch {
        Write-Fail "Test '$($test.Name)' failed: $_"
        $allResults += [PSCustomObject]@{
            TestName      = $test.Name
            Description   = $test.Description
            Hostname      = $env:COMPUTERNAME
            Timestamp     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            IOPS          = "ERROR"
            ThroughputMBs = "ERROR"
            AvgLatencyMs  = "ERROR"
            P99LatencyMs  = "ERROR"
            P999LatencyMs = "ERROR"
            Error         = $_.Exception.Message
        }
    }
}

#endregion

#region --- Output Results ----------------------------------------------------

Write-Banner "Saving Results"

# CSV output
$csvPath = Join-Path $OutputPath "DiskSpd_Results_$($env:COMPUTERNAME)_$timestamp.csv"
$allResults | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-OK "CSV saved: $csvPath"

# Console summary table
Write-Banner "Results Summary — $env:COMPUTERNAME"
$allResults | Format-Table TestName, IOPS, ThroughputMBs, AvgLatencyMs, P99LatencyMs -AutoSize

Write-Host ""
Write-Host "All done! To compare v6 vs v7:" -ForegroundColor Cyan
Write-Host "  1. Run this script on your v6 host and save the CSV" -ForegroundColor White
Write-Host "  2. Run this script on your v7 host and save the CSV" -ForegroundColor White
Write-Host "  3. Merge both CSVs in Excel and compare the Hostname rows" -ForegroundColor White
Write-Host ""
Write-Host "Raw DiskSpd output files saved to: $rawOutputDir" -ForegroundColor Gray

#endregion
