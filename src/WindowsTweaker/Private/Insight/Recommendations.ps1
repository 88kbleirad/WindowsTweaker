# WindowsTweaker - the recommendation policy.
#
# A recommendation is a *proposal*, never an action. This file ranks nothing, scores nothing and
# applies nothing: it walks the catalog and explains, for every item it considered, why it is
# recommended, already satisfied, excluded, unknown or blocked.
#
# Two rules shape everything below:
#
#   * eligibility is not evidence, not risk and not user intent. A document may *ask* to be
#     considered (`recommendation.policy`), and the engine decides - from the definition's own
#     flags, its recovery limits, the evidence that can be vouched for and the objective the user
#     asked for - whether that request is honoured. An imported pack is never honoured: its
#     metadata is an author claim, so a pack can be manual at best.
#   * an objective is defined independently. If no candidate serves it, the answer is "nothing
#     qualifies", never a silent substitution with another objective's items.
#
# Preferences (themes, animations, what the interface shows) are manual unless the user explicitly
# asks for preferences, and the Gaming objective never takes them at all: this engine does not
# claim that hiding UI elements or turning off animations makes a game run faster.

# Each objective is its own filter: the kinds it accepts, whether it takes preference items at all,
# and its own description key. A repair is admitted by every objective because a repair is a
# response to an observed finding - which objective it serves is decided by the objectives the
# definition itself names, not by a second list here.
$Script:WtObjectivePolicy = @{
    Balanced        = @{
        Kinds            = @('Optimization', 'Repair')
        Description      = 'Rec.Objective.Balanced'
        AllowPreferences = $true
    }
    Responsiveness  = @{
        Kinds            = @('Optimization', 'Repair')
        Description      = 'Rec.Objective.Responsiveness'
        AllowPreferences = $false
    }
    Gaming          = @{
        Kinds            = @('Optimization', 'Repair')
        Description      = 'Rec.Objective.Gaming'
        AllowPreferences = $false
    }
    PowerEfficiency = @{
        Kinds            = @('Optimization', 'Repair')
        Description      = 'Rec.Objective.PowerEfficiency'
        AllowPreferences = $false
    }
    Privacy         = @{
        Kinds            = @('Optimization', 'Repair')
        Description      = 'Rec.Objective.Privacy'
        AllowPreferences = $false
    }
}

<#
.SYNOPSIS
    Reports whether an observed finding satisfies what a repair asks for.
.DESCRIPTION
    A repair names the finding it addresses as '<rule id>' or '<rule id>/<probe id>'. The qualified
    form pins the repair to the one probe whose finding it actually fixes; a bare rule id is a
    rule-level observation and matches any finding of that rule, which is what a caller can pass
    when only the rule ids are known.
#>
function Test-WtFindingMatchInternal
{
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Requires,
        [Parameter(Mandatory = $false)][string[]]$Finding = @()
    )

    if (-not $Requires) { return $false }

    $RequiredRule = $Requires.Split('/')[0]
    foreach ($Observed in @($Finding))
    {
        if (-not $Observed) { continue }
        if ($Observed -eq $Requires) { return $true }
        if ($Observed.Split('/')[0] -ne $RequiredRule) { continue }
        if ($Requires -notmatch '/' -or $Observed -notmatch '/') { return $true }
    }

    return $false
}

<#
.SYNOPSIS
    Reports whether this engine can read a change back after it is applied.
.DESCRIPTION
    Verification is a required gate, not an assumption: a recommendation is only a candidate when
    every target of the state it would apply has a read-back reader implemented on this platform.
    A scripted change is not judged here at all - its targets are only known once it has run - so
    it is reported as unsupported-for-automatic-selection with its reason, never as verified.
.OUTPUTS
    @{ Supported; Known; ReasonKey; Targets }
