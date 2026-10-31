# WindowsTweaker - TUI background worker.
#
# Every long operation (applying a pending selection, rolling a recorded change back)
# runs in its own runspace so the interface keeps rendering and keeps accepting keys.
# The worker is the only place that mutates system state, it runs one task at a time
# (conflicting changes cannot interleave), and it reports structured events instead of
# formatted text:
#
#   @{ Kind = 'start'|'result'|'error'|'cancelled'|'done'; Id; Index; Total; Result; Message }
#
# Progress is only ever reported as item counts the worker has actually reached - no
# percentage is invented, and an operation whose native progress cannot be observed
# (DISM, Remove-AppxPackage) is reported as running until it returns.
#
# Cancellation is cooperative: the flag is checked between items, so queued work is
# dropped and the item that is already running finishes its safe boundary. A native
# operation that is in flight cannot be interrupted, and the interface says so.

<#
.SYNOPSIS
    Creates the runspace, event queue and cancellation state used by the TUI.
.PARAMETER ModulePath
    Module manifest to import inside the worker runspace.
#>
function New-WtWorker
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][string]$ModulePath)

    $Module = Get-Module -Name WindowsTweaker
    $Resolved = if ($ModulePath)
    {
        $ModulePath
    }
    elseif ($Module -and $Module.Path)
    {
        $Module.Path
    }
    else
    {
        Join-Path $Script:WtModuleRoot 'WindowsTweaker.psd1'
    }

    $Runspace = [runspacefactory]::CreateRunspace()
    $Runspace.ApartmentState = 'MTA'
    $Runspace.ThreadOptions = 'ReuseThread'
    $Runspace.Open()

    $PowerShell = [powershell]::Create()
    $PowerShell.Runspace = $Runspace

    return @{
        ModulePath = $Resolved
        Runspace   = $Runspace
        PowerShell = $PowerShell
        Queue      = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        Cancel     = [hashtable]::Synchronized(@{ Requested = $false; Active = $null })
        Handle     = $null
        Kind       = $null
        Total      = 0
        Started    = 0
        Finished   = 0
        Results    = [System.Collections.Generic.List[object]]::new()
        Failures   = [System.Collections.Generic.List[object]]::new()
        Closed     = $false
    }
}

<#
.SYNOPSIS
    Closes the worker runspace (safe to call twice).
#>
function Close-WtWorker
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Worker)

    if ($Worker.Closed)
    {
        return
    }

    try
    {
        $Worker.PowerShell.Dispose()
    }
    catch
    {
        Write-WtLog -Level Debug -Message 'Worker PowerShell instance was already disposed.' -NoConsole
    }

    try
    {
        $Worker.Runspace.Dispose()
    }
    catch
    {
        Write-WtLog -Level Debug -Message 'Worker runspace was already disposed.' -NoConsole
    }

    $Worker.Closed = $true
}

<#
.SYNOPSIS
    Reports whether a task is currently running in the worker.
#>
function Test-WtWorkerBusy
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ([Parameter(Mandatory = $true)][object]$Worker)

    return ($null -ne $Worker.Handle -and -not $Worker.Handle.IsCompleted)
}

<#
.SYNOPSIS
    Starts a batch of tweak applications or rollbacks in the worker runspace.
.DESCRIPTION
    `Items` carries the exact reviewed selection:
      apply    - @{ Id; Target; Arguments; Label }
      rollback - @{ HistoryId; Label }
    The worker itself never chooses what to change.
