# WindowsTweaker - TUI workflows.
#
# This file contains everything the old graphical interface did behind a window:
# argument pickers (Store packages, Windows features and capabilities, network
# adapters, DNS servers, paths), the pending-change review, the dry-run preview, the
# apply/rollback runner, presets, help and quit handling.
#
# Every workflow ends in the same place: a reviewed pending entry that is applied by
# Invoke-WtTweak/Undo-WtTweak in the worker runspace. No workflow writes anything itself,
# and the interface never opens a window, a file dialog or a message box.

#region Worker plumbing

<#
.SYNOPSIS
    Returns the worker, creating it on first use.
.DESCRIPTION
    The worker runspace is only created when a change is actually started, so opening the
    interface never imports the module a second time.
#>
function Get-WtTuiWorker
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    if (-not $State.Worker)
    {
        $State.Worker = New-WtWorker
    }

    return $State.Worker
}

<#
.SYNOPSIS
    Closes the worker runspace if one exists.
#>
function Close-WtTuiWorker
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    if ($State.Worker)
    {
        Close-WtWorker -Worker $State.Worker
        $State.Worker = $null
    }
}

<#
.SYNOPSIS
    Drains worker events and updates the operation panel, the status line and the catalog.
.DESCRIPTION
    Called from every frame, so progress and the final per-item report appear while the
    interface stays responsive. The summary is reported from the worker's own result
    objects - succeeded, failed, skipped, unsupported, unchanged and dryrun are never
    collapsed into a single "done".
#>
function Update-WtTuiOperation
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    if (-not $State.Operation -or -not $State.Worker)
    {
        return
    }

    $Events = @(Receive-WtWorkerEvent -Worker $State.Worker)
    $Finished = $false

    foreach ($WorkerEvent in $Events)
    {
        switch ($WorkerEvent.Kind)
        {
            'start'
            {
                $State.Operation.Active = [string]$WorkerEvent.Label
                $State.Operation.Started = [int]$WorkerEvent.Index
                $State.Operation.Events = @($State.Operation.Events + (Get-WtString -Key 'Tui.Busy.Started' -Arguments @($WorkerEvent.Label)))
            }
            'result'
            {
                $Status = [string]$WorkerEvent.Result.Status
                $State.Operation.Results = @($State.Operation.Results + $WorkerEvent.Result)
                $State.Operation.Events = @($State.Operation.Events + (Get-WtString -Key 'Tui.Busy.Result' -Arguments @($WorkerEvent.Label, (Get-WtString -Key "Op.$Status"))))
            }
            'error'
            {
                $State.Operation.Failures = @($State.Operation.Failures + $WorkerEvent)
                $State.Operation.Events = @($State.Operation.Events + (Get-WtString -Key 'Tui.Busy.Failed' -Arguments @($WorkerEvent.Label, [string]$WorkerEvent.Message)))
            }
            'cancelled'
            {
                $State.Operation.Events = @($State.Operation.Events + (Get-WtString -Key 'Tui.Busy.Skipped' -Arguments @($WorkerEvent.Label)))
            }
            'stopped'
            {
                # The batch stopped because a journal write failed: one line here, one primary
                # failure in the report, never the same error once per remaining tweak.
                $State.Operation.Stop = $WorkerEvent
                $State.Operation.Skipped = [int]$WorkerEvent.Skipped
                $State.Operation.Events = @($State.Operation.Events + (Get-WtString -Key 'Tui.Busy.Stopped' -Arguments @([int]$WorkerEvent.Skipped)))
            }
            'done'
            {
                $Finished = $true
                $State.Operation.Finished = [int]$WorkerEvent.Index
                $State.Operation.Active = $null
            }
            default
            {
                Write-WtLog -Level Debug -Message "Unhandled worker event: $($WorkerEvent.Kind)" -NoConsole
            }
        }
    }

    $Busy = Test-WtWorkerBusy -Worker $State.Worker
    if ($Busy -and -not $Finished)
    {
        $State.Screen.Dirty = $true
        return
    }

    if ($Busy -and $Finished)
    {
        $State.Screen.Dirty = $true
        return
    }

    if (-not $Finished)
    {
        # The task ended without a 'done' event: report it instead of pretending it ran.
        $State.Operation.Events = @($State.Operation.Events + (Get-WtString -Key 'Tui.Busy.Interrupted'))
    }

    Complete-WtTuiOperation -State $State
}

<#
.SYNOPSIS
    Turns the worker's results into the lines the user sees, with an honest summary.
.DESCRIPTION
    Pure presentation over the result objects the backend produced: succeeded, failed,
    skipped, unsupported, unchanged and dryrun are reported as they are, the restart
    requirement is collected per item, and a failure is never described as a success.
#>
function Get-WtTuiResultReport
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$Results = @(),
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$Failures = @(),
        [Parameter(Mandatory = $false)][bool]$Preview = $false,
        [Parameter(Mandatory = $false)][int]$Skipped = 0
    )

    $Lines = [System.Collections.Generic.List[string]]::new()
    $Restarts = [System.Collections.Generic.List[string]]::new()
    $Tone = 'Success'
    $Failed = 0
    $Changed = 0
    $Verified = 0
    $Compensated = 0
    $CompensationFailed = 0
    $DurableRecords = 0
    $InMemoryRecords = 0
    $Primary = ''
    $PrimaryTweak = ''
    $PrimaryStage = ''
    $Uncertain = 0
    $UncertainStages = [System.Collections.Generic.List[string]]::new()

    # A journal that could not be written is reported once, at the top, as the reason the batch
    # stopped - the per-item lines below stay as the detailed, scrollable evidence.
    foreach ($Result in $Results)
    {
        if ($null -eq $Result) { continue }
        if (-not (Test-WtJournalStopRequired -Result $Result)) { continue }

        $Uncertain++
        $UncertainStages.Add([string]$Result.Journal.UncertainStage)
        $DurableRecords += [int]$Result.Journal.DurableRecords
        $InMemoryRecords += [int]$Result.Journal.InMemoryRecords

        if (-not $Primary)
        {
            $Primary = [string]$Result.Journal.Message
            $PrimaryTweak = [string]$Result.TweakId
            $PrimaryStage = [string]$Result.Journal.UncertainStage
        }
    }

    if ($Primary)
    {
        $Lines.Add((Get-WtString -Key 'Tui.Result.JournalPrimary' -Arguments @($PrimaryTweak, $PrimaryStage)))
        $Lines.Add("  - $Primary")
        $Tone = 'Error'
    }

    foreach ($Result in $Results)
    {
        if ($null -eq $Result)
        {
            continue
        }

        $Status = [string]$Result.Status
        $Operations = @($Result.Operations)
        $Lines.Add((Get-WtString -Key 'Tui.Result.Line' -Arguments @($Result.TweakId, (Get-WtString -Key "Op.$Status"), $Operations.Count)))

        foreach ($Operation in $Operations)
        {
            $Lines.Add((Get-WtString -Key 'Tui.Result.Operation' -Arguments @(
                        [string]$Operation.Status,
                        [string]$Operation.Operation,
                        [string]$Operation.Target,
                        [string]$Operation.Message)))
        }

        foreach ($Message in @($Result.Messages))
        {
            if ($Message) { $Lines.Add("  - $Message") }
        }

        if ($Status -eq 'failed')
        {
            $Failed++
            $Tone = 'Error'
        }
        elseif ($Status -in 'succeeded', 'dryrun', 'partial')
        {
            $Changed++
        }

        if ($Result.Verified -eq $true) { $Verified++ }

        if ($Result.Compensation -and $Result.Compensation.Attempted)
        {
            $Compensated++
            $CompensationFailed += [int]$Result.Compensation.Failed
        }

        if ($Result.Restart -and $Result.Restart -ne 'None')
        {
            $Restarts.Add((Get-WtString -Key "Restart.$($Result.Restart)"))
        }
    }

    foreach ($Failure in $Failures)
    {
        $Lines.Add((Get-WtString -Key 'Tui.Result.WorkerFailure' -Arguments @([string]$Failure.Message)))
        $Failed++
        $Tone = 'Error'
    }

    if ($Restarts.Count -gt 0)
    {
        $Lines.Add((Get-WtString -Key 'Tui.Result.Restart' -Arguments @((@($Restarts | Select-Object -Unique) -join ', '))))
        if ($Tone -eq 'Success') { $Tone = 'Warning' }
    }

    if (-not $Preview -and @($Results).Count -gt 0)
    {
        # An honest summary of a batch: what reached the system, what the journal could not
        # record, what compensating restoration did, and what was never attempted.
        $Lines.Add((Get-WtString -Key 'Tui.Result.Summary.Changes' -Arguments @($Changed, $Verified)))

        if ($Uncertain -gt 0)
        {
            $Lines.Add((Get-WtString -Key 'Tui.Result.Summary.Journal' -Arguments @($Uncertain, (@($UncertainStages | Select-Object -Unique) -join ', '))))
            $Lines.Add((Get-WtString -Key 'Tui.Result.Summary.Recovery' -Arguments @($DurableRecords, $InMemoryRecords)))
        }

        if ($Compensated -gt 0)
        {
            $Lines.Add((Get-WtString -Key 'Tui.Result.Summary.Compensation' -Arguments @($Compensated, $CompensationFailed)))
        }

        if ($Skipped -gt 0)
        {
            $Lines.Add((Get-WtString -Key 'Tui.Result.Summary.Skipped' -Arguments @($Skipped)))
            if ($Tone -eq 'Success') { $Tone = 'Warning' }
        }

        if ($Uncertain -gt 0)
        {
            $Lines.Add((Get-WtString -Key 'Tui.Result.JournalInspect'))
        }
    }

    if ($Preview)
    {
        $Lines.Add((Get-WtString -Key 'Msg.DryRun'))
    }

    return @{
        Lines    = $Lines.ToArray()
        Tone     = $Tone
        Failed   = $Failed
        Changed  = $Changed
        Verified = $Verified
        Uncertain = $Uncertain
        Skipped  = $Skipped
        Primary  = $Primary
        Restarts = $Restarts.ToArray()
    }
}

<#
.SYNOPSIS
    Collects the worker's final output and shows the per-item report.
#>
function Complete-WtTuiOperation
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Outcome = Complete-WtWorkerTask -Worker $State.Worker
    $Operation = $State.Operation

    $Results = @($Outcome.Results | ForEach-Object { $_.Result })
    $Failures = @($Outcome.Failures)

    $Report = Get-WtTuiResultReport -Results $Results -Failures $Failures -Preview ([bool]$Operation.Preview) -Skipped ([int]$Operation.Skipped)
    $Lines = @($Report.Lines)
    $Tone = [string]$Report.Tone
    $Failed = [int]$Report.Failed
    $Uncertain = [int]$Report.Uncertain

    $Title = if ($Operation.Preview)
    {
        Get-WtString -Key 'Tui.Preview.Title'
    }
    elseif ($Operation.Kind -eq 'rollback')
    {
        Get-WtString -Key 'Tui.Restore.ResultTitle'
    }
    else
    {
        Get-WtString -Key 'Tui.Result.Title'
    }

    if ($Failed -gt 0 -or $Uncertain -gt 0)
    {
        $State.Operation = $null
        Sync-WtTuiCatalog -State $State

        # One status line: the persistence failure when there is one (it is the reason the rest
        # of the batch was not attempted), otherwise the count of failed items.
        $StatusText = if ($Uncertain -gt 0 -and $Report.Primary)
        {
            [string]$Report.Primary
        }
        else
        {
            Get-WtString -Key 'Msg.PartialFailure' -Arguments @($Failed)
        }

        Set-WtTuiStatus -State $State -Text $StatusText -Tone 'StatusError'
        Show-WtTuiMessage -State $State -Title $Title -Lines $Lines -Tone 'Error'
        if ($State.ExitPending) { $State.Exit = $true }
        return
    }

    # Everything the user asked for is in place: drop only those entries from the pending
    # set, and keep anything that failed, was reported unsupported, or whose journal record
    # is incomplete (that one needs inspection before it is retried).
    if ($Operation.Kind -eq 'apply' -and -not $Operation.Preview)
    {
        foreach ($Result in $Results)
        {
            if ($null -eq $Result) { continue }
            if ($Result.Status -in 'succeeded', 'unchanged', 'dryrun')
            {
                [void]$State.Pending.Remove([string]$Result.TweakId)
            }
        }
    }

    $State.Operation = $null
    Sync-WtTuiCatalog -State $State

    $Summary = if ($Operation.Preview)
    {
        Get-WtString -Key 'Tui.Preview.Done' -Arguments @($Results.Count)
    }
    else
    {
        Get-WtString -Key 'Tui.Result.Done' -Arguments @($Results.Count)
    }

    Set-WtTuiStatus -State $State -Text $Summary -Tone $(if ($Operation.Preview) { 'StatusInfo' } else { 'StatusOk' })
    Show-WtTuiMessage -State $State -Title $Title -Lines $Lines -Tone $(if ($Tone -eq 'Success') { 'Success' } else { 'Warning' })

    # A quit requested while the operation was running is honoured only now, so the
    # terminal is restored after the last result has been reported.
    if ($State.ExitPending) { $State.Exit = $true }
}

<#
.SYNOPSIS
    Handles keys while an operation is running.
.DESCRIPTION
    Only cancellation is accepted. Selection and application keys are ignored so no
    second change can be queued on top of a running one (conflicting modifications are
    serialized by design: one worker task at a time).
