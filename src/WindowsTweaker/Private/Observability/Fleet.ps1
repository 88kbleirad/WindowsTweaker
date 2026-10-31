# WindowsTweaker - read-only multi-host overview (fleet).
#
# Hosts come from *explicitly configured* Prometheus data sources: each source is a
# registered endpoint, and targets are discovered from that source's `up` series
# (label_values(up, instance) and the up metric itself). Nothing scans networks,
# installs agents, enables remote management or collects credentials.
#
# Stable identity = data source + instance label. Two hosts with the same hostname on
# different data sources are different hosts; they are never merged.
#
# Host conditions are derived solely from observations:
#   healthy        - source reachable, `up` == 1, metrics fresh
#   failed-scrape  - source reachable, `up` == 0 (does NOT prove the host is powered off)
#   stale          - source reachable, last observation older than the staleness window
#   missing-target - instance disappeared from the source's target list
#   unreachable-ds - the data source endpoint itself failed (timeout/HTTP error)
#   unknown        - no usable observation at all
#
# Read-only: viewing a remote host never authorizes modifying it.

$Script:WtFleetDefaults = @{
    MaxSources = 8
    MaxTargetsPerSource = 128
    StaleAfterSeconds = 120
    QueryTimeoutMs = 5000
    CacheSeconds = 10
}

function New-WtFleetState {
    [CmdletBinding()]
    param ()

    return @{
        Sources = @()          # @{ id, endpoint, alias }
        Hosts = @{}            # "sourceId|instance" -> host row
        LastRefreshUtc = $null
        CacheSeconds = [int]$Script:WtFleetDefaults.CacheSeconds
        Errors = [System.Collections.Generic.List[string]]::new()
    }
}

function Register-WtFleetSource {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][hashtable]$Fleet,
        [Parameter(Mandatory = $true)][string]$Endpoint,
        [Parameter(Mandatory = $false)][string]$Alias = ''
    )

    if ($Fleet.Sources.Count -ge [int]$Script:WtFleetDefaults.MaxSources) {
        throw "At most $($Script:WtFleetDefaults.MaxSources) data sources are supported."
    }
    if (-not $Alias) { $Alias = $Endpoint }

    $Id = "ds$([guid]::NewGuid().ToString('n').Substring(0,8))"
    $Source = @{ Id = $Id; Endpoint = $Endpoint.TrimEnd('/'); Alias = $Alias }
    $Fleet.Sources += $Source
    return $Source
}

# Fetches the list of instances of one data source (bounded).
function Get-WtFleetInstances {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][hashtable]$Source,
        [Parameter(Mandatory = $false)][hashtable]$PromSource = $null
    )

    if (-not $PromSource) { $PromSource = New-WtPromDataSource -Endpoint $Source.Endpoint }
    $InstanceQuery = 'label_values(up, instance)'
    $Result = Invoke-WtPromQuery -Source $PromSource -Template $InstanceQuery -StepSeconds 60
    if (-not $Result.Ok) {
        return @{ Ok = $false; Reason = $Result.Reason; Instances = @() }
    }

    # label_values returns vector results with the instance label on each result.
    $Instances = @()
    foreach ($S in $Result.Series) {
        foreach ($Key in $S.Labels.Keys) {
            if ($Key -eq 'instance') { $Instances += $S.Labels[$Key] }
        }
    }
    $Instances = @($Instances | Sort-Object -Unique | Select-Object -First $Script:WtFleetDefaults.MaxTargetsPerSource)
    return @{ Ok = $true; Reason = ''; Instances = $Instances }
}

