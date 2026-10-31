# WindowsTweaker - sanity scan, recommendations, state dimensions and choice groups (public API).
#
# None of these functions changes anything. The scan reads; the recommendation proposal is a
# list; the dimensions are observations; a choice group is a view of one setting with several
# alternatives. Applying still goes through Invoke-WtTweak, so preview, review revalidation,
# journal, verification and recovery are unchanged.

<#
.SYNOPSIS
    Lists the sanity rules that the scan can run.
.PARAMETER Id
    Return only this rule.
.EXAMPLE
    Get-WtSanityRule
.OUTPUTS
    Rule objects with Id, Revision, Area, Severity, the localized title/rationale/limitations,
    the source page and the specific claim it supports, and the probes the rule reads.
#>
function Get-WtSanityRule
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param ([Parameter(Mandatory = $false, Position = 0)][string]$Id)

    if (@($Script:WtRuleErrors).Count -gt 0)
    {
        Write-Error -Message ($Script:WtRuleErrors -join ' ')
        return
    }

    return @(Get-WtSanityRuleInternal -Id $Id | ForEach-Object {
            [pscustomobject]@{
                PSTypeName   = 'WindowsTweaker.SanityRule'
                Id           = $_.Id
                Revision     = $_.Revision
                Area         = $_.Area
                Severity     = $_.Severity
                Title        = $_.Title
                Rationale    = $_.Rationale
                Expected     = $_.Expected
                Limitations  = $_.Limitations
                NextStep     = $_.NextStep
                Effective    = $_.Effective
                Source       = $_.Source
                Remediation  = $_.Remediation
                Probes       = @($_.Probes)
            }
        })
}

<#
.SYNOPSIS
    Runs the read-only sanity scan.
.DESCRIPTION
    The scan reads configuration and reports what is worth a human look. It writes nothing,
    starts nothing (except the read-only `bcdedit /enum {current}` a boot rule asks for), removes
    nothing and repairs nothing. It reports one of four outcomes:

      Clean        every required probe of every applicable rule answered, and nothing fired;
      Findings     at least one rule found something to review (and nothing required was unreadable);
      Incomplete   a required probe could not be read, so the picture is partial - never Clean;
      Unsupported  no rule applies to this system, or there are no rules.

    A finding is not a fault and not a score: it comes with the documented claim it rests on, the
    expectation that claim implies, and what the claim does not cover.
.PARAMETER Rule
    Run only these rule ids.
.PARAMETER Export
    Write the report to this path. Nothing is written unless this is given.
.PARAMETER Format
    Markdown (default) or Json.
.EXAMPLE
    Get-WtSanityScan
.EXAMPLE
    Get-WtSanityScan -Rule Tcp.LegacyReceiveWindow, Restart.PendingMarkers -Export ./scan.md
.OUTPUTS
    Scan object with Outcome, Findings, Gaps, PendingRestart, RuleCount and ExportedTo.
