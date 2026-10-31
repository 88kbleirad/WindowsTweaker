# WindowsTweaker - durable operation journal.
#
# The journal is the state store's `journal` array (schema version 2). One entry describes
# one apply/restore operation end to end:
#
#   operationId, parentOperationId, sessionId, sequence, origin, stage
#   tweakId, state, arguments, dryRun, startedUtc, updatedUtc, appVersion, platform
#   targets[]  - canonical identity, original value, intended value, baseline reference,
#                captured flag and the read-back verification result
#   records[]  - the exact pre-change capture the rollback engine replays (unchanged)
#   outcome, messages, verification, compensation, rolledBack
#
# Durability rules this file implements:
#   * recovery information is written *before* the mutation starts (stage 'planned'), and a
#     write that fails aborts the operation before anything is changed;
#   * every stage transition is its own atomic, locked write, so an interrupted process
#     leaves a journal that says exactly how far it got;
#   * a store that cannot be parsed is an error, and is never overwritten;
#   * a stage transition that cannot be written is reported, never swallowed.
#
# Sessions exist so a run can be reasoned about as a unit: every entry carries the session it
# belonged to plus an explicit parent operation when it was caused by another one (a preset
# apply is the parent of its entries; a reapply is the child of the drift review that asked
# for it). Ordering is by the monotonic `sequence`, never by timestamp: timestamps can tie,
# move backwards when the clock is corrected, and say nothing about dependency.

$Script:WtJournalStages = @('planned', 'applied', 'verified', 'failed', 'compensated', 'restored', 'completed', 'abandoned')
$Script:WtJournalOrigins = @('manual', 'preset', 'recovery', 'reapply', 'legacy')
$Script:WtSessionId = $null
$Script:WtSessionStarted = $null
$Script:WtJournalSequence = $null

<#
.SYNOPSIS
    Returns the current session id, creating and persisting one on first use.
.DESCRIPTION
    A session groups the operations of one run of the interface or one CLI invocation. The
    id is created lazily so a read-only command never writes anything.
#>
function Get-WtSessionId
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][switch]$Start)

    if ($Start -or -not $Script:WtSessionId)
    {
        if (-not $Script:WtSessionId)
        {
            $Script:WtSessionId = [guid]::NewGuid().ToString('n')
            $Script:WtSessionStarted = (Get-Date).ToUniversalTime().ToString('o')
        }
    }

    return [string]$Script:WtSessionId
}

<#
.SYNOPSIS
    Returns the next journal sequence number.
.DESCRIPTION
    Monotonic within the machine-wide store: it is derived from the highest sequence already
    recorded, so ordering survives process restarts and never depends on the clock.
#>
function Get-WtJournalSequence
{
    [CmdletBinding()]
    [OutputType([int])]
    param ([Parameter(Mandatory = $false)][object]$Store)

    if ($null -ne $Script:WtJournalSequence)
    {
        $Script:WtJournalSequence = [int]$Script:WtJournalSequence + 1
        return [int]$Script:WtJournalSequence
    }

    if (-not $Store) { $Store = Read-WtStateStore }

    $Highest = 0
    foreach ($Entry in @($Store.History))
    {
        if ($Entry.PSObject.Properties.Name -contains 'sequence' -and $Entry.sequence)
        {
            $Value = [int]$Entry.sequence
            if ($Value -gt $Highest) { $Highest = $Value }
        }
    }

    $Script:WtJournalSequence = $Highest + 1
    return [int]$Script:WtJournalSequence
}

<#
.SYNOPSIS
    Returns the platform and application context recorded with every operation.
#>
function Get-WtJournalContext
{
    [CmdletBinding()]
    param ()

    $Version = ''
    try
    {
        $Manifest = Join-Path $Script:WtModuleRoot 'WindowsTweaker.psd1'
        if (Test-Path -LiteralPath $Manifest)
        {
            $Version = [string](Import-PowerShellDataFile -LiteralPath $Manifest -ErrorAction Stop).ModuleVersion
        }
    }
    catch
    {
        $Version = ''
    }

    $Environment = Get-WtEnvironment

    return @{
        appVersion = $Version
        platform   = @{
            PowerShell = $PSVersionTable.PSVersion.ToString()
            OSVersion  = [string]$Environment.OSVersionKey
            OSBuild    = [string]$Environment.OSBuild
            OSUBR      = [string]$Environment.OSUBR
            OSName     = [string]$Environment.OSName
            IsWindows  = [bool]$Environment.IsWindows
        }
    }
}

