# WindowsTweaker - deterministic dependency planning for the declarative catalog.
#
# A catalog definition may declare three relationships:
#
#   requires       a hard prerequisite: it must reach its state before this tweak runs;
#   runAfter       ordering only: if both are being applied, this one goes second;
#   conflictsWith  they must not be applied together.
#
# Planning is read-only and deterministic: the same selection always produces the same order
# (category, then id, as the tie-breaker), a cycle is reported instead of being broken
# silently, and every prerequisite is either already satisfied - in which case it is *excluded*
# from the apply set and is never rewritten - or it is added as a proposed change with the
# reason it was added. A prerequisite whose live state cannot be read is kept in the plan and
# reported as unreadable: "cannot read" is not "already done", and the apply performs its own
# verification.
#
# The plan is a review artefact. Nothing here writes anything, and the engine re-reads the
# live state before executing, so a plan can never authorize a change on its own.

<#
.SYNOPSIS
    Builds the dependency plan for a selection of tweak ids.
.PARAMETER Ids
    Selected tweak ids (or aliases, which resolve through the migration registry).
.PARAMETER State
    Optional map of tweak id -> requested state for the selected tweaks. A prerequisite is
    planned for its own default state.
.OUTPUTS
    @{ Items; Order; Errors; Warnings; Conflicts; Unresolved }
#>

<#
.SYNOPSIS
    Reads one catalog relationship list from a tweak, treating "absent" as empty.
.DESCRIPTION
    Only catalog-backed tweaks carry DefinitionRequires/RunAfter/ConflictsWith; a tweak written
    in PowerShell has no such property, and its value must be an empty list rather than a list
    holding a single null (which would be read as an id called '').
#>
function Get-WtDefinitionList
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param
    (
        [Parameter(Mandatory = $true)][object]$Tweak,
        [Parameter(Mandatory = $true)][ValidateSet('DefinitionRequires', 'DefinitionRunAfter', 'DefinitionConflictsWith')][string]$Name
    )

    if (-not $Tweak -or @($Tweak.PSObject.Properties.Name) -notcontains $Name)
    {
        return @()
    }

    return @(@($Tweak.$Name) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}

<#
.SYNOPSIS
    Builds the dependency plan for a selection of tweak ids.
.PARAMETER Ids
    Selected tweak ids (or aliases, which resolve through the migration registry).
.PARAMETER State
    Optional map of tweak id -> requested state for the selected tweaks. A prerequisite is
    planned for its own default state.
.OUTPUTS
    @{ Items; Order; Errors; Warnings; Conflicts; Unresolved }