#>
function Get-WtSanityScan
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory = $false)][string[]]$Rule = @(),
        [Parameter(Mandatory = $false)][string]$Export,
        [Parameter(Mandatory = $false)][ValidateSet('Markdown', 'Json')][string]$Format = 'Markdown'
    )

    if (@($Script:WtRuleErrors).Count -gt 0)
    {
        Write-Error -Message ($Script:WtRuleErrors -join ' ')
        return
    }

    $Scan = Invoke-WtSanityScanInternal -Rule @($Rule)

    if ($Export)
    {
        # The writer owns the record of what it wrote (WroteAnything/ExportedTo on the scan); this
        # wrapper only keeps the refusal, which is the part that has to reach the caller.
        $Written = Export-WtSanityReportInternal -Scan $Scan -Path $Export -Format $Format
        if (-not $Written.Ok)
        {
            # A refused export writes nothing: the caller is told why instead of being handed a
            # path to a file that does not exist.
            $Scan | Add-Member -NotePropertyName 'ExportRefused' -NotePropertyValue ([string]$Written.Message) -Force
        }
    }

    # The object carries the text a caller renders, in the active language, so no caller has to
    # reach into the module for a label.
    $Findings = @($Scan.Findings | ForEach-Object {
            $Finding = $_
            [pscustomobject]@{
                PSTypeName  = 'WindowsTweaker.SanityFinding'
                RuleId      = $Finding.RuleId
                Revision    = $Finding.Revision
                Area        = $Finding.Area
                Severity    = $Finding.Severity
                ProbeId     = $Finding.ProbeId
                Target      = $Finding.Target
                Observed    = $Finding.Observed
                ObservedMarker = $Finding.ObservedMarker
                ObservedType = [string]$Finding.ObservedType
                ObservedTypeLabel = Get-WtObservedTypeLabelInternal -Type ([string]$Finding.ObservedType)
                Effective   = $Finding.Effective
                EffectiveLabel = Get-WtDimensionLabelInternal -Dimension 'Evidence' -Value ([string]$Finding.Effective)
                Conditions  = $Finding.Conditions
                ConditionsLabel = Get-WtConditionsLabelInternal -Conditions $Finding.Conditions
                Remediation = $Finding.Remediation
                RemediationLabel = Get-WtRuleRemediationLabelInternal -Remediation $Finding.Remediation
                Claim       = $Finding.Claim
                Source      = $Finding.Source
                Title       = $Finding.Title
                DisplayTitle = Get-WtText -Value $Finding.Title
                DisplayExpected = Get-WtText -Value $Finding.Expected
                DisplayRationale = Get-WtText -Value $Finding.Rationale
                DisplayLimitations = Get-WtText -Value $Finding.Limitations
                DisplayNextStep = Get-WtText -Value $Finding.NextStep
            }
        })

    $Markers = @($Scan.PendingRestart.Markers | ForEach-Object {
            [pscustomobject]@{
                PSTypeName  = 'WindowsTweaker.PendingRestartMarker'
                Id          = $_.Id
                Marker      = $_.Marker
                MarkerLabel = Get-WtMarkerLabelInternal -Marker $_.Marker
                Detail      = $_.Detail
                Boundary    = $_.Boundary
            }
        })

    return [pscustomobject]@{
        PSTypeName     = 'WindowsTweaker.SanityScan'
        Outcome        = [string]$Scan.Outcome
        OutcomeLabel   = Get-WtScanOutcomeLabelInternal -Outcome $Scan.Outcome
        ScannedUtc     = $Scan.ScannedUtc
        Rules          = @($Scan.Rules)
        RuleCount      = $Scan.RuleCount
        Findings       = $Findings
        FindingCount   = @($Findings).Count
        Gaps           = @($Scan.Gaps)
        UnknownRules   = @($Scan.UnknownRules)
        PendingRestart = [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.PendingRestart'
            Markers    = $Markers
            Present    = [int]$Scan.PendingRestart.Present
            Unreadable = [int]$Scan.PendingRestart.Unreadable
            Boundary   = [string]$Scan.PendingRestart.Boundary
            BoundaryKey = [string]$Scan.PendingRestart.BoundaryKey
        }
        WroteAnything  = [bool]$Scan.WroteAnything
        ExportedTo     = [string]$Scan.ExportedTo
        ExportRefused  = [string]$(if (@($Scan.PSObject.Properties.Name) -contains 'ExportRefused') { $Scan.ExportRefused } else { '' })
    }
}

<#
.SYNOPSIS
    Lists the recommendation objectives this engine defines.
.DESCRIPTION
    Each objective is defined independently: if nothing serves it, the proposal is empty and says
    so rather than quietly borrowing another objective's items.
.EXAMPLE
    Get-WtRecommendationObjective
.OUTPUTS
    Objective objects with Name, Description, the item kinds it accepts and whether it takes
    preference items at all.
#>
function Get-WtRecommendationObjective
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param ()

    return @($Script:WtObjectivePolicy.Keys | Sort-Object | ForEach-Object {
            $Policy = $Script:WtObjectivePolicy[$_]
            [pscustomobject]@{
                PSTypeName       = 'WindowsTweaker.RecommendationObjective'
                Name             = $_
                Description      = Get-WtString -Key $Policy.Description
                Kinds            = @($Policy.Kinds)
                AllowPreferences = [bool]$Policy.AllowPreferences
            }
        })
}

<#
.SYNOPSIS
    Builds a recommendation proposal for one objective, with an explanation for every item.
