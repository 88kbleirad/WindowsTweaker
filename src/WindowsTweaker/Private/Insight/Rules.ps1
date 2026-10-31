# WindowsTweaker - sanity rule registry: constants, validation and loading.
#
# Rules are data (Data/Insight/rules.json). A rule states one documented claim, cites the page it
# came from, and declares what it *cannot* conclude. It contains probes, never code: the probe
# kinds below are the whole vocabulary, and each one is implemented in PowerShell with fixed,
# read-only behaviour. A rule document therefore cannot make the scanner run a command, resolve a
# reference, download anything or write to the system.
#
# Strictness is the same as the catalog's: unknown keys, unknown probe kinds, unknown comparison
# operators, an unsupported schema version and a duplicate rule id are all errors, so a typo fails
# loudly instead of silently weakening a check.

$Script:WtRulesSchemaVersion = 1
$Script:WtRuleAreas = @('Boot', 'Mmcss', 'Tcp', 'Power', 'Restart')
$Script:WtRuleSeverities = @('Info', 'Low', 'Medium')
$Script:WtRuleSupportedOS = @('Windows10', 'Windows11')
$Script:WtRuleEffective = @('Observed', 'Inferred', 'Unknown')
$Script:WtProbeKinds = @('RegistryValue', 'RegistryPair', 'RegistryValuesUnderKey', 'PendingRestart', 'BcdEntry')
$Script:WtProbeReviewWhen = @('Present', 'Absent', 'NotIn', 'GreaterThan', 'NonEmpty')
$Script:WtRuleRemediationKinds = @('None', 'Manual', 'Tweak')
$Script:WtRuleDocumentKeys = @('schemaVersion', 'kind', 'id', 'version', 'description', 'rules')
$Script:WtRuleKeys = @(
    'id', 'revision', 'area', 'title', 'rationale', 'severity', 'effective', 'supportedOS', 'minBuild',
    'source', 'limitations', 'expected', 'nextStep', 'remediation', 'probes'
)
$Script:WtRuleProbeKeys = @(
    'id', 'required', 'kind', 'hive', 'key', 'name', 'settings', 'reviewWhen', 'values', 'value',
    'conditions', 'expect', 'claim', 'source'
)
$Script:WtRuleSourceKeys = @('url', 'title', 'claim', 'checkedUtc')
$Script:WtRules = @()
$Script:WtRuleErrors = @()

<#
.SYNOPSIS
    Path of the sanity rule registry (WT_RULES_PATH overrides it).
#>
function Get-WtRulePath
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    if ($env:WT_RULES_PATH)
    {
        return [System.IO.Path]::GetFullPath($env:WT_RULES_PATH)
    }

    return (Join-Path (Join-Path $Script:WtDataDirectory 'Insight') 'rules.json')
}

<#
.SYNOPSIS
    Validates one rule document.
.OUTPUTS
    @{ Errors; Rules }
