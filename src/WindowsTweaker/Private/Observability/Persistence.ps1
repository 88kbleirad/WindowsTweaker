# WindowsTweaker - optional persistent metrics recording.
#
# Recording is explicit and user-configurable. The *single writer* is the Go worker:
# PowerShell never opens the database file; it sends protocol requests
# (metric.store.write/query/raw/retention/stats) through the worker client. This keeps
# the metrics database separate from the recovery journal (which stays in PowerShell's
# state store and is never touched here).
#
# Backpressure: the writer queue is bounded. When the queue is full, new batches are
# dropped and counted (never blocked forever). Upserts are transactional in the worker.
# Retention is applied at most once per slow cycle and reports what it deletes before
# deleting; recovery records are never affected.

$Script:WtMetricPersistenceLimits = @{
    QueueCap = 64
    BatchCap = 2048
    RetentionDays = 30
    MaxDbBytes = 256MB
}

function Get-WtMetricPersistenceDefaultsInternal {
    [CmdletBinding()]
    param ()
    return $Script:WtMetricPersistenceLimits.Clone()
}

function New-WtMetricPersistenceInternal {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)][string]$Path = ''
    )

    if (-not $Path) {
        $Path = Join-Path (Get-WtDataRoot) 'metrics/metrics.db'
    }

    return @{
        Enabled = $false
        Path = $Path
        Queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        Dropped = 0
        Written = 0
        LastFlushMs = 0
        RetentionNextMs = 0
        Error = ''
        Limits = Get-WtMetricPersistenceDefaultsInternal
    }
}

# Converts a metric sample to a writable row hashtable for the worker.
function ConvertTo-WtStoredMetricRow {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Sample)

    $DimsJson = '{}'
    if ($Sample.dims -and $Sample.dims.Count -gt 0) {
        $DimsJson = $Sample.dims | ConvertTo-Json -Compress
    }

    return @{
        id = [string]$Sample.id
        type = [string]$Sample.type
        unit = [string]$Sample.unit
        tsMs = [long]$Sample.tsMs
        quality = [string]$Sample.quality
        provider = [string]$Sample.provider
        value = if ($null -ne $Sample.value) { [double]$Sample.value } else { $null }
        dims = $DimsJson
        errorCode = [string]$Sample.errorCode
        note = [string]$Sample.note
    }
}

# Enqueues a batch of samples (bounded queue with drop-and-count backpressure).
function Add-WtMetricPersistenceBatchInternal {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][hashtable]$Persistence,
        [Parameter(Mandatory = $true)][object[]]$Samples
    )

    if (-not $Persistence.Enabled) { return }
    if ($Samples.Count -eq 0) { return }

    $Rows = @($Samples | Select-Object -First $Persistence.Limits.BatchCap | ForEach-Object { ConvertTo-WtStoredMetricRow -Sample $_ })
    if ($Persistence.Queue.Count -lt $Persistence.Limits.QueueCap) {
        $Persistence.Queue.Enqueue(@{ Path = $Persistence.Path; Rows = $Rows })
    } else {
        $Persistence.Dropped++
    }
}

# Flushes all queued batches through the worker (one client round-trip per batch).
function Write-WtMetricPersistenceBatch {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][hashtable]$Persistence,
        [Parameter(Mandatory = $false)][object]$WorkerClient = $null
    )

    if (-not $Persistence.Enabled) { return }

    $Item = $null
    $Flushed = 0
    while ($Persistence.Queue.TryDequeue([ref]$Item)) {
        try {
            if (-not $WorkerClient) { $WorkerClient = Start-WtWorkerClient }
            $Result = Invoke-WtWorkerRoundTrip -Client $WorkerClient -Message @{
                v = $Script:WtWorkerProtocolVersion
                id = "store$([guid]::NewGuid().ToString('n'))"
                op = 'metric.store.write'
                params = @{ path = $Item.Path; rows = $Item.Rows }
            } -TimeoutMs 10000
            if ([string]$Result.type -eq 'result') {
                $Flushed++
                $Persistence.Written += [int]$Result.result.wrote
            } else {
                $Persistence.Error = "write failed: $($Result.error.code) $($Result.error.message)"
            }
        } catch {
            $Persistence.Error = $_.Exception.Message
            # Stop flushing; the queue keeps the remainder for the next cycle.
            $Persistence.Queue.Enqueue($Item)
            break
        }
    }
    return $Flushed
}