#>
function Read-WtTuiOperationKey
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Key
    )

    switch ($Key.Name)
    {
        'Escape' { Request-WtTuiCancellation -State $State }
        'Char'
        {
            if (([string]$Key.Char).ToLowerInvariant() -eq 'q')
            {
                $State.ExitPending = $true
                Request-WtTuiCancellation -State $State
            }
        }
        'Control'
        {
            if (([string]$Key.Char).ToLowerInvariant() -eq 'c')
            {
                $State.ExitPending = $true
                Request-WtTuiCancellation -State $State
            }
        }
        default { }
    }
}

<#
.SYNOPSIS
    Requests cooperative cancellation and explains what can and cannot be stopped.
#>
function Request-WtTuiCancellation
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    if (-not $State.Operation -or $State.Operation.Cancelling)
    {
        return
    }

    $Active = Stop-WtWorkerTask -Worker $State.Worker
    $State.Operation.Cancelling = $true

    $Text = if ($Active -and $Active.Active)
    {
        Get-WtString -Key 'Tui.Busy.CancelActive' -Arguments @([string]$Active.Active)
    }
    else
    {
        Get-WtString -Key 'Tui.Busy.Cancelling'
    }

    Set-WtTuiStatus -State $State -Text $Text -Tone 'StatusWarn'
}

#endregion Worker plumbing

#region Operation start

<#
.SYNOPSIS
    Starts an apply (or dry-run preview, or rollback) through the worker.
.DESCRIPTION
    The items passed here are the reviewed ones: the pending set for an apply, or the
    single history entry the user selected for a rollback. A dry run is forced for
    previews, so the same code path proves that a preview writes nothing.
#>
function Start-WtTuiOperation
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $false)][switch]$Preview,
        [Parameter(Mandatory = $false)][object]$RollbackItem
    )

    if ($State.Operation)
    {
        Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Busy.AlreadyRunning') -Tone 'StatusWarn'
        return
    }

    $Kind = 'apply'
    $Items = @()
    $DryRun = [bool]$State.DryRun

    if ($RollbackItem)
    {
        $Kind = 'rollback'
        $Items = @(@{
            Id        = $RollbackItem.TweakId
            HistoryId = $RollbackItem.HistoryId
            Label     = "$($RollbackItem.TweakId) ($($RollbackItem.Timestamp))"
        })
    }
    else
    {
        foreach ($Key in $State.Pending.Keys)
        {
            $Entry = $State.Pending[$Key]
            $Items += @{
                Id          = $Entry.Id
                HistoryId   = $null
                Target      = $Entry.Target
                Arguments   = $Entry.Arguments
                Label       = $Entry.Id
                Fingerprint = $Entry.Fingerprint
                Origin      = 'manual'
            }
        }
    }

    if ($Items.Count -eq 0)
    {
        Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Gui.NothingPending') -Tone 'StatusWarn'
        return
    }

    if ($Preview)
    {
        $DryRun = $true
    }

    $Worker = Get-WtTuiWorker -State $State
    $State.Operation = @{
        Kind       = $Kind
        Preview    = [bool]$Preview
        Total      = $Items.Count
        Started    = 0
        Finished   = 0
        Active     = $null
        Cancelling = $false
        Events     = @()
        Results    = @()
        Failures   = @()
    }

    try
    {
        $null = Start-WtWorkerTask -Worker $Worker -Kind $Kind -Items $Items -DryRun $DryRun
    }
    catch
    {
        $State.Operation = $null
        Set-WtTuiStatus -State $State -Text $_.Exception.Message -Tone 'StatusError'
        return
    }

    $Text = if ($Preview)
    {
        Get-WtString -Key 'Tui.Busy.Preview' -Arguments @($Items.Count)
    }
    else
    {
        Get-WtString -Key 'Tui.Busy.StartedMany' -Arguments @($Items.Count)
    }

    # The typed keys stay exactly as they were: the footer states that a dry run writes
    # nothing instead of hiding behind a colour.
    Set-WtTuiStatus -State $State -Text $Text -Tone $(if ($Preview) { 'StatusWarn' } else { 'StatusInfo' })
}

#endregion Operation start

#region Pending review

<#
.SYNOPSIS
    Shows the exact pending changes, allows removing them, and applies the reviewed set.
.DESCRIPTION
    This is the only path that applies a selection from the interface: the list shows
    every entry with its current and requested state, its scope, its restart requirement
    and its rollback capability, and nothing is applied without an explicit confirmation
    afterwards.
#>
function Show-WtTuiPendingReview
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    if ($State.Pending.Count -eq 0)
    {
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Gui.Pending') -Lines @((Get-WtString -Key 'Gui.NothingPending'))
        return
    }

    while ($true)
    {
        # Re-reading the reviewed state here is what makes the confirmation honest: every row
        # gets the exact per-target preview (current value, intended value, type, recovery) and
        # the fingerprint the engine will revalidate before it writes anything.
        $Items = @()
        $Previews = @{}
        foreach ($Key in $State.Pending.Keys)
        {
            $Entry = $State.Pending[$Key]
            $Preview = $null
            try
            {
                $Preview = Get-WtChangePreviewInternal -Id $Entry.Id -State $Entry.Target -Arguments $Entry.Arguments
            }
            catch
            {
                Write-WtLog -Level Warning -Message "Preview unavailable for $($Entry.Id): $($_.Exception.Message)" -NoConsole
            }

            if ($Preview)
            {
                $Previews[$Entry.Id] = $Preview
                $Entry.Fingerprint = $Preview.Fingerprint
            }

            $TargetCount = if ($Preview) { @($Preview.Targets).Count } else { 0 }
            $Items += @{
                Label    = Get-WtString -Key 'Tui.Pending.Change' -Arguments @($Entry.Id, $Entry.Target)
                Right    = Get-WtString -Key 'Tui.Preview.Targets' -Arguments @($TargetCount, (Get-WtString -Key "Restart.$($Entry.Restart)"))
                Payload  = $Entry.Id
                Filter   = "$($Entry.Id) $($Entry.Name) $($Entry.Target)"
                Disabled = $false
                Checked  = $false
            }
        }

        $Conflicts = @(Get-WtChangeConflictInternal -Preview @($Previews.Values))

        # The dependency plan is part of the review, not an extra step: a selection can pull in
        # prerequisites, and a prerequisite that is already at its default state is shown as
        # "already satisfied, not changed" so nobody believes it will be written again.
        $Plan = $null
        try
        {
            $Plan = Get-WtDependencyPlanInternal -Ids @($State.Pending.Keys | ForEach-Object { [string]$_ })
        }
        catch
        {
            Write-WtLog -Level Warning -Message "Dependency plan unavailable: $($_.Exception.Message)" -NoConsole
        }

        $Warnings = @(Get-WtTuiPendingWarnings -State $State)
        $Lines = @(Get-WtString -Key 'Tui.Pending.ReviewHint')

        $Prerequisites = @()
        $Satisfied = @()
        if ($Plan)
        {
            $Prerequisites = @($Plan.Items | Where-Object { $_.Source -eq 'Prerequisite' -and $_.Action -eq 'Apply' })
            $Satisfied = @($Plan.Items | Where-Object { $_.Action -eq 'Skip-Satisfied' })
        }

        if ($Prerequisites.Count -gt 0 -or $Satisfied.Count -gt 0 -or ($Plan -and @($Plan.Errors).Count -gt 0))
        {
            $Lines += ''
            $Lines += (Get-WtString -Key 'Cat.Tui.PlanTitle') + ':'

            $Number = 0
            foreach ($Item in @($Plan.Items | Where-Object { $_.Action -eq 'Apply' }))
            {
                $Number++
                $Source = if ($Item.Source -eq 'Prerequisite') { Get-WtString -Key 'Cat.PlanPrerequisite' } else { Get-WtString -Key 'Cat.PlanSelected' }
                $Lines += ("  {0}. {1} -> {2} ({3})" -f $Number, $Item.Id, $Item.State, $Source)
            }

            foreach ($Item in $Satisfied)
            {
                $Lines += ("  - {0}: {1}" -f $Item.Id, $Item.Reason)
            }

            foreach ($Problem in @($Plan.Errors))
            {
                $Lines += ("  {0}: {1}" -f (Get-WtString -Key 'Cat.PlanErrors'), $Problem)
            }
        }

        # Capability-loss disclosure: what may stop working is part of the review. The
        # aggregation is computed once here and reused for the final confirmation.
        $CapLoss = Get-WtCapabilityLossInternal -Selection (Get-WtSelectionForCapabilityLossInternal -State $State -Plan $Plan)
        $CapLossLines = (Get-WtCapabilityLossLinesInternal -Result $CapLoss).Lines
        if ($CapLoss.Count -gt 0)
        {
            $Lines += ''
            $Lines += (Get-WtString -Key 'Cap.Loss.Title') + ':'
            $Lines += $CapLossLines
        }

        foreach ($Conflict in $Conflicts)
        {
            $Lines += (Get-WtString -Key 'Tui.Preview.Conflict' -Arguments @($Conflict.Label, $Conflict.Left, $Conflict.Right))
        }

        if ($Conflicts.Count -gt 0)
        {
            $Lines += (Get-WtString -Key 'Tui.Preview.ConflictNote')
        }
        if ($Warnings.Count -gt 6)
        {
            # The list below shows every entry in full; the summary only needs the
            # distinct problems, so the panel does not become a wall of text.
            $Lines += $Warnings[0..5]
            $Lines += (Get-WtString -Key 'Tui.Pending.MoreWarnings' -Arguments @($Warnings.Count - 6))
        }
        else
        {
            $Lines += $Warnings
        }

        $Details = {
            param ($Item)

            $Entry = $State.Pending[$Item.Payload]
            if (-not $Entry) { return @() }

            $Lines = @()
            $Lines += (Get-WtString -Key 'Tui.Details.Effect') + ": $($Entry.Name)"
            $Lines += (Get-WtString -Key 'Tui.Details.State') + ": $(Get-WtString -Key 'Tui.Pending.Change' -Arguments @($Entry.From, $Entry.Target))"

            # An alternative that asks for Windows' own behaviour is not the same action as
            # restoring the captured state, so the review names which one this is.
            if (@($Entry.Keys) -contains 'Intent' -and $Entry.Intent)
            {
                $Lines += (Get-WtString -Key "Cat.Tui.Review.Intent.$($Entry.Intent)")
            }

            $Lines += (Get-WtString -Key 'Tui.Details.Risk') + ": $(Get-WtString -Key "Tui.Impact.$($Entry.Risk)") | $(Get-WtString -Key 'Tui.Details.Rollback'): $(Get-WtString -Key "Rollback.$($Entry.Rollback)")"

            # One line per target: the current value, the proposed value and its type.
            $Preview = $Previews[$Item.Payload]
            if ($Preview)
            {
                foreach ($Target in @($Preview.Targets))
                {
                    $Intended = if ($Target.Intended) { "$($Target.Intended.Display)$(if ($Target.Intended.Type) { " [$($Target.Intended.Type)]" })" } else { '-' }
                    $Lines += (Get-WtString -Key 'Tui.Preview.Row' -Arguments @($Target.Label, $Target.Current.Display, $Intended))
                }

                if ($Preview.Targets.Count -eq 0)
                {
                    $Lines += (Get-WtString -Key 'Tui.Preview.NoTargets')
                }
            }

            if ($Entry.Arguments)
            {
                $Lines += (Get-WtString -Key 'Tui.Details.Parameters') + ": " + (Get-WtTuiArgumentSummary -Arguments $Entry.Arguments)
            }

            return $Lines
        }

        $OnKey = {
            param ($Overlay, $Key)

            if ($Key.Name -ne 'Char') { return $false }

            $Character = ([string]$Key.Char).ToLowerInvariant()
            if ($Character -eq 'x')
            {
                $Id = [string]$Overlay.List.Items[[int]$Overlay.List.Cursor].Payload
                [void]$State.Pending.Remove($Id)
                $Overlay.Accepted = $true
                $Overlay.Result = $null
                return $true
            }

            if ($Character -eq 'c')
            {
                $State.Pending.Clear()
                $Overlay.Accepted = $true
                $Overlay.Result = $null
                return $true
            }

            return $false
        }

        $Result = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Gui.Pending') -Lines $Lines -Items $Items `
            -Searchable -Details $Details -OnKey $OnKey -DetailsHeight 4 -EmptyText (Get-WtString -Key 'Gui.NothingPending')

        if ($null -eq $Result)
        {
            if ($State.Pending.Count -eq 0)
            {
                Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Gui.NothingPending')
            }
            return
        }

        if ($State.Pending.Count -eq 0)
        {
            continue
        }

        $ConfirmLines = @()
        $Warnings = @(Get-WtTuiPendingWarnings -State $State)
        if ($Warnings.Count -gt 4)
        {
            $ConfirmLines += $Warnings[0..3]
            $ConfirmLines += (Get-WtString -Key 'Tui.Pending.MoreWarnings' -Arguments @($Warnings.Count - 4))
        }
        else
        {
            $ConfirmLines += $Warnings
        }

        $ConfirmLines += (Get-WtTuiPendingSummary -State $State)

        if ($CapLoss.Count -gt 0)
        {
            $ConfirmLines += ''
            $ConfirmLines += (Get-WtString -Key 'Cap.Loss.Title') + ':'
            $ConfirmLines += $CapLossLines
        }

        if ($State.DryRun)
        {
            $ConfirmLines += (Get-WtString -Key 'Tui.Pending.DryRunNote')
        }

        $ConfirmLines += (Get-WtString -Key 'Tui.Preview.Revalidated')

        if (Confirm-WtTui -State $State -Title (Get-WtString -Key 'Tui.Pending.ConfirmTitle') -Lines $ConfirmLines -Tone 'Warning')
        {
            Start-WtTuiOperation -State $State
        }

        return
    }
}

