# WindowsTweaker - rollback engine.
#
# Rollback replays the captured pre-change records in reverse order through the same
# provider functions used to apply the change. Nothing is reset to a hard-coded
# default: the stored value, kind, existence, service configuration or per-adapter
# DNS address list is what gets restored.

<#
.SYNOPSIS
    Normalises a service start mode from any of the sources we read.
#>
function ConvertTo-WtServiceStartupType
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][object]$StartupType)

    if ($null -eq $StartupType)
    {
        return $null
    }

    switch (([string]$StartupType).Trim())
    {
        { $_ -in 'Auto', 'AutoStart', 'Automatic', '2' } { return 'Automatic' }
        { $_ -in 'Manual', '3' } { return 'Manual' }
        { $_ -in 'Disabled', '4' } { return 'Disabled' }
        'AutomaticDelayedStart' { return 'AutomaticDelayedStart' }
        default { return $null }
    }
}

<#
.SYNOPSIS
    Removes a registry key only when it is empty (used when rollback created it).
#>
function Remove-WtRegistryKeyIfEmpty
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-WtRegistryKeyRaw -Path $Path))
    {
        return New-WtOperationResult -Status 'unchanged' -Operation 'RemoveRegistryKeyIfEmpty' -Target $Path -Message "Key already absent: $Path"
    }

    $Content = Get-WtRegistryKeyContentRaw -Path $Path

    if (-not $Content.Exists)
    {
        return New-WtOperationResult -Status 'unchanged' -Operation 'RemoveRegistryKeyIfEmpty' -Target $Path -Message "Key already absent: $Path"
    }

    if (-not $Content.Inspected)
    {
        return New-WtOperationResult -Status 'skipped' -Operation 'RemoveRegistryKeyIfEmpty' -Target $Path -Message "Key could not be inspected: $Path"
    }

    if ($Content.Values -gt 0 -or $Content.SubKeys -gt 0)
    {
        # Something else now lives in the key: leave it alone rather than delete data we did not create.
        return New-WtOperationResult -Status 'skipped' -Operation 'RemoveRegistryKeyIfEmpty' -Target $Path -Message "Key is not empty; left in place: $Path"
    }

    return Remove-WtRegistryKey -Path $Path
}

<#
.SYNOPSIS
    Restores one captured registry record.
#>
function Restore-WtRegistryRecord
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Record)

    $Path = $Record.path
    $Name = $Record.name

    if ($Record.valueExisted)
    {
        $Kind = Resolve-WtRegistryKind -Kind $Record.kind
        if (-not $Kind)
        {
            $Kind = 'String'
        }

        if ($Record.kindInferred -eq $true)
        {
            Write-WtLog -Level Warning -Message "Restoring $Path\$Name with an inferred value kind ($Kind)."
        }

        return Set-WtRegistryValue -Path $Path -Name $Name -Value (ConvertFrom-WtPersistableValue -Value $Record.value) -Kind $Kind
    }

    if ($Record.keyExisted)
    {
        return Remove-WtRegistryValue -Path $Path -Name $Name
    }

    # Neither the key nor the value existed before the change: remove the value we
    # added and drop the key we created, as long as nothing else moved in.
    $Results = @()
    $Results += Remove-WtRegistryValue -Path $Path -Name $Name
    $Results += Remove-WtRegistryKeyIfEmpty -Path $Path
    return $Results
}

<#
.SYNOPSIS
    Restores a registry key removed with -Recurse.
#>
function Restore-WtRegistryKeyRecord
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Record)

    $Results = @()

    if (-not $Record.existed)
    {
        # The key did not exist before the change, so this tool created it; remove it
        # again unless something else has since put values or subkeys in it.
        return Remove-WtRegistryKeyIfEmpty -Path $Record.path
    }

    if ($Record.truncated)
    {
        return New-WtOperationResult -Status 'failed' -Operation 'RestoreRegistryKey' -Target $Record.path -Message "The captured subtree for $($Record.path) was truncated; a complete restore is not possible." -PartialRollback
    }

    $SubKeys = @($Record.snapshot.SubKeys | Sort-Object -Property Level)
    if ($SubKeys.Count -eq 0)
    {
        $Results += New-WtRegistryKey -Path $Record.path
        return $Results
    }

    foreach ($SubKey in $SubKeys)
    {
        $Results += New-WtRegistryKey -Path $SubKey.Path
    }

    foreach ($SubKey in $SubKeys)
    {
        foreach ($Value in @($SubKey.Values))
        {
            $Kind = Resolve-WtRegistryKind -Kind $Value.Kind
            if (-not $Kind) { $Kind = 'String' }

            $Results += Set-WtRegistryValue -Path $SubKey.Path -Name $Value.Name -Value (ConvertFrom-WtPersistableValue -Value $Value.Value) -Kind $Kind
        }
    }

    return $Results
}

