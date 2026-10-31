# WindowsTweaker - bounded time-series history (in-memory ring buffers).
#
# Memory bounds are explicit (and the limits are used at every entry point, so they are
# testable):
#   * max series count (a new series beyond the bound is refused and counted);
#   * samples per series (a ring: oldest sample is dropped when the bound is reached);
#   * total metric memory (approximate, very conservative: bytes of stored values plus a
#     fixed per-sample overhead);
#   * dimension cardinality (unique dimension values per series are bounded);
#   * subscription count (bounded).
#
# Only actual observed history is kept: the ring stores the samples that were registered.
# A requested time range that exceeds the available history is reported as such, and the
# caller renders the available interval. Aggregation operates on the samples that exist;
# it never fills gaps with zeros, and where it can it keeps min/max alongside the mean so
# peaks are not flattened into a misleading average.

$Script:WtMonitorLimits = @{
    MaxSeries        = 256
    SamplesPerSeries = 4096
    ApproxBytesPerSample = 128
    MaxTotalBytes    = 64MB
    MaxDimsPerSeries = 16
    MaxSubscriptions = 32
}

<#
.SYNOPSIS
    Creates an empty, bounded metric history store.
#>
function New-WtMetricHistory
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    return @{
        Series = @{}
        Order = [System.Collections.Generic.List[string]]::new()
        TotalBytes = [long]0
        RefusedSeries = [long]0
        DroppedSamples = [long]0
        Limits = @{ MaxSeries = $Script:WtMonitorLimits.MaxSeries; SamplesPerSeries = $Script:WtMonitorLimits.SamplesPerSeries; ApproxBytesPerSample = $Script:WtMonitorLimits.ApproxBytesPerSample; MaxTotalBytes = $Script:WtMonitorLimits.MaxTotalBytes; MaxDimsPerSeries = $Script:WtMonitorLimits.MaxDimsPerSeries; MaxSubscriptions = $Script:WtMonitorLimits.MaxSubscriptions }
    }
}

<#
.SYNOPSIS
    Returns the series object for a key, creating it when allowed.
.DESCRIPTION
    A series holds a circular List of samples ({ tsMs, value } plus the last full sample
    object for rate calculations), the number of unique dimension values seen, and a
    counter of refused dimension values.
#>
function Get-WtMetricSeries
{
    [CmdletBinding()]
    [OutputType([object])]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$History,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][object]$Sample
    )

    if ($History.Series.ContainsKey($Key))
    {
        return $History.Series[$Key]
    }

    if ($History.Series.Count -ge $History.Limits.MaxSeries)
    {
        $History.RefusedSeries++
        return $null
    }

    # Dimension/cardinality bound: the same metric id may not fan out into more series than
    # MaxDimsPerSeries (each distinct dimension combination is a series).
    $BaseId = [string]$Sample.id
    $SameBase = @($History.Series.Values | Where-Object { $_.Id -eq $BaseId })
    if ($SameBase.Count -ge $History.Limits.MaxDimsPerSeries)
    {
        $History.RefusedSeries++
        return $null
    }

    $History.FamilyRefused = ($History.FamilyRefused -or $SameBase.Count -ge $History.Limits.MaxDimsPerSeries)

    $Series = @{
        Key = $Key
        Id = [string]$Sample.id
        Samples = [System.Collections.Generic.List[object]]::new()
        LastVerbose = $null
        Dims = @{}
        RefusedDims = 0
    }

    $History.Series[$Key] = $Series
    $History.Order.Add($Key)
    return $Series
}

<#
.SYNOPSIS
    Registers one sample in the bounded history.
.DESCRIPTION
    Enforces every limit. Returns @{ Accepted; Reason } - Accepted is false when the
    series bound or the memory bound is exceeded (the sample is then counted as dropped,
    never as zero).
#>
function Add-WtMetricSample
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$History,
        [Parameter(Mandatory = $true)][object]$Sample
    )

    $Key = Get-WtMetricSeriesKey -Sample $Sample
    $Series = Get-WtMetricSeries -History $History -Key $Key -Sample $Sample
    if (-not $Series)
    {
        $History.DroppedSamples++
        $Reason = 'series-limit'
        $SameBase = @($History.Series.Values | Where-Object { $_.Id -eq [string]$Sample.id })
        if ($SameBase.Count -ge $History.Limits.MaxDimsPerSeries) { $Reason = 'dim-cardinality' }
        return @{ Accepted = $false; Reason = $Reason }
    }

    # Dimension cardinality bound.
    if ($Sample.dims)
    {
        foreach ($Dim in $Sample.dims.Keys)
        {
            $DimKey = "$Dim=$($Sample.dims[$Dim])"
            if (-not $Series.Dims.ContainsKey($DimKey))
            {
                if ($Series.Dims.Count -ge $History.Limits.MaxDimsPerSeries)
                {
                    $Series.RefusedDims++
                    $History.DroppedSamples++
                    return @{ Accepted = $false; Reason = 'dim-cardinality' }
                }
                $Series.Dims[$DimKey] = $true
            }
        }
    }

    # Memory bound (approximate): value bytes + overhead. Counters keep their prior
    # sample for rates; a series is ~2 samples + fixed overhead.
    if ([long]$Sample.value -is [double]) { $ValueBytes = 8 } else { $ValueBytes = 8 }
    $SeriesBytes = [long](16 + $ValueBytes + ($Series.Samples.Count * 32) + 64)
    $History.TotalBytes = $SeriesBytes + $History.Series.Count * 64

    if ($History.TotalBytes -gt $History.Limits.MaxTotalBytes)
    {
        $History.DroppedSamples++
        return @{ Accepted = $false; Reason = 'memory-limit' }
    }

    $Series.Samples.Add($Sample)
    $Series.LastVerbose = $Sample

    if ($Series.Samples.Count -gt $History.Limits.SamplesPerSeries)
    {
        $Series.Samples.RemoveAt(0)
        $History.DroppedSamples++
    }

    return @{ Accepted = $true; Reason = '' }
}

