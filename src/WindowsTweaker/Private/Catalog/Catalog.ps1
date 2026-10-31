# WindowsTweaker - declarative catalog: schema constants, strict JSON reader and validation.
#
# The catalog is *data*. Nothing in this file evaluates an expression, runs a script, resolves
# a remote reference or touches Windows: a definition is read, validated, and then registered
# through the existing New-WtRegistryTweak constructor, so detection, preview, journal,
# verification and recovery stay exactly the paths they already are.
#
# Strictness is the point of this file. A malformed or hostile document must fail loudly and
# cheaply, before anything is registered:
#   * the byte size, the nesting depth, the string lengths and the operation counts are bounded;
#   * duplicate JSON property names are an error (a plain ConvertFrom-Json would silently keep
#     the last one, which is exactly how a definition can be smuggled past a reviewer);
#   * unknown top-level keys, unknown schema versions, unknown operation kinds, unknown
#     registry types and unknown enum values are errors, not defaults;
#   * every error is reported with its document path, and the list is bounded.
#
# The JSON Schema in Data/Catalog/catalog.schema.json is the normative description of the
# document format for authors; a test asserts that the enums it declares and the enums below
# are the same, so the two cannot drift.

$Script:WtCatalogSchemaVersion = 1
$Script:WtCatalogEngineVersion = '1.0.0'

# Boundaries. A catalog that needs more than this is not a catalog, it is a dataset.
$Script:WtCatalogLimits = @{
    MaxDocumentBytes   = 262144   # 256 KiB per document
    MaxDepth           = 32       # JSON nesting
    MaxStringLength    = 4096     # any single string
    MaxTweaks          = 256      # per document
    MaxStatesPerTweak  = 8
    MaxOperations      = 16       # per state
    MaxErrors          = 100      # reported validation errors
    MaxTags            = 16
    MaxReferences      = 16
}

$Script:WtCatalogOperationKinds = @('RegistrySet', 'RegistryRemove')
$Script:WtCatalogRegistryHives = @('HKCU', 'HKLM', 'HKCR', 'HKU', 'HKCC')
$Script:WtCatalogRegistryViews = @('Default', 'Registry32', 'Registry64')
$Script:WtCatalogScopes = @('User', 'Machine', 'UserAndMachine')
$Script:WtCatalogPrivileges = @('None', 'Admin')
$Script:WtCatalogRestart = @('None', 'Explorer', 'SignOut', 'Reboot')
$Script:WtCatalogRollback = @('Full', 'Partial', 'None')
$Script:WtCatalogRisk = @('Low', 'Medium', 'High')
$Script:WtCatalogLifecycle = @('Available', 'Experimental', 'Unsupported', 'Deprecated', 'Restore-only')
$Script:WtCatalogArchitectures = @('Any', 'X64', 'Arm64', 'X86')
$Script:WtCatalogEvidenceStatus = @('Documented', 'Structural', 'ProviderTested', 'WindowsValidated', 'Unverified')
$Script:WtCatalogSources = @('BuiltIn', 'Pack')
$Script:WtCatalogLanguages = @('en', 'vi')

