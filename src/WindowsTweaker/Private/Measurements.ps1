# WindowsTweaker - bounded, local network measurements.
#
# Measure-WtNetworkDiagnostics runs a small, bounded series of latency probes (a DNS
# resolution or a TCP connect) and returns every raw sample plus a summary.
# Compare-WtMeasurements classifies two measurements against each other.
#
# Nothing here applies a tweak, writes a file, logs or blocks indefinitely: each probe is
# bounded by -TimeoutMs and the whole call by Samples * TimeoutMs + 1000 ms. The resolver
# and the clock are injectable seams so tests never touch the network, and the default
# resolver is the only place in this file that performs I/O.

$Script:WtMeasurementDefaultSamples = 5
$Script:WtMeasurementMinSamples = 1
$Script:WtMeasurementMaxSamples = 20
$Script:WtMeasurementDefaultTimeoutMs = 1500
$Script:WtMeasurementMinTimeoutMs = 250
$Script:WtMeasurementMaxTimeoutMs = 5000
$Script:WtMeasurementBudgetSlackMs = 1000

# Short human-readable descriptions of the rule that produced a classification. They are
# diagnostics text, not user interface text: the interface localizes its own wording.
$Script:WtCompareCriteria = @{
    NoSamples      = 'insufficient: a side has zero successful samples'
    ShortOfSamples = 'insufficient: a side has fewer successful samples than MinimumSamples'
    Mismatch       = 'inconclusive: target, kind or unit differ between the measurements'
    BelowThreshold = 'inconclusive: the median change is smaller than the threshold'
    OverlapBetter  = 'inconclusive: the median improved but the after-side maximum exceeds the before-side maximum'
    OverlapWorse   = 'inconclusive: the median regressed but the after-side minimum is below the before-side minimum'
    Improved       = 'improved: after median <= before median * (1 - threshold) and after max <= before max'
    Regressed      = 'regressed: after median >= before median * (1 + threshold) and after min >= before min'
}

<#
.SYNOPSIS
    Formats a measurement number with an invariant, culture-independent representation.
.DESCRIPTION
    Reasons and criteria are produced as machine-stable text, so numbers must not follow
    the current culture's decimal separator.
#>
function Format-WtMeasurementNumber
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][double]$Value)

    return $Value.ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture)
}

<#
.SYNOPSIS
    Collapses a probe error into a short single-line string.
.DESCRIPTION
    Failed samples carry a short reason; the full exception text is not useful in a record
    and may be several lines long.
#>
function ConvertTo-WtShortError
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $Message = ($ErrorRecord.Exception.Message -replace '\s+', ' ').Trim()

    if ([string]::IsNullOrWhiteSpace($Message))
    {
        $Message = 'probe failed without a message'
    }

    if ($Message.Length -gt 200)
    {
        $Message = $Message.Substring(0, 200)
    }

    return $Message
}

<#
.SYNOPSIS
    Returns the platform name recorded in a measurement's conditions.
#>
function Get-WtMeasurementPlatform
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    $RuntimeProfile = Get-WtRuntimeProfile

    if ($RuntimeProfile.IsWindows) { return 'Windows' }
    if ($RuntimeProfile.IsLinux) { return 'Linux' }
    if ($RuntimeProfile.IsMacOS) { return 'macOS' }

    return 'Unknown'
}

<#
.SYNOPSIS
    Creates the identifier of one measurement.
#>
function New-WtMeasurementId
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    return ('wt-{0}' -f [guid]::NewGuid().ToString('n'))
}

<#
.SYNOPSIS
    Default probe used when Measure-WtNetworkDiagnostics gets no -Resolve seam.
.DESCRIPTION
    Kind 'dns' resolves the target with [System.Net.Dns]::GetHostAddressesAsync and waits
    at most TimeoutMs; kind 'tcp' opens a TcpClient connection to Target:Port under the same
    bound. The elapsed milliseconds are returned, and a failure or a timeout throws so the
    caller records a failed sample instead of inventing a latency.

    This is the only code in this file that performs network I/O, and tests never call it.
