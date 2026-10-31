# WindowsTweaker - public change-verification and recovery surface.
#
# Everything the CLI and the terminal interface need to show a change before it happens, to
# explain conflicts, to compare what was applied with what is live, to walk sessions, to
# restore them in dependency order and to export evidence. The implementation lives in the
# private layer (Targets/Journal/Preview/Diagnostics/Measurements); this file is the
# supported, documented front door.

<#
.SYNOPSIS
    Shows exactly what a tweak state would change, before anything runs.
.DESCRIPTION
    Read-only: the declared operations of a declarative tweak are read from the definition,
    and a scripted tweak is dry-run through its own implementation. Each target row reports
    the current value (keeping absent, unreadable, empty and zero apart), the intended value
    and type, the scope, the support status and the recovery limits, plus whether an earlier
    operation already captured a baseline for the same target.
.PARAMETER Id
    Tweak id.
.PARAMETER State
    Requested state; defaults to the tweak's default state.
.PARAMETER Arguments
    Parameters for parameterized tweaks.
.EXAMPLE
    Get-WtChangePreview -Id Privacy.AdvertisingId -State Disabled
#>
function Get-WtChangePreview
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $true, Position = 1)][string]$Id,
        [Parameter(Mandatory = $false, Position = 2)][string]$State,
        [Parameter(Mandatory = $false)][hashtable]$Arguments
    )

    return (Get-WtChangePreviewInternal -Id $Id -State $State -Arguments $Arguments)
}

<#
.SYNOPSIS
    Reports overlapping targets between two or more previews.
.DESCRIPTION
    Two tweaks that write the same canonical target (or a registry key that contains the
    other's value) are reported as a conflict before anything is applied, with both sides and
    the reason.
.PARAMETER Preview
    Preview objects from Get-WtChangePreview.
#>
function Get-WtChangeConflict
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ([Parameter(Mandatory = $true, ValueFromPipeline = $true)][object[]]$Preview)

    begin { $Collected = [System.Collections.Generic.List[object]]::new() }
    process { foreach ($Item in $Preview) { $Collected.Add($Item) } }
    end { return @(Get-WtChangeConflictInternal -Preview @($Collected.ToArray())) }
}

<#
.SYNOPSIS
    Compares the applied state recorded in the journal with the live system.
.DESCRIPTION
    Every still-active operation contributes its targets, and each one is classified as
    matching, changed, unreadable or unsupported. The Windows build and revision recorded at
    apply time are reported as context when they differ - never as the cause of a drift.
    Nothing is reapplied: use Invoke-WtTweak with -Origin reapply after reviewing the rows.
.PARAMETER TweakId
    Restrict the comparison to one tweak.
.PARAMETER OnlyDrifted
    Return only the rows that are not matching.
.EXAMPLE
    Get-WtDrift -OnlyDrifted
#>
function Get-WtDrift
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $false)][string]$TweakId,
        [Parameter(Mandatory = $false)][switch]$OnlyDrifted,
        [Parameter(Mandatory = $false)][int]$Limit = 100
    )

    return @(Get-WtDriftInternal -TweakId $TweakId -OnlyDrifted:$OnlyDrifted -Limit $Limit)
}

<#
.SYNOPSIS
    Lists the recorded sessions (one per run of the interface or CLI invocation).
.DESCRIPTION
    Each session reports when it started, how many operations it holds, the origins they came
    from, the stage of each, and how many operations were interrupted. Ordered by the journal
    sequence, never by timestamps alone.
#>
function Get-WtSession
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ([Parameter(Mandatory = $false)][int]$Limit = 20)

    return @(Get-WtSessionRecord -Limit $Limit)
}

<#
.SYNOPSIS
    Marks the current session as ended (called on a clean shutdown).
.DESCRIPTION
    A session is opened when the first journal entry of a run is written and stays open until
    this command closes it, so Get-WtSession can tell a run that finished from one that was
    interrupted. The interface and the command line call it on their way out; a caller that
    hosts the module itself should call it when its own run ends.

    It is bookkeeping only: a run that never wrote a journal entry has no session to close, so
    this command writes nothing and returns $false - a read-only command stays read-only. A
    store that cannot be read is reported the same way instead of throwing, because a shutdown
    must never turn into a failure the caller has to handle. Closing an already closed session
    keeps the first end timestamp: the end of a run does not move because two callers closed it.
.PARAMETER SessionId
    Session to close. Defaults to the session of this process.
.OUTPUTS
    Boolean: $true when the session was found and is closed when this command returns.
.EXAMPLE
    Close-WtSession
