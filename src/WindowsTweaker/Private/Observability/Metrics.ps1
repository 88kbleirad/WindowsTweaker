# WindowsTweaker - shared metric model (versioned contract).
#
# A metric sample is a typed, timestamped observation with quality semantics:
#
#   id        stable metric id (allowlist in dashboards and alerts)
#   type      gauge | counter
#   unit      SI-ish unit string ("%", "bytes", "bytes/s", "seconds", "count", ...)
#   tsMs      UTC epoch milliseconds (wall clock, for display and ordering)
#   quality   valid | unavailable | unsupported | stale | error
#   dims      bounded dimension map (adapter, disk, ...)
#   provider  stable provider name
#   value     number when available (never fabricated)
#   errorCode stable code; note human-readable reason
#
# Invariants enforced here:
#   * missing data is never replaced with zero: a sample either carries a value or a
#     quality with a reason;
#   * gaps are preserved: history keeps the timestamps of what was actually observed;
#     aggregations never fill a gap with a zero, an average, or an interpolated value;
#   * counter rates use elapsed monotonic time between two samples of the same series,
#     and handle reset, wrap, first sample and identity changes without producing a
#     negative rate;
#   * bytes/s stays distinct from bits/s (no implicit conversion).

$Script:WtMetricSchemaVersion = 1
$Script:WtMetricQualities = @('valid', 'unavailable', 'unsupported', 'stale', 'error')
$Script:WtMetricTypes = @('gauge', 'counter')

<#
.SYNOPSIS
    Validates one metric sample shape (data contract, used by every provider).
.DESCRIPTION
    Accepts both hashtables and objects. Returns an array of problem strings (empty when
    the sample satisfies the contract).
#>
function Test-WtMetricSample
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ([Parameter(Mandatory = $true)][object]$Sample)

    $Errors = [System.Collections.Generic.List[string]]::new()

    $Get = {
        param ([string]$Name)
        if ($Sample -is [System.Collections.IDictionary])
        {
            if ($Sample.Contains($Name)) { return $Sample[$Name] }
            return $null
        }
        if (@($Sample.PSObject.Properties.Name) -contains $Name) { return $Sample.$Name }
        return $null
    }

    $Id = [string]$(& $Get 'id')
    $Type = [string]$(& $Get 'type')
    $Unit = [string]$(& $Get 'unit')
    $Quality = [string]$(& $Get 'quality')
    $TsMs = [int64]$(& $Get 'tsMs')
    $Value = $(& $Get 'value')
    $Dims = $(& $Get 'dims')

    if ($Id -notmatch '^[a-z0-9][a-z0-9._-]*$') { $Errors.Add("id '$Id' is not a stable metric id.") }
    if ($Script:WtMetricTypes -notcontains $Type) { $Errors.Add("type '$Type' is not supported (gauge|counter).") }
    if ([string]::IsNullOrWhiteSpace($Unit)) { $Errors.Add('unit is required.') }
    if ($Script:WtMetricQualities -notcontains $Quality) { $Errors.Add("quality '$Quality' is not supported.") }
    if ($TsMs -le 0) { $Errors.Add('tsMs must be a positive UTC epoch millisecond timestamp.') }

    if ($Quality -eq 'valid')
    {
        if ($null -eq $Value)
        {
            $Errors.Add('a valid sample must carry a value.')
        }
        elseif ($Value -isnot [double] -and $Value -isnot [float] -and $Value -isnot [decimal] -and $Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [uint64] -and $Value -isnot [uint32] -and $Value -isnot [int16] -and $Value -isnot [uint16] -and $Value -isnot [sbyte] -and $Value -isnot [byte])
        {
            $Errors.Add('value must be numeric.')
        }
    }
    else
    {
        if ($null -ne $Value)
        {
            $Errors.Add('a non-valid sample must not carry a value (missing data is never zero).')
        }
        $Code = [string]$(& $Get 'errorCode')
        if (-not $Code) { $Errors.Add('a non-valid sample must carry a stable errorCode.') }
    }

    if ($null -ne $Dims)
    {
        if ($Dims -isnot [System.Collections.IDictionary])
        {
            $Errors.Add('dims must be a map.')
        }
        elseif ($Dims.Count -gt 8)
        {
            $Errors.Add('dims exceeds the 8-dimension bound.')
        }
        else
        {
            foreach ($Key in $Dims.Keys)
            {
                if ([string]::IsNullOrWhiteSpace([string]$Key) -or [string]$Key -notmatch '^[a-z0-9][a-z0-9_-]*$')
                {
                    $Errors.Add("dimension key '$Key' is invalid.")
                }
                $DimLength = ([string]$Dims[$Key]).Length
                if ($DimLength -gt 128)
                {
                    $Errors.Add("dimension '$Key' value exceeds 128 characters (got ${DimLength}: '$($Dims[$Key])').")
                }
            }
        }
    }

    return @($Errors.ToArray())
}