.PARAMETER Context
    @{ Target; TimeoutMs; Index; Kind; Port } handed over by Measure-WtNetworkDiagnostics.
#>
function Get-WtNetworkSampleMilliseconds
{
    [CmdletBinding()]
    [OutputType([double])]
    param ([Parameter(Mandatory = $true)][hashtable]$Context)

    $Target = [string]$Context.Target
    $TimeoutMs = [int]$Context.TimeoutMs

    if ([string]$Context.Kind -eq 'tcp')
    {
        $Client = [System.Net.Sockets.TcpClient]::new()
        try
        {
            $Watch = [System.Diagnostics.Stopwatch]::StartNew()
            $Connect = $Client.ConnectAsync($Target, [int]$Context.Port)

            if (-not $Connect.Wait($TimeoutMs))
            {
                throw "TCP connect to ${Target}:$($Context.Port) timed out after $TimeoutMs ms"
            }

            # Observes a faulted task as an exception instead of returning a fake timing.
            [void]$Connect.GetAwaiter().GetResult()
            $Watch.Stop()

            return [double]$Watch.Elapsed.TotalMilliseconds
        }
        finally
        {
            $Client.Dispose()
        }
    }

    $Watch = [System.Diagnostics.Stopwatch]::StartNew()
    $ResolveTask = [System.Net.Dns]::GetHostAddressesAsync($Target)

    if (-not $ResolveTask.Wait($TimeoutMs))
    {
        throw "DNS resolution of '$Target' timed out after $TimeoutMs ms"
    }

    [void]$ResolveTask.GetAwaiter().GetResult()
    $Watch.Stop()

    return [double]$Watch.Elapsed.TotalMilliseconds
}

<#
.SYNOPSIS
    Lower-middle median of a set of numbers.
.DESCRIPTION
    The values are sorted ascending. An odd count yields the single middle value; an even
    count yields the lower of the two central values ('lower-middle' convention, not the
    average of the pair). The convention is deliberate so a measurement's median is always
    one of the measured samples.
#>
function Get-WtMedianValue
{
    [CmdletBinding()]
    [OutputType([double])]
    param ([Parameter(Mandatory = $true)][AllowEmptyCollection()][double[]]$Values)

    $Sorted = @($Values | Sort-Object)
    $Count = $Sorted.Count

    if ($Count -eq 0)
    {
        throw 'Get-WtMedianValue needs at least one value.'
    }

    $Index = [int][math]::Floor(($Count - 1) / 2)

    return [double]$Sorted[$Index]
}

<#
.SYNOPSIS
    Reads the sample list of a measurement as an array (never $null).
.DESCRIPTION
    Returns `,@()`-wrapped arrays on purpose: a bare empty array would be unrolled into no
    pipeline output and hand the caller $null, which callers would then treat as one sample.
.PARAMETER Measurement
    A measurement hashtable as produced by Measure-WtNetworkDiagnostics.
#>
function Get-WtMeasurementSampleList
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param ([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Measurement)

    if (-not $Measurement.Contains('Samples'))
    {
        return , @()
    }

    $Samples = $Measurement['Samples']

    if ($null -eq $Samples)
    {
        return , @()
    }

    return , @($Samples)
}

<#
.SYNOPSIS
    Counts successful/failed samples and computes Min, Max and Median over the successful ones.
.DESCRIPTION
    Min, Max and Median are $null when no sample succeeded. Failed samples are counted but
    never contribute a value.
#>
function Get-WtMeasurementStatistics
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$Samples)

    $All = if ($null -eq $Samples) { @() } else { @($Samples) }
    $Values = @($All | Where-Object { $_.Ok } | ForEach-Object { [double]$_.Value })

    $Result = @{
        Count  = $All.Count
        Ok     = $Values.Count
        Failed = $All.Count - $Values.Count
        Min    = $null
        Max    = $null
        Median = $null
    }

    if ($Values.Count -gt 0)
    {
        $Sorted = @($Values | Sort-Object)
        $Result.Min = [double]$Sorted[0]
        $Result.Max = [double]$Sorted[$Sorted.Count - 1]
        $Result.Median = Get-WtMedianValue -Values $Values
    }

    return $Result
}

