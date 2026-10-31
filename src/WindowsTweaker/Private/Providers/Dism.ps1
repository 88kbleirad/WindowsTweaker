# WindowsTweaker - Windows optional feature / capability provider (read-only).
#
# These functions only read: they list what this Windows installation offers so the
# interface can show a selectable list with the current state of every entry. The change
# itself is performed by the Apps.WindowsFeature / Apps.WindowsCapability tweaks through
# dism.exe, with -WhatIf, state capture and logging in the same place as every other
# tweak.
#
# DISM's own read cmdlets (Get-WindowsOptionalFeature / Get-WindowsCapability) require an
# elevated session; when they are unavailable or fail, an empty list is returned and the
# reason is logged and reported by the caller instead of being guessed at.

<#
.SYNOPSIS
    Reports whether the DISM read cmdlets are usable in this session.
#>
function Test-WtDismAvailable
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    if (-not (Get-WtRuntimeProfile).IsWindows)
    {
        return $false
    }

    return [bool](Get-Command -Name Get-WindowsOptionalFeature -ErrorAction Ignore)
}

<#
.SYNOPSIS
    Lists Windows optional features (read-only).
.PARAMETER Name
    Exact feature name; without it every feature is listed.
#>
function Get-WtWindowsFeatureInternal
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][string]$Name)

    if (-not (Test-WtDismAvailable))
    {
        Write-WtLog -Level Debug -Message 'Get-WindowsOptionalFeature is not available in this session.' -NoConsole
        return @()
    }

    $Parameters = @{ Online = $true; ErrorAction = 'Stop' }
    if ($Name)
    {
        $Parameters.FeatureName = $Name
    }

    try
    {
        $Features = @(Get-WindowsOptionalFeature @Parameters)
    }
    catch
    {
        Write-WtLog -Level Warning -Message "Could not list Windows optional features: $($_.Exception.Message)" -Operation 'WindowsOptionalFeature' -Status 'failed' -NoConsole
        return @()
    }

    foreach ($Feature in $Features)
    {
        [pscustomobject]@{
            PSTypeName     = 'WindowsTweaker.WindowsFeature'
            Kind           = 'Feature'
            Name           = [string]$Feature.FeatureName
            State          = [string]$Feature.State
            Description    = [string]$Feature.Description
            DisplayName    = [string]$Feature.DisplayName
            RestartRequired = ($Feature.RestartRequired -eq 'Possible')
        }
    }
}

<#
.SYNOPSIS
    Lists Windows capabilities (Features on Demand, read-only).
.PARAMETER Name
    Exact capability name (including the version suffix); without it every capability is
    listed.
#>
function Get-WtWindowsCapabilityInternal
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][string]$Name)

    if (-not (Test-WtDismAvailable) -or -not (Get-Command -Name Get-WindowsCapability -ErrorAction Ignore))
    {
        Write-WtLog -Level Debug -Message 'Get-WindowsCapability is not available in this session.' -NoConsole
        return @()
    }

    $Parameters = @{ Online = $true; ErrorAction = 'Stop' }
    if ($Name)
    {
        $Parameters.Name = $Name
    }

    try
    {
        $Capabilities = @(Get-WindowsCapability @Parameters)
    }
    catch
    {
        Write-WtLog -Level Warning -Message "Could not list Windows capabilities: $($_.Exception.Message)" -Operation 'WindowsCapability' -Status 'failed' -NoConsole
        return @()
    }

    foreach ($Capability in $Capabilities)
    {
        [pscustomobject]@{
            PSTypeName      = 'WindowsTweaker.WindowsCapability'
            Kind            = 'Capability'
            Name            = [string]$Capability.Name
            State           = [string]$Capability.State
            Description     = [string]$Capability.Description
            DisplayName     = [string]$Capability.DisplayName
            RestartRequired = ($Capability.RestartRequired -eq 'True')
        }
    }
}
