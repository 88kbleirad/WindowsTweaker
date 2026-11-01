# WindowsTweaker - background execution for the external-tool download (TUI).
#
# The download runs in its own runspace for one reason: the interface must keep painting and
# keep accepting keys while a 4 MiB file crosses the network. The rules that come with that
# split:
#
#   * ONE OWNER OF THE TERMINAL. The runspace never paints and never writes to the host: it
#     only mutates two shared tables (progress and cancellation) and enqueues structured
#     events. Every cell of the screen is still written by the interface thread, in
#     Add-WtExternalToolView, from values it reads here.
#   * PRIVATE IMPLEMENTATION, UNCHANGED PUBLIC SURFACE. A runspace can normally call only a
#     module's exported commands, and the external-tool implementation is deliberately not
#     exported. The work is therefore invoked inside the module's own scope (& $Module { }),
#     which is how a background runspace reaches a private function without widening the
#     public API - the same idiom the repository's own benchmark and invariant tools use.
#   * ONE TASK AT A TIME. The task object refuses a second start while one is running, which
#     is what makes a duplicated D/U press harmless instead of a second download.
#   * BOUNDED. The transport enforces its own byte and time limits; this layer adds a deadline
#     of its own so a stalled socket can never hold the view forever, and a cancellation that
#     the reader observes once per chunk. A stop that is not observed in time ends with
#     Stop() on the runspace, after which the staging file is still removed by the download
#     itself (its finally block) or by the caller.
#
# Event shape:
#   @{ Kind = 'result'|'error'|'done'; Result; Message }
#
# Progress shape (read by the painter, never written by it):
#   @{ Phase = 'idle'|'resolving'|'downloading'|'verifying'|'publishing'|'done';
#      Received; Total; Percent; StartedUtc }

<#
.SYNOPSIS
    Creates the runspace, the event queue and the shared progress/cancellation tables.
#>
function New-WtExternalToolTask
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

    return @{
        ModulePath = $Resolved
        Runspace   = $Runspace
        PowerShell = $null
        Queue      = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        Cancel     = [hashtable]::Synchronized(@{ Requested = $false })
        Progress   = [hashtable]::Synchronized(@{
                Phase      = 'idle'
                Received   = [long]0
                Total      = [long]0
                Percent    = -1
                StartedUtc = [datetime]::MinValue
            })
        Handle     = $null
        Mode       = ''
        Result     = $null
        Error      = ''
        DeadlineUtc = [datetime]::MaxValue
        Closed     = $false
    }
}

<#
.SYNOPSIS
    Reports whether a download is running in the task.
#>
function Test-WtExternalToolTaskBusy
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ([Parameter(Mandatory = $true)][object]$Task)

    return ($null -ne $Task.Handle -and -not $Task.Handle.IsCompleted)
}

<#
.SYNOPSIS
    Starts the download in the task runspace.
.DESCRIPTION
    Refuses when a download is already running (the caller turns that into a status message;
    it is never a second transfer). The runspace reports through the shared tables and the
    event queue only - it never touches the screen, the host or the confirmation flow.
.PARAMETER TimeoutSeconds
    Deadline for the whole task. The transport has its own, smaller limits; this one exists so
    a socket that never answers cannot keep the view waiting.