.DESCRIPTION
    A proposal only: nothing is applied, nothing is added to a pending set, and this function does
    not touch a selection the user made by hand. Each considered item carries one decision:

      Recommended        it serves this objective and the engine's floors allow it;
      AlreadySatisfied   the machine is already in the state the item would set;
      Excluded           the engine or the objective keeps it out, with the reason;
      Unknown            applicability or current state could not be established;
      Blocked            a dependency or a conflict stops it inside this proposal.

    Eligibility is decided by the engine, never by the document: an imported pack is offered at
    most, and anything that reduces protection, cannot be restored exactly or carries high risk is
    never selected automatically. Preferences are excluded unless -IncludePreferences is given, and
    the Gaming objective never takes them at all.
.PARAMETER Objective
    Balanced, Responsiveness, Gaming, PowerEfficiency or Privacy.
.PARAMETER IncludeManual
    Also list the items the engine keeps out of automatic selection, with the reason.
.PARAMETER IncludePreferences
    Consider preference items (themes, animations, what the interface shows). They are still never
    presented as a performance improvement.
.PARAMETER Finding
    Sanity rule ids with an observed finding; a repair recommendation needs one.
.EXAMPLE
    Get-WtRecommendation -Objective Privacy -IncludeManual
.OUTPUTS
    Proposal object with Objective, Items, Recommended, Counts, Plan and Errors.
#>
function Get-WtRecommendation
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory = $true, Position = 0)][string]$Objective,
        [Parameter(Mandatory = $false)][switch]$IncludeManual,
        [Parameter(Mandatory = $false)][switch]$IncludePreferences,
        [Parameter(Mandatory = $false)][string[]]$Finding = @()
    )

    $Proposal = Get-WtRecommendationInternal -Objective $Objective -IncludeManual:$IncludeManual -IncludePreferences:$IncludePreferences -Finding @($Finding)

    $Items = @($Proposal.Items | ForEach-Object {
            $Item = $_
            [pscustomobject]@{
                PSTypeName   = 'WindowsTweaker.RecommendationItem'
                Id           = $Item.Id
                Category     = $Item.Category
                Name         = $Item.Name
                DisplayName  = Get-WtText -Value $Item.Name
                Decision     = $Item.Decision
                Kind         = $Item.Kind
                KindLabel    = Get-WtRecommendationKindLabelInternal -Kind $Item.Kind
                Policy       = $Item.Policy
                PolicyLabel  = Get-WtRecommendationPolicyLabelInternal -Policy $Item.Policy
                Objectives   = @($Item.Objectives)
                TargetState  = $Item.TargetState
                Support      = $Item.Support
                Risk         = $Item.Risk
                Rollback     = $Item.Rollback
                Configured   = $Item.Configured
                Effective    = $Item.Effective
                EffectiveLabel = Get-WtDimensionLabelInternal -Dimension 'Effective' -Value ([string]$Item.Effective)
                EffectiveEvidence = $Item.EffectiveEvidence
                EffectiveEvidenceLabel = Get-WtDimensionLabelInternal -Dimension 'Evidence' -Value ([string]$Item.EffectiveEvidence)
                Ownership    = $Item.Ownership
                Verification = $Item.Verification
                VerificationLabel = if ($Item.Verification -eq 'Supported') { Get-WtString -Key 'Rec.Verification.Supported' } else { '' }
                ReasonKey    = $Item.ReasonKey
                Reason       = Get-WtRecommendationReasonInternal -Item $Item
                Rationale    = $Item.Rationale
                DisplayRationale = if ($Item.Rationale) { Get-WtText -Value $Item.Rationale } else { '' }
            }
        })

    return [pscustomobject]@{
        PSTypeName    = 'WindowsTweaker.Recommendation'
        Objective     = $Proposal.Objective
        ObjectiveLabel = if ($Proposal.ContainsKey('Description')) { Get-WtString -Key $Proposal.Description } else { '' }
        Items         = $Items
        Recommended   = @($Items | Where-Object { $_.Decision -eq 'Recommended' })
        Counts        = $Proposal.Counts
        Plan          = $Proposal.Plan
        Errors        = @($Proposal.Errors)
        Applied       = $false
    }
}

<#
.SYNOPSIS
    Reads the pending-restart markers.
