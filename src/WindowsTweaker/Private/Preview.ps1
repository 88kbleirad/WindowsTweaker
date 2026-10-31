# WindowsTweaker - exact change preview, review fingerprints and conflict detection.
#
# Before a change is applied, this file answers the four questions a user actually has:
#   * what will be touched (one row per canonical target),
#   * what it holds now, keeping absent / unreadable / empty / zero apart,
#   * what it will hold afterwards, with its type,
#   * what can be recovered, and whether an earlier baseline already covers it.
#
# The preview is produced with the real code path: the declared operation list of a
# declarative tweak, or a dry run of a scripted tweak (which never writes). Every row is
# then completed by a read-only read of the live state.
#
# A preview also carries a fingerprint over the reviewed rows. The interface passes it back
# when the user confirms, and the engine recomputes the preview immediately before executing:
# if anything moved in between, the change is not applied and a new review is required.

<#
.SYNOPSIS
    Returns the target rows a tweak state declares (declarative tweaks).
.DESCRIPTION
    Declarative tweaks describe every write as an operation list, so the preview can name
    the targets and the intended values before anything runs.
#>
function Get-WtDeclaredOperation
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Tweak,
        [Parameter(Mandatory = $false)][string]$State
    )

    if (-not $State) { return @() }

    $States = $null
    if ($Tweak.PSObject.Properties.Name -contains 'States') { $States = $Tweak.States }
    if (-not $States) { return @() }

    if ($States -is [System.Collections.IDictionary])
    {
        if (-not $States.Contains($State)) { return @() }
        return @($States[$State])
    }

    if ($States.PSObject.Properties.Name -contains $State)
    {
        return @($States.$State)
    }

    return @()
}

<#
.SYNOPSIS
    Describes what one declared operation will do to its target.
.OUTPUTS
    @{ Kind = 'Set'|'Remove'|'CreateKey'|'RemoveKey'|'Configure'; Value; Display; Type; Operation }
#>
function Get-WtIntendedChange
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][hashtable]$Operation)

    $Result = @{ Kind = 'Configure'; Value = $null; Display = ''; Type = ''; Operation = [string]$Operation.Kind }

    switch ([string]$Operation.Kind)
    {
        'RegistrySet'
        {
            $Kind = Resolve-WtRegistryKind -Kind $Operation.Type
            $Result.Kind = 'Set'
            $Result.Value = $Operation.Value
            $Result.Type = [string]$Kind
            $Result.Display = ConvertTo-WtTargetDisplayValue -Value $Operation.Value
        }
        'RegistryRemove'
        {
            $Result.Kind = 'Remove'
            $Result.Display = '(removed)'
        }
        'RegistryKeyCreate'
        {
            $Result.Kind = 'CreateKey'
            $Result.Display = '(key created)'
        }
        'RegistryKeyRemove'
        {
            $Result.Kind = 'RemoveKey'
            $Result.Display = '(key removed)'
        }
        'Service'
        {
            $Parts = @()
            if ($Operation.StartupType) { $Parts += "startup $($Operation.StartupType)" }
            if ($Operation.Status) { $Parts += "state $($Operation.Status)" }
            $Result.Kind = 'Configure'
            $Result.Value = ($Parts -join ', ')
            $Result.Display = ($Parts -join ', ')
        }
        'ScheduledTask'
        {
            $Result.Kind = 'Configure'
            $Result.Value = [bool]$Operation.Enabled
            $Result.Display = $(if ($Operation.Enabled) { 'enabled' } else { 'disabled' })
        }
        'FirewallGroup'
        {
            $Parts = @()
            if ($Operation.ContainsKey('Enabled')) { $Parts += "enabled=$($Operation.Enabled)" }
            if ($Operation.Action) { $Parts += "action=$($Operation.Action)" }
            $Result.Kind = 'Configure'
            $Result.Value = ($Parts -join ', ')
            $Result.Display = ($Parts -join ', ')
        }
    }

    return $Result
}

<#
.SYNOPSIS
    Builds one preview row for a canonical target.
