# WindowsTweaker - PowerShell versus Go worker benchmark.
#
# Measures the same read-only workload with both backends, under the same conditions, and
# writes every raw sample to JSON so the numbers can be checked instead of trusted.
#
# What is measured:
#   * the directory scan itself (same tree, same file count and sizes);
#   * worker startup and handshake, separately from the scan;
#   * protocol round-trip overhead (trivial requests), separately from the scan;
#   * elapsed time, CPU time and peak working set of the process that did the work.
#
# What is *not* measured, and never claimed: page-cache control. Evicting the cache needs
# root, so "cold" here means "the tree was just re-created and the run happens in a fresh
# process", and "warm" means "the following runs in the same process". Both are reported as
# what they are.
#
# Usage:
#   pwsh -NoProfile -File tools/Measure-WtWorker.ps1
#   pwsh -NoProfile -File tools/Measure-WtWorker.ps1 -Files 5000 -Runs 5 -Backends Both
#   pwsh -NoProfile -File tools/Measure-WtWorker.ps1 -OneShot -Backend Go -Path <tree>

[CmdletBinding()]
param
(
    [Parameter(Mandatory = $false)][ValidateSet('Both', 'PowerShell', 'Go')][string]$Backends = 'Both',
    [Parameter(Mandatory = $false)][int]$Files = 2000,
    [Parameter(Mandatory = $false)][int]$Directories = 40,
    [Parameter(Mandatory = $false)][int]$Runs = 3,
    [Parameter(Mandatory = $false)][string]$Path,
    [Parameter(Mandatory = $false)][string]$Out = '',
    [Parameter(Mandatory = $false)][switch]$OneShot,
    [Parameter(Mandatory = $false)][ValidateSet('Both', 'PowerShell', 'Go')][string]$Backend = 'Both'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Path $PSScriptRoot -Parent
$Manifest = Join-Path $Root 'src/WindowsTweaker/WindowsTweaker.psd1'
Import-Module $Manifest -Force

$Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-bench-{0}" -f ([guid]::NewGuid().ToString('n')))
$DataRoot = Join-Path $Sandbox 'data'
$env:WT_DATA_ROOT = $DataRoot
$env:WT_STATE_PATH = Join-Path $DataRoot 'state.json'
$env:WT_LOG_DIRECTORY = Join-Path $DataRoot 'logs'
$env:WT_SETTINGS_PATH = Join-Path $DataRoot 'settings.json'
$env:WT_LANG = 'en'

<#
.SYNOPSIS
    Creates a deterministic tree: Files files spread over Directories directories, each file
    with a known size, plus one symlink and one hard link, so both backends see the same
    workload and the aggregation can be checked by hand.
#>
function New-WtBenchmarkTree
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Base,
        [Parameter(Mandatory = $true)][int]$FileCount,
        [Parameter(Mandatory = $true)][int]$DirectoryCount
    )

    if (Test-Path -LiteralPath $Base) { Remove-Item -LiteralPath $Base -Recurse -Force }
    New-Item -ItemType Directory -Path $Base -Force | Out-Null

    $Flat = [System.Collections.Generic.List[object]]::new()
    for ($Index = 0; $Index -lt $DirectoryCount; $Index++)
    {
        $Directory = Join-Path $Base ("dir{0:d3}" -f $Index)
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
        $Flat.Add($Directory)
    }

    for ($Index = 0; $Index -lt $FileCount; $Index++)
    {
        $Directory = $Flat[$Index % $Flat.Count]
        $Name = if ($Index % 17 -eq 0) { "tệp-{0:d5}.bin" -f $Index } else { "f{0:d5}.bin" -f $Index }
        $Size = 512 + (($Index % 11) * 1024)
        $File = Join-Path $Directory $Name
        $Bytes = [byte[]]::new($Size)
        [System.IO.File]::WriteAllBytes($File, $Bytes)
    }

    # One symlink (must be skipped) and one hard link (must not be double counted).
    try { New-Item -ItemType SymbolicLink -Path (Join-Path $Base 'link-outside') -Target ([System.IO.Path]::GetTempPath()) -ErrorAction Stop | Out-Null } catch { Write-Host "  (symlink unavailable: $($_.Exception.Message))" }
    $First = Get-ChildItem -LiteralPath $Base -Recurse -File | Select-Object -First 1
    if ($First)
    {
        try { New-Item -ItemType HardLink -Path (Join-Path $Base 'hardlink.bin') -Target $First.FullName -ErrorAction Stop | Out-Null } catch { Write-Host "  (hard link unavailable: $($_.Exception.Message))" }
    }

    $Total = (Get-ChildItem -LiteralPath $Base -Recurse -File | Measure-Object -Property Length -Sum).Sum

    return @{ Path = $Base; Files = $FileCount; Bytes = [long]$Total }
}