<#
.SYNOPSIS
    Normalises one entry read from the store (v2 shape) into the object the code uses.
.DESCRIPTION
    Legacy fields are kept alongside the journal fields: `historyId` mirrors `operationId`,
    `records` still carries the capture the rollback engine replays, and `state`/`timestamp`
    keep their names, so every existing caller and stored file keeps working.
#>
function ConvertTo-WtJournalInstant
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][object]$Value)

    # A timestamp is written as an ISO-8601 UTC round-trip string, but the JSON reader hands an
    # ISO string back as a DateTime, and casting that to a string renders it in the current
    # culture with an unspecified kind. Everything downstream - the boundary probe, exports, a
    # reader comparing two operations - then compares culture text instead of instants, so the
    # value is normalised back to the form it was written in.
    if ($null -eq $Value) { return '' }

    if ($Value -is [datetime])
    {
        $Stamp = [datetime]$Value
        if ($Stamp.Kind -ne [System.DateTimeKind]::Utc) { $Stamp = $Stamp.ToUniversalTime() }
        return $Stamp.ToString('o')
    }

    $Text = [string]$Value
    if (-not $Text) { return '' }

    $Parsed = [datetime]::MinValue
    if ([datetime]::TryParse($Text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$Parsed))
    {
        # Records written before this normalisation hold culture text produced from a UTC instant,
        # so an unspecified kind is read as UTC rather than as local time.
        if ($Parsed.Kind -eq [System.DateTimeKind]::Unspecified)
        {
            $Parsed = [datetime]::SpecifyKind($Parsed, [System.DateTimeKind]::Utc)
        }

        return $Parsed.ToUniversalTime().ToString('o')
    }

    # Not a timestamp: keep exactly what was stored instead of inventing an instant for it.
    return $Text
}

<#
.SYNOPSIS
    Normalises one entry read from the store (v2 shape) into the object the code uses.
.DESCRIPTION
    Legacy fields are kept alongside the journal fields: `historyId` mirrors `operationId`,
    `records` still carries the capture the rollback engine replays, and `state`/`timestamp`
    keep their names, so every existing caller and stored file keeps working.
#>
function ConvertTo-WtJournalEntry
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $false)][switch]$LegacyEntry
    )

    $Names = @($Entry.PSObject.Properties.Name)
    $OperationId = if ($Names -contains 'operationId' -and $Entry.operationId) { [string]$Entry.operationId }
    elseif ($Names -contains 'historyId' -and $Entry.historyId) { [string]$Entry.historyId }
    else { [guid]::NewGuid().ToString('n') }

    $Outcome = if ($Names -contains 'outcome') { [string]$Entry.outcome } else { 'pending' }
    $RolledBack = ($Names -contains 'rolledBack') -and [bool]$Entry.rolledBack

    $EntryLevel = [pscustomobject]@{
        PSTypeName        = 'WindowsTweaker.JournalEntry'
        operationId       = $OperationId
        historyId         = $OperationId
        parentOperationId = if ($Names -contains 'parentOperationId') { $Entry.parentOperationId } else { $null }
        sessionId         = if ($Names -contains 'sessionId' -and $Entry.sessionId) { [string]$Entry.sessionId } else { 'legacy' }
        sequence          = if ($Names -contains 'sequence' -and $Entry.sequence) { [int]$Entry.sequence } else { 0 }
        origin            = if ($Names -contains 'origin' -and $Entry.origin) { [string]$Entry.origin } else { 'legacy' }
        stage             = if ($Names -contains 'stage' -and $Entry.stage) { [string]$Entry.stage } else { $(if ($Outcome -eq 'pending') { 'abandoned' } else { 'completed' }) }
        appVersion        = if ($Names -contains 'appVersion') { [string]$Entry.appVersion } else { '' }
        platform          = if ($Names -contains 'platform') { $Entry.platform } else { $null }
        tweakId           = [string]$Entry.tweakId
        state             = if ($Names -contains 'state') { [string]$Entry.state } else { '' }
        arguments         = if ($Names -contains 'arguments' -and $Entry.arguments) { $Entry.arguments } else { @{} }
        timestamp         = ConvertTo-WtJournalInstant -Value $(if ($Names -contains 'timestamp') { $Entry.timestamp } else { '' })
        updatedUtc        = ConvertTo-WtJournalInstant -Value $(if ($Names -contains 'updatedUtc') { $Entry.updatedUtc } else { $Entry.timestamp })
        dryRun            = ($Names -contains 'dryRun') -and [bool]$Entry.dryRun
        targets           = if ($Names -contains 'targets' -and $Entry.targets) { @($Entry.targets) } else { @() }
        records           = if ($Names -contains 'records' -and $Entry.records) { @($Entry.records) } else { @() }
        outcome           = $Outcome
        messages          = if ($Names -contains 'messages' -and $Entry.messages) { @($Entry.messages) } else { @() }
        verification      = if ($Names -contains 'verification') { $Entry.verification } else { $null }
        compensation      = if ($Names -contains 'compensation') { $Entry.compensation } else { $null }
        rolledBack        = $RolledBack
        rolledBackAt      = if ($Names -contains 'rolledBackAt') { $Entry.rolledBackAt } else { $null }
        legacy            = [bool]$LegacyEntry
    }

    return $EntryLevel
}