#>
function New-WtChangeTarget
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $false)][string]$Label = '',
        [Parameter(Mandatory = $false)][string]$Operation = '',
        [Parameter(Mandatory = $false)][object]$Intended,
        [Parameter(Mandatory = $false)][object]$Current
    )

    if (-not $Current)
    {
        $Current = Get-WtTargetState -Identity $Identity
    }

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.ChangeTarget'
        Identity   = $Identity
        Label      = (Format-WtTargetIdentity -Identity $Identity -Label $Label)
        Class      = [string]$Current.Class
        Operation  = $Operation
        Current    = @{
            ValueKind = [string]$Current.ValueKind
            Value     = $Current.Value
            Display   = (ConvertTo-WtTargetDisplayValue -Value $Current.Value -ValueKind $Current.ValueKind)
            Type      = [string]$Current.Kind
            Readable  = ($Current.Reader -ne '' -and $Current.ValueKind -ne 'Unreadable')
            Reason    = [string]$Current.Reason
        }
        Intended   = if ($Intended) { $Intended } else { $null }
        Recovery   = @{
            Rollback           = 'Full'
            Irreversible       = $false
            DataDeletion       = $false
            BaselineOperationId = $null
            BaselinePreserved  = $false
        }
        Verified   = $null
    }
}

<#
.SYNOPSIS
    Computes the fingerprint of a set of preview rows.
.DESCRIPTION
    The fingerprint covers the tweak, the requested state, the arguments and, per target,
    the identity plus the *observed* current value state. It deliberately does not cover
    timestamps, so a review stays valid while nothing actually moved.
#>
function Get-WtChangeFingerprint
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][object]$Preview)

    $Lines = [System.Collections.Generic.List[string]]::new()
    $Lines.Add("tweak=$($Preview.TweakId)|state=$($Preview.State)")

    if ($Preview.Arguments)
    {
        $Lines.Add("args=$(($Preview.Arguments.GetEnumerator() | Sort-Object -Property Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',')")
    }

    foreach ($Target in @($Preview.Targets | Sort-Object -Property Identity))
    {
        $Lines.Add("target=$($Target.Identity)|current=$($Target.Current.ValueKind):$($Target.Current.Display)")
    }

    $Payload = [System.Text.Encoding]::UTF8.GetBytes(($Lines -join "`n"))
    $Hash = [System.Security.Cryptography.SHA256]::Create()
    try
    {
        return (($Hash.ComputeHash($Payload) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally
    {
        $Hash.Dispose()
    }
}

<#
.SYNOPSIS
    Best-effort identity for a target label reported by a provider.
.DESCRIPTION
    Scripted tweaks build their operations at run time, so the dry run reports a label
    instead of a descriptor. A registry-looking label can still be turned into a canonical
    identity, which is what makes a preview of those tweaks comparable and checkable; any
    other shape stays unidentified and is reported as such rather than being guessed.
#>
function Get-WtTargetIdentityFromLabel
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][AllowEmptyString()][string]$Label)

    if ([string]::IsNullOrWhiteSpace($Label))
    {
        return ''
    }

    if ($Label -match '^(HKLM|HKCU|HKCR|HKU|HKCC):\\(?<Path>.+?)\\(?<Name>[^\\]+)$')
    {
        return (New-WtTargetIdentity -Class 'Registry' -Path $Matches.Path -Name $Matches.Name)
    }

    if ($Label -match '^(HKLM|HKCU|HKCR|HKU|HKCC):\\(?<Path>.+)$')
    {
        return (New-WtTargetIdentity -Class 'RegistryKey' -Path $Matches.Path)
    }

    return ''
}

<#
.SYNOPSIS
    Produces the exact preview of one tweak state.
.DESCRIPTION
    Read-only end to end: the declared operation list is read from the definition, and a
    scripted tweak is dry-run (WhatIf) through its own Apply implementation, which the tests
    prove writes nothing. Each target is then read back from the live system so the preview
    shows the current value, its type, its scope, the support status and the recovery limits.
.PARAMETER Id
    Tweak id.
.PARAMETER State
    Requested state; defaults to the tweak's default state.