.DESCRIPTION
    Structured evidence, read-only: a marker is present, present but empty, missing, or unreadable,
    and those four are kept apart. Nothing is deleted - a restart marker is Windows' own
    bookkeeping - and no other view is blocked by one.
.EXAMPLE
    Get-WtPendingRestart
.OUTPUTS
    Object with Markers, Present, Unreadable, Boundary and BoundaryKey.
#>
function Get-WtPendingRestart
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param ()

    $Pending = Get-WtPendingRestartInternal

    return [pscustomobject]@{
        PSTypeName  = 'WindowsTweaker.PendingRestart'
        Markers     = @($Pending.Markers)
        Present     = [int]$Pending.Present
        Unreadable  = [int]$Pending.Unreadable
        Boundary    = [string]$Pending.Boundary
        BoundaryKey = [string]$Pending.BoundaryKey
    }
}

<#
.SYNOPSIS
    Returns the configured, effective and ownership dimensions of one tweak.
.DESCRIPTION
    Three answers to three different questions:
      Configured  does the machine hold what the state describes (Matches / Differs / Mixed /
                  Absent / Unreadable / Unsupported);
      Effective   what is Windows doing with it (Active / Inactive / PendingRestart /
                  PendingSignOut / PendingReboot / Unknown / Unsupported), with the evidence it
                  rests on (Observed / Inferred / Unknown);
      Ownership   who put it there (Unmanaged / Owned / Conflicting / Interrupted).

    A successful write and read-back proves configuration, not behaviour: an effective state is
    only reported from evidence, and 'Unknown' is a complete answer.
.PARAMETER Id
    Tweak id.
.PARAMETER State
    Compare against this state instead of the tweak's detected/default state.
.EXAMPLE
    Get-WtTweakDimensions -Id Privacy.WindowsTips
.OUTPUTS
    Dimension object with Configured, ConfiguredDetail, Effective, EffectiveEvidence,
    EffectiveReason, Ownership, OwnershipDetail, Boundary and PendingRestart.
#>
function Get-WtTweakDimensions
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory = $true, Position = 0)][string]$Id,
        [Parameter(Mandatory = $false)][string]$State,
        [Parameter(Mandatory = $false)][hashtable]$Arguments
    )

    $Resolved = Resolve-WtTweakIdInternal -Id $Id
    $Tweak = $Resolved.Tweak
    if (-not $Tweak)
    {
        Write-Error -Message (Get-WtString -Key 'Error.TweakNotFound' -Arguments @($Id))
        return
    }

    if (-not $State)
    {
        $Detected = [string](Get-WtTweakState -Id $Tweak.Id).State
        $State = if ($Detected -in '', 'Unknown', 'Unsupported') { [string]$Tweak.DefaultState } else { $Detected }
    }

    $Pending = Get-WtPendingRestartInternal
    $Dimensions = Get-WtStateDimensionsInternal -Tweak $Tweak -State $State -Arguments $Arguments -Pending $Pending

    return [pscustomobject]@{
        PSTypeName        = 'WindowsTweaker.TweakDimensions'
        Id                = $Tweak.Id
        State             = $State
        DefaultState      = [string]$Tweak.DefaultState
        Configured        = [string]$Dimensions.Configured
        ConfiguredDetail  = [string]$Dimensions.ConfiguredDetail
        Effective         = [string]$Dimensions.Effective
        EffectiveEvidence = [string]$Dimensions.EffectiveEvidence
        EffectiveReason   = [string]$Dimensions.EffectiveReason
        Ownership         = [string]$Dimensions.Ownership
        OwnershipDetail   = [string]$Dimensions.OwnershipDetail
        OwnershipHistory  = [string]$Dimensions.HistoryId
        Boundary          = [string]$Dimensions.Boundary
        ConfiguredLabel   = Get-WtDimensionLabelInternal -Dimension 'Configured' -Value ([string]$Dimensions.Configured)
        EffectiveLabel    = Get-WtDimensionLabelInternal -Dimension 'Effective' -Value ([string]$Dimensions.Effective)
        EvidenceLabel     = Get-WtDimensionLabelInternal -Dimension 'Evidence' -Value ([string]$Dimensions.EffectiveEvidence)
        OwnershipLabel    = Get-WtDimensionLabelInternal -Dimension 'Ownership' -Value ([string]$Dimensions.Ownership)
        PendingLabel      = Get-WtMarkerLabelInternal -Marker $(if ($Pending.Present -gt 0) { 'NonEmpty' } elseif ($Pending.Unreadable -gt 0) { 'Unreadable' } else { 'Missing' })
        PendingRestart    = [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.PendingRestart'
            Markers    = @($Pending.Markers | ForEach-Object {
                    [pscustomobject]@{
                        PSTypeName  = 'WindowsTweaker.PendingRestartMarker'
                        Id          = $_.Id
                        Marker      = $_.Marker
                        MarkerLabel = Get-WtMarkerLabelInternal -Marker $_.Marker
                        Detail      = $_.Detail
                        Boundary    = $_.Boundary
                    }
                })
            Present    = [int]$Pending.Present
            Unreadable = [int]$Pending.Unreadable
            Boundary   = [string]$Pending.Boundary
        }
    }
}

