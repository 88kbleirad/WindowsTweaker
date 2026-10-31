# WindowsTweaker - capability-loss disclosure: evaluation and aggregation.
#
# A definition may declare what may stop working after one of its actions (see the
# `capabilityLoss` document block). This file evaluates those declarations against the
# selection being reviewed and aggregates them:
#
#   * stable capability ids group impacts across definitions, so the same loss caused by
#     several selected actions is shown once, with every cause named;
#   * Guaranteed impacts apply whenever the action runs; Conditional impacts carry a
#     condition whose capability tokens are probed on this machine; Unknown impacts are
#     always shown as needing further review;
#   * a conditional impact whose condition cannot be evaluated is never treated as
#     satisfied or as irrelevant - it is reported as conditional with the probe missing;
#   * temporary and persistent effects are kept apart, and restoration text and recovery
#     limitations are carried through to the caller.
#
# This file is read-only: it probes capabilities, reads definitions and produces data. It
# never writes anything and never changes a selection.

<#
.SYNOPSIS
    Evaluates one capability impact declaration against this machine.
.DESCRIPTION
    Returns whether the impact applies now and why. Guaranteed always applies. Conditional
    probes its capability tokens: all present -> applies; any absent -> does not apply now
    (with the missing token named); a probe that cannot be answered -> the impact stays
    conditional and the probe is reported as missing. Unknown never claims to apply or not
    to apply - it is a request for review.
.OUTPUTS
    Object with Capability, Kind, Temporary, Applies, Reason.
#>
function Test-WtCapabilityImpactInternal
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Impact,
        [Parameter(Mandatory = $false)][hashtable]$Environment
    )

    $Kind = [string]$Impact.Kind
    $Capability = [string]$Impact.Capability
    $Temporary = [bool]$Impact.Temporary

    if ($Kind -eq 'Guaranteed')
    {
        return [pscustomobject]@{
            Capability = $Capability
            Kind       = $Kind
            Temporary  = $Temporary
            Applies    = $true
            Reason     = ''
        }
    }

    if ($Kind -eq 'Unknown')
    {
        return [pscustomobject]@{
            Capability = $Capability
            Kind       = $Kind
            Temporary  = $Temporary
            Applies    = $null
            Reason     = 'Unknown impact: the definition declares the loss is possible but does not state when or how it would occur; review it before deciding.'
        }
    }

    # Conditional. The condition is required by the schema for this kind; an older or
    # hand-built definition without one is reported as unverifiable, never as satisfied.
    $Condition = $Impact.Condition
    if (-not $Condition)
    {
        return [pscustomobject]@{
            Capability = $Capability
            Kind       = $Kind
            Temporary  = $Temporary
            Applies    = $null
            Reason     = 'Conditional impact without a condition: cannot be evaluated, treat as needing review.'
        }
    }

    $Tokens = @()
    if ($Condition -is [System.Collections.IDictionary] -and $Condition.Contains('requiresCapabilities'))
    {
        $Tokens = @($Condition['requiresCapabilities']) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    }
    if ($Tokens.Count -eq 0)
    {
        return [pscustomobject]@{
            Capability = $Capability
            Kind       = $Kind
            Temporary  = $Temporary
            Applies    = $null
            Reason     = 'Conditional impact with no probed condition: it applies when the stated condition is true; this machine was not checked.'
        }
    }

    $Missing = @()
    $Unreadable = @()
    foreach ($Token in $Tokens)
    {
        $Probe = Test-WtCapability -Name $Token -Environment $Environment
        if ([bool]$Probe.Available)
        {
            continue
        }
        if ($Probe.Kind -eq 'unknown')
        {
            $Unreadable += $Token
        }
        else
        {
            $Missing += $Token
        }
    }

    if ($Unreadable.Count -gt 0)
    {
        return [pscustomobject]@{
            Capability = $Capability
            Kind       = $Kind
            Temporary  = $Temporary
            Applies    = $null
            Reason     = "The condition could not be fully evaluated for this machine (unreadable: $($Unreadable -join ', ')); treat as conditional."
        }
    }

    if ($Missing.Count -gt 0)
    {
        return [pscustomobject]@{
            Capability = $Capability
            Kind       = $Kind
            Temporary  = $Temporary
            Applies    = $false
            Reason     = "The condition is not met on this machine (missing: $($Missing -join ', ')); the loss does not apply to this selection now."
        }
    }

    return [pscustomobject]@{
        Capability = $Capability
        Kind       = $Kind
        Temporary  = $Temporary
        Applies    = $true
        Reason     = ''
    }
}