# Top-level keys, exactly. An unknown key is an error: it is either a typo that would silently
# do nothing, or an attempt to smuggle instructions past review.
$Script:WtCatalogDocumentKeys = @('schemaVersion', 'kind', 'id', 'version', 'minEngineVersion', 'author', 'description', 'tweaks', 'references')
$Script:WtCatalogTweakKeys = @(
    'id', 'revision', 'category', 'tags', 'names', 'descriptions', 'impacts', 'sideEffects',
    'scope', 'privilege', 'lifecycle', 'risk', 'restart', 'rollback', 'irreversible', 'dataDeletion',
    'reducesProtection', 'requires', 'runAfter', 'conflictsWith', 'requiresCapabilities',
    'supportedOS', 'minBuild', 'maxBuild', 'editions', 'architecture', 'hardware',
    'detection', 'states', 'defaultState', 'managedPolicy', 'references', 'evidence',
    'recommendation', 'effective', 'group', 'capabilityLoss'
)
$Script:WtCatalogCapabilityKinds = @('Guaranteed', 'Conditional', 'Unknown')
$Script:WtCatalogCapabilityKeys = @('capability', 'names', 'kind', 'temporary', 'condition', 'restoredBy', 'limitations')
$Script:WtCatalogCapabilityConditionKeys = @('explanation', 'requiresCapabilities')
$Script:WtCatalogMaxCapabilityImpacts = 16
$Script:WtCatalogMaxCapabilityConditionTokens = 16
$Script:WtCatalogRecommendationKeys = @('kind', 'policy', 'objectives', 'rationale', 'requiresFinding', 'documented')
$Script:WtCatalogEffectiveKeys = @('evidence', 'boundary', 'map', 'note')
$Script:WtCatalogGroupKeys = @('id', 'revision', 'labels', 'descriptions', 'options', 'notes')
$Script:WtCatalogGroupOptionKeys = @('id', 'intent', 'labels', 'descriptions')
$Script:WtRecommendationKinds = @('Optimization', 'Preference', 'Diagnostic', 'Repair')
$Script:WtRecommendationPolicies = @('Eligible', 'Manual', 'Never')
$Script:WtRecommendationObjectives = @('Balanced', 'Responsiveness', 'Gaming', 'PowerEfficiency', 'Privacy')
$Script:WtEffectiveBoundaries = @('None', 'Explorer', 'SignOut', 'Reboot')
$Script:WtGroupOptionIntents = @('Configured', 'WindowsDefault')
$Script:WtCatalogReferenceKeys = @('id', 'url', 'title', 'supports', 'status', 'checkedUtc')
$Script:WtCatalogEvidenceKeys = @('source', 'documentation', 'structural', 'providerTests', 'windowsIntegration', 'notes')
$Script:WtCatalogWindowsEvidenceKeys = @('build', 'edition', 'architecture', 'dateUtc', 'method', 'limitations', 'result')

<#
.SYNOPSIS
    Reads one JSON document with the strict options this file requires.
.DESCRIPTION
    Returns @{ Ok; Document; Errors; Bytes; Depth } - Document is $null when the document could
    not be parsed at all, and Errors carries every problem found (bounded).
    The reader deliberately does not convert to objects first: duplicate property names are
    detected by walking the parsed tree, which a plain conversion hides.
#>
function Read-WtCatalogJson
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Path)

    $Result = @{ Ok = $false; Document = $null; Errors = @(); Bytes = 0; Depth = 0 }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        $Result.Errors = @("The document does not exist: $Path")
        return $Result
    }

    $Bytes = (Get-Item -LiteralPath $Path).Length
    $Result.Bytes = [int]$Bytes
    if ($Bytes -gt $Script:WtCatalogLimits.MaxDocumentBytes)
    {
        $Result.Errors = @("The document is $Bytes bytes, above the $($Script:WtCatalogLimits.MaxDocumentBytes) byte limit.")
        return $Result
    }

    $Text = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($Text))
    {
        $Result.Errors = @('The document is empty.')
        return $Result
    }

    $Options = [System.Text.Json.JsonDocumentOptions]::new()
    $Options.AllowTrailingCommas = $false
    $Options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
    $Options.MaxDepth = $Script:WtCatalogLimits.MaxDepth

    $Document = $null
    try
    {
        $Document = [System.Text.Json.JsonDocument]::Parse($Text, $Options)
    }
    catch
    {
        $Message = $_.Exception.Message
        if ($_.Exception.InnerException) { $Message = $_.Exception.InnerException.Message }
        $Result.Errors = @("The document is not valid JSON: $Message")
        return $Result
    }

    $Errors = [System.Collections.Generic.List[string]]::new()

    # Walk the tree: duplicate property names, depth and type sanity are reported with a path.
    $Walk = {
        param ($Element, [string]$Path, [int]$Depth)

        $DepthValue = $Depth
        if ($DepthValue -gt $Result.Depth) { $Result.Depth = $DepthValue }

        if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object)
        {
            $Seen = @{}
            foreach ($Property in $Element.EnumerateObject())
            {
                $Name = [string]$Property.Name
                if ($Seen.ContainsKey($Name) -and $Errors.Count -lt $Script:WtCatalogLimits.MaxErrors)
                {
                    $Errors.Add("$Path.$Name : duplicate property name.")
                }
                $Seen[$Name] = $true

                if ($Property.Value.ValueKind -eq [System.Text.Json.JsonValueKind]::String)
                {
                    $Value = [string]$Property.Value.GetString()
                    if ($Value.Length -gt $Script:WtCatalogLimits.MaxStringLength -and $Errors.Count -lt $Script:WtCatalogLimits.MaxErrors)
                    {
                        $Errors.Add("$Path.$Name : string of $($Value.Length) characters exceeds the $($Script:WtCatalogLimits.MaxStringLength) character limit.")
                    }
                }

                & $Walk $Property.Value "$Path.$Name" ($DepthValue + 1)
            }

            return
        }

        if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array)
        {
            $Index = 0
            foreach ($Item in $Element.EnumerateArray())
            {
                & $Walk $Item "$Path[$Index]" ($DepthValue + 1)
                $Index++
            }
        }
    }

    & $Walk $Document.RootElement '$' 1

    $Result.Document = $Document
    $Result.Errors = @($Errors.ToArray())
    $Result.Ok = ($Errors.Count -eq 0)
    return $Result
}