#>
function Test-WtVerificationSupportedInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Tweak,
        [Parameter(Mandatory = $false)][string]$State
    )

    if (-not $State) { $State = [string]$Tweak.DefaultState }

    $Result = @{ Supported = $true; Known = $true; ReasonKey = ''; Targets = @() }

    $Declared = @($Tweak.PSObject.Properties.Name) -contains 'States' -and $Tweak.States -and $Tweak.States.ContainsKey($State)
    if (-not $Declared)
    {
        # A scripted change names its targets while it runs, so nothing here can promise a read-back.
        return @{ Supported = $false; Known = $false; ReasonKey = 'Rec.Unknown.VerificationScript'; Targets = @() }
    }

    $WithoutReader = [System.Collections.Generic.List[string]]::new()
    foreach ($Operation in @(Get-WtDeclaredOperation -Tweak $Tweak -State $State))
    {
        if ($Operation -isnot [hashtable]) { continue }

        $Identity = Get-WtOperationIdentity -Operation $Operation
        if (-not $Identity)
        {
            $WithoutReader.Add('a target this operation does not name')
            continue
        }

        $TargetState = Get-WtTargetState -Identity $Identity
        if (-not $TargetState.Reader) { $WithoutReader.Add([string]$TargetState.Label) }
    }

    if ($WithoutReader.Count -gt 0)
    {
        return @{ Supported = $false; Known = $true; ReasonKey = 'Rec.Unknown.Verification'; Targets = @($WithoutReader.ToArray()) }
    }

    return $Result
}

<#
.SYNOPSIS
    Decides the engine policy for one tweak, without looking at what the document claims.
.DESCRIPTION
    Returns the claim (kind, policy, objectives) together with the engine's verdict on whether the
    item may be selected automatically. The verdict is 'Allowed', 'Manual' or 'Never'; every
    'Manual' and 'Never' carries the reason key that explains it, so the interface can say why an
    item is not recommended instead of quietly leaving it out.
.PARAMETER Finding
    Findings the caller has observed, as '<rule id>' or '<rule id>/<probe id>'. A repair is only
    judged on its finding: with the finding it addresses present it becomes a candidate, without
    it the engine refuses to offer it as one.
.OUTPUTS
    @{ Declared; Kind; Policy; Objectives; Rationale; RequiresFinding; Documented; Verdict;
       ReasonKey; ReasonArgs }