<#
.SYNOPSIS
    Builds one classification result for Compare-WtMeasurements.
.DESCRIPTION
    Keeps the result shape identical across every branch of the comparison.
#>
function New-WtCompareResult
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory = $true)][ValidateSet('improved', 'regressed', 'inconclusive', 'insufficient')][string]$Classification,
        [Parameter(Mandatory = $true)][string]$Criteria,
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter()][AllowNull()][object]$BeforeMedian = $null,
        [Parameter()][AllowNull()][object]$AfterMedian = $null,
        [Parameter()][AllowNull()][object]$DeltaMs = $null,
        [Parameter()][AllowNull()][object]$DeltaPercent = $null,
        [Parameter()][AllowNull()][string]$Unit = $null
    )

    return @{
        Classification = $Classification
        BeforeMedian   = $BeforeMedian
        AfterMedian    = $AfterMedian
        DeltaMs        = $DeltaMs
        DeltaPercent   = $DeltaPercent
        Unit           = $Unit
        Criteria       = $Criteria
        Reason         = $Reason
    }
}

<#
.SYNOPSIS
    Runs a bounded series of local network probes and returns the raw samples and a summary.
.DESCRIPTION
    Probes -Target by DNS resolution ('dns') or by a TCP connect to -Port ('tcp'), then
    returns one hashtable:

        @{
            MeasurementId; StartedUtc; CompletedUtc; Target; Kind; Unit = 'ms'
            Conditions = @{ Samples; TimeoutMs; Port; Adapter; Platform; PSVersion }
            Samples    = @( @{ Index; TimestampUtc; Value; Unit; Ok; Error } )
            Summary    = @{ Count; Ok; Failed; Min; Max; Median }
        }

    Bounded: -Samples is clamped to 1..20 (default 5), -TimeoutMs to 250..5000 ms (default
    1500), and the loop stops for good once Samples * TimeoutMs + 1000 ms have elapsed.
    Every sample is retained: a probe that throws, times out or returns nothing is recorded
    with Ok = $false and a short Error, never silently dropped. Min, Max and Median cover the
    successful samples only (median: odd count -> middle value, even count -> lower-middle).

    This function only measures. It applies no tweak, writes no file and takes no follow-up
    action of any kind; interpreting the result is the caller's job. Comparison lives in
    Compare-WtMeasurements, which likewise only classifies.
.PARAMETER Target
    Host name or address to probe.
.PARAMETER Kind
    'dns' (default) resolves the target; 'tcp' connects to Target:Port.
.PARAMETER Port
    TCP port for -Kind tcp. Default 443. Unused by 'dns' but still recorded in Conditions.
.PARAMETER Samples
    Number of probes, clamped to 1..20. Default 5.
.PARAMETER TimeoutMs
    Per-probe timeout in milliseconds, clamped to 250..5000. Default 1500.
.PARAMETER Adapter
    Optional network adapter name recorded in Conditions for attribution. It is never
    queried or changed.
.PARAMETER Resolve
    Probe seam. Called with @{ Target; TimeoutMs; Index; Kind; Port } where Index is the
    1-based sample number; returns the latency in milliseconds, or throws/returns $null for a
    failed sample. The default performs the real DNS/TCP probe. Tests always override it.
.PARAMETER Now
    Clock seam returning a [datetime]. Default { [datetime]::UtcNow }.
.OUTPUTS
    System.Collections.Hashtable as described above.
.EXAMPLE
    Measure-WtNetworkDiagnostics -Target 'one.one.one.one' -Kind tcp -Port 443 -Samples 5