<#
.SYNOPSIS
    Lists the mutually exclusive groups and their alternatives.
.DESCRIPTION
    A group is one setting with several alternatives, so exactly one alternative can be pending at
    a time. Each alternative carries its intent: 'Configured' means a value this tool writes and
    can restore exactly, 'WindowsDefault' means a request for Windows' own behaviour. Those are
    different actions, and restoring the captured original state is a third: it is what Undo-WtTweak
    and the journal do.
    The current state is reported as detected, including the honest answers: it may be no
    alternative at all (custom value, absent value, unreadable, unsupported), and when the live
    alternative writes several targets and only some of them hold it the answer is Mixed. Whether
    an alternative is pending is session state, so it is only reported when the caller passes the
    pending set it wants judged.
.PARAMETER Id
    Return only this group.
.PARAMETER Pending
    Optional map of tweak id -> pending entry whose 'Target' names the alternative pending for that
    tweak. When it is given, each option and the group report what is pending; when it is not, no
    option is reported as pending rather than one being guessed.
.EXAMPLE
    Get-WtChoiceGroup
.OUTPUTS
    Group objects with Id, TweakId, Labels, Options (with Intent, Detected and Pending),
    CurrentState, CurrentDetail, CurrentLabel, PendingState, Supported, Effective and Ownership.
#>
function Get-WtChoiceGroup
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory = $false, Position = 0)][string]$Id,
        [Parameter(Mandatory = $false)][hashtable]$Pending
    )

    return @(Get-WtChoiceGroupInternal -Id $Id -Pending $Pending | ForEach-Object {
            $Group = $_
            [pscustomobject]@{
                PSTypeName     = 'WindowsTweaker.ChoiceGroup'
                Id             = $Group.Id
                Revision       = $Group.Revision
                TweakId        = $Group.TweakId
                Category       = $Group.Category
                Labels         = $Group.Labels
                DisplayLabel   = Get-WtText -Value $Group.Labels
                DisplayDescription = if ($Group.Descriptions) { Get-WtText -Value $Group.Descriptions } else { '' }
                DisplayNotes   = if ($Group.Notes) { Get-WtText -Value $Group.Notes } else { '' }
                OptionIds      = @($Group.OptionIds)
                Options        = @($Group.Options | ForEach-Object {
                        [pscustomobject]@{
                            PSTypeName     = 'WindowsTweaker.ChoiceOption'
                            Id             = $_.Id
                            Intent         = $_.Intent
                            IntentLabel    = Get-WtIntentLabelInternal -Intent $_.Intent
                            Labels         = $_.Labels
                            DisplayLabel   = Get-WtText -Value $_.Labels
                            DisplayDescription = if ($_.Descriptions) { Get-WtText -Value $_.Descriptions } else { '' }
                            Detected       = [bool]$_.Detected
                            Pending        = [bool]$_.Pending
                        }
                    })
                CurrentState   = $Group.CurrentState
                CurrentDetail  = [string]$Group.CurrentDetail
                CurrentLabel   = Get-WtGroupStateLabelInternal -Group $Group
                PendingState   = [string]$Group.PendingState
                Supported      = [bool]$Group.Supported
                Effective      = [string]$Group.Effective
                Ownership      = [string]$Group.Ownership
                Restart        = [string]$Group.Restart
            }
        })
}
