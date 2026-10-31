# WindowsTweaker - public surface of the optional background worker.
#
# The capability itself (Invoke-WtDirectoryScan) is implemented in the private worker layer;
# it is exported here because the CLI and the terminal interface both need one documented way
# to ask for a read-only directory aggregation with an explicit backend.

<#
.SYNOPSIS
    Lists the direct children of a directory with per-subdirectory subtree aggregates.
.DESCRIPTION
    Read-only: one level of the directory hierarchy, with each subdirectory aggregated by
    the selected backend (Go worker when it advertises scan.children, otherwise the
    PowerShell implementation, or explicitly Go/PowerShell). The result states logical size
    and whether allocation is known; it never implies the bytes are reclaimable.
.PARAMETER Path
    Absolute directory to list.
.PARAMETER Backend
    Auto (default), Go or PowerShell.
.EXAMPLE
    Get-WtDirectoryChildren -Path C:\Users\me\Downloads
.OUTPUTS
    Object with Root, Entries, Cancelled, ElapsedMS, Backend, Ok, Code and Message.
#>
function Get-WtDirectoryChildren
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][ValidateSet('', 'Auto', 'Go', 'PowerShell')][string]$Backend = ''
    )

    return (Invoke-WtDirectoryChildren -Root $Path -Backend $Backend)
}

<#
.SYNOPSIS
    Reports whether the background worker is usable on this machine, and why.
.DESCRIPTION
    Combines the installed path, the protocol handshake and the resolved backend into one
    object. Nothing is installed, started for longer than the handshake, or changed.
.PARAMETER Force
    Ignore the cached handshake and probe again.
.EXAMPLE
    Get-WtWorkerStatus
#>
function Get-WtWorkerStatus
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $false)][switch]$Force,
        [Parameter(Mandatory = $false)][ValidateSet('', 'Auto', 'Go', 'PowerShell')][string]$Backend = ''
    )

    $Availability = Test-WtWorkerAvailable -Force:$Force
    $Resolution = Resolve-WtWorkerBackend -Requested $Backend

    return [pscustomobject]@{
        PSTypeName   = 'WindowsTweaker.WorkerStatus'
        Path         = $Availability.Path
        Installed    = [bool]$Availability.Path
        Available    = [bool]$Availability.Available
        Code         = [string]$Availability.Code
        Reason       = [string]$Availability.Reason
        Protocol     = [int]$Availability.Protocol
        ExpectedProtocol = $Script:WtWorkerProtocolVersion
        Version      = [string]$Availability.Version
        Capabilities = @($Availability.Capabilities)
        Backend      = [string]$Resolution.Backend
        BackendReason = [string]$Resolution.Reason
        Preference   = (Get-WtWorkerBackendPreference)
    }
}

<#
.SYNOPSIS
    Saves the preferred backend for background work.
.DESCRIPTION
    Auto uses the Go worker when it is available and compatible and falls back to PowerShell
    with the reason; Go refuses to fall back; PowerShell always uses the comparison baseline.
.PARAMETER Backend
    Auto, Go or PowerShell.
.EXAMPLE
    Set-WtWorkerBackend -Backend Go
#>
function Set-WtWorkerBackend
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateSet('Auto', 'Go', 'PowerShell')]
        [string]$Backend
    )

    if (-not $PSCmdlet.ShouldProcess($Backend, 'save the background worker backend preference'))
    {
        return $Backend
    }

    return (Set-WtWorkerBackendPreference -Backend $Backend)
}

<#
.SYNOPSIS
    Measures worker startup and protocol round-trip overhead.
.DESCRIPTION
    Separates the cost of starting the worker and speaking the protocol from the cost of the
    work itself, so a benchmark can report both. Returns timings and the worker's memory
    footprint; nothing is left running (the client is stopped with the documented bounded
    shutdown).
.PARAMETER RoundTrips
    How many trivial requests to send (default 20).
.EXAMPLE
    Measure-WtWorkerOverhead
#>
function Measure-WtWorkerOverhead
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ([Parameter(Mandatory = $false)][ValidateRange(1, 500)][int]$RoundTrips = 20)

    $Availability = Test-WtWorkerAvailable -Force
    if (-not $Availability.Available)
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.WorkerOverhead'
            Available  = $false
            Code       = [string]$Availability.Code
            Reason     = [string]$Availability.Reason
        }
    }

    $Process = [System.Diagnostics.Process]::GetCurrentProcess()
    $CpuBefore = $Process.TotalProcessorTime

    $Watch = [System.Diagnostics.Stopwatch]::StartNew()
    $Client = Start-WtWorkerClient
    $Watch.Stop()

    $StartupMs = [int]$Watch.ElapsedMilliseconds
    $StartupCpuMs = [int]($Process.TotalProcessorTime - $CpuBefore).TotalMilliseconds
    $WorkerWorking = [math]::Round($Client.Process.WorkingSet64 / 1MB, 1)
    $WorkerPeak = [math]::Round($Client.Process.PeakWorkingSet64 / 1MB, 1)

    $RoundTripWatch = [System.Diagnostics.Stopwatch]::StartNew()
    try
    {
        for ($Index = 0; $Index -lt $RoundTrips; $Index++)
        {
            $null = Invoke-WtWorkerRoundTrip -Client $Client -Message @{ v = $Script:WtWorkerProtocolVersion; id = "ping$Index"; op = 'hello' } -TimeoutMs 5000
        }
    }
    finally
    {
        $RoundTripWatch.Stop()
        $Stop = Stop-WtWorkerClient -Client $Client
    }

    return [pscustomobject]@{
        PSTypeName       = 'WindowsTweaker.WorkerOverhead'
        Available        = $true
        Code             = 'Available'
        Reason           = ''
        WorkerVersion    = [string]$Availability.Version
        Protocol         = [int]$Availability.Protocol
        StartupMs        = $StartupMs
        StartupCpuMs     = $StartupCpuMs
        WorkerWorkingMB  = $WorkerWorking
        WorkerPeakMB     = $WorkerPeak
        RoundTrips       = $RoundTrips
        RoundTripTotalMs = [int]$RoundTripWatch.ElapsedMilliseconds
        RoundTripAvgMs   = [math]::Round($RoundTripWatch.Elapsed.TotalMilliseconds / [math]::Max(1, $RoundTrips), 2)
        CleanShutdown    = [bool]$Stop.Exited
        Killed           = [bool]$Stop.Killed
    }
}