#>
function Get-WtRecommendationPolicyInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Tweak,
        [Parameter(Mandatory = $false)][string[]]$Finding = @()
    )

    $Result = @{
        Declared       = $false
        Kind           = ''
        Policy         = 'Manual'
        Objectives     = @()
        Rationale      = $null
        RequiresFinding = ''
        Documented     = $false
        Verdict        = 'Never'
        ReasonKey      = 'Rec.Excluded.NoMetadata'
        ReasonArgs     = @($Tweak.Id)
    }

    $HasBlock = @($Tweak.PSObject.Properties.Name) -contains 'DefinitionRecommendation'
    $Declared = if ($HasBlock) { $Tweak.DefinitionRecommendation } else { $null }

    if (-not $Declared)
    {
        return $Result
    }

    $Result.Declared = $true
    $Result.Kind = [string]$Declared.Kind
    $Result.Policy = [string]$Declared.Policy
    $Result.Objectives = @($Declared.Objectives)
    $Result.Rationale = $Declared.Rationale
    $Result.RequiresFinding = [string]$Declared.RequiresFinding
    $Result.Documented = [bool]$Declared.Documented

    $Source = if (@($Tweak.PSObject.Properties.Name) -contains 'DefinitionSource') { [string]$Tweak.DefinitionSource } else { 'BuiltIn' }

    # The engine's floors, in the order a reviewer would ask about them.
    if ($Result.Policy -eq 'Never')
    {
        $Result.Verdict = 'Never'
        $Result.ReasonKey = 'Rec.Excluded.Never'
        return $Result
    }

    if ($Result.Kind -notin $Script:WtRecommendationKinds -or $Result.Policy -notin $Script:WtRecommendationPolicies)
    {
        # A document that cannot say what it is, is not recommended.
        $Result.Verdict = 'Never'
        $Result.ReasonKey = 'Rec.Excluded.InvalidMetadata'
        return $Result
    }

    if ($Tweak.Lifecycle -ne 'Available')
    {
        $Result.Verdict = 'Never'
        $Result.ReasonKey = 'Rec.Excluded.Lifecycle'
        $Result.ReasonArgs = @($Tweak.Id, [string]$Tweak.Lifecycle)
        return $Result
    }

    if ($Tweak.ReducesProtection)
    {
        $Result.Verdict = 'Never'
        $Result.ReasonKey = 'Rec.Excluded.Protection'
        $Result.ReasonArgs = @($Tweak.Id)
        return $Result
    }

    if ($Tweak.Irreversible -or $Tweak.DataDeletion -or [string]$Tweak.Rollback -ne 'Full' -or [string]$Tweak.Risk -eq 'High')
    {
        $Result.Verdict = 'Never'
        $Result.ReasonKey = 'Rec.Excluded.Recovery'
        $Result.ReasonArgs = @($Tweak.Id, [string]$Tweak.Rollback)
        return $Result
    }

    if ($Source -eq 'Pack')
    {
        # A pack cannot grant itself trust: what its document says about evidence and risk is an
        # author claim, so an imported definition is offered, never selected automatically.
        $Result.Verdict = 'Manual'
        $Result.ReasonKey = 'Rec.Excluded.PackClaim'
        $Result.ReasonArgs = @($Tweak.Id)
        return $Result
    }

    $Support = Get-WtSupportStatusInternal -Tweak $Tweak
    if ($Support -in 'Unsupported', 'AuthorClaimed', 'Unverified')
    {
        $Result.Verdict = 'Manual'
        $Result.ReasonKey = 'Rec.Excluded.Evidence'
        $Result.ReasonArgs = @($Tweak.Id, $Support)
        return $Result
    }

    if ($Result.Kind -eq 'Repair' -and -not $Result.RequiresFinding)
    {
        # A repair that does not name the finding it fixes cannot be judged at all.
        $Result.Verdict = 'Never'
        $Result.ReasonKey = 'Rec.Excluded.InvalidMetadata'
        $Result.ReasonArgs = @($Tweak.Id)
        return $Result
    }

    if ($Result.Kind -eq 'Diagnostic')
    {
        $Result.Verdict = 'Manual'
        $Result.ReasonKey = 'Rec.Excluded.Diagnostic'
        $Result.ReasonArgs = @($Tweak.Id)
        return $Result
    }

    if ($Result.Kind -eq 'Preference')
    {
        $Result.Verdict = 'Manual'
        $Result.ReasonKey = 'Rec.Excluded.Preference'
        $Result.ReasonArgs = @($Tweak.Id)
        return $Result
    }

    if ($Result.Kind -eq 'Repair')
    {
        # A repair follows an observed finding, never an unapplied tweak: without the finding it
        # is not even offered as a candidate, and with it the item is judged like any other.
        if (-not (Test-WtFindingMatchInternal -Requires $Result.RequiresFinding -Finding $Finding))
        {
            $Result.Verdict = 'Manual'
            $Result.ReasonKey = 'Rec.Excluded.RepairNeedsFinding'
            $Result.ReasonArgs = @($Tweak.Id, $Result.RequiresFinding)
            return $Result
        }

        # The finding is present, so the item continues to the same floors as any other candidate
        # (policy, objectives and rationale below); it earns no exemption for being a repair.
    }

    if ($Result.Policy -eq 'Manual')
    {
        $Result.Verdict = 'Manual'
        $Result.ReasonKey = 'Rec.Excluded.Manual'
        $Result.ReasonArgs = @($Tweak.Id)
        return $Result
    }

    if ($Result.Objectives.Count -eq 0 -or -not $Result.Rationale)
    {
        $Result.Verdict = 'Never'
        $Result.ReasonKey = 'Rec.Excluded.InvalidMetadata'
        $Result.ReasonArgs = @($Tweak.Id)
        return $Result
    }

    # 'documented' is the author's statement that the rationale rests on the referenced pages
    # instead of on an opinion. It is claimed in the document and judged here, and it decides
    # exactly one thing: an item that cannot assert it is offered, never selected automatically.
    if (-not $Result.Documented)
    {
        $Result.Verdict = 'Manual'
        $Result.ReasonKey = 'Rec.Excluded.Undocumented'
        $Result.ReasonArgs = @($Tweak.Id)
        return $Result
    }

    $Result.Verdict = 'Allowed'
    $Result.ReasonKey = 'Rec.Recommended'
    $Result.ReasonArgs = @($Tweak.Id)
    return $Result
}

