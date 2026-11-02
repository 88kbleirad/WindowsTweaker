# WindowsTweaker - bridge DTO projection.
#
# The engine returns live objects (tweak definitions carry scriptblocks in Detect/Apply/
# States/Detection; journal entries carry nested record lists). Sending those across the
# bridge is wrong twice over: a scriptblock is not JSON, and serialising the whole nested
# graph at depth 12 is pathologically slow (measured: >200 s for one tweak state row).
#
# Every frame the bridge emits therefore goes through a projection here: a bounded, flat
# object holding exactly the fields the frontend renders. Nothing in this file changes
# engine behaviour - it only reads objects and builds new ones.

<#
.SYNOPSIS
    Safely reads a property from an object, returning $null when it is absent.
#>
function Get-WtBridgeProp
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $Property = $Object.psobject.Properties[$Name]
    if ($null -eq $Property) { return $null }
    return $Property.Value
}

<#
.SYNOPSIS
    Converts a possibly-nested value into something the frontend can render: a string.
.DESCRIPTION
    The engine carries some localizable text as a hashtable keyed by language code
    (@{ en = ...; vi = ... }). The frontend must not re-implement the fallback chain, so
    the projection resolves it here against the active language, exactly as Get-WtText
    does inside the engine.
#>
function ConvertTo-WtBridgeText
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [hashtable] -or $Value -is [System.Collections.IDictionary])
    {
        $Language = Get-WtLanguage
        if ($Value.Contains($Language)) { return [string]$Value[$Language] }
        if ($Value.Contains('en')) { return [string]$Value['en'] }
        foreach ($Key in $Value.Keys) { return [string]$Value[$Key] }
        return ''
    }
    return [string]$Value
}

<#
.SYNOPSIS
    Projects one tweak state row (Get-WtTweakState) into a flat DTO.
.DESCRIPTION
    The raw row's `Tweak` property (the whole definition, including its scriptblocks) is
    dropped; only the small metadata subset the details pane needs is kept.
#>
function ConvertTo-WtBridgeStateRow
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Row)

    $Tweak = Get-WtBridgeProp -Object $Row -Name 'Tweak'
    $Parameters = @()
    if ($Tweak) { $Parameters = @(Get-WtBridgeProp -Object $Tweak -Name 'Parameters') }
    $ManagedPolicy = @()
    if ($Tweak) { $ManagedPolicy = @(Get-WtBridgeProp -Object $Tweak -Name 'ManagedPolicy') }
    $CapabilityLoss = $null
    if ($Tweak) { $CapabilityLoss = Get-WtBridgeProp -Object $Tweak -Name 'CapabilityLoss' }

    return [ordered]@{
        Id = [string](Get-WtBridgeProp -Object $Row -Name 'Id')
        Category = [string](Get-WtBridgeProp -Object $Row -Name 'Category')
        Name = ConvertTo-WtBridgeText -Value (Get-WtBridgeProp -Object $Row -Name 'Name')
        Description = ConvertTo-WtBridgeText -Value (Get-WtBridgeProp -Object $Row -Name 'Description')
        Impact = ConvertTo-WtBridgeText -Value (Get-WtBridgeProp -Object $Row -Name 'Impact')
        Risk = [string](Get-WtBridgeProp -Object $Row -Name 'Risk')
        Scope = [string](Get-WtBridgeProp -Object $Row -Name 'Scope')
        Privilege = [string](Get-WtBridgeProp -Object $Row -Name 'Privilege')
        Restart = [string](Get-WtBridgeProp -Object $Row -Name 'Restart')
        Rollback = [string](Get-WtBridgeProp -Object $Row -Name 'Rollback')
        Irreversible = [bool](Get-WtBridgeProp -Object $Row -Name 'Irreversible')
        DataDeletion = [bool](Get-WtBridgeProp -Object $Row -Name 'DataDeletion')
        ReducesProtection = [bool](Get-WtBridgeProp -Object $Row -Name 'ReducesProtection')
        StateNames = @(Get-WtBridgeProp -Object $Row -Name 'StateNames')
        DefaultState = [string](Get-WtBridgeProp -Object $Row -Name 'DefaultState')
        Requires = @(Get-WtBridgeProp -Object $Row -Name 'Requires')
        State = [string](Get-WtBridgeProp -Object $Row -Name 'State')
        Details = [string](Get-WtBridgeProp -Object $Row -Name 'Details')
        Supported = [bool](Get-WtBridgeProp -Object $Row -Name 'Supported')
        UnsupportedReason = [string](Get-WtBridgeProp -Object $Row -Name 'UnsupportedReason')
        Lifecycle = [string](Get-WtBridgeProp -Object $Row -Name 'Lifecycle')
        ApplyAllowed = Get-WtBridgeProp -Object $Row -Name 'ApplyAllowed'
        Managed = [bool](Get-WtBridgeProp -Object $Row -Name 'Managed')
        ManagedBy = @(Get-WtBridgeProp -Object $Row -Name 'ManagedBy')
        Note = ConvertTo-WtBridgeText -Value (Get-WtBridgeProp -Object $Row -Name 'Note')
        Parameters = @($Parameters)
        ManagedPolicy = @($ManagedPolicy)
        CapabilityLoss = $CapabilityLoss
    }
}

