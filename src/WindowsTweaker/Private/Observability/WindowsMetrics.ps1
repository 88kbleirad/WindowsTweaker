# WindowsTweaker - local hardware measurements for the WinUI overview dashboard.
#
# Everything here is a *local* read: CIM classes and performance counters that Windows
# exposes on the machine itself. No Prometheus server, no Grafana, no exporter, no network
# service and no agent are involved, and nothing is installed or started.
#
# The one rule that shapes every provider: missing data is never reported as zero. Each
# reading carries a quality ('valid', 'unavailable', 'unsupported', 'error') and a note, so
# the interface can say "unavailable" instead of drawing a 0% bar. A GPU utilization
# counter is the normal case for that on a virtual machine, where Windows exposes the
# adapter but no GPU Engine counter set.
#
# Providers are isolated: a failure in one becomes an error-quality reading and never stops
# the others.

<#
.SYNOPSIS
    Reads CPU utilization on Windows as a percentage.
.DESCRIPTION
    Prefers the formatted performance counter (the same source Task Manager uses), and
    falls back to the WMI processor load. Returns a reading hashtable; when neither source
    can be read the quality is 'error' and the value is $null - never 0.
#>
function Get-WtWindowsCpuReading
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    try
    {
        $Counters = Get-Counter -Counter '\Processor Information(_Total)\% Processor Time' -ErrorAction Stop
        $Samples = @($Counters.CounterSamples)
        if ($Samples.Count -gt 0)
        {
            $Value = [double]$Samples[0].CookedValue
            if ($Value -lt 0) { $Value = 0 }
            if ($Value -gt 100) { $Value = 100 }
            return @{ quality = 'valid'; percent = $Value; note = 'Processor Information(_Total)\% Processor Time' }
        }
    }
    catch
    {
        Write-WtLog -Level Debug -Message ("CPU counter read failed: {0}" -f $_.Exception.Message) -NoConsole
    }

    try
    {
        $Cpus = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Where-Object { $null -ne $_.LoadPercentage })
        if ($Cpus.Count -gt 0)
        {
            $Total = 0.0
            foreach ($Cpu in $Cpus) { $Total += [double]$Cpu.LoadPercentage }
            return @{ quality = 'valid'; percent = [double]($Total / $Cpus.Count); note = 'Win32_Processor.LoadPercentage' }
        }
    }
    catch
    {
        Write-WtLog -Level Debug -Message ("CPU CIM read failed: {0}" -f $_.Exception.Message) -NoConsole
    }

    return @{ quality = 'error'; percent = $null; note = 'E_READ_FAILED' }
}

<#
.SYNOPSIS
    Reads physical memory on Windows, in bytes.
#>
function Get-WtWindowsMemoryReading
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    try
    {
        $Os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $TotalKb = [double]$Os.TotalVisibleMemorySize
        $FreeKb = [double]$Os.FreePhysicalMemory
        if ($TotalKb -gt 0)
        {
            $Total = $TotalKb * 1024
            $Free = $FreeKb * 1024
            return @{
                quality        = 'valid'
                totalBytes     = $Total
                availableBytes = $Free
                usedBytes      = [double]($Total - $Free)
                note           = 'Win32_OperatingSystem'
            }
        }
    }
    catch
    {
        Write-WtLog -Level Debug -Message ("memory CIM read failed: {0}" -f $_.Exception.Message) -NoConsole
    }

    return @{ quality = 'error'; totalBytes = $null; availableBytes = $null; usedBytes = $null; note = 'E_READ_FAILED' }
}

<#
.SYNOPSIS
    Reads the GPU adapter and its utilization on Windows when the machine exposes it.
.DESCRIPTION
    The adapter name comes from Win32_VideoController and is reported on a virtual machine
    too (QEMU exposes e.g. a basic display adapter). Utilization comes from the GPU Engine
    performance counter set, which most virtual machines do not publish; when it is absent
    the reading is 'unavailable' with the note E_NO_COUNTER and the value stays $null, so
    the interface can say "utilization unavailable" rather than drawing 0%.