<#
.SYNOPSIS
    Restores one captured record of any supported kind.
#>
function Restore-WtStateRecord
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param ([Parameter(Mandatory = $true)][object]$Record)

    switch ($Record.resource)
    {
        'Registry'
        {
            return Restore-WtRegistryRecord -Record $Record
        }
        'RegistryKey'
        {
            return Restore-WtRegistryKeyRecord -Record $Record
        }
        'Service'
        {
            $Parameters = @{ Name = $Record.name }
            $StartupType = ConvertTo-WtServiceStartupType -StartupType $Record.startupType
            if ($StartupType) { $Parameters.StartupType = $StartupType }
            if ($Record.status) { $Parameters.Status = $Record.status }

            if ($Parameters.Count -eq 1)
            {
                return New-WtOperationResult -Status 'skipped' -Operation 'RestoreService' -Target $Record.name -Message "No restorable service configuration was captured for $($Record.name)."
            }

            return Set-WtServiceState @Parameters
        }
        'ScheduledTask'
        {
            if (-not $Record.exists)
            {
                return New-WtOperationResult -Status 'skipped' -Operation 'RestoreScheduledTask' -Target "$($Record.path)$($Record.name)" -Message 'Task did not exist at capture time.'
            }

            return Set-WtScheduledTaskState -Path $Record.path -Name $Record.name -Enabled ([bool]$Record.enabled)
        }
        'FirewallGroup'
        {
            $Results = @()
            foreach ($Rule in @($Record.rules))
            {
                $Parameters = @{ Name = $Rule.Name; Enabled = [string]$Rule.Enabled }
                if ($Rule.Action) { $Parameters.Action = [string]$Rule.Action }
                # Profile is only present in records captured after the profile became
                # part of the snapshot; older records restore Enabled/Action alone.
                if ($Rule.PSObject.Properties.Name -contains 'Profile' -and $Rule.Profile) { $Parameters.Profile = [string]$Rule.Profile }

                if (-not $PSCmdlet.ShouldProcess($Rule.Name, "restore firewall rule (enabled=$($Rule.Enabled))"))
                {
                    $Results += New-WtOperationResult -Status (Get-WtShouldProcessStatus) -Operation 'RestoreFirewallRule' -Target $Rule.Name -Message "Would restore firewall rule $($Rule.Name)"
                    continue
                }

                try
                {
                    Set-WtFirewallRuleRaw @Parameters
                    $Results += New-WtOperationResult -Status 'succeeded' -Operation 'RestoreFirewallRule' -Target $Rule.Name -Message "Restored firewall rule $($Rule.Name) (enabled=$($Rule.Enabled))"
                }
                catch
                {
                    $Results += New-WtOperationResult -Status 'failed' -Operation 'RestoreFirewallRule' -Target $Rule.Name -Message $_.Exception.Message -ErrorRecord $_
                }
            }
            return $Results
        }
        'AdapterPower'
        {
            if (-not $Record.exists)
            {
                return New-WtOperationResult -Status 'skipped' -Operation 'RestoreAdapterPower' -Target "interface $($Record.interfaceIndex)" -Message 'The adapter did not report a power management setting at capture time.'
            }

            if ([string]::IsNullOrEmpty([string]$Record.allowComputerToTurnOffDevice))
            {
                return New-WtOperationResult -Status 'skipped' -Operation 'RestoreAdapterPower' -Target "interface $($Record.interfaceIndex)" -Message 'No restorable adapter power value was captured.'
            }

            return Set-WtAdapterPowerState -InterfaceIndex ([int]$Record.interfaceIndex) -AllowComputerToTurnOffDevice ([string]$Record.allowComputerToTurnOffDevice)
        }
        'DnsServer'
        {
            $Target = "interface $($Record.interfaceIndex)"
            $Description = if ($Record.automatic) { 'obtain DNS servers automatically' } else { "restore DNS servers $((@($Record.serverAddresses)) -join ', ')" }

            if (-not $PSCmdlet.ShouldProcess($Target, $Description))
            {
                return New-WtOperationResult -Status (Get-WtShouldProcessStatus) -Operation 'RestoreDnsServer' -Target $Target -Message "Would $Description"
            }

            if (-not (Test-WtDnsAvailable))
            {
                return New-WtOperationResult -Status 'unsupported' -Operation 'RestoreDnsServer' -Target $Target -Message 'DnsClient module is not available on this platform.'
            }

            try
            {
                if ($Record.automatic)
                {
                    Reset-WtDnsServerAddressRaw -InterfaceIndex ([int]$Record.interfaceIndex)
                }
                else
                {
                    Set-WtDnsServerAddressRaw -InterfaceIndex ([int]$Record.interfaceIndex) -ServerAddresses @($Record.serverAddresses)
                }
            }
            catch
            {
                return New-WtOperationResult -Status 'failed' -Operation 'RestoreDnsServer' -Target $Target -Message $_.Exception.Message -ErrorRecord $_
            }

            return New-WtOperationResult -Status 'succeeded' -Operation 'RestoreDnsServer' -Target $Target -Message "Restored DNS configuration on $Target"
        }
        'MpPreference'
        {
            $Value = ConvertFrom-WtPersistableValue -Value $Record.value
            if ($null -eq $Value)
            {
                return New-WtOperationResult -Status 'skipped' -Operation 'RestoreMpPreference' -Target $Record.name -Message "No restorable Defender preference value was captured for $($Record.name)."
            }

            return Set-WtMpPreferenceState -Name $Record.name -Value $Value -Reason 'rollback'
        }
        'AppxPackage'
        {
            # Removal deletes package data; there is nothing to restore.
            return New-WtOperationResult -Status 'skipped' -Operation 'RestoreAppxPackage' -Target $Record.name -Message "Package removal is irreversible: $($Record.name) ($($Record.fullName)) must be reinstalled from the Microsoft Store." -Rollback None
        }
        default
        {
            return New-WtOperationResult -Status 'skipped' -Operation 'Restore' -Target $Record.resource -Message "No rollback handler for resource kind '$($Record.resource)'."
        }
    }
}