<#
.SYNOPSIS
    Builds a recommendation proposal for one objective.
.DESCRIPTION
    Read-only with one exception that is still read-only: it reads live state to decide whether an
    item is already satisfied, and it runs the dependency planner to decide whether the proposal
    can be applied as a whole. It never adds anything to the pending set.
.PARAMETER Objective
    Balanced, Responsiveness, Gaming, PowerEfficiency or Privacy.
.PARAMETER IncludeManual
    Also report items the engine keeps out of automatic selection, with the reason.
.PARAMETER IncludePreferences
    Treat preference items as eligible for consideration (never for the Gaming objective).
.PARAMETER Finding
    Sanity rule ids with an observed finding, which unlock repair recommendations.
.OUTPUTS
    @{ Objective; Items; Recommended; Counts; Plan; Errors; ObjectiveDescription }
#>
function Get-WtRecommendationInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Objective,
        [Parameter(Mandatory = $false)][switch]$IncludeManual,
        [Parameter(Mandatory = $false)][switch]$IncludePreferences,
        [Parameter(Mandatory = $false)][string[]]$Finding = @(),
        [Parameter(Mandatory = $false)][hashtable]$Arguments = @{}
    )

    $Items = [System.Collections.Generic.List[object]]::new()
    $Errors = [System.Collections.Generic.List[string]]::new()

    if (-not $Script:WtObjectivePolicy.ContainsKey($Objective))
    {
        $Errors.Add((Get-WtString -Key 'Rec.UnknownObjective' -Arguments @($Objective, (($Script:WtObjectivePolicy.Keys | Sort-Object) -join ', '))))
        return @{ Objective = $Objective; Items = @(); Recommended = @(); Counts = @{}; Plan = $null; Errors = @($Errors.ToArray()) }
    }

    $Policy = $Script:WtObjectivePolicy[$Objective]
    $Pending = Get-WtPendingRestartInternal

    foreach ($Tweak in @($Script:WtCatalog.Values | Sort-Object -Property Category, Id))
    {
        $Item = [ordered]@{
            Id            = [string]$Tweak.Id
            Category      = [string]$Tweak.Category
            Name          = $Tweak.Name
            Kind          = ''
            Policy        = ''
            Objectives    = @()
            Decision      = 'Excluded'
            ReasonKey     = ''
            ReasonArgs    = @()
            Rationale     = $null
            TargetState   = [string]$Tweak.DefaultState
            Support       = ''
            Risk          = [string]$Tweak.Risk
            Rollback      = [string]$Tweak.Rollback
            Configured    = 'Unsupported'
            Effective     = 'Unknown'
            EffectiveEvidence = 'Unknown'
            Ownership     = 'Unmanaged'
            Verification  = 'Supported'
            Group         = if (@($Tweak.PSObject.Properties.Name) -contains 'DefinitionGroup') { $Tweak.DefinitionGroup } else { $null }
            Tweak         = $Tweak
        }

        $Engine = Get-WtRecommendationPolicyInternal -Tweak $Tweak -Finding $Finding
        $Item.Kind = $Engine.Kind
        $Item.Policy = $Engine.Policy
        $Item.Objectives = @($Engine.Objectives)
        $Item.Rationale = $Engine.Rationale
        $Item.Support = Get-WtSupportStatusInternal -Tweak $Tweak

        # First decision: the engine policy.
        if ($Engine.Verdict -eq 'Never')
        {
            $Item.Decision = 'Excluded'
            $Item.ReasonKey = $Engine.ReasonKey
            $Item.ReasonArgs = @($Engine.ReasonArgs)
            $Items.Add([pscustomobject]$Item)
            continue
        }

        if ($Engine.Verdict -eq 'Manual')
        {
            $Manual = $Engine.ReasonKey -eq 'Rec.Excluded.Preference' -and $IncludePreferences -and $Objective -ne 'Gaming'
            if (-not $Manual)
            {
                $Item.Decision = 'Excluded'
                $Item.ReasonKey = $Engine.ReasonKey
                $Item.ReasonArgs = @($Engine.ReasonArgs)
                if ($IncludeManual) { $Items.Add([pscustomobject]$Item) }
                continue
            }
        }

        # The objective has to have been chosen deliberately by the author for *this* objective.
        if (@($Engine.Objectives) -notcontains $Objective)
        {
            $Item.Decision = 'Excluded'
            $Item.ReasonKey = 'Rec.Excluded.Objective'
            $Item.ReasonArgs = @($Tweak.Id, $Objective, (@($Engine.Objectives) -join ', '))
            if ($IncludeManual) { $Items.Add([pscustomobject]$Item) }
            continue
        }

        # A preference is only considered when the user asked for preferences and the objective
        # allows them; the Gaming objective never does, and no objective turns a preference into
        # a performance claim.
        $PreferenceAllowed = ($Engine.Kind -eq 'Preference' -and $IncludePreferences -and $Policy.AllowPreferences -and $Objective -ne 'Gaming')

        if ($Engine.Kind -notin @($Policy.Kinds) -and -not $PreferenceAllowed)
        {
            $Item.Decision = 'Excluded'
            $Item.ReasonKey = 'Rec.Excluded.Kind'
            $Item.ReasonArgs = @($Tweak.Id, $Engine.Kind, $Objective)
            if ($IncludeManual) { $Items.Add([pscustomobject]$Item) }
            continue
        }

        # Applicability on this machine.
        $Prerequisite = Test-WtPrerequisite -Tweak $Tweak
        if (-not $Prerequisite.Supported)
        {
            $Item.Decision = 'Unknown'
            $Item.ReasonKey = 'Rec.Unknown.Applicability'
            $Item.ReasonArgs = @($Tweak.Id, [string]$Prerequisite.Reason)
            $Items.Add([pscustomobject]$Item)
            continue
        }

        # Supported verification. A change whose targets have no read-back reader cannot be shown
        # to have worked, so it is never recommended automatically - whatever its documentation
        # says. The configured-state gate below would catch the readable ones as Unknown; this makes
        # the reason explicit instead of burying it in a state result.
        $Verification = Test-WtVerificationSupportedInternal -Tweak $Tweak -State $Item.TargetState
        if (-not $Verification.Supported)
        {
            $Item.Verification = if ($Verification.Known) { 'Unsupported' } else { 'Unknown' }
            $Item.Decision = 'Unknown'
            $Item.ReasonKey = $Verification.ReasonKey
            $Item.ReasonArgs = @($Tweak.Id, (@($Verification.Targets) -join ', '))
            $Items.Add([pscustomobject]$Item)
            continue
        }

        # Already satisfied? Then there is nothing to propose, and nothing to rewrite.
        $Dimensions = Get-WtStateDimensionsInternal -Tweak $Tweak -State $Item.TargetState -Arguments $Arguments -Pending $Pending
        $Item.Configured = [string]$Dimensions.Configured
        $Item.Effective = [string]$Dimensions.Effective
        $Item.EffectiveEvidence = [string]$Dimensions.EffectiveEvidence
        $Item.Ownership = [string]$Dimensions.Ownership

        if ($Item.Configured -eq 'Matches')
        {
            $Item.Decision = 'AlreadySatisfied'
            $Item.ReasonKey = 'Rec.AlreadySatisfied'
            $Item.ReasonArgs = @($Tweak.Id, $Item.TargetState)
            $Items.Add([pscustomobject]$Item)
            continue
        }

        if ($Item.Configured -in 'Unreadable', 'Unsupported')
        {
            $Item.Decision = 'Unknown'
            $Item.ReasonKey = 'Rec.Unknown.State'
            $Item.ReasonArgs = @($Tweak.Id, $Item.Configured)
            $Items.Add([pscustomobject]$Item)
            continue
        }

        $Item.Decision = 'Recommended'
        $Item.ReasonKey = 'Rec.Recommended'
        $Item.ReasonArgs = @($Tweak.Id, $Item.TargetState)
        $Items.Add([pscustomobject]$Item)
    }

    # Planning pass: dependencies and conflicts decide the final proposal, not the ordering above.
    $CandidateIds = @($Items | Where-Object { $_.Decision -eq 'Recommended' } | ForEach-Object { $_.Id })
    $Plan = $null
    if ($CandidateIds.Count -gt 0)
    {
        try
        {
            $Plan = Get-WtDependencyPlanInternal -Ids $CandidateIds
        }
        catch
        {
            $Plan = $null
            $Errors.Add((Get-WtString -Key 'Rec.PlanFailed' -Arguments @($_.Exception.Message)))
        }
    }

    if ($Plan -and @($Plan.Errors).Count -gt 0)
    {
        # A conflict or a cycle inside the proposal removes the items it involves, and says so.
        foreach ($Problem in @($Plan.Errors))
        {
            $Errors.Add($Problem)
        }

        $Blocked = @()
        foreach ($Conflict in @($Plan.Conflicts))
        {
            $Blocked += [string]$Conflict.Left
            $Blocked += [string]$Conflict.Right
        }

        foreach ($Item in @($Items))
        {
            if ($Item.Decision -ne 'Recommended') { continue }
            if ($Blocked -contains $Item.Id)
            {
                $Item.Decision = 'Blocked'
                $Item.ReasonKey = 'Rec.Blocked.Conflict'
                $Item.ReasonArgs = @($Item.Id)
            }
            elseif ($Plan.Errors -match [regex]::Escape($Item.Id))
            {
                $Item.Decision = 'Blocked'
                $Item.ReasonKey = 'Rec.Blocked.Plan'
                $Item.ReasonArgs = @($Item.Id)
            }
        }
    }

    $Recommended = @($Items | Where-Object { $_.Decision -eq 'Recommended' })
    $Counts = @{}
    foreach ($Decision in 'Recommended', 'AlreadySatisfied', 'Excluded', 'Unknown', 'Blocked')
    {
        $Counts[$Decision] = @($Items | Where-Object { $_.Decision -eq $Decision }).Count
    }

    return @{
        Objective    = $Objective
        Items        = @($Items)
        Recommended  = $Recommended
        Counts       = $Counts
        Plan         = $Plan
        Errors       = @($Errors.ToArray())
        Description  = $Policy.Description
        Applied      = $false
    }
}