#>
function Get-WtGpuAdapterReading
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    $Name = ''
    $NameNote = ''
    try
    {
        $Adapters = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
        if ($Adapters.Count -gt 0)
        {
            # A machine can expose more than one controller (an integrated one plus a
            # virtual/remote one). Prefer the first adapter that is not the basic display
            # driver, because that is the one doing real work.
            $Chosen = @($Adapters | Where-Object { $_.Name -and $_.Name -notmatch 'Basic Display' })[0]
            if (-not $Chosen) { $Chosen = $Adapters[0] }
            $Name = [string]$Chosen.Name
            $NameNote = [string]$Chosen.PNPDeviceID
        }
    }
    catch
    {
        Write-WtLog -Level Debug -Message ("GPU CIM read failed: {0}" -f $_.Exception.Message) -NoConsole
    }

    $Utilization = $null
    $Quality = 'unavailable'
    $Note = 'E_NO_COUNTER'

    try
    {
        $Counters = Get-Counter -Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop
        $Values = @($Counters.CounterSamples | ForEach-Object { [double]$_.CookedValue })
        if ($Values.Count -gt 0)
        {
            $Sum = 0.0
            foreach ($Value in $Values) { if ($Value -gt 0) { $Sum += $Value } }
            if ($Sum -gt 100) { $Sum = 100 }
            $Utilization = $Sum
            $Quality = 'valid'
            $Note = 'GPU Engine(*)\Utilization Percentage'
        }
    }
    catch
    {
        Write-WtLog -Level Debug -Message ("GPU counter read failed: {0}" -f $_.Exception.Message) -NoConsole
    }

    if (-not $Name -and $Quality -ne 'valid')
    {
        return @{ quality = 'unavailable'; name = ''; utilizationPercent = $null; note = $Note }
    }

    return @{
        quality            = $Quality
        name               = $Name
        utilizationPercent = $Utilization
        note               = $Note
        deviceId           = $NameNote
    }
}

<#
.SYNOPSIS
    Returns the metric samples a Windows host can read locally.
.DESCRIPTION
    The Windows counterpart of the /proc and /sys providers: CPU and memory from the
    formatted counters / CIM, exposed as the same metric ids so the dashboard, the alert
    rules and the interface all read one vocabulary. The system volume samples come from
    the slow snapshot, which already has a Windows branch.
#>
function Get-WtWindowsFastSnapshot
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param
    (
        [Parameter(Mandatory = $false)][long]$NowMs = 0
    )

    if (-not $NowMs) { $NowMs = [int64]([datetime]::UtcNow.ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,[datetimekind]::Utc)).TotalMilliseconds }

    $Samples = [System.Collections.Generic.List[object]]::new()

    $Cpu = Get-WtWindowsCpuReading
    if ($Cpu.quality -eq 'valid')
    {
        $Samples.Add((New-WtMetricSample -Id 'host.cpu.utilization' -Type gauge -Unit '%' -Quality valid -Value ([double]$Cpu.percent) -Provider 'windows' -Note $Cpu.note -TsMs $NowMs))
    }
    else
    {
        $Samples.Add((New-WtMetricSample -Id 'host.cpu.utilization' -Type gauge -Unit '%' -Quality error -ErrorCode 'E_READ_FAILED' -Provider 'windows' -Note $Cpu.note -TsMs $NowMs))
    }

    $Memory = Get-WtWindowsMemoryReading
    if ($Memory.quality -eq 'valid')
    {
        $Samples.Add((New-WtMetricSample -Id 'host.mem.physical.totalBytes' -Type gauge -Unit bytes -Quality valid -Value ([double]$Memory.totalBytes) -Provider 'windows' -Note $Memory.note -TsMs $NowMs))
        $Samples.Add((New-WtMetricSample -Id 'host.mem.physical.availableBytes' -Type gauge -Unit bytes -Quality valid -Value ([double]$Memory.availableBytes) -Provider 'windows' -TsMs $NowMs))
        $Samples.Add((New-WtMetricSample -Id 'host.mem.physical.usedBytes' -Type gauge -Unit bytes -Quality valid -Value ([double]$Memory.usedBytes) -Provider 'windows' -TsMs $NowMs))
    }
    else
    {
        $Samples.Add((New-WtMetricSample -Id 'host.mem.physical.totalBytes' -Type gauge -Unit bytes -Quality error -ErrorCode 'E_READ_FAILED' -Provider 'windows' -Note $Memory.note -TsMs $NowMs))
    }

    try
    {
        $Uptime = [double]((Get-Date) - (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime).TotalSeconds
        if ($Uptime -ge 0)
        {
            $Samples.Add((New-WtMetricSample -Id 'host.uptime.seconds' -Type gauge -Unit seconds -Quality valid -Value $Uptime -Provider 'windows' -TsMs $NowMs))
        }
    }
    catch
    {
        Write-WtLog -Level Debug -Message ("uptime CIM read failed: {0}" -f $_.Exception.Message) -NoConsole
    }

    return @($Samples.ToArray())
}

