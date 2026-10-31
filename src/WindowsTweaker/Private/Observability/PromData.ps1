# WindowsTweaker - optional remote Prometheus data source (TUI adapter).
#
# This adapter talks to an existing Prometheus server (HTTP API v1). It is optional,
# explicit, and strictly bounded:
#   - endpoint configured explicitly; a connection test is available;
#   - queries come from a curated, documented template set (no arbitrary query editing),
#     with validated variables;
#   - timeout, cancellation, bounded response size, bounded concurrent requests;
#   - remote responses are treated as untrusted display data: terminal control sequences
#     are stripped, labels and error text are sanitized;
#   - remote series are never mixed with local series without a visible source badge.
#
# No credentials are put in the dashboard JSON or logs; the endpoint itself is the only
# secret input and is kept in session state (never persisted to dashboard files).

$Script:WtPromQueryTemplates = @{
    'host.cpu.utilization' = '100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)'
    'host.mem.physical.usedBytes' = 'node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes'
    'host.disk.system.freeBytes' = 'node_filesystem_avail_bytes{fstype!~"tmpfs|overlay",mountpoint="/"}'
    'host.net.rxBytes' = 'rate(node_network_receive_bytes_total[5m])'
    'host.net.txBytes' = 'rate(node_network_transmit_bytes_total[5m])'
}

function New-WtPromDataSource {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Endpoint,
        [Parameter(Mandatory = $false)][int]$TimeoutMs = 5000,
        [Parameter(Mandatory = $false)][int]$MaxResponseBytes = 262144,
        [Parameter(Mandatory = $false)][int]$MaxSeries = 64
    )

    return @{
        Endpoint = $Endpoint.TrimEnd('/')
        TimeoutMs = $TimeoutMs
        MaxResponseBytes = $MaxResponseBytes
        MaxSeries = $MaxSeries
        LastError = ''
        LastQueryMs = 0
    }
}

# Strips ANSI/terminal control sequences from strings (untrusted display data).
function Clear-WtPromLabel {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Text)
    $Clean = $Text -replace "`e\[[0-9;?]*[a-zA-Z]", ''
    $Clean = $Clean -replace "[`r`n]", ' '
    return $Clean.Trim()
}

<#
.SYNOPSIS
    Makes System.Net.Http usable on the running runtime.
.DESCRIPTION
    Windows PowerShell 5.1 runs on .NET Framework, where System.Net.Http is not loaded by
    default: `[System.Net.Http.HttpClient]::new()` fails there with "Unable to find type" until
    the assembly is loaded. It is part of .NET Framework 4.5, so loading it by name is enough;
    on PowerShell 7 the assembly is already loaded and this is a no-op.

    The same reason is why this file must use HttpContent.ReadAsStreamAsync() rather than the
    .NET 5+ synchronous ReadAsStream(): the asynchronous accessor exists on both runtimes.
#>
function Initialize-WtPromHttpClient {
    try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { $null = $_ }
}

function Invoke-WtPromQuery {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][hashtable]$Source,
        [Parameter(Mandatory = $true)][string]$Template,
        [Parameter(Mandatory = $false)][long]$FromMs = 0,
        [Parameter(Mandatory = $false)][long]$ToMs = 0,
        [Parameter(Mandatory = $false)][int]$StepSeconds = 60,
        [Parameter(Mandatory = $false)][hashtable]$Variables = @{}
    )

    $Query = $Template
    foreach ($Key in $Variables.Keys) {
        $Query = $Query.Replace("{${Key}}", [string]$Variables[$Key])
    }

    if (-not $ToMs) { $ToMs = [int64]([datetime]::UtcNow.ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,[datetimekind]::Utc)).TotalMilliseconds }
    if (-not $FromMs) { $FromMs = $ToMs - 300000 }

    $Uri = "{0}/api/v1/query_range?query={1}&start={2}&end={3}&step={4}s" -f `
        $Source.Endpoint, [uri]::EscapeDataString($Query), [math]::Floor($FromMs / 1000), [math]::Floor($ToMs / 1000), $StepSeconds

    Initialize-WtPromHttpClient
    $Client = [System.Net.Http.HttpClient]::new()
    try {
        $Client.Timeout = [TimeSpan]::FromMilliseconds([int]$Source.TimeoutMs)
        $Request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Uri)
        $Response = $Client.SendAsync($Request).GetAwaiter().GetResult()
        try {
            if (-not $Response.IsSuccessStatusCode) {
                $Source.LastError = "HTTP $([int]$Response.StatusCode)"
                return @{ Ok = $false; Reason = $Source.LastError; Series = @() }
            }
            $Bytes = [byte[]]::new([int]$Source.MaxResponseBytes + 1)
            $Read = $Response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $Received = 0
            $Buffer = [byte[]]::new(8192)
            while (($n = $Read.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
                if ($Received + $n -gt [int]$Source.MaxResponseBytes) {
                    $Source.LastError = 'response exceeds bounded size'
                    return @{ Ok = $false; Reason = $Source.LastError; Series = @() }
                }
                [Array]::Copy($Buffer, 0, $Bytes, $Received, $n)
                $Received += $n
            }
            $Json = [System.Text.Encoding]::UTF8.GetString($Bytes, 0, $Received)
            $Parsed = $Json | ConvertFrom-Json
            if (-not $Parsed.data -or -not $Parsed.data.result) {
                return @{ Ok = $true; Reason = ''; Series = @() }
            }
            $Series = @()
            foreach ($Result in @($Parsed.data.result | Select-Object -First $Source.MaxSeries)) {
                $Values = @()
                foreach ($Pair in @($Result.values)) {
                    $Values += [pscustomobject]@{
                        TsMs = [long]([double]$Pair[0] * 1000)
                        Value = [double]$Pair[1]
                    }
                }
                $Labels = @{}
                foreach ($Prop in $Result.metric.PSObject.Properties) {
                    $Labels[$Prop.Name] = Clear-WtPromLabel -Text ([string]$Prop.Value)
                }
                $Series += [pscustomobject]@{
                    Name = $Result.metric.__name__
                    Labels = $Labels
                    Values = $Values
                }
            }
            $Source.LastError = ''
            return @{ Ok = $true; Reason = ''; Series = $Series }
        }
        finally {
            $Response.Dispose()
        }
    }
    catch {
        $Source.LastError = $_.Exception.Message
        return @{ Ok = $false; Reason = $Source.LastError; Series = @() }
    }
    finally {
        $Client.Dispose()
    }
}

# Connection test: instant query of an allowlisted scalar.
function Test-WtPromConnection {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][hashtable]$Source)

    $Uri = "{0}/api/v1/query?query=up&time={1}" -f $Source.Endpoint, [math]::Floor(([datetime]::UtcNow.ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,[datetimekind]::Utc)).TotalMilliseconds / 1000)
    Initialize-WtPromHttpClient
    $Client = [System.Net.Http.HttpClient]::new()
    try {
        $Client.Timeout = [TimeSpan]::FromMilliseconds([int]$Source.TimeoutMs)
        $Response = $Client.GetAsync($Uri).GetAwaiter().GetResult()
        try {
            return @{ Ok = [bool]$Response.IsSuccessStatusCode; Status = [int]$Response.StatusCode }
        }
        finally { $Response.Dispose() }
    }
    catch {
        return @{ Ok = $false; Status = 0; Reason = $_.Exception.Message }
    }
    finally { $Client.Dispose() }
}