.PARAMETER Arguments
    Parameters for parameterized tweaks (without them, the preview reports that it needs them).
.OUTPUTS
    A preview object: TweakId, State, Arguments, Supported, Support, Scope, Privilege,
    Restart, Recovery, Targets, Conflicts, Complete, Messages, Fingerprint, DetectedState.
#>
function Get-WtChangePreviewInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $false)][string]$State,
        [Parameter(Mandatory = $false)][hashtable]$Arguments
    )

    $Tweak = Get-WtTweakInternal -Id $Id
    if (-not $Tweak)
    {
        throw (Get-WtString -Key 'Error.TweakNotFound' -Arguments @($Id))
    }

    if (-not $State)
    {
        $State = $Tweak.DefaultState
    }

    if (-not $State -and @($Tweak.StateNames).Count -eq 0)
    {
        throw (Get-WtString -Key 'Error.StateRequired' -Arguments @($Id))
    }

    if (@($Tweak.StateNames).Count -gt 0 -and $Tweak.StateNames -notcontains $State)
    {
        throw (Get-WtString -Key 'Error.InvalidState' -Arguments @($State, $Id, (@($Tweak.StateNames) -join ', ')))
    }

    $Prerequisite = Test-WtPrerequisite -Tweak $Tweak
    $Detected = Get-WtTweakState -Tweak $Tweak -Arguments $Arguments | Select-Object -First 1

    $Targets = [System.Collections.Generic.List[object]]::new()
    $Messages = [System.Collections.Generic.List[string]]::new()
    $Complete = $true

    # 1. Declarative tweaks: the operation list *is* the plan.
    foreach ($Operation in @(Get-WtDeclaredOperation -Tweak $Tweak -State $State))
    {
        if ($Operation -isnot [hashtable]) { continue }

        $Identity = Get-WtOperationIdentity -Operation $Operation
        if (-not $Identity) { continue }

        $Label = ''
        if ($Operation.ContainsKey('Path') -and $Operation.ContainsKey('Name')) { $Label = "$($Operation.Path)\$($Operation.Name)" }
        elseif ($Operation.ContainsKey('Path')) { $Label = [string]$Operation.Path }
        elseif ($Operation.ContainsKey('Name')) { $Label = [string]$Operation.Name }
        elseif ($Operation.ContainsKey('Group')) { $Label = [string]$Operation.Group }

        $Targets.Add((New-WtChangeTarget -Identity $Identity -Label $Label -Operation ([string]$Operation.Kind) -Intended (Get-WtIntendedChange -Operation $Operation)))
    }

    # 2. Scripted tweaks: dry-run the real implementation and keep the reported targets.
    if ($Targets.Count -eq 0 -and $Prerequisite.Supported)
    {
        if (@($Tweak.Parameters).Count -gt 0 -and -not $Arguments)
        {
            $Complete = $false
            $Messages.Add((Get-WtString -Key 'Tui.Args.Unsupported' -Arguments @((@($Tweak.Parameters) -join ', '))))
        }
        else
        {
            $PreviousWhatIf = $WhatIfPreference
            $PreviousContext = Get-WtOperationContext
            $WhatIfPreference = $true
            Set-WtOperationContext -HistoryEntry $null -DryRun $true -Phase 'preview' -SuppressConfirm $true

            try
            {
                $Raw = @(& $Tweak.Apply $Tweak $State $Arguments)
            }
            finally
            {
                Set-WtOperationContext -HistoryEntry $PreviousContext.HistoryEntry -DryRun $PreviousContext.DryRun -Phase $PreviousContext.Phase -SuppressConfirm $PreviousContext.SuppressConfirm
                $WhatIfPreference = $PreviousWhatIf
            }

            foreach ($Result in @($Raw | Where-Object { $_ -and ($_.PSObject.Properties.Name -contains 'Status') }))
            {
                if ([string]$Result.Status -ne 'dryrun') { continue }

                $Label = [string]$Result.Target
                $Identity = Get-WtTargetIdentityFromLabel -Label $Label
                $Intended = @{ Kind = 'Configure'; Value = $null; Display = [string]$Result.Message; Type = ''; Operation = [string]$Result.Operation }

                if ($Identity)
                {
                    $Targets.Add((New-WtChangeTarget -Identity $Identity -Label $Label -Operation ([string]$Result.Operation) -Intended $Intended))
                }
                else
                {
                    # No canonical identity: the target is shown and flagged, but it cannot be
                    # compared with another tweak or verified afterwards.
                    $Complete = $false
                    $Unknown = New-WtChangeTarget -Identity '' -Label $Label -Operation ([string]$Result.Operation) -Intended $Intended -Current @{
                        Class = 'Unknown'; ValueKind = 'Unreadable'; Value = $null; Kind = ''; Reader = ''; Reason = 'The target is only known once the change has run.'
                    }
                    $Targets.Add($Unknown)
                }
            }

            if ($Targets.Count -eq 0)
            {
                $Complete = $false
                $Messages.Add((Get-WtString -Key 'Tui.Details.None'))
            }
        }
    }

    # 3. Recovery limits, per target and per tweak.
    $Recovery = @{
        Rollback      = [string]$Tweak.Rollback
        Irreversible  = [bool]$Tweak.Irreversible
        DataDeletion  = [bool]$Tweak.DataDeletion
        Restart       = [string]$Tweak.Restart
        BaselineCount = 0
    }

    foreach ($Target in $Targets)
    {
        $Target.Recovery.Rollback = [string]$Tweak.Rollback
        $Target.Recovery.Irreversible = [bool]$Tweak.Irreversible
        $Target.Recovery.DataDeletion = [bool]$Tweak.DataDeletion

        if ($Target.Identity)
        {
            $Baseline = Get-WtBaselineEntry -Identity $Target.Identity
            if ($Baseline)
            {
                $Target.Recovery.BaselineOperationId = [string]$Baseline.operationId
                $Target.Recovery.BaselinePreserved = $true
                $Recovery.BaselineCount++
            }
        }
    }

    if (@($Targets | Where-Object { $_.Recovery.BaselinePreserved }).Count -gt 0)
    {
        $Messages.Add((Get-WtString -Key 'Tui.Preview.BaselineKept' -Arguments @($Recovery.BaselineCount)))
    }

    $Preview = [pscustomobject]@{
        PSTypeName    = 'WindowsTweaker.ChangePreview'
        TweakId       = $Id
        State         = $State
        Arguments     = $Arguments
        Supported     = [bool]$Prerequisite.Supported
        Support       = @{ Supported = [bool]$Prerequisite.Supported; Reason = [string]$Prerequisite.Reason; Missing = @($Prerequisite.Missing) }
        Scope         = [string]$Tweak.Scope
        Privilege     = [string]$Tweak.Privilege
        Restart       = [string]$Tweak.Restart
        Irreversible  = [bool]$Tweak.Irreversible
        Lifecycle     = [string]$(if ($Tweak.PSObject.Properties.Name -contains 'Lifecycle') { $Tweak.Lifecycle } else { 'Available' })
        Recovery      = $Recovery
        Targets       = @($Targets.ToArray())
        Conflicts     = @()
        Complete      = $Complete
        DetectedState = [string]$Detected.State
        Messages      = @($Messages.ToArray())
        Fingerprint   = ''
        ReviewedUtc   = (Get-Date).ToUniversalTime().ToString('o')
    }

    $Preview.Fingerprint = Get-WtChangeFingerprint -Preview $Preview
    return $Preview
}