<#
.SYNOPSIS
    Projects a catalog definition view row (Get-WtTweakDefinitionView).
#>
function ConvertTo-WtBridgeCatalogRow
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Row)

    return [ordered]@{
        Id = [string](Get-WtBridgeProp -Object $Row -Name 'Id')
        Category = [string](Get-WtBridgeProp -Object $Row -Name 'Category')
        DisplayName = ConvertTo-WtBridgeText -Value (Get-WtBridgeProp -Object $Row -Name 'DisplayName')
        Name = ConvertTo-WtBridgeText -Value (Get-WtBridgeProp -Object $Row -Name 'Name')
        Lifecycle = [string](Get-WtBridgeProp -Object $Row -Name 'Lifecycle')
        Scope = [string](Get-WtBridgeProp -Object $Row -Name 'Scope')
        Privilege = [string](Get-WtBridgeProp -Object $Row -Name 'Privilege')
        Risk = [string](Get-WtBridgeProp -Object $Row -Name 'Risk')
        Restart = [string](Get-WtBridgeProp -Object $Row -Name 'Restart')
        Rollback = [string](Get-WtBridgeProp -Object $Row -Name 'Rollback')
        States = @(Get-WtBridgeProp -Object $Row -Name 'States')
        DefaultState = [string](Get-WtBridgeProp -Object $Row -Name 'DefaultState')
        Source = [string](Get-WtBridgeProp -Object $Row -Name 'Source')
        PackId = [string](Get-WtBridgeProp -Object $Row -Name 'PackId')
        Revision = Get-WtBridgeProp -Object $Row -Name 'Revision'
        Support = [string](Get-WtBridgeProp -Object $Row -Name 'Support')
        Requires = @(Get-WtBridgeProp -Object $Row -Name 'Requires')
        RunAfter = @(Get-WtBridgeProp -Object $Row -Name 'RunAfter')
        ConflictsWith = @(Get-WtBridgeProp -Object $Row -Name 'ConflictsWith')
        Tags = @(Get-WtBridgeProp -Object $Row -Name 'Tags')
    }
}

<#
.SYNOPSIS
    Projects one preview target row (Get-WtChangePreview -> Targets[]).