<#
.SYNOPSIS
    Reads the journal, newest first, with optional filters.
.DESCRIPTION
    Filters are explicit (tweak, session, origin, stage, outcome) and never inferred from
    timestamps.
#>
function Get-WtJournalEntryInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][string]$TweakId,
        [Parameter(Mandatory = $false)][string]$SessionId,
        [Parameter(Mandatory = $false)][string]$Origin,
        [Parameter(Mandatory = $false)][string]$Stage,
        [Parameter(Mandatory = $false)][string]$OperationId,
        [Parameter(Mandatory = $false)][int]$Limit = 50,
        [Parameter(Mandatory = $false)][switch]$IncludeDryRun,
        [Parameter(Mandatory = $false)][switch]$All
    )

    $Store = Read-WtStateStore
    $Entries = @($Store.History)

    if ($TweakId) { $Entries = @($Entries | Where-Object { $_.tweakId -eq $TweakId }) }
    if ($SessionId) { $Entries = @($Entries | Where-Object { $_.sessionId -eq $SessionId }) }
    if ($Origin) { $Entries = @($Entries | Where-Object { $_.origin -eq $Origin }) }
    if ($Stage) { $Entries = @($Entries | Where-Object { $_.stage -eq $Stage }) }
    if ($OperationId) { $Entries = @($Entries | Where-Object { $_.operationId -eq $OperationId }) }
    if (-not $IncludeDryRun) { $Entries = @($Entries | Where-Object { -not $_.dryRun }) }

    # Order by the monotonic sequence (dependency order), never by timestamp.
    $Ordered = @($Entries | Sort-Object -Property sequence -Descending)
    if ($All) { return $Ordered }
    return @($Ordered | Select-Object -First $Limit)
}

<#
.SYNOPSIS
    Appends a new journal entry and persists it before any mutation happens.
.DESCRIPTION
    Throws when the entry cannot be persisted: an operation whose recovery information could
    not be stored must not start. A corrupt store therefore stops the operation instead of
    being overwritten.
