#Requires -RunAsAdministrator
<#
.SYNOPSIS
    YouTube Demo Script - Windows Pagefile in Action (Edge Edition)
    VirtualManc | github.com/virtualmanc

.DESCRIPTION
    Opens Microsoft Edge with progressively more tabs to consume memory naturally,
    while monitoring RAM, pagefile usage, and browser responsiveness over time.
    Open Task Manager > Performance > Memory BEFORE running this script.

.NOTES
    Supports all Edge deployment types - system, user, Store, Dev, Beta, Canary.
    Press CTRL+C at any time to stop. Edge will be closed on exit.
#>

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION  ← Tweak these for your VM
# ─────────────────────────────────────────────────────────────────────────────
$PauseBetweenTabs     = 8       # Seconds between opening new tabs
$TabsPerRound         = 2       # How many tabs to open each round
$MaxTabs              = 30      # Safety ceiling on total tabs
$WarnThresholdPct     = 80      # Warn when RAM usage hits this %
$ResponsivenessEvery  = 3       # Check responsiveness every N rounds
# ─────────────────────────────────────────────────────────────────────────────

# Heavy pages that consume real memory (mix of media, maps, docs)
$HeavyUrls = @(
    "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    "https://www.google.com/maps/@51.5074,-0.1278,14z",
    "https://www.bbc.co.uk/news",
    "https://www.office.com",
    "https://web.whatsapp.com",
    "https://outlook.office.com",
    "https://www.reddit.com",
    "https://www.twitch.tv",
    "https://www.canva.com",
    "https://teams.microsoft.com",
    "https://www.figma.com",
    "https://www.notion.so",
    "https://www.linkedin.com",
    "https://github.com",
    "https://www.amazon.co.uk",
    "https://www.bbc.co.uk/weather",
    "https://earth.google.com/web",
    "https://www.spotify.com",
    "https://www.dropbox.com",
    "https://mail.google.com"
)

# ─────────────────────────────────────────────────────────────────────────────
# EDGE DETECTION - Covers all deployment types
# ─────────────────────────────────────────────────────────────────────────────
function Find-EdgePath {
    $candidatePaths = @(
        # Standard system-wide installs (x86 installer on 64-bit OS - most common enterprise)
        "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        # 64-bit system install
        "C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        # Per-user install (non-admin, runs from AppData)
        "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe",
        # Beta channel
        "C:\Program Files (x86)\Microsoft\Edge Beta\Application\msedge.exe",
        "C:\Program Files\Microsoft\Edge Beta\Application\msedge.exe",
        "$env:LOCALAPPDATA\Microsoft\Edge Beta\Application\msedge.exe",
        # Dev channel
        "C:\Program Files (x86)\Microsoft\Edge Dev\Application\msedge.exe",
        "C:\Program Files\Microsoft\Edge Dev\Application\msedge.exe",
        "$env:LOCALAPPDATA\Microsoft\Edge Dev\Application\msedge.exe",
        # Canary channel
        "$env:LOCALAPPDATA\Microsoft\Edge SxS\Application\msedge.exe",
        # Windows Server / LTSC path variant
        "C:\Program Files (x86)\Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe"
    )

    # Check all known static paths first
    foreach ($path in $candidatePaths) {
        if (-not [string]::IsNullOrEmpty($path) -and (Test-Path $path)) {
            return $path
        }
    }

    # Try registry - covers custom enterprise deployment paths
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe"
    )
    foreach ($reg in $regPaths) {
        $regVal = (Get-ItemProperty -Path $reg -ErrorAction SilentlyContinue).'(Default)'
        if (-not [string]::IsNullOrEmpty($regVal) -and (Test-Path $regVal)) {
            return $regVal
        }
    }

    # Try Windows Store / MSIX package (packaged Edge)
    try {
        $storeEdge = Get-AppxPackage -Name "Microsoft.MicrosoftEdge.Stable" -ErrorAction SilentlyContinue |
                     Select-Object -First 1
        if ($storeEdge) {
            $storePath = Join-Path $storeEdge.InstallLocation "msedge.exe"
            if (Test-Path $storePath) { return $storePath }
        }
        # Also try legacy Store Edge name
        $storeEdgeLegacy = Get-AppxPackage -Name "Microsoft.MicrosoftEdge" -ErrorAction SilentlyContinue |
                           Select-Object -First 1
        if ($storeEdgeLegacy) {
            $storePath = Join-Path $storeEdgeLegacy.InstallLocation "msedge.exe"
            if (Test-Path $storePath) { return $storePath }
        }
    }
    catch {}

    # Last resort - search PATH environment variable
    $fromPath = Get-Command "msedge.exe" -ErrorAction SilentlyContinue
    if ($fromPath) { return $fromPath.Source }

    # Nothing found
    return $null
}

