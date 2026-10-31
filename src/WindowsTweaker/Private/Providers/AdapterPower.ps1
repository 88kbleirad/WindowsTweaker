# WindowsTweaker - network adapter power management provider.
#
# The legacy modules/NetworkAdapterSavePower.ps1 toggled "Allow the computer to turn
# off this device to save power". Set-NetAdapterPowerManagement exposes no
# -AllowComputerToTurnOffDevice parameter (the MSFT_NetAdapterPowerManagementSettingData
# class carries that property), so the documented way to change it is to assign the
# property on the instance returned by Get-NetAdapterPowerManagement and pipe that
# instance back into Set-NetAdapterPowerManagement. This provider wraps that call with
# the usual contract: availability check, read-only snapshot, -WhatIf, state capture,
# verification and per-operation logging, so the previous per-adapter value is stored
# and rollback can restore it.
#
# Values used are the ones the property and the cmdlet document ('Enabled' /
# 'Disabled'); the legacy module assigned 'Enable' / 'Disable'.
#
# Scope is deliberately per adapter: the caller names the interfaces (InterfaceIndex)
# and nothing else is touched.

function Test-WtAdapterPowerAvailable
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    if (-not (Get-WtRuntimeProfile).IsWindows)
    {
        return $false
    }

    return [bool]((Get-Command -Name Get-NetAdapterPowerManagement -ErrorAction Ignore) -and
        (Get-Command -Name Get-NetAdapter -ErrorAction Ignore))
}

function Get-WtAdapterPowerRaw
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][int]$InterfaceIndex)

    # Get-NetAdapterPowerManagement accepts -Name / -InterfaceDescription (or an adapter
    # object through the pipeline), never -InterfaceIndex, so resolve the adapter first.
    return (Get-NetAdapter -InterfaceIndex $InterfaceIndex -ErrorAction Ignore |
        Get-NetAdapterPowerManagement -ErrorAction Ignore |
        Select-Object -First 1)
}

function Set-WtAdapterPowerRaw
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][int]$InterfaceIndex,
        [Parameter(Mandatory = $true)][ValidateSet('Enabled', 'Disabled')][string]$AllowComputerToTurnOffDevice
    )

    $Adapter = Get-WtAdapterPowerRaw -InterfaceIndex $InterfaceIndex
    if (-not $Adapter)
    {
        throw "No power management settings are available for interface index $InterfaceIndex."
    }

    # Only the InputObject form of Set-NetAdapterPowerManagement can carry this property.
    $Adapter.AllowComputerToTurnOffDevice = $AllowComputerToTurnOffDevice
    $Adapter | Set-NetAdapterPowerManagement -ErrorAction Stop | Out-Null
}

<#
.SYNOPSIS
    Read-only power management snapshot of one adapter.
#>
function Get-WtAdapterPowerSnapshot
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][int]$InterfaceIndex)

    if (-not (Test-WtAdapterPowerAvailable))
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.AdapterPowerState'
            InterfaceIndex = $InterfaceIndex
            Name       = $null
            Available  = $false
            Exists     = $false
            AllowComputerToTurnOffDevice = $null
        }
    }

    $Adapter = Get-WtAdapterPowerRaw -InterfaceIndex $InterfaceIndex
    if (-not $Adapter)
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.AdapterPowerState'
            InterfaceIndex = $InterfaceIndex
            Name       = $null
            Available  = $true
            Exists     = $false
            AllowComputerToTurnOffDevice = $null
        }
    }

    $Name = $null
    foreach ($Candidate in 'InterfaceAlias', 'Name', 'InterfaceDescription')
    {
        if ($Adapter.PSObject.Properties.Name -contains $Candidate)
        {
            $Name = [string]$Adapter.$Candidate
            break
        }
    }

    $Value = $null
    if ($Adapter.PSObject.Properties.Name -contains 'AllowComputerToTurnOffDevice')
    {
        $Value = [string]$Adapter.AllowComputerToTurnOffDevice
    }

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.AdapterPowerState'
        InterfaceIndex = $InterfaceIndex
        Name       = $Name
        Available  = $true
        Exists     = $true
        AllowComputerToTurnOffDevice = $Value
    }
}

<#
.SYNOPSIS
    Sets "Allow the computer to turn off this device to save power" on one adapter.
