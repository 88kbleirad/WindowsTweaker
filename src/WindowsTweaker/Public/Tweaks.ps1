# WindowsTweaker - state detection, apply and rollback (public API).

<#
.SYNOPSIS
    Reports the current state of a tweak without changing anything.
.DESCRIPTION
    Detection is strictly read-only. The result combines:
      State          - Enabled / Disabled / Mixed / Unknown / Unsupported / <custom state>
      Supported      - whether the tweak can run here, with UnsupportedReason
      Managed        - whether an organization policy governs the setting
      Details        - detector explanation
.PARAMETER Id
    Exact tweak id (with -Id), category (with -Category) or free text (with -Search).
.PARAMETER Arguments
    Parameters for parameterized tweaks (DNS adapter index, DoH template, ...).
#>
function Get-WtTweakState
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $false, ValueFromPipeline = $true)][psobject]$Tweak,
        [Parameter(Mandatory = $false)][string]$Id,
        [Parameter(Mandatory = $false)][string]$Category,
        [Parameter(Mandatory = $false)][string]$Search,
        [Parameter(Mandatory = $false)][hashtable]$Arguments,
        [Parameter(Mandatory = $false)][switch]$Dimensions
    )

    begin
    {
        # The three dimensions cost one preview (live reads of every target) and one journal
        # lookup per tweak, so they are opt-in: the plain listing stays a cheap detection pass.
        $Pending = if ($Dimensions) { Get-WtPendingRestartInternal } else { $null }

        $Tweaks = if ($Tweak)
        {
            @($Tweak)
        }
        else
        {
            @(Get-WtTweakInternal -Id $Id -Category $Category -Search $Search)
        }
    }

    process
    {
        foreach ($Item in $Tweaks)
        {
            $Prerequisite = Test-WtPrerequisite -Tweak $Item

            $Lifecycle = if ($Item.PSObject.Properties.Name -contains 'Lifecycle') { [string]$Item.Lifecycle } else { 'Available' }
            $State = 'Unknown'
            $Details = ''
            $Instances = @()

            if (-not $Prerequisite.Supported)
            {
                $State = 'Unsupported'
                $Details = $Prerequisite.Reason
            }
            elseif ($Item.Detect)
            {
                try
                {
                    $Detection = & $Item.Detect $Item $Arguments

                    if ($null -ne $Detection)
                    {
                        $DetectedState = Get-WtDetectionField -Detection $Detection -Field 'State'
                        if ($DetectedState)
                        {
                            $State = [string]$DetectedState
                        }

                        $DetectedReason = Get-WtDetectionField -Detection $Detection -Field 'Reason'
                        if ($DetectedReason)
                        {
                            $Details = [string]$DetectedReason
                        }

                        $DetectedInstances = Get-WtDetectionField -Detection $Detection -Field 'Instances'
                        if ($DetectedInstances)
                        {
                            $Instances = @($DetectedInstances)
                        }
                    }
                }
                catch
                {
                    Write-WtLog -Level Error -Message "Detection failed for $($Item.Id)" -TweakId $Item.Id -Operation 'Detect' -Status 'failed' -Exception $_.Exception
                    $State = 'Unknown'
                    $Details = $_.Exception.Message
                }
            }

            $ManagedBy = @()
            foreach ($Policy in @($Item.ManagedPolicy))
            {
                $PolicyState = Get-WtRegistryState -Path $Policy.Path -Name $Policy.Name
                if ($PolicyState.Available -and $PolicyState.ValueExists)
                {
                    $ManagedBy += "$($Policy.Path)\$($Policy.Name)"
                }
            }

            $VerificationNote = if ($Item.Rollback -eq 'Full' -and -not $Item.Detect)
            {
                Get-WtString -Key 'Status.NoCapture'
            }
            else
            {
                ''
            }

            $DimensionFields = @{}
            if ($Dimensions)
            {
                $Compared = if ($State -in '', 'Unknown', 'Unsupported') { [string]$Item.DefaultState } else { [string]$State }
                $Computed = Get-WtStateDimensionsInternal -Tweak $Item -State $Compared -Arguments $Arguments -Pending $Pending
                $DimensionFields = @{
                    Configured        = [string]$Computed.Configured
                    ConfiguredDetail  = [string]$Computed.ConfiguredDetail
                    Effective         = [string]$Computed.Effective
                    EffectiveEvidence = [string]$Computed.EffectiveEvidence
                    EffectiveReason   = [string]$Computed.EffectiveReason
                    Ownership         = [string]$Computed.Ownership
                    OwnershipDetail   = [string]$Computed.OwnershipDetail
                    OwnershipHistory  = [string]$Computed.HistoryId
                    Boundary          = [string]$Computed.Boundary
                }
            }

            $StateObject = [pscustomobject]@{
                PSTypeName         = 'WindowsTweaker.TweakState'
                Id                 = $Item.Id
                Category           = $Item.Category
                Name               = Get-WtText -Value $Item.Name
                Description        = Get-WtText -Value $Item.Description
                Impact             = Get-WtText -Value $Item.Impact
                Risk               = $Item.Risk
                Scope              = $Item.Scope
                Privilege          = $Item.Privilege
                Restart            = $Item.Restart
                Rollback           = $Item.Rollback
                Irreversible       = $Item.Irreversible
                DataDeletion       = $Item.DataDeletion
                ReducesProtection  = $Item.ReducesProtection
                StateNames         = @($Item.StateNames)
                DefaultState       = $Item.DefaultState
                Requires           = @($Item.Requires)
                State              = $State
                Details            = $Details
                Instances          = $Instances
                Supported          = $Prerequisite.Supported
                UnsupportedReason  = if ($Prerequisite.Supported) { '' } else { $Prerequisite.Reason }
                Lifecycle          = $Lifecycle
                ApplyAllowed       = ($Lifecycle -eq 'Available' -and $Prerequisite.Supported)
                Managed            = ($ManagedBy.Count -gt 0)
                ManagedBy          = $ManagedBy
                Note               = $VerificationNote
                Tweak              = $Item
            }

            foreach ($Pair in $DimensionFields.GetEnumerator())
            {
                $StateObject | Add-Member -NotePropertyName $Pair.Key -NotePropertyValue $Pair.Value -Force
            }

            $StateObject
        }
    }
}

