# WindowsTweaker - metrics collector (one controlled owner).
#
# The collector owns every metric sample in the application. It has exactly one owner (a
# single runspace when the monitoring workspace is active), bounded concurrency (one
# snapshot at a time), separate fast and slow schedules (defaults: 1 s and 10 s),
# per-provider error isolation, a bounded event queue with a documented backpressure
# policy, and deterministic cancellation/shutdown.
#
# Providers:
#   * worker (Go): when the optional worker advertises `metric.snapshot`, it serves the
#     snapshot for the host platform it runs on (Linux reads /proc and /sys). The
#     PowerShell collector is a pure client of that snapshot in worker mode.
#   * powershell: fallback providers for Windows (CIM: Win32_OperatingSystem,
#     Win32_LogicalDisk, Win32_PerfFormattedData_PerfProc_Process for CPU, and the
#     adapter counters) and for Linux (the same /proc and /sys sources, read only).
#
# Monitoring never changes Windows settings, never resets counters, never enables
# services, never installs drivers and never downloads anything.

$Script:WtMonitorDefaults = @{
    FastSeconds = 1
    SlowSeconds = 10
    QueueCap = 512
    ProviderTimeoutMs = 5000
}

# One reusable worker client for the monitoring session (started for the first Go cycle,
# closed when the collector stops). This keeps the worker lifecycle under the same owner
# and avoids spawning a process per sample.
$Script:WtMonitorWorkerClient = $null

<#
.SYNOPSIS
    Returns the collection defaults (configurable, documented as starting settings).
#>
function Get-WtMonitorDefaultsInternal
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    return $Script:WtMonitorDefaults.Clone()
}

<#
.SYNOPSIS
    Reads the Linux /proc/stat counters (total, idle jiffies).
#>
function Read-WtProcStat
{
    [CmdletBinding()]
    [OutputType([object])]
    param ()

    $Data = $null
    try { $Data = [System.IO.File]::ReadAllText('/proc/stat') } catch { return $null }

    $Total = [uint64]0
    $Idle = [uint64]0
    foreach ($Line in @($Data -split "`n"))
    {
        if (-not $Line.StartsWith('cpu ')) { continue }
        $Fields = @($Line -split '\s+')
        for ($i = 1; $i -lt $Fields.Count; $i++)
        {
            $Total += [uint64]$Fields[$i]
            if ($i -eq 4) { $Idle = [uint64]$Fields[$i] }
        }
        return @{ Total = $Total; Idle = $Idle }
    }

    return $null
}

<#
.SYNOPSIS
    Collects one fast snapshot (CPU, memory, uptime, selected adapter counters).
.DESCRIPTION
    Returns a bounded array of validated metric samples. Providers are isolated: one
    provider's failure yields error-quality samples and does not stop the others. The
    CPU provider keeps its own baseline across calls; the first call reports unavailable
    (E_NO_BASELINE). Counter series report raw counters; rates are computed by the
    history/rate layer from monotonic elapsed time.
