# WindowsTweaker - optional automatic restart after a completed batch.
#
# The restart is a decision, not a side effect: this file owns
#
#   1. what the selected changes require (a full restart, an application/Explorer restart,
#      nothing, or an unknown requirement - three different answers, never collapsed),
#   2. whether the machine can be restarted at all (platform and mechanism),
#   3. the single robustness rule for the whole feature: a batch may restart automatically
#      only when it finished with changes applied, verified and fully recorded,
#   4. the one OS-facing request, in one function, so an automated test can replace it.
#
# The countdown itself lives in the user interface (see Private/Tui/Workflows.ps1): it runs
# inside the application and the OS is asked exactly once, when it expires - a crash of the
# interface therefore cannot leave an unexpected restart pending behind it. Nothing here
# escalates, forces applications to close, or uses a forced-restart flag.

$Script:WtRestartOwner = $null

<#
.SYNOPSIS
    Classifies what a selection of tweaks requires.
.DESCRIPTION
    Returns one of:
      Reboot      - at least one selected change requires a full restart
      Application - no full restart, but Explorer or a sign-out is required
      None        - every selected change declares "no restart"
      Unknown     - at least one selected change does not declare a requirement, so no
                    answer can be given for the selection (never treated as None)
    Precedence is Reboot, then Unknown, then Application, then None: the strongest
    requirement wins, and "cannot tell" outranks "no restart needed".
.OUTPUTS
    [string] Reboot, Application, Unknown or None.
#>
function Get-WtRestartRequirementInternal
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$Entries = @())

    $Requirement = 'None'
    $Unknown = $false

    foreach ($Entry in $Entries)
    {
        if ($null -eq $Entry) { continue }

        $Value = ''
        if ($Entry -is [System.Collections.IDictionary])
        {
            if ($Entry.Contains('Restart')) { $Value = [string]$Entry['Restart'] }
        }
        elseif (@($Entry.PSObject.Properties.Name) -contains 'Restart')
        {
            $Value = [string]$Entry.Restart
        }
        else
        {
            $Value = [string]$Entry
        }

        switch ($Value)
        {
            'Reboot' { return 'Reboot' }
            'SignOut' { if ($Requirement -ne 'Reboot') { $Requirement = 'Application' } }
            'Explorer' { if ($Requirement -ne 'Reboot') { $Requirement = 'Application' } }
            'None' { }
            default { $Unknown = $true }
        }
    }

    if ($Unknown) { return 'Unknown' }
    return $Requirement
}

<#
.SYNOPSIS
    Reports whether this machine can be restarted by this process, and how.
.DESCRIPTION
    Windows only. The mechanism is `shutdown.exe` when it is present (the documented,
    non-interactive command-line contract), otherwise the `Restart-Computer` cmdlet. A
    platform without either is reported as unavailable with the reason - the caller keeps
    the completed results and offers the manual command instead of escalating.
.OUTPUTS
    A hashtable with Available, Mechanism and Reason.
#>
function Test-WtRestartAvailable
{
    [CmdletBinding()]
    param ()

    $Runtime = Get-WtRuntimeProfile

    if (-not $Runtime.IsWindows)
    {
        return @{ Available = $false; Mechanism = ''; Reason = 'platform' }
    }

    $Shutdown = Get-Command -Name 'shutdown.exe' -ErrorAction Ignore
    if ($Shutdown)
    {
        return @{ Available = $true; Mechanism = 'shutdown.exe'; Reason = '' }
    }

    $Cmdlet = Get-Command -Name 'Restart-Computer' -ErrorAction Ignore
    if ($Cmdlet)
    {
        return @{ Available = $true; Mechanism = 'Restart-Computer'; Reason = '' }
    }

    return @{ Available = $false; Mechanism = ''; Reason = 'no-mechanism' }
}

<#
.SYNOPSIS
    Requests one restart of this machine, without forcing anything.
.DESCRIPTION
    The single OS-facing call of the feature, so an automated test can replace it and no
    test can ever reboot the machine it runs on. Nothing is forced: no /f, no forced flags
    and no forced application close, so a program with unsaved work can still delay or
    prevent the restart, which is what the interface tells the user.
