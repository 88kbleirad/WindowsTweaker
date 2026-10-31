# Validates the insight invariants - sanity rules, exclusive groups and recommendation links -
# without touching the system.
#
# These are the invariants that span two documents. The loader already refuses a malformed
# document; what it cannot check is whether the *pair* of documents agrees: a rule that advertises
# a reviewed remediation whose definition does not repair that finding, a repair that names a rule
# or probe that does not exist, or an eligible item that can never be selected because it does not
# state a documented reason. Each one is a silent authoring mistake, so it is a failure here.
#
# Usage:
#   pwsh -NoProfile -File tools/Test-Insight.ps1

[CmdletBinding()]
param ()

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Path $PSScriptRoot -Parent
$env:WT_LANG = 'en'

$Manifest = Join-Path $Root 'src/WindowsTweaker/WindowsTweaker.psd1'
try
{
    Import-Module $Manifest -Force -ErrorAction Stop
}
catch
{
    Write-Host ("The module could not be loaded, so the insight data cannot be validated:")
    Write-Host ("  {0}" -f $_.Exception.Message)
    exit 1
}

# A rule registry that failed to validate leaves the scan inactive. That is a failure of this
# check, not an empty rule set: the comparison below would otherwise pass trivially.
$RuleErrors = @(& (Get-Module WindowsTweaker) { @($Script:WtRuleErrors) })
if ($RuleErrors.Count -gt 0)
{
    Write-Host ("The sanity rule registry was refused ({0} problem(s)):" -f $RuleErrors.Count)
    foreach ($Problem in $RuleErrors) { Write-Host ("  {0}" -f $Problem) }
    exit 1
}

$Violations = [System.Collections.Generic.List[object]]::new()

function Add-Violation
{
    param ([string]$Subject, [string]$Rule, [string]$Detail)

    $script:Violations.Add([pscustomobject]@{ Subject = $Subject; Rule = $Rule; Detail = $Detail })
}

$Rules = @(Get-WtSanityRule)
$Tweaks = @(Get-WtTweak)
$Definitions = @(Get-WtTweakDefinitionView -Filter definitions)

Write-Host ("Sanity rules      : {0}" -f $Rules.Count)
Write-Host ("Catalog tweaks    : {0}" -f $Tweaks.Count)

foreach ($Rule in $Rules)
{
    # A rule whose every probe is optional can never report Incomplete, so an unreadable probe would
    # quietly leave the rule Clean. The shipped rules must have at least one required probe.
    $Required = @($Rule.Probes | Where-Object { $_['required'] })
    if ($Required.Count -eq 0)
    {
        Add-Violation -Subject $Rule.Id -Rule 'NoRequiredProbe' -Detail 'every probe is optional, so the rule can never report Incomplete'
    }

    if ([int]$Rule.Revision -lt 1)
    {
        Add-Violation -Subject $Rule.Id -Rule 'Revision' -Detail "revision is $($Rule.Revision)"
    }

    foreach ($Probe in @($Rule.Probes))
    {
        if ([string]::IsNullOrWhiteSpace([string]$Probe['claim']))
        {
            Add-Violation -Subject "$($Rule.Id)/$($Probe['id'])" -Rule 'ProbeClaim' -Detail 'the probe states no claim'
        }
    }
}

# The findings a rule can produce are '<rule id>' and '<rule id>/<probe id>'.
$RuleIndex = @{}
foreach ($Rule in $Rules)
{
    $RuleIndex[$Rule.Id] = @($Rule.Probes | ForEach-Object { [string]$_['id'] })
}

function Test-FindingReference
{
    param ([string]$Subject, [string]$Reference)

    $Parts = $Reference.Split('/')
    if (-not $script:RuleIndex.ContainsKey($Parts[0]))
    {
        Add-Violation -Subject $Subject -Rule 'UnknownFindingRule' -Detail "'$Reference' names a rule that does not exist"
        return $false
    }

    if ($Parts.Count -gt 1 -and $script:RuleIndex[$Parts[0]] -notcontains $Parts[1])
    {
        Add-Violation -Subject $Subject -Rule 'UnknownFindingProbe' -Detail "'$Reference' names a probe that '$($Parts[0])' does not declare"
        return $false
    }

    return $true
}