<#
.SYNOPSIS
    Returns the warning lines for the current pending set (irreversible, protection
    reducing, managed by policy, already in the target state).
#>
function Get-WtTuiPendingWarnings
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Lines = [System.Collections.Generic.List[string]]::new()

    foreach ($Key in $State.Pending.Keys)
    {
        $Entry = $State.Pending[$Key]

        if ($Entry.Irreversible)
        {
            $Lines.Add((Get-WtString -Key 'Error.Irreversible' -Arguments @($Entry.Name)))
        }

        if ($Entry.ReducesProtection)
        {
            $Lines.Add((Get-WtString -Key 'Tui.Pending.ProtectionWarning' -Arguments @($Entry.Name)))
        }

        $Detected = $State.States | Where-Object { $_.Id -eq $Entry.Id } | Select-Object -First 1
        if ($Detected)
        {
            if ($Detected.Managed)
            {
                $Lines.Add((Get-WtString -Key 'Error.ManagedByPolicy' -Arguments @(($Detected.ManagedBy) -join ', ')))
            }

            if (-not $Detected.Supported)
            {
                $Lines.Add((Get-WtString -Key 'Tui.Pending.Unsupported' -Arguments @($Entry.Id, $Detected.UnsupportedReason)))
            }

            if ($Detected.State -eq $Entry.Target)
            {
                $Lines.Add((Get-WtString -Key 'Tui.Pending.Unchanged' -Arguments @($Entry.Id)))
            }
        }
    }

    return $Lines.ToArray()
}

<#
.SYNOPSIS
    Returns one line per pending change (id, from -> to, arguments).
#>
function Get-WtTuiPendingSummary
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Lines = [System.Collections.Generic.List[string]]::new()

    foreach ($Key in $State.Pending.Keys)
    {
        $Entry = $State.Pending[$Key]
        $Line = Get-WtString -Key 'Tui.Pending.Change' -Arguments @($Entry.Id, $Entry.Target)
        if ($Entry.Arguments)
        {
            $Line += ' [' + (Get-WtTuiArgumentSummary -Arguments $Entry.Arguments) + ']'
        }
        $Lines.Add('  - ' + $Line)
    }

    return $Lines.ToArray()
}

<#
.SYNOPSIS
    Renders collected arguments in one readable line for review and confirmations.
#>
function Get-WtTuiArgumentSummary
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][object]$Arguments)

    $Parts = [System.Collections.Generic.List[string]]::new()

    foreach ($Name in @($Arguments.Keys | Sort-Object))
    {
        $Value = $Arguments[$Name]
        if ($Value -is [array])
        {
            $Parts.Add("$Name=$(@($Value).Count) item(s)")
        }
        else
        {
            $Parts.Add("$Name=$Value")
        }
    }

    return ($Parts -join ', ')
}

#endregion Pending review

#region Target state and arguments

<#
.SYNOPSIS
    Asks for the target state of a tweak.
.DESCRIPTION
    Multi-state and parameterized tweaks cannot be toggled with one key press, so the
    exact target is chosen here; the current state and the detector's explanation are
    shown next to each option.
#>
function Select-WtTuiTargetState
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Entry
    )

    if (-not $Entry.Supported)
    {
        Show-WtTuiMessage -State $State -Title $Entry.Name -Lines @($Entry.UnsupportedReason) -Tone 'Warning'
        return $null
    }

    $States = @($Entry.StateNames)
    if ($States.Count -eq 0)
    {
        Show-WtTuiMessage -State $State -Title $Entry.Name -Lines @((Get-WtString -Key 'Error.StateRequired' -Arguments @($Entry.Id))) -Tone 'Warning'
        return $null
    }

    $Items = @()
    foreach ($Name in $States)
    {
        $Items += @{
            Label    = Get-WtTuiStateLabel -Name $Name
            Right    = if ($Name -eq $Entry.State) { Get-WtString -Key 'Tui.State.Current' } else { '' }
            Payload  = $Name
            Filter   = "$Name $($Entry.Name) $($Entry.Id)"
            Disabled = $false
            Checked  = ($Name -eq $Entry.State)
            Icon     = Get-WtStateIconKey -State $Name
        }
    }

    $Lines = @(
        $Entry.Description,
        (Get-WtString -Key 'Tui.Details.State') + ": $($Entry.State)",
        (Get-WtString -Key 'Tui.Details.Impact') + ": $($Entry.Impact)"
    )

    if ($Entry.Managed)
    {
        $Lines += Get-WtString -Key 'Error.ManagedByPolicy' -Arguments @(($Entry.ManagedBy) -join ', ')
    }

    $Details = {
        param ($Item)

        @(
            (Get-WtString -Key 'Tui.State.Option') + ": $(Get-WtTuiStateLabel -Name $Item.Payload)",
            (Get-WtString -Key 'Tui.Details.Restart') + ": $(Get-WtString -Key "Restart.$($Entry.Restart)")",
            (Get-WtString -Key 'Tui.Details.Rollback') + ": $(Get-WtString -Key "Rollback.$($Entry.Rollback)")"
        )
    }

    $Result = Select-WtTuiItem -State $State -Title $Entry.Name -Lines $Lines -Items $Items -Details $Details -DetailsHeight 3 -Searchable
    if ($null -eq $Result)
    {
        return $null
    }

    return [string]$Result.Value
}

<#
.SYNOPSIS
    Turns an internal state name into a readable label, keeping unknown names verbatim.
#>
function Get-WtTuiStateLabel
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][string]$Name)

    $Key = "Tui.State.$Name"
    $Label = Get-WtString -Key $Key

    if ($Label -like "[[]Tui.State.*[]]")
    {
        return $Name
    }

    return $Label
}

<#
.SYNOPSIS
    Collects the -Arguments a parameterized tweak needs, using terminal pickers.
.DESCRIPTION
    Returns $null when the user cancels, which the caller treats as "no change": a
    parameterized tweak is never applied with guessed arguments.
#>
function Read-WtTuiTweakArguments
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Entry
    )

    $Parameters = @($Entry.Tweak.Parameters)

    if ($Parameters -contains 'PackageFullName')
    {
        return (Select-WtTuiUwpPackage -State $State -Entry $Entry)
    }

    if ($Parameters -contains 'FeatureName')
    {
        $Names = Select-WtTuiWindowsFeature -State $State -Entry $Entry -Capability:$false
        if ($null -eq $Names) { return $null }
        return @{ FeatureName = @($Names) }
    }

    if ($Parameters -contains 'CapabilityName')
    {
        $Names = Select-WtTuiWindowsFeature -State $State -Entry $Entry -Capability
        if ($null -eq $Names) { return $null }
        return @{ CapabilityName = @($Names) }
    }

    if ($Parameters -contains 'InterfaceIndex')
    {
        return (Read-WtTuiNetworkArguments -State $State -Entry $Entry)
    }

    if ($Parameters -contains 'Uri')
    {
        return (Read-WtTuiInstallerArguments -State $State -Entry $Entry)
    }

    Show-WtTuiMessage -State $State -Title $Entry.Name -Tone 'Warning' -Lines @(
        (Get-WtString -Key 'Tui.Args.Unsupported' -Arguments @(($Parameters -join ', '))),
        (Get-WtString -Key 'Tui.Args.CliHint' -Arguments @($Entry.Id))
    )

    return $null
}

<#
.SYNOPSIS
    Store package picker: searchable list, explicit multi-selection, package details and
    an explicit user scope.
.DESCRIPTION
    Nothing is ticked by default, the exact package identity and the scope are shown, and
    packages this tool refuses to remove (Store, shell components, runtimes, frameworks)
    cannot be ticked at all.
#>
function Select-WtTuiUwpPackage
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Entry
    )

    if (-not (Test-WtAppxAvailable))
    {
        Show-WtTuiMessage -State $State -Title $Entry.Name -Tone 'Warning' -Lines @((Get-WtString -Key 'Tui.Uwp.Unavailable'))
        return $null
    }

    $Scope = @{ AllUsers = $false }

    if (-not $State.Environment.IsAdmin)
    {
        Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Cli.NotAdmin') -Tone 'StatusWarn'
    }

    while ($true)
    {
        $Packages = @(Get-WtAppxPackageInfo -AllUsers:([bool]$Scope.AllUsers) |
            Where-Object { -not $_.IsFramework -and -not $_.IsResourcePackage } |
            Sort-Object -Property Name)

        if ($Packages.Count -eq 0)
        {
            Show-WtTuiMessage -State $State -Title $Entry.Name -Tone 'Warning' -Lines @((Get-WtString -Key 'Tui.Uwp.None'))
            return $null
        }

        $Items = @()
        foreach ($Package in $Packages)
        {
            $Items += @{
                Label    = $Package.Name
                Right    = $Package.Version
                Checked  = $false
                Disabled = [bool]($Package.Protected -or $Package.NonRemovable)
                Payload  = [string]$Package.PackageFullName
                Filter   = "$($Package.Name) $($Package.PackageFullName) $($Package.Publisher)"
                Icon     = $(if ($Package.Protected -or $Package.NonRemovable) { 'Status.Unsupported' } else { '' })
            }
        }

        $ScopeLabel = if ($Scope.AllUsers) { Get-WtString -Key 'Tui.Uwp.ScopeAll' } else { Get-WtString -Key 'Tui.Uwp.ScopeCurrent' }
        $Lines = @(
            (Get-WtString -Key 'Tui.Uwp.Scope') + ": $ScopeLabel",
            (Get-WtString -Key 'Tui.Uwp.Hint'),
            (Get-WtString -Key 'Error.Irreversible' -Arguments @((Get-WtString -Key 'Tui.Uwp.Irreversible')))
        )

        if (-not $State.Environment.IsAdmin)
        {
            $Lines += Get-WtString -Key 'Tui.Uwp.NeedsAdmin'
        }

        $Details = {
            param ($Item)

            $Package = $Packages | Where-Object { $_.PackageFullName -eq $Item.Payload } | Select-Object -First 1
            if (-not $Package) { return @() }

            @(
                $Package.PackageFullName,
                (Get-WtString -Key 'Tui.Uwp.Publisher') + ": $($Package.Publisher)",
                (Get-WtString -Key 'Tui.Uwp.Version') + ": $($Package.Version) [$($Package.Architecture)]",
                (Get-WtString -Key 'Tui.Uwp.Scope') + ": $($Package.Scope)  $(Get-WtString -Key 'Tui.Uwp.User'): $($Package.User)",
                $(if ($Package.Protected) { Get-WtString -Key 'Tui.Uwp.Protected' }
                  elseif ($Package.NonRemovable) { Get-WtString -Key 'Tui.Uwp.NonRemovable' }
                  else { Get-WtString -Key 'Tui.Uwp.Removable' })
            )
        }

        $OnKey = {
            param ($Overlay, $Key)

            if ($Key.Name -ne 'Char') { return $false }
            if (([string]$Key.Char).ToLowerInvariant() -ne 'u') { return $false }

            if (-not $State.Environment.IsAdmin)
            {
                Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Uwp.ScopeNeedsAdmin') -Tone 'StatusWarn'
                return $true
            }

            $Scope.AllUsers = -not $Scope.AllUsers
            $Overlay.Accepted = $true
            $Overlay.Result = 'reselect'
            return $true
        }

        $Result = Select-WtTuiItem -State $State -Title $Entry.Name -Lines $Lines -Items $Items -Multi -Searchable `
            -Details $Details -OnKey $OnKey -DetailsHeight 5 -EmptyText (Get-WtString -Key 'Tui.Uwp.None')

        if ($null -eq $Result)
        {
            return $null
        }

        if ([string]$Result.Value -eq 'reselect')
        {
            continue
        }

        $Selected = @($Result.Selected)
        if ($Selected.Count -eq 0)
        {
            Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Uwp.NothingSelected') -Tone 'StatusWarn'
            return $null
        }

        $Names = @($Packages | Where-Object { $Selected -contains $_.PackageFullName } | ForEach-Object { $_.Name })

        $ConfirmLines = @(
            (Get-WtString -Key 'Tui.Uwp.Scope') + ": $ScopeLabel",
            (Get-WtString -Key 'Tui.Uwp.Selected' -Arguments @($Selected.Count)),
            (Get-WtString -Key 'Tui.Uwp.ReinstallNote')
        )
        $ConfirmLines += @($Names | ForEach-Object { "  - $_" })

        if (-not (Confirm-WtTui -State $State -Title $Entry.Name -Lines $ConfirmLines -Tone 'Error'))
        {
            return $null
        }

        return @{ PackageFullName = @($Selected); AllUsers = [bool]$Scope.AllUsers }
    }
}

<#
.SYNOPSIS
    Windows features / capabilities picker (the terminal replacement for the DISM
    selection the legacy tool did in a window).
.DESCRIPTION
    Lists what this Windows installation has, with the current state next to each entry;
    multi-selection only, and the enable/disable direction is chosen afterwards through
    the normal target-state chooser.
#>
function Select-WtTuiWindowsFeature
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $false)][switch]$Capability
    )

    $Available = if ($Capability)
    {
        @(Get-WtWindowsCapability)
    }
    else
    {
        @(Get-WtWindowsFeature)
    }

    if ($Available.Count -eq 0)
    {
        Show-WtTuiMessage -State $State -Title $Entry.Name -Tone 'Warning' -Lines @(
            (Get-WtString -Key 'Tui.Feature.Unavailable'),
            (Get-WtString -Key 'Tui.Feature.RequiresDism')
        )
        return $null
    }

    $Items = @()
    foreach ($Feature in $Available)
    {
        $Items += @{
            Label    = $Feature.Name
            Right    = [string]$Feature.State
            Checked  = $false
            Disabled = $false
            Payload  = [string]$Feature.Name
            Filter   = "$($Feature.Name) $($Feature.State) $($Feature.Description)"
            Icon     = Get-WtStateIconKey -State ([string]$Feature.State)
        }
    }

    $Lines = @(
        (Get-WtString -Key 'Tui.Feature.Hint'),
        (Get-WtString -Key 'Tui.Feature.Impact')
    )

    $Details = {
        param ($Item)

        $Feature = $Available | Where-Object { $_.Name -eq $Item.Payload } | Select-Object -First 1
        if (-not $Feature) { return @() }

        $Lines = @((Get-WtString -Key 'Tui.Feature.State') + ": $($Feature.State)")
        if ($Feature.Description) { $Lines += $Feature.Description }
        if ($Feature.RestartRequired) { $Lines += (Get-WtString -Key 'Tui.Feature.Restart') }
        return $Lines
    }

    $Result = Select-WtTuiItem -State $State -Title $Entry.Name -Lines $Lines -Items $Items -Multi -Searchable `
        -Details $Details -DetailsHeight 4 -EmptyText (Get-WtString -Key 'Tui.Feature.None')

    if ($null -eq $Result)
    {
        return $null
    }

    $Selected = @($Result.Selected)
    if ($Selected.Count -eq 0)
    {
        Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Feature.NothingSelected') -Tone 'StatusWarn'
        return $null
    }

    return @($Selected)
}