#>
function Start-WtExternalToolTask
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Task,
        [Parameter(Mandatory = $false)][object]$Spec,
        [Parameter(Mandatory = $false)][ValidateSet('resolve', 'download')][string]$Mode = 'download',
        [Parameter(Mandatory = $false)][switch]$Latest,
        [Parameter(Mandatory = $false)][object]$Release,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 90
    )

    if (Test-WtExternalToolTaskBusy -Task $Task)
    {
        return [pscustomobject]@{ Started = $false; Reason = 'AlreadyRunning' }
    }

    if (-not $Spec) { $Spec = Get-WtExternalToolSpec }

    $Task.Result = $null
    $Task.Error = ''
    $Task.Mode = $Mode
    $Task.Cancel.Requested = $false
    $Task.Progress.Phase = 'resolving'
    $Task.Progress.Received = [long]0
    $Task.Progress.Total = [long]$Spec.Bytes
    $Task.Progress.Percent = -1
    $Task.Progress.StartedUtc = [datetime]::UtcNow
    $Task.DeadlineUtc = [datetime]::UtcNow.AddSeconds([math]::Max(10, $TimeoutSeconds))

    $PowerShell = [powershell]::Create()
    $PowerShell.Runspace = $Task.Runspace
    $Task.PowerShell = $PowerShell

    [void]$PowerShell.AddScript({
        param ($ModulePath, $Bundle, $Queue, $Cancel, $Progress, $StatePath, $LogDirectory)

        if ($StatePath) { $env:WT_STATE_PATH = $StatePath }
        if ($LogDirectory) { $env:WT_LOG_DIRECTORY = $LogDirectory }

        # The module is loaded here, in this runspace, and the work runs inside its scope: the
        # download is not part of the public surface, on purpose.
        $Module = Import-Module -Name $ModulePath -Force -PassThru

        # This runspace owns no terminal: the log goes to the file only (no console mirror), the
        # progress stream stays silent, and nothing here may prompt - a prompt in a background
        # runspace would block forever because the interface owns the keyboard.
        $ConfirmPreference = 'None'
        $ProgressPreference = 'SilentlyContinue'
        Initialize-WtLogging -Console $false | Out-Null

        try
        {
            & $Module {
                param ($Bundle)

                try
                {
                    if ($Bundle.Mode -eq 'resolve')
                    {
                        # Reading the newest release is a handful of small documents; it runs here
                        # for the same reason the download does - the view must keep taking keys.
                        $Release = Resolve-WtExternalToolLatest -Spec $Bundle.Spec -Progress $Bundle.Progress -Cancel $Bundle.Cancel
                        $Bundle.Queue.Enqueue(@{ Kind = 'result'; Mode = 'resolve'; Result = $Release })
                    }
                    else
                    {
                        $Parameters = @{
                            Spec     = $Bundle.Spec
                            Progress = $Bundle.Progress
                            Cancel   = $Bundle.Cancel
                        }
                        if ($Bundle.Latest) { $Parameters['Latest'] = $true }
                        if ($Bundle.Release) { $Parameters['Release'] = $Bundle.Release }

                        $Result = Invoke-WtExternalToolDownload @Parameters
                        $Bundle.Queue.Enqueue(@{ Kind = 'result'; Mode = 'download'; Result = $Result })
                    }
                }
                catch
                {
                    $Bundle.Queue.Enqueue(@{ Kind = 'error'; Message = $_.Exception.Message })
                }
            } $Bundle
        }
        finally
        {
            $Progress.Phase = 'idle'
            $Queue.Enqueue(@{ Kind = 'done' })
        }
    })

    [void]$PowerShell.AddParameter('ModulePath', $Task.ModulePath)
    [void]$PowerShell.AddParameter('Bundle', @{
            Mode     = $Mode
            Spec     = $Spec
            Latest   = [bool]$Latest
            Release  = $Release
            Queue    = $Task.Queue
            Cancel   = $Task.Cancel
            Progress = $Task.Progress
        })
    [void]$PowerShell.AddParameter('Queue', $Task.Queue)
    [void]$PowerShell.AddParameter('Cancel', $Task.Cancel)
    [void]$PowerShell.AddParameter('Progress', $Task.Progress)
    [void]$PowerShell.AddParameter('StatePath', (Get-WtStatePath))
    [void]$PowerShell.AddParameter('LogDirectory', (Get-WtLogDirectory))

    $Task.Handle = $PowerShell.BeginInvoke()

    return [pscustomobject]@{ Started = $true; Reason = '' }
}

<#
.SYNOPSIS
    Requests a stop, cooperatively or by aborting the runspace pipeline.
.DESCRIPTION
    Without -Force the reader observes the flag once per chunk and the download unwinds through
    its own failure path (staging file removed, nothing published). With -Force the pipeline is
    aborted, which is the last resort when a stop was requested and the task is still running
    past its deadline.