#>
function Test-WtRuleDocument
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Document)

    $Errors = [System.Collections.Generic.List[string]]::new()
    $Rules = [System.Collections.Generic.List[object]]::new()
    $Add = { param ([string]$Message) if ($Errors.Count -lt $Script:WtCatalogLimits.MaxErrors) { $Errors.Add($Message) } }

    foreach ($Problem in (Test-WtCatalogKeys -Table $Document -Allowed $Script:WtRuleDocumentKeys -Path '$')) { & $Add $Problem }

    $Version = 0
    try { $Version = [int]$Document['schemaVersion'] } catch { & $Add '$.schemaVersion : must be an integer.' }
    if ($Version -ne $Script:WtRulesSchemaVersion) { & $Add "$.schemaVersion : version $Version is not supported (supported: $($Script:WtRulesSchemaVersion))." }
    if ([string]$Document['kind'] -ne 'Rules') { & $Add "$.kind : must be 'Rules'." }

    $RuleList = @($Document['rules'])
    if ($RuleList.Count -eq 0) { & $Add '$.rules : at least one rule is required.' }
    if ($RuleList.Count -gt 128) { & $Add '$.rules : at most 128 rules per document.' }

    $Seen = @{}
    foreach ($Rule in $RuleList)
    {
        $Path = '$.rules[]'

        if ($Rule -isnot [System.Collections.IDictionary])
        {
            & $Add "$Path : every rule must be an object."
            continue
        }

        foreach ($Problem in (Test-WtCatalogKeys -Table $Rule -Allowed $Script:WtRuleKeys -Path $Path)) { & $Add $Problem }

        $Id = [string]$Rule['id']
        if ($Id -notmatch '^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z0-9][A-Za-z0-9_-]*)+$')
        {
            & $Add "$Path.id : '$Id' is not a rule id (for example 'Tcp.LegacyReceiveWindow')."
        }
        elseif ($Seen.ContainsKey($Id))
        {
            & $Add "$Path.id : '$Id' is declared twice."
        }
        else
        {
            $Seen[$Id] = $true
        }

        # Numbers arrive from the JSON reader as doubles, so an integral, in-range value is checked
        # here instead of being trusted to a cast that would either round silently or throw.
        $Revision = 0
        if (-not $Rule.Contains('revision'))
        {
            & $Add "$Path.revision : required; state which revision of the claim this rule records (an integer of at least 1)."
        }
        else
        {
            $RevisionValue = $Rule['revision']
            $RevisionOk = $false
            if ($null -ne $RevisionValue -and $RevisionValue -isnot [bool] -and $RevisionValue -isnot [System.Collections.IDictionary])
            {
                try
                {
                    $RevisionNumber = [double]$RevisionValue
                    if ([Math]::Floor($RevisionNumber) -eq $RevisionNumber -and $RevisionNumber -ge 1 -and $RevisionNumber -le [int]::MaxValue)
                    {
                        $Revision = [int]$RevisionNumber
                        $RevisionOk = $true
                    }
                }
                catch
                {
                    $RevisionOk = $false
                }
            }

            if (-not $RevisionOk) { & $Add "$Path.revision : must be an integer of at least 1." }
        }

        $MinBuild = 0
        if ($Rule.Contains('minBuild'))
        {
            $BuildValue = $Rule['minBuild']
            $BuildOk = $false
            if ($null -ne $BuildValue -and $BuildValue -isnot [bool] -and $BuildValue -isnot [System.Collections.IDictionary])
            {
                try
                {
                    $BuildNumber = [double]$BuildValue
                    if ([Math]::Floor($BuildNumber) -eq $BuildNumber -and $BuildNumber -ge 0 -and $BuildNumber -le [int]::MaxValue)
                    {
                        $MinBuild = [int]$BuildNumber
                        $BuildOk = $true
                    }
                }
                catch
                {
                    $BuildOk = $false
                }
            }

            if (-not $BuildOk) { & $Add "$Path.minBuild : must be a non-negative integer." }
        }

        if ($Rule.Contains('supportedOS'))
        {
            foreach ($Entry in @($Rule['supportedOS']))
            {
                if ([string]$Entry -notin $Script:WtRuleSupportedOS)
                {
                    & $Add "$Path.supportedOS : '$Entry' is not a supported operating system ($($Script:WtRuleSupportedOS -join ', '))."
                }
            }
        }

        if ([string]$Rule['area'] -notin $Script:WtRuleAreas) { & $Add "$Path.area : '$($Rule['area'])' is not a supported area ($($Script:WtRuleAreas -join ', '))." }
        if ([string]$Rule['severity'] -notin $Script:WtRuleSeverities) { & $Add "$Path.severity : '$($Rule['severity'])' is not a supported severity ($($Script:WtRuleSeverities -join ', '))." }
        if ([string]$Rule['effective'] -notin $Script:WtRuleEffective) { & $Add "$Path.effective : '$($Rule['effective'])' is not a supported evidence kind ($($Script:WtRuleEffective -join ', '))." }

        foreach ($Field in 'title', 'rationale', 'limitations', 'expected', 'nextStep')
        {
            if (-not $Rule.Contains($Field))
            {
                & $Add "$Path.$Field : required."
                continue
            }

            foreach ($Problem in (Test-WtCatalogLocalized -Value $Rule[$Field] -Path "$Path.$Field")) { & $Add $Problem }
        }

        if (-not $Rule.Contains('source'))
        {
            & $Add "$Path.source : required; a rule without a source is an opinion."
        }
        elseif ($Rule['source'] -isnot [System.Collections.IDictionary])
        {
            & $Add "$Path.source : must be an object."
        }
        else
        {
            foreach ($Problem in (Test-WtCatalogKeys -Table $Rule['source'] -Allowed $Script:WtRuleSourceKeys -Path "$Path.source")) { & $Add $Problem }
            $Url = [string]$Rule['source']['url']
            if ($Url -notmatch '^https://') { & $Add "$Path.source.url : must be an https:// URL." }
            if ([string]::IsNullOrWhiteSpace([string]$Rule['source']['claim'])) { & $Add "$Path.source.claim : state the specific claim this source supports." }
        }

        $Remediation = $Rule['remediation']
        if ($Remediation -isnot [System.Collections.IDictionary])
        {
            & $Add "$Path.remediation : required (kind None, Manual or Tweak)."
        }
        else
        {
            foreach ($Problem in (Test-WtCatalogKeys -Table $Remediation -Allowed @('kind', 'tweak', 'notes') -Path "$Path.remediation")) { & $Add $Problem }
            $Kind = [string]$Remediation['kind']
            if ($Kind -notin $Script:WtRuleRemediationKinds) { & $Add "$Path.remediation.kind : '$Kind' is not supported ($($Script:WtRuleRemediationKinds -join ', '))." }
            if ($Kind -eq 'Tweak')
            {
                $TweakId = [string]$Remediation['tweak']
                if ($TweakId -notmatch $Script:WtTweakIdPattern) { & $Add "$Path.remediation.tweak : '$TweakId' is not a tweak id." }
                elseif (-not $Script:WtCatalog.Contains($TweakId)) { & $Add "$Path.remediation.tweak : '$TweakId' does not exist in this catalog." }
            }

            if ($Remediation.Contains('notes'))
            {
                foreach ($Problem in (Test-WtCatalogLocalized -Value $Remediation['notes'] -Path "$Path.remediation.notes")) { & $Add $Problem }
            }
        }

        $Probes = @($Rule['probes'])
        if ($Probes.Count -eq 0) { & $Add "$Path.probes : at least one probe is required." }

        $ProbeIds = @{}
        foreach ($Probe in $Probes)
        {
            $ProbePath = "$Path.probes[]"

            if ($Probe -isnot [System.Collections.IDictionary])
            {
                & $Add "$ProbePath : every probe must be an object."
                continue
            }

            foreach ($Problem in (Test-WtCatalogKeys -Table $Probe -Allowed $Script:WtRuleProbeKeys -Path $ProbePath)) { & $Add $Problem }

            # 'required' is what makes the "never report Clean when a probe could not be read"
            # guarantee structural: a probe that omits it would default to optional and quietly
            # stop forcing Incomplete, so the key itself is mandatory and must be a boolean.
            if (-not $Probe.Contains('required'))
            {
                & $Add "$ProbePath.required : required; state whether an unreadable probe makes this rule Incomplete (true or false)."
            }
            elseif ($Probe['required'] -isnot [bool])
            {
                & $Add "$ProbePath.required : must be true or false."
            }

            $ProbeId = [string]$Probe['id']
            if ($ProbeId -notmatch '^[a-z][a-z0-9-]*$') { & $Add "$ProbePath.id : '$ProbeId' is not a probe id (lower case, digits and dashes)." }
            elseif ($ProbeIds.ContainsKey($ProbeId)) { & $Add "$ProbePath.id : '$ProbeId' is declared twice." }
            else { $ProbeIds[$ProbeId] = $true }

            $Kind = [string]$Probe['kind']
            if ($Kind -notin $Script:WtProbeKinds) { & $Add "$ProbePath.kind : '$Kind' is not a supported probe kind ($($Script:WtProbeKinds -join ', '))." }
            if ([string]$Probe['reviewWhen'] -notin $Script:WtProbeReviewWhen) { & $Add "$ProbePath.reviewWhen : '$($Probe['reviewWhen'])' is not supported ($($Script:WtProbeReviewWhen -join ', '))." }

            if ($Kind -in 'RegistryValue', 'RegistryPair', 'RegistryValuesUnderKey')
            {
                if ($Script:WtCatalogRegistryHives -notcontains [string]$Probe['hive']) { & $Add "$ProbePath.hive : '$($Probe['hive'])' is not a supported hive." }
                if ([string]::IsNullOrWhiteSpace([string]$Probe['key'])) { & $Add "$ProbePath.key : required." }
                if ([string]$Probe['key'] -match '^(HKLM|HKCU|HKCR|HKU|HKCC):') { & $Add "$ProbePath.key : omit the hive prefix here; it belongs in 'hive'." }
                if (-not $Probe.Contains('name')) { & $Add "$ProbePath.name : required; use an empty string for the default value." }
            }

            if ($Kind -eq 'RegistryPair')
            {
                $Conditions = @($Probe['conditions'])
                if ($Conditions.Count -eq 0) { & $Add "$ProbePath.conditions : a paired probe needs at least one condition." }
                foreach ($Condition in $Conditions)
                {
                    if ($Condition -isnot [System.Collections.IDictionary]) { & $Add "$ProbePath.conditions[] : every condition must be an object."; continue }
                    foreach ($Problem in (Test-WtCatalogKeys -Table $Condition -Allowed @('name', 'equals') -Path "$ProbePath.conditions[]")) { & $Add $Problem }
                    if (-not $Condition.Contains('name')) { & $Add "$ProbePath.conditions[].name : required." }
                    if (-not $Condition.Contains('equals')) { & $Add "$ProbePath.conditions[].equals : required." }
                }
            }

            if ($Kind -eq 'BcdEntry')
            {
                $Settings = @($Probe['settings'])
                if ($Settings.Count -eq 0) { & $Add "$ProbePath.settings : name at least one boot-entry setting." }
                foreach ($Setting in $Settings)
                {
                    if ($Setting -notmatch '^[a-z][a-z0-9]*$') { & $Add "$ProbePath.settings : '$Setting' is not a boot-entry setting name." }
                }
            }

            if ([string]$Probe['reviewWhen'] -eq 'NotIn' -and @($Probe['values']).Count -eq 0)
            {
                & $Add "$ProbePath.values : 'NotIn' needs the documented set of values."
            }
            if ([string]$Probe['reviewWhen'] -eq 'GreaterThan' -and -not $Probe.Contains('value'))
            {
                & $Add "$ProbePath.value : 'GreaterThan' needs a comparison value."
            }
            if (-not $Probe.Contains('expect')) { & $Add "$ProbePath.expect : state the documented expectation." }

            if ($Probe.Contains('source'))
            {
                if ($Probe['source'] -isnot [System.Collections.IDictionary]) { & $Add "$ProbePath.source : must be an object." }
                else
                {
                    foreach ($Problem in (Test-WtCatalogKeys -Table $Probe['source'] -Allowed $Script:WtRuleSourceKeys -Path "$ProbePath.source")) { & $Add $Problem }
                }
            }
        }

        if ($Errors.Count -eq 0)
        {
            $Rules.Add(@{
                    Id          = $Id
                    Revision    = $Revision
                    Area        = [string]$Rule['area']
                    Title       = $Rule['title']
                    Rationale   = $Rule['rationale']
                    Severity    = [string]$Rule['severity']
                    Effective   = [string]$Rule['effective']
                    SupportedOS = @($Rule['supportedOS'])
                    MinBuild    = $MinBuild
                    Source      = @{ Url = [string]$Rule['source']['url']; Title = [string]$Rule['source']['title']; Claim = [string]$Rule['source']['claim']; CheckedUtc = [string]$Rule['source']['checkedUtc'] }
                    Limitations = $Rule['limitations']
                    Expected    = $Rule['expected']
                    NextStep    = $Rule['nextStep']
                    Remediation = if ($Remediation['kind'] -eq 'Tweak')
                    {
                        @{ Kind = 'Tweak'; Tweak = [string]$Remediation['tweak']; Notes = $Remediation['notes'] }
                    }
                    else
                    {
                        @{ Kind = [string]$Remediation['kind']; Tweak = ''; Notes = $Remediation['notes'] }
                    }
                    Probes      = @($Probes)
                    Document    = $Rule
                })
        }
    }

    return @{ Errors = @($Errors.ToArray()); Rules = @($Rules.ToArray()) }
}