#>
function ConvertTo-WtBridgePreviewTarget
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Target)

    $Current = Get-WtBridgeProp -Object $Target -Name 'Current'
    $Intended = Get-WtBridgeProp -Object $Target -Name 'Intended'
    $Recovery = Get-WtBridgeProp -Object $Target -Name 'Recovery'

    return [ordered]@{
        Identity = [string](Get-WtBridgeProp -Object $Target -Name 'Identity')
        Label = [string](Get-WtBridgeProp -Object $Target -Name 'Label')
        Class = [string](Get-WtBridgeProp -Object $Target -Name 'Class')
        Operation = [string](Get-WtBridgeProp -Object $Target -Name 'Operation')
        Current = [ordered]@{
            ValueKind = ConvertTo-WtBridgeText -Value (Get-WtBridgeProp -Object $Current -Name 'ValueKind')
            Type = [string](Get-WtBridgeProp -Object $Current -Name 'Type')
            Display = ConvertTo-WtBridgeText -Value (Get-WtBridgeProp -Object $Current -Name 'Display')
            Reason = ConvertTo-WtBridgeText -Value (Get-WtBridgeProp -Object $Current -Name 'Reason')
            Readable = Get-WtBridgeProp -Object $Current -Name 'Readable'
        }
        Intended = [ordered]@{
            Kind = [string](Get-WtBridgeProp -Object $Intended -Name 'Kind')
            Type = [string](Get-WtBridgeProp -Object $Intended -Name 'Type')
            Display = ConvertTo-WtBridgeText -Value (Get-WtBridgeProp -Object $Intended -Name 'Display')
            Operation = [string](Get-WtBridgeProp -Object $Intended -Name 'Operation')
        }
        Recovery = [ordered]@{
            Rollback = [string](Get-WtBridgeProp -Object $Recovery -Name 'Rollback')
            Irreversible = [bool](Get-WtBridgeProp -Object $Recovery -Name 'Irreversible')
            DataDeletion = [bool](Get-WtBridgeProp -Object $Recovery -Name 'DataDeletion')
            BaselinePreserved = [bool](Get-WtBridgeProp -Object $Recovery -Name 'BaselinePreserved')
        }
    }
}

<#
.SYNOPSIS
    Projects a preview object (Get-WtChangePreview).
#>
function ConvertTo-WtBridgePreview
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Preview)

    $Targets = @()
    foreach ($Target in @(Get-WtBridgeProp -Object $Preview -Name 'Targets')) { $Targets += (ConvertTo-WtBridgePreviewTarget -Target $Target) }
    $Conflicts = @()
    foreach ($Conflict in @(Get-WtBridgeProp -Object $Preview -Name 'Conflicts')) {
        $Conflicts += [ordered]@{
            Kind = [string](Get-WtBridgeProp -Object $Conflict -Name 'Kind')
            Message = ConvertTo-WtBridgeText -Value (Get-WtBridgeProp -Object $Conflict -Name 'Message')
        }
    }
    $Support = Get-WtBridgeProp -Object $Preview -Name 'Support'
    $Recovery = Get-WtBridgeProp -Object $Preview -Name 'Recovery'

    return [ordered]@{
        TweakId = [string](Get-WtBridgeProp -Object $Preview -Name 'TweakId')
        State = [string](Get-WtBridgeProp -Object $Preview -Name 'State')
        Supported = [bool](Get-WtBridgeProp -Object $Preview -Name 'Supported')
        SupportReason = ConvertTo-WtBridgeText -Value (Get-WtBridgeProp -Object $Support -Name 'Reason')
        Scope = [string](Get-WtBridgeProp -Object $Preview -Name 'Scope')
        Privilege = [string](Get-WtBridgeProp -Object $Preview -Name 'Privilege')
        Restart = [string](Get-WtBridgeProp -Object $Preview -Name 'Restart')
        Irreversible = [bool](Get-WtBridgeProp -Object $Preview -Name 'Irreversible')
        Lifecycle = [string](Get-WtBridgeProp -Object $Preview -Name 'Lifecycle')
        Complete = Get-WtBridgeProp -Object $Preview -Name 'Complete'
        DetectedState = [string](Get-WtBridgeProp -Object $Preview -Name 'DetectedState')
        Fingerprint = [string](Get-WtBridgeProp -Object $Preview -Name 'Fingerprint')
        ReviewedUtc = [string](Get-WtBridgeProp -Object $Preview -Name 'ReviewedUtc')
        Recovery = [ordered]@{
            Rollback = [string](Get-WtBridgeProp -Object $Recovery -Name 'Rollback')
            Irreversible = [bool](Get-WtBridgeProp -Object $Recovery -Name 'Irreversible')
            DataDeletion = [bool](Get-WtBridgeProp -Object $Recovery -Name 'DataDeletion')
            Restart = [string](Get-WtBridgeProp -Object $Recovery -Name 'Restart')
        }
        Messages = @(Get-WtBridgeProp -Object $Preview -Name 'Messages')
        Targets = @($Targets)
        Conflicts = @($Conflicts)
    }
}

