# WindowsTweaker - bridge task runner (background runspace pool).
#
# Long or streaming operations (state scans, applies, rollback, external-tool actions)
# run in their own runspace so the host loop keeps reading stdin and honouring cancel /
# quit requests. One task per operation; a second mutating task is refused while one is
# running (single-writer rule, same as the engine). Every task carries:
#   - a deadline from the operation table that aborts it (cooperatively first),
#   - a cancel flag checked at safe boundaries by the operation itself,
#   - a bounded event queue the host drains into protocol frames.
#
# The worker runspace imports the module and runs the entire operation switch inside the
# module scope (`& $Module { ... }`), which is how it reaches the engine's private
# helpers. It never talks to the UI thread and it never paints.

$Script:WtBridgeTaskEventCap = 500

<#
.SYNOPSIS
    Creates the session-scoped task registry.
#>
function New-WtBridgeSession
{
    [CmdletBinding()]
    param ()

    return @{
        Tasks = @{}
        MutatingRunning = $false
        NextSequence = 0
    }
}

<#
.SYNOPSIS
    Returns the operation definition for a name, or $null.
#>
function Get-WtBridgeOperation
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Name)

    $Ops = Get-WtBridgeOperations
    if ($Ops.ContainsKey($Name)) { return $Ops[$Name] }
    return $null
}

<#
.SYNOPSIS
    Creates and starts a background task in a fresh runspace.
.DESCRIPTION
    The runspace is dedicated to this task and is disposed when the task finishes, so a
    hung operation can be aborted without poisoning the next one. Events are frames
    (ordered hashtables) or the string 'done' as the terminal sentinel.