<#
.SYNOPSIS
    Builds the capability-loss summary for one selected change.
.DESCRIPTION
    Pure data: one entry per declared impact with its evaluated applicability, plus the
    tweak id and state that cause it. Entries whose condition is not met are kept (with
    Applies = $false) so a review can see why a known loss does not apply here; the
    aggregator decides what the caller displays.
.OUTPUTS
    Array of pscustomobject rows.
#>
function Get-WtTweakCapabilityLossInternal
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param
    (
        [Parameter(Mandatory = $true)][object]$Tweak,
        [Parameter(Mandatory = $false)][string]$State = '',
        [Parameter(Mandatory = $false)][hashtable]$Environment
    )

    if (-not $Tweak)
    {
        return @()
    }

    $Declarations = $null
    if (@($Tweak.PSObject.Properties.Name) -contains 'DefinitionCapabilityLoss')
    {
        $Declarations = @($Tweak.DefinitionCapabilityLoss)
    }
    elseif (@($Tweak.PSObject.Properties.Name) -contains 'CapabilityLoss')
    {
        # A tweak written in PowerShell may carry the same declarations directly.
        $Declarations = @($Tweak.CapabilityLoss)
    }

    if (-not $Declarations -or $Declarations.Count -eq 0)
    {
        return @()
    }

    $Rows = [System.Collections.Generic.List[object]]::new()
    foreach ($Impact in $Declarations)
    {
        if (-not $Impact) { continue }

        $Evaluation = Test-WtCapabilityImpactInternal -Impact $Impact -Environment $Environment
        $Rows.Add([pscustomobject]@{
            PSTypeName = 'WindowsTweaker.CapabilityLossRow'
            Capability = $Evaluation.Capability
            Names      = $Impact.Names
            Kind       = $Evaluation.Kind
            Temporary  = $Evaluation.Temporary
            Applies    = $Evaluation.Applies
            Reason     = $Evaluation.Reason
            Condition  = $Impact.Condition
            RestoredBy = $Impact.RestoredBy
            Limitations = $Impact.Limitations
            TweakId    = [string]$Tweak.Id
            State      = [string]$State
        })
    }

    return @($Rows.ToArray())
}

<#
.SYNOPSIS
    Aggregates capability-loss rows across a selection, deduplicating by capability id.
.DESCRIPTION
    One entry per capability id. Entry carries every cause (tweak id + state + its own
    kind), whether any cause is guaranteed or unknown, whether temporariness is uniform,
    and the shared display texts (names, restoration, limitations - first declared wins
    since the ids are stable). Rows whose condition is not met are reported separately so
    the caller can show "this loss does not apply to this selection" without silently
    dropping a declaration.
.OUTPUTS
    @{ Impacts; NotApplicable }
