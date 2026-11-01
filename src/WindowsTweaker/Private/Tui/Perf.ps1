# WindowsTweaker - bounded TUI performance diagnostics.
#
# Opt-in, monotonic, and deliberately quiet unless enabled. When enabled it records the
# application-side durations of the input-to-render path - key dispatch, handler, frame
# construction and frame output - plus how many rows a frame actually wrote, in a bounded
# ring. A summary (counts, median/p95/max per metric, process CPU share) is written to the
# structured log when the interface exits. Nothing here measures physical key-to-display
# latency: that needs a real terminal and input hardware.
#
# Privacy contract: samples carry durations, key *names*, dispatch targets (a small fixed
# vocabulary) and an idle flag. Typed search text, confirmation text, paths and values are
# never recorded - the dispatch target 'search' is recorded, never the characters.

$Script:WtTuiPerfEnabled = $false
$Script:WtTuiPerfMaxSamples = 1024

# $Script:WtTuiPerf = @{ Samples; Frames; Painted; Idle; WallStart; CpuStart; Started }
$Script:WtTuiPerf = $null

<#
.SYNOPSIS
    Enables or disables the bounded TUI performance diagnostics.
.DESCRIPTION
    Also controlled by WT_TUI_PERF_DIAGNOSTICS=1. The diagnostics are in-process only: a
    ring of the most recent samples plus a summary at exit; nothing is sampled when
    disabled. Records carry no typed text, so enabling this never exposes a search term or
    a confirmation value.
#>
function Set-WtTuiPerf
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][bool]$Enabled)

    if ($Enabled -and -not $Script:WtTuiPerf)
    {
        $Script:WtTuiPerf = @{
            Samples  = [System.Collections.Generic.List[object]]::new()
            Frames  = 0
            Painted = 0
            Idle    = 0
            WallStart = [datetime]::UtcNow
            CpuStart = (Get-Process -Id $PID).TotalProcessorTime
            Started  = [System.Diagnostics.Stopwatch]::StartNew()
        }
    }

    if (-not $Enabled)
    {
        $Script:WtTuiPerf = $null
    }

    $Script:WtTuiPerfEnabled = [bool]$Enabled
}

<#
.SYNOPSIS
    Reports whether the performance diagnostics are recording.
#>
function Test-WtTuiPerf
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    return [bool]$Script:WtTuiPerfEnabled
}

<#
.SYNOPSIS
    Starts a frame sample and returns the sample handle.
.DESCRIPTION
    The frame records dispatch/construction/output durations; the caller (the main loop)
    completes the sample with the handler duration once the key has been processed. A
    sample without a handler is an idle frame.
#>
function New-WtTuiPerfSample
{
    [CmdletBinding()]
    [OutputType([object])]
    param ()

    return [pscustomobject]@{
        PSTypeName  = 'WindowsTweaker.TuiPerfSample'
        Kind        = 'idle'
        DispatchMs  = [double]0
        HandlerMs   = [double]0
        ConstructMs = [double]0
        OutputMs    = [double]0
        RowsWritten = 0
        Painted     = $false
    }
}

<#
.SYNOPSIS
    Adds one sample to the bounded ring.
.DESCRIPTION
    The ring never grows past the configured bound: the oldest sample is dropped.
#>
function Add-WtTuiPerfSample
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Sample)

    if (-not $Script:WtTuiPerf -or $null -eq $Sample)
    {
        return
    }

    $Script:WtTuiPerf.Frames = [int]$Script:WtTuiPerf.Frames + 1
    if ($Sample.Painted) { $Script:WtTuiPerf.Painted = [int]$Script:WtTuiPerf.Painted + 1 }
    if ($Sample.Kind -eq 'idle') { $Script:WtTuiPerf.Idle = [int]$Script:WtTuiPerf.Idle + 1 }

    $Samples = $Script:WtTuiPerf.Samples
    $Samples.Add($Sample)
    if ($Samples.Count -gt $Script:WtTuiPerfMaxSamples)
    {
        $Samples.RemoveAt(0)
    }
}

<#
.SYNOPSIS
    Returns a copy of the recorded samples.
.DESCRIPTION
    Used by the tests to assert boundedness and that the metrics are populated without
    competing with the live ring.
#>
function Get-WtTuiPerfSamples
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param ()

    if (-not $Script:WtTuiPerf)
    {
        return @()
    }

    return @($Script:WtTuiPerf.Samples.ToArray())
}

<#
.SYNOPSIS
    Computes a percentile over a sorted numeric array.
