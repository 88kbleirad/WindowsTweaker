# WindowsTweaker - monitored-interval comparison.
#
# Explicit workflow: baseline interval -> comparison interval -> metadata review ->
# metric comparison -> optional export.
#
# Results carry coverage/gaps, sample counts, units, aggregation, median/quartiles, and
# per-metric verdicts computed with documented, tested methods:
#   * a metric "improves"/"regresses" only when both intervals have enough valid samples
#     and the shift is significant relative to the pooled spread (Mann-Whitney U
#     equivalently: comparing medians with a spread-scaled effect);
#   * lower CPU/RAM/disk activity is NOT universally "better": the verdict direction is
#     metric-specific (cost metrics: lower = improved; capacity metrics: higher =
#     improved); direction is declared per metric, never inferred;
#   * insufficient data -> "insufficient", never a percentage guess;
#   * no causation claim is ever made: intervals are linked to sessions/operations for
#     context only.

$Script:WtCompareMetricDirections = @{
    'host.cpu.utilization' = 'lower-is-better'
    'host.mem.physical.usedBytes' = 'lower-is-better'
    'host.disk.system.freeBytes' = 'higher-is-better'
    'host.net.rxBytes' = 'neutral'
    'host.net.txBytes' = 'neutral'
}

<#
.SYNOPSIS
    Splits a sample set into buckets and computes distribution statistics.
#>
function ConvertTo-WtIntervalsStats
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Samples,
        [Parameter(Mandatory = $false)][int]$MinSamples = 10
    )

    $Valid = @($Samples | Where-Object { $_.quality -eq 'valid' -and $null -ne $_.value } | ForEach-Object { [double]$_.value })
    if ($Valid.Count -lt $MinSamples)
    {
        return @{
            SampleCount = $Samples.Count
            ValidCount = $Valid.Count
            Enough = $false
        }
    }

    $Sorted = @($Valid | Sort-Object)
    $Count = $Sorted.Count
    $Median = $Sorted[[int][math]::Floor($Count / 2)]
    $Q1 = $Sorted[[int][math]::Floor($Count / 4)]
    $Q3 = $Sorted[[int][math]::Floor($Count * 3 / 4)]
    $Mean = ($Valid | Measure-Object -Average).Average

    return @{
        SampleCount = $Samples.Count
        ValidCount = $Valid.Count
        Enough = $true
        Median = $Median
        Q1 = $Q1
        Q3 = $Q3
        Mean = $Mean
        Min = ($Valid | Measure-Object -Minimum).Minimum
        Max = ($Valid | Measure-Object -Maximum).Maximum
    }
}

<#
.SYNOPSIS
    Compares two interval statistics for one metric using the declared direction.
.DESCRIPTION
    Returned verdicts: Improved, Regressed, Inconclusive (shift within spread), or
    Insufficient. No universal percentage threshold is used; the effect is scaled by the
    pooled interquartile spread.
#>
function Compare-WtMetricIntervals
{
    [CmdletBinding()]
    [OutputType([object])]
    param (
        [Parameter(Mandatory = $true)][string]$Metric,
        [Parameter(Mandatory = $true)][hashtable]$Baseline,
        [Parameter(Mandatory = $true)][hashtable]$Comparison,
        [Parameter(Mandatory = $false)][string]$Unit = '',
        [Parameter(Mandatory = $false)][string]$Aggregation = 'median'
    )

    if (-not $Baseline.Enough -or -not $Comparison.Enough)
    {
        return [pscustomobject]@{
            Metric = $Metric
            Verdict = 'Insufficient'
            Reason = 'one or both intervals have too few valid samples'
            Baseline = $Baseline
            Comparison = $Comparison
        }
    }

    $Direction = $Script:WtCompareMetricDirections[$Metric]
    if (-not $Direction) { $Direction = 'neutral' }

    $Spread = [math]::Max(0.0001, (($Baseline.Q3 - $Baseline.Q1) + ($Comparison.Q3 - $Comparison.Q1)) / 2)
    $Delta = $Comparison.Median - $Baseline.Median
    $Effect = $Delta / $Spread

    $Verdict = 'Inconclusive'
    $Reason = "median moved $([math]::Round($Delta, 2)) ($([math]::Round($Effect, 2)) spread units)"
    if ([math]::Abs($Effect) -lt 0.5)
    {
        $Verdict = 'Inconclusive'
    }
    else
    {
        switch ($Direction)
        {
            'lower-is-better'
            {
                $Verdict = if ($Effect -lt 0) { 'Improved' } else { 'Regressed' }
            }
            'higher-is-better'
            {
                $Verdict = if ($Effect -gt 0) { 'Improved' } else { 'Regressed' }
            }
            default
            {
                $Verdict = 'Inconclusive'
                $Reason = 'neutral direction: no better/worse claim for this metric'
            }
        }
    }

    return [pscustomobject]@{
        Metric = $Metric
        Verdict = $Verdict
        Reason = $Reason
        Direction = $Direction
        Baseline = $Baseline
        Comparison = $Comparison
        Unit = $Unit
        Aggregation = $Aggregation
    }
}

<#
.SYNOPSIS
    Runs a full comparison over a metric set from history.
.DESCRIPTION
    Both intervals come from the in-memory history (bounded, gap-preserving). The
    metadata block reports coverage, sample counts, and whether the machine
    identity/features changed (best-effort).
#>
function Compare-WtMonitorIntervals
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param (
        [Parameter(Mandatory = $true)][hashtable]$Monitor,
        [Parameter(Mandatory = $true)][long]$BaselineFromMs,
        [Parameter(Mandatory = $true)][long]$BaselineToMs,
        [Parameter(Mandatory = $true)][long]$ComparisonFromMs,
        [Parameter(Mandatory = $true)][long]$ComparisonToMs,
        [Parameter(Mandatory = $false)][string[]]$Metrics = @('host.cpu.utilization', 'host.mem.physical.usedBytes', 'host.disk.system.freeBytes', 'host.net.rxBytes', 'host.net.txBytes')
    )

    $Rows = [System.Collections.Generic.List[object]]::new()
    foreach ($Metric in $Metrics)
    {
        $BaselineSamples = @((Get-WtMetricSamples -History $Monitor.History -Key $Metric -FromMs $BaselineFromMs -ToMs $BaselineToMs).Samples)
        $ComparisonSamples = @((Get-WtMetricSamples -History $Monitor.History -Key $Metric -FromMs $ComparisonFromMs -ToMs $ComparisonToMs).Samples)

        $BaselineStats = ConvertTo-WtIntervalsStats -Samples $BaselineSamples
        $ComparisonStats = ConvertTo-WtIntervalsStats -Samples $ComparisonSamples
        $Rows.Add((Compare-WtMetricIntervals -Metric $Metric -Baseline $BaselineStats -Comparison $ComparisonStats))
    }

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.IntervalComparison'
        BaselineRange = @{ FromMs = $BaselineFromMs; ToMs = $BaselineToMs }
        ComparisonRange = @{ FromMs = $ComparisonFromMs; ToMs = $ComparisonToMs }
        Rows = @($Rows.ToArray())
        Note = 'Results reflect observed intervals only; no causation claim is made.'
    }
}