foreach ($Definition in $Definitions)
{
    $Tweak = @($Tweaks | Where-Object { $_.Id -eq $Definition.Id } | Select-Object -First 1)
    if ($Tweak.Count -eq 0) { continue }
    $Tweak = $Tweak[0]

    $Recommendation = if (@($Tweak.PSObject.Properties.Name) -contains 'DefinitionRecommendation') { $Tweak.DefinitionRecommendation } else { $null }
    if (-not $Recommendation) { continue }

    $Kind = [string]$Recommendation.Kind
    $Policy = [string]$Recommendation.Policy
    $RequiresFinding = [string]$Recommendation.RequiresFinding

    # An eligible item that never states its reason rests on documentation is offered at most, so
    # the claim would read as a recommendation while behaving as a manual note.
    if ($Policy -eq 'Eligible' -and -not [bool]$Recommendation.Documented)
    {
        Add-Violation -Subject $Definition.Id -Rule 'EligibleNotDocumented' -Detail 'policy is Eligible but documented is not true, so the item can never be selected automatically'
    }

    if ($Kind -eq 'Repair')
    {
        if (-not $RequiresFinding)
        {
            Add-Violation -Subject $Definition.Id -Rule 'RepairWithoutFinding' -Detail 'a repair must name the finding it addresses'
        }
        elseif (Test-FindingReference -Subject $Definition.Id -Reference $RequiresFinding)
        {
            # The rule that produces the finding must point back at this definition, or the review
            # would advertise one remediation and the proposal another.
            $Parts = $RequiresFinding.Split('/')
            $Rule = @($Rules | Where-Object { $_.Id -eq $Parts[0] })[0]
            $Remediation = $Rule.Remediation
            if ([string]$Remediation.Kind -ne 'Tweak' -or [string]$Remediation.Tweak -ne $Definition.Id)
            {
                Add-Violation -Subject $Definition.Id -Rule 'FindingNotLinkedBack' -Detail "'$($Parts[0])' does not link back to $($Definition.Id) as its reviewed remediation"
            }
        }
    }
    elseif ($RequiresFinding)
    {
        Add-Violation -Subject $Definition.Id -Rule 'FindingOnNonRepair' -Detail "kind $Kind must not name a finding"
    }

    if ($Kind -eq 'Diagnostic' -and $Policy -eq 'Eligible')
    {
        # Diagnostics are never selected automatically by the engine, so an Eligible diagnostic is
        # a claim that cannot be honoured.
        Add-Violation -Subject $Definition.Id -Rule 'EligibleDiagnostic' -Detail 'a diagnostic is never selected automatically'
    }
}

foreach ($Rule in $Rules)
{
    $Remediation = $Rule.Remediation
    if ([string]$Remediation.Kind -ne 'Tweak') { continue }

    $Tweak = @($Tweaks | Where-Object { $_.Id -eq $Remediation.Tweak } | Select-Object -First 1)
    if ($Tweak.Count -eq 0)
    {
        Add-Violation -Subject $Rule.Id -Rule 'UnknownRemediation' -Detail "'$($Remediation.Tweak)' does not exist in the catalog"
        continue
    }

    $Recommendation = if (@($Tweak[0].PSObject.Properties.Name) -contains 'DefinitionRecommendation') { $Tweak[0].DefinitionRecommendation } else { $null }
    if (-not $Recommendation -or [string]$Recommendation.Kind -ne 'Repair')
    {
        Add-Violation -Subject $Rule.Id -Rule 'RemediationNotRepair' -Detail "'$($Remediation.Tweak)' is not declared as a repair"
        continue
    }

    $Requires = [string]$Recommendation.RequiresFinding
    if ($Requires -and $Requires.Split('/')[0] -ne $Rule.Id)
    {
        Add-Violation -Subject $Rule.Id -Rule 'RemediationFindingMismatch' -Detail "'$($Remediation.Tweak)' repairs '$Requires', not '$($Rule.Id)'"
    }
}

# A group must be one setting with alternatives. The loader enforces the shape; what is worth
# checking here is that the shipped group is usable: at least two alternatives, each of them
# reported with a label and an intent.
foreach ($Definition in @($Definitions | Where-Object { $_.Group }))
{
    $Group = $Definition.Group
    if (@($Group.Options).Count -lt 2)
    {
        Add-Violation -Subject $Definition.Id -Rule 'GroupOptions' -Detail 'a group needs at least two alternatives'
    }

    foreach ($Option in @($Group.Options))
    {
        if (-not $Option.Labels) { Add-Violation -Subject "$($Definition.Id)/$($Option.Id)" -Rule 'GroupLabel' -Detail 'the alternative has no labels' }
        if ([string]$Option.Intent -notin 'Configured', 'WindowsDefault') { Add-Violation -Subject "$($Definition.Id)/$($Option.Id)" -Rule 'GroupIntent' -Detail "intent '$($Option.Intent)' is not supported" }
    }
}

Write-Host ''
if ($Violations.Count -eq 0)
{
    Write-Host 'No insight invariant violation.'
    exit 0
}

Write-Host ("Violations: {0}" -f $Violations.Count)
foreach ($Violation in $Violations)
{
    Write-Host ("  [{0}] {1}: {2}" -f $Violation.Rule, $Violation.Subject, $Violation.Detail)
}

exit 1