#>
function Get-WtPerfPercentile
{
    [CmdletBinding()]
    [OutputType([double])]
    param
    (
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][double[]]$Values,
        [Parameter(Mandatory = $true)][double]$Percentile
    )

    if ($Values.Count -eq 0) { return 0 }
    if ($Values.Count -eq 1) { return $Values[0] }

    $Rank = [math]::Max(0, [math]::Ceiling($Percentile * $Values.Count) - 1)
    return $Values[[math]::Min($Rank, $Values.Count - 1)]
}

<#
.SYNOPSIS
    Writes the summary of the recorded samples to the structured log.
.DESCRIPTION
    Median and p95 of the application-side durations, the frame counts, the share of
    frames that painted rows, the average rows written per painted frame, and the share of
    one CPU the process consumed over the session. The wall clock is the session length;
    the CPU share is process CPU time divided by it, so a reading of ~25% on a VM with 4
    vCPUs means roughly one core busy.
#>
function Write-WtTuiPerfSummary
{
    [CmdletBinding()]
    param ()

    if (-not $Script:WtTuiPerf)
    {
        return
    }

    $Perf = $Script:WtTuiPerf
    $Samples = @($Perf.Samples.ToArray())

    $Dispatch = @($Samples | ForEach-Object { [double]$_.DispatchMs } | Sort-Object)
    $Handler  = @($Samples | Where-Object { $_.Kind -ne 'idle' } | ForEach-Object { [double]$_.HandlerMs } | Sort-Object)
    $Construct = @($Samples | Where-Object { $_.Painted } | ForEach-Object { [double]$_.ConstructMs } | Sort-Object)
    $Output   = @($Samples | Where-Object { $_.Painted } | ForEach-Object { [double]$_.OutputMs } | Sort-Object)
    $Rows     = @($Samples | Where-Object { $_.Painted } | ForEach-Object { [double]$_.RowsWritten } | Sort-Object)

    $Elapsed = ([datetime]::UtcNow - $Perf.WallStart).TotalSeconds
    $Cpu = [double]0
    if ($Elapsed -gt 0)
    {
        $CpuDelta = ((Get-Process -Id $PID).TotalProcessorTime - $Perf.CpuStart).TotalSeconds
        $Cpu = [math]::Round(100 * $CpuDelta / $Elapsed, 1)
    }

    Write-WtLog -Level Information -Message "TUI performance: frames=$($Perf.Frames) painted=$($Perf.Painted) idle=$($Perf.Idle) samples=$($Samples.Count)" -NoConsole
    Write-WtLog -Level Information -Message "TUI performance (ms): dispatch median=$(Get-WtPerfPercentile -Values ([double[]]$Dispatch) -Percentile 0.5) p95=$(Get-WtPerfPercentile -Values ([double[]]$Dispatch) -Percentile 0.95) max=$(Get-WtPerfPercentile -Values ([double[]]$Dispatch) -Percentile 1)" -NoConsole
    Write-WtLog -Level Information -Message "TUI performance handler (ms): median=$(Get-WtPerfPercentile -Values ([double[]]$Handler) -Percentile 0.5) p95=$(Get-WtPerfPercentile -Values ([double[]]$Handler) -Percentile 0.95) max=$(Get-WtPerfPercentile -Values ([double[]]$Handler) -Percentile 1)" -NoConsole
    Write-WtLog -Level Information -Message "TUI performance frame build (ms): median=$(Get-WtPerfPercentile -Values ([double[]]$Construct) -Percentile 0.5) p95=$(Get-WtPerfPercentile -Values ([double[]]$Construct) -Percentile 0.95) max=$(Get-WtPerfPercentile -Values ([double[]]$Construct) -Percentile 1)" -NoConsole
    Write-WtLog -Level Information -Message "TUI performance frame output (ms): median=$(Get-WtPerfPercentile -Values ([double[]]$Output) -Percentile 0.5) p95=$(Get-WtPerfPercentile -Values ([double[]]$Output) -Percentile 0.95) max=$(Get-WtPerfPercentile -Values ([double[]]$Output) -Percentile 1)" -NoConsole
    if ($Rows.Count -gt 0)
    {
        Write-WtLog -Level Information -Message "TUI performance rows written per painted frame: median=$(Get-WtPerfPercentile -Values ([double[]]$Rows) -Percentile 0.5) p95=$(Get-WtPerfPercentile -Values ([double[]]$Rows) -Percentile 0.95) max=$(Get-WtPerfPercentile -Values ([double[]]$Rows) -Percentile 1)" -NoConsole
    }
    Write-WtLog -Level Information -Message "TUI performance process CPU: $Cpu%" -NoConsole
}