#>
function Get-WtMonitorFastSnapshot
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param
    (
        [Parameter(Mandatory = $false)][string]$Backend = 'Auto',
        [Parameter(Mandatory = $false)][hashtable]$CpuState = $null,
        [Parameter(Mandatory = $false)][string]$Adapter = '',
        [Parameter(Mandatory = $false)][long]$NowMs = 0,
        [Parameter(Mandatory = $false)][long]$MonotonicMs = 0
    )

    if (-not $NowMs) { $NowMs = [int64]([datetime]::UtcNow.ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,[datetimekind]::Utc)).TotalMilliseconds }
    if (-not $CpuState) { $CpuState = @{ Total = $null; Idle = $null; Wall = 0; Mono = 0 } }

    $Samples = [System.Collections.Generic.List[object]]::new()

    # --- CPU ------------------------------------------------------------------
    $Cpu = Read-WtProcStat
    if ($null -eq $Cpu)
    {
        $Samples.Add((New-WtMetricSample -Id 'host.cpu.utilization' -Type gauge -Unit '%' -Quality error -ErrorCode 'E_READ_FAILED' -Note 'no /proc/stat' -TsMs $NowMs))
    }
    elseif ($null -eq $CpuState.Total)
    {
        $CpuState.Total = $Cpu.Total
        $CpuState.Idle = $Cpu.Idle
        $CpuState.Wall = $NowMs
        $CpuState.Mono = $MonotonicMs
        $Samples.Add((New-WtMetricSample -Id 'host.cpu.utilization' -Type gauge -Unit '%' -Quality unavailable -ErrorCode 'E_NO_BASELINE' -Note 'first sample: utilization needs two reads' -TsMs $NowMs))
    }
    else
    {
        $MonoElapsed = $MonotonicMs - $CpuState.Mono
        if ($MonoElapsed -le 0) { $MonoElapsed = $NowMs - $CpuState.Wall }
        if ($MonoElapsed -le 0) { $MonoElapsed = 1 }

        $DtTotal = $Cpu.Total - $CpuState.Total
        $DtIdle = $Cpu.Idle - $CpuState.Idle
        $Reset = $DtTotal -gt ([uint64]::MaxValue / 2)

        $CpuState.Total = $Cpu.Total
        $CpuState.Idle = $Cpu.Idle
        $CpuState.Wall = $NowMs
        $CpuState.Mono = $MonotonicMs

        if ($Reset)
        {
            $Samples.Add((New-WtMetricSample -Id 'host.cpu.utilization' -Type gauge -Unit '%' -Quality unavailable -ErrorCode 'E_NO_BASELINE' -Note 'counter reset; new baseline' -TsMs $NowMs))
        }
        elseif ($DtTotal -eq 0)
        {
            $Samples.Add((New-WtMetricSample -Id 'host.cpu.utilization' -Type gauge -Unit '%' -Quality valid -Value ([double]0.0) -TsMs $NowMs))
        }
        else
        {
            $Util = (($DtTotal - $DtIdle) / $DtTotal) * 100.0
            $Samples.Add((New-WtMetricSample -Id 'host.cpu.utilization' -Type gauge -Unit '%' -Quality valid -Value ([double]$Util) -TsMs $NowMs))
        }
    }

    # --- memory ---------------------------------------------------------------
    $Mem = $null
    try { $Mem = [System.IO.File]::ReadAllText('/proc/meminfo') } catch { Write-WtLog -Level Debug -Message ('meminfo read failed: {0}' -f $_.Exception.Message) -NoConsole }
    if ($Mem)
    {
        $TotalKb = [long]0
        $AvailKb = [long]0
        foreach ($Line in @($Mem -split "`n"))
        {
            if ($Line.StartsWith('MemTotal:')) { $TotalKb = [long]($Line -split '\s+')[1] }
            elseif ($Line.StartsWith('MemAvailable:')) { $AvailKb = [long]($Line -split '\s+')[1] }
        }
        if ($TotalKb -gt 0)
        {
            $Samples.Add((New-WtMetricSample -Id 'host.mem.physical.totalBytes' -Type gauge -Unit bytes -Quality valid -Value ([double]($TotalKb * 1024)) -TsMs $NowMs))
            $Samples.Add((New-WtMetricSample -Id 'host.mem.physical.availableBytes' -Type gauge -Unit bytes -Quality valid -Value ([double]($AvailKb * 1024)) -TsMs $NowMs))
            $Samples.Add((New-WtMetricSample -Id 'host.mem.physical.usedBytes' -Type gauge -Unit bytes -Quality valid -Value ([double](($TotalKb - $AvailKb) * 1024)) -TsMs $NowMs))
        }
        else
        {
            $Samples.Add((New-WtMetricSample -Id 'host.mem.physical.totalBytes' -Type gauge -Unit bytes -Quality unavailable -ErrorCode 'E_READ_FAILED' -Note 'MemTotal missing' -TsMs $NowMs))
        }
    }
    else
    {
        $Samples.Add((New-WtMetricSample -Id 'host.mem.physical.totalBytes' -Type gauge -Unit bytes -Quality error -ErrorCode 'E_READ_FAILED' -Note 'no /proc/meminfo' -TsMs $NowMs))
    }

    # --- uptime --------------------------------------------------------------
    try
    {
        $Uptime = [System.IO.File]::ReadAllText('/proc/uptime').Trim()
        if ($Uptime)
        {
            $Seconds = [double]($Uptime -split '\s+')[0]
            $Samples.Add((New-WtMetricSample -Id 'host.uptime.seconds' -Type gauge -Unit seconds -Quality valid -Value $Seconds -TsMs $NowMs))
        }
    }
    catch
    {
        $Samples.Add((New-WtMetricSample -Id 'host.uptime.seconds' -Type gauge -Unit seconds -Quality error -ErrorCode 'E_READ_FAILED' -Note $_.Exception.Message -TsMs $NowMs))
    }

    # --- network counters (raw; rates computed by the rate layer) --------------
    if (Test-Path -LiteralPath '/sys/class/net')
    {
        $Interfaces = @(Get-ChildItem -LiteralPath '/sys/class/net' -Directory -ErrorAction Ignore | Where-Object { $_.Name -ne 'lo' })
        $LinkCount = 0
        foreach ($Iface in $Interfaces)
        {
            $Dims = @{ adapter = $Iface.Name }
            $Carrier = ''
            try { $Carrier = [System.IO.File]::ReadAllText((Join-Path $Iface.FullName 'carrier')).Trim() } catch { Write-WtLog -Level Debug -Message ('carrier read failed: {0}' -f $_.Exception.Message) -NoConsole }

            $Up = ($Carrier -eq '1')
            if ($Up) { $LinkCount++ }
            $Samples.Add((New-WtMetricSample -Id 'host.net.link.state' -Type gauge -Unit state -Quality valid -Value ([double]$(if ($Up) { 1 } else { 0 })) -Dims $Dims -Note $(if ($Up) { 'up' } else { 'down' }) -TsMs $NowMs))

            if ($Adapter -and $Adapter -ne $Iface.Name) { continue }

            $Rx = [uint64]0
            $Tx = [uint64]0
            try { $Rx = [uint64][System.IO.File]::ReadAllText((Join-Path $Iface.FullName 'statistics\rx_bytes')).Trim() } catch { Write-WtLog -Level Debug -Message ('rx_bytes read failed: {0}' -f $_.Exception.Message) -NoConsole }
            try { $Tx = [uint64][System.IO.File]::ReadAllText((Join-Path $Iface.FullName 'statistics\tx_bytes')).Trim() } catch { Write-WtLog -Level Debug -Message ('tx_bytes read failed: {0}' -f $_.Exception.Message) -NoConsole }

            $Samples.Add((New-WtMetricSample -Id 'host.net.rxBytes' -Type counter -Unit bytes -Quality valid -Value ([double]$Rx) -Dims $Dims -TsMs $NowMs))
            $Samples.Add((New-WtMetricSample -Id 'host.net.txBytes' -Type counter -Unit bytes -Quality valid -Value ([double]$Tx) -Dims $Dims -TsMs $NowMs))
        }

        $Samples.Add((New-WtMetricSample -Id 'host.net.links' -Type gauge -Unit count -Quality valid -Value ([double]$LinkCount) -TsMs $NowMs))
    }

    return @($Samples.ToArray())
}