#>
function Close-WtSession
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ([Parameter(Mandatory = $false)][string]$SessionId)

    if (-not $SessionId) { $SessionId = Get-WtSessionId }
    if (-not $SessionId) { return $false }

    $Store = Read-WtStateStore
    if ($Store.Corrupt) { return $false }

    $Found = $false
    $Changed = $false
    $Sessions = @()
    foreach ($Session in @($Store.Sessions))
    {
        if ($Session.sessionId -eq $SessionId)
        {
            $Found = $true
            if (-not $Session.endedUtc)
            {
                $Session.endedUtc = (Get-Date).ToUniversalTime().ToString('o')
                $Changed = $true
            }
        }
        $Sessions += $Session
    }

    if ($Changed)
    {
        $Store.Sessions = $Sessions
        Write-WtStateStore -Store $Store
    }

    return $Found
}

<#
.SYNOPSIS
    Lists operations that were interrupted (planned or applied but never finished).
.DESCRIPTION
    Read-only. The interface shows these at startup and offers to inspect them; restoring one
    is an explicit Undo-WtTweak/Undo-WtSession call, never something that happens by itself.
#>
function Get-WtInterruptedOperation
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ()

    return @(Get-WtInterruptedOperationInternal)
}

<#
.SYNOPSIS
    Returns the operations of the journal, newest first.
.PARAMETER TweakId
    Only operations of this tweak.
.PARAMETER SessionId
    Only operations of this session.
.PARAMETER Origin
    manual, preset, recovery, reapply or legacy.
.PARAMETER Stage
    planned, applied, verified, failed, compensated, restored, completed or abandoned.
.PARAMETER Limit
    Maximum number of rows (0 or less means all of them).
.EXAMPLE
    Get-WtOperation -Origin preset -Limit 20
#>
function Get-WtOperation
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $false)][string]$TweakId,
        [Parameter(Mandatory = $false)][string]$SessionId,
        [Parameter(Mandatory = $false)][ValidateSet('manual', 'preset', 'recovery', 'reapply', 'legacy')][string]$Origin,
        [Parameter(Mandatory = $false)][string]$Stage,
        [Parameter(Mandatory = $false)][int]$Limit = 50,
        [Parameter(Mandatory = $false)][switch]$IncludeDryRun
    )

    $All = $Limit -le 0
    $Parameters = @{ Limit = [math]::Max(1, $Limit); IncludeDryRun = [bool]$IncludeDryRun; All = $All }
    if ($TweakId) { $Parameters.TweakId = $TweakId }
    if ($SessionId) { $Parameters.SessionId = $SessionId }
    if ($Origin) { $Parameters.Origin = $Origin }
    if ($Stage) { $Parameters.Stage = $Stage }

    return @(Get-WtJournalEntryInternal @Parameters)
}

<#
.SYNOPSIS
    Writes the journal (optionally filtered) to a file.
.DESCRIPTION
    One row per operation with its targets, stage, verification and compensation. JSON keeps
    the records themselves; CSV is a flat summary for spreadsheets. Nothing is written unless
    this command is called.
.PARAMETER Path
    Destination file. Refuses to overwrite unless -Force is given.
.PARAMETER Format
    Json (default) or Csv.
.EXAMPLE
    Export-WtHistory -Path ~/wintweaker-history.json -SessionId $session
#>
function Export-WtHistory
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][ValidateSet('Json', 'Csv')][string]$Format = 'Json',
        [Parameter(Mandatory = $false)][string]$TweakId,
        [Parameter(Mandatory = $false)][string]$SessionId,
        [Parameter(Mandatory = $false)][ValidateSet('manual', 'preset', 'recovery', 'reapply', 'legacy')][string]$Origin,
        [Parameter(Mandatory = $false)][switch]$Force
    )

    if ((Test-Path -LiteralPath $Path) -and -not $Force)
    {
        throw "Refusing to overwrite '$Path'. Pass -Force to replace it."
    }

    $Filter = @{ Limit = 0 }
    if ($TweakId) { $Filter.TweakId = $TweakId }
    if ($SessionId) { $Filter.SessionId = $SessionId }
    if ($Origin) { $Filter.Origin = $Origin }
    $Operations = @(Get-WtOperation @Filter)
    $Directory = Split-Path -Path $Path -Parent
    if ($Directory) { New-WtDirectory -Path $Directory }

    if ($Format -eq 'Csv')
    {
        $Rows = @($Operations | ForEach-Object {
                [pscustomobject]@{
                    operationId    = $_.operationId
                    sessionId      = $_.sessionId
                    parentOperationId = $_.parentOperationId
                    sequence       = $_.sequence
                    origin         = $_.origin
                    stage          = $_.stage
                    tweakId        = $_.tweakId
                    state          = $_.state
                    outcome        = $_.outcome
                    dryRun         = $_.dryRun
                    timestamp      = $_.timestamp
                    targets        = @($_.targets).Count
                    captured       = @($_.records).Count
                    verified       = $(if ($_.verification) { [int]$_.verification.Verified } else { '' })
                    mismatched     = $(if ($_.verification) { [int]$_.verification.Mismatched } else { '' })
                    compensated    = $(if ($_.compensation) { [int]$_.compensation.Succeeded } else { '' })
                    rolledBack     = $_.rolledBack
                }
            })

        if ($Rows.Count -eq 0)
        {
            Write-WtTextFile -Path $Path -Value 'operationId,sessionId,parentOperationId,sequence,origin,stage,tweakId,state,outcome,dryRun,timestamp,targets,captured,verified,mismatched,compensated,rolledBack'
            return $Path
        }

        Write-WtTextFile -Path $Path -Value (($Rows | ConvertTo-Csv -NoTypeInformation) -join [System.Environment]::NewLine)
        return $Path
    }

    $Payload = [ordered]@{
        version    = $Script:WtStateSchemaVersion
        exportedUtc = (Get-Date).ToUniversalTime().ToString('o')
        appVersion = (Get-WtAppVersion).ModuleVersion
        platform   = (Get-WtJournalContext).platform
        operations = $Operations
    }

    Write-WtTextFile -Path $Path -Value (ConvertTo-WtJson -InputObject $Payload -Depth 32)
    return $Path
}