.PARAMETER DelaySeconds
    Seconds the operating system itself waits. The interface keeps its own countdown and
    asks with 0, so the request never outlives the application that made it.
.PARAMETER Comment
    Reason text recorded in the event log by the operating system.
.OUTPUTS
    A hashtable with Requested, Mechanism, Message and RequestedUtc.
#>
function Invoke-WtRestartRequest
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][int]$DelaySeconds = 0,
        [Parameter(Mandatory = $false)][string]$Comment = 'WindowsTweaker: restarting after applied changes'
    )

    $Stamp = (Get-Date).ToUniversalTime().ToString('o')
    $Availability = Test-WtRestartAvailable

    if (-not $Availability.Available)
    {
        return @{ Requested = $false; Mechanism = ''; Message = "restart is unavailable ($($Availability.Reason))"; RequestedUtc = $Stamp }
    }

    try
    {
        if ($Availability.Mechanism -eq 'shutdown.exe')
        {
            $Arguments = @('/r', '/t', [string][math]::Max(0, $DelaySeconds))
            if ($Comment) { $Arguments += @('/c', $Comment) }

            $Process = Start-Process -FilePath 'shutdown.exe' -ArgumentList $Arguments -NoNewWindow -Wait -PassThru
            if ($Process.ExitCode -ne 0)
            {
                # The OS reports the reason; the two codes worth naming are the ones a user
                # actually hits: a denied request and a shutdown that is already in progress.
                $Message = switch ($Process.ExitCode)
                {
                    5 { 'access denied (the account may not be allowed to restart this machine)' }
                    1190 { 'a restart is already pending' }
                    default { "shutdown.exe exited with code $($Process.ExitCode)" }
                }

                return @{ Requested = $false; Mechanism = 'shutdown.exe'; Message = $Message; RequestedUtc = $Stamp }
            }

            return @{ Requested = $true; Mechanism = 'shutdown.exe'; Message = 'restart requested'; RequestedUtc = $Stamp }
        }

        if ($DelaySeconds -gt 0)
        {
            Restart-Computer -ComputerName 'localhost' -Delay $DelaySeconds -ErrorAction Stop
        }
        else
        {
            Restart-Computer -ComputerName 'localhost' -ErrorAction Stop
        }

        return @{ Requested = $true; Mechanism = 'Restart-Computer'; Message = 'restart requested'; RequestedUtc = $Stamp }
    }
    catch
    {
        return @{ Requested = $false; Mechanism = $Availability.Mechanism; Message = $_.Exception.Message; RequestedUtc = $Stamp }
    }
}

<#
.SYNOPSIS
    Decides whether a finished batch may restart the machine automatically.
.DESCRIPTION
    Every rule is a reason to refuse, and refusal is the default:
      NotRequested   the user did not enable it for this batch
      Unavailable    the platform cannot restart (reported separately from a failure)
      Active         an operation or recovery task is still running
      NoChange       nothing was applied (an all-unchanged batch never restarts)
      Outcome        a result was failed, partial, cancelled, skipped, unsupported or a
                     worker-level exception occurred
      Verification   read-back verification did not satisfy the provider policy
      Compensation   compensating restoration ran (the change was undone)
      Journal        a journal stage or the session record could not be persisted, or the
                     journal reports an uncertain stage
    Unchanged entries may coexist with successful changes; only their presence is not
    enough. The function is pure: it takes what the caller observed and returns a verdict
    plus reason codes, so the wording (EN/VI) stays in the caller.
.OUTPUTS
    A hashtable with Eligible, Applied, Unchanged, Failed, and Reasons (codes).