<#
.SYNOPSIS
    Adapter picker plus validated DNS input (explicit adapters only, previous
    configuration shown, unrelated virtual/VPN adapters kept out by default).
#>
function Read-WtTuiNetworkArguments
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Entry
    )

    $Adapters = @(Get-WtNetworkAdapter)
    if ($Adapters.Count -eq 0)
    {
        Show-WtTuiMessage -State $State -Title $Entry.Name -Tone 'Warning' -Lines @((Get-WtString -Key 'Tui.Dns.NoAdapters'))
        return $null
    }

    $Items = @()
    foreach ($Adapter in $Adapters)
    {
        $Dns = @($Adapter.DnsServers)
        $Right = if ($Dns.Count -gt 0) { $Dns -join ',' } else { Get-WtString -Key 'Tui.Dns.Automatic' }

        $Items += @{
            Label    = "$($Adapter.Name) [$($Adapter.InterfaceIndex)]"
            Right    = $Right
            Checked  = $false
            Disabled = $false
            Payload  = [int]$Adapter.InterfaceIndex
            Filter   = "$($Adapter.Name) $($Adapter.Description) $($Adapter.InterfaceIndex)"
            Icon     = $(if ($Adapter.IsVirtualOrTunnel) { 'Status.Warning' } else { 'Category.Hardware' })
        }
    }

    $Lines = @(
        (Get-WtString -Key 'Tui.Dns.Hint'),
        (Get-WtString -Key 'Tui.Dns.VirtualNote')
    )

    $Details = {
        param ($Item)

        $Adapter = $Adapters | Where-Object { $_.InterfaceIndex -eq $Item.Payload } | Select-Object -First 1
        if (-not $Adapter) { return @() }

        $Dns = @($Adapter.DnsServers)
        @(
            $Adapter.Description,
            (Get-WtString -Key 'Tui.Dns.Status') + ": $($Adapter.Status)",
            (Get-WtString -Key 'Tui.Dns.Current') + ": $(if ($Dns.Count -gt 0) { $Dns -join ', ' } else { Get-WtString -Key 'Tui.Dns.Automatic' })",
            $(if ($Adapter.IsVirtualOrTunnel) { Get-WtString -Key 'Tui.Dns.Virtual' } else { Get-WtString -Key 'Tui.Dns.Physical' })
        )
    }

    $Result = Select-WtTuiItem -State $State -Title $Entry.Name -Lines $Lines -Items $Items -Multi -Searchable `
        -Details $Details -DetailsHeight 4 -EmptyText (Get-WtString -Key 'Tui.Dns.NoAdapters')

    if ($null -eq $Result)
    {
        return $null
    }

    $Selected = @($Result.Selected)
    if ($Selected.Count -eq 0)
    {
        Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Dns.NothingSelected') -Tone 'StatusWarn'
        return $null
    }

    $Chosen = @($Adapters | Where-Object { $Selected -contains $_.InterfaceIndex })
    $Virtual = @($Chosen | Where-Object { $_.IsVirtualOrTunnel })
    $AllowVirtual = $false

    if ($Virtual.Count -gt 0)
    {
        $AllowVirtual = Confirm-WtTui -State $State -Title (Get-WtString -Key 'Tui.Dns.VirtualTitle') -Lines @(
            (Get-WtString -Key 'Tui.Dns.VirtualSelected' -Arguments @(($Virtual | ForEach-Object { $_.Name }) -join ', ')),
            (Get-WtString -Key 'Tui.Dns.VirtualConfirm')
        ) -Tone 'Warning'
    }

    $Arguments = @{
        InterfaceIndex      = @($Chosen | ForEach-Object { [int]$_.InterfaceIndex })
        AllowVirtualAdapter = [bool]$AllowVirtual
    }

    $ServerText = Read-WtTuiText -State $State -Title $Entry.Name -Label (Get-WtString -Key 'Tui.Dns.ServerLabel') `
        -Lines @((Get-WtString -Key 'Tui.Dns.ServerHint')) -Validate {
            param ($Text)

            $Addresses = @($Text -split '[,\s]+' | Where-Object { $_ })
            if ($Addresses.Count -eq 0)
            {
                return (Get-WtString -Key 'Tui.Dns.ServerRequired')
            }

            foreach ($Address in $Addresses)
            {
                $Parsed = $null
                if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$Parsed))
                {
                    return (Get-WtString -Key 'Tui.Dns.ServerInvalid' -Arguments @($Address))
                }
            }

            return ''
        }

    if ($null -eq $ServerText)
    {
        return $null
    }

    $Arguments.ServerAddresses = @($ServerText -split '[,\s]+' | Where-Object { $_ })

    # The DoH template is only asked for when the tweak declares it, and it is validated
    # as an https:// URL before it is accepted.
    if (@($Entry.Tweak.Parameters) -contains 'DohTemplate')
    {
        $Template = Read-WtTuiText -State $State -Title $Entry.Name -Label (Get-WtString -Key 'Tui.Dns.DohLabel') `
            -Lines @((Get-WtString -Key 'Tui.Dns.DohHint')) -Validate {
                param ($Text)

                if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
                if ($Text -notmatch '^https://') { return (Get-WtString -Key 'Tui.Dns.DohInvalid') }
                return ''
            }

        if ($null -eq $Template)
        {
            return $null
        }

        if (-not [string]::IsNullOrWhiteSpace($Template))
        {
            $Arguments.DohTemplate = $Template.Trim()
        }
    }

    return $Arguments
}

<#
.SYNOPSIS
    Collects the download URI and the destination path for an installer tweak, with
    validation and an explicit source warning.
#>
function Read-WtTuiInstallerArguments
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Entry
    )

    $Uri = Read-WtTuiText -State $State -Title $Entry.Name -Label (Get-WtString -Key 'Tui.Installer.UriLabel') `
        -Lines @((Get-WtString -Key 'Tui.Installer.UriHint')) -Validate {
            param ($Text)

            if ([string]::IsNullOrWhiteSpace($Text)) { return (Get-WtString -Key 'Tui.Path.Required') }

            try
            {
                $Parsed = [System.Uri]$Text
                if ($Parsed.Scheme -ne 'https')
                {
                    return (Get-WtString -Key 'Tui.Installer.UriScheme')
                }
            }
            catch
            {
                return (Get-WtString -Key 'Tui.Installer.UriInvalid')
            }

            return ''
        }

    if ($null -eq $Uri)
    {
        return $null
    }

    $Destination = Read-WtTuiText -State $State -Title $Entry.Name -Label (Get-WtString -Key 'Tui.Installer.PathLabel') `
        -Initial (Get-WtTuiDefaultDownloadPath) -Lines @((Get-WtString -Key 'Tui.Installer.PathHint')) -Validate {
            param ($Text)

            return (Resolve-WtTuiPathError -Path $Text)
        }

    if ($null -eq $Destination)
    {
        return $null
    }

    return @{ Uri = $Uri.Trim(); DestinationPath = $Destination.Trim() }
}

<#
.SYNOPSIS
    Validates a path the user typed: it must be absolute and its directory must be
    writable, so a change cannot fail halfway through for a typo.
#>
function Resolve-WtTuiPathError
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][string]$Path)

    $Trimmed = $Path.Trim()
    if ([string]::IsNullOrWhiteSpace($Trimmed))
    {
        return (Get-WtString -Key 'Tui.Path.Required')
    }

    if (-not [System.IO.Path]::IsPathRooted($Trimmed))
    {
        return (Get-WtString -Key 'Tui.Path.NotAbsolute')
    }

    $Extension = [System.IO.Path]::GetExtension($Trimmed)
    if ([string]::IsNullOrEmpty($Extension))
    {
        return (Get-WtString -Key 'Tui.Path.NeedsExtension')
    }

    $Directory = [System.IO.Path]::GetDirectoryName($Trimmed)
    if ([string]::IsNullOrWhiteSpace($Directory))
    {
        return (Get-WtString -Key 'Tui.Path.NotAbsolute')
    }

    if (-not (Test-Path -LiteralPath $Directory))
    {
        return (Get-WtString -Key 'Tui.Path.NoDirectory' -Arguments @($Directory))
    }

    if (Test-Path -LiteralPath $Trimmed)
    {
        return (Get-WtString -Key 'Tui.Path.Exists' -Arguments @($Trimmed))
    }

    return ''
}

<#
.SYNOPSIS
    Default download destination shown for the installer workflow.
#>
function Get-WtTuiDefaultDownloadPath
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    $Base = if ([string]::IsNullOrWhiteSpace($env:TEMP)) { [System.IO.Path]::GetTempPath() } else { $env:TEMP }
    return (Join-Path $Base 'WindowsTweaker-download.exe')
}

#endregion Target state and arguments

#region History, restore, presets, help

<#
.SYNOPSIS
    Opens the restore workflow: pick a recorded operation and roll it back.
#>
function Invoke-WtTuiRestore
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    Set-WtTuiCategory -State $State -Key 'History'

    if ($State.History.Count -eq 0)
    {
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Gui.History') -Lines @((Get-WtString -Key 'Tui.Restore.Empty'))
        return
    }

    $Items = @()
    foreach ($Entry in $State.History)
    {
        $Items += @{
            Label    = $Entry.TweakId
            Right    = if ($Entry.RolledBack) { Get-WtString -Key 'Tui.History.RolledBack' } else { Get-WtString -Key "Op.$($Entry.Outcome)" }
            Payload  = $Entry
            Filter   = "$($Entry.TweakId) $($Entry.State) $($Entry.Outcome) $($Entry.Timestamp)"
            Disabled = $false
            Checked  = $false
        }
    }

    $Details = {
        param ($Item)

        $Entry = $Item.Payload
        @(
            (Get-WtString -Key 'Tui.Col.Time') + ": $($Entry.Timestamp)",
            (Get-WtString -Key 'Tui.Col.State') + ": $($Entry.State)",
            (Get-WtString -Key 'Tui.Details.Records') + ": $($Entry.RecordCount)",
            $(if ($Entry.Irreversible) { Get-WtString -Key 'Tui.Restore.Irreversible' } else { Get-WtString -Key 'Tui.Restore.Restorable' })
        )
    }

    $Result = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Tui.Restore.Title') -Items $Items -Searchable `
        -Lines @((Get-WtString -Key 'Tui.Restore.Hint')) -Details $Details -DetailsHeight 4 -EmptyText (Get-WtString -Key 'Tui.Restore.Empty')

    if ($null -eq $Result -or $null -eq $Result.Value)
    {
        return
    }

    $Entry = $Result.Value
    $Lines = @(
        (Get-WtString -Key 'Tui.Details.Tweak') + ": $($Entry.TweakId)"
        (Get-WtString -Key 'Tui.Col.State') + ": $($Entry.State)"
        (Get-WtString -Key 'Tui.Restore.Confirm')
    )

    if ($Entry.Irreversible)
    {
        $Lines += (Get-WtString -Key 'Tui.Restore.Irreversible')
    }

    if ($State.DryRun)
    {
        $Lines += (Get-WtString -Key 'Tui.Pending.DryRunNote')
    }

    if (Confirm-WtTui -State $State -Title (Get-WtString -Key 'Tui.Restore.Title') -Lines $Lines -Tone $(if ($Entry.Irreversible) { 'Error' } else { 'Warning' }))
    {
        Start-WtTuiOperation -State $State -RollbackItem $Entry
    }
}

<#
.SYNOPSIS
    Preset menu: load a shipped preset, import one from a file, or export the pending
    selection.