#>
function Get-WtDependencyPlanInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string[]]$Ids,
        [Parameter(Mandatory = $false)][hashtable]$State = @{}
    )

    $Items = [ordered]@{}
    $Errors = [System.Collections.Generic.List[string]]::new()
    $Warnings = [System.Collections.Generic.List[string]]::new()
    $Conflicts = [System.Collections.Generic.List[object]]::new()
    $Unresolved = [System.Collections.Generic.List[string]]::new()

    # 1. Resolve the selection. An id that does not exist is reported, never dropped.
    $Selected = [System.Collections.Generic.List[string]]::new()
    foreach ($RawId in $Ids)
    {
        $Id = [string]$RawId
        if ([string]::IsNullOrWhiteSpace($Id)) { continue }

        $Resolved = Resolve-WtTweakIdInternal -Id $Id
        if (-not $Resolved.Tweak)
        {
            $Unresolved.Add($Id)
            $Errors.Add("Unknown tweak id: $Id")
            continue
        }

        if ($Resolved.Migrated)
        {
            $Warnings.Add("$Id was renamed to $($Resolved.Id); the plan uses the current id.")
        }

        if ($Resolved.Tweak.Lifecycle -in 'Unsupported', 'Restore-only', 'Deprecated')
        {
            $Errors.Add("$Id is $($Resolved.Tweak.Lifecycle) and cannot be applied.")
            continue
        }

        $Selected.Add($Resolved.Id)
        $Items[$Resolved.Id] = @{
            Id            = $Resolved.Id
            Requested     = $Id
            Source        = 'Selected'
            Action        = 'Apply'
            State         = if ($State.ContainsKey($Id)) { [string]$State[$Id] } elseif ($State.ContainsKey($Resolved.Id)) { [string]$State[$Resolved.Id] } else { $Resolved.Tweak.DefaultState }
            Satisfied     = $false
            ObservedState = $null
            Reason        = ''
            Requires      = @(Get-WtDefinitionList -Tweak $Resolved.Tweak -Name 'DefinitionRequires')
            RunAfter      = @(Get-WtDefinitionList -Tweak $Resolved.Tweak -Name 'DefinitionRunAfter')
            ConflictsWith = @(Get-WtDefinitionList -Tweak $Resolved.Tweak -Name 'DefinitionConflictsWith')
        }
    }

    # 2. Close over the hard prerequisites, breadth-first and deterministic.
    $Queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($Id in $Selected) { $Queue.Enqueue($Id) }
    $Seen = @{}
    foreach ($Id in $Selected) { $Seen[$Id] = $true }

    while ($Queue.Count -gt 0)
    {
        $CurrentId = $Queue.Dequeue()
        $Current = Get-WtTweakInternal -Id $CurrentId | Select-Object -First 1
        if (-not $Current) { continue }

        foreach ($DependencyId in @(Get-WtDefinitionList -Tweak $Current -Name 'DefinitionRequires'))
        {
            $Dependency = Resolve-WtTweakIdInternal -Id $DependencyId
            if (-not $Dependency.Tweak)
            {
                $Unresolved.Add($DependencyId)
                $Errors.Add("$CurrentId requires '$DependencyId', which does not exist in this catalog.")
                continue
            }

            if ($Dependency.Tweak.Lifecycle -in 'Unsupported', 'Deprecated')
            {
                $Errors.Add("$CurrentId requires '$DependencyId', which is $($Dependency.Tweak.Lifecycle).")
                continue
            }

            if ($Items.Contains($Dependency.Id)) { continue }

            $Items[$Dependency.Id] = @{
                Id            = $Dependency.Id
                Requested     = $DependencyId
                Source        = 'Prerequisite'
                Action        = 'Apply'
                State         = $Dependency.Tweak.DefaultState
                Satisfied     = $false
                ObservedState = $null
                Reason        = "Required by $CurrentId."
                Requires      = @(Get-WtDefinitionList -Tweak $Dependency.Tweak -Name 'DefinitionRequires')
                RunAfter      = @(Get-WtDefinitionList -Tweak $Dependency.Tweak -Name 'DefinitionRunAfter')
                ConflictsWith = @(Get-WtDefinitionList -Tweak $Dependency.Tweak -Name 'DefinitionConflictsWith')
            }

            if (-not $Seen.ContainsKey($Dependency.Id))
            {
                $Seen[$Dependency.Id] = $true
                $Queue.Enqueue($Dependency.Id)
            }
        }
    }

    # 3. A prerequisite that is already at its default state is excluded from the apply set:
    #    it is not rewritten, and it is not reported as part of the change.
    foreach ($Id in @($Items.Keys))
    {
        if ($Items[$Id].Source -ne 'Prerequisite') { continue }

        $Tweak = Get-WtTweakInternal -Id $Id | Select-Object -First 1
        $Observed = $null
        try
        {
            $Observed = Get-WtTweakState -Id $Id
        }
        catch
        {
            $Observed = $null
        }

        $ObservedState = if ($Observed) { [string]$Observed.State } else { '' }
        $Items[$Id].ObservedState = $ObservedState

        if ($ObservedState -eq $Tweak.DefaultState)
        {
            $Items[$Id].Satisfied = $true
            $Items[$Id].Action = 'Skip-Satisfied'
            $Items[$Id].Reason = "Already at '$($Tweak.DefaultState)'; it is not changed."
        }
        elseif ($ObservedState -in '', 'Unknown', 'Unsupported')
        {
            $Items[$Id].Reason = "Required by the selection; its current state could not be read ($(if ($ObservedState) { $ObservedState } else { 'no result' })), so it is left in the plan and verified when it runs."
            $Warnings.Add("${Id}: current state could not be read; it stays in the plan.")
        }
    }

    # 4. Conflicts inside the planned set, in both directions, reported once per pair.
    $PlannedIds = @($Items.Keys)
    $Reported = @{}
    foreach ($Id in $PlannedIds)
    {
        foreach ($OtherId in @($Items[$Id].ConflictsWith))
        {
            $Other = Resolve-WtTweakIdInternal -Id $OtherId
            if (-not $Other.Tweak) { continue }
            if ($PlannedIds -notcontains $Other.Id) { continue }

            $Key = (@($Id, $Other.Id) | Sort-Object) -join '|'
            if ($Reported.ContainsKey($Key)) { continue }
            $Reported[$Key] = $true

            $Conflicts.Add(@{ Left = $Id; Right = $Other.Id })
            $Errors.Add("$Id and $($Other.Id) conflict with each other and cannot be applied together.")
        }
    }

    # 5. Deterministic topological order over requires + runAfter.
    $Order = [System.Collections.Generic.List[string]]::new()
    $Mark = @{}
    $Path = [System.Collections.Generic.List[string]]::new()

    function Resolve-WtPlanNode
    {
        param ([string]$NodeId, $ItemsTable, $MarkTable, $OrderList, $PathList)

        if ($MarkTable.ContainsKey($NodeId))
        {
            if ($MarkTable[$NodeId] -eq 'done') { return $true }
            if ($MarkTable[$NodeId] -eq 'active')
            {
                $Cycle = (@($PathList) + $NodeId) -join ' -> '
                return $Cycle
            }
        }

        $MarkTable[$NodeId] = 'active'
        $PathList.Add($NodeId)

        $Item = $ItemsTable[$NodeId]
        $Edges = @()
        foreach ($Edge in @($Item.Requires) + @($Item.RunAfter))
        {
            $ResolvedEdge = Resolve-WtTweakIdInternal -Id $Edge
            if ($ResolvedEdge.Tweak -and $ItemsTable.Contains($ResolvedEdge.Id) -and $ResolvedEdge.Id -ne $NodeId)
            {
                $Edges += $ResolvedEdge.Id
            }
        }

        foreach ($Edge in @($Edges | Sort-Object -Unique))
        {
            $Result = Resolve-WtPlanNode -NodeId $Edge -ItemsTable $ItemsTable -MarkTable $MarkTable -OrderList $OrderList -PathList $PathList
            if ($Result -is [string]) { return $Result }
        }

        [void]$PathList.RemoveAt($PathList.Count - 1)
        $MarkTable[$NodeId] = 'done'
        $OrderList.Add($NodeId)
        return $true
    }

    foreach ($Id in @($Items.Keys | Sort-Object { $Items[$_].Source } -Descending | Sort-Object))
    {
        # Sorting by id twice keeps the order stable: prerequisites are visited first only
        # through their edges, never through the iteration order.
        $Result = Resolve-WtPlanNode -NodeId $Id -ItemsTable $Items -MarkTable $Mark -OrderList $Order -PathList $Path
        if ($Result -is [string])
        {
            $Errors.Add("Dependency cycle: $Result")
        }
    }

    return @{
        Items      = @($Order | ForEach-Object { $Items[$_] })
        Order      = @($Order)
        Errors     = @($Errors.ToArray())
        Warnings   = @($Warnings.ToArray())
        Conflicts  = @($Conflicts.ToArray())
        Unresolved = @($Unresolved.ToArray())
    }
}