<#
.SYNOPSIS
    Applies a tweak state, capturing the previous state for rollback.
.DESCRIPTION
    Behaviour contract:
      * -WhatIf (or a dry run) never writes a registry value, never changes a
        service, task, firewall rule or DNS setting and never downloads anything.
      * The previous state is captured before each change and stored in the state
        store; Undo-WtTweak restores exactly that state.
      * Every operation reports succeeded / failed / skipped / unsupported /
        unchanged / dryrun; a failed operation is never reported as success.
.PARAMETER Id
    Tweak id.
.PARAMETER State
    Target state; defaults to the tweak's DefaultState.
.PARAMETER Arguments
    Parameters for parameterized tweaks.
.PARAMETER IncludeRestorePoint
    Optionally create a System Restore point first. Never implicit.
#>
function Invoke-WtTweak
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $true, Position = 1)][string]$Id,
        [Parameter(Mandatory = $false, Position = 2)][string]$State,
        [Parameter(Mandatory = $false)][hashtable]$Arguments,
        [Parameter(Mandatory = $false)][switch]$IncludeRestorePoint,
        [Parameter(Mandatory = $false)][ValidateSet('manual', 'preset', 'recovery', 'reapply')][string]$Origin = 'manual',
        [Parameter(Mandatory = $false)][string]$ParentOperationId,
        [Parameter(Mandatory = $false)][string]$ReviewedFingerprint,
        [Parameter(Mandatory = $false)][switch]$NoCompensation
    )

    $Tweak = Get-WtTweakInternal -Id $Id
    if (-not $Tweak)
    {
        $Message = Get-WtString -Key 'Error.TweakNotFound' -Arguments @($Id)
        Write-WtLog -Level Error -Message $Message -TweakId $Id -Operation 'Apply' -Status 'failed'
        throw $Message
    }

    if (-not $State)
    {
        $State = $Tweak.DefaultState
    }

    if (-not $State -and @($Tweak.StateNames).Count -eq 0)
    {
        $Message = Get-WtString -Key 'Error.StateRequired' -Arguments @($Id)
        Write-WtLog -Level Error -Message $Message -TweakId $Id -Operation 'Apply' -Status 'failed'
        throw $Message
    }

    if (@($Tweak.StateNames).Count -gt 0 -and $Tweak.StateNames -notcontains $State)
    {
        $Message = Get-WtString -Key 'Error.InvalidState' -Arguments @($State, $Id, (@($Tweak.StateNames) -join ', '))
        Write-WtLog -Level Error -Message $Message -TweakId $Id -Operation 'Apply' -Status 'failed'
        throw $Message
    }

    $Prerequisite = Test-WtPrerequisite -Tweak $Tweak
    if (-not $Prerequisite.Supported)
    {
        Write-WtLog -Level Warning -Message $Prerequisite.Reason -TweakId $Id -Operation 'Apply' -Status 'unsupported'
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.InvokeResult'
            TweakId    = $Id
            State      = $State
            Status     = 'unsupported'
            DryRun     = $false
            Operations = @()
            Messages   = @($Prerequisite.Reason)
            Restart    = $Tweak.Restart
            Rollback   = $Tweak.Rollback
            Irreversible = $Tweak.Irreversible
            CapturedState = $false
        }
    }

    # Lifecycle: a retired tweak is never applied again, but its captured snapshots stay
    # restorable (Undo-WtTweak does not go through this guard).
    $Lifecycle = if ($Tweak.PSObject.Properties.Name -contains 'Lifecycle') { [string]$Tweak.Lifecycle } else { 'Available' }
    if ($Lifecycle -in 'Unsupported', 'Restore-only', 'Deprecated')
    {
        $Reason = Get-WtString -Key "Tweak.Lifecycle.$Lifecycle"
        Write-WtLog -Level Warning -Message $Reason -TweakId $Id -Operation 'Apply' -Status 'unsupported'
        return [pscustomobject]@{
            PSTypeName    = 'WindowsTweaker.InvokeResult'
            TweakId       = $Id
            State         = $State
            Status        = 'unsupported'
            DryRun        = $false
            Operations    = @()
            Messages      = @($Reason)
            Restart       = $Tweak.Restart
            Rollback      = $Tweak.Rollback
            Irreversible  = $Tweak.Irreversible
            CapturedState = $false
            Lifecycle     = $Lifecycle
        }
    }

    $DryRun = [bool]$WhatIfPreference
    $Messages = @()

    if ($Lifecycle -eq 'Experimental')
    {
        $Messages += Get-WtString -Key 'Tweak.Lifecycle.ExperimentalNote'
    }

    if ($Tweak.ReducesProtection)
    {
        $Messages += "This tweak reduces protection: $(Get-WtText -Value $Tweak.Impact)"
    }

    if ($Tweak.Irreversible -or $Tweak.DataDeletion)
    {
        $Messages += Get-WtString -Key 'Error.Irreversible' -Arguments @(Get-WtText -Value $Tweak.Name)
        if ($Tweak.DataDeletion)
        {
            $Messages += Get-WtString -Key 'Error.DataDeletion' -Arguments @(Get-WtText -Value $Tweak.Name)
        }
    }

    foreach ($Policy in @($Tweak.ManagedPolicy))
    {
        $PolicyState = Get-WtRegistryState -Path $Policy.Path -Name $Policy.Name
        if ($PolicyState.Available -and $PolicyState.ValueExists)
        {
            $Messages += Get-WtString -Key 'Error.ManagedByPolicy' -Arguments @("$($Policy.Path)\$($Policy.Name)")
        }
    }

    # A dry run is not short-circuited here on purpose: every provider reports its own
    # "would change" status, so -WhatIf enumerates exactly which operations would run.
    # -Confirm (without -WhatIf) still stops the whole tweak when the user declines.
    if (-not $WhatIfPreference -and -not $PSCmdlet.ShouldProcess($Id, "apply state '$State'"))
    {
        $Status = Get-WtShouldProcessStatus
        Write-WtLog -Message (Get-WtString -Key 'Msg.DryRun') -TweakId $Id -Operation 'Apply' -Status $Status
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.InvokeResult'
            TweakId    = $Id
            State      = $State
            Status     = $Status
            DryRun     = $DryRun
            Operations = @()
            Messages   = $Messages
            Restart    = $Tweak.Restart
            Rollback   = $Tweak.Rollback
            Irreversible = $Tweak.Irreversible
            CapturedState = $false
        }
    }

    if ($IncludeRestorePoint -and -not $DryRun)
    {
        $RestorePoint = New-WtRestorePoint -Description "WindowsTweaker: $Id"
        $Messages += $RestorePoint.Message
    }

    # ---- exact preview and review revalidation -----------------------------------------
    # The preview is read-only (declared operations, or a dry run of the scripted ones) and is
    # what the journal records as the intended change. When the caller passes the fingerprint
    # of the review it showed the user, the preview is recomputed here, immediately before
    # anything is touched: a difference means the user reviewed something that is no longer
    # true, so the change is refused instead of being applied blind.
    $Preview = $null
    try
    {
        $Preview = Get-WtChangePreviewInternal -Id $Id -State $State -Arguments $Arguments
    }
    catch
    {
        Write-WtLog -Level Warning -Message "The change preview could not be produced: $($_.Exception.Message)" -TweakId $Id -Operation 'Preview' -NoConsole
    }

    if ($Preview -and $ReviewedFingerprint)
    {
        $Review = Test-WtReviewedState -Preview $Preview -Fingerprint $ReviewedFingerprint
        if (-not $Review.Match)
        {
            $Message = Get-WtString -Key 'Msg.ReviewRequired'
            $Details = @($Review.Changed | ForEach-Object { "  - $(if ($_.Label) { $_.Label } else { $_.Identity }): $($_.Was) -> $($_.Now)" })
            Write-WtLog -Level Warning -Message $Message -TweakId $Id -Operation 'Apply' -Status 'review-required'

            return [pscustomobject]@{
                PSTypeName    = 'WindowsTweaker.InvokeResult'
                TweakId       = $Id
                State         = $State
                Status        = 'review-required'
                DryRun        = $false
                Operations    = @()
                Messages      = @($Message) + $Details
                Restart       = $Tweak.Restart
                Rollback      = $Tweak.Rollback
                Irreversible  = $Tweak.Irreversible
                CapturedState = $false
                Review        = $Review
                Preview       = $Review.Preview
            }
        }
    }

    $Entry = New-WtHistoryEntry -TweakId $Id -State $State -Arguments $Arguments -DryRun:$DryRun -Origin $Origin -ParentOperationId $ParentOperationId

    if ($Preview)
    {
        $Entry.targets = @($Preview.Targets | ForEach-Object {
                [pscustomobject]@{
                    identity = [string]$_.Identity
                    label    = [string]$_.Label
                    class    = [string]$_.Class
                    kind     = [string]$_.Operation
                    original = @{
                        valueKind = [string]$_.Current.ValueKind
                        value     = $_.Current.Value
                        display   = [string]$_.Current.Display
                        type      = [string]$_.Current.Type
                    }
                    intended = $(if ($_.Intended) {
                            @{ kind = [string]$_.Intended.Kind; value = $_.Intended.Value; display = [string]$_.Intended.Display; type = [string]$_.Intended.Type }
                        }
                        else { $null })
                    captured = $false
                    verified = $null
                }
            })
    }

    if (-not $DryRun)
    {
        # Recovery information is persisted before the first mutation. If it cannot be stored,
        # nothing is changed: an operation whose way back is unknown must not start.
        try
        {
            Add-WtJournalEntry -Entry $Entry | Out-Null
        }
        catch
        {
            $Message = "The operation journal could not be written, so nothing was changed: $($_.Exception.Message)"
            Write-WtLog -Level Error -Message $Message -TweakId $Id -Operation 'Apply' -Status 'failed' -Exception $_.Exception

            return [pscustomobject]@{
                PSTypeName    = 'WindowsTweaker.InvokeResult'
                TweakId       = $Id
                State         = $State
                Status        = 'failed'
                DryRun        = $false
                Operations    = @()
                Messages      = @($Message)
                Restart       = $Tweak.Restart
                Rollback      = $Tweak.Rollback
                Irreversible  = $Tweak.Irreversible
                CapturedState = $false
            }
        }
    }

    # The confirmation happened above (once, at tweak level); providers apply without
    # prompting again.
    Set-WtOperationContext -HistoryEntry $Entry -DryRun $DryRun -Phase 'apply' -SuppressConfirm $true

    try
    {
        $Raw = & $Tweak.Apply $Tweak $State $Arguments
    }
    finally
    {
        Set-WtOperationContext -HistoryEntry $null -DryRun $false -Phase 'none' -SuppressConfirm $false
    }

    $Operations = @($Raw | Where-Object { $_ -and ($_.PSObject.Properties.Name -contains 'Status') })
    $Status = Get-WtAggregateStatus -Results $Operations

    $CapturedState = (@($Entry.records).Count -gt 0)
    if ($Status -eq 'succeeded' -and $Tweak.Rollback -eq 'Full' -and -not $CapturedState -and -not $DryRun)
    {
        $Messages += "No previous state was captured for $Id; rollback will report itself as unavailable."
    }

    if ($Status -eq 'failed')
    {
        $Failed = @($Operations | Where-Object { $_.Status -eq 'failed' }).Count
        $Messages += Get-WtString -Key 'Msg.PartialFailure' -Arguments @($Failed)
    }

    $Outcome = switch ($Status)
    {
        'succeeded' { 'succeeded' }
        'failed' { 'failed' }
        'unchanged' { 'unchanged' }
        'dryrun' { 'dryrun' }
        'unsupported' { 'unsupported' }
        default { 'skipped' }
    }

    # ---- capture, verify, compensate ---------------------------------------------------
    $Verification = $null
    $Compensation = $null
    $Compensated = $false

    if (-not $DryRun)
    {
        # The capture the providers wrote is the authoritative way back. It is attached to the
        # target it belongs to and persisted before verification runs, so an interruption during
        # verification still leaves the recovery data on disk.
        $Captured = @($Entry.records)
        foreach ($Target in @($Entry.targets))
        {
            if (-not $Target.identity) { continue }

            $Record = @($Captured | Where-Object { (Get-WtRecordIdentity -Record $_) -eq $Target.identity }) | Select-Object -First 1
            if ($Record)
            {
                $Target.captured = $true
            }

            # A repeat apply must not lose the original way back: when an earlier operation
            # already captured this target, that baseline is referenced, not replaced.
            $Baseline = Get-WtBaselineEntry -Identity $Target.identity
            if ($Baseline -and $Baseline.operationId -ne $Entry.operationId)
            {
                $Target | Add-Member -NotePropertyName baselineOperationId -NotePropertyValue ([string]$Baseline.operationId) -Force
            }
        }

        try
        {
            Update-WtJournalStage -Entry $Entry -Stage 'applied' | Out-Null
        }
        catch
        {
            $Messages += "The operation journal could not record the applied stage: $($_.Exception.Message)"
        }

        # Read the supported targets back and say what was actually found.
        if (@($Entry.targets).Count -gt 0)
        {
            $Verification = Test-WtAppliedTargets -Entry $Entry

            if ($Verification.Mismatched -gt 0)
            {
                $Messages += Get-WtString -Key 'Msg.VerificationFailed' -Arguments @($Verification.Mismatched)
                if ($Status -eq 'succeeded' -or $Status -eq 'unchanged')
                {
                    $Status = 'failed'
                }
            }
            elseif ($Verification.Verified -gt 0)
            {
                $Messages += Get-WtString -Key 'Msg.Verified' -Arguments @($Verification.Verified)
            }
        }
    }

    if (-not $DryRun -and $Status -eq 'failed' -and -not $NoCompensation -and $Tweak.Rollback -ne 'None' -and @($Entry.records).Count -gt 0)
    {
        # Compensating restoration, not atomic rollback: the targets that already succeeded are
        # put back to their captured values and the outcome is reported per target. The captured
        # records are kept either way, so a failed compensation can still be retried by hand.
        $Compensation = Invoke-WtCompensation -Entry $Entry
        $Messages += @($Compensation.Messages)
        $Compensated = [bool]$Compensation.Attempted
    }

    $Entry.outcome = $Outcome
    $Entry.messages = @($Messages)

    if (-not $DryRun)
    {
        $Stage = if ($Status -eq 'failed') { $(if ($Compensated) { 'compensated' } else { 'failed' }) } else { 'completed' }
        try
        {
            Update-WtJournalStage -Entry $Entry -Stage $Stage -Verification $Verification -Compensation $Compensation | Out-Null
        }
        catch
        {
            $Messages += "The operation journal could not be finalized: $($_.Exception.Message)"
            Write-WtLog -Level Error -Message $Messages[-1] -TweakId $Id -Operation 'Journal' -Status 'failed' -NoConsole
        }
    }

    foreach ($Operation in $Operations)
    {
        Write-WtLog -Level Information -Message $Operation.Message -TweakId $Id -Operation $Operation.Operation -Status $Operation.Status
    }

    if ($Status -eq 'succeeded')
    {
        $Confirmation = Get-WtString -Key 'Msg.Applied'
    }
    elseif ($Status -eq 'unchanged')
    {
        $Confirmation = Get-WtString -Key 'Msg.Unchanged'
    }
    else
    {
        $Confirmation = ''
    }

    return [pscustomobject]@{
        PSTypeName    = 'WindowsTweaker.InvokeResult'
        TweakId       = $Id
        State         = $State
        Status        = $Status
        DryRun        = $DryRun
        HistoryId     = $Entry.historyId
        Operations    = $Operations
        Messages      = @($Messages + @($Confirmation) | Where-Object { $_ })
        Restart       = $Tweak.Restart
        Rollback      = $Tweak.Rollback
        Irreversible  = $Tweak.Irreversible
        CapturedState = $CapturedState
        OperationId   = $Entry.operationId
        SessionId     = $Entry.sessionId
        Origin        = $Entry.origin
        Stage         = $Entry.stage
        Targets       = @($Entry.targets)
        Preview       = $Preview
        Verified      = $(if ($Verification) { ($Verification.Mismatched -eq 0 -and $Verification.Verified -gt 0) } else { $null })
        Verification  = $Verification
        Compensation  = $Compensation
    }
}