.DESCRIPTION
    Importing never applies anything: the entries become pending changes that still have
    to be reviewed and confirmed. Exporting writes the reviewed selection as a JSON preset.
#>
function Show-WtTuiPresets
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    while ($true)
    {
        $Presets = @(Get-WtPreset)
        $Items = @()

        foreach ($Preset in $Presets)
        {
            $Items += @{
                Label    = $Preset.Name
                Right    = Get-WtString -Key 'Tui.Preset.Entries' -Arguments @($Preset.Entries.Count)
                Payload  = @{ Action = 'Load'; Preset = $Preset }
                Filter   = "$($Preset.Name) $($Preset.Description) $($Preset.Source)"
                Disabled = $false
                Checked  = ($State.PresetName -eq $Preset.Name)
                Icon     = 'Action.Restore'
            }
        }

        $Items += @{ Label = Get-WtString -Key 'Tui.Preset.Import'; Payload = @{ Action = 'Import' }; Filter = 'import file json'; Disabled = $false; Checked = $false; Icon = 'Action.Import' }
        $Items += @{ Label = Get-WtString -Key 'Tui.Preset.Export'; Payload = @{ Action = 'Export' }; Filter = 'export file json'; Disabled = ($State.Pending.Count -eq 0); Checked = $false; Icon = 'Action.Export' }
        $Items += @{ Label = Get-WtString -Key 'Tui.Preset.Clear'; Payload = @{ Action = 'Clear' }; Filter = 'clear pending'; Disabled = ($State.Pending.Count -eq 0); Checked = $false; Icon = 'Action.Cancel' }

        $Lines = @(
            (Get-WtString -Key 'Tui.Preset.Hint' -Arguments @($State.Pending.Count)),
            (Get-WtString -Key 'Tui.Preset.Path' -Arguments @((Get-WtPresetDirectory)))
        )

        $Details = {
            param ($Item)

            $Payload = $Item.Payload
            if ($Payload.Action -ne 'Load') { return @() }

            $Preset = $Payload.Preset
            $Lines = @((Get-WtPresetDescription -Preset $Preset), (Get-WtString -Key 'Tui.Preset.Source') + ": $($Preset.Source)")
            foreach ($Entry in @($Preset.Entries | Select-Object -First 4))
            {
                $Lines += "  - $($Entry.Id) -> $($Entry.State)"
            }
            if ($Preset.Entries.Count -gt 4)
            {
                $Lines += (Get-WtString -Key 'Tui.Preset.More' -Arguments @($Preset.Entries.Count - 4))
            }

            # Preset preview shows the capability-loss disclosure the same way the review does.
            $Selection = @()
            foreach ($Entry in @($Preset.Entries))
            {
                $Tweak = Get-WtTweakInternal -Id $Entry.Id
                if ($Tweak)
                {
                    $Selection += @{ Tweak = $Tweak; State = [string]$Entry.State }
                }
            }

            if ($Selection.Count -gt 0)
            {
                $Result = Get-WtCapabilityLossInternal -Selection $Selection
                $LossLines = (Get-WtCapabilityLossLinesInternal -Result $Result).Lines
                if (@($Result.Impacts).Count -gt 0)
                {
                    $Lines += ''
                    $Lines += (Get-WtString -Key 'Cap.Loss.Title') + ':'
                    $Lines += $LossLines
                }
            }

            return $Lines
        }

        $Result = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Gui.Pending') -Lines $Lines -Items $Items `
            -Searchable -Details $Details -DetailsHeight 6 -EmptyText (Get-WtString -Key 'Tui.Preset.None')

        if ($null -eq $Result -or $null -eq $Result.Value)
        {
            return
        }

        $Action = [string]$Result.Value.Action

        switch ($Action)
        {
            'Load'
            {
                Import-WtTuiPreset -State $State -Preset $Result.Value.Preset
                return
            }
            'Import'
            {
                $Path = Read-WtTuiPresetPath -State $State -Mode 'Import'
                if ($Path)
                {
                    Import-WtTuiPreset -State $State -Preset $Path
                }
                return
            }
            'Export'
            {
                $Path = Read-WtTuiPresetPath -State $State -Mode 'Export'
                if ($Path)
                {
                    Export-WtTuiPreset -State $State -Path $Path
                }
                return
            }
            'Clear'
            {
                if (Confirm-WtTui -State $State -Title (Get-WtString -Key 'Tui.Preset.Clear') -Lines @(
                        (Get-WtString -Key 'Tui.Preset.ClearHint' -Arguments @($State.Pending.Count))))
                {
                    $State.Pending.Clear()
                    Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Gui.NothingPending')
                }
                return
            }
            default { return }
        }
    }
}

<#
.SYNOPSIS
    Reads and validates the path used to import or export a preset.
#>
function Read-WtTuiPresetPath
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][ValidateSet('Import', 'Export')][string]$Mode
    )

    $Directory = Get-WtPresetDirectory
    $Initial = if ($Mode -eq 'Export')
    {
        Join-Path $Directory ("WindowsTweaker-{0}.json" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
    }
    else
    {
        Join-Path $Directory 'preset.json'
    }

    $Title = if ($Mode -eq 'Import') { Get-WtString -Key 'Tui.Preset.Import' } else { Get-WtString -Key 'Tui.Preset.Export' }

    return (Read-WtTuiText -State $State -Title $Title -Label (Get-WtString -Key 'Tui.Preset.PathLabel') -Initial $Initial `
        -Lines @((Get-WtString -Key 'Tui.Preset.PathHint' -Arguments @($Directory))) -Validate {
            param ($Text)

            if ([string]::IsNullOrWhiteSpace($Text)) { return (Get-WtString -Key 'Tui.Path.Required') }

            $Trimmed = $Text.Trim()
            if (-not [System.IO.Path]::IsPathRooted($Trimmed))
            {
                return (Get-WtString -Key 'Tui.Path.NotAbsolute')
            }

            if ([System.IO.Path]::GetExtension($Trimmed) -ne '.json')
            {
                return (Get-WtString -Key 'Tui.Path.NeedsJson')
            }

            if ($Mode -eq 'Import')
            {
                if (-not (Test-Path -LiteralPath $Trimmed -PathType Leaf))
                {
                    return (Get-WtString -Key 'Tui.Preset.NotFound' -Arguments @($Trimmed))
                }
            }
            else
            {
                if (Test-Path -LiteralPath $Trimmed)
                {
                    return (Get-WtString -Key 'Tui.Path.Exists' -Arguments @($Trimmed))
                }

                $Parent = [System.IO.Path]::GetDirectoryName($Trimmed)
                if (-not (Test-Path -LiteralPath $Parent))
                {
                    return (Get-WtString -Key 'Tui.Path.NoDirectory' -Arguments @($Parent))
                }
            }

            return ''
        })
}

<#
.SYNOPSIS
    Loads a preset (object, name or path) into the pending set.
.DESCRIPTION
    Read-only until the user applies: the preset only fills the pending selection, and
    protection-reducing entries are refused by the loader rather than silently included.
#>
function Import-WtTuiPreset
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Preset
    )

    try
    {
        $Resolved = if ($Preset -is [string]) { Import-WtPreset -Path $Preset } else { $Preset }
    }
    catch
    {
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Tui.Preset.Import') -Tone 'Error' -Lines @($_.Exception.Message)
        return
    }

    $Lines = @(
        (Get-WtString -Key 'Tui.Preset.Loaded' -Arguments @($Resolved.Name, $Resolved.Entries.Count))
    )

    # The preset's own description, in the active language for the shipped presets and
    # verbatim for a user preset (which was authored in one language).
    $Description = Get-WtPresetDescription -Preset $Resolved
    if ($Description)
    {
        $Lines += $Description
    }

    $Lines += Get-WtString -Key 'Tui.Preset.ReviewNote'

    if (@($Resolved.Skipped).Count -gt 0)
    {
        $Lines += (Get-WtString -Key 'Tui.Preset.Skipped' -Arguments @($Resolved.Skipped.Count))
        $Lines += @($Resolved.Skipped | ForEach-Object { "  - $_" })
    }

    $Lines += @($Resolved.Entries | ForEach-Object { "  - $($_.Id) -> $($_.State)" })

    if (-not (Confirm-WtTui -State $State -Title (Get-WtString -Key 'Tui.Preset.Import') -Lines $Lines -Tone 'Warning'))
    {
        return
    }

    $State.Pending.Clear()
    foreach ($Entry in $Resolved.Entries)
    {
        $Detected = $State.States | Where-Object { $_.Id -eq $Entry.Id } | Select-Object -First 1
        if (-not $Detected) { continue }

        $State.Pending[$Entry.Id] = @{
            Id                = $Entry.Id
            Target            = $Entry.State
            From              = $Detected.State
            Name              = $Detected.Name
            Arguments         = $Entry.Arguments
            Risk              = $Detected.Risk
            Restart           = $Detected.Restart
            Rollback          = $Detected.Rollback
            Irreversible      = $Detected.Irreversible
            ReducesProtection = $Detected.ReducesProtection
        }
    }

    $State.PresetName = $Resolved.Name
    Update-WtTuiItems -State $State
    Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Preset.Loaded' -Arguments @($Resolved.Name, $State.Pending.Count)) -Tone 'StatusOk'
}

<#
.SYNOPSIS
    Writes the current pending selection as a preset file.
.DESCRIPTION
    A file write is the only side effect a preset export has; it is confirmed first and
    never overwrites an existing file silently.
#>
function Export-WtTuiPreset
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ($State.Pending.Count -eq 0)
    {
        Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Gui.NothingPending') -Tone 'StatusWarn'
        return
    }

    $Entries = @()
    foreach ($Key in $State.Pending.Keys)
    {
        $Entry = $State.Pending[$Key]
        $Export = @{ id = $Entry.Id; state = $Entry.Target }
        if ($Entry.Arguments)
        {
            $Export.arguments = $Entry.Arguments
        }
        $Entries += $Export
    }

    try
    {
        $Written = Export-WtPreset -Entries $Entries -Path $Path -Name ([System.IO.Path]::GetFileNameWithoutExtension($Path)) -Force:$false
    }
    catch
    {
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Tui.Preset.Export') -Tone 'Error' -Lines @($_.Exception.Message)
        return
    }

    Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Preset.Exported' -Arguments @($Written)) -Tone 'StatusOk'
    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Tui.Preset.Export') -Tone 'Success' -Lines @(
        (Get-WtString -Key 'Tui.Preset.Exported' -Arguments @($Written)),
        (Get-WtString -Key 'Tui.Preset.ExportedCount' -Arguments @($State.Pending.Count)))
}

<#
.SYNOPSIS
    Language picker (English / Vietnamese), applied without restarting the interface.
#>
function Show-WtTuiLanguagePicker
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Items = @()
    foreach ($Code in (Get-WtSupportedLanguages))
    {
        $Items += @{
            Label    = Get-WtString -Key "Tui.Language.$Code"
            Right    = $Code
            Payload  = $Code
            Filter   = $Code
            Disabled = $false
            Checked  = ($Code -eq $State.Language)
        }
    }

    $Result = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Cli.Language') -Items $Items -Searchable
    if ($null -eq $Result -or -not $Result.Value)
    {
        return
    }

    $Chosen = [string]$Result.Value
    Set-WtLanguage -Language $Chosen | Out-Null
    $State.Language = Get-WtLanguage

    # The choice is remembered for the next start (the -Language option still wins over it).
    Set-WtLanguagePreference -Language $State.Language | Out-Null

    # The tweak names, descriptions and history rows are localized when detection runs, so a
    # language switch re-reads them (read-only) instead of leaving half the interface in the
    # previous language. Detection never applies, resets or writes a tweak, and the search
    # text, the pending set, the cursor and the pane focus all survive it.
    Sync-WtTuiCatalog -State $State
    Update-WtTuiCategories -State $State
    Update-WtTuiItems -State $State

    # Everything else the interface draws is resolved from the string tables at paint time,
    # so one repaint covers the labels, hints, titles and status tone.
    $State.ForceRepaint = $true
    Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Status.Language' -Arguments @(Get-WtString -Key "Tui.Language.$($State.Language)"))
}

<#
.SYNOPSIS
    Returns the description of a preset in the active language.
.DESCRIPTION
    A preset file carries one description string, authored in one language. The shipped
    presets therefore have a localized description of their own; a user preset keeps the
    text from its file unchanged.
#>
function Get-WtPresetDescription
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][object]$Preset)

    if (-not $Preset)
    {
        return ''
    }

    # The shipped presets are listed explicitly (rather than composing the key from the
    # name), so every localized description is visible to the string-coverage checks and a
    # new preset cannot silently claim a missing translation.
    switch ([string]$Preset.Name)
    {
        'privacy-hardening' { return (Get-WtString -Key 'Tui.Preset.Desc.privacy-hardening') }
        'explorer-usability' { return (Get-WtString -Key 'Tui.Preset.Desc.explorer-usability') }
        default { return [string]$Preset.Description }
    }
}

<#
.SYNOPSIS
    Icon display mode picker with an in-terminal preview of every mode.
.DESCRIPTION
    The preview is built from the real glyph table of each mode with the same helpers the
    painter uses, so what is listed is exactly what the interface would draw - which is
    the only honest way to show whether the selected terminal font has those glyphs.
    Choosing a mode saves it in the settings file; no font is installed, no terminal
    setting is changed, and the picker can be reopened at once if a glyph appears as a
    box.
#>
function Show-WtTuiIconPicker
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Labels = @{
        'Auto'     = Get-WtString -Key 'Tui.Icons.Mode.Auto'
        'Unicode'  = Get-WtString -Key 'Tui.Icons.Mode.Unicode'
        'NerdFont' = Get-WtString -Key 'Tui.Icons.Mode.NerdFont'
        'ASCII'    = Get-WtString -Key 'Tui.Icons.Mode.ASCII'
        'None'     = Get-WtString -Key 'Tui.Icons.Mode.None'
    }

    $Notes = @{
        'Auto'     = Get-WtString -Key 'Tui.Icons.AutoNote'
        'Unicode'  = Get-WtString -Key 'Tui.Icons.UnicodeNote'
        'NerdFont' = (Get-WtString -Key 'Tui.Icons.NerdFontNote') + ' ' + (Get-WtString -Key 'Tui.Icons.NerdFontRequirement')
        'ASCII'    = Get-WtString -Key 'Tui.Icons.AsciiNote'
        'None'     = Get-WtString -Key 'Tui.Icons.NoneNote'
    }

    $Saved = Get-WtIconPreference
    $PreviewKeys = @(Get-WtIconPreviewKey)
    $Tables = @{}
    foreach ($Name in (Get-WtIconMode)) { $Tables[$Name] = New-WtIconTable -Mode $Name }

    $Items = @()
    foreach ($Mode in (Get-WtIconMode))
    {
        $Right = if ($Mode -eq 'Auto')
        {
            Get-WtIconSetName -Mode (Resolve-WtIconMode -Requested 'Auto' -Capability $State.Capability -Preference $Saved)
        }
        else
        {
            ''
        }

        $Items += @{
            Label    = $Labels[$Mode]
            Right    = $Right
            Checked  = ($Mode -eq $Saved)
            Disabled = $false
            Payload  = $Mode
            Filter   = "$Mode $($Labels[$Mode])"
        }
    }

    $Details = {
        param ($Item)

        $Table = $Tables[$Item.Payload]
        $Sample = Format-WtIconSample -Icons $Table -Keys $PreviewKeys
        $SampleLine = if ($Sample) { Get-WtString -Key 'Tui.Icons.Sample' -Arguments @($Sample) } else { Get-WtString -Key 'Tui.Icons.SampleNone' }

        @(
            $SampleLine,
            (Get-WtString -Key 'Tui.Icons.Slot' -Arguments @($Table.Slot)),
            $Notes[$Item.Payload]
        )
    }

    $Lines = @(
        (Get-WtString -Key 'Tui.Icons.Hint'),
        (Get-WtString -Key 'Tui.Icons.Current' -Arguments @($Labels[$Saved], $State.IconMode))
    )

    $Result = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Tui.Icons.Title') -Lines $Lines -Items $Items `
        -Details $Details -DetailsHeight 3 -Searchable
    if ($null -eq $Result -or -not $Result.Value)
    {
        return
    }

    $Mode = [string]$Result.Value
    Set-WtIconPreference -Mode $Mode | Out-Null

    # An explicit choice wins over the startup mode for this session; the frame stays in
    # whatever character set the terminal capability decided.
    $Resolved = Resolve-WtIconMode -Requested $Mode -Capability $State.Capability -Preference $Mode
    $State.IconMode = $Resolved
    $State.IconRequested = $Mode
    $State.Icons = New-WtIconTable -Mode $Resolved
    $State.Theme.Icons = $State.Icons
    $State.ForceRepaint = $true

    switch ($true)
    {
        { $Resolved -ne $Mode }
        {
            Set-WtTuiStatus -State $State -Tone 'StatusWarn' -Text (Get-WtString -Key 'Tui.Status.IconsForced' -Arguments @($Labels[$Mode], $Resolved))
        }
        { $Resolved -eq 'NerdFont' }
        {
            Set-WtTuiStatus -State $State -Tone 'StatusInfo' -Text (Get-WtString -Key 'Tui.Status.IconsNerdFont' -Arguments @($Labels[$Mode]))
        }
        default
        {
            Set-WtTuiStatus -State $State -Tone 'StatusOk' -Text (Get-WtString -Key 'Tui.Status.Icons' -Arguments @($Labels[$Mode]))
        }
    }
}

<#
.SYNOPSIS
    Shows the keyboard reference and the safety rules.
#>
function Show-WtTuiHelp
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Keys = @(
        'Tui.Help.Move', 'Tui.Help.Panes', 'Tui.Help.Select', 'Tui.Help.Enter', 'Tui.Help.Search',
        'Tui.Help.Review', 'Tui.Help.Preview', 'Tui.Help.History', 'Tui.Help.Restore', 'Tui.Help.Language',
        'Tui.Help.Icons', 'Tui.Help.IconsNote', 'Tui.Help.Presets', 'Tui.Help.DryRun', 'Tui.Help.Refresh',
        'Tui.Help.Sanity', 'Tui.Help.Recommend', 'Tui.Help.Choices',
        'Tui.Help.Help', 'Tui.Help.Escape', 'Tui.Help.Quit'
    )

    $Lines = [System.Collections.Generic.List[string]]::new()
    $Lines.Add((Get-WtString -Key 'Tui.Help.Safety'))
    foreach ($Key in $Keys)
    {
        $Lines.Add((Get-WtString -Key $Key))
    }

    $Lines.Add((Get-WtString -Key 'Tui.Help.Notes'))

    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Tui.Help.Title') -Lines $Lines.ToArray() -Icon 'Category.Help'
}