# ─────────────────────────────────────────────────────────────────────────────
# HELPER FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────
function Get-MemoryStatus {
    $os        = Get-CimInstance Win32_OperatingSystem
    $totalGB   = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    $freeGB    = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
    $usedGB    = [math]::Round($totalGB - $freeGB, 2)
    $usedPct   = [math]::Round(($usedGB / $totalGB) * 100, 1)
    $pageFile  = Get-CimInstance Win32_PageFileUsage
    $pfCurrMB  = ($pageFile | Measure-Object -Property CurrentUsage -Sum).Sum
    $pfPeakMB  = ($pageFile | Measure-Object -Property PeakUsage -Sum).Sum

    return [PSCustomObject]@{
        TotalGB    = $totalGB
        UsedGB     = $usedGB
        FreeGB     = $freeGB
        UsedPct    = $usedPct
        PagefileMB = $pfCurrMB
        PeakPFMB   = $pfPeakMB
    }
}

function Get-EdgeMemoryMB {
    $edgeProcs = Get-Process -Name "msedge" -ErrorAction SilentlyContinue
    if (-not $edgeProcs) { return 0 }
    $totalMB = ($edgeProcs | Measure-Object -Property WorkingSet64 -Sum).Sum / 1MB
    return [math]::Round($totalMB, 1)
}