#>
function Measure-WtNetworkDiagnostics
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Target,
        [Parameter()][ValidateSet('dns', 'tcp')][string]$Kind = 'dns',
        [Parameter()][ValidateRange(1, 65535)][int]$Port = 443,
        [Parameter()][int]$Samples = $Script:WtMeasurementDefaultSamples,
        [Parameter()][int]$TimeoutMs = $Script:WtMeasurementDefaultTimeoutMs,
        [Parameter()][AllowEmptyString()][string]$Adapter = '',
        [Parameter()][scriptblock]$Resolve = { param ($Context) Get-WtNetworkSampleMilliseconds -Context $Context },
        [Parameter()][scriptblock]$Now = { [datetime]::UtcNow }
    )

    $EffectiveSamples = [int][math]::Min([math]::Max($Samples, $Script:WtMeasurementMinSamples), $Script:WtMeasurementMaxSamples)
    $EffectiveTimeoutMs = [int][math]::Min([math]::Max($TimeoutMs, $Script:WtMeasurementMinTimeoutMs), $Script:WtMeasurementMaxTimeoutMs)
    $BudgetMs = ($EffectiveSamples * $EffectiveTimeoutMs) + $Script:WtMeasurementBudgetSlackMs
    $AdapterName = if ([string]::IsNullOrWhiteSpace($Adapter)) { $null } else { $Adapter.Trim() }

    $StartedUtc = [datetime](& $Now)
    $Clock = [System.Diagnostics.Stopwatch]::StartNew()
    $SampleList = [System.Collections.Generic.List[hashtable]]::new()

    for ($Index = 1; $Index -le $EffectiveSamples; $Index++)
    {
        $TimestampUtc = [datetime](& $Now)
        $Value = $null
        $SampleError = $null

        if ($Clock.Elapsed.TotalMilliseconds -ge $BudgetMs)
        {
            $SampleError = "measurement budget of $BudgetMs ms was exhausted before sample $Index"
        }
        else
        {
            $Context = @{
                Target    = $Target
                TimeoutMs = $EffectiveTimeoutMs
                Index     = $Index
                Kind      = $Kind
                Port      = $Port
            }

            try
            {
                $Emitted = @(& $Resolve $Context)

                if ($Emitted.Count -eq 0 -or $null -eq $Emitted[0])
                {
                    $SampleError = 'probe returned no value'
                }
                elseif ($Emitted.Count -gt 1)
                {
                    $SampleError = "probe returned $($Emitted.Count) values; expected one"
                }
                else
                {
                    $Value = [double]$Emitted[0]
                }
            }
            catch
            {
                $Value = $null
                $SampleError = ConvertTo-WtShortError -ErrorRecord $_
            }
        }

        $SampleList.Add(@{
                Index        = $Index
                TimestampUtc = $TimestampUtc
                Value        = $Value
                Unit         = 'ms'
                Ok           = ($null -ne $Value)
                Error        = $SampleError
            })
    }

    $CompletedUtc = [datetime](& $Now)
    $RawSamples = $SampleList.ToArray()

    return @{
        MeasurementId = New-WtMeasurementId
        StartedUtc    = $StartedUtc
        CompletedUtc  = $CompletedUtc
        Target        = $Target
        Kind          = $Kind
        Unit          = 'ms'
        Conditions    = @{
            Samples   = $EffectiveSamples
            TimeoutMs = $EffectiveTimeoutMs
            Port      = $Port
            Adapter   = $AdapterName
            Platform  = Get-WtMeasurementPlatform
            PSVersion = $PSVersionTable.PSVersion.ToString()
        }
        Samples       = $RawSamples
        Summary       = Get-WtMeasurementStatistics -Samples $RawSamples
    }
}

<#
.SYNOPSIS
    Classifies two network measurements as improved, regressed, inconclusive or insufficient.
.DESCRIPTION
    Lower milliseconds is better. The two measurements must describe the same probe; when
    their Target, Kind or Unit differ there is nothing to compare.

    Documented criteria (in this order):
      * insufficient - either side has fewer than MinimumSamples successful samples, or
        either side has zero successful samples.
      * inconclusive - Target, Kind or Unit differ between the two measurements; or the
        median change is smaller than Threshold; or the change points in the better
        direction but the after-side maximum is not at or below the before-side maximum
        (overlapping / noisy samples).
      * improved    - the after median is at most BeforeMedian * (1 - Threshold) and
        AfterMax is at or below BeforeMax.
      * regressed   - the after median is at least BeforeMedian * (1 + Threshold) and
        AfterMin is at or above BeforeMin.

    Medians follow the same lower-middle convention as Measure-WtNetworkDiagnostics. The
    comparison reads both measurements only; it never mutates them and takes no action.
    Criteria is a short rule description and Reason spells out the numbers; both are plain
    diagnostics text (the interface localizes its own wording).
