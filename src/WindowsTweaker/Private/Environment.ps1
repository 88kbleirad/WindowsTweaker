# WindowsTweaker - read-only environment and dependency probing.
#
# Hard rule: nothing in this file may modify the system. Every function here only
# reads (registry reads, service queries, module/cmdlet lookups). Initialisation
# therefore never changes settings - it reports what is supported and what is not.

$Script:WtEnvironmentCache = $null
$Script:WtCapabilityCache = @{}

<#
.SYNOPSIS
    PowerShell version that must be present for the application to start.
.DESCRIPTION
    Windows PowerShell 5.1 ships with Windows, so it is the requirement - not 7.4. The
    validated runtime is Get-WtSupportedPowerShellVersion (7.4-7.6), and the bootstrap
    prefers it when it is installed. See docs/COMPATIBILITY.md.
#>
function Get-WtRequiredPowerShellVersion
{
    [CmdletBinding()]
    [OutputType([version])]
    param ()

    return (Get-WtMinimumPowerShellVersion)
}

<#
.SYNOPSIS
    PowerShell version the application is designed and validated for.
.DESCRIPTION
    Not a start gate: the bootstrap hands off to it, and the interactive interface prefers
    it, but Windows PowerShell 5.1 runs the same engine natively.
#>
function Get-WtRecommendedPowerShellVersion
{
    [CmdletBinding()]
    [OutputType([version])]
    param ()

    return (Get-WtSupportedPowerShellVersion)
}

<#
.SYNOPSIS
    Oldest PowerShell version that may start the application.
#>
function Get-WtMinimumRuntimeVersion
{
    [CmdletBinding()]
    [OutputType([version])]
    param ()

    return (Get-WtMinimumPowerShellVersion)
}

<#
.SYNOPSIS
    Returns a read-only snapshot of the host environment.
.PARAMETER Refresh
    Discard the cached snapshot and probe again.
