# WindowsTweaker - public catalog and environment queries (all read-only).

<#
.SYNOPSIS
    Returns a read-only snapshot of the environment WindowsTweaker is running in.
.DESCRIPTION
    Reads only: PowerShell/OS version, elevation, architecture, language mode,
    pending-reboot flags and which optional features are available. It never
    changes a setting, which is what makes it safe to call during startup.
.PARAMETER Refresh
    Ignore the cached snapshot and probe again.
#>
function Get-WtEnvironment
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ([Parameter(Mandatory = $false)][switch]$Refresh)

    $Environment = Get-WtEnvironmentInternal -Refresh:$Refresh
    $PendingDetail = Get-WtEnvironmentPendingRestartInternal -Environment $Environment

    $Capabilities = [ordered]@{}
    foreach ($Token in 'Windows', 'Admin', 'Cmdlet:Get-AppxPackage', 'Cmdlet:Get-NetAdapter', 'Cmdlet:Get-DnsClientServerAddress', 'Cmdlet:Get-ScheduledTask', 'Cmdlet:Get-MpPreference', 'Module:DISM', 'Module:Appx', 'Module:NetSecurity', 'Module:DnsClient', 'Module:ScheduledTasks')
    {
        $Capabilities[$Token] = (Test-WtCapability -Name $Token -Environment $Environment).Available
    }

    return [pscustomobject]@{
        PSTypeName       = 'WindowsTweaker.Environment'
        PowerShell       = $Environment.PowerShell
        RequiredPowerShell = $Environment.RequiredPS
        MeetsPowerShell  = $Environment.MeetsPowerShell
        IsWindows        = $Environment.IsWindows
        IsAdmin          = $Environment.IsAdmin
        OSName           = $Environment.OSName
        OSBuild          = $Environment.OSBuild
        OSUBR            = $Environment.OSUBR
        OSDisplayVersion = $Environment.OSDisplayVersion
        OSVersionKey     = $Environment.OSVersionKey
        Architecture     = $Environment.Architecture
        IsVirtualMachine = $Environment.IsVirtualMachine
        LanguageMode     = $Environment.LanguageMode
        PendingReboot    = $Environment.PendingReboot
        PendingRebootEvidence = [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.PendingRestartSummary'
            Markers    = @($(if ($PendingDetail) { $PendingDetail.Markers }))
            Present    = [int]$(if ($PendingDetail) { $PendingDetail.Present } else { 0 })
            Unreadable = [int]$(if ($PendingDetail) { $PendingDetail.Unreadable } else { 0 })
            Boundary   = [string]$(if ($PendingDetail) { $PendingDetail.Boundary } else { '' })
        }
        PendingRebootLabel = Get-WtPendingRestartValueLabelInternal -Pending $PendingDetail
        Culture          = $Environment.Culture
        Language         = Get-WtLanguage
        LogPath          = Get-WtLogPath
        StatePath        = Get-WtStatePath
        Capabilities     = [pscustomobject]$Capabilities
    }
}

<#
.SYNOPSIS
    Tests whether a tweak can run on this machine, with the reason when it cannot.
#>
function Test-WtPrerequisite
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ([Parameter(Mandatory = $true, ValueFromPipeline = $true)][psobject]$Tweak)

    process
    {
        $Environment = Get-WtEnvironmentInternal

        $Requirements = [System.Collections.Generic.List[string]]::new()
        foreach ($Requirement in @($Tweak.Requires))
        {
            $Requirements.Add($Requirement)
        }

        if ($Tweak.Privilege -eq 'Admin')
        {
            $Requirements.Add('Admin')
        }

        if (@($Tweak.SupportedOS).Count -gt 0)
        {
            foreach ($Supported in @($Tweak.SupportedOS))
            {
                $Requirements.Add("OS:$Supported")
            }
        }

        if ($Tweak.MinBuild -gt 0)
        {
            $Requirements.Add("Build:$($Tweak.MinBuild)")
        }

        $Dependency = Test-WtDependency -Requires $Requirements.ToArray() -Environment $Environment

        # OS-family requirements are a union (Windows 10 OR 11), not a conjunction.
        if (-not $Dependency.Supported)
        {
            $OnlyOsFamilyFailures = @($Dependency.Missing | Where-Object { $_.Kind -ne 'OS' }).Count -eq 0
            if ($OnlyOsFamilyFailures -and ($Environment.OSVersionKey -in @($Tweak.SupportedOS)))
            {
                $Dependency = [pscustomobject]@{
                    PSTypeName = 'WindowsTweaker.DependencyResult'
                    Supported  = $true
                    All        = $Dependency.All
                    Missing    = @()
                    Reason     = ''
                }
            }
        }

        $Effective = if ($null -ne $Tweak.MinBuild -and $Tweak.MinBuild -gt 0 -and $null -ne $Environment.OSBuild -and [int]$Environment.OSBuild -ge [int]$Tweak.MinBuild)
        {
            $Dependency
        }
        else
        {
            $Dependency
        }

        return [pscustomobject]@{
            PSTypeName   = 'WindowsTweaker.PrerequisiteResult'
            TweakId      = $Tweak.Id
            Supported    = $Effective.Supported
            Reason       = $Effective.Reason
            Missing      = @($Effective.Missing)
            Requirements = $Requirements.ToArray()
        }
    }
}