#>
function Get-WtRestartEligibilityInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][bool]$Requested = $false,
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$Results = @(),
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$Failures = @(),
        [Parameter(Mandatory = $false)][int]$Skipped = 0,
        [Parameter(Mandatory = $false)][int]$Cancelled = 0,
        [Parameter(Mandatory = $false)][bool]$OperationActive = $false,
        [Parameter(Mandatory = $false)][bool]$PlatformAvailable = $true
    )

    $Reasons = [System.Collections.Generic.List[string]]::new()

    $Applied = 0
    $Unchanged = 0
    $Failed = 0

    foreach ($Result in @($Results))
    {
        if ($null -eq $Result) { continue }
        $Status = [string]$Result.Status

        switch ($Status)
        {
            'succeeded' { $Applied++ }
            'unchanged' { $Unchanged++ }
            default { $Failed++ }
        }

        if ($Status -notin 'succeeded', 'unchanged')
        {
            if ($Reasons -notcontains 'Outcome') { $Reasons.Add('Outcome') }
        }

        if (@($Result.PSObject.Properties.Name) -contains 'Verification' -and $Result.Verification -and [int]$Result.Verification.Mismatched -gt 0)
        {
            if ($Reasons -notcontains 'Verification') { $Reasons.Add('Verification') }
        }

        if (@($Result.PSObject.Properties.Name) -contains 'Compensation' -and $Result.Compensation -and [bool]$Result.Compensation.Attempted)
        {
            if ($Reasons -notcontains 'Compensation') { $Reasons.Add('Compensation') }
        }

        if (@($Result.PSObject.Properties.Name) -contains 'Journal' -and $Result.Journal)
        {
            if ([bool]$Result.Journal.StopBatch -or [string]$Result.Journal.UncertainStage)
            {
                if ($Reasons -notcontains 'Journal') { $Reasons.Add('Journal') }
            }
        }
    }

    if (@($Failures).Count -gt 0 -and $Reasons -notcontains 'Outcome') { $Reasons.Add('Outcome') }
    if ($Cancelled -gt 0 -and $Reasons -notcontains 'Outcome') { $Reasons.Add('Outcome') }
    if ($Skipped -gt 0 -and $Reasons -notcontains 'Outcome') { $Reasons.Add('Outcome') }
    if ($OperationActive -and $Reasons -notcontains 'Active') { $Reasons.Add('Active') }
    if (-not $PlatformAvailable -and $Reasons -notcontains 'Unavailable') { $Reasons.Add('Unavailable') }
    if ($Applied -eq 0 -and $Reasons.Count -eq 0) { $Reasons.Add('NoChange') }

    return @{
        Requested = [bool]$Requested
        Eligible  = [bool]($Requested -and $Reasons.Count -eq 0)
        Applied   = [int]$Applied
        Unchanged = [int]$Unchanged
        Failed    = [int]$Failed
        Reasons   = @($Reasons.ToArray())
    }
}

<#
.SYNOPSIS
    Turns eligibility reason codes into localized lines.
#>
function Get-WtRestartBlockedLinesInternal
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ([Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$Reasons = @())

    $Lines = [System.Collections.Generic.List[string]]::new()

    foreach ($Reason in @($Reasons))
    {
        switch ($Reason)
        {
            'Outcome' { $Lines.Add((Get-WtString -Key 'Tui.Restart.Blocked.Outcome')) }
            'Verification' { $Lines.Add((Get-WtString -Key 'Tui.Restart.Blocked.Verification')) }
            'Compensation' { $Lines.Add((Get-WtString -Key 'Tui.Restart.Blocked.Compensation')) }
            'Journal' { $Lines.Add((Get-WtString -Key 'Tui.Restart.Blocked.Journal')) }
            'Active' { $Lines.Add((Get-WtString -Key 'Tui.Restart.Blocked.Active')) }
            'Unavailable' { $Lines.Add((Get-WtString -Key 'Tui.Restart.Unavailable' -Arguments @((Get-WtString -Key 'Restart.None')))) }
            'NoChange' { $Lines.Add((Get-WtString -Key 'Tui.Restart.Blocked.NoChange')) }
            'Busy' { $Lines.Add((Get-WtString -Key 'Tui.Restart.Blocked.Active')) }
            default { $Lines.Add((Get-WtString -Key 'Tui.Restart.Blocked.Outcome')) }
        }
    }

    return $Lines.ToArray()
}

<#
.SYNOPSIS
    Returns the localized label for a restart requirement class.
.DESCRIPTION
    Each class keeps its own wording: a full restart, an application/Explorer restart and an
    unknown requirement are three different statements and are never rendered as one.