<#
.SYNOPSIS
    Collects one slow snapshot (system volume free space).
#>
function Get-WtMonitorSlowSnapshot
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param
    (
        [Parameter(Mandatory = $false)][long]$NowMs = 0,
        [Parameter(Mandatory = $false)][string]$Disk = ''
    )

    if (-not $NowMs) { $NowMs = [int64]([datetime]::UtcNow.ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,[datetimekind]::Utc)).TotalMilliseconds }

    $RuntimeProfile = Get-WtRuntimeProfile
    $Samples = [System.Collections.Generic.List[object]]::new()

    $Drive = $Disk
    if (-not $Drive)
    {
        if ($RuntimeProfile.IsWindows)
        {
            $SystemDrive = [string](Get-WtEnvironment).OSName -replace '.*', ''
            if (-not $SystemDrive) { $SystemDrive = $env:SystemDrive }
            if (-not $SystemDrive) { $SystemDrive = 'C:' }
            $Drive = $SystemDrive.TrimEnd('\') + '\'
        }
        else
        {
            $Drive = '/'
        }
    }

    try
    {
        if ($RuntimeProfile.IsWindows)
        {
            $Volume = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($Drive.TrimEnd('\'))'" -ErrorAction Stop
            if ($Volume)
            {
                $Free = [double]$Volume.FreeSpace
                $Total = [double]$Volume.Size
                $Samples.Add((New-WtMetricSample -Id 'host.disk.system.freeBytes' -Type gauge -Unit bytes -Quality valid -Value $Free -Dims @{ disk = $Drive } -TsMs $NowMs))
                $Samples.Add((New-WtMetricSample -Id 'host.disk.system.totalBytes' -Type gauge -Unit bytes -Quality valid -Value $Total -Dims @{ disk = $Drive } -TsMs $NowMs))
            }
            else
            {
                $Samples.Add((New-WtMetricSample -Id 'host.disk.system.freeBytes' -Type gauge -Unit bytes -Quality unavailable -ErrorCode 'E_READ_FAILED' -Note "volume $Drive not found" -Dims @{ disk = $Drive } -TsMs $NowMs))
            }
        }
        else
        {
            $Free = [double]((Get-PSDrive -Name ([System.IO.Path]::GetPathRoot($Drive).TrimEnd('\'))) | Select-Object -ExpandProperty Free)
            $Used = [double]((Get-PSDrive -Name ([System.IO.Path]::GetPathRoot($Drive).TrimEnd('\'))) | Select-Object -ExpandProperty Used)
            $Samples.Add((New-WtMetricSample -Id 'host.disk.system.freeBytes' -Type gauge -Unit bytes -Quality valid -Value $Free -Dims @{ disk = $Drive } -TsMs $NowMs))
            $Samples.Add((New-WtMetricSample -Id 'host.disk.system.totalBytes' -Type gauge -Unit bytes -Quality valid -Value ($Free + $Used) -Dims @{ disk = $Drive } -TsMs $NowMs))
        }
    }
    catch
    {
        $Samples.Add((New-WtMetricSample -Id 'host.disk.system.freeBytes' -Type gauge -Unit bytes -Quality error -ErrorCode 'E_READ_FAILED' -Note $_.Exception.Message -Dims @{ disk = $Drive } -TsMs $NowMs))
    }

    return @($Samples.ToArray())
}

<#
.SYNOPSIS
    Runs one collection cycle (fast + slow depending on the tick) through a provider.
.DESCRIPTION
    Backend precedence: 'Go' uses the Go worker metric.snapshot (when it advertises the
    capability; otherwise the call fails with a stable code and the collector falls back
    to the PowerShell providers under Auto, or reports unavailable under Go). 'Auto'
    prefers the worker and falls back with a reason. The worker path merges the worker
    snapshot with slow samples (worker already returns disk for the root volume).
#>
function Invoke-WtMonitorCycle
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $false)][string]$Backend = 'Auto',
        [Parameter(Mandatory = $false)][switch]$Slow,
        [Parameter(Mandatory = $false)][hashtable]$CpuState = $null,
        [Parameter(Mandatory = $false)][string]$Adapter = '',
        [Parameter(Mandatory = $false)][string]$Disk = '',
        [Parameter(Mandatory = $false)][long]$NowMs = 0,
        [Parameter(Mandatory = $false)][long]$MonotonicMs = 0,
        [Parameter(Mandatory = $false)][scriptblock]$OnSample
    )

    if (-not $NowMs) { $NowMs = [int64]([datetime]::UtcNow.ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,[datetimekind]::Utc)).TotalMilliseconds }
    if (-not $MonotonicMs) { $MonotonicMs = $NowMs }

    $Samples = [System.Collections.Generic.List[object]]::new()
    $BackendUsed = $Backend
    $FallbackReason = ''

    # Try the Go worker first when requested, reusing the session-owned client.
    if ($Backend -in 'Auto', 'Go')
    {
        $Resolution = Resolve-WtWorkerBackend -Requested $Backend
        if ($Resolution.Backend -eq 'Go' -and @($Resolution.Worker.Capabilities) -contains 'metric.snapshot')
        {
            try
            {
                if (-not $Script:WtMonitorWorkerClient)
                {
                    $Script:WtMonitorWorkerClient = Start-WtWorkerClient
                }
                $Result = Invoke-WtWorkerRoundTrip -Client $Script:WtMonitorWorkerClient -Message @{ v = $Script:WtWorkerProtocolVersion; id = "cycle$NowMs"; op = 'metric.snapshot'; params = @{ scope = if ($Slow) { 'slow' } else { 'fast' } } } -TimeoutMs 5000
                if ($Result.kind -eq 'result')
                {
                    foreach ($Raw in @($Result.result.metrics))
                    {
                        $Sample = ConvertTo-WtWorkerMetricSample -Raw $Raw
                        if ($Sample) { $Samples.Add($Sample) }
                    }
                    $BackendUsed = 'Go'
                }
            }
            catch
            {
                $FallbackReason = $_.Exception.Message
                if ($Backend -eq 'Go')
                {
                    return @{ Ok = $false; Backend = 'Go'; Reason = "go worker metric snapshot failed: $FallbackReason"; Samples = @() }
                }
            }
        }
        elseif ($Backend -eq 'Go')
        {
            return @{ Ok = $false; Backend = 'Go'; Reason = 'the Go worker does not advertise metric.snapshot'; Samples = @() }
        }
    }

    if ($BackendUsed -eq 'Go' -and $Samples.Count -gt 0 -and -not $Slow)
    {
        return @{ Ok = $true; Backend = 'Go'; Reason = ''; Samples = @($Samples.ToArray()) }
    }

    # PowerShell providers (Auto fallback or explicit PowerShell; always for the slow
    # cycle, which the worker covers only for the root volume).
    $BackendUsed = if ($BackendUsed -eq 'Go') { 'Go+PowerShell' } else { 'PowerShell' }

    if (-not $Slow)
    {
        foreach ($Sample in @(Get-WtMonitorFastSnapshot -Backend 'PowerShell' -CpuState $CpuState -Adapter $Adapter -NowMs $NowMs -MonotonicMs $MonotonicMs))
        {
            $Samples.Add($Sample)
        }
    }
    else
    {
        foreach ($Sample in @(Get-WtMonitorSlowSnapshot -NowMs $NowMs -Disk $Disk))
        {
            $Samples.Add($Sample)
        }
    }

    return @{ Ok = $true; Backend = $BackendUsed; Reason = $FallbackReason; Samples = @($Samples.ToArray()) }
}

<#
.SYNOPSIS
    Converts one worker JSON metric into a validated PowerShell sample.
#>
function ConvertTo-WtWorkerMetricSample
{
    [CmdletBinding()]
    [OutputType([object])]
    param ([Parameter(Mandatory = $true)][object]$Raw)

    try
    {
        $Quality = [string]$Raw.quality
        $Value = $null
        if ($Quality -eq 'valid' -and $null -ne $Raw.value)
        {
            $Value = [double]$Raw.value
        }

        $Dims = @{}
        if ($Raw.dims)
        {
            foreach ($Prop in $Raw.dims.PSObject.Properties)
            {
                $Dims[$Prop.Name] = [string]$Prop.Value
            }
        }

        return (New-WtMetricSample -Id ([string]$Raw.id) -Type ([string]$Raw.type) -Unit ([string]$Raw.unit) `
                -TsMs ([long]$Raw.tsMs) -Quality $Quality -Dims $Dims -Provider ([string]$Raw.provider) `
                -Value $Value -ErrorCode ([string]$Raw.errorCode) -Note ([string]$Raw.note))
    }
    catch
    {
        return $null
    }
}

<#
.SYNOPSIS
    The collector runspace entry point (started by Start-WtMonitorCollector).
#>
function Start-WtMonitorCollector
{
    [CmdletBinding()]
    [OutputType([object])]
    param
    (
        [Parameter(Mandatory = $false)][int]$FastSeconds = 0,
        [Parameter(Mandatory = $false)][int]$SlowSeconds = 0,
        [Parameter(Mandatory = $false)][string]$Backend = 'Auto',
        [Parameter(Mandatory = $false)][string]$Adapter = '',
        [Parameter(Mandatory = $false)][string]$Disk = ''
    )

    $Defaults = Get-WtMonitorDefaultsInternal
    if (-not $FastSeconds) { $FastSeconds = [int]$Defaults.FastSeconds }
    if (-not $SlowSeconds) { $SlowSeconds = [int]$Defaults.SlowSeconds }

    # In-process collector: one owner (the UI frame loop), no extra processes or
    # runspaces. Sampling happens inside Update-WtMonitorWorkspace on the frame loop;
    # cancellation is simply not calling it, and Stop marks the lifecycle end. This is
    # deterministic, introduces no cross-runspace privacy issues and is the measured
    # "monitoring-enabled" overhead.
    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.MonitorCollector'
        Running = $true
        FastSeconds = $FastSeconds
        SlowSeconds = $SlowSeconds
        Backend = $Backend
        Adapter = $Adapter
        Disk = $Disk
        LastFast = [datetime]::UtcNow.AddSeconds(-$FastSeconds)
        LastSlow = [datetime]::UtcNow.AddSeconds(-$SlowSeconds)
        Watch = [System.Diagnostics.Stopwatch]::StartNew()
        Dropped = 0
        CpuState = @{ Total = $null; Idle = $null; Wall = 0; Mono = 0 }
    }
}

function Stop-WtMonitorCollector
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Collector)

    if ($Collector.Running)
    {
        $Collector.Running = $false
        $Collector.Watch.Stop()
    }

    if ($Script:WtMonitorWorkerClient)
    {
        Stop-WtWorkerClient -Client $Script:WtMonitorWorkerClient | Out-Null
        $Script:WtMonitorWorkerClient = $null
    }
}

function Receive-WtMonitorSnapshots
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param ([Parameter(Mandatory = $true)][object]$Collector)

    $Out = [System.Collections.Generic.List[object]]::new()
    $Item = $null
    while ($Collector.Queue.TryDequeue([ref]$Item))
    {
        $Out.Add($Item)
    }
    return @($Out.ToArray())
}