<#
.SYNOPSIS
    Restores the state captured before a tweak was applied.
.DESCRIPTION
    Uses the stored pre-change records (values, kinds, existence, service config,
    per-adapter DNS addresses). Refuses to guess when nothing was captured.
.PARAMETER Id
    Roll back the newest applied change of this tweak.
.PARAMETER HistoryId
    Roll back a specific history entry (see Get-WtHistory).
#>
function Undo-WtTweak
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $false, ParameterSetName = 'ById', Position = 1)][string]$Id,
        [Parameter(Mandatory = $false, ParameterSetName = 'ByHistory')][string]$HistoryId,
        [Parameter(Mandatory = $false)][switch]$Force,
        [Parameter(Mandatory = $false)][ValidateSet('manual', 'recovery')][string]$Origin = 'recovery'
    )

    if ($PSCmdlet.ParameterSetName -eq 'ById' -and -not $Id)
    {
        throw 'Specify -Id or -HistoryId.'
    }

    $Entry = Get-WtRollbackCandidate -TweakId $Id -HistoryId $HistoryId
    if (-not $Entry)
    {
        $Message = Get-WtString -Key 'Error.RollbackUnavailable' -Arguments @($(if ($Id) { $Id } else { $HistoryId }))
        Write-WtLog -Level Warning -Message $Message -TweakId $Id -Operation 'Rollback' -Status 'unsupported'
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.RollbackResult'
            TweakId    = $Id
            HistoryId  = $HistoryId
            Status     = 'unsupported'
            Operations = @()
            Messages   = @($Message)
        }
    }

    $Label = if ($Entry.tweakId) { $Entry.tweakId } else { $Entry.historyId }
    $Restart = 'None'
    $Tweak = Get-WtTweakInternal -Id $Entry.tweakId
    if ($Tweak)
    {
        $Restart = $Tweak.Restart
    }

    # External changes are detected before anything is overwritten: a target whose live value
    # is no longer what this operation applied was changed by something else (another tool, a
    # policy, the user), and silently restoring over it would destroy that change. The plan is
    # computed read-only and the restore stops unless the caller insists with -Force.
    $Plan = Get-WtRestorePlanInternal -OperationId $Entry.operationId
    if (@($Plan.ExternalChanges).Count -gt 0 -and -not $Force)
    {
        $Message = Get-WtString -Key 'Msg.ExternalChange'
        $Details = @($Plan.ExternalChanges | ForEach-Object { "  - $($_.Label): applied $($_.Expected), live $($_.Live)" })
        Write-WtLog -Level Warning -Message $Message -TweakId $Entry.tweakId -Operation 'Rollback' -Status 'review-required'

        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.RollbackResult'
            TweakId    = $Entry.tweakId
            HistoryId  = $Entry.historyId
            Status     = 'review-required'
            Operations = @()
            Messages   = @($Message) + $Details
            Restart    = $Restart
            Plan       = $Plan
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Label, 'restore the previously captured state'))
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.RollbackResult'
            TweakId    = $Entry.tweakId
            HistoryId  = $Entry.historyId
            Status     = (Get-WtShouldProcessStatus)
            Operations = @()
            Messages   = @()
            Restart    = $Restart
        }
    }

    $Operations = @(Invoke-WtRollback -HistoryEntry $Entry)
    $Status = Get-WtAggregateStatus -Results $Operations

    # Read the restored targets back: a restore that reports success but leaves the value
    # behind is reported as a failure, not as "rolled back".
    $Verification = $null
    if (@($Entry.targets).Count -gt 0)
    {
        $Verification = Test-WtAppliedTargets -Entry $Entry -UseOriginal
    }

    $Messages = @()
    if ($Status -in 'succeeded', 'unchanged')
    {
        $Messages += Get-WtString -Key 'Msg.RolledBack'
        if ($Verification -and $Verification.Mismatched -gt 0)
        {
            $Status = 'failed'
            $Messages += Get-WtString -Key 'Msg.RestoreVerificationFailed' -Arguments @($Verification.Mismatched)
        }
        else
        {
            # Mark it on the in-memory entry as well: the stage write below persists this object,
            # and the marker must survive it.
            $Entry.rolledBack = $true
            $Entry.rolledBackAt = (Get-Date).ToUniversalTime().ToString('o')
            Set-WtHistoryRolledBack -HistoryId $Entry.historyId | Out-Null
        }
    }
    elseif ($Status -eq 'failed')
    {
        $Failed = @($Operations | Where-Object { $_.Status -eq 'failed' }).Count
        $Messages += Get-WtString -Key 'Msg.RollbackFailed' -Arguments @($Failed)
    }

    # Report the honest rollback fidelity: an entry containing an irreversible
    # record (e.g. a removed package) is only partially restorable.
    $IrreversibleRecords = @($Entry.records | Where-Object { $_.irreversible -eq $true }).Count
    if ($IrreversibleRecords -gt 0)
    {
        $Messages += "This change contains $IrreversibleRecords irreversible record(s); those cannot be restored."
    }

    foreach ($Operation in $Operations)
    {
        Write-WtLog -Level Information -Message $Operation.Message -TweakId $Entry.tweakId -Operation $Operation.Operation -Status $Operation.Status
    }

    $Stage = if ($Status -eq 'failed') { 'failed' } else { 'restored' }
    try
    {
        Update-WtJournalStage -Entry $Entry -Stage $Stage -Verification $Verification | Out-Null
    }
    catch
    {
        $Messages += "The operation journal could not be updated: $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.RollbackResult'
        TweakId    = $Entry.tweakId
        HistoryId  = $Entry.historyId
        Status     = $Status
        Operations = $Operations
        Messages   = $Messages
        Restart    = $Restart
        Origin     = $Origin
        Verification = $Verification
        Plan       = $Plan
    }
}
