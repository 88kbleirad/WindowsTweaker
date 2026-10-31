# WindowsTweaker - one view of a definition, shared by the command line and the interface.
#
# A definition carries several kinds of statement that must not be blended together:
#
#   structural     the loader validated the document (fields, enums, boundaries, targets);
#   provider       the detection and the operations are exercised by the provider tests;
#   Windows        somebody observed the behaviour on a real Windows build;
#   author         an imported pack says so about itself.
#
# Support status below never upgrades a claim: a pack can only ever be AuthorClaimed, and
# WindowsValidated is reported only for a definition whose evidence records an actual build.
# Everything else is reported as what it is, and "Unverified" is a legitimate answer.

<#
.SYNOPSIS
    Returns the support status that can actually be vouched for on this machine.
.OUTPUTS
    Structural, ProviderTested, WindowsValidated, AuthorClaimed, Unsupported or Unverified.
#>
function Get-WtSupportStatusInternal
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][object]$Tweak)

    if ($Tweak.Lifecycle -in 'Unsupported', 'Deprecated', 'Restore-only')
    {
        return 'Unsupported'
    }

    $Source = if (@($Tweak.PSObject.Properties.Name) -contains 'DefinitionSource') { [string]$Tweak.DefinitionSource } else { 'BuiltIn' }
    $Evidence = if (@($Tweak.PSObject.Properties.Name) -contains 'DefinitionEvidence') { $Tweak.DefinitionEvidence } else { $null }

    if ($Source -eq 'Pack')
    {
        # An imported document cannot authorize trust. What it claims is recorded as a claim.
        if ($Evidence -and $Evidence.WindowsIntegration -and $Evidence.WindowsIntegration.Result -notin '', 'Unverified')
        {
            return 'AuthorClaimed'
        }

        return 'Unverified'
    }

    if ($Evidence -and $Evidence.WindowsIntegration -and [string]$Evidence.WindowsIntegration.Result -eq 'WindowsValidated')
    {
        return 'WindowsValidated'
    }

    if ($Evidence -and [string]$Evidence.ProviderTests -in 'ProviderTested', 'WindowsValidated')
    {
        return 'ProviderTested'
    }

    return 'Structural'
}

<#
.SYNOPSIS
    Builds the display row for one tweak, definition-backed or not.
.DESCRIPTION
    Pure data: every field is either an id, a number, a boolean or a string-table key, so the
    command line and the interface render the same row in the active language.
.OUTPUTS
    Ordered hashtable with Id, Category, Name, Lifecycle, Scope, Privilege, Risk, Restart,
    Rollback, States, DefaultState, Source (BuiltIn/PowerShell/Pack), PackId, Support,
    Evidence, Requires, RunAfter, ConflictsWith, Tags, Revision and Backed (bool).
#>
function Get-WtDefinitionRowInternal
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Tweak)

    $Backed = [bool](@($Tweak.PSObject.Properties.Name) -contains 'DefinitionDocument')
    $Evidence = if ($Backed) { $Tweak.DefinitionEvidence } else { $null }

    return [ordered]@{
        Id            = [string]$Tweak.Id
        Category      = [string]$Tweak.Category
        Name          = $Tweak.Name
        Lifecycle     = [string]$Tweak.Lifecycle
        Scope         = [string]$Tweak.Scope
        Privilege     = [string]$Tweak.Privilege
        Risk          = [string]$Tweak.Risk
        Restart       = [string]$Tweak.Restart
        Rollback      = [string]$Tweak.Rollback
        States        = @($Tweak.StateNames)
        DefaultState  = [string]$Tweak.DefaultState
        Backed        = $Backed
        Source        = if (-not $Backed) { 'PowerShell' } elseif ([string]$Tweak.DefinitionSource -eq 'Pack') { 'Pack' } else { 'BuiltIn' }
        PackId        = if ($Backed) { [string]$Tweak.DefinitionPackId } else { '' }
        Revision      = if ($Backed) { [int]$Tweak.DefinitionRevision } else { 0 }
        Support       = Get-WtSupportStatusInternal -Tweak $Tweak
        Evidence      = @{
            Structural    = if ($Backed) { [string]$Evidence.Structural } else { '' }
            ProviderTests = if ($Backed) { [string]$Evidence.ProviderTests } else { '' }
            Windows       = if ($Backed -and $Evidence.WindowsIntegration) { [string]$Evidence.WindowsIntegration.Result } else { '' }
            AuthorClaimed = if ($Backed) { [bool]$Evidence.AuthorClaimed } else { $false }
        }
        Requires      = @(Get-WtDefinitionList -Tweak $Tweak -Name 'DefinitionRequires')
        RunAfter      = @(Get-WtDefinitionList -Tweak $Tweak -Name 'DefinitionRunAfter')
        ConflictsWith = @(Get-WtDefinitionList -Tweak $Tweak -Name 'DefinitionConflictsWith')
        Tags          = if ($Backed) { @($Tweak.DefinitionTags) } else { @() }
        Tweak         = $Tweak
    }
}