<#
.SYNOPSIS
    Converts a parsed JSON element into a plain hashtable/array tree, preserving property order.
.DESCRIPTION
    PowerShell's ConvertFrom-Json is not used for documents: this conversion keeps every value
    as a string/number/bool/array/hashtable and never produces a script block, a type name or a
    resolved reference. Objects become ordered hashtables so the loader can require exact keys.
#>
function ConvertFrom-WtCatalogElement
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][System.Text.Json.JsonElement]$Element)

    switch ($Element.ValueKind)
    {
        ([System.Text.Json.JsonValueKind]::Object)
        {
            $Table = [ordered]@{}
            foreach ($Property in $Element.EnumerateObject())
            {
                $Table[$Property.Name] = ConvertFrom-WtCatalogElement -Element $Property.Value
            }
            return $Table
        }
        ([System.Text.Json.JsonValueKind]::Array)
        {
            $Items = @()
            foreach ($Item in $Element.EnumerateArray())
            {
                $Items += , (ConvertFrom-WtCatalogElement -Element $Item)
            }
            return , $Items
        }
        ([System.Text.Json.JsonValueKind]::String) { return [string]$Element.GetString() }
        ([System.Text.Json.JsonValueKind]::Number)
        {
            $Value = 0.0
            if ($Element.TryGetDouble([ref]$Value)) { return $Value }
            return [string]$Element.GetRawText()
        }
        ([System.Text.Json.JsonValueKind]::True) { return $true }
        ([System.Text.Json.JsonValueKind]::False) { return $false }
        default { return $null }
    }
}

<#
.SYNOPSIS
    Reports whether a table carries exactly the allowed keys.
.OUTPUTS
    An array of error strings (empty when the shape is right).
#>
function Test-WtCatalogKeys
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param
    (
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Table,
        [Parameter(Mandatory = $true)][string[]]$Allowed,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $Errors = [System.Collections.Generic.List[string]]::new()

    foreach ($Key in $Table.Keys)
    {
        if ($Allowed -notcontains $Key)
        {
            $Errors.Add("$Path.$Key : unknown property (allowed: $($Allowed -join ', ')).")
        }
    }

    return @($Errors.ToArray())
}

<#
.SYNOPSIS
    Validates one localized string map (en + vi, non-empty, no unknown languages).