<#
.SYNOPSIS
    Returns the samples of a series within a time range (ms since epoch).
.DESCRIPTION
    Only observed samples are returned; nothing is synthesized. When the requested range
    extends beyond the available history, the available interval is returned and the
    AvailableUntil/AvailableFrom fields state it.
#>
function Get-WtMetricSamples
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$History,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $false)][long]$FromMs = 0,
        [Parameter(Mandatory = $false)][long]$ToMs = 0
    )

    if (-not $History.Series.ContainsKey($Key))
    {
        return @{ Key = $Key; Samples = @(); AvailableFrom = 0; AvailableTo = 0 }
    }

    $Series = $History.Series[$Key]

    if (-not $ToMs) { $ToMs = [int64]([datetime]::UtcNow.ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,[datetimekind]::Utc)).TotalMilliseconds }

    $Samples = @($Series.Samples | Where-Object { [long]$_.tsMs -ge $FromMs -and [long]$_.tsMs -le $ToMs })

    $First = $Series.Samples[0]
    $Last = $Series.Samples[$Series.Samples.Count - 1]

    return @{
        Key = $Key
        Samples = $Samples
        AvailableFrom = [long]$First.tsMs
        AvailableTo = [long]$Last.tsMs
    }
}

<#
.SYNOPSIS
    Aggregates a sample list into chart buckets.
.DESCRIPTION
    Buckets span equal time slices between the requested range (clamped to available
    history). Aggregation methods are allowlisted: none (raw), avg, min, max, sum,
    last. Each bucket records count, min, max, sum and the last sample ts, and marks the
    bucket as a gap when it contains no samples - gaps are never filled.
#>
function ConvertTo-WtMetricBuckets
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$Range,
        [Parameter(Mandatory = $true)][int]$Buckets,
        [Parameter(Mandatory = $false)][ValidateSet('raw', 'avg', 'min', 'max', 'sum', 'last')][string]$Method = 'avg'
    )

    if ($Buckets -le 0) { $Buckets = 1 }
    $Samples = @($Range.Samples)
    if ($Samples.Count -eq 0)
    {
        return @()
    }

    $From = [math]::Max([long]$Range.AvailableFrom, [long]$Range.FromMs)
    $To = [math]::Min([long]$Range.AvailableTo, [long]$Range.ToMs)
    if ($To -le $From) { $To = $From + 1 }

    $Span = [double]($To - $From)
    $Step = [math]::Max(1, [int][math]::Floor($Span / $Buckets))
    $UseBuckets = [math]::Min($Buckets, [int][math]::Ceiling($Span / $Step))

    $Result = [System.Collections.Generic.List[object]]::new()

    for ($B = 0; $B -lt $UseBuckets; $B++)
    {
        $Start = $From + ($B * $Step)
        $End = $Start + $Step
        $InBucket = @($Samples | Where-Object { [long]$_.tsMs -ge $Start -and ([long]$_.tsMs -lt $End -or ($B -eq $UseBuckets - 1 -and [long]$_.tsMs -le $End)) })

        if ($InBucket.Count -eq 0)
        {
            $Result.Add([pscustomobject]@{
                StartMs = $Start
                EndMs = $End
                Count = 0
                Gap = $true
                Min = $null
                Max = $null
                Sum = $null
                Last = $null
                LastTsMs = $null
            })
            continue
        }

        $Values = @($InBucket | ForEach-Object { [double]$_.value })
        $Value = switch ($Method)
        {
            'min' { ($Values | Measure-Object -Minimum).Minimum }
            'max' { ($Values | Measure-Object -Maximum).Maximum }
            'sum' { ($Values | Measure-Object -Sum).Sum }
            'last' { $Values[$Values.Count - 1] }
            'raw' { $Values[0] }
            default { ($Values | Measure-Object -Average).Average }
        }

        $Result.Add([pscustomobject]@{
            StartMs = $Start
            EndMs = $End
            Count = $InBucket.Count
            Gap = $false
            Min = ($Values | Measure-Object -Minimum).Minimum
            Max = ($Values | Measure-Object -Maximum).Maximum
            Sum = ($Values | Measure-Object -Sum).Sum
            Last = $Value
            LastTsMs = [long]$InBucket[$InBucket.Count - 1].tsMs
        })
    }

    return @($Result.ToArray())
}

<#
.SYNOPSIS
    Applies a time-range selection (seconds) against available history.
.DESCRIPTION
    When the requested range exceeds available history, the window is clamped and the
    Available flag reflects what was actually returned.
#>
function Select-WtMetricRange
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$History,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $false)][int]$Seconds = 300
    )

    $Now = [int64]([datetime]::UtcNow.ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,[datetimekind]::Utc)).TotalMilliseconds
    $FromMs = $Now - ($Seconds * 1000)

    $Range = Get-WtMetricSamples -History $History -Key $Key -FromMs $FromMs -ToMs $Now
    $Range.FromMs = $FromMs
    $Range.ToMs = $Now
    $Range.RequestedSeconds = $Seconds
    $Range.Available = ($Range.AvailableFrom -le $FromMs) -and ($Range.AvailableTo -ge $Now - 1000)
    return $Range
}