<#
.SYNOPSIS
    Loads and validates the rule registry.
.DESCRIPTION
    Read-only. A missing registry disables the scan (it is optional); an invalid one is reported
    and inactive, because a rule that cannot be trusted must not silently produce findings.
#>
function Import-WtSanityRuleRegistry
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][string]$Path)

    if (-not $Path) { $Path = Get-WtRulePath }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        $Script:WtRules = @()
        $Script:WtRuleErrors = @()
        return @{ Path = $Path; Rules = @(); Errors = @(); Present = $false }
    }

    $Read = Read-WtCatalogJson -Path $Path
    if (-not $Read.Ok)
    {
        $Script:WtRules = @()
        $Script:WtRuleErrors = @($Read.Errors)
        return @{ Path = $Path; Rules = @(); Errors = @($Read.Errors); Present = $true }
    }

    $Document = ConvertFrom-WtCatalogElement -Element $Read.Document.RootElement
    $Read.Document.Dispose()

    $Tested = Test-WtRuleDocument -Document $Document
    if ($Tested.Errors.Count -gt 0)
    {
        $Script:WtRules = @()
        $Script:WtRuleErrors = @($Tested.Errors)
        return @{ Path = $Path; Rules = @(); Errors = @($Tested.Errors); Present = $true }
    }

    $Script:WtRules = @($Tested.Rules)
    $Script:WtRuleErrors = @()
    return @{ Path = $Path; Rules = @($Tested.Rules); Errors = @(); Present = $true }
}

<#
.SYNOPSIS
    Returns the loaded rules, optionally one rule by id.
#>
function Get-WtSanityRuleInternal
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][string]$Id)

    if ($Id) { return @($Script:WtRules | Where-Object { $_.Id -eq $Id }) }
    return @($Script:WtRules)
}