<#
.SYNOPSIS
    Shows the full environment snapshot of the Overview row.
#>
<#
.SYNOPSIS
    Overview lines for the installed packs.
.DESCRIPTION
    Read-only and data in, data out, so it can be exercised without a terminal: the interface
    shows which packs are installed, the hash recorded at import and whether they are enabled,
    and it never applies one. Importing, enabling, disabling and removing stay on the command
    line, where the command is explicit and -WhatIf is available.
.OUTPUTS
    A blank line, the section title, then one line per pack (or the "none installed" hint).
#>
function Get-WtTuiPackLines
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ()

    $Empty = '  ' + (Get-WtString -Key 'Cat.PackListEmpty')
    $Lines = @('', (Get-WtString -Key 'Cat.Tui.PacksTitle'), $Empty)
    $Packs = @(Get-WtTweakPackInternal)
    if ($Packs.Count -eq 0)
    {
        return @($Lines)
    }

    $Lines = @('', (Get-WtString -Key 'Cat.Tui.PacksTitle'))
    foreach ($Pack in $Packs)
    {
        $StateText = if ($Pack.Enabled) { Get-WtString -Key 'Cat.Tui.PackEnabled' } else { Get-WtString -Key 'Cat.Tui.PackDisabled' }
        $Hash = if ($Pack.Sha256) { $Pack.Sha256.Substring(0, [Math]::Min(12, $Pack.Sha256.Length)) } else { '' }
        $Lines += ("  " + (Get-WtString -Key 'Cat.PackRow' -Arguments @($Pack.Id, $Pack.Version, $Pack.TweakCount, $StateText, $Hash)))
    }

    return @($Lines)
}

function Show-WtTuiOverviewDetails
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Environment = $State.Environment
    $Lines = @(
        (Get-WtString -Key 'Tui.Overview.Windows') + ": $($Environment.OSName) $($Environment.OSVersionKey) $($Environment.OSBuild).$($Environment.OSUBR)"
        (Get-WtString -Key 'Tui.Overview.PowerShellVersion' -Arguments @($Environment.PowerShell, $Environment.RequiredPowerShell, $Environment.MeetsPowerShell))
        (Get-WtString -Key 'Tui.Overview.Privilege') + ": $(if ($Environment.IsAdmin) { Get-WtString -Key 'Tui.Header.Admin' } else { Get-WtString -Key 'Tui.Header.Standard' })"
        (Get-WtString -Key 'Tui.Overview.LanguageMode') + ": $($Environment.LanguageMode)"
        (Get-WtString -Key 'Tui.Overview.Reboot') + ": " + (Get-WtPendingRestartValueLabelInternal -Pending (Get-WtEnvironmentPendingRestartInternal -Environment $Environment))
        (Get-WtString -Key 'Tui.Overview.Architecture') + ": $($Environment.Architecture)"
        (Get-WtString -Key 'Tui.Overview.StatePath') + ": $($Environment.StatePath)"
        (Get-WtString -Key 'Tui.Overview.LogPath') + ": $($Environment.LogPath)"
        ''
        (Get-WtString -Key 'Tui.Overview.Capabilities')
    )

    foreach ($Name in $Environment.Capabilities.PSObject.Properties.Name)
    {
        $Available = $Environment.Capabilities.$Name
        $Lines += "  $Name : $(if ($Available) { Get-WtString -Key 'Common.Available' } else { Get-WtString -Key 'Common.NotAvailable' })"
    }

    # Installed packs, with the hash recorded at import: the interface never applies a pack - it
    # only shows what is installed, and management stays on the command line (-Pack* switches).
    $Lines += Get-WtTuiPackLines

    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Tui.Overview.Title') -Lines $Lines
}

<#
.SYNOPSIS
    Quit handling: pending changes and a running operation are both raised explicitly.
.DESCRIPTION
    The confirmation returns exactly one [bool]: True only when the highlighted choice (or
    Y) was accepted with Enter. Nothing here touches the category, the filter, the cursor,
    the pane focus or the pending set, so cancelling leaves the interface exactly as it was
    and confirming only sets the flag the main loop reads.
#>
function Invoke-WtTuiQuit
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Title = Get-WtString -Key 'Tui.Quit.Title'

    if ($State.Operation)
    {
        $Confirmed = [bool](Confirm-WtTui -State $State -Title $Title -Lines @(
                (Get-WtString -Key 'Tui.Quit.Operation'),
                (Get-WtString -Key 'Tui.Quit.OperationNote')
            ) -Tone 'Warning' -Icon 'Action.Quit')

        if (-not $Confirmed)
        {
            Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Status.QuitCancelled')
            return
        }

        # Quitting while a change is running stays cooperative: queued items are dropped, the
        # item that is already running finishes at its safe boundary, and the loop stops once
        # the operation has reported its last result.
        $State.ExitPending = $true
        Request-WtTuiCancellation -State $State
        return
    }

    $Lines = @()
    if ($State.Pending.Count -gt 0)
    {
        $Lines += Get-WtString -Key 'Tui.Quit.Pending' -Arguments @($State.Pending.Count)
        $Lines += @(Get-WtTuiPendingSummary -State $State)
    }
    else
    {
        $Lines += Get-WtString -Key 'Tui.Quit.Confirm'
    }

    $Confirmed = [bool](Confirm-WtTui -State $State -Title $Title -Lines $Lines -Tone 'Warning' -Icon 'Action.Quit')

    if (-not $Confirmed)
    {
        Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Status.QuitCancelled')
        return
    }

    # The flag the main loop reads (Start-WtTui: `while (-not $State.Exit)`), set on the same
    # state object, so the loop ends instead of the dialog being reopened.
    $State.Exit = $true
}

#endregion History, restore, presets, help

<#
.SYNOPSIS
    Verification and recovery view: drift, interrupted operations and their explicit actions.
.DESCRIPTION
    Read-only until the user asks for something. The list shows, per target, the value this
    tool applied and the value the system reports now, classified as matching, changed,
    unreadable or unsupported, with the Windows build recorded at apply time as context when
    it differs. Interrupted operations (planned or applied but never finished) are listed the
    same way. `R` reviews and reapplies the selected tweak, `U` restores the selected
    operation, `E` exports the journal, `D` exports the diagnostics - every one of them an
    explicit choice, never something the interface does on its own.