#>
function Test-WtCatalogLocalized
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param
    (
        [Parameter(Mandatory = $false)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $Errors = [System.Collections.Generic.List[string]]::new()

    if ($null -eq $Value -or $Value -isnot [System.Collections.IDictionary])
    {
        $Errors.Add("$Path : localized text must be an object with one entry per language.")
        return @($Errors.ToArray())
    }

    foreach ($Key in $Value.Keys)
    {
        if ($Script:WtCatalogLanguages -notcontains $Key)
        {
            $Errors.Add("$Path.$Key : unknown language (supported: $($Script:WtCatalogLanguages -join ', ')).")
        }
    }

    foreach ($Language in $Script:WtCatalogLanguages)
    {
        $Text = [string]$Value[$Language]
        if ([string]::IsNullOrWhiteSpace($Text))
        {
            $Errors.Add("$Path.$Language : a non-empty string is required.")
        }
    }

    return @($Errors.ToArray())
}

<#
.SYNOPSIS
    Validates one Registry operation from a document.
.DESCRIPTION
    The hive, the key path, the value name, the type and the registry view are all explicit:
    an unnamed (default) value is written as `""` and is canonicalised the same way the target
    layer canonicalises it, so a catalog definition and a built-in definition cannot end up
    describing two different targets.
.OUTPUTS
    @{ Errors; Operation } - Operation is the descriptor the existing provider expects.
#>
function ConvertTo-WtCatalogRegistryOperation
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Definition,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $Errors = [System.Collections.Generic.List[string]]::new()
    $Allowed = @('kind', 'hive', 'key', 'name', 'type', 'value', 'view', 'user')
    foreach ($Problem in (Test-WtCatalogKeys -Table $Definition -Allowed $Allowed -Path $Path)) { $Errors.Add($Problem) }

    $Kind = [string]$Definition['kind']
    if ($Script:WtCatalogOperationKinds -notcontains $Kind -and -not $Errors.Count)
    {
        $Errors.Add("$Path.kind : '$Kind' is not a supported operation (supported: $($Script:WtCatalogOperationKinds -join ', ')).")
    }

    $Hive = [string]$Definition['hive']
    if ($Script:WtCatalogRegistryHives -notcontains $Hive)
    {
        $Errors.Add("$Path.hive : '$Hive' is not a supported hive (supported: $($Script:WtCatalogRegistryHives -join ', ')).")
    }

    $Key = [string]$Definition['key']
    if ([string]::IsNullOrWhiteSpace($Key))
    {
        $Errors.Add("$Path.key : a registry path is required.")
    }
    elseif ($Key -match '^(HKLM|HKCU|HKCR|HKU|HKCC):')
    {
        $Errors.Add("$Path.key : omit the hive prefix here; it belongs in '$Path.hive'.")
    }

    # An absent 'name' means the default (unnamed) value, which must stay distinguishable
    # from "no name was given at all" - so it is required to be present, and may be empty.
    if (-not $Definition.Contains('name'))
    {
        $Errors.Add("$Path.name : required; use an empty string for the default (unnamed) value.")
    }

    $View = if ($Definition.Contains('view')) { [string]$Definition['view'] } else { 'Default' }
    if ($Script:WtCatalogRegistryViews -notcontains $View)
    {
        $Errors.Add("$Path.view : '$View' is not a supported registry view (supported: $($Script:WtCatalogRegistryViews -join ', ')).")
    }

    $User = if ($Definition.Contains('user')) { [string]$Definition['user'] } else { 'CurrentUser' }
    if (@('CurrentUser') -notcontains $User)
    {
        $Errors.Add("$Path.user : '$User' is not supported (only 'CurrentUser' is implemented).")
    }

    $Operation = $null
    if ($Errors.Count -eq 0)
    {
        $FullPath = "${Hive}:\$Key"

        if ($Kind -eq 'RegistrySet')
        {
            $Type = [string]$Definition['type']
            $ResolvedType = Resolve-WtRegistryKind -Kind $Type
            if (-not $ResolvedType)
            {
                $Errors.Add("$Path.type : '$Type' is not a supported registry value type (String, ExpandString, Binary, DWord, MultiString, QWord).")
            }

            if (-not $Definition.Contains('value'))
            {
                $Errors.Add("$Path.value : required for RegistrySet (use 0 or an empty string deliberately; both are written as given).")
            }

            if ($Errors.Count -eq 0)
            {
                $Operation = @{
                    Kind  = 'RegistrySet'
                    Path  = $FullPath
                    Name  = [string]$Definition['name']
                    Type  = [string]$ResolvedType
                    Value = $Definition['value']
                }
            }
        }
        else
        {
            if ($Definition.Contains('type') -or $Definition.Contains('value'))
            {
                $Errors.Add("$Path : RegistryRemove does not take 'type' or 'value'; a restore never replays a written value, it replays the captured state.")
            }
            else
            {
                $Operation = @{
                    Kind = 'RegistryRemove'
                    Path = $FullPath
                    Name = [string]$Definition['name']
                }
            }
        }
    }

    return @{ Errors = @($Errors.ToArray()); Operation = $Operation }
}

<#
.SYNOPSIS
    Builds the canonical identity of a registry operation, for collision detection.
.DESCRIPTION
    Delegates to the target layer, so a catalog definition and a built-in tweak that name the
    same value produce the same identity string.
#>
function Get-WtCatalogOperationIdentity
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][hashtable]$Operation)

    return (Get-WtOperationIdentity -Operation $Operation)
}