#>
function Get-WtEnvironmentInternal
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][switch]$Refresh)

    if ($Script:WtEnvironmentCache -and -not $Refresh)
    {
        return $Script:WtEnvironmentCache
    }

    # One snapshot of the runtime, shared with every capability question below.
    $Runtime = Get-WtRuntimeProfile

    $Environment = [ordered]@{
        PSTypeName    = 'WindowsTweaker.Environment'
        PowerShell    = $PSVersionTable.PSVersion
        PSEdition     = $Runtime.PSEdition
        RequiredPS    = Get-WtRequiredPowerShellVersion
        MinimumPS     = $Runtime.MinimumVersion
        RecommendedPS = Get-WtRecommendedPowerShellVersion
        MeetsPowerShell = ($PSVersionTable.PSVersion -ge (Get-WtRequiredPowerShellVersion))
        MeetsMinimumRuntime = ($PSVersionTable.PSVersion -ge $Runtime.MinimumVersion)
        MeetsRecommendedRuntime = ($PSVersionTable.PSVersion -ge (Get-WtRecommendedPowerShellVersion))
        RuntimeTier   = $Runtime.Tier
        IsPreviewRuntime = [bool]$Runtime.PreRelease
        IsWindowsPowerShell = [bool]$Runtime.IsWindowsPowerShell
        RuntimeCapabilities = @(Get-WtRuntimeCapabilityList)
        IsWindows     = [bool]$Runtime.IsWindows
        IsAdmin       = $false
        OSName        = $null
        OSBuild       = $null
        OSUBR         = $null
        OSDisplayVersion = $null
        OSVersionKey  = 'Unknown'
        Architecture  = Get-WtPlatformArchitecture
        IsVirtualMachine = $null
        LanguageMode  = $ExecutionContext.SessionState.LanguageMode.ToString()
        PendingReboot = $null
        PendingRebootDetail = $null
        Culture       = $null
    }

    try
    {
        $Environment.Culture = Get-WtCultureName
    }
    catch
    {
        $Environment.Culture = 'en-US'
    }

    if ($Runtime.IsWindows)
    {
        try
        {
            $Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            $Principal = [System.Security.Principal.WindowsPrincipal]::new($Identity)
            $Environment.IsAdmin = $Principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        catch
        {
            $Environment.IsAdmin = $false
        }

        $CurrentVersion = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        try
        {
            $Info = Get-ItemProperty -Path $CurrentVersion -ErrorAction Stop
            $Environment.OSName = $Info.ProductName
            $Environment.OSBuild = [int]$Info.CurrentBuildNumber
            $Environment.OSUBR = [int]$Info.UBR
            $Environment.OSDisplayVersion = $Info.DisplayVersion
        }
        catch
        {
            Write-WtLog -Level Debug -Message "Could not read $CurrentVersion" -NoConsole
        }

        if ($Environment.OSBuild -ge 22000)
        {
            $Environment.OSVersionKey = 'Windows11'
        }
        elseif ($Environment.OSBuild)
        {
            $Environment.OSVersionKey = 'Windows10'
        }

        try
        {
            $Environment.IsVirtualMachine = [bool](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent
        }
        catch
        {
            $Environment.IsVirtualMachine = $null
        }

        # Pending restart comes from the structured probe the rest of the engine uses: the same
        # markers, with missing, empty, non-empty and unreadable kept apart. A local Test-Path over
        # a different set of paths would be a second, weaker answer to the same question - and a
        # permission-denied read would have looked like "no restart is pending".
        $Pending = Get-WtPendingRestartInternal
        $Environment.PendingReboot = [bool]([int]$Pending.Present -gt 0)
        $Environment.PendingRebootDetail = $Pending
    }

    $Script:WtEnvironmentCache = $Environment
    return $Environment
}

<#
.SYNOPSIS
    A human-readable platform description that is never empty.
.DESCRIPTION
    Used in messages such as "WindowsTweaker only runs on Windows. Detected platform:
    <x>", where an empty value would leave a dangling placeholder.
#>
function Get-WtPlatformDescription
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    $Environment = Get-WtEnvironmentInternal

    if ($Environment.OSName)
    {
        return [string]$Environment.OSName
    }

    # RuntimeInformation.OSDescription does not exist on .NET Framework, so it is read
    # through the compatibility layer, which falls back to the platform name.
    $Description = Get-WtOsDescription
    if ($Description)
    {
        return [string]$Description
    }

    return [string][System.Environment]::OSVersion.Platform
}

<#
.SYNOPSIS
    Tests one dependency token and explains the outcome.
.DESCRIPTION
    Supported tokens:
      Cmdlet:<name>   - the cmdlet must be resolvable in the current session
      Module:<name>   - the module must be importable or already loaded
      Admin           - the current process must be elevated
      Windows         - must run on Windows
      OS:<key>        - Windows10 / Windows11 (key from the environment snapshot)
      Build:<min>     - minimum Windows build number
.PARAMETER Name
    The dependency token.
.PARAMETER Environment
    Pre-computed environment snapshot (avoids repeated probing).