<#
.SYNOPSIS
    Rolls back a captured history entry (records replayed newest-first).
#>
function Invoke-WtRollback
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param ([Parameter(Mandatory = $true)][object]$HistoryEntry)

    $Records = @($HistoryEntry.records)
    if ($Records.Count -eq 0)
    {
        return @()
    }

    [array]::Reverse($Records)

    # Rollback must not capture new pre-state: run with an empty context.
    $PreviousContext = Get-WtOperationContext
    Set-WtOperationContext -HistoryEntry $null -DryRun ([bool]$WhatIfPreference) -Phase 'rollback' -SuppressConfirm $true

    try
    {
        $Results = @()
        foreach ($Record in $Records)
        {
            $Results += Restore-WtStateRecord -Record $Record
        }
        return $Results
    }
    finally
    {
        Set-WtOperationContext -HistoryEntry $PreviousContext.HistoryEntry -DryRun $PreviousContext.DryRun -Phase $PreviousContext.Phase -SuppressConfirm $PreviousContext.SuppressConfirm
    }
}

<#
.SYNOPSIS
    Reads every recorded target back and reports whether it now holds the expected value.
.DESCRIPTION
    Used twice: after applying (expected = what was intended) and after restoring (expected =
    what was captured). Only targets with a reader can be verified; the rest are counted as
    unverifiable and reported by name, so "we could not check" is never displayed as "verified".
.PARAMETER UseOriginal
    Compare against the captured (pre-change) value instead of the intended one.