function Measure-BrowserResponsiveness {
    param([int]$TabCount)

    Write-Host ""
    Write-Host "  ⏱  Measuring browser responsiveness..." -ForegroundColor Cyan

    $before    = (Get-Date)
    $edgeProcs = Get-Process -Name "msedge" -ErrorAction SilentlyContinue

    if (-not $edgeProcs) {
        Write-Host "  ⚠  Edge not running - skipping responsiveness check" -ForegroundColor Yellow
        return
    }

    $sample1 = $edgeProcs | Select-Object Id, CPU
    Start-Sleep -Milliseconds 1000
    $edgeProcs2 = Get-Process -Name "msedge" -ErrorAction SilentlyContinue
    $sample2 = $edgeProcs2 | Select-Object Id, CPU

    $cpuDelta = 0
    foreach ($s2 in $sample2) {
        $s1match = $sample1 | Where-Object { $_.Id -eq $s2.Id }
        if ($s1match -and $s2.CPU -and $s1match.CPU) {
            $cpuDelta += ($s2.CPU - $s1match.CPU)
        }
    }
    $cpuPct = [math]::Round($cpuDelta, 1)

    $handleCount = ($edgeProcs | Measure-Object -Property Handles -Sum).Sum

    $pfSample1 = (Get-CimInstance Win32_PerfRawData_PerfProc_Process -Filter "Name LIKE 'msedge%'" |
                  Measure-Object -Property PageFaultsPerSec -Sum).Sum
    Start-Sleep -Milliseconds 1000
    $pfSample2 = (Get-CimInstance Win32_PerfRawData_PerfProc_Process -Filter "Name LIKE 'msedge%'" |
                  Measure-Object -Property PageFaultsPerSec -Sum).Sum
    $pageFaults = [math]::Round(($pfSample2 - $pfSample1) / 1, 0)

    $uiStart     = Get-Date
    $edgeWindows = Get-Process -Name "msedge" -ErrorAction SilentlyContinue |
                   Where-Object { $_.MainWindowTitle -ne "" }
    $uiMs        = [math]::Round(((Get-Date) - $uiStart).TotalMilliseconds, 1)

    $rating = "🟢 GOOD"
    $colour = "Green"
    if ($pageFaults -gt 500 -or $cpuPct -gt 50 -or $uiMs -gt 200) {
        $rating = "🟡 DEGRADED"
        $colour = "Yellow"
    }
    if ($pageFaults -gt 2000 -or $cpuPct -gt 150 -or $uiMs -gt 500) {
        $rating = "🔴 POOR - Pagefile thrashing likely!"
        $colour = "Red"
    }

    $elapsed = [math]::Round(((Get-Date) - $before).TotalSeconds, 1)

    Write-Host "  ┌─────────────────────────────────────────┐" -ForegroundColor DarkCyan
    Write-Host "  │  BROWSER RESPONSIVENESS REPORT          │" -ForegroundColor DarkCyan
    Write-Host "  ├─────────────────────────────────────────┤" -ForegroundColor DarkCyan
    Write-Host "  │  Open Tabs          : $($TabCount.ToString().PadRight(18))│" -ForegroundColor White
    Write-Host "  │  Edge Processes     : $($edgeProcs.Count.ToString().PadRight(18))│" -ForegroundColor White
    Write-Host "  │  CPU Usage (1s)     : $("$cpuPct`s".PadRight(18))│" -ForegroundColor White
    Write-Host "  │  Handle Count       : $($handleCount.ToString().PadRight(18))│" -ForegroundColor White
    Write-Host "  │  Page Faults/sec    : $($pageFaults.ToString().PadRight(18))│" -ForegroundColor White
    Write-Host "  │  UI Enum Time       : $("${uiMs}ms".PadRight(18))│" -ForegroundColor White
    Write-Host "  │  Check Duration     : $("${elapsed}s".PadRight(18))│" -ForegroundColor White
    Write-Host "  ├─────────────────────────────────────────┤" -ForegroundColor DarkCyan
    Write-Host "  │  Rating: $($rating.PadRight(32))│" -ForegroundColor $colour
    Write-Host "  └─────────────────────────────────────────┘" -ForegroundColor DarkCyan
    Write-Host ""

    if ($colour -eq "Yellow") {
        Write-Host "  💡 TIP: Open a new tab in Edge now and time how long it takes to load!" -ForegroundColor Yellow
    }
    if ($colour -eq "Red") {
        Write-Host "  💡 TIP: Try scrolling in Edge - notice the stutter? That's pagefile latency!" -ForegroundColor Red
    }
}

function Write-StatusBar {
    param($mem, $round, $tabCount, $edgeMB)

    $filled    = [math]::Round($mem.UsedPct / 5)
    $bar       = ("#" * $filled).PadRight(20, "-")
    $ramColour = if ($mem.UsedPct -ge $WarnThresholdPct) { "Red" } else { "Cyan" }
    $pfColour  = if ($mem.PagefileMB -gt 0) { "Yellow" } else { "Green" }

    Write-Host ""
    Write-Host "  Round       : $round  |  Tabs Open: $tabCount" -ForegroundColor White
    Write-Host "  RAM Total   : $($mem.TotalGB) GB" -ForegroundColor White
    Write-Host "  RAM Used    : $($mem.UsedGB) GB ($($mem.UsedPct)%)" -ForegroundColor $ramColour
    Write-Host "  RAM Free    : $($mem.FreeGB) GB" -ForegroundColor White
    Write-Host "  [RAM $bar] $($mem.UsedPct)%" -ForegroundColor $ramColour
    Write-Host "  Edge RAM    : $edgeMB MB (across all Edge processes)" -ForegroundColor Cyan
    Write-Host "  Pagefile    : $($mem.PagefileMB) MB used  (Peak: $($mem.PeakPFMB) MB)" -ForegroundColor $pfColour
    Write-Host ""
}

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────
Clear-Host
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor DarkCyan
Write-Host "   VirtualManc | Windows Pagefile Demo - Edge Edition" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  Searching for Microsoft Edge..." -ForegroundColor Cyan

$EdgePath = Find-EdgePath

if ([string]::IsNullOrEmpty($EdgePath)) {
    Write-Host "  ✗ Microsoft Edge could not be found on this system." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Searched locations:" -ForegroundColor Yellow
    Write-Host "   - Program Files (x86 and 64-bit)" -ForegroundColor White
    Write-Host "   - AppData (per-user install)" -ForegroundColor White
    Write-Host "   - Beta / Dev / Canary channels" -ForegroundColor White
    Write-Host "   - Registry App Paths" -ForegroundColor White
    Write-Host "   - Windows Store (AppX packages)" -ForegroundColor White
    Write-Host "   - System PATH" -ForegroundColor White
    Write-Host ""
    Write-Host "  Please install Microsoft Edge and re-run the script." -ForegroundColor Yellow
    exit 1
}

Write-Host "  ✓ Edge found: $EdgePath" -ForegroundColor Green

# Detect which channel we found
$channel = switch -Wildcard ($EdgePath) {
    "*Edge SxS*" { "Canary" }
    "*Edge Dev*" { "Dev" }
    "*Edge Beta*" { "Beta" }
    default       { "Stable" }
}
Write-Host "  ✓ Channel: $channel" -ForegroundColor Green
Write-Host ""
Write-Host "  BEFORE YOU PRESS START:" -ForegroundColor Yellow
Write-Host "   1. Open Task Manager > Performance > Memory tab" -ForegroundColor White
Write-Host "   2. Open Resource Monitor > Memory tab" -ForegroundColor White
Write-Host "   3. Close any other heavy apps" -ForegroundColor White
Write-Host "   4. Make sure your VM has 4-8 GB RAM for best effect" -ForegroundColor White
Write-Host ""
Write-Host "  Press any key to launch Edge and begin..." -ForegroundColor Green
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

# ─────────────────────────────────────────────────────────────────────────────
# LAUNCH EDGE
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Launching Edge ($channel)..." -ForegroundColor Cyan

Get-Process -Name "msedge" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

Start-Process -FilePath $EdgePath -ArgumentList "--new-window", $HeavyUrls[0]
Start-Sleep -Seconds 4

$tabCount = 1
$urlIndex = 1
$round    = 0

# ─────────────────────────────────────────────────────────────────────────────
# MAIN LOOP
# ─────────────────────────────────────────────────────────────────────────────
try {
    while ($tabCount -lt $MaxTabs) {
        $round++

        Write-Host "─────────────────────────────────────────────────────────" -ForegroundColor DarkGray

        for ($t = 0; $t -lt $TabsPerRound; $t++) {
            if ($tabCount -ge $MaxTabs) { break }
            if ($urlIndex -ge $HeavyUrls.Count) { $urlIndex = 0 }

            $url = $HeavyUrls[$urlIndex]
            Write-Host "  [Round $round] Opening tab $($tabCount + 1): $url" -ForegroundColor White
            Start-Process -FilePath $EdgePath -ArgumentList "--new-tab", $url
            $urlIndex++
            $tabCount++
            Start-Sleep -Seconds 2
        }

        Write-Host "  Waiting $PauseBetweenTabs seconds for pages to load..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $PauseBetweenTabs

        $mem    = Get-MemoryStatus
        $edgeMB = Get-EdgeMemoryMB
        Write-StatusBar -mem $mem -round $round -tabCount $tabCount -edgeMB $edgeMB

        if ($mem.PagefileMB -gt 0 -and $mem.PagefileMB -lt 200) {
            Write-Host "  *** PAGEFILE KICKING IN - Windows is starting to page Edge! ***" -ForegroundColor Yellow
        }
        elseif ($mem.PagefileMB -ge 200) {
            Write-Host "  *** PAGEFILE HEAVILY USED - Try switching tabs and feel the lag! ***" -ForegroundColor Red
        }

        if ($round % $ResponsivenessEvery -eq 0) {
            Measure-BrowserResponsiveness -TabCount $tabCount
        }

        if ($mem.UsedPct -ge $WarnThresholdPct) {
            Write-Host "  ⚠  RAM above $WarnThresholdPct% - system pressure is HIGH" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "  ✓ Max tab count ($MaxTabs) reached. Holding for final reading..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
    Measure-BrowserResponsiveness -TabCount $tabCount
}
finally {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor DarkCyan
    Write-Host "  Closing Edge and releasing memory..." -ForegroundColor Cyan
    Get-Process -Name "msedge" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    $mem = Get-MemoryStatus
    Write-Host "  Edge closed. RAM now: $($mem.UsedGB) GB ($($mem.UsedPct)%)" -ForegroundColor Green
    Write-Host "  Pagefile usage after close: $($mem.PagefileMB) MB" -ForegroundColor Green
    Write-Host "  (Watch Task Manager - RAM should drop back now!)" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor DarkCyan
    Write-Host ""
}