#>
function Start-WtBridgeTask
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$Session,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Options,
        [Parameter(Mandatory = $true)][string]$ModulePath
    )

    $Operation = Get-WtBridgeOperation -Name $Name
    if (-not $Operation) { return $null }

    if ($Operation.Mutating -and $Session.MutatingRunning)
    {
        return $null
    }
    if ($Operation.Mutating) { $Session.MutatingRunning = $true }

    $Events = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $Cancel = [hashtable]::Synchronized(@{ Requested = $false })

    $Task = @{
        Id = $Id
        Name = $Name
        Options = $Options
        Events = $Events
        Cancel = $Cancel
        State = 'running'
        StartedUtc = [datetime]::UtcNow
        DeadlineUtc = [datetime]::UtcNow.AddMilliseconds([double]$Operation.TimeoutMs)
        TimeoutMs = [int]$Operation.TimeoutMs
        Mutating = [bool]$Operation.Mutating
        Phase = 'starting'
        Text = ''
        Item = $null
        Done = 0
        Total = 0
        Ps = $null
        Runspace = $null
        Handle = $null
        Result = $null
        Error = $null
        ErrorCode = ''
        Expired = $false
    }

    $Session.Tasks[$Id] = $Task

    $Runspace = [runspacefactory]::CreateRunspace()
    $Runspace.ApartmentState = 'MTA'
    $Runspace.ThreadOptions = 'ReuseThread'
    $Runspace.Open()

    $PowerShell = [powershell]::Create()
    $PowerShell.Runspace = $Runspace

    [void]$PowerShell.AddScript({
        param ($ModulePath, $Task)

        # The worker owns no terminal and no keyboard. The protocol helpers are dot-sourced
        # in this scope so the same framing functions (and their bounds) exist here.
        $Protocol = Join-Path (Split-Path $ModulePath -Parent) 'Private/Bridge/BridgeProtocol.ps1'
        if (Test-Path -LiteralPath $Protocol) { . $Protocol }

        # The whole operation dispatch runs inside the module scope: the engine's private
        # helpers are reachable there, and no prompt can ever block this runspace.
        $Module = Import-Module -Name $ModulePath -Force -PassThru
        $ConfirmPreference = 'None'
        $ProgressPreference = 'SilentlyContinue'

        $Protocol = Join-Path (Split-Path $ModulePath -Parent) 'Private/Bridge/BridgeProtocol.ps1'
        if (Test-Path -LiteralPath $Protocol) { . $Protocol }
        $Dto = Join-Path (Split-Path $ModulePath -Parent) 'Private/Bridge/BridgeDto.ps1'
        if (Test-Path -LiteralPath $Dto) { . $Dto }

        & $Module {
            param ($Task)

            function Add-WtBridgeTaskEvent
            {
                param ($Frame)
                $Task.Events.Enqueue($Frame)
                if ($Task.Events.Count -gt 500)
                {
                    $Dropped = $null
                    [void]$Task.Events.TryDequeue([ref]$Dropped)
                }
            }

            try
            {
                Initialize-WtLogging -Console $false | Out-Null
                Initialize-WtLocalization | Out-Null
                Add-WtBridgeTaskEvent (New-WtBridgeProgressFrame -Id $Task.Id -Phase 'starting' -Text '')
                switch -Regex ($Task.Name)
                {
                    '^state\.get$'
                    {
                        $Params = @{ }
                        if ($Task.Options.ContainsKey('category') -and $Task.Options['category']) { $Params['Category'] = [string]$Task.Options['category'] }
                        if ($Task.Options.ContainsKey('search') -and $Task.Options['search']) { $Params['Search'] = [string]$Task.Options['search'] }
                        if ($Task.Options.ContainsKey('id') -and $Task.Options['id']) { $Params['Id'] = [string]$Task.Options['id'] }
                        Add-WtBridgeTaskEvent (New-WtBridgeProgressFrame -Id $Task.Id -Phase 'collecting' -Text (Get-WtString -Key 'Tui.Status.Refreshing'))
                        $Rows = @(Get-WtTweakState @Params | ForEach-Object { ConvertTo-WtBridgeStateRow -Row $_ })
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Rows)
                    }
                    '^state\.refresh$'
                    {
                        $Rows = @(Get-WtTweakState | ForEach-Object { ConvertTo-WtBridgeStateRow -Row $_ })
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Rows)
                    }
                    '^preview\.get$'
                    {
                        $Id = [string]$Task.Options['id']
                        $State = ''
                        if ($Task.Options.ContainsKey('state')) { $State = [string]$Task.Options['state'] }
                        $Arguments = $null
                        if ($Task.Options.ContainsKey('arguments')) { $Arguments = $Task.Options['arguments'] }
                        $Params = @{ Id = $Id }
                        if ($State) { $Params['State'] = $State }
                        if ($null -ne $Arguments) { $Params['Arguments'] = $Arguments }
                        $Preview = Get-WtChangePreview @Params
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data (ConvertTo-WtBridgePreview -Preview $Preview))
                    }
                    '^plan\.get$'
                    {
                        $Ids = @()
                        if ($Task.Options.ContainsKey('ids')) { $Ids = @($Task.Options['ids']) }
                        $StateMap = $null
                        if ($Task.Options.ContainsKey('states')) { $StateMap = $Task.Options['states'] }
                        $Params = @{ Id = $Ids }
                        if ($null -ne $StateMap) { $Params['State'] = $StateMap }
                        $Plan = Get-WtDependencyPlan @Params
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Plan)
                    }
                    '^history\.list$'
                    {
                        $Limit = 100
                        if ($Task.Options.ContainsKey('limit')) { $Limit = [int]$Task.Options['limit'] }
                        $Rows = @(Get-WtHistory -Limit $Limit | ForEach-Object { ConvertTo-WtBridgeHistoryRow -Row $_ })
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Rows)
                    }
                    '^journal\.operation$'
                    {
                        $Limit = 100
                        if ($Task.Options.ContainsKey('limit')) { $Limit = [int]$Task.Options['limit'] }
                        $Rows = @(Get-WtOperation -Limit $Limit | ForEach-Object { ConvertTo-WtBridgeOperationRow -Row $_ })
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Rows)
                    }
                    '^history\.interrupted$'
                    {
                        $Params = @{ }
                        if ($Task.Options.ContainsKey('targets') -and $Task.Options['targets']) { $Params['Targets'] = $true }
                        $Rows = @(Get-WtInterruptedOperation @Params | ForEach-Object { ConvertTo-WtBridgeInterruptedRow -Row $_ })
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Rows)
                    }
                    '^restore\.plan$'
                    {
                        $Params = @{ }
                        if ($Task.Options.ContainsKey('sessionId') -and $Task.Options['sessionId']) { $Params['SessionId'] = [string]$Task.Options['sessionId'] }
                        $Plan = Get-WtRestorePlan @Params
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Plan)
                    }
                    '^session\.list$'
                    {
                        $Rows = @(Get-WtSession)
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Rows)
                    }
                    '^drift\.get$'
                    {
                        $Params = @{ }
                        if ($Task.Options.ContainsKey('onlyDrifted') -and $Task.Options['onlyDrifted']) { $Params['OnlyDrifted'] = $true }
                        $Rows = @(Get-WtDrift @Params)
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Rows)
                    }
                    '^preset\.list$'
                    {
                        $Rows = @(Get-WtPreset)
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Rows)
                    }
                    '^preset\.load$'
                    {
                        $Params = @{ }
                        if ($Task.Options.ContainsKey('name') -and $Task.Options['name']) { $Params['Name'] = [string]$Task.Options['name'] }
                        $Rows = @(Get-WtPreset @Params)
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Rows)
                    }
                    '^diagnostics\.report$'
                    {
                        $Rows = @(Get-WtTweakState)
                        $Report = @{
                            generatedAt = (Get-Date).ToUniversalTime().ToString('o')
                            environment = (Get-WtEnvironment)
                            language = (Get-WtLanguage)
                            history = @(Get-WtHistory -Limit 200)
                            tweaks = @($Rows | Select-Object Id, Category, Name, State, Supported, UnsupportedReason, Managed, ManagedBy, Risk, Restart, Rollback, Irreversible, DataDeletion, Requires)
                        }
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Report)
                    }
                    '^scan\.directory$'
                    {
                        $Path = [string]$Task.Options['path']
                        Add-WtBridgeTaskEvent (New-WtBridgeProgressFrame -Id $Task.Id -Phase 'scanning' -Text $Path)
                        $Result = Invoke-WtDirectoryScan -Path $Path
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Result)
                    }
                    '^monitor\.cycle$'
                    {
                        Add-WtBridgeTaskEvent (New-WtBridgeProgressFrame -Id $Task.Id -Phase 'monitoring' -Text '')
                        $Result = Measure-WtMonitorCycle
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Result)
                    }
                    '^metrics\.range$'
                    {
                        $Rows = @(Get-WtStoredMetricRange)
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Rows)
                    }
                    '^inventory\.devices$'
                    {
                        $Result = Get-WtDeviceInventory
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Result)
                    }
                    '^power\.settings$'
                    {
                        $Result = Get-WtPowerSettings
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Result)
                    }
                    '^privacy\.activity$'
                    {
                        $Result = Get-WtPrivacyActivity
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Result)
                    }
                    '^quarantine\.summary$'
                    {
                        $Result = Get-WtQuarantineSummary
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Result)
                    }
                    '^quarantine\.candidates$'
                    {
                        $Rows = @(Get-WtQuarantineCandidates)
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Rows)
                    }
                    '^setup\.list$'
                    {
                        $Rows = @(Get-WtSetupPlan)
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Rows)
                    }
                    '^setup\.preview$'
                    {
                        $Params = @{ }
                        if ($Task.Options.ContainsKey('planId') -and $Task.Options['planId']) { $Params['Id'] = [string]$Task.Options['planId'] }
                        $Preview = Get-WtSetupPlanPreview @Params
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Preview)
                    }
                    '^licensing\.diagnostics$'
                    {
                        $Result = Get-WtLicensingDiagnostics
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Result)
                    }
                    '^exttool\.status$'
                    {
                        $Result = Get-WtExternalToolState
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Result)
                    }
                    '^exttool\.methods$'
                    {
                        $Methods = @(Get-WtWindowsActivationMethod)
                        $Selected = Get-WtWindowsActivationMethodSetting
                        $Edition = Get-WtWindowsActivationEdition
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data @{
                            methods = $Methods
                            selected = $Selected
                            edition = $Edition
                        })
                    }
                    '^exttool\.download$'
                    {
                        $Latest = $false
                        if ($Task.Options.ContainsKey('latest') -and $Task.Options['latest']) { $Latest = $true }
                        $CancelRef = $Task.Cancel
                        $ProgressState = @{ Phase = 'idle'; Received = [long]0; Total = [long]0; Percent = -1 }
                        $Result = Invoke-WtExternalToolDownload -Progress $ProgressState -Cancel $CancelRef -Latest:$Latest
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Result)
                    }
                    '^exttool\.remove$'
                    {
                        $Result = Remove-WtExternalToolFiles
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Result)
                    }
                    '^exttool\.activate$'
                    {
                        $MethodId = ''
                        if ($Task.Options.ContainsKey('method')) { $MethodId = [string]$Task.Options['method'] }
                        $WaitSeconds = 1800
                        if ($Task.Options.ContainsKey('timeoutSeconds')) { $WaitSeconds = [int]$Task.Options['timeoutSeconds'] }
                        $Result = Start-WtWindowsActivation -Method $MethodId -TimeoutSeconds $WaitSeconds -TableSource (Get-WtWindowsActivationMethod)
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Result)
                    }
                    '^slmgr\.request$'
                    {
                        $Result = Request-WtLicensingActivation
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Result)
                    }
                    '^apply\.batch$'
                    {
                        $Items = @()
                        if ($Task.Options.ContainsKey('items')) { $Items = @($Task.Options['items']) }
                        $DryRun = $false
                        if ($Task.Options.ContainsKey('dryRun')) { $DryRun = [bool]$Task.Options['dryRun'] }
                        $RestartAfterApply = $false
                        if ($Task.Options.ContainsKey('restartAfterApply')) { $RestartAfterApply = [bool]$Task.Options['restartAfterApply'] }
                        $Total = $Items.Count
                        $Idx = 0
                        $Results = @()
                        foreach ($Item in $Items)
                        {
                            $Idx++
                            if ($Task.Cancel.Requested)
                            {
                                Add-WtBridgeTaskEvent (New-WtBridgeProgressFrame -Id $Task.Id -Phase 'cancelled' -Text (Get-WtString -Key 'Tui.Busy.CancelActive'))
                                break
                            }
                            $ItemId = [string]$Item.Id
                            $ItemState = [string]$Item.State
                            $ItemArguments = $null
                            if ($Item.psobject.Properties.Name -contains 'Arguments') { $ItemArguments = $Item.Arguments }
                            Add-WtBridgeTaskEvent (New-WtBridgeProgressFrame -Id $Task.Id -Phase 'applying' -Text $ItemId -Item $ItemId -Done $Idx -Total $Total)
                            $Params = @{ Id = $ItemId; State = $ItemState }
                            if ($null -ne $ItemArguments) { $Params['Arguments'] = $ItemArguments }
                            if ($DryRun) { $Params['WhatIf'] = $true }
                            $Result = Invoke-WtTweak @Params
                            $Results += (ConvertTo-WtBridgeApplyResult -Result ([pscustomobject]@{
                                RequestedId = $ItemId
                                RequestedState = $ItemState
                                TweakId = $Result.TweakId
                                Status = $Result.Status
                                Outcome = $Result.Outcome
                                Messages = @($Result.Messages)
                                Journal = $Result.Journal
                                Verification = $Result.Verification
                                Compensation = $Result.Compensation
                            }))
                            if ($Result.Journal -and $Result.Journal.StopBatch) { break }
                        }
                        $Payload = @{ results = $Results; cancelled = [bool]$Task.Cancel.Requested }
                        if ($RestartAfterApply)
                        {
                            $Payload.restart = (Invoke-WtBatchRestart -Results @($Results | ForEach-Object { [pscustomobject]@{ Status = $_.Status; Messages = $_.Messages; Journal = $_.Journal } }) -Requirement 'Unknown' -DryVerdict $true)
                        }
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Payload)
                    }
                    '^rollback$'
                    {
                        $Params = @{ }
                        if ($Task.Options.ContainsKey('id') -and $Task.Options['id']) { $Params['Id'] = [string]$Task.Options['id'] }
                        if ($Task.Options.ContainsKey('historyId') -and $Task.Options['historyId']) { $Params['HistoryId'] = [string]$Task.Options['historyId'] }
                        Add-WtBridgeTaskEvent (New-WtBridgeProgressFrame -Id $Task.Id -Phase 'rollback' -Text '')
                        $Result = Undo-WtTweak @Params
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data (ConvertTo-WtBridgeUndoResult -Result $Result))
                    }
                    '^session\.restore$'
                    {
                        $Params = @{ }
                        if ($Task.Options.ContainsKey('sessionId') -and $Task.Options['sessionId']) { $Params['SessionId'] = [string]$Task.Options['sessionId'] }
                        $Result = Undo-WtSession @Params
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Result)
                    }
                    '^restart\.invoke$'
                    {
                        $Result = Invoke-WtBatchRestart -Requirement 'Unknown' -DryVerdict $false
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Result)
                    }
                    '^restorepoint\.create$'
                    {
                        $Description = 'WindowsTweaker'
                        if ($Task.Options.ContainsKey('description') -and $Task.Options['description']) { $Description = [string]$Task.Options['description'] }
                        $Result = New-WtRestorePoint -Description $Description
                        Add-WtBridgeTaskEvent (New-WtBridgeResultFrame -Id $Task.Id -Data $Result)
                    }
                    default
                    {
                        Add-WtBridgeTaskEvent (New-WtBridgeErrorFrame -Id $Task.Id -Code 'UnknownOperation' -Message "No worker implementation for '$($Task.Name)'.")
                    }
                }
            }
            catch
            {
                Add-WtBridgeTaskEvent (New-WtBridgeErrorFrame -Id $Task.Id -Code 'InternalError' -Message $_.Exception.Message)
            }
            finally
            {
                $Task.State = 'finished'
                Add-WtBridgeTaskEvent ('done')
            }
        } $Task
    })

    [void]$PowerShell.AddParameter('ModulePath', $ModulePath)
    [void]$PowerShell.AddParameter('Task', $Task)

    $Task.Ps = $PowerShell
    $Task.Runspace = $Runspace
    $Task.Handle = $PowerShell.BeginInvoke()

    return $Task
}