<#
.SYNOPSIS
    Finds overlapping targets between previews (and inside one preview).
.DESCRIPTION
    A conflict is reported when two different tweaks write the same canonical target, or when
    one writes a registry key that contains the other's value. The rows name both sides and
    the reason, so the interface can explain the conflict before anything is applied.
.PARAMETER Preview
    One or more preview objects.
#>
function Get-WtChangeConflictInternal
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$Preview = @())

    $Rows = [System.Collections.Generic.List[object]]::new()
    $Owners = @{}

    foreach ($Item in @($Preview))
    {
        foreach ($Target in @($Item.Targets))
        {
            if (-not $Target.Identity) { continue }

            foreach ($Existing in @($Owners.Keys))
            {
                if ($Owners[$Existing].TweakId -eq $Item.TweakId) { continue }
                if (-not (Test-WtTargetOverlap -Left $Existing -Right $Target.Identity)) { continue }

                $Rows.Add([pscustomobject]@{
                    PSTypeName = 'WindowsTweaker.ChangeConflict'
                    Identity   = [string]$Target.Identity
                    Label      = (Format-WtTargetIdentity -Identity ([string]$Target.Identity) -Label ([string]$Target.Label))
                    Left       = [string]$Owners[$Existing].TweakId
                    LeftState  = [string]$Owners[$Existing].State
                    Right      = [string]$Item.TweakId
                    RightState = [string]$Item.State
                    Reason     = if ($Existing -eq $Target.Identity) { 'Both tweaks write the same target.' } else { 'One target is a registry key that contains the other target.' }
                })
            }

            if (-not $Owners.ContainsKey($Target.Identity))
            {
                $Owners[$Target.Identity] = @{ TweakId = [string]$Item.TweakId; State = [string]$Item.State }
            }
        }
    }

    return @($Rows.ToArray())
}