<#
.SYNOPSIS
    Projects one history row (Get-WtHistory).
#>
function ConvertTo-WtBridgeHistoryRow
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Row)

    return [ordered]@{
        HistoryId = [string](Get-WtBridgeProp -Object $Row -Name 'HistoryId')
        OperationId = [string](Get-WtBridgeProp -Object $Row -Name 'HistoryId')
        TweakId = [string](Get-WtBridgeProp -Object $Row -Name 'TweakId')
        State = [string](Get-WtBridgeProp -Object $Row -Name 'State')
        Outcome = [string](Get-WtBridgeProp -Object $Row -Name 'Outcome')
        Timestamp = [string](Get-WtBridgeProp -Object $Row -Name 'Timestamp')
        RolledBack = [bool](Get-WtBridgeProp -Object $Row -Name 'RolledBack')
        RolledBackAt = Get-WtBridgeProp -Object $Row -Name 'RolledBackAt'
        RecordCount = Get-WtBridgeProp -Object $Row -Name 'RecordCount'
        Irreversible = [bool](Get-WtBridgeProp -Object $Row -Name 'Irreversible')
        Messages = @(Get-WtBridgeProp -Object $Row -Name 'Messages')
    }
}

<#
.SYNOPSIS
    Projects one journal operation row (Get-WtOperation).
#>
function ConvertTo-WtBridgeOperationRow
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Row)

    $Verification = Get-WtBridgeProp -Object $Row -Name 'verification'
    $Compensation = Get-WtBridgeProp -Object $Row -Name 'compensation'
    $TargetCount = @(Get-WtBridgeProp -Object $Row -Name 'targets').Count

    return [ordered]@{
        OperationId = [string](Get-WtBridgeProp -Object $Row -Name 'operationId')
        ParentOperationId = Get-WtBridgeProp -Object $Row -Name 'parentOperationId'
        SessionId = [string](Get-WtBridgeProp -Object $Row -Name 'sessionId')
        Sequence = Get-WtBridgeProp -Object $Row -Name 'sequence'
        Origin = [string](Get-WtBridgeProp -Object $Row -Name 'origin')
        Stage = [string](Get-WtBridgeProp -Object $Row -Name 'stage')
        TweakId = [string](Get-WtBridgeProp -Object $Row -Name 'tweakId')
        State = [string](Get-WtBridgeProp -Object $Row -Name 'state')
        Timestamp = [string](Get-WtBridgeProp -Object $Row -Name 'timestamp')
        UpdatedUtc = [string](Get-WtBridgeProp -Object $Row -Name 'updatedUtc')
        DryRun = [bool](Get-WtBridgeProp -Object $Row -Name 'dryRun')
        Outcome = [string](Get-WtBridgeProp -Object $Row -Name 'outcome')
        RolledBack = [bool](Get-WtBridgeProp -Object $Row -Name 'rolledBack')
        RolledBackAt = Get-WtBridgeProp -Object $Row -Name 'rolledBackAt'
        TargetCount = $TargetCount
        Messages = @(Get-WtBridgeProp -Object $Row -Name 'messages')
        Verified = [bool](Get-WtBridgeProp -Object $Verification -Name 'Attempted')
        VerifiedCount = Get-WtBridgeProp -Object $Verification -Name 'Verified'
        Mismatched = Get-WtBridgeProp -Object $Verification -Name 'Mismatched'
        Unverifiable = Get-WtBridgeProp -Object $Verification -Name 'Unverifiable'
        Compensated = [bool](Get-WtBridgeProp -Object $Compensation -Name 'Attempted')
    }
}

<#
.SYNOPSIS
    Projects one interrupted-operation row (Get-WtInterruptedOperation).