#>
function Start-WtWorkerTask
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Worker,
        [Parameter(Mandatory = $true)][ValidateSet('apply', 'rollback')][string]$Kind,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory = $false)][bool]$DryRun = $false
    )

    if (Test-WtWorkerBusy -Worker $Worker)
    {
        throw 'A worker task is already running.'
    }

    $Worker.Kind = $Kind
    $Worker.Total = @($Items).Count
    $Worker.Started = 0
    $Worker.Finished = 0
    $Worker.Results.Clear()
    $Worker.Failures.Clear()
    $Worker.Cancel.Requested = $false
    $Worker.Cancel.Active = $null

    $PowerShell = $Worker.PowerShell
    [void]$PowerShell.AddScript({
        param ($ModulePath, $Kind, $Items, $DryRun, $Queue, $Cancel, $StatePath, $LogDirectory)

        if ($StatePath) { $env:WT_STATE_PATH = $StatePath }
        if ($LogDirectory) { $env:WT_LOG_DIRECTORY = $LogDirectory }

        Import-Module -Name $ModulePath -Force
        Initialize-WtLogging -Console $false | Out-Null

        # The interface owns the confirmation flow: the exact selection was reviewed in
        # a dialog before the worker was started, so no provider may prompt here (a
        # prompt in a background runspace would block forever).
        $ConfirmPreference = 'None'
        $ProgressPreference = 'SilentlyContinue'

        $Index = 0
        $Total = @($Items).Count

        foreach ($Item in $Items)
        {
            if ($Cancel.Requested)
            {
                $Queue.Enqueue(@{ Kind = 'cancelled'; Id = $Item.Id; HistoryId = $Item.HistoryId; Index = $Index; Total = $Total })
                continue
            }

            $Index++
            $Cancel.Active = if ($Kind -eq 'rollback') { $Item.HistoryId } else { $Item.Id }
            $Queue.Enqueue(@{ Kind = 'start'; Id = $Item.Id; HistoryId = $Item.HistoryId; Label = $Item.Label; Index = $Index; Total = $Total })

            try
            {
                if ($Kind -eq 'rollback')
                {
                    $Parameters = @{ HistoryId = $Item.HistoryId }
                    if ($Item.Force) { $Parameters.Force = $true }
                }
                else
                {
                    $Parameters = @{ Id = $Item.Id; State = $Item.Target }
                    if ($Item.Arguments) { $Parameters.Arguments = $Item.Arguments }

                    # The fingerprint of the review the user confirmed, plus where the action came
                    # from: the engine revalidates the first and records the second.
                    if ($Item.Fingerprint) { $Parameters.ReviewedFingerprint = $Item.Fingerprint }
                    if ($Item.Origin) { $Parameters.Origin = $Item.Origin }
                }

                if ($DryRun) { $Parameters.WhatIf = $true }

                $Result = if ($Kind -eq 'rollback') { Undo-WtTweak @Parameters } else { Invoke-WtTweak @Parameters }
                $Queue.Enqueue(@{ Kind = 'result'; Id = $Item.Id; HistoryId = $Item.HistoryId; Label = $Item.Label; Index = $Index; Total = $Total; Result = $Result })
            }
            catch
            {
                $Queue.Enqueue(@{ Kind = 'error'; Id = $Item.Id; HistoryId = $Item.HistoryId; Label = $Item.Label; Index = $Index; Total = $Total; Message = $_.Exception.Message })
            }

            $Cancel.Active = $null
        }

        $Queue.Enqueue(@{ Kind = 'done'; Index = $Index; Total = $Total })
    })

    [void]$PowerShell.AddParameter('ModulePath', $Worker.ModulePath)
    [void]$PowerShell.AddParameter('Kind', $Kind)
    [void]$PowerShell.AddParameter('Items', @($Items))
    [void]$PowerShell.AddParameter('DryRun', [bool]$DryRun)
    [void]$PowerShell.AddParameter('Queue', $Worker.Queue)
    [void]$PowerShell.AddParameter('Cancel', $Worker.Cancel)
    [void]$PowerShell.AddParameter('StatePath', (Get-WtStatePath))
    [void]$PowerShell.AddParameter('LogDirectory', (Get-WtLogDirectory))

    $Worker.Handle = $PowerShell.BeginInvoke()
    return $Worker.Handle
}

<#
.SYNOPSIS
    Requests cooperative cancellation.
.DESCRIPTION
    Queued items are dropped; the item that is already running is allowed to reach its
    safe boundary. The caller is told which item that is so it can explain the wait.
#>
function Stop-WtWorkerTask
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Worker)

    if (-not (Test-WtWorkerBusy -Worker $Worker))
    {
        return $null
    }

    $Worker.Cancel.Requested = $true

    return [pscustomobject]@{
        Active     = $Worker.Cancel.Active
        Started    = $Worker.Started
        Total      = $Worker.Total
        Interruptible = $false
    }
}

<#
.SYNOPSIS
    Drains the worker event queue into structured objects.
.DESCRIPTION
    Also maintains the worker's own counters so the interface can render progress
    without re-deriving it from formatted text.
#>
function Receive-WtWorkerEvent
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param ([Parameter(Mandatory = $true)][object]$Worker)

    $Events = [System.Collections.Generic.List[object]]::new()
    $Item = $null

    while ($Worker.Queue.TryDequeue([ref]$Item))
    {
        if ($null -eq $Item)
        {
            continue
        }

        switch ($Item.Kind)
        {
            'start' { $Worker.Started = [int]$Item.Index }
            'result'
            {
                $Worker.Finished = [int]$Item.Index
                $Worker.Results.Add($Item)
            }
            'error'
            {
                $Worker.Finished = [int]$Item.Index
                $Worker.Failures.Add($Item)
            }
            'cancelled' { $Worker.Finished = [int]$Item.Index }
            default { Write-WtLog -Level Debug -Message "Worker event: $($Item.Kind)" -NoConsole }
        }

        $Events.Add($Item)
    }

    return $Events.ToArray()
}

<#
.SYNOPSIS
    Waits for the running task to finish and returns everything it produced.
.DESCRIPTION
    Exceptions raised outside the per-item guard (for example a module that fails to
    import in the worker) are surfaced as a failure entry instead of being swallowed.
#>
function Complete-WtWorkerTask
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Worker,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 0
    )

    $Handle = $Worker.Handle
    if ($null -eq $Handle)
    {
        return [pscustomobject]@{ Events = @(); Results = @(); Failures = @(); TimedOut = $false }
    }

    $TimedOut = $false
    if ($TimeoutSeconds -gt 0)
    {
        $Waited = $Handle.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        $TimedOut = -not $Waited
    }

    $Events = @(Receive-WtWorkerEvent -Worker $Worker)

    if (-not $Handle.IsCompleted)
    {
        return [pscustomobject]@{ Events = $Events; Results = @($Worker.Results); Failures = @($Worker.Failures); TimedOut = $true }
    }

    try
    {
        $null = $Worker.PowerShell.EndInvoke($Handle)
    }
    catch
    {
        $Worker.Failures.Add(@{
            Kind    = 'error'
            Id      = $null
            Index   = 0
            Total   = $Worker.Total
            Message = $_.Exception.Message
        })
    }

    $Events += @(Receive-WtWorkerEvent -Worker $Worker)

    $Outcome = [pscustomobject]@{
        Events   = $Events
        Results  = @($Worker.Results)
        Failures = @($Worker.Failures)
        TimedOut = $TimedOut
    }

    $Worker.Handle = $null
    return $Outcome
}