<#
.SYNOPSIS
    Recomputes a preview and reports whether the reviewed state still holds.
.DESCRIPTION
    Called immediately before execution. The preview is regenerated (detection plus a dry
    run, both read-only) and compared with the reviewed fingerprint; a difference - a value
    that appeared, changed, became unreadable, or a different detected state - means the user
    reviewed something that is no longer true, so the change is refused and a new review is
    required.
.OUTPUTS
    @{ Match; ExpectedFingerprint; CurrentFingerprint; Changed; Preview }
#>
function Test-WtReviewedState
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Preview,
        [Parameter(Mandatory = $false)][string]$Fingerprint = ''
    )

    $Expected = if ($Fingerprint) { $Fingerprint } else { [string]$Preview.Fingerprint }
    $Current = Get-WtChangePreviewInternal -Id $Preview.TweakId -State $Preview.State -Arguments $Preview.Arguments

    $Changed = [System.Collections.Generic.List[object]]::new()
    $Before = @{}
    foreach ($Target in @($Preview.Targets)) { if ($Target.Identity) { $Before[$Target.Identity] = $Target.Current } }

    foreach ($Target in @($Current.Targets))
    {
        if (-not $Target.Identity) { continue }

        if (-not $Before.ContainsKey($Target.Identity))
        {
            $Changed.Add(@{ Identity = $Target.Identity; Label = $Target.Label; Change = 'appeared'; Was = ''; Now = [string]$Target.Current.Display })
            continue
        }

        $Old = $Before[$Target.Identity]
        if ($Old.ValueKind -ne $Target.Current.ValueKind -or $Old.Display -ne $Target.Current.Display)
        {
            $Changed.Add(@{
                Identity = $Target.Identity
                Label    = $Target.Label
                Change   = 'value'
                Was      = ("{0}: {1}" -f $Old.ValueKind, $Old.Display)
                Now      = ("{0}: {1}" -f $Target.Current.ValueKind, $Target.Current.Display)
            })
        }
    }

    foreach ($Identity in @($Before.Keys))
    {
        if (-not @($Current.Targets | Where-Object { $_.Identity -eq $Identity }))
        {
            $Changed.Add(@{ Identity = $Identity; Label = $Identity; Change = 'disappeared'; Was = [string]$Before[$Identity].Display; Now = '' })
        }
    }

    if ($Current.DetectedState -ne $Preview.DetectedState)
    {
        $Changed.Add(@{ Identity = ''; Label = $Preview.TweakId; Change = 'state'; Was = [string]$Preview.DetectedState; Now = [string]$Current.DetectedState })
    }

    return @{
        Match              = ([bool]($Current.Fingerprint -eq $Expected) -and $Changed.Count -eq 0)
        ExpectedFingerprint = $Expected
        CurrentFingerprint  = [string]$Current.Fingerprint
        Changed            = @($Changed.ToArray())
        Preview            = $Current
    }
}