#>
function Add-WtJournalEntry
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Entry)

    $Store = Read-WtStateStore
    if ($Store.Corrupt)
    {
        throw "The state store could not be read ($($Store.Error)). Refusing to start: recovery information cannot be stored."
    }

    if ($Entry.sequence -le 0)
    {
        $Entry.sequence = Get-WtJournalSequence -Store $Store
    }

    $SessionId = [string]$Entry.sessionId
    $Sessions = @($Store.Sessions)
    if ($SessionId -and $SessionId -ne 'legacy' -and -not @($Sessions | Where-Object { $_.sessionId -eq $SessionId }))
    {
        $Sessions += [pscustomobject]@{
            sessionId     = $SessionId
            startedUtc    = $(if ($Script:WtSessionStarted) { $Script:WtSessionStarted } else { $Entry.timestamp })
            endedUtc      = $null
            appVersion    = [string]$Entry.appVersion
            platform      = $Entry.platform
        }
    }

    $Store.Sessions = $Sessions
    $Store.History = @($Store.History) + @($Entry)

    if ($Store.History.Count -gt 500)
    {
        # Keep the store bounded, but never drop an entry that still holds recovery data
        # which has not been restored yet: those are the ones the user can still undo.
        $Restorable = @($Store.History | Where-Object { -not $_.rolledBack -and @($_.records).Count -gt 0 })
        $Keep = @($Restorable | Sort-Object -Property sequence | Select-Object -First 200)
        $Tail = @($Store.History | Where-Object { $_.rolledBack -or @($_.records).Count -eq 0 } | Sort-Object -Property sequence -Descending | Select-Object -First ([math]::Max(0, 400 - $Keep.Count)))
        $Store.History = @(($Keep + $Tail) | Sort-Object -Property sequence)
    }

    Write-WtStateStore -Store $Store
    return $Entry
}

<#
.SYNOPSIS
    Persists one stage transition of an existing entry.
.DESCRIPTION
    Read-modify-write under the store lock. A failure is thrown, never swallowed: the caller
    reports it, and the entry already on disk still holds the previous (safer) stage.
#>
function Update-WtJournalStage
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][ValidateSet('planned', 'applied', 'verified', 'failed', 'compensated', 'restored', 'completed', 'abandoned')][string]$Stage,
        [Parameter(Mandatory = $false)][string[]]$Messages = @(),
        [Parameter(Mandatory = $false)][object]$Verification,
        [Parameter(Mandatory = $false)][object]$Compensation
    )

    $Entry.stage = $Stage
    $Entry.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    if ($Messages.Count -gt 0) { $Entry.messages = @($Entry.messages) + @($Messages) }
    if ($Verification) { $Entry.verification = $Verification }
    if ($Compensation) { $Entry.compensation = $Compensation }

    $Store = Read-WtStateStore
    if ($Store.Corrupt)
    {
        throw "The state store could not be read ($($Store.Error)). The operation journal was not updated."
    }

    $Found = $false
    $Journal = @()
    foreach ($Existing in @($Store.History))
    {
        if ($Existing.operationId -eq $Entry.operationId)
        {
            # Monotonic flags belong to whoever set them: a stage update must never clear the
            # "rolled back" marker another write already persisted (this is written from an
            # in-memory copy that may predate that write).
            if ($Existing.rolledBack -and -not $Entry.rolledBack)
            {
                $Entry.rolledBack = $Existing.rolledBack
                $Entry.rolledBackAt = $Existing.rolledBackAt
            }

            $Journal += $Entry
            $Found = $true
        }
        else
        {
            $Journal += $Existing
        }
    }

    if (-not $Found)
    {
        $Journal += $Entry
    }

    $Store.History = $Journal
    Write-WtStateStore -Store $Store
    return $Entry
}

<#
.SYNOPSIS
    Returns the sessions recorded in the store, newest first.
#>
function Get-WtSessionRecord
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][int]$Limit = 20)

    $Store = Read-WtStateStore
    $Sessions = [System.Collections.Generic.List[object]]::new()

    foreach ($Session in @($Store.Sessions))
    {
        $Entries = @($Store.History | Where-Object { $_.sessionId -eq $Session.sessionId })
        $Stages = @($Entries | Group-Object -Property stage | ForEach-Object { "$($_.Name):$($_.Count)" })
        $Sessions.Add([pscustomobject]@{
            PSTypeName    = 'WindowsTweaker.JournalSession'
            SessionId     = $Session.sessionId
            StartedUtc    = $Session.startedUtc
            EndedUtc      = $Session.endedUtc
            Open          = -not $Session.endedUtc
            OperationCount = $Entries.Count
            Origins       = @(($Entries | Group-Object -Property origin | ForEach-Object { "$($_.Name):$($_.Count)" }) -join ' ')
            Stages        = @($Stages -join ' ')
            Interrupted   = @($Entries | Where-Object { $_.stage -in 'planned', 'applied' }).Count
        })
    }

    return @($Sessions | Sort-Object -Property StartedUtc -Descending | Select-Object -First $Limit)
}