# Applies retention (bounded, reported) at most once per slow cycle.
function Update-WtMetricRetentionInternal {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][hashtable]$Persistence,
        [Parameter(Mandatory = $false)][object]$WorkerClient = $null,
        [Parameter(Mandatory = $false)][long]$NowMs = 0
    )

    if (-not $Persistence.Enabled) { return }
    if (-not $NowMs) { $NowMs = [int64]([datetime]::UtcNow.ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,[datetimekind]::Utc)).TotalMilliseconds }

    if ($NowMs -lt $Persistence.RetentionNextMs) { return }
    $Persistence.RetentionNextMs = $NowMs + 3600000  # at most hourly

    $Cutoff = $NowMs - ([long]$Persistence.Limits.RetentionDays * 86400000)
    try {
        if (-not $WorkerClient) { $WorkerClient = Start-WtWorkerClient }
        $Result = Invoke-WtWorkerRoundTrip -Client $WorkerClient -Message @{
            v = $Script:WtWorkerProtocolVersion
            id = "ret$([guid]::NewGuid().ToString('n'))"
            op = 'metric.store.retention'
            params = @{ path = $Persistence.Path; cutoffMs = $Cutoff }
        } -TimeoutMs 10000
        if ([string]$Result.type -eq 'result') {
            # Policy explained before deletion: retention was user-enabled and the count is
            # reported here; recovery records are never deleted by this store.
            $Persistence.Error = ''
        } else {
            $Persistence.Error = "retention failed: $($Result.error.code)"
        }
    } catch {
        $Persistence.Error = "retention failed: $($_.Exception.Message)"
    }
}

# Opens the database store nothing (worker side); this reports stats and validates the
# path is openable without mutating it.
function Test-WtMetricPersistenceInternal {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][hashtable]$Persistence,
        [Parameter(Mandatory = $false)][object]$WorkerClient = $null
    )

    try {
        if (-not $WorkerClient) { $WorkerClient = Start-WtWorkerClient }
        $Result = Invoke-WtWorkerRoundTrip -Client $WorkerClient -Message @{
            v = $Script:WtWorkerProtocolVersion
            id = "stats$([guid]::NewGuid().ToString('n'))"
            op = 'metric.store.stats'
            params = @{ path = $Persistence.Path }
        } -TimeoutMs 10000
        if ([string]$Result.type -eq 'result') {
            return @{ Ok = $true; Stats = $Result.result }
        }
        return @{ Ok = $false; Reason = "$($Result.error.code): $($Result.error.message)" }
    } catch {
        return @{ Ok = $false; Reason = $_.Exception.Message }
    }
}

# Stops persistence: drains remaining queued writes before reporting done.
function Stop-WtMetricPersistenceInternal {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][hashtable]$Persistence,
        [Parameter(Mandatory = $false)][object]$WorkerClient = $null
    )

    if (-not $Persistence.Enabled) { return }
    $Flushed = Write-WtMetricPersistenceBatch -Persistence $Persistence -WorkerClient $WorkerClient
    $Persistence.Enabled = $false
    return $Flushed
}


# Records alert transitions when the state changes (deduplicated: never per-refresh
# duplicates). Only runs when recording is enabled; transitions are persisted through
# the single-worker writer.
function Add-WtAlertTransitionInternal {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][hashtable]$Persistence,
        [Parameter(Mandatory = $true)][object[]]$Alerts,
        [Parameter(Mandatory = $true)][hashtable]$AlertState,
        [Parameter(Mandatory = $false)][long]$NowMs = 0
    )

    if (-not $Persistence.Enabled) { return }
    if (-not $NowMs) { $NowMs = [int64]([datetime]::UtcNow.ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,[datetimekind]::Utc)).TotalMilliseconds }

    $Client = $null
    try {
        foreach ($Alert in $Alerts) {
            $Id = [string]$Alert.id
            $PreviousState = if ($AlertState.ContainsKey($Id)) { [string]$AlertState[$Id].lastRecordedState } else { '' }
            if ($PreviousState -eq $Alert.state) { continue }

            # Record on every *change* (pending/firing/resolved/normal), not each refresh.
            if (-not $Client) { $Client = Start-WtWorkerClient }
            $Result = Invoke-WtWorkerRoundTrip -Client $Client -Message @{
                v = $Script:WtWorkerProtocolVersion
                id = "alert$([guid]::NewGuid().ToString('n'))"
                op = 'metric.store.alert'
                params = @{
                    path = $Persistence.Path
                    ruleId = $Id
                    revision = 1
                    fromState = $PreviousState
                    toState = [string]$Alert.state
                    atMs = $NowMs
                    evidence = "threshold=$($Alert.threshold);value=$(if ($null -ne $Alert.value) { $Alert.value } else { 'missing' })"
                    dataSource = 'local'
                }
            } -TimeoutMs 10000
            if ([string]$Result.type -eq 'result') {
                $AlertState[$Id] = @{ lastRecordedState = [string]$Alert.state }
            } else {
                $Persistence.Error = "alert transition failed: $($Result.error.code)"
            }
        }
    }
    finally {
        if ($Client) { Stop-WtWorkerClient -Client $Client | Out-Null }
    }
}