#>
function Show-WtTuiVerification
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    while ($true)
    {
        $Rows = [System.Collections.Generic.List[object]]::new()

        foreach ($Interrupted in @(Get-WtInterruptedOperationInternal))
        {
            $Rows.Add(@{
                Label   = Get-WtString -Key 'Tui.Verify.Interrupted' -Arguments @($Interrupted.TweakId, $Interrupted.Stage)
                Right   = [string]$Interrupted.StartedUtc
                Payload = @{ Kind = 'interrupted'; OperationId = [string]$Interrupted.OperationId; TweakId = [string]$Interrupted.TweakId; CanRestore = [bool]$Interrupted.CanRestore }
                Filter  = "$($Interrupted.TweakId) interrupted $($Interrupted.Stage)"
                Icon    = 'Status.Warning'
            })
        }

        foreach ($Row in @(Get-WtDriftInternal))
        {
            $Label = Get-WtString -Key 'Tui.Verify.Row' -Arguments @($Row.Label, $Row.LiveValue, $Row.IntendedValue)
            $Rows.Add(@{
                Label   = $Label
                Right   = Get-WtString -Key "Tui.Verify.Status.$($Row.Status)"
                Payload = @{ Kind = 'drift'; TweakId = [string]$Row.TweakId; Status = [string]$Row.Status; Identity = [string]$Row.Identity }
                Filter  = "$($Row.TweakId) $($Row.Label) $($Row.Status)"
                Icon    = 'Status.Warning'
            })
        }

        $Lines = @(Get-WtString -Key 'Tui.Verify.Hint')
        if ($Rows.Count -eq 0)
        {
            $Lines += (Get-WtString -Key 'Tui.Verify.Empty')
        }

        $Details = {
            param ($Item)

            $Payload = $Item.Payload
            if ($Payload.Kind -eq 'drift')
            {
                $Row = @(Get-WtDriftInternal -TweakId $Payload.TweakId) | Where-Object { $_.Identity -eq $Payload.Identity } | Select-Object -First 1
                if (-not $Row) { return @() }

                $Out = @(
                    (Get-WtString -Key 'Tui.Verify.Status') + ": $(Get-WtString -Key "Tui.Verify.Status.$($Row.Status)")",
                    (Get-WtString -Key 'Tui.Verify.Applied') + ": $($Row.IntendedValue)",
                    (Get-WtString -Key 'Tui.Verify.Live') + ": $($Row.LiveValue)",
                    (Get-WtString -Key 'Tui.Verify.AppliedAt') + ": $($Row.AppliedUtc)"
                )
                if ($Row.Reason) { $Out += $Row.Reason }
                if ($Row.BuildChanged) { $Out += (Get-WtString -Key 'Tui.Verify.BuildContext' -Arguments @($Row.RecordedBuild)) }
                return $Out
            }

            $Out = @(
                (Get-WtString -Key 'Tui.Verify.InterruptedNote'),
                (Get-WtString -Key 'Tui.Verify.CanRestore') + ": $(if ($Payload.CanRestore) { Get-WtString -Key 'Common.Yes' } else { Get-WtString -Key 'Common.No' })"
            )

            # The live value of every target the interrupted operation recorded, read-only. An
            # operation whose capture never reached the store still shows what it intended, and
            # reports the difference instead of inventing a baseline.
            $Row = @(Get-WtInterruptedOperationInternal -Targets -OperationId ([string]$Payload.OperationId)) | Select-Object -First 1
            foreach ($Target in @($Row.Targets))
            {
                $Out += (Get-WtString -Key 'Tui.Verify.TargetLive' -Arguments @($Target.Label, $Target.LiveValue, (Get-WtString -Key "Tui.Verify.Status.$($Target.Status)")))
            }

            return $Out
        }

        $OnKey = {
            param ($Overlay, $Key)

            if ($Key.Name -ne 'Char') { return $false }
            $Character = ([string]$Key.Char).ToLowerInvariant()
            $Item = $Overlay.List.Items[[int]$Overlay.List.Cursor]
            if (-not $Item) { return $false }

            if ($Character -eq 'r')
            {
                # Review and reapply: the tweak goes into the pending set, and the normal apply
                # path (with its own revalidation) takes over.
                $TweakId = [string]$Item.Payload.TweakId
                $Detected = Get-WtTweakState -Id $TweakId | Select-Object -First 1
                if (-not $Detected -or -not $Detected.ApplyAllowed)
                {
                    Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Status.Unsupported' -Arguments @($TweakId)) -Tone 'StatusWarn'
                    return $true
                }

                $Overlay.Accepted = $true
                $Overlay.Result = @{ Action = 'Reapply'; TweakId = $TweakId }
                return $true
            }

            if ($Character -eq 'u')
            {
                $Overlay.Accepted = $true
                $Overlay.Result = @{ Action = 'Restore'; Match = $Item.Payload }
                return $true
            }

            if ($Character -eq 'e')
            {
                $Overlay.Accepted = $true
                $Overlay.Result = @{ Action = 'ExportJournal' }
                return $true
            }

            if ($Character -eq 'd')
            {
                $Overlay.Accepted = $true
                $Overlay.Result = @{ Action = 'ExportDiagnostics' }
                return $true
            }

            return $false
        }

        $Result = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Tui.Verify.Title') -Lines $Lines -Items @($Rows.ToArray()) `
            -Searchable -Details $Details -OnKey $OnKey -DetailsHeight 6 -EmptyText (Get-WtString -Key 'Tui.Verify.Empty')

        if ($null -eq $Result -or $null -eq $Result.Value)
        {
            return
        }

        switch ([string]$Result.Value.Action)
        {
            'Reapply'
            {
                $TweakId = [string]$Result.Value.TweakId
                if (Confirm-WtTui -State $State -Title (Get-WtString -Key 'Tui.Verify.ReapplyTitle') -Lines @(
                        (Get-WtString -Key 'Tui.Verify.ReapplyNote' -Arguments @($TweakId)),
                        (Get-WtString -Key 'Tui.Pending.ReviewHint')
                    ))
                {
                    Set-WtTuiCategory -State $State -Key 'History'
                    $State.Search = $TweakId
                    Set-WtTuiCategory -State $State -Key 'Overview'
                    $State.Search = ''
                    Update-WtTuiItems -State $State
                    $Index = -1
                    for ($Position = 0; $Position -lt $State.Items.Count; $Position++)
                    {
                        if ($State.Items[$Position].Kind -eq 'Tweak' -and $State.Items[$Position].State.Id -eq $TweakId)
                        {
                            $Index = $Position
                            break
                        }
                    }

                    if ($Index -ge 0)
                    {
                        Set-WtTuiItemIndex -State $State -Index $Index
                        Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Verify.ReapplySelected' -Arguments @($TweakId))
                    }
                    else
                    {
                        Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Verify.ReapplyNotFound' -Arguments @($TweakId)) -Tone 'StatusWarn'
                    }
                }

                return
            }

            'Restore'
            {
                $Match = $Result.Value.Match
                if (-not $Match.CanRestore)
                {
                    Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Verify.NoRecovery' -Arguments @($Match.TweakId)) -Tone 'StatusWarn'
                    return
                }

                if (Confirm-WtTui -State $State -Title (Get-WtString -Key 'Tui.Verify.RestoreTitle') -Lines @(
                        (Get-WtString -Key 'Tui.Verify.RestoreNote' -Arguments @($Match.TweakId)),
                        (Get-WtString -Key 'Tui.Restore.Irreversible')
                    ) -Tone 'Warning')
                {
                    Start-WtTuiOperation -State $State -RollbackItem @{
                        TweakId   = $Match.TweakId
                        HistoryId = $Match.OperationId
                        Timestamp = ''
                    }
                }

                return
            }

            'ExportJournal'
            {
                $Path = Join-Path (Get-WtDataRoot) ("journal-{0}.json" -f (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))
                try
                {
                    Export-WtHistory -Path $Path -Force | Out-Null
                    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Tui.Verify.ExportTitle') -Tone 'Success' -Lines @((Get-WtString -Key 'Tui.Verify.Exported' -Arguments @($Path)))
                }
                catch
                {
                    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Tui.Verify.ExportTitle') -Tone 'Error' -Lines @($_.Exception.Message)
                }

                continue
            }

            'ExportDiagnostics'
            {
                $Path = Join-Path (Get-WtDataRoot) ("diagnostics-{0}.jsonl" -f (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))
                try
                {
                    Export-WtDiagnostics -Path $Path -Force | Out-Null
                    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Tui.Verify.ExportTitle') -Tone 'Success' -Lines @(
                        (Get-WtString -Key 'Tui.Verify.DiagnosticsExported' -Arguments @($Path)),
                        (Get-WtString -Key 'Tui.Verify.DiagnosticsNote')
                    )
                }
                catch
                {
                    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Tui.Verify.ExportTitle') -Tone 'Error' -Lines @($_.Exception.Message)
                }

                continue
            }

            default { return }
        }
    }
}

<#
.SYNOPSIS
    Read-only sanity scan: what is worth reviewing, and what the scan could not check.
.DESCRIPTION
    The scan runs when the view opens and when R is pressed; it writes nothing, repairs nothing and
    deletes nothing, and it reports Incomplete rather than Clean when a required probe failed. A
    finding shows the observed value, the documented expectation, why it deserves a look, what the
    rule does not cover, the claim it rests on and its source. Nothing can be applied from here:
    remediation is a separate, reviewed action.
