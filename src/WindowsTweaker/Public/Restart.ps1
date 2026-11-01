# WindowsTweaker - public restart surface.
#
# Two functions, because a scripted caller needs exactly two answers:
#
#   Test-WtRestartRequest - may this invocation restart the machine at all, and if not, why?
#   Invoke-WtBatchRestart - restart after a finished batch, under the documented rules.
#
# Both are thin wrappers over Private/Restart.ps1, which owns the classification, the
# eligibility rules, the ownership of a single pending restart and the one OS-facing
# request. The terminal interface uses the same private pieces, so the rules cannot drift
# between the command line and the interface.
#
# Nothing here ever forces applications to close, escalates the process, or remembers the
# choice: a restart is authorised per invocation and spent by the invocation that used it.

<#
.SYNOPSIS
    Reports whether an invocation may restart the machine, and why not when it may not.
.DESCRIPTION
    A restart is refused when the invocation cannot produce the state a restart would be
    for (a dry run writes nothing), when it does not apply changes at all (the read-only
    switches), or when the platform cannot restart. The refusal is a usage error for the
    caller to report, never a silent downgrade to "no restart".
.PARAMETER Requested
    The caller asked for a restart.
.PARAMETER Preview
    The invocation is a -WhatIf/dry run.
.PARAMETER ReadOnly
    The invocation only reads state.
.OUTPUTS
    A hashtable with Allowed, Reason (preview, readonly, unsupported or ''), Available and
    Mechanism from the platform probe.
.EXAMPLE
    $Decision = Test-WtRestartRequest -Requested $true -Preview $false -ReadOnly $false
    if (-not $Decision.Allowed) { throw $Decision.Reason }