#>
function Test-WtAppliedTargets
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $false)][switch]$UseOriginal
    )

    $Rows = [System.Collections.Generic.List[object]]::new()
    $Verified = 0
    $Mismatched = 0
    $Unverifiable = 0

    foreach ($Target in @($Entry.targets))
    {
        $Identity = [string]$Target.identity
        $Expected = if ($UseOriginal) { $Target.original } else { $Target.intended }
        $Label = Format-WtTargetIdentity -Identity $Identity -Label ([string]$Target.label)

        if (-not $Identity)
        {
            $Unverifiable++
            $Target.verified = $null
            $Rows.Add(@{ identity = ''; label = $Label; status = 'unidentifiable'; expected = ''; live = '' })
            continue
        }

        $Live = Get-WtTargetState -Identity $Identity
        if ($Live.Reader -eq '')
        {
            $Unverifiable++
            $Target.verified = $null
            $Rows.Add(@{ identity = $Identity; label = $Label; status = 'unsupported'; expected = ''; live = '' })
            continue
        }

        if ($Live.ValueKind -eq 'Unreadable')
        {
            $Unverifiable++
            $Target.verified = $null
            $Rows.Add(@{ identity = $Identity; label = $Label; status = 'unreadable'; expected = ''; live = '' })
            continue
        }

        $ExpectedDisplay = ''
        $Match = $true

        if (-not $Expected)
        {
            $Unverifiable++
            $Target.verified = $null
            $Rows.Add(@{ identity = $Identity; label = $Label; status = 'unrecorded'; expected = ''; live = (ConvertTo-WtTargetDisplayValue -Value $Live.Value -ValueKind $Live.ValueKind) })
            continue
        }

        if ([string]$Expected.kind -eq 'Absent' -or [string]$Expected.valueKind -eq 'Absent')
        {
            $ExpectedDisplay = '(absent)'
            $Match = ($Live.ValueKind -eq 'Absent')
        }
        else
        {
            $ExpectedDisplay = [string]$Expected.display
            $Match = Test-WtTargetValueMatch -Left $Live.Value -Right $Expected.value
        }

        $Target.verified = $Match
        $LiveDisplay = ConvertTo-WtTargetDisplayValue -Value $Live.Value -ValueKind $Live.ValueKind

        if ($Match) { $Verified++ } else { $Mismatched++ }

        $Rows.Add(@{
            identity = $Identity
            label    = $Label
            status   = $(if ($Match) { 'verified' } else { 'mismatch' })
            expected = $ExpectedDisplay
            live     = $LiveDisplay
        })
    }

    return @{
        Attempted    = $true
        Verified     = $Verified
        Mismatched   = $Mismatched
        Unverifiable = $Unverifiable
        Rows         = @($Rows.ToArray())
        VerifiedUtc  = (Get-Date).ToUniversalTime().ToString('o')
    }
}

<#
.SYNOPSIS
    Attempts to undo the targets that already succeeded after a partial failure.
.DESCRIPTION
    Compensating restoration, not atomic rollback: every recorded target is replayed through
    the normal restore path (newest first), and the outcome is reported per target. Targets
    whose platform refuses restoration (a removed package, a truncated key subtree) are
    reported as failures of the compensation, and the captured recovery data is kept so the
    user can retry deliberately. Nothing here claims that Windows offers an atomic rollback.
#>
function Invoke-WtCompensation
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Entry)

    $Records = @($Entry.records)
    if ($Records.Count -eq 0)
    {
        return @{ Attempted = $false; Succeeded = 0; Failed = 0; Messages = @('No captured state to compensate with.'); Results = @(); CompensationUtc = (Get-Date).ToUniversalTime().ToString('o') }
    }

    [array]::Reverse($Records)

    # Compensation is a restore: it must not capture new pre-state and must not prompt.
    $PreviousContext = Get-WtOperationContext
    Set-WtOperationContext -HistoryEntry $null -DryRun $false -Phase 'compensation' -SuppressConfirm $true

    try
    {
        $Results = @()
        foreach ($Record in $Records)
        {
            $Results += Restore-WtStateRecord -Record $Record
        }
    }
    finally
    {
        Set-WtOperationContext -HistoryEntry $PreviousContext.HistoryEntry -DryRun $PreviousContext.DryRun -Phase $PreviousContext.Phase -SuppressConfirm $PreviousContext.SuppressConfirm
    }

    $Statuses = @($Results | Where-Object { $_ -and ($_.PSObject.Properties.Name -contains 'Status') })
    $Succeeded = @($Statuses | Where-Object { $_.Status -in 'succeeded', 'unchanged' }).Count
    $Failed = @($Statuses | Where-Object { $_.Status -in 'failed', 'unsupported' }).Count
    $Skipped = @($Statuses | Where-Object { $_.Status -eq 'skipped' }).Count

    $Messages = @()
    if ($Succeeded -gt 0) { $Messages += "Compensated $Succeeded target(s) back to their captured value." }
    if ($Failed -gt 0) { $Messages += "Compensation failed for $Failed target(s); the captured state is kept for a manual retry." }
    if ($Skipped -gt 0) { $Messages += "$Skipped target(s) cannot be restored by design (irreversible kind)." }

    return @{
        Attempted        = $true
        Succeeded        = $Succeeded
        Failed           = $Failed
        Skipped          = $Skipped
        Messages         = $Messages
        Results          = $Results
        CompensationUtc  = (Get-Date).ToUniversalTime().ToString('o')
    }
}