<#
.SYNOPSIS
    Measures one scan with one backend, in this process.
#>
function Measure-WtBenchmarkRun
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Tree,
        [Parameter(Mandatory = $true)][string]$Mode,   # PowerShell | Go
        [Parameter(Mandatory = $true)][string]$Cache,  # cold | warm
        [Parameter(Mandatory = $true)][int]$Index
    )

    $Process = [System.Diagnostics.Process]::GetCurrentProcess()
    $CpuBefore = $Process.TotalProcessorTime
    $Watch = [System.Diagnostics.Stopwatch]::StartNew()
    $Result = Invoke-WtDirectoryScan -Root $Tree -Backend $Mode
    $Watch.Stop()
    $Cpu = $Process.TotalProcessorTime - $CpuBefore

    return [pscustomobject]@{
        Backend        = $Result.Backend
        Mode           = $Mode
        Cache          = $Cache
        Run            = $Index
        Ok             = [bool]$Result.Ok
        Files          = $Result.Files
        Directories    = $Result.Directories
        Bytes          = $Result.Bytes
        AllocatedBytes = $Result.AllocatedBytes
        ElapsedMs      = [int]$Watch.ElapsedMilliseconds
        CpuMs          = [int]$Cpu.TotalMilliseconds
        WorkingSetMB   = [math]::Round($Process.WorkingSet64 / 1MB, 1)
        PeakSetMB      = [math]::Round($Process.PeakWorkingSet64 / 1MB, 1)
        Partial        = [bool]$Result.Partial
        Cancelled      = [bool]$Result.Cancelled
        Code           = [string]$Result.Code
    }
}

# Worker startup and protocol overhead are measured by the public helper
# Measure-WtWorkerOverhead, which owns the client lifecycle (bounded shutdown included).

# ---- one-shot mode: used by the cold measurements, which need a fresh process -----------
if ($OneShot)
{
    $Tree = $Path
    $Rows = @()
    foreach ($Mode in @($Backend -split ','))
    {
        if ($Mode -eq 'Both') { continue }
        $Rows += Measure-WtBenchmarkRun -Tree $Tree -Mode $Mode -Cache 'cold' -Index 0
    }

    $Rows | ConvertTo-Json -Depth 6
    return
}

# ---- full run ---------------------------------------------------------------------------
$Tree = if ($Path) { $Path } else { Join-Path $Sandbox 'tree' }

if (-not $Path)
{
    Write-Host ("Building a deterministic tree: {0} files in {1} directories..." -f $Files, $Directories)
    New-WtBenchmarkTree -Base $Tree -FileCount $Files -DirectoryCount $Directories | Out-Null
}

# Identical logical total for both backends: the Go backend deduplicates the hard link and
# reports allocation size, which is recorded in the raw rows rather than mixed into the totals.
$Baseline = Invoke-WtDirectoryScan -Root $Tree -Backend 'PowerShell'
Write-Host ("Workload: {0} files, {1} directories, {2} bytes logical" -f $Baseline.Files, $Baseline.Directories, $Baseline.Bytes)

$Modes = switch ($Backends)
{
    'Both' { @('PowerShell', 'Go') }
    default { @($Backends) }
}

$Rows = [System.Collections.Generic.List[object]]::new()
$Overhead = [System.Collections.Generic.List[object]]::new()