#>
function Get-WtCapabilityLossInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object[]]$Selection,
        [Parameter(Mandatory = $false)][hashtable]$Environment
    )

    $Grouped = [ordered]@{}
    $NotApplicable = [System.Collections.Generic.List[object]]::new()

    foreach ($Item in @($Selection))
    {
        $Tweak = $Item.Tweak
        $State = [string]$Item.State
        if (-not $Tweak) { continue }

        foreach ($Row in @(Get-WtTweakCapabilityLossInternal -Tweak $Tweak -State $State -Environment $Environment))
        {
            if ($Row.Applies -eq $false)
            {
                $NotApplicable.Add($Row)
                continue
            }

            $Id = [string]$Row.Capability
            if (-not $Grouped.Contains($Id))
            {
                $Grouped[$Id] = @{
                    Capability = $Id
                    Names      = $Row.Names
                    RestoredBy = $Row.RestoredBy
                    Limitations = $Row.Limitations
                    Kinds     = [System.Collections.Generic.List[string]]::new()
                    Temporaries = [System.Collections.Generic.List[bool]]::new()
                    Causes    = [System.Collections.Generic.List[object]]::new()
                }
            }

            $Entry = $Grouped[$Id]
            if (-not $Entry.Kinds.Contains($Row.Kind)) { $Entry.Kinds.Add($Row.Kind) }
            $Entry.Temporaries.Add([bool]$Row.Temporary)
            $Entry.Causes.Add([pscustomobject]@{
                TweakId = $Row.TweakId
                State   = $Row.State
                Kind    = $Row.Kind
                Temporary = [bool]$Row.Temporary
                Reason  = $Row.Reason
            })

            if (-not $Entry.RestoredBy) { $Entry.RestoredBy = $Row.RestoredBy }
            if (-not $Entry.Limitations) { $Entry.Limitations = $Row.Limitations }
        }
    }

    $Impacts = [System.Collections.Generic.List[object]]::new()
    foreach ($Id in $Grouped.Keys)
    {
        $Entry = $Grouped[$Id]
        $Kinds = @($Entry.Kinds)
        $Temporaries = @($Entry.Temporaries)
        $UniformTemporary = ($Temporaries.Count -gt 0) -and (@($Temporaries | Select-Object -Unique).Count -eq 1)

        $Impacts.Add([pscustomobject]@{
            PSTypeName   = 'WindowsTweaker.CapabilityLoss'
            Capability   = $Id
            Names        = $Entry.Names
            Kinds        = $Kinds
            AnyGuaranteed = $Kinds -contains 'Guaranteed'
            AnyUnknown    = $Kinds -contains 'Unknown'
            Temporary     = if ($UniformTemporary) { [bool]$Temporaries[0] } else { $null }
            MixedTemporary = -not $UniformTemporary
            Causes       = @($Entry.Causes)
            RestoredBy   = $Entry.RestoredBy
            Limitations  = $Entry.Limitations
        })
    }

    return @{
        Impacts       = @($Impacts.ToArray())
        NotApplicable = @($NotApplicable.ToArray())
    }
}

<#
.SYNOPSIS
    Renders an aggregated capability-loss result as localized display lines.
.DESCRIPTION
    Shared by the details pane, the pending review, the final confirmation and the preset
    preview, so every surface shows the same disclosure text. Every line is a plain string
    in the active language.
.OUTPUTS
    @{ Lines; Count } - Lines is string[], Count is the number of applied impacts.