#>
function Get-WtRestartRequirementLabelInternal
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][string]$Requirement = 'None')

    switch ($Requirement)
    {
        'Reboot' { return (Get-WtString -Key 'Tui.Restart.Requirement.Reboot') }
        'Application' { return (Get-WtString -Key 'Tui.Restart.Requirement.Application') }
        'Unknown' { return (Get-WtString -Key 'Tui.Restart.Requirement.Unknown') }
        default { return (Get-WtString -Key 'Tui.Restart.Requirement.None') }
    }
}

<#
.SYNOPSIS
    Takes ownership of the single restart that may be pending at a time.
.DESCRIPTION
    Duplicate scheduling is impossible: the first caller owns the countdown until it
    releases it, and every later caller is refused rather than given a second one. The
    token is compared on release, so one owner can never clear another's claim.
.OUTPUTS
    [bool] $true when the caller now owns the restart.
#>
function Enter-WtRestartOwnership
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ([Parameter(Mandatory = $true)][string]$Owner)

    if ($Script:WtRestartOwner) { return $false }
    $Script:WtRestartOwner = $Owner
    return $true
}

<#
.SYNOPSIS
    Releases the restart ownership held by one owner.
#>
function Exit-WtRestartOwnership
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Owner)

    if ($Script:WtRestartOwner -eq $Owner) { $Script:WtRestartOwner = $null }
}

<#
.SYNOPSIS
    Reports whether a countdown is currently owned by someone.
#>
function Test-WtRestartPending
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    return [bool]$Script:WtRestartOwner
}

<#
.SYNOPSIS
    Decides whether a command-line restart request may proceed.
.DESCRIPTION
    Refused, with a reason code, when the invocation cannot produce the state a restart
    would be for:
      preview     -WhatIf/dry run writes nothing
      readonly    the selected switch only reads state
      unsupported the platform cannot restart
    A refusal is a usage error, never a silent downgrade.
.OUTPUTS
    A hashtable with Allowed and Reason ('' when allowed).
#>
function Test-WtRestartCliRequestInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][bool]$Requested = $false,
        [Parameter(Mandatory = $false)][bool]$Preview = $false,
        [Parameter(Mandatory = $false)][bool]$ReadOnly = $false,
        [Parameter(Mandatory = $false)][bool]$PlatformAvailable = $true
    )

    if (-not $Requested) { return @{ Allowed = $false; Reason = '' } }
    if ($Preview) { return @{ Allowed = $false; Reason = 'preview' } }
    if ($ReadOnly) { return @{ Allowed = $false; Reason = 'readonly' } }
    if (-not $PlatformAvailable) { return @{ Allowed = $false; Reason = 'unsupported' } }

    return @{ Allowed = $true; Reason = '' }
}

<#
.SYNOPSIS
    Runs the command-line restart countdown and returns what happened.
.DESCRIPTION
    The command-line counterpart of the interface countdown: it counts inside the process
    (the operating system is asked only when the countdown ends), shows the planned restart
    time, and cancels on Escape. Q cancels and asks the caller to stop.
    Input and output are injectable so a test can drive the whole countdown without a
    console and without ever reaching the restart request.
.PARAMETER ReadKey
    Returns a normalized key name ('Escape', 'Char', ...) or $null when nothing is pending.
    Defaults to the real console through Read-WtConsoleKey.
.PARAMETER Clock
    Returns the current UTC time (injectable so a test does not have to wait a minute).
.OUTPUTS
    A hashtable with Outcome (Expired, Cancelled, Quit, Unavailable) and Remaining.