foreach ($Mode in $Modes)
{
    Write-Host ("`n== {0} ==" -f $Mode)

    # Cold: a fresh process per run, after the tree was touched by the previous scan.
    for ($Index = 1; $Index -le $Runs; $Index++)
    {
        $Json = & (Join-Path $PSHOME 'pwsh') -NoProfile -File $PSCommandPath -OneShot -Backend $Mode -Path $Tree
        $Cold = @($Json | ConvertFrom-Json)[0]
        $Cold | Add-Member -NotePropertyName Cache -NotePropertyValue 'cold' -Force
        $Rows.Add($Cold)
        Write-Host ("  cold run {0}: {1} ms elapsed, {2} ms cpu" -f $Index, $Cold.ElapsedMs, $Cold.CpuMs)
    }

    # Warm: repeated runs in this process.
    for ($Index = 1; $Index -le $Runs; $Index++)
    {
        $Warm = Measure-WtBenchmarkRun -Tree $Tree -Mode $Mode -Cache 'warm' -Index $Index
        $Rows.Add($Warm)
        Write-Host ("  warm run {0}: {1} ms elapsed, {2} ms cpu" -f $Index, $Warm.ElapsedMs, $Warm.CpuMs)
    }

    if ($Mode -eq 'Go')
    {
        $Overhead.Add((Measure-WtWorkerOverhead -RoundTrips 20))
    }
}

$Summary = foreach ($Group in ($Rows | Group-Object -Property Mode, Cache))
{
    $Items = @($Group.Group | Where-Object { $_.Ok })
    if ($Items.Count -eq 0)
    {
        [pscustomobject]@{ Backend = $Group.Name; Runs = 0; MedianElapsedMs = 0; MedianCpuMs = 0; MedianFiles = 0; MedianBytes = 0; PeakSetMB = 0 }
        continue
    }

    $Elapsed = @($Items | ForEach-Object { $_.ElapsedMs } | Sort-Object)
    $Cpu = @($Items | ForEach-Object { $_.CpuMs } | Sort-Object)

    [pscustomobject]@{
        Backend         = $Group.Name
        Runs            = $Items.Count
        MedianElapsedMs = $Elapsed[[int][math]::Floor(($Elapsed.Count - 1) / 2)]
        MedianCpuMs     = $Cpu[[int][math]::Floor(($Cpu.Count - 1) / 2)]
        MedianFiles     = $Items[0].Files
        MedianBytes     = $Items[0].Bytes
        PeakSetMB       = ($Items | Measure-Object -Property PeakSetMB -Maximum).Maximum
    }
}

$Payload = [ordered]@{
    tool         = 'Measure-WtWorker.ps1'
    measuredUtc  = (Get-Date).ToUniversalTime().ToString('o')
    platform     = @{
        os          = if ($IsWindows) { 'windows' } else { 'linux' }
        arch        = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
        powershell  = $PSVersionTable.PSVersion.ToString()
        worker      = (Get-WtWorkerStatus -Force).Version
        protocol    = (Get-WtWorkerStatus).ExpectedProtocol
    }
    workload     = @{ path = $Tree; files = $Baseline.Files; directories = $Baseline.Directories; logicalBytes = $Baseline.Bytes }
    cacheNote    = 'cold = fresh process after the tree was re-created/touched; warm = subsequent runs in the same process. True page-cache eviction needs root and was not performed, so "cold" here is not a guaranteed uncached read.'
    runs         = @($Rows.ToArray())
    overhead     = @($Overhead.ToArray())
    summary      = @($Summary)
}

if (-not $Out)
{
    $Directory = Join-Path $Root 'docs/benchmarks'
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $Out = Join-Path $Directory ("worker-{0}-{1}.json" -f ($Payload.platform.os), (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))
}

($Payload | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $Out -Encoding utf8NoBOM

Write-Host "`n== Summary (median of runs) =="
$Summary | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
if ($Overhead.Count -gt 0)
{
    Write-Host '== Worker startup and protocol overhead =='
    $Overhead | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}

Write-Host ("Raw measurements: {0}" -f $Out)
Remove-Item -LiteralPath $Sandbox -Recurse -Force -ErrorAction Ignore