#>
function Get-WtCapabilityLossLinesInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $false)][int]$MaxLines = 24
    )

    $Lines = [System.Collections.Generic.List[string]]::new()
    $Impacts = @($Result.Impacts)
    $NotApplicable = @($Result.NotApplicable)

    if ($Impacts.Count -eq 0 -and $NotApplicable.Count -eq 0)
    {
        $Lines.Add((Get-WtString -Key 'Cap.Loss.None'))
        return @{ Lines = $Lines.ToArray(); Count = 0 }
    }

    for ($Index = 0; $Index -lt $Impacts.Count -and $Lines.Count -lt $MaxLines; $Index++)
    {
        $Impact = $Impacts[$Index]

        $KindText = @($Impact.Kinds | ForEach-Object { Get-WtString -Key "Cap.Loss.Kind.$_" }) -join '/'
        $TemporaryText = if ($Impact.MixedTemporary) { Get-WtString -Key 'Cap.Loss.Mixed' }
        elseif ($Impact.Temporary) { Get-WtString -Key 'Cap.Loss.Temporary' }
        else { Get-WtString -Key 'Cap.Loss.Persistent' }

        $Header = "{0} [{1} | {2}]" -f (Get-WtText -Value $Impact.Names), $KindText, $TemporaryText
        $Lines.Add($Header)

        $Causes = @($Impact.Causes | ForEach-Object { "$($_.TweakId) -> $($_.State)" }) -join ', '
        $Lines.Add("  " + (Get-WtString -Key 'Cap.Loss.Causes' -Arguments @($Causes)))

        # A conditional impact whose condition could not be evaluated is labelled as such,
        # never as satisfied or as irrelevant.
        $Unverifiable = @($Impact.Causes | Where-Object { $_.Kind -eq 'Conditional' -and $_.Reason } | Select-Object -Unique -Property Reason)
        foreach ($Cause in $Unverifiable)
        {
            $Lines.Add("  " + (Get-WtString -Key 'Cap.Loss.ConditionMissing' -Arguments @($Cause.Reason)))
        }

        if ($Impact.RestoredBy)
        {
            $Lines.Add("  " + (Get-WtString -Key 'Cap.Loss.Restore' -Arguments @((Get-WtText -Value $Impact.RestoredBy))))
        }

        if ($Impact.Limitations)
        {
            $Lines.Add("  " + (Get-WtString -Key 'Cap.Loss.Limitations' -Arguments @((Get-WtText -Value $Impact.Limitations))))
        }
    }

    if ($Impacts.Count -gt $MaxLines)
    {
        $Lines.Add((Get-WtString -Key 'Tui.Pending.MoreWarnings' -Arguments @($Impacts.Count - $MaxLines)))
    }

    if ($NotApplicable.Count -gt 0)
    {
        if ($Lines.Count -lt $MaxLines)
        {
            $Lines.Add('')
            $Lines.Add((Get-WtString -Key 'Cap.Loss.NotApplicableTitle') + ':')
            foreach ($Row in $NotApplicable)
            {
                if ($Lines.Count -ge $MaxLines)
                {
                    $Lines.Add((Get-WtString -Key 'Tui.Pending.MoreWarnings' -Arguments @($NotApplicable.Count)))
                    break
                }
                $Lines.Add("  " + (Get-WtString -Key 'Cap.Loss.NotApplicable' -Arguments @((Get-WtText -Value $Row.Names), $Row.TweakId)))
            }
        }
    }

    return @{ Lines = $Lines.ToArray(); Count = $Impacts.Count }
}

<#
.SYNOPSIS
    Builds the selection shape the aggregator consumes from a pending set plus a plan.
.DESCRIPTION
    The pending entries carry Tweak objects; the plan's Apply items carry only ids, so they
    are resolved here. The result is a flat list of @{ Tweak; State } for the aggregator.
.OUTPUTS
    Array of @{ Tweak; State }.
#>
function Get-WtSelectionForCapabilityLossInternal
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param
    (
        [Parameter(Mandatory = $false)][object]$State,
        [Parameter(Mandatory = $false)][object]$Plan
    )

    $Selection = [System.Collections.Generic.List[object]]::new()

    if ($State)
    {
        foreach ($Key in $State.Pending.Keys)
        {
            $Entry = $State.Pending[$Key]
            $Tweak = Get-WtTweakInternal -Id $Entry.Id
            if ($Tweak)
            {
                $Selection.Add(@{ Tweak = $Tweak; State = [string]$Entry.Target })
            }
        }
    }

    if ($Plan)
    {
        foreach ($Item in @($Plan.Items | Where-Object { $_.Action -eq 'Apply' }))
        {
            $Known = @($Selection | Where-Object { $_.Tweak.Id -eq $Item.Id })
            if ($Known.Count -gt 0) { continue }

            $Tweak = Get-WtTweakInternal -Id $Item.Id
            if ($Tweak)
            {
                $Selection.Add(@{ Tweak = $Tweak; State = [string]$Item.State })
            }
        }
    }

    return @($Selection.ToArray())
}
