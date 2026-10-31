# WindowsTweaker - public metrics-persistence API (write/query via worker, read-only).

<#
.SYNOPSIS
    Enables recording. The Go worker is the single writer; PowerShell only sends protocol
    requests. Retention is configurable (days) and reported before it deletes anything.
#>
function Enable-WtMetricRecording
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $true)][object]$Persistence,
        [Parameter(Mandatory = $false)][int]$RetentionDays = 30
    )

    $Limits = Get-WtMetricPersistenceDefaultsInternal
    if ($RetentionDays -le 0 -or $RetentionDays -gt $Limits.RetentionDays * 12)
    {
        throw "Retention days must be between 1 and $($Limits.RetentionDays * 12)."
    }

    if ($PSCmdlet.ShouldProcess($Persistence.Path, 'enable metric recording'))
    {
        $Persistence.Limits.RetentionDays = $RetentionDays
        $Probe = Test-WtMetricPersistenceInternal -Persistence $Persistence
        if (-not $Probe.Ok)
        {
            throw "Metric recording cannot start: $($Probe.Reason)"
        }
        $Persistence.Enabled = $true
        return [pscustomobject]@{ Enabled = $true; Path = $Persistence.Path; RetentionDays = $RetentionDays }
    }
    return [pscustomobject]@{ Enabled = $false; Path = ''; RetentionDays = 0 }
}

<#
.SYNOPSIS
    Disables recording after flushing queued writes.
#>
function Disable-WtMetricRecording
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([psobject])]
    param ([Parameter(Mandatory = $true)][object]$Persistence)

    if ($PSCmdlet.ShouldProcess($Persistence.Path, 'disable metric recording'))
    {
        $Flushed = Stop-WtMetricPersistenceInternal -Persistence $Persistence
        return [pscustomobject]@{ Enabled = $false; FlushedBatches = $Flushed }
    }
    return [pscustomobject]@{ Enabled = $true; FlushedBatches = 0 }
}

<#
.SYNOPSIS
    Returns recording state (enabled, path, queue depth, written sample count).
#>
function Get-WtMetricRecording
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ([Parameter(Mandatory = $true)][object]$Persistence)

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.MetricRecording'
        Enabled = [bool]$Persistence.Enabled
        Path = [string]$Persistence.Path
        QueueDepth = $Persistence.Queue.Count
        Written = [long]$Persistence.Written
        Dropped = [long]$Persistence.Dropped
        RetentionDays = [int]$Persistence.Limits.RetentionDays
        Error = [string]$Persistence.Error
    }
}

<#
.SYNOPSIS
    Queries aggregated buckets from the persisted store (read-only, bounded).
#>
function Get-WtStoredMetricRange
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $true)][object]$Persistence,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $false)][long]$FromMs = 0,
        [Parameter(Mandatory = $false)][long]$ToMs = 0,
        [Parameter(Mandatory = $false)][long]$BucketMs = 0
    )

    if (-not $Persistence.Enabled)
    {
        throw 'Metric recording is not enabled.'
    }
    if (-not $ToMs) { $ToMs = [int64]([datetime]::UtcNow.ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,[datetimekind]::Utc)).TotalMilliseconds }

    $Client = Start-WtWorkerClient
    try
    {
        $Result = Invoke-WtWorkerRoundTrip -Client $Client -Message @{
            v = $Script:WtWorkerProtocolVersion
            id = "q$([guid]::NewGuid().ToString('n'))"
            op = 'metric.store.query'
            params = @{ path = $Persistence.Path; id = $Id; fromMs = $FromMs; toMs = $ToMs; bucketMs = $BucketMs }
        } -TimeoutMs 10000

        if ([string]$Result.type -ne 'result')
        {
            throw "Stored query failed: $($Result.error.code) $($Result.error.message)"
        }
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.StoredMetricRange'
            Id = $Id
            FromMs = $FromMs
            ToMs = $ToMs
            Buckets = @($Result.result.buckets)
        }
    }
    finally
    {
        Stop-WtWorkerClient -Client $Client | Out-Null
    }
}