<#
.SYNOPSIS
    The mutually exclusive groups declared by the catalog, with their live state.
.DESCRIPTION
    Read-only. A group is one setting with several alternatives: exactly one of them can be
    pending, because the engine keys the pending set by tweak id and a group is a single tweak
    whose states are the alternatives. The current state is reported as detected - including the
    honest answers Mixed, custom/unknown and unsupported - and the option whose intent is
    'WindowsDefault' is labelled as a request for Windows' own behaviour rather than a restoration.
.OUTPUTS
    Group objects with Id, Labels, Options (Id, Intent, Labels, Detected, Pending) and CurrentState.
#>
function Get-WtChoiceGroupInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][string]$Id,
        [Parameter(Mandatory = $false)][hashtable]$Pending
    )

    $Groups = @()
    foreach ($Tweak in @($Script:WtCatalog.Values | Sort-Object -Property Category, Id))
    {
        if (@($Tweak.PSObject.Properties.Name) -notcontains 'DefinitionGroup') { continue }
        $Group = $Tweak.DefinitionGroup
        if (-not $Group) { continue }
        if ($Id -and $Group.Id -ne $Id) { continue }

        $State = Get-WtTweakState -Id $Tweak.Id
        $Detected = [string]$State.State

        # The honest current-state detail. 'Unknown' from detection means the value is either not
        # set at all or holds something no alternative declares - two different facts, so the value
        # is read once more instead of being guessed. 'Mixed' is reported when the alternative that
        # is live writes several targets and only some of them hold it.
        $Detail = 'Custom'
        if ($Detected -eq 'Unsupported')
        {
            $Detail = 'Unsupported'
        }
        elseif ($Detected -eq 'Unknown')
        {
            $Detail = 'Custom'
            $Spec = if (@($Tweak.PSObject.Properties.Name) -contains 'Detection') { $Tweak.Detection } else { $null }
            if ($Spec -and $Spec.Path)
            {
                $Read = Get-WtRegistryState -Path ([string]$Spec.Path) -Name ([string]$Spec.Name)
                if ($Read.Available -and -not $Read.ValueExists) { $Detail = 'Absent' }
                elseif (-not $Read.Available) { $Detail = 'Unreadable' }
            }
        }
        else
        {
            $OptionDimensions = Get-WtStateDimensionsInternal -Tweak $Tweak -State $Detected
            $Detail = if ([string]$OptionDimensions.Configured -eq 'Mixed') { 'Mixed' } else { 'Matched' }
        }

        $PendingTarget = ''
        if ($Pending -and $Pending.Contains($Tweak.Id)) { $PendingTarget = [string]$Pending[$Tweak.Id].Target }

        $Options = @()
        foreach ($OptionId in @($Group.OptionIds))
        {
            $Option = $Group.Options[$OptionId]
            $Options += [pscustomobject]@{
                PSTypeName   = 'WindowsTweaker.ChoiceOption'
                Id           = $OptionId
                Intent       = [string]$Option.Intent
                Labels       = $Option.Labels
                Descriptions = $Option.Descriptions
                Detected     = ($Detected -eq $OptionId)
                Pending      = ($PendingTarget -eq $OptionId)
                State        = $Tweak.States[$OptionId]
            }
        }

        $Groups += [pscustomobject]@{
            PSTypeName   = 'WindowsTweaker.ChoiceGroup'
            Id           = [string]$Group.Id
            Revision     = [int]$Group.Revision
            TweakId      = [string]$Tweak.Id
            Category     = [string]$Tweak.Category
            Labels       = $Group.Labels
            Descriptions = $Group.Descriptions
            Notes        = $Group.Notes
            Options      = @($Options)
            OptionIds    = @($Group.OptionIds)
            CurrentState = $Detected
            CurrentDetail = $Detail
            PendingState = $PendingTarget
            Supported    = [bool]$State.Supported
            Effective    = if (@($State.PSObject.Properties.Name) -contains 'Effective') { [string]$State.Effective } else { 'Unknown' }
            Ownership    = if (@($State.PSObject.Properties.Name) -contains 'Ownership') { [string]$State.Ownership } else { 'Unmanaged' }
            Restart      = [string]$Tweak.Restart
            Tweak        = $Tweak
        }
    }

    return @($Groups)
}