<#
.SYNOPSIS
    Finds the oldest entry that still holds the original recovery baseline for one target.
.DESCRIPTION
    Applying a tweak twice must not lose the way back to the state before the *first* apply.
    The baseline is the earliest operation that captured this identity and has not been
    rolled back; later applies reference it instead of replacing it.
#>
function Get-WtBaselineEntry
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Identity)

    if (-not $Identity) { return $null }

    $Candidates = @(Get-WtJournalEntryInternal -Limit 500 -All | Where-Object {
            -not $_.rolledBack -and @($_.records).Count -gt 0 -and
            @($_.targets | Where-Object { $_.identity -eq $Identity -and $_.captured }) 
        })

    return @($Candidates | Sort-Object -Property sequence | Select-Object -First 1)
}

<#
.SYNOPSIS
    Returns the operations that were interrupted (planned or applied but never finished).
.DESCRIPTION
    Startup uses this to offer read-only inspection and an explicit recovery. Nothing here
    acts on its own.
#>
function Get-WtInterruptedOperationInternal
{
    [CmdletBinding()]
    param ()

    $Store = Read-WtStateStore
    if ($Store.Corrupt)
    {
        return @()
    }

    $Rows = [System.Collections.Generic.List[object]]::new()
    foreach ($Entry in @($Store.History))
    {
        if ($Entry.dryRun) { continue }
        if ($Entry.stage -notin 'planned', 'applied') { continue }
        if ($Entry.outcome -in 'unsupported', 'skipped') { continue }

        $Rows.Add([pscustomobject]@{
            PSTypeName    = 'WindowsTweaker.InterruptedOperation'
            OperationId   = $Entry.operationId
            SessionId     = $Entry.sessionId
            TweakId       = $Entry.tweakId
            State         = $Entry.state
            Stage         = $Entry.stage
            StartedUtc    = $Entry.timestamp
            TargetCount   = @($Entry.targets).Count
            CapturedCount = @($Entry.records).Count
            CanRestore    = (@($Entry.records).Count -gt 0)
            Origin        = $Entry.origin
        })
    }

    return @($Rows | Sort-Object -Property StartedUtc)
}

<#
.SYNOPSIS
    Compares one target's recorded intended value with its live value.
.OUTPUTS
    One row with Status: matching, changed, unreadable or unsupported.
#>
function Get-WtDriftRow
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Target,
        [Parameter(Mandatory = $true)][object]$Entry
    )

    $Live = Get-WtTargetState -Identity ([string]$Target.identity)
    $Intended = $Target.intended
    $Row = [pscustomobject]@{
        PSTypeName    = 'WindowsTweaker.DriftRow'
        Identity      = [string]$Target.identity
        Label         = (Format-WtTargetIdentity -Identity ([string]$Target.identity) -Label ([string]$Target.label))
        TweakId       = [string]$Entry.tweakId
        OperationId   = [string]$Entry.operationId
        AppliedUtc    = [string]$Entry.timestamp
        IntendedValue = $(if ($Intended) { [string]$Intended.display } else { '' })
        LiveValue     = (ConvertTo-WtTargetDisplayValue -Value $Live.Value -ValueKind $Live.ValueKind)
        LiveValueKind = [string]$Live.ValueKind
        Status        = 'matching'
        Reason        = ''
    }

    if ($Live.Reader -eq '')
    {
        $Row.Status = 'unsupported'
        $Row.Reason = $Live.Reason
        return $Row
    }

    if ($Live.ValueKind -eq 'Unreadable')
    {
        $Row.Status = 'unreadable'
        $Row.Reason = $Live.Reason
        return $Row
    }

    if (-not $Intended -or $Intended.kind -eq 'Absent')
    {
        # The operation removed the target: matching means "still absent".
        if ($Live.ValueKind -eq 'Absent')
        {
            $Row.Status = 'matching'
            return $Row
        }

        $Row.Status = 'changed'
        $Row.Reason = 'The target was removed by this operation but exists again.'
        return $Row
    }

    if ($Live.ValueKind -eq 'Absent')
    {
        $Row.Status = 'changed'
        $Row.Reason = 'The target no longer holds the applied value.'
        return $Row
    }

    if (Test-WtTargetValueMatch -Left $Live.Value -Right $Intended.value)
    {
        $Row.Status = 'matching'
        return $Row
    }

    $Row.Status = 'changed'
    $Row.Reason = 'The live value differs from the applied value.'
    return $Row
}