<#
.SYNOPSIS
    Tests a definition row against one filter expression.
.DESCRIPTION
    Filters keep the vocabulary of the fields: 'definitions', 'powershell', 'pack:<id>',
    'scope:<User|Machine|UserAndMachine>', 'risk:<Low|Medium|High>', 'lifecycle:<name>',
    'evidence:<status>', 'support:<status>', 'category:<name>', 'tag:<name>', 'requires:<id>',
    'conflicts:<id>'. An unknown filter matches nothing and is reported by the caller, so a
    typo cannot silently show a different set than the user asked for.
.OUTPUTS
    $true when the row matches; $null when the filter expression itself is not understood.
#>
function Test-WtDefinitionFilterInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Row,
        [Parameter(Mandatory = $true)][string]$Filter
    )

    $Value = $Filter.Trim()
    if (-not $Value) { return $true }

    $Name = $Value
    $Argument = ''
    $Index = $Value.IndexOf(':')
    if ($Index -ge 0)
    {
        $Name = $Value.Substring(0, $Index)
        $Argument = $Value.Substring($Index + 1)
    }

    switch ($Name.ToLowerInvariant())
    {
        'definitions' { return [bool]$Row.Backed }
        'powershell' { return (-not $Row.Backed) }
        'pack' { return ($Row.Source -eq 'Pack' -and ($Argument -eq '' -or $Row.PackId -eq $Argument)) }
        'builtin' { return ($Row.Source -eq 'BuiltIn') }
        'scope' { return ($Row.Scope -eq $Argument) }
        'risk' { return ($Row.Risk -eq $Argument) }
        'lifecycle' { return ($Row.Lifecycle -eq $Argument) }
        'evidence' { return ($Row.Evidence.Structural -eq $Argument -or $Row.Evidence.ProviderTests -eq $Argument -or $Row.Evidence.Windows -eq $Argument) }
        'support' { return ($Row.Support -eq $Argument) }
        'category' { return ($Row.Category -eq $Argument) }
        'tag' { return (@($Row.Tags) -contains $Argument) }
        'requires' { return (@($Row.Requires) -contains $Argument) }
        'conflicts' { return (@($Row.ConflictsWith) -contains $Argument) }
        default { return $null }
    }
}

<#
.SYNOPSIS
    Filters definition rows, reporting filters that are not understood.
.OUTPUTS
    @{ Rows; Unknown }
#>
function Select-WtDefinitionRowInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $false)][string[]]$Filter = @()
    )

    $Selected = @($Rows)
    $Unknown = [System.Collections.Generic.List[string]]::new()

    foreach ($Expression in @($Filter))
    {
        if ([string]::IsNullOrWhiteSpace($Expression)) { continue }

        $Matching = @()
        foreach ($Row in $Selected)
        {
            $Result = Test-WtDefinitionFilterInternal -Row $Row -Filter $Expression
            if ($null -eq $Result)
            {
                $Unknown.Add($Expression)
                $Matching = @()
                break
            }

            if ($Result) { $Matching += $Row }
        }

        if ($Unknown.Count -gt 0) { break }
        $Selected = @($Matching)
    }

    return @{ Rows = @($Selected); Unknown = @($Unknown.ToArray()) }
}