#>
function Test-WtCapability
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [hashtable]$Environment
    )

    if (-not $Environment)
    {
        $Environment = Get-WtEnvironmentInternal
    }

    $Result = @{
        Name        = $Name
        Available   = $false
        Reason      = ''
        Kind        = 'unknown'
    }

    $Parts = $Name -split ':', 2
    $Kind = $Parts[0].Trim()
    $Argument = if ($Parts.Count -gt 1) { $Parts[1].Trim() } else { '' }

    switch ($Kind)
    {
        'Cmdlet'
        {
            $Result.Kind = 'Cmdlet'
            $Result.Available = [bool](Get-Command -Name $Argument -ErrorAction Ignore)
            if (-not $Result.Available)
            {
                $Result.Reason = Get-WtString -Key 'Error.CmdletMissing' -Arguments @($Argument)
            }
        }
        'Module'
        {
            $Result.Kind = 'Module'
            $Result.Available = [bool](Get-Module -Name $Argument -ListAvailable -ErrorAction Ignore)
            if (-not $Result.Available)
            {
                $Result.Reason = Get-WtString -Key 'Error.ModuleMissing' -Arguments @($Argument)
            }
        }
        'Admin'
        {
            $Result.Kind = 'Admin'
            $Result.Available = [bool]$Environment.IsAdmin
            if (-not $Result.Available)
            {
                $Result.Reason = Get-WtString -Key 'Error.AdminRequired' -Arguments @($Argument)
            }
        }
        'Windows'
        {
            $Result.Kind = 'Windows'
            $Result.Available = [bool]$Environment.IsWindows
            if (-not $Result.Available)
            {
                $Result.Reason = Get-WtString -Key 'Error.WindowsOnly' -Arguments @($Environment.OSName)
            }
        }
        'OS'
        {
            $Result.Kind = 'OS'
            $Result.Available = ($Environment.OSVersionKey -eq $Argument)
            if (-not $Result.Available)
            {
                $Result.Reason = Get-WtString -Key 'Error.OSCondition' -Arguments @($Argument)
            }
        }
        'Build'
        {
            $Result.Kind = 'Build'
            $Minimum = 0
            [void][int]::TryParse($Argument, [ref]$Minimum)
            $Result.Available = ($null -ne $Environment.OSBuild -and [int]$Environment.OSBuild -ge $Minimum)
            if (-not $Result.Available)
            {
                $Result.Reason = Get-WtString -Key 'Error.OSCondition' -Arguments @("build >= $Minimum")
            }
        }
        default
        {
            $Result.Kind = 'Unknown'
            $Result.Reason = "Unknown dependency token: $Name"
        }
    }

    return $Result
}

<#
.SYNOPSIS
    Tests a list of dependency tokens and returns the first failure.
#>
function Test-WtDependency
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)]
        [string[]]$Requires = @(),

        [Parameter(Mandatory = $false)]
        [hashtable]$Environment
    )

    if (-not $Environment)
    {
        $Environment = Get-WtEnvironmentInternal
    }

    $Results = @()
    foreach ($Requirement in $Requires)
    {
        $Results += (Test-WtCapability -Name $Requirement -Environment $Environment)
    }

    $Failed = @($Results | Where-Object { -not $_.Available })

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.DependencyResult'
        Supported  = ($Failed.Count -eq 0)
        All        = $Results
        Missing    = $Failed
        Reason     = if ($Failed.Count -gt 0) { ($Failed.Reason -join '; ') } else { '' }
    }
}

<#
.SYNOPSIS
    Lists network adapters for DNS operations (read-only).
.DESCRIPTION
    VPN, virtual and tunnelling adapters are flagged rather than selected, so the
    caller can keep them out of a DNS change by default.
#>
function Get-WtNetworkAdapterInternal
{
    [CmdletBinding()]
    param ()

    if (-not (Get-Command -Name Get-NetAdapter -ErrorAction Ignore))
    {
        return @()
    }

    $Adapters = @(Get-NetAdapter -ErrorAction Ignore | Sort-Object -Property InterfaceIndex)
    $VirtualPatterns = 'VPN|TAP|TUN|WireGuard|OpenVPN|Loopback|Hyper-V|VMware|VirtualBox|Bluetooth|Teredo|ISATAP|WAN Miniport|Npcap|Tailscale|ZeroTier|Docker|WSL'

    foreach ($Adapter in $Adapters)
    {
        $IsVirtual = ($Adapter.Virtual -eq $true) -or ($Adapter.InterfaceDescription -match $VirtualPatterns) -or ($Adapter.Name -match $VirtualPatterns)

        [pscustomobject]@{
            PSTypeName          = 'WindowsTweaker.NetworkAdapter'
            Name                = $Adapter.Name
            InterfaceIndex      = $Adapter.InterfaceIndex
            InterfaceGuid       = $Adapter.InterfaceGuid
            Description         = $Adapter.InterfaceDescription
            Status              = [string]$Adapter.Status
            IsPhysical          = ($Adapter.Virtual -ne $true)
            IsVirtualOrTunnel   = [bool]$IsVirtual
            MediaType           = [string]$Adapter.MediaType
        }
    }
}