#>
function Stop-WtExternalToolTask
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Task,
        [Parameter(Mandatory = $false)][switch]$Force
    )

    $Busy = Test-WtExternalToolTaskBusy -Task $Task
    $Task.Cancel.Requested = $true

    if ($Force -and $Busy -and $Task.PowerShell)
    {
        try { $Task.PowerShell.Stop() } catch { Write-WtLog -Level Debug -Message 'The download pipeline was already gone.' -NoConsole }
    }

    return [pscustomobject]@{
        Busy      = $Busy
        Phase     = [string]$Task.Progress.Phase
        Received  = [long]$Task.Progress.Received
        Forced    = [bool]$Force
    }
}

<#
.SYNOPSIS
    Reports whether the task is past its deadline.
#>
function Test-WtExternalToolTaskExpired
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ([Parameter(Mandatory = $true)][object]$Task)

    if (-not (Test-WtExternalToolTaskBusy -Task $Task)) { return $false }
    return ([datetime]::UtcNow -gt $Task.DeadlineUtc)
}

<#
.SYNOPSIS
    Drains the task event queue.
#>
function Receive-WtExternalToolTaskEvent
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param ([Parameter(Mandatory = $true)][object]$Task)

    $Events = [System.Collections.Generic.List[object]]::new()
    $Item = $null

    while ($Task.Queue.TryDequeue([ref]$Item))
    {
        if ($null -eq $Item) { continue }

        switch ([string]$Item.Kind)
        {
            'result' { $Task.Result = $Item.Result }
            'error' { $Task.Error = [string]$Item.Message }
            default { }
        }

        $Events.Add($Item)
    }

    return $Events.ToArray()
}

<#
.SYNOPSIS
    Collects the finished task and releases its pipeline.
.DESCRIPTION
    Returns the download result (or the error the runspace raised), whether the task is still
    running, and whether it stopped because it was cancelled. The handle is cleared so the next
    action can start a new task on the same runspace.
#>
function Complete-WtExternalToolTask
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Task)

    $Outcome = [pscustomobject]@{
        Completed = $false
        Result    = $null
        Error     = ''
        Cancelled = [bool]$Task.Cancel.Requested
    }

    $Handle = $Task.Handle
    if ($null -eq $Handle)
    {
        $Outcome.Result = $Task.Result
        $Outcome.Error = $Task.Error
        $Outcome.Completed = $true
        return $Outcome
    }

    $null = Receive-WtExternalToolTaskEvent -Task $Task
    if (-not $Handle.IsCompleted)
    {
        return $Outcome
    }

    try
    {
        $null = $Task.PowerShell.EndInvoke($Handle)
    }
    catch
    {
        if (-not $Task.Error)
        {
            $Task.Error = $_.Exception.Message
        }
    }

    $null = Receive-WtExternalToolTaskEvent -Task $Task

    try { $Task.PowerShell.Dispose() } catch { Write-WtLog -Level Debug -Message 'The download pipeline was already disposed.' -NoConsole }
    $Task.PowerShell = $null
    $Task.Handle = $null

    $Outcome.Completed = $true
    $Outcome.Result = $Task.Result
    $Outcome.Error = $Task.Error
    $Outcome.Cancelled = [bool]$Task.Cancel.Requested
    return $Outcome
}

<#
.SYNOPSIS
    Disposes the task and its runspace (safe to call twice).
#>
function Close-WtExternalToolTask
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Task)

    if ($Task.Closed)
    {
        return
    }

    if (Test-WtExternalToolTaskBusy -Task $Task)
    {
        $null = Stop-WtExternalToolTask -Task $Task -Force
    }

    if ($Task.PowerShell)
    {
        try { $Task.PowerShell.Dispose() } catch { Write-WtLog -Level Debug -Message 'The download pipeline was already disposed.' -NoConsole }
        $Task.PowerShell = $null
    }

    try { $Task.Runspace.Dispose() } catch { Write-WtLog -Level Debug -Message 'The download runspace was already disposed.' -NoConsole }

    $Task.Handle = $null
    $Task.Closed = $true
}