<#
.SYNOPSIS
    Builds a validated metric sample object.
#>
function New-WtMetricSample
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][ValidateSet('gauge', 'counter')][string]$Type,
        [Parameter(Mandatory = $true)][string]$Unit,
        [Parameter(Mandatory = $false)][long]$TsMs = 0,
        [Parameter(Mandatory = $false)][ValidateSet('valid', 'unavailable', 'unsupported', 'stale', 'error')][string]$Quality = 'valid',
        [Parameter(Mandatory = $false)][hashtable]$Dims = @{},
        [Parameter(Mandatory = $false)][string]$Provider = '',
        [Parameter(Mandatory = $false)][object]$Value = $null,
        [Parameter(Mandatory = $false)][string]$ErrorCode = '',
        [Parameter(Mandatory = $false)][string]$Note = ''
    )

    if (-not $TsMs) { $TsMs = [int64]([datetime]::UtcNow.ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,[datetimekind]::Utc)).TotalMilliseconds }
    if (-not $Provider) { $Provider = $Id.Split('.')[0] }

    $Sample = [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.MetricSample'
        id = $Id
        type = $Type
        unit = $Unit
        tsMs = $TsMs
        quality = $Quality
        dims = $Dims
        provider = $Provider
        value = $Value
        errorCode = $ErrorCode
        note = $Note
    }

    $Problems = Test-WtMetricSample -Sample $Sample
    if ($Problems.Count -gt 0)
    {
        throw "Invalid metric sample: $($Problems -join '; ')"
    }

    return $Sample
}

<#
.SYNOPSIS
    Computes the stable series key for a sample (id + sorted dimensions).
#>
function Get-WtMetricSeriesKey
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][object]$Sample)

    $Id = [string]$Sample.id
    $Dims = $Sample.dims
    if (-not $Dims -or @($Dims.Keys).Count -eq 0)
    {
        return $Id
    }

    $Parts = @($Dims.Keys | Sort-Object | ForEach-Object { "$_=$($Dims[$_])" })
    return "$Id|$($Parts -join '|')"
}

<#
.SYNOPSIS
    Computes a rate from two counter samples of the same series.
.DESCRIPTION
    Uses the actual elapsed time between the two samples' write times (monotonic where
    the collector records it). Returns $null when the elapsed time is not positive, when
    the identity changed, or when a reset or wrap is detected - never a negative rate.
    The value is per-second in the source unit (e.g. bytes/s from bytes).
#>
function ConvertTo-WtMetricRate
{
    [CmdletBinding()]
    [OutputType([object])]
    param
    (
        [Parameter(Mandatory = $false)][AllowNull()][object]$Previous,
        [Parameter(Mandatory = $true)][object]$Current,
        [Parameter(Mandatory = $false)][long]$MonotonicMs = 0
    )

    if ($null -eq $Previous -or $null -eq $Current) { return $null }
    if ([string]$Previous.id -ne [string]$Current.id -or [string]$Previous.type -ne 'counter' -or [string]$Current.type -ne 'counter')
    {
        return $null
    }

    if ((Get-WtMetricSeriesKey -Sample $Previous) -ne (Get-WtMetricSeriesKey -Sample $Current))
    {
        return $null
    }

    if ($null -eq $Previous.value -or $null -eq $Current.value)
    {
        return $null
    }

    $ElapsedMs = $MonotonicMs
    if ($ElapsedMs -le 0)
    {
        $ElapsedMs = [long]$Current.tsMs - [long]$Previous.tsMs
    }

    if ($ElapsedMs -le 0)
    {
        return $null
    }

    $Delta = [double]$Current.value - [double]$Previous.value

    # Reset or wrap: the counter went down (or up by more than a plausible wrap), so no
    # negative rate is emitted. A reset between samples means we have no true elapsed
    # measurement for the delta; report $null.
    if ($Delta -lt 0)
    {
        return $null
    }

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.MetricRate'
        id = [string]$Current.id
        key = (Get-WtMetricSeriesKey -Sample $Current)
        unitSuffix = '/s'
        valuePerSecond = $Delta * 1000 / $ElapsedMs
        elapsedMs = $ElapsedMs
        delta = $Delta
        reset = ($Delta -eq 0 -and [double]$Current.value -lt [double]$Previous.value)
    }
}

<#
.SYNOPSIS
    Returns whether a sample is usable for display (valid only).
#>
function Test-WtMetricUsable
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ([Parameter(Mandatory = $true)][object]$Sample)

    return ([string]$Sample.quality -eq 'valid' -and $null -ne $Sample.value)
}
