# WindowsTweaker - public observability API (dashboards and monitoring facts).

<#
.SYNOPSIS
    Lists dashboard ids (built-ins first, then imported ones).
#>
function Get-WtDashboardList
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param ()

    $Ids = Get-WtDashboardIdsInternal
    return @($Ids | ForEach-Object { [pscustomobject]@{ id = $_ } })
}

<#
.SYNOPSIS
    Returns one dashboard document (read-only).
#>
function Get-WtDashboard
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ([Parameter(Mandatory = $true)][string]$Id)

    $Dashboard = Read-WtDashboardInternal -Id $Id
    if (-not $Dashboard)
    {
        throw "The dashboard '$Id' does not exist."
    }
    return $Dashboard
}

<#
.SYNOPSIS
    Imports a dashboard document (validated, stored locally).
.DESCRIPTION
    The document must satisfy the dashboard schema (allowlisted metrics and aggregations,
    bounded size, unique panel ids). Importing never executes anything and never changes
    system settings.
#>
function Import-WtDashboard
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][switch]$Force
    )

    $Result = Import-WtDashboardInternal -Path $Path -Force:$Force
    if (-not $Result.Ok)
    {
        throw "Dashboard import failed: $($Result.Errors -join '; ')"
    }

    if ($PSCmdlet.ShouldProcess((Split-Path -Leaf $Path), 'import dashboard'))
    {
        return [pscustomobject]@{
            Imported = $true
            Path = $Result.Target
        }
    }
    return [pscustomobject]@{ Imported = $false; Path = '' }
}

<#
.SYNOPSIS
    Exports a dashboard document to a path.
.DESCRIPTION
    The exported document contains only the dashboard definition; it never includes
    personal metrics or operation history.
#>
function Export-WtDashboard
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][switch]$Force
    )

    if (-not $Force -and (Test-Path -LiteralPath $Path))
    {
        throw "The export path already exists: $Path"
    }

    $Dashboard = Read-WtDashboardInternal -Id $Id
    if (-not $Dashboard)
    {
        throw "The dashboard '$Id' does not exist."
    }

    if ($PSCmdlet.ShouldProcess("$Id -> $Path", 'export dashboard'))
    {
        $Json = ConvertTo-WtJson -InputObject $Dashboard -Depth 12
        Write-WtTextFile -Path $Path -Value $Json
        return $Path
    }
    return ''
}

<#
.SYNOPSIS
    Returns the monitoring defaults (fast/slow schedules, queue cap, timeout).
#>
function Get-WtMonitorDefaults
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ()

    $Defaults = Get-WtMonitorDefaultsInternal
    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.MonitorDefaults'
        FastSeconds = [int]$Defaults.FastSeconds
        SlowSeconds = [int]$Defaults.SlowSeconds
        QueueCap = [int]$Defaults.QueueCap
        ProviderTimeoutMs = [int]$Defaults.ProviderTimeoutMs
    }
}

<#
.SYNOPSIS
    Measures one monitoring cycle's overhead (sampled on this machine).
.DESCRIPTION
    Runs N fast cycles against the PowerShell providers and reports elapsed time per
    cycle, error summary, and the worker's memory footprint when the Go backend is used.
    This is a measurement, not a guarantee; conditions (host, PowerShell, backend) are
    reported with the result.
#>
function Measure-WtMonitorCycle
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $false)][ValidateRange(1, 200)][int]$Cycles = 20,
        [Parameter(Mandatory = $false)][ValidateSet('Auto', 'Go', 'PowerShell')][string]$Backend = 'PowerShell'
    )

    $CpuState = @{ Total = $null; Idle = $null; Wall = 0; Mono = 0 }
    $Watch = [System.Diagnostics.Stopwatch]::StartNew()
    $Errors = 0
    $Samples = 0

    for ($i = 0; $i -lt $Cycles; $i++)
    {
        $NowMs = [int64]([datetime]::UtcNow.ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,[datetimekind]::Utc)).TotalMilliseconds
        $Cycle = Invoke-WtMonitorCycle -Backend $Backend -CpuState $CpuState -NowMs $NowMs -MonotonicMs $Watch.ElapsedMilliseconds
        $Samples += @($Cycle.Samples).Count
        if (-not $Cycle.Ok) { $Errors++ }
    }
    $Watch.Stop()

    $WorkerMemoryMB = $null
    $WorkerVersion = ''
    if ($Backend -ne 'PowerShell')
    {
        $Status = Get-WtWorkerStatus -Force
        if ($Status.Available)
        {
            $WorkerVersion = $Status.Version
            $Overhead = Measure-WtWorkerOverhead -RoundTrips 2
            $WorkerMemoryMB = $Overhead.WorkerWorkingMB
        }
    }

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.MonitorCycleMeasurement'
        Backend = $Backend
        Cycles = $Cycles
        TotalMs = [int]$Watch.ElapsedMilliseconds
        PerCycleMs = [math]::Round($Watch.Elapsed.TotalMilliseconds / [math]::Max(1, $Cycles), 2)
        TotalSamples = $Samples
        FailedCycles = $Errors
        WorkerVersion = $WorkerVersion
        WorkerMemoryMB = $WorkerMemoryMB
        Conditions = @{
            OS = [string](Get-WtPlatformDescription)
            PowerShell = $PSVersionTable.PSVersion.ToString()
            IsWindows = [bool](Get-WtRuntimeProfile).IsWindows
        }
    }
}