.PARAMETER Before
    Measurement taken before the change, as produced by Measure-WtNetworkDiagnostics.
.PARAMETER After
    Measurement taken after the change.
.PARAMETER Threshold
    Relative median change that counts as a difference. Default 0.10 (10 %).
.PARAMETER MinimumSamples
    Successful samples each side needs before a classification is meaningful. Default 3.
.OUTPUTS
    System.Collections.Hashtable with Classification, BeforeMedian, AfterMedian, DeltaMs,
    DeltaPercent, Unit, Criteria and Reason. DeltaMs is AfterMedian - BeforeMedian in
    milliseconds and DeltaPercent is that change relative to BeforeMedian in percent
    (negative means faster); DeltaPercent is $null when the before median is zero.
.EXAMPLE
    $Result.Classification | Should -Be 'improved'
    Compare-WtMeasurements -Before $Before -After $After -Threshold 0.10 -MinimumSamples 3
#>
function Compare-WtMeasurements
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Before,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$After,
        [Parameter()][ValidateRange(0.0, 1.0)][double]$Threshold = 0.10,
        [Parameter()][ValidateRange(1, 100000)][int]$MinimumSamples = 3
    )

    $BeforeSamples = @(Get-WtMeasurementSampleList -Measurement $Before)
    $AfterSamples = @(Get-WtMeasurementSampleList -Measurement $After)
    $BeforeStats = Get-WtMeasurementStatistics -Samples $BeforeSamples
    $AfterStats = Get-WtMeasurementStatistics -Samples $AfterSamples

    $BeforeUnit = [string]$Before['Unit']
    $AfterUnit = [string]$After['Unit']

    if ($BeforeStats.Ok -lt 1 -or $AfterStats.Ok -lt 1)
    {
        $Reason = "before has $($BeforeStats.Ok) successful sample(s) of $($BeforeStats.Count), after has $($AfterStats.Ok) of $($AfterStats.Count)."

        return New-WtCompareResult -Classification 'insufficient' -Criteria $Script:WtCompareCriteria.NoSamples -Reason $Reason -BeforeMedian $BeforeStats.Median -AfterMedian $AfterStats.Median -Unit $AfterUnit
    }

    if ($BeforeStats.Ok -lt $MinimumSamples -or $AfterStats.Ok -lt $MinimumSamples)
    {
        $Reason = "before has $($BeforeStats.Ok) successful sample(s), after has $($AfterStats.Ok); MinimumSamples=$MinimumSamples."

        return New-WtCompareResult -Classification 'insufficient' -Criteria $Script:WtCompareCriteria.ShortOfSamples -Reason $Reason -BeforeMedian $BeforeStats.Median -AfterMedian $AfterStats.Median -Unit $AfterUnit
    }

    $BeforeTarget = [string]$Before['Target']
    $AfterTarget = [string]$After['Target']
    $BeforeKind = [string]$Before['Kind']
    $AfterKind = [string]$After['Kind']

    $Differences = @()
    if ($BeforeTarget -ne $AfterTarget) { $Differences += "target '$BeforeTarget' vs '$AfterTarget'" }
    if ($BeforeKind -ne $AfterKind) { $Differences += "kind '$BeforeKind' vs '$AfterKind'" }
    if ($BeforeUnit -ne $AfterUnit) { $Differences += "unit '$BeforeUnit' vs '$AfterUnit'" }

    if ($Differences.Count -gt 0)
    {
        $Reason = "$($Differences -join '; ')."

        return New-WtCompareResult -Classification 'inconclusive' -Criteria $Script:WtCompareCriteria.Mismatch -Reason $Reason -BeforeMedian $BeforeStats.Median -AfterMedian $AfterStats.Median -Unit $AfterUnit
    }

    $BeforeMedian = [double]$BeforeStats.Median
    $AfterMedian = [double]$AfterStats.Median
    $DeltaMs = [math]::Round($AfterMedian - $BeforeMedian, 4)
    $DeltaPercent = $null
    if ($BeforeMedian -ne 0)
    {
        $DeltaPercent = [math]::Round((($AfterMedian - $BeforeMedian) / $BeforeMedian) * 100, 4)
    }

    $Base = @{
        Unit         = $AfterUnit
        BeforeMedian = $BeforeMedian
        AfterMedian  = $AfterMedian
        DeltaMs      = $DeltaMs
        DeltaPercent = $DeltaPercent
    }

    $ThresholdText = Format-WtMeasurementNumber -Value ($Threshold * 100)
    $ChangeText = if ($null -ne $DeltaPercent) { "$(Format-WtMeasurementNumber -Value $DeltaMs) ms ($(Format-WtMeasurementNumber -Value $DeltaPercent) %)" } else { "$(Format-WtMeasurementNumber -Value $DeltaMs) ms" }

    if ($AfterMedian -lt $BeforeMedian -and $AfterMedian -le ($BeforeMedian * (1 - $Threshold)))
    {
        if ([double]$AfterStats.Max -le [double]$BeforeStats.Max)
        {
            $Reason = "before median $(Format-WtMeasurementNumber -Value $BeforeMedian) ms, after median $(Format-WtMeasurementNumber -Value $AfterMedian) ms, change $ChangeText; threshold $ThresholdText %; after max $(Format-WtMeasurementNumber -Value ([double]$AfterStats.Max)) ms <= before max $(Format-WtMeasurementNumber -Value ([double]$BeforeStats.Max)) ms."

            return New-WtCompareResult -Classification 'improved' -Criteria $Script:WtCompareCriteria.Improved -Reason $Reason @Base
        }

        $Reason = "after median $(Format-WtMeasurementNumber -Value $AfterMedian) ms beats before median $(Format-WtMeasurementNumber -Value $BeforeMedian) ms (threshold $ThresholdText %), but after max $(Format-WtMeasurementNumber -Value ([double]$AfterStats.Max)) ms exceeds before max $(Format-WtMeasurementNumber -Value ([double]$BeforeStats.Max)) ms."

        return New-WtCompareResult -Classification 'inconclusive' -Criteria $Script:WtCompareCriteria.OverlapBetter -Reason $Reason @Base
    }

    if ($AfterMedian -gt $BeforeMedian -and $AfterMedian -ge ($BeforeMedian * (1 + $Threshold)))
    {
        if ([double]$AfterStats.Min -ge [double]$BeforeStats.Min)
        {
            $Reason = "before median $(Format-WtMeasurementNumber -Value $BeforeMedian) ms, after median $(Format-WtMeasurementNumber -Value $AfterMedian) ms, change $ChangeText; threshold $ThresholdText %; after min $(Format-WtMeasurementNumber -Value ([double]$AfterStats.Min)) ms >= before min $(Format-WtMeasurementNumber -Value ([double]$BeforeStats.Min)) ms."

            return New-WtCompareResult -Classification 'regressed' -Criteria $Script:WtCompareCriteria.Regressed -Reason $Reason @Base
        }

        $Reason = "after median $(Format-WtMeasurementNumber -Value $AfterMedian) ms is worse than before median $(Format-WtMeasurementNumber -Value $BeforeMedian) ms (threshold $ThresholdText %), but after min $(Format-WtMeasurementNumber -Value ([double]$AfterStats.Min)) ms is below before min $(Format-WtMeasurementNumber -Value ([double]$BeforeStats.Min)) ms."

        return New-WtCompareResult -Classification 'inconclusive' -Criteria $Script:WtCompareCriteria.OverlapWorse -Reason $Reason @Base
    }

    $Reason = "median change $ChangeText is smaller than the threshold of $ThresholdText % (before $(Format-WtMeasurementNumber -Value $BeforeMedian) ms, after $(Format-WtMeasurementNumber -Value $AfterMedian) ms)."

    return New-WtCompareResult -Classification 'inconclusive' -Criteria $Script:WtCompareCriteria.BelowThreshold -Reason $Reason @Base
}