<#
.SYNOPSIS
    Returns the drift of every target a still-active operation applied.
.DESCRIPTION
    Only operations that were not rolled back are compared, and the newest operation per
    target wins (it is the one whose intended value the live system is expected to show).
    The platform recorded at apply time is compared with the current one and reported as
    context - a build change is never presented as the cause of a drift.
.PARAMETER TweakId
    Restrict the comparison to one tweak.
#>
function Get-WtDriftInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][string]$TweakId,
        [Parameter(Mandatory = $false)][int]$Limit = 100,
        [Parameter(Mandatory = $false)][switch]$OnlyDrifted
    )

    $Store = Read-WtStateStore
    if ($Store.Corrupt)
    {
        throw "The state store could not be read ($($Store.Error)). Drift cannot be compared."
    }

    $Environment = Get-WtEnvironment
    $Live = @{
        OSBuild   = [string]$Environment.OSBuild
        OSUBR     = [string]$Environment.OSUBR
        OSVersion = [string]$Environment.OSVersionKey
    }

    $Seen = @{}
    $Rows = [System.Collections.Generic.List[object]]::new()

    foreach ($Entry in @(Get-WtJournalEntryInternal -TweakId $TweakId -All | Where-Object { -not $_.rolledBack -and -not $_.dryRun -and $_.outcome -in 'succeeded', 'partial' }))
    {
        foreach ($Target in @($Entry.targets))
        {
            $Identity = [string]$Target.identity
            if (-not $Identity -or $Seen.ContainsKey($Identity)) { continue }
            $Seen[$Identity] = $true

            $Row = Get-WtDriftRow -Target $Target -Entry $Entry
            $Row | Add-Member -NotePropertyName RecordedBuild -NotePropertyValue $(if ($Entry.platform) { [string]$Entry.platform.OSBuild } else { '' })
            $Row | Add-Member -NotePropertyName BuildChanged -NotePropertyValue ($false)
            if ($Entry.platform -and (([string]$Entry.platform.OSBuild -ne $Live.OSBuild) -or ([string]$Entry.platform.OSUBR -ne $Live.OSUBR)))
            {
                $Row.BuildChanged = $true
            }

            $Rows.Add($Row)
        }
    }

    $Result = @($Rows | Sort-Object -Property Status, Label)
    if ($OnlyDrifted) { $Result = @($Result | Where-Object { $_.Status -ne 'matching' }) }

    return @($Result | Select-Object -First $Limit)
}

<#
.SYNOPSIS
    Builds a dependency-aware restore plan for a session (or one operation).
.DESCRIPTION
    Entries are ordered by the journal sequence, newest first, which is the reverse of the
    order they were applied in - never by timestamp. Overlapping targets inside the plan are
    resolved explicitly: the newest operation that wrote a target is restored once, and the
    older operations that touched the same target are reported as superseded instead of
    being replayed on top of it. Targets whose live value no longer matches what the plan
    applied are reported as external changes, so nothing is overwritten silently.