#>
function Show-WtTuiSanity
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Scan = $null
    try
    {
        $Scan = Get-WtSanityScan
    }
    catch
    {
        Set-WtTuiStatus -State $State -Text $_.Exception.Message -Tone 'StatusWarn'
        return
    }

    if (-not $Scan)
    {
        Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Cat.Sanity.NoRules') -Tone 'StatusWarn'
        return
    }

    $Rows = [System.Collections.Generic.List[object]]::new()
    foreach ($Finding in @($Scan.Findings))
    {
        $Rows.Add(@{
                Label   = ('[{0}] {1}: {2}' -f $Finding.Severity, (Get-WtText -Value $Finding.Title), $Finding.Observed)
                Right   = [string]$Finding.RuleId
                Payload = $Finding
                Filter  = "$($Finding.RuleId) $($Finding.Target) $($Finding.Observed) $($Finding.Area)"
                Icon    = 'Status.Warning'
            })
    }

    $Lines = @(
        (Get-WtString -Key 'Cat.Sanity.ReadOnly'),
        (Get-WtScanOutcomeLabelInternal -Outcome $Scan.Outcome),
        (Get-WtString -Key 'Cat.Sanity.Summary' -Arguments @(
                $Scan.RuleCount,
                @($Scan.Rules | Where-Object { $_.Outcome -eq 'Findings' }).Count,
                @($Scan.Rules | Where-Object { $_.Outcome -eq 'Incomplete' }).Count,
                @($Scan.Rules | Where-Object { $_.Outcome -eq 'Unsupported' }).Count,
                $Scan.FindingCount)),
        (Get-WtString -Key 'Cat.Tui.Sanity.Keys')
    )

    foreach ($Gap in @($Scan.Gaps))
    {
        $Lines += (Get-WtString -Key 'Cat.Sanity.Gap' -Arguments @($Gap.RuleId, $Gap.Outcome, $Gap.Reason))
    }

    $Details = {
        param ($Item)

        $Finding = $Item.Payload
        if (-not $Finding) { return @() }

        $Out = @(
            (Get-WtString -Key 'Cat.Sanity.Severity') + ": $($Finding.Severity)",
            (Get-WtString -Key 'Cat.Sanity.Target') + ": $($Finding.Target)",
            (Get-WtString -Key 'Cat.Sanity.Observed') + ": $($Finding.Observed)",
            (Get-WtString -Key 'Cat.Sanity.ObservedType') + ": $($Finding.ObservedTypeLabel)",
            (Get-WtString -Key 'Cat.Sanity.Expected') + ": " + (Get-WtText -Value $Finding.Expected),
            (Get-WtString -Key 'Cat.Sanity.WhyReview') + ": " + (Get-WtText -Value $Finding.Rationale),
            (Get-WtString -Key 'Cat.Sanity.EffectiveKind') + ": $($Finding.EffectiveLabel)",
            (Get-WtString -Key 'Cat.Sanity.Conditions') + ": $($Finding.ConditionsLabel)",
            (Get-WtString -Key 'Cat.Sanity.Claim') + ": $($Finding.Claim)"
        )

        if ($Finding.RemediationLabel) { $Out += (Get-WtString -Key 'Cat.Sanity.Remediation') + ": $($Finding.RemediationLabel)" }
        if ($Finding.Limitations) { $Out += (Get-WtString -Key 'Cat.Sanity.Limitations') + ": " + (Get-WtText -Value $Finding.Limitations) }
        if ($Finding.NextStep) { $Out += (Get-WtString -Key 'Cat.Sanity.NextStep') + ": " + (Get-WtText -Value $Finding.NextStep) }
        if ($Finding.Source -and $Finding.Source.Url) { $Out += (Get-WtString -Key 'Cat.Sanity.Source') + ": $($Finding.Source.Url)" }

        return $Out
    }

    $OnKey = {
        param ($Overlay, $Key)

        if ($Key.Name -ne 'Char') { return $false }
        $Character = ([string]$Key.Char).ToLowerInvariant()

        if ($Character -eq 'e')
        {
            $Overlay.Accepted = $true
            $Overlay.Result = @{ Action = 'Export' }
            return $true
        }

        return $false
    }

    $Result = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Cat.Sanity.Title') -Lines $Lines -Items @($Rows.ToArray()) `
        -Searchable -Details $Details -OnKey $OnKey -DetailsHeight 5 -EmptyText (Get-WtString -Key 'Cat.Tui.Sanity.Empty')

    if ($null -eq $Result -or $null -eq $Result.Value) { return }

    if ([string]$Result.Value.Action -eq 'Export')
    {
        $Path = Read-WtTuiText -State $State -Title (Get-WtString -Key 'Cat.Tui.Sanity.ExportPrompt') `
            -Label (Get-WtString -Key 'Cat.Tui.Sanity.ExportPrompt') `
            -Lines @((Get-WtString -Key 'Cat.Tui.Sanity.ExportHint')) `
            -Validate {
                param ($Value)
                if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
                $Parent = Split-Path -Parent $Value
                return [bool]((Test-Path -LiteralPath $Parent -PathType Container) -and -not (Test-Path -LiteralPath $Value))
            }

        if (-not $Path) { return }

        try
        {
            # The scan the reviewer is looking at is exported, not a fresh one: a report that
            # disagrees with the screen is worse than no report, and a second run would also run
            # the boot-entry probe again.
            $Written = Export-WtSanityReportInternal -Scan $Scan -Path $Path
            if ($Written.Ok)
            {
                Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Cat.Tui.Sanity.ExportWritten' -Arguments @([string]$Written.Path))
            }
            else
            {
                Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Cat.Tui.Sanity.ExportFailed' -Arguments @([string]$Written.Message)) -Tone 'StatusWarn'
            }
        }
        catch
        {
            Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Cat.Tui.Sanity.ExportFailed' -Arguments @($_.Exception.Message)) -Tone 'StatusWarn'
        }
    }
}

<#
.SYNOPSIS
    Recommendations for one objective, with the reason for every item.
.DESCRIPTION
    A proposal, nothing more: opening this view, changing the objective or recomputing never applies
    anything and never discards a manual selection - the pending set is left exactly as it was, and
    the view says so. Left/Right cycles the objectives, and each objective stands on its own: when
    nothing qualifies, the view says nothing qualifies rather than borrowing another objective's
    items.
#>
function Show-WtTuiRecommendations
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Objectives = @(Get-WtRecommendationObjective)
    if ($Objectives.Count -eq 0) { return }

    if (-not $State.RecommendObjective -or @($Objectives | Where-Object { $_.Name -eq $State.RecommendObjective }).Count -eq 0)
    {
        $State.RecommendObjective = [string]$Objectives[0].Name
    }

    while ($true)
    {
        $Objective = [string]$State.RecommendObjective
        $Proposal = Get-WtRecommendation -Objective $Objective -IncludeManual

        $Rows = [System.Collections.Generic.List[object]]::new()
        foreach ($Item in @($Proposal.Items))
        {
            $Icon = switch ([string]$Item.Decision)
            {
                'Recommended' { 'Status.Success' }
                'AlreadySatisfied' { 'Status.Ready' }
                'Blocked' { 'Status.Error' }
                'Unknown' { 'Status.Warning' }
                default { 'Status.Muted' }
            }

            $Rows.Add(@{
                    Label   = (Get-WtString -Key 'Cat.Tui.Rec.Item' -Arguments @($Item.Decision, $Item.Id, (Get-WtRecommendationKindLabelInternal -Kind $Item.Kind)))
                    Right   = [string]$Item.Decision
                    Payload = $Item
                    Filter  = "$($Item.Id) $($Item.Decision) $($Item.Category) $($Item.Kind)"
                    Icon    = $Icon
                })
        }

        $PendingKept = $State.Pending.Count
        $ObjectiveEntry = @($Objectives | Where-Object { $_.Name -eq $Objective } | Select-Object -First 1)
        $Lines = @(
            (Get-WtString -Key 'Rec.NotApplied'),
            (Get-WtString -Key 'Cat.Tui.Rec.ObjectiveLine' -Arguments @($Objective)),
            [string]$ObjectiveEntry.Description,
            (Get-WtString -Key 'Cat.Tui.Rec.Summary' -Arguments @(
                    $Proposal.Counts['Recommended'], $Proposal.Counts['AlreadySatisfied'], $Proposal.Counts['Excluded'],
                    $Proposal.Counts['Unknown'], $Proposal.Counts['Blocked'])),
            (Get-WtString -Key 'Cat.Tui.Rec.Kept' -Arguments @($PendingKept)),
            (Get-WtString -Key 'Cat.Tui.Rec.Keys')
        )

        if (@($Proposal.Recommended).Count -eq 0)
        {
            $Lines += (Get-WtString -Key 'Cat.Tui.Rec.NoCandidates')
        }

        $Details = {
            param ($Item)

            $Out = @(
                (Get-WtString -Key 'Cat.Tui.Rec.Explanation'),
                (Get-WtRecommendationReasonInternal -Item $Item.Payload)
            )

            if ($Item.Payload.Rationale) { $Out += (Get-WtText -Value $Item.Payload.Rationale) }
            $Out += (Get-WtString -Key 'Cat.Tui.Configured') + ": " + (Get-WtDimensionLabelInternal -Dimension 'Configured' -Value $Item.Payload.Configured)
            $Out += (Get-WtString -Key 'Cat.Tui.Rec.Evidence' -Arguments @(
                    (Get-WtDimensionLabelInternal -Dimension 'Effective' -Value $Item.Payload.Effective),
                    (Get-WtDimensionLabelInternal -Dimension 'Evidence' -Value $Item.Payload.EffectiveEvidence)))
            $Out += (Get-WtString -Key 'Cat.Tui.Ownership') + ": " + (Get-WtDimensionLabelInternal -Dimension 'Ownership' -Value $Item.Payload.Ownership)
            $Out += (Get-WtString -Key 'Cat.Tui.Rec.Verification' -Arguments @(
                    $(if ($Item.Payload.VerificationLabel) { $Item.Payload.VerificationLabel } else { (Get-WtDimensionLabelInternal -Dimension 'Evidence' -Value 'Unknown') })))

            return $Out
        }

        $OnKey = {
            param ($Overlay, $Key)

            $Character = if ($Key.Name -eq 'Char') { ([string]$Key.Char).ToLowerInvariant() } else { '' }

            # The objective is a single choice, so it is changed with the arrows as the help line
            # documents, and 'o' walks forward for the key that was documented before them. None of
            # these touches the pending set.
            if ($Character -eq 'o')
            {
                $Overlay.Accepted = $true
                $Overlay.Result = @{ Action = 'Objective'; Step = 1 }
                return $true
            }

            if ($Key.Name -eq 'Left' -or $Key.Name -eq 'Right')
            {
                $Overlay.Accepted = $true
                $Overlay.Result = @{ Action = 'Objective'; Step = $(if ($Key.Name -eq 'Left') { -1 } else { 1 }) }
                return $true
            }

            return $false
        }

        # The objective selector is a list dialog too: the selected row *is* the objective, so the
        # chooser never needs a second modal and never touches the pending set.
        $Result = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Rec.Title') -Lines $Lines -Items @($Rows.ToArray()) `
            -Searchable -Details $Details -OnKey $OnKey -DetailsHeight 5 -EmptyText (Get-WtString -Key 'Cat.Tui.Rec.NoCandidates')

        if ($null -eq $Result -or $null -eq $Result.Value) { return }
        if ([string]$Result.Value.Action -ne 'Objective') { return }

        $Names = @($Objectives | ForEach-Object { $_.Name })
        $Index = $Names.IndexOf($Objective)
        $Step = [int]$Result.Value.Step
        # A cyclic step in either direction: the objective is a choice, and reaching the end of the
        # list must not silently do nothing.
        $Index = (($Index + $Step) % $Names.Count + $Names.Count) % $Names.Count
        $State.RecommendObjective = [string]$Names[$Index]
    }
}

<#
.SYNOPSIS
    Settings that offer several alternatives: one can be pending at a time.
.DESCRIPTION
    Choosing an alternative replaces the pending one for that setting - it is one tweak with several
    states, so the pending set cannot hold two of them - and the replacement recomputes nothing by
    hand: the engine revalidates and re-plans from the new target, and the earlier review of this
    item no longer counts. Restoring the captured original state is a different action and lives in
    the journal, not here.
#>
function Show-WtTuiChoices
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Groups = @(Get-WtChoiceGroup -Pending $State.Pending)
    if ($Groups.Count -eq 0)
    {
        Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Cat.Tui.Choices.Empty')
        return
    }

    $Rows = [System.Collections.Generic.List[object]]::new()
    foreach ($Group in $Groups)
    {
        # What is live and what is pending are two different facts, so the row carries both: the
        # detected alternative stays visible while another one is pending.
        $Current = (Get-WtString -Key 'Cat.Tui.Choices.Current' -Arguments @((Get-WtGroupStateLabelInternal -Group $Group)))
        if ($Group.PendingState)
        {
            $Current += ' | ' + (Get-WtString -Key 'Cat.Tui.Choices.Pending' -Arguments @($Group.PendingState))
        }

        $Rows.Add(@{
                Label   = (Get-WtText -Value $Group.Labels)
                Right   = $Current
                Payload = $Group
                Filter  = "$($Group.Id) $($Group.TweakId) $($Group.CurrentState) $($Group.PendingState)"
                Icon    = 'Status.Ready'
            })
    }

    $Lines = @(
        (Get-WtString -Key 'Cat.Tui.Group.Options'),
        (Get-WtString -Key 'Cat.Tui.Group.ReplaceNote'),
        (Get-WtString -Key 'Cat.Tui.Group.RestoreNote'),
        (Get-WtString -Key 'Cat.Tui.Choices.Keys')
    )

    $Details = {
        param ($Item)

        $Group = $Item.Payload
        $Out = @((Get-WtText -Value $Group.Descriptions), (Get-WtString -Key 'Cat.Tui.Group.Current') + ": " + (Get-WtGroupStateLabelInternal -Group $Group))

        foreach ($Option in @($Group.Options))
        {
            # A radio marker for what is pending (one alternative at a time) and a separate mark
            # for what is live: they are different questions and must not share one glyph.
            $Radio = if ($Option.Pending) { Get-WtString -Key 'Cat.Tui.Choices.RadioSelected' } else { Get-WtString -Key 'Cat.Tui.Choices.RadioEmpty' }
            $Mark = if ($Option.Detected) { (Get-WtString -Key 'Cat.Tui.Group.Detected') } else { '' }
            $Out += (Get-WtString -Key 'Cat.Tui.Choices.Option' -Arguments @(
                    "$Radio " + (Get-WtText -Value $Option.Labels),
                    "$(Get-WtIntentLabelInternal -Intent $Option.Intent) $Mark").Trim())
        }

        if ($Group.Notes) { $Out += (Get-WtText -Value $Group.Notes) }
        return $Out
    }

    $Result = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Cat.Tui.Group') -Lines $Lines -Items @($Rows.ToArray()) `
        -Searchable -Details $Details -DetailsHeight 8 -EmptyText (Get-WtString -Key 'Cat.Tui.Choices.Empty')

    if ($null -eq $Result -or $null -eq $Result.Value) { return }

    # A list dialog returns the payload as its Value: the row is the item, the payload inside it
    # is what the row means. Reading one level too deep left this view with $null and it reported
    # every group as one that cannot run here.
    $Group = $Result.Value
    if (-not $Group.Supported)
    {
        Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Cat.Tui.Choices.NotSupported' -Arguments @($Group.TweakId)) -Tone 'StatusWarn'
        return
    }

    $Options = [System.Collections.Generic.List[object]]::new()
    foreach ($Option in @($Group.Options))
    {
        $Options.Add(@{
                Label   = (Get-WtText -Value $Option.Labels)
                Right   = (Get-WtIntentLabelInternal -Intent $Option.Intent)
                Payload = $Option
                Filter  = "$($Option.Id) $($Option.Intent)"
                Icon    = $(if ($Option.Detected) { 'Status.Success' } else { 'Status.Muted' })
            })
    }

    $Choice = Select-WtTuiItem -State $State -Title (Get-WtText -Value $Group.Labels) -Lines @(
        (Get-WtString -Key 'Cat.Tui.Group.ReplaceNote'),
        (Get-WtString -Key 'Cat.Tui.Group.RestoreNote')
    ) -Items @($Options.ToArray()) -DetailsHeight 0 -EmptyText (Get-WtString -Key 'Cat.Tui.Choices.Empty')

    if ($null -eq $Choice -or $null -eq $Choice.Value) { return }

    $Entry = Get-WtTweakState -Id $Group.TweakId | Select-Object -First 1
    if (-not $Entry -or -not $Entry.ApplyAllowed)
    {
        Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Cat.Tui.Choices.NotSupported' -Arguments @($Group.TweakId)) -Tone 'StatusWarn'
        return
    }

    $Replaced = $State.Pending.Contains($Entry.Id)
    $Option = $Choice.Value
    Add-WtTuiPending -State $State -Entry $Entry -Target ([string]$Option.Id) -Arguments $null -Intent ([string]$Option.Intent)

    # Recompute instead of promising: the conflicts and the dependency plan of everything pending
    # are recalculated from the new target right now, so the status line reports a count that was
    # actually observed. Nothing is applied by any of this, and the review fingerprint of this item
    # went away with the replaced entry.
    $ConflictCount = 0
    $PlanFailed = $false
    try
    {
        $Previews = @()
        foreach ($Key in $State.Pending.Keys)
        {
            $PendingEntry = $State.Pending[$Key]
            try
            {
                $Previews += Get-WtChangePreviewInternal -Id $PendingEntry.Id -State $PendingEntry.Target -Arguments $PendingEntry.Arguments
            }
            catch
            {
                Write-WtLog -Level Warning -Message "Preview unavailable for $($PendingEntry.Id): $($_.Exception.Message)" -NoConsole
            }
        }

        $ConflictCount = @(Get-WtChangeConflictInternal -Preview @($Previews)).Count
        $Plan = Get-WtDependencyPlanInternal -Ids @($State.Pending.Keys | ForEach-Object { [string]$_ })
        if ($Plan -and @($Plan.Errors).Count -gt 0) { $PlanFailed = $true }
    }
    catch
    {
        $PlanFailed = $true
        Write-WtLog -Level Warning -Message "Dependency plan unavailable: $($_.Exception.Message)" -NoConsole
    }

    $Outcome = $(if ($ConflictCount -gt 0) { Get-WtString -Key 'Cat.Tui.Choices.Conflicts' -Arguments @($ConflictCount) } else { Get-WtString -Key 'Cat.Tui.Choices.NoConflicts' })
    if ($PlanFailed) { $Outcome += ' ' + (Get-WtString -Key 'Cat.Tui.Choices.PlanFailed') }

    if ($Replaced)
    {
        Set-WtTuiStatus -State $State -Text ((Get-WtString -Key 'Cat.Tui.Choices.Replaced' -Arguments @($Entry.Id, $Option.Id)) + ' ' + $Outcome)
    }
    else
    {
        Set-WtTuiStatus -State $State -Text ((Get-WtString -Key 'Cat.Tui.Choices.Chosen' -Arguments @($Entry.Id, $Option.Id)) + ' ' + $Outcome)
    }
}