.DESCRIPTION
    Captures the previous value before the change, honours -WhatIf, verifies the result
    and reports one operation result. Writes and removes nothing else.
#>
function Set-WtAdapterPowerState
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param
    (
        [Parameter(Mandatory = $true)][int]$InterfaceIndex,
        [Parameter(Mandatory = $true)][ValidateSet('Enabled', 'Disabled')][string]$AllowComputerToTurnOffDevice
    )

    $Operation = 'SetAdapterPower'
    $Target = "interface $InterfaceIndex"

    if (-not (Test-WtAdapterPowerAvailable))
    {
        return New-WtOperationResult -Status 'unsupported' -Operation $Operation -Target $Target -Message 'The NetAdapter module is not available on this platform.'
    }

    $Previous = Get-WtAdapterPowerSnapshot -InterfaceIndex $InterfaceIndex
    if (-not $Previous.Exists)
    {
        return New-WtOperationResult -Status 'unsupported' -Operation $Operation -Target $Target -Message "No power management settings were reported for interface index $InterfaceIndex."
    }

    if ([string]::IsNullOrEmpty($Previous.AllowComputerToTurnOffDevice) -or $Previous.AllowComputerToTurnOffDevice -eq 'Unsupported')
    {
        return New-WtOperationResult -Status 'unsupported' -Operation $Operation -Target $Target -Message "Adapter '$($Previous.Name)' (interface index $InterfaceIndex) does not support the 'Allow the computer to turn off this device' setting."
    }

    if ($Previous.AllowComputerToTurnOffDevice -eq $AllowComputerToTurnOffDevice)
    {
        return New-WtOperationResult -Status 'unchanged' -Operation $Operation -Target $Target -Message "Adapter '$($Previous.Name)' already has AllowComputerToTurnOffDevice=$AllowComputerToTurnOffDevice."
    }

    # One confirmation per tweak: Invoke-WtTweak/Undo-WtTweak confirm once, and the
    # providers must not prompt again while that apply/rollback is in progress.
    if ((Get-WtOperationContext).SuppressConfirm) { $ConfirmPreference = 'None' }

    if (-not $PSCmdlet.ShouldProcess($Target, "set AllowComputerToTurnOffDevice=$AllowComputerToTurnOffDevice"))
    {
        return New-WtOperationResult -Status (Get-WtShouldProcessStatus) -Operation $Operation -Target $Target -Message "Would set AllowComputerToTurnOffDevice=$AllowComputerToTurnOffDevice on $Target ('$($Previous.Name)')"
    }

    $Context = Get-WtOperationContext
    if ($null -ne $Context.HistoryEntry)
    {
        Add-WtStateRecord -HistoryEntry $Context.HistoryEntry -Record @{
            resource                     = 'AdapterPower'
            interfaceIndex               = $InterfaceIndex
            name                         = $Previous.Name
            exists                       = $true
            allowComputerToTurnOffDevice = $Previous.AllowComputerToTurnOffDevice
        }
    }

    try
    {
        Set-WtAdapterPowerRaw -InterfaceIndex $InterfaceIndex -AllowComputerToTurnOffDevice $AllowComputerToTurnOffDevice
    }
    catch
    {
        Write-WtLog -Level Error -Message "Failed to set the power management setting on $Target" -Operation $Operation -Status 'failed' -Exception $_.Exception
        return New-WtOperationResult -Status 'failed' -Operation $Operation -Target $Target -Message $_.Exception.Message -ErrorRecord $_
    }

    $Verify = Get-WtAdapterPowerSnapshot -InterfaceIndex $InterfaceIndex
    if ($Verify.AllowComputerToTurnOffDevice -ne $AllowComputerToTurnOffDevice)
    {
        $Message = "Verification failed for adapter {0}: AllowComputerToTurnOffDevice is '{1}', expected '{2}'." -f $Target, $Verify.AllowComputerToTurnOffDevice, $AllowComputerToTurnOffDevice
        Write-WtLog -Level Error -Message $Message -Operation $Operation -Status 'failed'
        return New-WtOperationResult -Status 'failed' -Operation $Operation -Target $Target -Message $Message
    }

    $Message = "Set AllowComputerToTurnOffDevice={0} on adapter {1}." -f $AllowComputerToTurnOffDevice, $Target
    return New-WtOperationResult -Status 'succeeded' -Operation $Operation -Target $Target -Message $Message
}