<#
.SYNOPSIS
    Lists the journal entries that would become inconsistent if a tweak were rolled back now.
.DESCRIPTION
    A prerequisite is applied for the sake of the tweaks that require it. Undoing it while
    those are still applied would leave them in a state they were never reviewed for, so this
    lists them first: the rollback is not forbidden, but the impact is named before it happens.
.OUTPUTS
    @{ Id; Dependents; Warnings }
#>
function Get-WtRestoreImpactInternal
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Id)

    $Dependents = [System.Collections.Generic.List[object]]::new()
    $Warnings = [System.Collections.Generic.List[string]]::new()

    $Tweak = Get-WtTweakInternal -Id $Id | Select-Object -First 1
    if (-not $Tweak)
    {
        return @{ Id = $Id; Dependents = @(); Warnings = @("Unknown tweak id: $Id") }
    }

    # Who in the catalog declares a dependency on this tweak?
    $DependentsInCatalog = @($Script:WtCatalog.Values | Where-Object {
            @(Get-WtDefinitionList -Tweak $_ -Name 'DefinitionRequires') -contains $Id
        } | Select-Object -ExpandProperty Id)

    if ($DependentsInCatalog.Count -eq 0)
    {
        return @{ Id = $Id; Dependents = @(); Warnings = @() }
    }

    $Store = Read-WtStateStore
    if ($Store -and -not $Store.Corrupt)
    {
        foreach ($Entry in @($Store.History))
        {
            if ($Entry.rolledBack) { continue }
            if ($DependentsInCatalog -notcontains [string]$Entry.tweakId) { continue }

            $Dependents.Add([pscustomobject]@{
                    HistoryId  = [string]$Entry.historyId
                    TweakId    = [string]$Entry.tweakId
                    CreatedUtc = [string]$Entry.createdUtc
                })
        }
    }

    if ($Dependents.Count -gt 0)
    {
        $Warnings.Add("$Id is a prerequisite of $(@($Dependents | Select-Object -ExpandProperty TweakId -Unique) -join ', '), which are still applied.")
    }

    return @{ Id = $Id; Dependents = @($Dependents.ToArray()); Warnings = @($Warnings.ToArray()) }
}