<#
.SYNOPSIS
    Requests a cooperative stop of a running task from its safe boundaries. Returns $false
    when no task with that id is running.
#>
function Stop-WtBridgeTask
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$Session,
        [Parameter(Mandatory = $true)][string]$Id
    )

    if (-not $Session.Tasks.ContainsKey($Id)) { return $false }
    $Task = $Session.Tasks[$Id]
    if ($Task.State -ne 'running') { return $false }
    $Task.Cancel.Requested = $true
    return $true
}

<#
.SYNOPSIS
    Drains all pending events of every running task into frames. Handles timeouts: a task
    past its deadline first gets a cooperative cancel and a short grace; if it is still
    running it is aborted and reported. Returns the list of frames to write.
#>
function Receive-WtBridgeTaskFrames
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$Session,
        [Parameter(Mandatory = $false)][int]$GraceMs = 5000
    )

    $Frames = [System.Collections.Generic.List[object]]::new()
    $ToRemove = @()

    foreach ($Id in @($Session.Tasks.Keys))
    {
        $Task = $Session.Tasks[$Id]

        # Timeout handling. `PowerShell.Stop()` would block until a busy pipeline
        # acknowledges the stop, so it is never called here: a task that ignores the
        # cooperative cancel is abandoned and its runspace is disposed (Dispose aborts
        # async work without joining). The process-level exit is the backstop.
        if ($Task.State -eq 'running' -and [datetime]::UtcNow -gt $Task.DeadlineUtc)
        {
            if (-not $Task.Cancel.Requested)
            {
                $Task.Cancel.Requested = $true
                $Task.Expired = $true
                $Task.DeadlineUtc = [datetime]::UtcNow.AddMilliseconds($GraceMs)
            }
            elseif ([datetime]::UtcNow -gt $Task.DeadlineUtc)
            {
                $Task.State = 'finished'
            }
        }

        # Drain the event queue.
        $Frame = $null
        while ($Task.Events.TryDequeue([ref]$Frame))
        {
            if ($Frame -is [string] -and $Frame -eq 'done')
            {
                $Task.State = 'finished'
                continue
            }
            $Frames.Add($Frame)
        }

        # A finished task that never delivered a terminal result/error frame gets one here.
        if ($Task.State -eq 'finished')
        {
            $HasTerminal = $false
            foreach ($F in $Frames)
            {
                if ($F.id -eq $Task.Id -and ($F.type -eq 'result' -or $F.type -eq 'error')) { $HasTerminal = $true; break }
            }
            if (-not $HasTerminal)
            {
                if ($Task.Expired)
                {
                    $Frames.Add((New-WtBridgeErrorFrame -Id $Task.Id -Code 'Timeout' -Message ("The operation exceeded its {0} ms deadline." -f $Task.TimeoutMs)))
                }
                else
                {
                    $Frames.Add((New-WtBridgeErrorFrame -Id $Task.Id -Code 'Aborted' -Message 'The operation ended without a result.'))
                }
            }
            if ($Task.Mutating) { $Session.MutatingRunning = $false }
            # Dispose the job's resources now that the pipeline has ended.
            try { if ($Task.Ps) { $Task.Ps.Dispose() } } catch { $null = $_ }
            try { if ($Task.Runspace) { $Task.Runspace.Dispose() } } catch { $null = $_ }
            $ToRemove += $Id
        }
    }

    foreach ($Id in $ToRemove) { $Session.Tasks.Remove($Id) }

    return @($Frames)
}