<#
.SYNOPSIS
    Finds a sample's quality and value by metric id.
#>
function Get-WtOverviewReading
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Samples,
        [Parameter(Mandatory = $true)][string]$Id
    )

    $Match = @($Samples | Where-Object { [string]$_.id -eq $Id })
    if ($Match.Count -eq 0)
    {
        return @{ quality = 'unavailable'; value = $null; note = 'E_NOT_COLLECTED' }
    }

    # Prefer a usable sample when the same id appears more than once.
    $Valid = @($Match | Where-Object { [string]$_.quality -eq 'valid' })
    $Chosen = if ($Valid.Count -gt 0) { $Valid[0] } else { $Match[0] }
    return @{ quality = [string]$Chosen.quality; value = $Chosen.value; note = [string]$Chosen.note }
}

<#
.SYNOPSIS
    Builds the read-only overview document the WinUI dashboard renders.
.DESCRIPTION
    One bounded collection pass (fast + slow providers), shaped per card. Every card keeps
    its own quality and note; a value that could not be read is $null, never 0, so the
    interface can distinguish "idle" from "unknown".
#>
function Get-WtMetricOverviewSnapshot
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $false)][string]$Drive = ''
    )

    $NowMs = [int64]([datetime]::UtcNow.ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,[datetimekind]::Utc)).TotalMilliseconds

    $Fast = @(Get-WtMonitorFastSnapshot -NowMs $NowMs)
    $Slow = @(Get-WtMonitorSlowSnapshot -NowMs $NowMs -Disk $Drive)
    $All = @($Fast + $Slow)

    $Cpu = Get-WtOverviewReading -Samples $All -Id 'host.cpu.utilization'
    $Total = Get-WtOverviewReading -Samples $All -Id 'host.mem.physical.totalBytes'
    $Used = Get-WtOverviewReading -Samples $All -Id 'host.mem.physical.usedBytes'
    $Available = Get-WtOverviewReading -Samples $All -Id 'host.mem.physical.availableBytes'
    $DiskTotal = Get-WtOverviewReading -Samples $All -Id 'host.disk.system.totalBytes'
    $DiskFree = Get-WtOverviewReading -Samples $All -Id 'host.disk.system.freeBytes'
    $Gpu = Get-WtGpuAdapterReading

    $DiskDrive = $Drive
    if (-not $DiskDrive)
    {
        $DiskDrive = (Get-WtSystemVolumeDriveLetter)
    }

    return @{
        tsMs   = $NowMs
        cpu    = @{
            quality = $Cpu.quality
            percent = $Cpu.value
            note    = $Cpu.note
        }
        memory = @{
            quality        = $Total.quality
            totalBytes     = $Total.value
            usedBytes      = $Used.value
            availableBytes = $Available.value
            note           = $Total.note
        }
        disk   = @{
            quality    = $DiskTotal.quality
            drive      = $DiskDrive
            totalBytes = $DiskTotal.value
            freeBytes  = $DiskFree.value
            note       = $DiskTotal.note
        }
        gpu    = @{
            quality            = $Gpu.quality
            name               = $Gpu.name
            utilizationPercent = $Gpu.utilizationPercent
            note               = $Gpu.note
        }
    }
}

<#
.SYNOPSIS
    Returns the drive letter of the Windows system volume, with a trailing backslash.
.DESCRIPTION
    The system volume is where Windows itself is installed, which is not always C: - the
    environment and the volume's own identity are both consulted, and C: is only the last
    resort.
#>
function Get-WtSystemVolumeDriveLetter
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    try
    {
        if (-not (Get-WtRuntimeProfile).IsWindows)
        {
            # The root volume on a POSIX host; there is no drive letter to report.
            return '/'
        }

        $SystemDrive = [string]$env:SystemDrive
        if (-not $SystemDrive)
        {
            $SystemDrive = [string]((Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).SystemDrive)
        }
        if (-not $SystemDrive) { $SystemDrive = 'C:' }
        return ($SystemDrive.TrimEnd('\') + '\')
    }
    catch
    {
        return 'C:\'
    }
}