#>
function ConvertTo-WtBridgeInterruptedRow
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Row)

    $Targets = @()
    foreach ($Target in @(Get-WtBridgeProp -Object $Row -Name 'Targets')) {
        $Targets += [ordered]@{
            Identity = [string](Get-WtBridgeProp -Object $Target -Name 'Identity')
            Label = [string](Get-WtBridgeProp -Object $Target -Name 'Label')
            Intended = ConvertTo-WtBridgeText -Value (Get-WtBridgeProp -Object $Target -Name 'Intended')
            Live = ConvertTo-WtBridgeText -Value (Get-WtBridgeProp -Object $Target -Name 'Live')
            Classification = [string](Get-WtBridgeProp -Object $Target -Name 'Classification')
        }
    }

    return [ordered]@{
        OperationId = [string](Get-WtBridgeProp -Object $Row -Name 'OperationId')
        SessionId = [string](Get-WtBridgeProp -Object $Row -Name 'SessionId')
        TweakId = [string](Get-WtBridgeProp -Object $Row -Name 'TweakId')
        State = [string](Get-WtBridgeProp -Object $Row -Name 'State')
        Stage = [string](Get-WtBridgeProp -Object $Row -Name 'Stage')
        Timestamp = [string](Get-WtBridgeProp -Object $Row -Name 'Timestamp')
        CanRestore = [bool](Get-WtBridgeProp -Object $Row -Name 'CanRestore')
        Targets = @($Targets)
    }
}

<#
.SYNOPSIS
    Projects a batch apply result (one entry per requested tweak).
#>
function ConvertTo-WtBridgeApplyResult
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Result)

    $Journal = Get-WtBridgeProp -Object $Result -Name 'Journal'
    $Verification = Get-WtBridgeProp -Object $Result -Name 'Verification'
    $Compensation = Get-WtBridgeProp -Object $Result -Name 'Compensation'

    return [ordered]@{
        RequestedId = [string](Get-WtBridgeProp -Object $Result -Name 'RequestedId')
        RequestedState = [string](Get-WtBridgeProp -Object $Result -Name 'RequestedState')
        TweakId = [string](Get-WtBridgeProp -Object $Result -Name 'TweakId')
        Status = [string](Get-WtBridgeProp -Object $Result -Name 'Status')
        Outcome = [string](Get-WtBridgeProp -Object $Result -Name 'Outcome')
        Messages = @(Get-WtBridgeProp -Object $Result -Name 'Messages')
        Verified = [bool](Get-WtBridgeProp -Object $Verification -Name 'Attempted')
        VerifiedCount = Get-WtBridgeProp -Object $Verification -Name 'Verified'
        Mismatched = Get-WtBridgeProp -Object $Verification -Name 'Mismatched'
        Compensated = [bool](Get-WtBridgeProp -Object $Compensation -Name 'Attempted')
        JournalPersisted = [bool](Get-WtBridgeProp -Object $Journal -Name 'Persisted')
        JournalStopBatch = [bool](Get-WtBridgeProp -Object $Journal -Name 'StopBatch')
        JournalUncertainStage = [string](Get-WtBridgeProp -Object $Journal -Name 'UncertainStage')
    }
}

<#
.SYNOPSIS
    Projects a rollback/undo result (Undo-WtTweak).
#>
function ConvertTo-WtBridgeUndoResult
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Result)

    $Journal = Get-WtBridgeProp -Object $Result -Name 'Journal'

    return [ordered]@{
        Status = [string](Get-WtBridgeProp -Object $Result -Name 'Status')
        TweakId = [string](Get-WtBridgeProp -Object $Result -Name 'TweakId')
        HistoryId = [string](Get-WtBridgeProp -Object $Result -Name 'HistoryId')
        Messages = @(Get-WtBridgeProp -Object $Result -Name 'Messages')
        ReviewRequired = [bool](Get-WtBridgeProp -Object $Result -Name 'ReviewRequired')
        ExternalChanges = @(Get-WtBridgeProp -Object $Result -Name 'ExternalChanges')
        JournalPersisted = [bool](Get-WtBridgeProp -Object $Journal -Name 'Persisted')
        JournalStopBatch = [bool](Get-WtBridgeProp -Object $Journal -Name 'StopBatch')
    }
}