<#
.SYNOPSIS
    Cancels every running task and waits (bounded) for the ones that matter, then
    abandons the rest. Mutating tasks are allowed to reach a safe boundary; read-only
    tasks are abandoned as soon as the deadline passes. Never blocks on a busy pipeline:
    a task that does not finish is disposed and reported as Timeout by the drain.
#>
function Stop-WtBridgeAllTasks
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$Session,
        [Parameter(Mandatory = $false)][int]$TimeoutMs = 15000
    )

    foreach ($Id in @($Session.Tasks.Keys))
    {
        $Session.Tasks[$Id].Cancel.Requested = $true
    }

    $Deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([datetime]::UtcNow -lt $Deadline)
    {
        $Remaining = 0
        foreach ($Id in @($Session.Tasks.Keys))
        {
            if ($Session.Tasks[$Id].State -eq 'running') { $Remaining++ }
        }
        if ($Remaining -eq 0) { break }
        Start-Sleep -Milliseconds 100
    }

    foreach ($Id in @($Session.Tasks.Keys))
    {
        $Task = $Session.Tasks[$Id]
        if ($Task.State -eq 'running')
        {
            $Task.State = 'finished'
            if (-not $Task.Expired) { $Task.Expired = $true }
            try { if ($Task.Ps) { $Task.Ps.Dispose() } } catch { $null = $_ }
            try { if ($Task.Runspace) { $Task.Runspace.Dispose() } } catch { $null = $_ }
            if ($Task.Mutating) { $Session.MutatingRunning = $false }
            $Session.Tasks.Remove($Id)
        }
    }
}