#>
function Get-WtRestorePlanInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][string]$SessionId,
        [Parameter(Mandatory = $false)][string]$OperationId,
        [Parameter(Mandatory = $false)][string]$TweakId
    )

    $Entries = if ($OperationId)
    {
        @(Get-WtJournalEntryInternal -OperationId $OperationId -All)
    }
    elseif ($SessionId)
    {
        @(Get-WtJournalEntryInternal -SessionId $SessionId -All)
    }
    elseif ($TweakId)
    {
        @(Get-WtJournalEntryInternal -TweakId $TweakId -All)
    }
    else
    {
        @(Get-WtJournalEntryInternal -All)
    }

    $Ordered = @($Entries |
        Where-Object { -not $_.rolledBack -and -not $_.dryRun -and $_.outcome -in 'succeeded', 'partial' -and @($_.records).Count -gt 0 } |
        Sort-Object -Property sequence -Descending)

    $Steps = [System.Collections.Generic.List[object]]::new()
    $Conflicts = [System.Collections.Generic.List[object]]::new()
    $External = [System.Collections.Generic.List[object]]::new()
    $Claimed = @{}

    foreach ($Entry in $Ordered)
    {
        $Superseded = @()
        foreach ($Target in @($Entry.targets | Where-Object { $_.captured }))
        {
            $Identity = [string]$Target.identity
            $Claim = $null
            foreach ($Existing in $Claimed.Keys)
            {
                if (Test-WtTargetOverlap -Left $Existing -Right $Identity)
                {
                    $Claim = $Existing
                    break
                }
            }

            if ($Claim)
            {
                # A newer operation already covers this target (or a key that contains it):
                # restoring this one on top would fight the other step.
                $Conflicts.Add([pscustomobject]@{
                    PSTypeName  = 'WindowsTweaker.RestoreConflict'
                    Identity    = $Identity
                    Label       = (Format-WtTargetIdentity -Identity $Identity -Label ([string]$Target.label))
                    OperationId = $Entry.operationId
                    ClaimedBy   = [string]$Claimed[$Claim]
                    Reason      = 'Superseded by a newer operation in this plan.'
                })
                $Superseded += $Identity
                continue
            }

            $Claimed[$Identity] = $Entry.operationId

            $Live = Get-WtTargetState -Identity $Identity
            if ($Live.Reader -ne '' -and $Live.ValueKind -ne 'Unreadable')
            {
                $Expected = $Target.intended
                $ValueMatches = $true
                if ($Expected -and $Expected.kind -ne 'Absent')
                {
                    $ValueMatches = Test-WtTargetValueMatch -Left $Live.Value -Right $Expected.value
                }
                elseif ($Live.ValueKind -ne 'Absent')
                {
                    $ValueMatches = $false
                }

                if (-not $ValueMatches)
                {
                    $External.Add([pscustomobject]@{
                        PSTypeName  = 'WindowsTweaker.ExternalChange'
                        Identity    = $Identity
                        Label       = (Format-WtTargetIdentity -Identity $Identity -Label ([string]$Target.label))
                        OperationId = $Entry.operationId
                        Expected    = (ConvertTo-WtTargetDisplayValue -Value $Expected.value -ValueKind $(if ($Expected -and $Expected.kind -eq 'Absent') { 'Absent' } else { 'Value' }))
                        Live        = (ConvertTo-WtTargetDisplayValue -Value $Live.Value -ValueKind $Live.ValueKind)
                        Reason      = 'The live value differs from what this operation applied.'
                    })
                }
            }
        }

        $Steps.Add([pscustomobject]@{
            PSTypeName    = 'WindowsTweaker.RestoreStep'
            OperationId   = $Entry.operationId
            SessionId     = $Entry.sessionId
            TweakId       = $Entry.tweakId
            State         = $Entry.state
            Sequence      = [int]$Entry.sequence
            AppliedUtc    = $Entry.timestamp
            RecordCount   = @($Entry.records).Count
            TargetCount   = @($Entry.targets).Count
            Superseded    = @($Superseded)
            SupersededOnly = (@($Superseded).Count -eq @($Entry.targets | Where-Object { $_.captured }).Count)
        })
    }

    return [pscustomobject]@{
        PSTypeName      = 'WindowsTweaker.RestorePlan'
        SessionId       = $SessionId
        OperationCount  = $Steps.Count
        Steps           = @($Steps.ToArray())
        Conflicts       = @($Conflicts.ToArray())
        ExternalChanges = @($External.ToArray())
        Summary         = $(if ($Steps.Count -eq 0) { 'Nothing to restore.' } else { "$($Steps.Count) operation(s) in reverse dependency order." })
    }
}