#>
function Test-WtRestartRequest
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $false)][switch]$Requested,
        [Parameter(Mandatory = $false)][switch]$Preview,
        [Parameter(Mandatory = $false)][switch]$ReadOnly
    )

    $Availability = Test-WtRestartAvailable
    $Decision = Test-WtRestartCliRequestInternal -Requested ([bool]$Requested) -Preview ([bool]$Preview) `
        -ReadOnly ([bool]$ReadOnly) -PlatformAvailable ([bool]$Availability.Available)

    return @{
        Allowed   = [bool]$Decision.Allowed
        Reason    = [string]$Decision.Reason
        Available = [bool]$Availability.Available
        Mechanism = [string]$Availability.Mechanism
    }
}

<#
.SYNOPSIS
    Restarts the machine after a finished batch, under the documented rules.
.DESCRIPTION
    Eligible only when the caller explicitly asked for it, at least one change was applied,
    every result succeeded or was already in place, verification and compensation are
    clean, the journal recorded every stage, and nothing else is running. A batch of
    unchanged entries, a failed or cancelled batch, an uncertain journal and an
    interrupted operation all refuse.

    The countdown runs inside this process, so the operating system is asked exactly once,
    when it expires: a crash of the caller cannot leave an unexpected restart pending. The
    interface countdown is painted by the caller; this one prints lines.

    A refusal or a failure never changes what the batch did - the apply outcome and the
    restart outcome stay separate.
.PARAMETER Results
    The Invoke-WtTweak results of the batch.
.PARAMETER Failures
    Worker-level exceptions the batch reported (objects with a Message property).
.PARAMETER Skipped
    Items that were never attempted after a batch stop.
.PARAMETER Cancelled
    Items the user cancelled.
.PARAMETER Requirement
    Restart requirement of the selection (Reboot, Application, Unknown or None); it only
    affects the wording of the countdown.
.PARAMETER CountdownSeconds
    Seconds to wait before requesting the restart (default 60). 0 requests immediately.
.PARAMETER Countdown
    Optional countdown implementation. The command line prints lines (the default); the
    terminal interface passes a scriptblock that paints its own countdown inside the cell
    grid. It receives the applied count and the unchanged count and returns a hashtable with
    an Outcome of Expired, Cancelled or Quit.
.PARAMETER DryVerdict
    Decide only: report whether a restart would happen without scheduling a countdown or
    asking the operating system.
.OUTPUTS
    A hashtable with Outcome (requested, cancelled, eligible, blocked or failed), Applied,
    Unchanged, Reasons (codes), Lines (the localized wording for those reasons) and Message.
.EXAMPLE
    Invoke-WtBatchRestart -Results $Results -Requirement 'Reboot'
#>
function Invoke-WtBatchRestart
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$Results = @(),
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$Failures = @(),
        [Parameter(Mandatory = $false)][int]$Skipped = 0,
        [Parameter(Mandatory = $false)][int]$Cancelled = 0,
        [Parameter(Mandatory = $false)][string]$Requirement = '',
        [Parameter(Mandatory = $false)][int]$CountdownSeconds = 60,
        [Parameter(Mandatory = $false)][scriptblock]$Countdown,
        [Parameter(Mandatory = $false)][switch]$DryVerdict
    )

    $Availability = Test-WtRestartAvailable
    $Eligibility = Get-WtRestartEligibilityInternal -Requested $true -Results $Results -Failures $Failures `
        -Skipped $Skipped -Cancelled $Cancelled -OperationActive $false -PlatformAvailable ([bool]$Availability.Available)

    $OperationId = ''
    foreach ($Result in @($Results))
    {
        if ($null -eq $Result) { continue }
        if (@($Result.PSObject.Properties.Name) -contains 'OperationId' -and $Result.OperationId) { $OperationId = [string]$Result.OperationId; break }
    }

    if (-not $Eligibility.Eligible)
    {
        Write-WtRestartRecord -Event $(if ($Eligibility.Reasons -contains 'Unavailable') { 'unavailable' } else { 'blocked' }) `
            -Message (@($Eligibility.Reasons) -join ',') -OperationId $OperationId
        $null = Add-WtOperationNoteInternal -OperationId $OperationId -Message "restart requested but not performed: $(@($Eligibility.Reasons) -join ', ')"

        return @{
            Outcome   = 'blocked'
            Applied   = [int]$Eligibility.Applied
            Unchanged = [int]$Eligibility.Unchanged
            Reasons   = @($Eligibility.Reasons)
            Lines     = @(Get-WtRestartBlockedLinesInternal -Reasons @($Eligibility.Reasons))
            Message   = ''
        }
    }

    if ($DryVerdict)
    {
        return @{
            Outcome   = 'eligible'
            Applied   = [int]$Eligibility.Applied
            Unchanged = [int]$Eligibility.Unchanged
            Reasons   = @()
            Lines     = @()
            Message   = ''
        }
    }

    $Owner = [guid]::NewGuid().ToString('n')
    if (-not (Enter-WtRestartOwnership -Owner $Owner))
    {
        Write-WtRestartRecord -Event 'blocked' -Message 'a restart countdown is already active' -OperationId $OperationId
        return @{
            Outcome   = 'blocked'
            Applied   = [int]$Eligibility.Applied
            Unchanged = [int]$Eligibility.Unchanged
            Reasons   = @('Busy')
            Lines     = @(Get-WtRestartBlockedLinesInternal -Reasons @('Busy'))
            Message   = ''
        }
    }

    $CountdownResult = $null
    try
    {
        if ($Countdown)
        {
            # The interface paints its own countdown; the decision, the ownership and the
            # request below stay identical to the command-line path.
            $CountdownResult = & $Countdown $Eligibility.Applied $Eligibility.Unchanged
        }
        else
        {
            $Planned = (Get-Date).AddSeconds([math]::Max(0, $CountdownSeconds))
            $CountdownResult = Invoke-WtConsoleRestartCountdownInternal -Seconds ([math]::Max(0, $CountdownSeconds)) -Lines @(
                (Get-WtString -Key 'Tui.Restart.Title'),
                (Get-WtString -Key 'Tui.Restart.Applied' -Arguments @($Eligibility.Applied, $Eligibility.Unchanged)),
                (Get-WtRestartRequirementLabelInternal -Requirement $(if ($Requirement) { $Requirement } else { 'Unknown' })),
                (Get-WtString -Key 'Tui.Restart.At' -Arguments @($Planned.ToString('HH:mm:ss'))),
                (Get-WtString -Key 'Tui.Restart.OpenApps')
            )
        }
    }
    finally
    {
        Exit-WtRestartOwnership -Owner $Owner
    }

    if ($CountdownResult.Outcome -ne 'Expired')
    {
        Write-WtRestartRecord -Event 'cancelled' -Message "countdown ended as $($CountdownResult.Outcome); the applied changes are kept" -OperationId $OperationId
        $null = Add-WtOperationNoteInternal -OperationId $OperationId -Message 'automatic restart cancelled; the applied changes are kept'
        return @{
            Outcome   = 'cancelled'
            Applied   = [int]$Eligibility.Applied
            Unchanged = [int]$Eligibility.Unchanged
            Reasons   = @()
            Lines     = @()
            Message   = [string]$CountdownResult.Outcome
        }
    }

    Write-WtRestartRecord -Event 'scheduled' -Message "countdown expired; requesting a restart through $($Availability.Mechanism)" -OperationId $OperationId
    $null = Add-WtOperationNoteInternal -OperationId $OperationId -Message 'automatic restart requested after a clean, fully recorded batch'

    $Request = Invoke-WtRestartRequest -DelaySeconds 0 -Comment 'WindowsTweaker: restarting after applied changes'

    if ($Request.Requested)
    {
        Write-WtRestartRecord -Event 'requested' -Message "accepted by $($Request.Mechanism); a request is not proof that Windows restarted" -OperationId $OperationId
        return @{ Outcome = 'requested'; Applied = [int]$Eligibility.Applied; Unchanged = [int]$Eligibility.Unchanged; Reasons = @(); Lines = @(); Message = [string]$Request.Message }
    }

    Write-WtRestartRecord -Event 'failed' -Message ([string]$Request.Message) -OperationId $OperationId
    if ($OperationId)
    {
        $null = Add-WtOperationNoteInternal -OperationId $OperationId -Message "restart request failed: $($Request.Message)"
    }

    return @{ Outcome = 'failed'; Applied = [int]$Eligibility.Applied; Unchanged = [int]$Eligibility.Unchanged; Reasons = @(); Lines = @(); Message = [string]$Request.Message }
}