# Queries `up` and per-instance metric values for one host.
function Get-WtFleetHostObservation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][hashtable]$Source,
        [Parameter(Mandatory = $true)][string]$Instance,
        [Parameter(Mandatory = $false)][hashtable]$PromSource = $null
    )

    if (-not $PromSource) { $PromSource = New-WtPromDataSource -Endpoint $Source.Endpoint }

    $Variables = @{ instance = $Instance }
    $Up = Invoke-WtPromQuery -Source $PromSource -Template 'up{instance="{instance}"}' -StepSeconds 60 -Variables $Variables
    if (-not $Up.Ok) {
        return @{ Ok = $false; Reason = $Up.Reason; Condition = 'unreachable-ds' }
    }

    # The `up` series value (0 or 1) and its latest timestamp.
    $Freshness = [double]0
    $UpValue = $null
    if ($Up.Series.Count -gt 0) {
        $Series = $Up.Series[0]
        if ($Series.Values.Count -gt 0) {
            $Last = $Series.Values[$Series.Values.Count - 1]
            $UpValue = [double]$Last.Value
            $Freshness = $Last.TsMs
        }
    }

    if ($null -eq $UpValue) {
        return @{ Ok = $true; Reason = ''; Condition = 'missing-target'; UpValue = $null; FreshnessMs = $Freshness }
    }

    $Condition = 'healthy'
    if ($UpValue -lt 0.5) { $Condition = 'failed-scrape' }

    # Freshness: the up sample age.
    $NowMs = [int64]([datetime]::UtcNow.ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,[datetimekind]::Utc)).TotalMilliseconds
    if (($NowMs - $Freshness) / 1000 -gt [int]$Script:WtFleetDefaults.StaleAfterSeconds) {
        if ($Condition -eq 'healthy') { $Condition = 'stale' }
    }

    # Best-effort metric observations (only what the source actually exposes).
    $Metrics = @{}
    $Candidates = @(
        @{ Name = 'host.cpu.utilization'; Query = '100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)' }
        @{ Name = 'host.mem.physical.usedBytes'; Query = 'node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes' }
        @{ Name = 'host.disk.system.freeBytes'; Query = 'node_filesystem_avail_bytes{fstype!~"tmpfs|overlay",mountpoint="/"}' }
        @{ Name = 'host.net.rxBytes'; Query = 'sum by (instance) (rate(node_network_receive_bytes_total[5m]))' }
        @{ Name = 'host.net.txBytes'; Query = 'sum by (instance) (rate(node_network_transmit_bytes_total[5m]))' }
    )
    foreach ($C in $Candidates) {
        $R = Invoke-WtPromQuery -Source $PromSource -Template $C.Query -StepSeconds 60 -Variables $Variables
        if ($R.Ok -and $R.Series.Count -gt 0 -and $R.Series[0].Values.Count -gt 0) {
            $Series = $R.Series[0]
            $Last = $Series.Values[$Series.Values.Count - 1]
            $Metrics[$C.Name] = [double]$Last.Value
        }
    }

    return @{
        Ok = $true
        Condition = $Condition
        UpValue = [double]$UpValue
        FreshnessMs = $Freshness
        Metrics = $Metrics
        LastObservationMs = $Freshness
    }
}

# Refresh all sources and hosts (bounded, cached).
function Update-WtFleet {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][hashtable]$Fleet,
        [Parameter(Mandatory = $false)][switch]$Force
    )

    $Now = [datetime]::UtcNow
    if (-not $Force -and $Fleet.LastRefreshUtc -and ($Now - $Fleet.LastRefreshUtc).TotalSeconds -lt $Fleet.CacheSeconds) {
        return
    }

    $Fleet.Hosts = @{}
    $Fleet.Errors.Clear()
    $Fleet.LastRefreshUtc = $Now

    foreach ($Source in $Fleet.Sources) {
        $PromSource = New-WtPromDataSource -Endpoint $Source.Endpoint
        $Instances = Get-WtFleetInstances -Source $Source -PromSource $PromSource
        if (-not $Instances.Ok) {
            # Source unreachable: keep every previously known host as unreachable-ds.
            foreach ($Key in @($Fleet.Hosts.Keys)) {
                if ($Key.StartsWith("$($Source.Id)|")) {
                    $Fleet.Hosts[$Key].Condition = 'unreachable-ds'
                }
            }
            $Fleet.Errors.Add("$($Source.Alias): $($Instances.Reason)")
            continue
        }

        foreach ($Instance in $Instances.Instances) {
            $Observation = Get-WtFleetHostObservation -Source $Source -Instance $Instance -PromSource $PromSource
            $Key = "$($Source.Id)|$Instance"
            $Fleet.Hosts[$Key] = @{
                SourceId = $Source.Id
                SourceAlias = $Source.Alias
                Instance = $Instance
                Alias = ''                       # user-defined alias
                Condition = $Observation.Condition
                UpValue = $Observation.UpValue
                FreshnessMs = $Observation.FreshnessMs
                Metrics = $Observation.Metrics
                LastObservationMs = $Observation.LastObservationMs
            }
        }
    }
}

# Host table rows (sorted, filterable).
function Get-WtFleetRows {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][hashtable]$Fleet,
        [Parameter(Mandatory = $false)][string]$Filter = '',
        [Parameter(Mandatory = $false)][string]$Sort = 'alias'
    )

    $Rows = @()
    foreach ($Key in $Fleet.Hosts.Keys) {
        $H = $Fleet.Hosts[$Key]
        $Display = if ($H.Alias) { $H.Alias } else { "$($H.SourceAlias): $($H.Instance)" }
        $Rows += [pscustomobject]@{
            Id = $Key
            Display = $Display
            SourceAlias = $H.SourceAlias
            Instance = $H.Instance
            Condition = $H.Condition
            FreshnessMs = $H.FreshnessMs
            Metrics = $H.Metrics
        }
    }

    if ($Filter) {
        $Rows = @($Rows | Where-Object { $_.Display -like "*$Filter*" -or $_.Condition -like "*$Filter*" })
    }

    switch ($Sort) {
        'condition' { $Rows = @($Rows | Sort-Object Condition, Display) }
        'freshness' { $Rows = @($Rows | Sort-Object -Property @{ Expression = { $_.FreshnessMs }; Descending = $true }) }
        default { $Rows = @($Rows | Sort-Object Display) }
    }

    return $Rows
}
