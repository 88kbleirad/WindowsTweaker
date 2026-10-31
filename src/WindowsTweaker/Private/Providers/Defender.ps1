# WindowsTweaker - Microsoft Defender preference provider.
#
# Scope is deliberately narrow: this provider can read and set a Defender preference
# (Controlled Folder Access, network protection, PUA protection) with state capture and rollback. It never
# disables Defender itself, and no code path in this tool turns a protection off
# during startup or as part of an unrelated tweak.

function Test-WtDefenderAvailable
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    if (-not (Get-WtRuntimeProfile).IsWindows)
    {
        return $false
    }

    return [bool](Get-Command -Name Get-MpPreference -ErrorAction Ignore)
}

function Get-WtMpPreferenceRaw
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Name)

    $Preference = Get-MpPreference -ErrorAction Stop
    if ($Preference.PSObject.Properties.Name -notcontains $Name)
    {
        return $null
    }

    return $Preference.$Name
}

function Set-WtMpPreferenceRaw
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][ValidateSet('EnableControlledFolderAccess', 'PUAProtection', 'EnableNetworkProtection')][string]$Name,
        [Parameter(Mandatory = $true)][object]$Value
    )

    Set-MpPreference -ErrorAction Stop @{ $Name = $Value }
}

<#
.SYNOPSIS
    Read-only state of a Defender preference.
#>
function Get-WtMpPreferenceState
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Test-WtDefenderAvailable))
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.MpPreferenceState'
            Name       = $Name
            Available  = $false
            Value      = $null
        }
    }

    try
    {
        $Value = Get-WtMpPreferenceRaw -Name $Name
    }
    catch
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.MpPreferenceState'
            Name       = $Name
            Available  = $false
            Value      = $null
            Reason     = $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.MpPreferenceState'
        Name       = $Name
        Available  = $true
        Value      = $Value
    }
}

<#
.SYNOPSIS
    Sets a Defender preference, capturing the previous value for rollback.
#>
function Set-WtMpPreferenceState
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param
    (
        [Parameter(Mandatory = $true)][ValidateSet('EnableControlledFolderAccess', 'PUAProtection', 'EnableNetworkProtection')][string]$Name,
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $false)][string]$Reason = ''
    )

    $Operation = 'SetMpPreference'
    $Target = $Name

    if (-not (Test-WtDefenderAvailable))
    {
        return New-WtOperationResult -Status 'unsupported' -Operation $Operation -Target $Target -Message 'The Defender module (Get-MpPreference) is not available on this platform.'
    }

    $Previous = Get-WtMpPreferenceState -Name $Name
    if (-not $Previous.Available)
    {
        return New-WtOperationResult -Status 'unsupported' -Operation $Operation -Target $Target -Message "Defender preference $Name could not be read."
    }

    if (Test-WtValueEqual -Left $Previous.Value -Right $Value)
    {
        return New-WtOperationResult -Status 'unchanged' -Operation $Operation -Target $Target -Message "Defender preference $Name already equals $Value."
    }


    # One confirmation per tweak: Invoke-WtTweak/Undo-WtTweak confirm once, and the
    # providers must not prompt again while that apply/rollback is in progress.
    if ((Get-WtOperationContext).SuppressConfirm) { $ConfirmPreference = 'None' }

    if (-not $PSCmdlet.ShouldProcess($Target, "set Defender preference $Name = $Value$(if ($Reason) { " ($Reason)" })"))
    {
        return New-WtOperationResult -Status (Get-WtShouldProcessStatus) -Operation $Operation -Target $Target -Message "Would set $Name = $Value"
    }

    $Context = Get-WtOperationContext
    if ($null -ne $Context.HistoryEntry)
    {
        Add-WtStateRecord -HistoryEntry $Context.HistoryEntry -Record @{
            resource = 'MpPreference'
            name     = $Name
            value    = ConvertTo-WtPersistableValue -Value $Previous.Value
        }
    }

    try
    {
        Set-WtMpPreferenceRaw -Name $Name -Value $Value
    }
    catch
    {
        Write-WtLog -Level Error -Message "Failed to set Defender preference $Name" -Operation $Operation -Status 'failed' -Exception $_.Exception
        return New-WtOperationResult -Status 'failed' -Operation $Operation -Target $Target -Message $_.Exception.Message -ErrorRecord $_
    }

    $Verify = Get-WtMpPreferenceState -Name $Name
    if (-not (Test-WtValueEqual -Left $Verify.Value -Right $Value))
    {
        $Message = "Verification failed for Defender preference $Name (expected $Value, found $($Verify.Value))."
        Write-WtLog -Level Error -Message $Message -Operation $Operation -Status 'failed'
        return New-WtOperationResult -Status 'failed' -Operation $Operation -Target $Target -Message $Message
    }

    return New-WtOperationResult -Status 'succeeded' -Operation $Operation -Target $Target -Message "Set Defender preference $Name = $Value"
}