<#
.SYNOPSIS
    Lists catalog tweaks.
.PARAMETER Id
    Exact tweak id.
.PARAMETER Category
    Category filter (Privacy, Security, System, Explorer, ...).
.PARAMETER Search
    Free-text filter over id, name and description.
#>
function Get-WtTweak
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $false)][string]$Id,
        [Parameter(Mandatory = $false)][string]$Category,
        [Parameter(Mandatory = $false)][string]$Search
    )

    return Get-WtTweakInternal -Id $Id -Category $Category -Search $Search
}

<#
.SYNOPSIS
    Lists the categories that currently contain tweaks.
#>
function Get-WtCategory
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ()

    return Get-WtCategoryInternal
}

<#
.SYNOPSIS
    Returns the aggregated capability-loss disclosures for a selection of tweaks.
.DESCRIPTION
    Read-only. Each selected tweak may declare what may stop working after it runs
    (a stable capability id, a guaranteed/conditional/unknown kind, temporary or
    persistent, and an optional restoration path). Impacts are deduplicated by their
    capability id, with every selected action that causes each one named.
.PARAMETER Id
    Tweak id(s), resolved through the migration registry like every other id.
.PARAMETER State
    Optional map of tweak id -> requested state; a tweak without one uses its default
    state, exactly like the plan does.
.EXAMPLE
    Get-WtCapabilityLoss -Id Privacy.DiagnosticDataLevel, Privacy.AdvertisingId
.OUTPUTS
    Object with Impacts (aggregated, deduplicated rows) and NotApplicable (declared
    impacts whose condition is not met on this machine).
#>
function Get-WtCapabilityLoss
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $true)][string[]]$Id,
        [Parameter(Mandatory = $false)][hashtable]$State
    )

    $Selection = [System.Collections.Generic.List[object]]::new()
    foreach ($TweakId in @($Id))
    {
        $Tweak = Get-WtTweakInternal -Id $TweakId
        if (-not $Tweak)
        {
            throw (Get-WtString -Key 'Error.TweakNotFound' -Arguments @($TweakId))
        }

        $Target = if ($State -and $State.Contains($TweakId)) { [string]$State[$TweakId] } else { [string]$Tweak.DefaultState }
        $Selection.Add(@{ Tweak = $Tweak; State = $Target })
    }

    return (Get-WtCapabilityLossInternal -Selection @($Selection.ToArray()))
}

<#
.SYNOPSIS
    Lists network adapters for DNS selection (read-only).
.DESCRIPTION
    VPN, virtual and tunnel adapters are flagged so callers can keep them out of a
    DNS change by default, and the current per-adapter DNS configuration is included so
    the previous state is visible before anything is changed.
#>
function Get-WtNetworkAdapter
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ()

    return Get-WtNetworkAdapterWithDns
}

<#
.SYNOPSIS
    Lists the Windows optional features of this installation (read-only).
.PARAMETER Name
    Exact feature name; without it every feature is listed.
.DESCRIPTION
    Read-only: used by the interface to show a selectable list with the current state of
    every feature. Requires an elevated session (DISM); an empty list means the feature
    list could not be read on this host, and the reason is logged.
#>
function Get-WtWindowsFeature
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ([Parameter(Mandatory = $false)][string]$Name)

    return Get-WtWindowsFeatureInternal -Name $Name
}

<#
.SYNOPSIS
    Lists the Windows capabilities (Features on Demand) of this installation (read-only).
.PARAMETER Name
    Exact capability name, including the version suffix.
#>
function Get-WtWindowsCapability
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ([Parameter(Mandatory = $false)][string]$Name)

    return Get-WtWindowsCapabilityInternal -Name $Name
}