<#
.SYNOPSIS
    Plans the restore of a session without changing anything.
.DESCRIPTION
    Operations are ordered by the journal sequence, newest first (never by timestamp), and
    overlapping targets inside the plan are resolved explicitly: a target is restored once by
    the newest operation that wrote it, older operations that touched it are reported as
    superseded, and targets whose live value no longer matches what was applied are reported
    as external changes so nothing is overwritten silently.
.PARAMETER SessionId
    Session to plan. Defaults to the current session.
#>
function Get-WtRestorePlan
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $false)][string]$SessionId,
        [Parameter(Mandatory = $false)][string]$TweakId
    )

    if (-not $SessionId -and -not $TweakId) { $SessionId = Get-WtSessionId }
    return (Get-WtRestorePlanInternal -SessionId $SessionId -TweakId $TweakId)
}

<#
.SYNOPSIS
    Restores every restorable operation of a session, in reverse dependency order.
.DESCRIPTION
    Each operation is rolled back through the normal path (Undo-WtTweak semantics), so the
    external-change check, the read-back verification and the journal stages apply to every
    step. A step that is blocked by an external change stops the session restore unless -Force
    is given. Nothing is applied, only restored.
.PARAMETER SessionId
    Session to restore. Defaults to the current session.
.PARAMETER WhatIf
    Report the plan without restoring anything.
.EXAMPLE
    Undo-WtSession -SessionId 8f2c... -WhatIf
#>
function Undo-WtSession
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $false)][string]$SessionId,
        [Parameter(Mandatory = $false)][string]$TweakId,
        [Parameter(Mandatory = $false)][switch]$Force
    )

    $Plan = Get-WtRestorePlan -SessionId $SessionId -TweakId $TweakId
    $Results = [System.Collections.Generic.List[object]]::new()

    if ($Plan.OperationCount -eq 0)
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.SessionRestoreResult'
            SessionId  = $Plan.SessionId
            Status     = 'unchanged'
            Steps      = @()
            Messages   = @((Get-WtString -Key 'Tui.Restore.Empty'))
            Plan       = $Plan
        }
    }

    foreach ($Step in $Plan.Steps)
    {
        if ($Step.SupersededOnly) { continue }

        if (-not $PSCmdlet.ShouldProcess($Step.TweakId, "restore operation $($Step.OperationId)"))
        {
            $Results.Add([pscustomobject]@{ OperationId = $Step.OperationId; TweakId = $Step.TweakId; Status = (Get-WtShouldProcessStatus); Messages = @() })
            continue
        }

        $Result = Undo-WtTweak -HistoryId $Step.OperationId -Force:$Force
        $Results.Add([pscustomobject]@{
            OperationId = $Step.OperationId
            TweakId     = $Step.TweakId
            Status      = [string]$Result.Status
            Messages    = @($Result.Messages)
            Verification = $Result.Verification
        })
    }

    $Failed = @($Results | Where-Object { $_.Status -in 'failed', 'unsupported', 'review-required' }).Count
    $Status = if ($Failed -gt 0) { 'failed' } elseif (@($Results).Count -eq 0) { 'unchanged' } else { 'succeeded' }

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.SessionRestoreResult'
        SessionId  = $Plan.SessionId
        Status     = $Status
        Steps      = @($Results.ToArray())
        Messages   = @($Plan.Conflicts | ForEach-Object { "Superseded: $($_.Label)" })
        Plan       = $Plan
    }
}