#>
function Invoke-WtConsoleRestartCountdownInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][int]$Seconds = 60,
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$Lines = @(),
        [Parameter(Mandatory = $false)][scriptblock]$ReadKey,
        [Parameter(Mandatory = $false)][scriptblock]$Write,
        [Parameter(Mandatory = $false)][scriptblock]$Clock,
        [Parameter(Mandatory = $false)][scriptblock]$Sleep
    )

    if (-not $ReadKey) { $ReadKey = { $Key = Read-WtConsoleKey -TimeoutMs 200; if ($Key) { $Key.Name } else { $null } } }
    if (-not $Write) { $Write = { param ($Text) Write-Host $Text } }
    if (-not $Clock) { $Clock = { [datetime]::UtcNow } }
    if (-not $Sleep) { $Sleep = { param ($Ms) Start-Sleep -Milliseconds $Ms } }

    $Deadline = (& $Clock).AddSeconds([math]::Max(0, $Seconds))
    $Shown = -1

    foreach ($Line in @($Lines))
    {
        & $Write $Line
    }

    while ($true)
    {
        $Remaining = [int][math]::Ceiling(($Deadline - (& $Clock)).TotalSeconds)
        if ($Remaining -lt 0) { $Remaining = 0 }

        if ($Remaining -ne $Shown)
        {
            $Shown = $Remaining
            & $Write (Get-WtString -Key 'Cli.Restart.Countdown' -Arguments @($Remaining))
        }

        if ($Remaining -le 0)
        {
            return @{ Outcome = 'Expired'; Remaining = 0 }
        }

        $Key = & $ReadKey
        switch ([string]$Key)
        {
            'Escape' { return @{ Outcome = 'Cancelled'; Remaining = $Remaining } }
            'Control' { return @{ Outcome = 'Cancelled'; Remaining = $Remaining } }
            'Char' { return @{ Outcome = 'Cancelled'; Remaining = $Remaining } }
            'Quit' { return @{ Outcome = 'Quit'; Remaining = $Remaining } }
            default { & $Sleep 100 }
        }
    }
}

<#
.SYNOPSIS
    Records one restart decision in the structured log.
.DESCRIPTION
    Uses the existing logging contract, so a restart preference, a cancellation, the request
    and a request failure all end up in the same place as every other operation record.
    Operation is 'Restart' so a support bundle or a log filter can isolate the whole story.
#>
function Write-WtRestartRecord
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][ValidateSet('preference', 'cancelled', 'scheduled', 'requested', 'failed', 'unavailable', 'blocked')][string]$Event,
        [Parameter(Mandatory = $false)][string]$Message = '',
        [Parameter(Mandatory = $false)][string]$OperationId = '',
        [Parameter(Mandatory = $false)][string]$SessionId = ''
    )

    $Text = "Restart $Event"
    if ($Message) { $Text = "$Text`: $Message" }
    if ($SessionId) { $Text = "$Text [session $SessionId]" }

    # The structured log has one vocabulary for operation statuses; the restart event keeps
    # its own name in the message so the whole restart story stays filterable by 'Restart'.
    $Status = switch ($Event)
    {
        'preference' { 'pending' }
        'scheduled' { 'pending' }
        'cancelled' { 'skipped' }
        'requested' { 'succeeded' }
        'failed' { 'failed' }
        'unavailable' { 'unsupported' }
        default { 'skipped' }
    }

    $Level = if ($Event -eq 'failed') { 'Error' } elseif ($Event -in 'cancelled', 'unavailable', 'blocked') { 'Warning' } else { 'Information' }

    Write-WtLog -Level $Level -Message $Text -Operation 'Restart' -Status $Status -NoConsole
}

<#
.SYNOPSIS
    Appends a restart note to an operation entry in the store.
.DESCRIPTION
    The durable half of the record: an operator reading the journal afterwards can see that
    the batch asked for a restart, that it was cancelled, or that the request failed. Best
    effort by design - a store that cannot be written must never turn a successful batch into
    a failure, so the reason is logged and the caller keeps its result.
.OUTPUTS
    [bool] $true when the note was persisted.
#>
function Add-WtOperationNoteInternal
{
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory = $false)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $OperationId -or -not $Message) { return $false }

    try
    {
        $Store = Read-WtStateStore
        if ($Store.Corrupt) { return $false }

        $Found = $false
        $Journal = @()
        foreach ($Entry in @($Store.History))
        {
            if ($Entry.operationId -eq $OperationId)
            {
                $Entry.messages = @($Entry.messages) + @($Message)
                $Entry.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
                $Found = $true
            }
            $Journal += $Entry
        }

        if (-not $Found) { return $false }

        $Store.History = $Journal
        Write-WtStateStore -Store $Store
        return $true
    }
    catch
    {
        Write-WtLog -Level Warning -Message "The restart note could not be recorded: $($_.Exception.Message)" -Operation 'Restart' -Status 'failed' -NoConsole
        return $false
    }
}
