# WindowsTweaker - catalog document validation and registration.
#
# Two steps, deliberately separated:
#
#   Test-WtCatalogDocument   validates a parsed document and returns every error it finds.
#                            Nothing is registered, nothing is written, Windows is untouched.
#   Import-WtCatalogDocument registers the validated tweaks through the *existing*
#                            New-WtRegistryTweak constructor, so detection, preview, review
#                            fingerprint, journal, verification, compensation and rollback are
#                            the same code paths a built-in tweak uses. There is no second
#                            engine, no second journal and no second recovery store.
#
# What a definition cannot do, whatever it says: lower its own privilege requirement, lower its
# own risk floor, claim Windows-validated evidence for local content, address a hive or value
# type outside the documented vocabulary, or describe a target the target layer cannot
# canonicalise.

<#
.SYNOPSIS
    Validates one catalog document (built-in catalog or pack body).
.PARAMETER Document
    Parsed document tree (ordered hashtables/arrays) from Read-WtCatalogJson.
.PARAMETER Source
    BuiltIn or Pack. Packs may only declare ids inside their own namespace.
.PARAMETER PackId
    The pack id, required for Source = Pack.
.OUTPUTS
    @{ Errors; Tweaks; Overlaps; Metadata } - Errors empty means the document is acceptable.
#>
function Test-WtCatalogDocument
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Document,
        [Parameter(Mandatory = $false)][ValidateSet('BuiltIn', 'Pack')][string]$Source = 'BuiltIn',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$PackId = ''
    )

    $Errors = [System.Collections.Generic.List[string]]::new()
    $Tweaks = [System.Collections.Generic.List[object]]::new()
    $Overlaps = [System.Collections.Generic.List[object]]::new()
    $Add = { param ([string]$Message) if ($Errors.Count -lt $Script:WtCatalogLimits.MaxErrors) { $Errors.Add($Message) } }

    foreach ($Problem in (Test-WtCatalogKeys -Table $Document -Allowed $Script:WtCatalogDocumentKeys -Path '$')) { & $Add $Problem }

    $SchemaVersion = 0
    if (-not $Document.Contains('schemaVersion'))
    {
        & $Add '$.schemaVersion : required.'
    }
    else
    {
        try { $SchemaVersion = [int]$Document['schemaVersion'] }
        catch { & $Add '$.schemaVersion : must be an integer.' }
    }

    if ($SchemaVersion -ne $Script:WtCatalogSchemaVersion)
    {
        & $Add "$.schemaVersion : version $SchemaVersion is not supported by this engine (supported: $($Script:WtCatalogSchemaVersion))."
        return @{ Errors = @($Errors.ToArray()); Tweaks = @(); Overlaps = @(); Metadata = $null }
    }

    $Kind = [string]$Document['kind']
    if ($Kind -notin 'Catalog', 'Pack')
    {
        & $Add "$.kind : '$Kind' is not a supported document kind (Catalog or Pack)."
    }
    elseif ($Source -eq 'Pack' -and $Kind -ne 'Pack')
    {
        & $Add "$.kind : a pack body must declare kind 'Pack'."
    }
    elseif ($Source -eq 'BuiltIn' -and $Kind -ne 'Catalog')
    {
        & $Add "$.kind : the built-in catalog must declare kind 'Catalog'."
    }

    $DocumentId = [string]$Document['id']
    if ([string]::IsNullOrWhiteSpace($DocumentId))
    {
        & $Add '$.id : required.'
    }
    elseif ($Source -eq 'Pack' -and $DocumentId -ne $PackId)
    {
        & $Add "$.id : must match the registered pack id '$PackId'."
    }

    $MinEngine = [string]$Document['minEngineVersion']
    if ($MinEngine)
    {
        $Required = $null
        if (-not [version]::TryParse($MinEngine, [ref]$Required))
        {
            & $Add "$.minEngineVersion : '$MinEngine' is not a version."
        }
        elseif ($Required -gt [version]$Script:WtCatalogEngineVersion)
        {
            & $Add "$.minEngineVersion : this document needs engine $MinEngine; this engine is $($Script:WtCatalogEngineVersion)."
        }
    }

    $TweakList = @()
    if (-not $Document.Contains('tweaks'))
    {
        & $Add '$.tweaks : required.'
    }
    else
    {
        $TweakList = @($Document['tweaks'])
    }

    if ($TweakList.Count -gt $Script:WtCatalogLimits.MaxTweaks)
    {
        & $Add "$.tweaks : $($TweakList.Count) definitions exceed the $($Script:WtCatalogLimits.MaxTweaks) definition limit."
    }

    $SeenIds = @{}
    $SeenTargets = @{}
    # Group ids are compared across the whole document: two definitions that declare the same
    # group id would be reported by Get-WtChoiceGroupInternal as one setting with two different
    # sets of alternatives, which is not what either definition says.
    $SeenGroupIds = @{}

    foreach ($Tweak in $TweakList)
    {
        if ($Tweak -isnot [System.Collections.IDictionary])
        {
            & $Add '$.tweaks[] : every entry must be an object.'
            continue
        }

        $Result = Test-WtCatalogTweak -Tweak $Tweak -Source $Source -PackId $PackId -SeenIds $SeenIds -SeenTargets $SeenTargets -SeenGroupIds $SeenGroupIds
        foreach ($Problem in $Result.Errors) { & $Add $Problem }
        foreach ($Overlap in $Result.Overlaps) { $Overlaps.Add($Overlap) }
        if ($Result.Errors.Count -eq 0) { $Tweaks.Add($Result.Tweak) }
    }

    return @{
        Errors   = @($Errors.ToArray())
        Tweaks   = @($Tweaks.ToArray())
        Overlaps = @($Overlaps.ToArray())
        Metadata = @{
            Id             = $DocumentId
            Kind           = $Kind
            SchemaVersion  = $SchemaVersion
            Version        = [string]$Document['version']
            MinEngine      = $MinEngine
            Author         = [string]$Document['author']
            Description    = [string]$Document['description']
            Source         = $Source
            PackId         = $PackId
            TweakCount     = @($Tweaks.ToArray()).Count
        }
    }
}

<#
.SYNOPSIS
    Validates one tweak definition and produces the metadata the engine will carry.
#>
function Test-WtCatalogTweak
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Tweak,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$PackId,
        [Parameter(Mandatory = $true)][hashtable]$SeenIds,
        [Parameter(Mandatory = $true)][hashtable]$SeenTargets,
        [Parameter(Mandatory = $true)][hashtable]$SeenGroupIds
    )

    $Errors = [System.Collections.Generic.List[string]]::new()
    $Overlaps = [System.Collections.Generic.List[object]]::new()
    $Add = { param ([string]$Message) if ($Errors.Count -lt $Script:WtCatalogLimits.MaxErrors) { $Errors.Add($Message) } }

    foreach ($Problem in (Test-WtCatalogKeys -Table $Tweak -Allowed $Script:WtCatalogTweakKeys -Path '$.tweaks[]')) { & $Add $Problem }

    $Id = [string]$Tweak['id']
    if ($Id -notmatch $Script:WtTweakIdPattern)
    {
        & $Add "$.tweaks[].id : '$Id' must look like 'Category.Setting'."
    }
    elseif ($SeenIds.ContainsKey($Id))
    {
        & $Add "$.tweaks[].id : '$Id' is declared twice."
    }
    elseif ($Source -eq 'Pack')
    {
        if (-not $Id.StartsWith("$PackId.", [System.StringComparison]::OrdinalIgnoreCase))
        {
            & $Add "$.tweaks[].id : '$Id' must be inside the pack namespace '$PackId.'."
        }
    }
    elseif ($Id.StartsWith('Pack.', [System.StringComparison]::OrdinalIgnoreCase))
    {
        & $Add "$.tweaks[].id : '$Id' uses the reserved 'Pack.' prefix, which belongs to imported packs."
    }
    else
    {
        $SeenIds[$Id] = $true
    }

    $Revision = 1
    if ($Tweak.Contains('revision'))
    {
        try { $Revision = [int]$Tweak['revision'] }
        catch { & $Add '$.tweaks[].revision : must be an integer.' }
        if ($Revision -lt 1) { & $Add '$.tweaks[].revision : must be 1 or more.' }
    }

    $Category = [string]$Tweak['category']
    if ($Script:WtKnownCategories -notcontains $Category)
    {
        & $Add "$.tweaks[].category : '$Category' is not a known category ($($Script:WtKnownCategories -join ', '))."
    }

    foreach ($Field in 'names', 'descriptions', 'impacts', 'sideEffects')
    {
        if (-not $Tweak.Contains($Field))
        {
            & $Add "$.tweaks[].$Field : required."
            continue
        }

        foreach ($Problem in (Test-WtCatalogLocalized -Value $Tweak[$Field] -Path "$.tweaks[].$Field")) { & $Add $Problem }
    }

    $Tags = @()
    if ($Tweak.Contains('tags'))
    {
        $Tags = @($Tweak['tags'])
        if ($Tags.Count -gt $Script:WtCatalogLimits.MaxTags) { & $Add "$.tweaks[].tags : at most $($Script:WtCatalogLimits.MaxTags) tags." }
        foreach ($Tag in $Tags)
        {
            if ($Tag -isnot [string] -or $Tag -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') { & $Add "$.tweaks[].tags : '$Tag' is not a valid tag." }
        }
    }

    # ---- scope, privilege and the risk floor -------------------------------------------
    $Scope = if ($Tweak.Contains('scope')) { [string]$Tweak['scope'] } else { 'User' }
    if ($Script:WtCatalogScopes -notcontains $Scope)
    {
        & $Add "$.tweaks[].scope : '$Scope' is not supported ($($Script:WtCatalogScopes -join ', '))."
    }

    $DeclaredPrivilege = if ($Tweak.Contains('privilege')) { [string]$Tweak['privilege'] } else { 'None' }
    if ($Script:WtCatalogPrivileges -notcontains $DeclaredPrivilege)
    {
        & $Add "$.tweaks[].privilege : '$DeclaredPrivilege' is not supported ($($Script:WtCatalogPrivileges -join ', '))."
    }

    # The privilege a change needs follows from its scope: a definition cannot declare a
    # machine-wide change as unprivileged, whether it is built in or imported.
    $Privilege = if ($Scope -eq 'User') { 'None' } else { 'Admin' }
    if ($Script:WtCatalogPrivileges -contains $DeclaredPrivilege -and $DeclaredPrivilege -ne $Privilege)
    {
        & $Add "$.tweaks[].privilege : declares '$DeclaredPrivilege' but scope '$Scope' requires '$Privilege'."
    }

    $Irreversible = [bool]$Tweak['irreversible']
    $DataDeletion = [bool]$Tweak['dataDeletion']
    $ReducesProtection = [bool]$Tweak['reducesProtection']

    $Rollback = if ($Tweak.Contains('rollback')) { [string]$Tweak['rollback'] } else { 'Full' }
    if ($Script:WtCatalogRollback -notcontains $Rollback) { & $Add "$.tweaks[].rollback : '$Rollback' is not supported." }
    if ($Irreversible -and $Rollback -ne 'None') { & $Add "$.tweaks[].rollback : an irreversible change must declare rollback 'None'." }

    $Risk = if ($Tweak.Contains('risk')) { [string]$Tweak['risk'] } else { 'Low' }
    if ($Script:WtCatalogRisk -notcontains $Risk) { & $Add "$.tweaks[].risk : '$Risk' is not supported." }

    # Risk floor: protection-reducing, irreversible and data-deleting changes are High.
    $RiskFloor = if ($ReducesProtection -or $Irreversible -or $DataDeletion) { 'High' } else { 'Low' }
    $Rank = @{ Low = 1; Medium = 2; High = 3 }
    if ($Rank[$Risk] -lt $Rank[$RiskFloor])
    {
        & $Add "$.tweaks[].risk : declares '$Risk' but the declared flags require at least '$RiskFloor'."
    }

    $Lifecycle = if ($Tweak.Contains('lifecycle')) { [string]$Tweak['lifecycle'] } else { 'Available' }
    if ($Script:WtCatalogLifecycle -notcontains $Lifecycle)
    {
        & $Add "$.tweaks[].lifecycle : '$Lifecycle' is not supported ($($Script:WtCatalogLifecycle -join ', '))."
    }

    $Restart = if ($Tweak.Contains('restart')) { [string]$Tweak['restart'] } else { 'None' }
    if ($Script:WtCatalogRestart -notcontains $Restart) { & $Add "$.tweaks[].restart : '$Restart' is not supported." }

    # ---- conditions --------------------------------------------------------------------
    $SupportedOS = @('Windows10', 'Windows11')
    if ($Tweak.Contains('supportedOS'))
    {
        $SupportedOS = @($Tweak['supportedOS'])
        foreach ($Os in $SupportedOS)
        {
            if ($Os -notin 'Windows10', 'Windows11') { & $Add "$.tweaks[].supportedOS : '$Os' is not a supported platform key." }
        }
    }

    $MinBuild = 0
    if ($Tweak.Contains('minBuild'))
    {
        try { $MinBuild = [int]$Tweak['minBuild'] } catch { & $Add '$.tweaks[].minBuild : must be an integer.' }
    }

    $MaxBuild = 0
    if ($Tweak.Contains('maxBuild'))
    {
        try { $MaxBuild = [int]$Tweak['maxBuild'] } catch { & $Add '$.tweaks[].maxBuild : must be an integer.' }
        if ($MaxBuild -gt 0 -and $MaxBuild -lt $MinBuild) { & $Add '$.tweaks[].maxBuild : must not be lower than minBuild.' }
    }

    $Architecture = if ($Tweak.Contains('architecture')) { [string]$Tweak['architecture'] } else { 'Any' }
    if ($Script:WtCatalogArchitectures -notcontains $Architecture)
    {
        & $Add "$.tweaks[].architecture : '$Architecture' is not supported ($($Script:WtCatalogArchitectures -join ', '))."
    }

    $Editions = @()
    if ($Tweak.Contains('editions')) { $Editions = @($Tweak['editions']) }

    $Hardware = @()
    if ($Tweak.Contains('hardware')) { $Hardware = @($Tweak['hardware']) }

    # The engine can evaluate the platform key and the minimum build only. Anything else is
    # recorded and reported as *not enforced*, never silently treated as satisfied.
    $UnenforcedConditions = @()
    if ($MaxBuild -gt 0) { $UnenforcedConditions += 'maxBuild' }
    if ($Editions.Count -gt 0) { $UnenforcedConditions += 'editions' }
    if ($Architecture -ne 'Any') { $UnenforcedConditions += 'architecture' }
    if ($Hardware.Count -gt 0) { $UnenforcedConditions += 'hardware' }

    # ---- capabilities, dependencies, ordering and conflicts -----------------------------
    $Capabilities = @()
    if ($Tweak.Contains('requiresCapabilities')) { $Capabilities = @($Tweak['requiresCapabilities']) }
    foreach ($Capability in $Capabilities)
    {
        if ($Capability -isnot [string] -or $Capability -notmatch '^(Cmdlet|Module|File|Service):[A-Za-z0-9_.-]+$' -and $Capability -notin 'Admin', 'Windows', 'OS:Windows10', 'OS:Windows11')
        {
            & $Add "$.tweaks[].requiresCapabilities : '$Capability' is not a supported capability token."
        }
    }

    $Requires = @()
    if ($Tweak.Contains('requires')) { $Requires = @($Tweak['requires']) }
    $RunAfter = @()
    if ($Tweak.Contains('runAfter')) { $RunAfter = @($Tweak['runAfter']) }
    $ConflictsWith = @()
    if ($Tweak.Contains('conflictsWith')) { $ConflictsWith = @($Tweak['conflictsWith']) }

    foreach ($Pair in @(@('requires', $Requires), @('runAfter', $RunAfter), @('conflictsWith', $ConflictsWith)))
    {
        $Field = $Pair[0]
        foreach ($Reference in $Pair[1])
        {
            if ($Reference -isnot [string] -or $Reference -notmatch $Script:WtTweakIdPattern)
            {
                & $Add "$.tweaks[].$Field : '$Reference' is not a tweak id."
                continue
            }

            if ($Reference -eq $Id -and $Field -ne 'runAfter')
            {
                & $Add "$.tweaks[].$Field : '$Id' cannot depend on or conflict with itself."
            }
        }
    }

    # ---- detection and states ----------------------------------------------------------
    $Detection = $null
    if ($Tweak.Contains('detection'))
    {
        $DetectionTable = $Tweak['detection']
        foreach ($Problem in (Test-WtCatalogKeys -Table $DetectionTable -Allowed @('hive', 'key', 'name', 'map', 'view') -Path '$.tweaks[].detection')) { & $Add $Problem }

        $Hive = [string]$DetectionTable['hive']
        if ($Script:WtCatalogRegistryHives -notcontains $Hive) { & $Add "$.tweaks[].detection.hive : '$Hive' is not a supported hive." }

        $Key = [string]$DetectionTable['key']
        if ([string]::IsNullOrWhiteSpace($Key)) { & $Add '$.tweaks[].detection.key : required.' }

        if (-not $DetectionTable.Contains('name')) { & $Add "$.tweaks[].detection.name : required; use an empty string for the default value." }

        $Map = [ordered]@{}
        if ($DetectionTable.Contains('map'))
        {
            # Not $Source: that name is the function parameter ('BuiltIn'/'Pack') and it is
            # typed [string], so assigning a table to it would silently coerce it.
            $MapSource = $DetectionTable['map']
            if ($MapSource -isnot [System.Collections.IDictionary])
            {
                & $Add '$.tweaks[].detection.map : must be an object of State -> value list.'
            }
            else
            {
                foreach ($StateName in $MapSource.Keys)
                {
                    $Values = @($MapSource[$StateName])
                    if ($Values.Count -eq 0) { & $Add "$.tweaks[].detection.map.$StateName : needs at least one value." }
                    $Map[$StateName] = $Values
                }
            }
        }
        else
        {
            & $Add '$.tweaks[].detection.map : required.'
        }

        $Detection = @{ Path = "${Hive}:\$Key"; Name = [string]$DetectionTable['name']; Map = $Map }
    }
    else
    {
        & $Add '$.tweaks[].detection : required; a definition that cannot be detected cannot be reviewed or verified.'
    }

    $States = [ordered]@{}
    if (-not $Tweak.Contains('states'))
    {
        & $Add '$.tweaks[].states : required.'
    }
    else
    {
        $StatesTable = $Tweak['states']
        if ($StatesTable -isnot [System.Collections.IDictionary] -or $StatesTable.Count -eq 0)
        {
            & $Add '$.tweaks[].states : must be a non-empty object of State -> operation list.'
        }
        elseif ($StatesTable.Count -gt $Script:WtCatalogLimits.MaxStatesPerTweak)
        {
            & $Add "$.tweaks[].states : $($StatesTable.Count) states exceed the $($Script:WtCatalogLimits.MaxStatesPerTweak) state limit."
        }
        else
        {
            foreach ($StateName in $StatesTable.Keys)
            {
                if ($StateName -notmatch '^[A-Za-z][A-Za-z0-9]*$') { & $Add "$.tweaks[].states.$StateName : state names are identifiers." }

                $OperationList = @($StatesTable[$StateName])
                if ($OperationList.Count -eq 0)
                {
                    & $Add "$.tweaks[].states.$StateName : needs at least one operation."
                    continue
                }

                if ($OperationList.Count -gt $Script:WtCatalogLimits.MaxOperations)
                {
                    & $Add "$.tweaks[].states.$StateName : $($OperationList.Count) operations exceed the $($Script:WtCatalogLimits.MaxOperations) operation limit."
                    continue
                }

                $Operations = @()
                $LocalTargets = @{}
                foreach ($Operation in $OperationList)
                {
                    if ($Operation -isnot [System.Collections.IDictionary])
                    {
                        & $Add "$.tweaks[].states.$StateName[] : every operation must be an object."
                        continue
                    }

                    $Converted = ConvertTo-WtCatalogRegistryOperation -Definition $Operation -Path "$.tweaks[].states.$StateName[]"
                    foreach ($Problem in $Converted.Errors) { & $Add $Problem }
                    if (-not $Converted.Operation) { continue }

                    $Identity = Get-WtCatalogOperationIdentity -Operation $Converted.Operation
                    if ($LocalTargets.ContainsKey($Identity))
                    {
                        & $Add "$.tweaks[].states.$StateName : '$(Format-WtTargetIdentity -Identity $Identity)' is written twice in the same state."
                    }
                    $LocalTargets[$Identity] = $true
                    $Operations += $Converted.Operation
                }

                $States[$StateName] = $Operations
            }
        }
    }

    $DefaultState = [string]$Tweak['defaultState']
    if (-not $DefaultState)
    {
        & $Add '$.tweaks[].defaultState : required.'
    }
    elseif ($States.Count -gt 0 -and -not $States.Contains($DefaultState))
    {
        & $Add "$.tweaks[].defaultState : '$DefaultState' is not one of the declared states ($($States.Keys -join ', '))."
    }

    $StateNames = @($States.Keys)

    if ($Detection -and $Detection.Map.Count -gt 0 -and $States.Count -gt 0)
    {
        foreach ($MappedState in $Detection.Map.Keys)
        {
            if ($StateNames -notcontains $MappedState)
            {
                & $Add "$.tweaks[].detection.map.$MappedState : detection reports a state the definition does not declare."
            }
        }
    }

    $ManagedPolicy = @()
    if ($Tweak.Contains('managedPolicy'))
    {
        foreach ($Policy in @($Tweak['managedPolicy']))
        {
            if ($Policy -isnot [System.Collections.IDictionary])
            {
                & $Add '$.tweaks[].managedPolicy[] : every entry must be an object.'
                continue
            }

            foreach ($Problem in (Test-WtCatalogKeys -Table $Policy -Allowed @('hive', 'key', 'name') -Path '$.tweaks[].managedPolicy[]')) { & $Add $Problem }
            $Hive = [string]$Policy['hive']
            if ($Script:WtCatalogRegistryHives -notcontains $Hive) { & $Add "$.tweaks[].managedPolicy[].hive : '$Hive' is not a supported hive." }
            if (-not $Policy.Contains('name')) { & $Add '$.tweaks[].managedPolicy[].name : required.' }
            $ManagedPolicy += @{ Path = "${Hive}:\$([string]$Policy['key'])"; Name = [string]$Policy['name'] }
        }
    }

    # ---- recommendation metadata --------------------------------------------------------
    # Recommendation eligibility is *claimed* here and decided by the engine (see
    # Private/Insight/Recommendations.ps1). A document may ask to be considered; it cannot grant
    # itself a place in an automatic proposal.
    $Recommendation = $null
    if ($Tweak.Contains('recommendation'))
    {
        $Table = $Tweak['recommendation']
        if ($Table -isnot [System.Collections.IDictionary])
        {
            & $Add '$.tweaks[].recommendation : must be an object.'
        }
        else
        {
            foreach ($Problem in (Test-WtCatalogKeys -Table $Table -Allowed $Script:WtCatalogRecommendationKeys -Path '$.tweaks[].recommendation')) { & $Add $Problem }

            $Kind = [string]$Table['kind']
            $Policy = [string]$Table['policy']
            if ($Script:WtRecommendationKinds -notcontains $Kind) { & $Add "$.tweaks[].recommendation.kind : '$Kind' is not supported ($($Script:WtRecommendationKinds -join ', '))." }
            if ($Script:WtRecommendationPolicies -notcontains $Policy) { & $Add "$.tweaks[].recommendation.policy : '$Policy' is not supported ($($Script:WtRecommendationPolicies -join ', '))." }

            $Objectives = @($Table['objectives'])
            if ($Policy -eq 'Eligible' -and $Objectives.Count -eq 0)
            {
                & $Add "$.tweaks[].recommendation.objectives : an eligible item must name at least one objective."
            }

            foreach ($Objective in $Objectives)
            {
                if ($Script:WtRecommendationObjectives -notcontains $Objective)
                {
                    & $Add "$.tweaks[].recommendation.objectives : '$Objective' is not a supported objective ($($Script:WtRecommendationObjectives -join ', '))."
                }
            }

            if ($Table.Contains('rationale'))
            {
                foreach ($Problem in (Test-WtCatalogLocalized -Value $Table['rationale'] -Path '$.tweaks[].recommendation.rationale')) { & $Add $Problem }
            }
            elseif ($Policy -eq 'Eligible')
            {
                & $Add '$.tweaks[].recommendation.rationale : required for an eligible item; say why it is recommended.'
            }

            if ($Kind -eq 'Repair' -and -not [string]$Table['requiresFinding'])
            {
                & $Add '$.tweaks[].recommendation.requiresFinding : a repair must name the sanity rule whose finding it addresses.'
            }

            if ($Kind -ne 'Repair' -and $Table.Contains('requiresFinding'))
            {
                & $Add '$.tweaks[].recommendation.requiresFinding : only a repair recommendation may require a finding.'
            }

            if ($Errors.Count -eq 0)
            {
                $Recommendation = @{
                    Kind            = $Kind
                    Policy          = $Policy
                    Objectives      = @($Objectives)
                    Rationale       = if ($Table.Contains('rationale')) { $Table['rationale'] } else { $null }
                    RequiresFinding = [string]$Table['requiresFinding']
                    Documented      = [bool]$Table['documented']
                }
            }
        }
    }

    # ---- effective-state declaration -----------------------------------------------------
    # What the configuration means for behaviour, and at which boundary it is read. Without this
    # declaration the engine reports the effective state as Unknown - configuration is not
    # behaviour, and a definition that does not say how it was observed cannot claim either.
    $Effective = $null
    if ($Tweak.Contains('effective'))
    {
        $Table = $Tweak['effective']
        if ($Table -isnot [System.Collections.IDictionary])
        {
            & $Add '$.tweaks[].effective : must be an object.'
        }
        else
        {
            foreach ($Problem in (Test-WtCatalogKeys -Table $Table -Allowed $Script:WtCatalogEffectiveKeys -Path '$.tweaks[].effective')) { & $Add $Problem }

            $Evidence = [string]$Table['evidence']
            $Boundary = if ($Table.Contains('boundary')) { [string]$Table['boundary'] } else { 'None' }
            if ($Script:WtEffectiveEvidenceKinds -notcontains $Evidence) { & $Add "$.tweaks[].effective.evidence : '$Evidence' is not supported ($($Script:WtEffectiveEvidenceKinds -join ', '))." }
            if ($Script:WtEffectiveBoundaries -notcontains $Boundary) { & $Add "$.tweaks[].effective.boundary : '$Boundary' is not supported ($($Script:WtEffectiveBoundaries -join ', '))." }

            $Map = [ordered]@{}
            if ($Table.Contains('map'))
            {
                # Not $Source: that name is this function's [string] parameter, and assigning a
                # table to it would silently coerce it.
                $MapSource = $Table['map']
                if ($MapSource -isnot [System.Collections.IDictionary])
                {
                    & $Add '$.tweaks[].effective.map : must be an object of State -> effective behaviour.'
                }
                else
                {
                    foreach ($Key in $MapSource.Keys)
                    {
                        if ($StateNames -notcontains $Key) { & $Add "$.tweaks[].effective.map.$Key : not a declared state ($(@($StateNames) -join ', '))." }
                        if ($Script:WtEffectiveStates -notcontains [string]$MapSource[$Key]) { & $Add "$.tweaks[].effective.map.$Key : '$($MapSource[$Key])' is not an effective state ($($Script:WtEffectiveStates -join ', '))." }
                        $Map[$Key] = [string]$MapSource[$Key]
                    }
                }
            }

            if ($Table.Contains('note'))
            {
                foreach ($Problem in (Test-WtCatalogLocalized -Value $Table['note'] -Path '$.tweaks[].effective.note')) { & $Add $Problem }
            }

            if ($Errors.Count -eq 0)
            {
                $Effective = @{
                    Evidence = $Evidence
                    Boundary = $Boundary
                    Map      = $Map
                    Note     = if ($Table.Contains('note')) { $Table['note'] } else { $null }
                }
            }
        }
    }

    # ---- mutually exclusive group -------------------------------------------------------
    # One setting with several alternatives is declared as a tweak whose *states are the
    # alternatives*, plus the metadata that makes it a group. It is deliberately not a set of
    # independent tweaks: the engine already keeps one pending entry per tweak id, so a group
    # cannot have two alternatives selected at once, and its targets go through the same
    # conflict detection as everything else.
    $Group = $null
    if ($Tweak.Contains('group'))
    {
        $Table = $Tweak['group']
        if ($Table -isnot [System.Collections.IDictionary])
        {
            & $Add '$.tweaks[].group : must be an object.'
        }
        else
        {
            foreach ($Problem in (Test-WtCatalogKeys -Table $Table -Allowed $Script:WtCatalogGroupKeys -Path '$.tweaks[].group')) { & $Add $Problem }

            $GroupId = [string]$Table['id']
            if ($GroupId -notmatch '^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z0-9][A-Za-z0-9_-]*)+$')
            {
                & $Add "$.tweaks[].group.id : '$GroupId' is not a group id."
            }
            elseif ($SeenGroupIds.ContainsKey($GroupId))
            {
                & $Add "$.tweaks[].group.id : '$GroupId' is declared twice in this document."
            }
            else
            {
                $SeenGroupIds[$GroupId] = $true
            }

            # Required, like the tweak-level revision: a group is a definition in its own right
            # and the interface reports it, so it carries a revision of its own.
            $GroupRevision = 1
            if (-not $Table.Contains('revision'))
            {
                & $Add '$.tweaks[].group.revision : required.'
            }
            else
            {
                try { $GroupRevision = [int]$Table['revision'] }
                catch { & $Add '$.tweaks[].group.revision : must be an integer.' }
                if ($GroupRevision -lt 1) { & $Add '$.tweaks[].group.revision : must be 1 or more.' }
            }

            if (-not $Table.Contains('labels')) { & $Add '$.tweaks[].group.labels : required.' }
            else { foreach ($Problem in (Test-WtCatalogLocalized -Value $Table['labels'] -Path '$.tweaks[].group.labels')) { & $Add $Problem } }
            if ($Table.Contains('descriptions')) { foreach ($Problem in (Test-WtCatalogLocalized -Value $Table['descriptions'] -Path '$.tweaks[].group.descriptions')) { & $Add $Problem } }
            if ($Table.Contains('notes')) { foreach ($Problem in (Test-WtCatalogLocalized -Value $Table['notes'] -Path '$.tweaks[].group.notes')) { & $Add $Problem } }

            $Options = @($Table['options'])
            if ($Options.Count -lt 2) { & $Add '$.tweaks[].group.options : a group needs at least two alternatives.' }

            $OptionIds = @()
            $OptionMap = [ordered]@{}
            foreach ($Option in $Options)
            {
                if ($Option -isnot [System.Collections.IDictionary]) { & $Add '$.tweaks[].group.options[] : every option must be an object.'; continue }
                foreach ($Problem in (Test-WtCatalogKeys -Table $Option -Allowed $Script:WtCatalogGroupOptionKeys -Path '$.tweaks[].group.options[]')) { & $Add $Problem }

                $OptionId = [string]$Option['id']
                if ($OptionId -notmatch '^[A-Za-z][A-Za-z0-9]*$') { & $Add "$.tweaks[].group.options[].id : '$OptionId' is not an option id." }
                if ($OptionIds -contains $OptionId) { & $Add "$.tweaks[].group.options[].id : '$OptionId' is declared twice." }
                $OptionIds += $OptionId

                $Intent = if ($Option.Contains('intent')) { [string]$Option['intent'] } else { 'Configured' }
                if ($Script:WtGroupOptionIntents -notcontains $Intent) { & $Add "$.tweaks[].group.options[].intent : '$Intent' is not supported ($($Script:WtGroupOptionIntents -join ', '))." }

                if (-not $Option.Contains('labels')) { & $Add "$.tweaks[].group.options[].labels : required for '$OptionId'." }
                else { foreach ($Problem in (Test-WtCatalogLocalized -Value $Option['labels'] -Path '$.tweaks[].group.options[].labels')) { & $Add $Problem } }
                if ($Option.Contains('descriptions')) { foreach ($Problem in (Test-WtCatalogLocalized -Value $Option['descriptions'] -Path '$.tweaks[].group.options[].descriptions')) { & $Add $Problem } }

                $OptionMap[$OptionId] = @{
                    Id          = $OptionId
                    Intent      = $Intent
                    Labels      = if ($Option.Contains('labels')) { $Option['labels'] } else { $null }
                    Descriptions = if ($Option.Contains('descriptions')) { $Option['descriptions'] } else { $null }
                }
            }

            if ($States.Count -gt 0)
            {
                foreach ($OptionId in $OptionIds)
                {
                    if (-not $States.Contains($OptionId)) { & $Add "$.tweaks[].group.options : '$OptionId' has no state of the same name." }
                }
                foreach ($StateName in @($States.Keys))
                {
                    if ($OptionIds -notcontains $StateName) { & $Add "$.tweaks[].states.$StateName : a group's states must be its options (extra state '$StateName')." }
                }

                # Every alternative must write the *same* targets. A group is one setting with
                # several values; an option that writes a target the others do not would leave
                # that target behind when the user switches, so the group would not be one setting.
                $TargetSets = [ordered]@{}
                foreach ($OptionId in $OptionIds)
                {
                    if (-not $States.Contains($OptionId)) { continue }
                    $Identities = @()
                    foreach ($Operation in @($States[$OptionId]))
                    {
                        $Identity = Get-WtCatalogOperationIdentity -Operation $Operation
                        if ($Identity) { $Identities += $Identity }
                    }
                    $TargetSets[$OptionId] = @($Identities | Sort-Object -Unique)
                }

                $ReferenceOption = $null
                foreach ($OptionId in $OptionIds)
                {
                    if ($TargetSets.Contains($OptionId)) { $ReferenceOption = $OptionId; break }
                }

                if ($ReferenceOption)
                {
                    $ReferenceSet = @($TargetSets[$ReferenceOption])
                    foreach ($OptionId in $OptionIds)
                    {
                        if ($OptionId -eq $ReferenceOption -or -not $TargetSets.Contains($OptionId)) { continue }

                        $Difference = @()
                        foreach ($Identity in @($ReferenceSet | Where-Object { @($TargetSets[$OptionId]) -notcontains $_ }))
                        {
                            $Difference += "'$(Format-WtTargetIdentity -Identity $Identity)' is not written by '$OptionId'"
                        }
                        foreach ($Identity in @($TargetSets[$OptionId] | Where-Object { $ReferenceSet -notcontains $_ }))
                        {
                            $Difference += "'$(Format-WtTargetIdentity -Identity $Identity)' is written only by '$OptionId'"
                        }

                        if ($Difference.Count -gt 0)
                        {
                            & $Add "$.tweaks[].group.options : '$OptionId' and '$ReferenceOption' must write the same targets, but $($Difference -join '; ')."
                        }
                    }
                }
            }

            # Every alternative must be detectable: the current alternative is reported by reading
            # the written values back, so an option with no detection.map entry could never be
            # reported as the one in effect.
            if ($Detection)
            {
                foreach ($OptionId in $OptionIds)
                {
                    if (-not $Detection.Map.Contains($OptionId)) { & $Add "$.tweaks[].group.options : '$OptionId' has no entry in detection.map, so it could never be reported as the current alternative." }
                }
            }

            if ($DefaultState -and $OptionIds -notcontains $DefaultState)
            {
                & $Add "$.tweaks[].defaultState : '$DefaultState' is not one of the group's options."
            }

            if ($Irreversible)
            {
                & $Add '$.tweaks[].group : an irreversible change cannot be an alternative in a group, because a group is meant to be switched back and forth.'
            }

            if ($Errors.Count -eq 0)
            {
                $Group = @{
                    Id           = $GroupId
                    Revision     = $GroupRevision
                    Labels       = $Table['labels']
                    Descriptions = if ($Table.Contains('descriptions')) { $Table['descriptions'] } else { $null }
                    Notes        = if ($Table.Contains('notes')) { $Table['notes'] } else { $null }
                    Options      = $OptionMap
                    OptionIds    = @($OptionIds)
                }
            }
        }
    }

    # ---- capability-loss disclosures ---------------------------------------------------
    # What may stop working after this action. A disclosure is a claim with a certainty kind,
    # an optional condition and an optional restoration path. It is display metadata and can
    # never suppress an engine-owned warning; a pack carries the same rules as the built-in
    # catalog, and duplicate capability ids inside one definition are refused.
    $CapabilityLoss = @()
    if ($Tweak.Contains('capabilityLoss'))
    {
        $List = @($Tweak['capabilityLoss'])
        if ($List.Count -gt $Script:WtCatalogMaxCapabilityImpacts)
        {
            & $Add "$.tweaks[].capabilityLoss : at most $($Script:WtCatalogMaxCapabilityImpacts) disclosures."
        }

        $SeenCapabilities = @{}
        foreach ($Entry in $List)
        {
            if ($Entry -isnot [System.Collections.IDictionary])
            {
                & $Add '$.tweaks[].capabilityLoss[] : every entry must be an object.'
                continue
            }

            $Before = $Errors.Count

            foreach ($Problem in (Test-WtCatalogKeys -Table $Entry -Allowed $Script:WtCatalogCapabilityKeys -Path '$.tweaks[].capabilityLoss[]')) { & $Add $Problem }

            $CapabilityId = [string]$Entry['capability']
            if ($CapabilityId -notmatch '^[a-z0-9][a-z0-9._-]*$')
            {
                & $Add "$.tweaks[].capabilityLoss[].capability : '$CapabilityId' is not a valid capability id (lowercase letters, digits, dots, dashes)."
            }
            elseif ($SeenCapabilities.ContainsKey($CapabilityId))
            {
                & $Add "$.tweaks[].capabilityLoss[].capability : '$CapabilityId' is declared twice in one definition."
            }
            else
            {
                $SeenCapabilities[$CapabilityId] = $true
            }

            if (-not $Entry.Contains('names') -or $null -eq $Entry['names'])
            {
                & $Add '$.tweaks[].capabilityLoss[].names : required.'
            }
            else
            {
                foreach ($Problem in (Test-WtCatalogLocalized -Value $Entry['names'] -Path '$.tweaks[].capabilityLoss[].names')) { & $Add $Problem }
            }

            $Kind = [string]$Entry['kind']
            if ($Script:WtCatalogCapabilityKinds -notcontains $Kind)
            {
                & $Add "$.tweaks[].capabilityLoss[].kind : '$Kind' is not supported ($($Script:WtCatalogCapabilityKinds -join ', '))."
            }

            $Temporary = [bool]$Entry['temporary']

            $Condition = $null
            if ($Entry.Contains('condition'))
            {
                $ConditionTable = $Entry['condition']
                if ($ConditionTable -isnot [System.Collections.IDictionary])
                {
                    & $Add '$.tweaks[].capabilityLoss[].condition : must be an object.'
                }
                else
                {
                    foreach ($Problem in (Test-WtCatalogKeys -Table $ConditionTable -Allowed $Script:WtCatalogCapabilityConditionKeys -Path '$.tweaks[].capabilityLoss[].condition')) { & $Add $Problem }

                    if (-not $ConditionTable.Contains('explanation'))
                    {
                        & $Add '$.tweaks[].capabilityLoss[].condition.explanation : required.'
                    }
                    else
                    {
                        foreach ($Problem in (Test-WtCatalogLocalized -Value $ConditionTable['explanation'] -Path '$.tweaks[].capabilityLoss[].condition.explanation')) { & $Add $Problem }
                    }

                    $ConditionTokens = @()
                    if ($ConditionTable.Contains('requiresCapabilities'))
                    {
                        $ConditionTokens = @($ConditionTable['requiresCapabilities'])
                        foreach ($Token in $ConditionTokens)
                        {
                            if ($Token -isnot [string] -or $Token -notmatch '^(Cmdlet|Module|File|Service):[A-Za-z0-9_.-]+$' -and $Token -notin 'Admin', 'Windows', 'OS:Windows10', 'OS:Windows11')
                            {
                                & $Add "$.tweaks[].capabilityLoss[].condition.requiresCapabilities : '$Token' is not a supported capability token."
                            }
                        }
                    }

                    if ($Errors.Count -eq $Before)
                    {
                        $Condition = @{
                            Explanation          = $ConditionTable['explanation']
                            RequiresCapabilities = @($ConditionTokens)
                        }
                    }
                }
            }

            if ($Kind -ne 'Conditional' -and $Condition)
            {
                & $Add '$.tweaks[].capabilityLoss[].condition : only a Conditional impact may carry a condition.'
            }

            $RestoredBy = $null
            if ($Entry.Contains('restoredBy'))
            {
                foreach ($Problem in (Test-WtCatalogLocalized -Value $Entry['restoredBy'] -Path '$.tweaks[].capabilityLoss[].restoredBy')) { & $Add $Problem }
                $RestoredBy = $Entry['restoredBy']
            }

            $Limitations = $null
            if ($Entry.Contains('limitations'))
            {
                foreach ($Problem in (Test-WtCatalogLocalized -Value $Entry['limitations'] -Path '$.tweaks[].capabilityLoss[].limitations')) { & $Add $Problem }
                $Limitations = $Entry['limitations']
            }

            if ($Errors.Count -eq $Before)
            {
                $CapabilityLoss += @{
                    Capability  = $CapabilityId
                    Names       = $Entry['names']
                    Kind        = $Kind
                    Temporary   = $Temporary
                    Condition   = $Condition
                    RestoredBy  = $RestoredBy
                    Limitations = $Limitations
                }
            }
        }
    }

    # ---- references and evidence -------------------------------------------------------
    $References = @()
    if ($Tweak.Contains('references'))
    {
        foreach ($Reference in @($Tweak['references']))
        {
            if ($Reference -isnot [System.Collections.IDictionary])
            {
                & $Add '$.tweaks[].references[] : every entry must be an object.'
                continue
            }

            foreach ($Problem in (Test-WtCatalogKeys -Table $Reference -Allowed $Script:WtCatalogReferenceKeys -Path '$.tweaks[].references[]')) { & $Add $Problem }

            $Url = [string]$Reference['url']
            if ($Url -notmatch '^https://')
            {
                & $Add "$.tweaks[].references[].url : '$Url' must be an https:// URL (references are never fetched, but a plain-text URL is required as evidence)."
            }

            if ([string]::IsNullOrWhiteSpace([string]$Reference['supports']))
            {
                & $Add '$.tweaks[].references[].supports : state what this reference supports; a bare URL proves nothing.'
            }

            $Status = [string]$Reference['status']
            if ($Status -and $Script:WtCatalogEvidenceStatus -notcontains $Status)
            {
                & $Add "$.tweaks[].references[].status : '$Status' is not a supported evidence status."
            }

            $References += @{
                Id         = [string]$Reference['id']
                Url        = $Url
                Title      = [string]$Reference['title']
                Supports   = [string]$Reference['supports']
                Status     = $Status
                CheckedUtc = [string]$Reference['checkedUtc']
            }
        }

        if ($References.Count -gt $Script:WtCatalogLimits.MaxReferences) { & $Add "$.tweaks[].references : at most $($Script:WtCatalogLimits.MaxReferences) references." }
    }

    $Evidence = @{
        Source            = $Source
        Documentation     = @()
        Structural        = 'Validated'
        ProviderTests     = 'NotRun'
        WindowsIntegration = $null
        Notes             = ''
        AuthorClaimed     = ($Source -eq 'Pack')
        UnenforcedConditions = @($UnenforcedConditions)
    }

    if ($Tweak.Contains('evidence'))
    {
        $EvidenceTable = $Tweak['evidence']
        foreach ($Problem in (Test-WtCatalogKeys -Table $EvidenceTable -Allowed $Script:WtCatalogEvidenceKeys -Path '$.tweaks[].evidence')) { & $Add $Problem }

        if ($EvidenceTable.Contains('documentation')) { $Evidence.Documentation = @($EvidenceTable['documentation']) }

        foreach ($Field in 'structural', 'providerTests')
        {
            if ($EvidenceTable.Contains($Field))
            {
                $Status = [string]$EvidenceTable[$Field]
                if ($Script:WtCatalogEvidenceStatus -notcontains $Status)
                {
                    & $Add "$.tweaks[].evidence.$Field : '$Status' is not a supported evidence status."
                }
                elseif ($Source -eq 'BuiltIn')
                {
                    # A built-in document may state what its own validation found; the loader
                    # recomputes structural status anyway, and a document cannot upgrade it.
                    if ($Field -eq 'structural') { $Evidence.Structural = $Status }
                    if ($Field -eq 'providerTests') { $Evidence.ProviderTests = $Status }
                }
            }
        }

        if ($EvidenceTable.Contains('windowsIntegration'))
        {
            $Windows = $EvidenceTable['windowsIntegration']
            if ($Windows -isnot [System.Collections.IDictionary])
            {
                & $Add '$.tweaks[].evidence.windowsIntegration : must be an object.'
            }
            else
            {
                foreach ($Problem in (Test-WtCatalogKeys -Table $Windows -Allowed $Script:WtCatalogWindowsEvidenceKeys -Path '$.tweaks[].evidence.windowsIntegration')) { & $Add $Problem }
                $Evidence.WindowsIntegration = @{
                    Build        = [string]$Windows['build']
                    Edition      = [string]$Windows['edition']
                    Architecture = [string]$Windows['architecture']
                    DateUtc      = [string]$Windows['dateUtc']
                    Method       = [string]$Windows['method']
                    Limitations  = [string]$Windows['limitations']
                    Result       = [string]$Windows['result']
                    AuthorClaimed = ($Source -eq 'Pack')
                }
            }
        }

        if ($EvidenceTable.Contains('notes')) { $Evidence.Notes = [string]$EvidenceTable['notes'] }
    }

    # Cross-tweak target collisions: reported, never silently accepted.
    if ($States.Count -gt 0)
    {
        foreach ($StateName in $States.Keys)
        {
            foreach ($Operation in $States[$StateName])
            {
                $Identity = Get-WtCatalogOperationIdentity -Operation $Operation
                if (-not $Identity) { continue }

                if ($SeenTargets.ContainsKey($Identity) -and $SeenTargets[$Identity] -ne $Id)
                {
                    $Overlaps.Add(@{
                        Identity = $Identity
                        Label    = (Format-WtTargetIdentity -Identity $Identity)
                        Left     = [string]$SeenTargets[$Identity]
                        Right    = $Id
                    })
                }

                if (-not $SeenTargets.ContainsKey($Identity)) { $SeenTargets[$Identity] = $Id }
            }
        }
    }

    $TweakMetadata = $null
    if ($Errors.Count -eq 0)
    {
        $TweakMetadata = @{
            Id               = $Id
            Revision         = $Revision
            Category         = $Category
            Tags             = @($Tags)
            Names            = $Tweak['names']
            Descriptions     = $Tweak['descriptions']
            Impacts          = $Tweak['impacts']
            SideEffects      = $Tweak['sideEffects']
            Scope            = $Scope
            Privilege        = $Privilege
            Lifecycle        = $Lifecycle
            Risk             = $Risk
            Restart          = $Restart
            Rollback         = $Rollback
            Irreversible     = $Irreversible
            DataDeletion     = $DataDeletion
            ReducesProtection = $ReducesProtection
            RequiresCapabilities = @($Capabilities)
            Requires         = @($Requires)
            RunAfter         = @($RunAfter)
            ConflictsWith    = @($ConflictsWith)
            SupportedOS      = @($SupportedOS)
            MinBuild         = $MinBuild
            MaxBuild         = $MaxBuild
            Editions         = @($Editions)
            Architecture     = $Architecture
            Hardware         = @($Hardware)
            Detection        = $Detection
            States           = $States
            StateNames       = @($StateNames)
            DefaultState     = $DefaultState
            ManagedPolicy    = @($ManagedPolicy)
            References       = @($References)
            Evidence         = $Evidence
            Recommendation   = $Recommendation
            Effective        = $Effective
            Group            = $Group
            CapabilityLoss   = @($CapabilityLoss)
            Source           = $Source
            PackId           = $PackId
            Definition         = $Tweak
        }
    }

    return @{ Errors = @($Errors.ToArray()); Tweak = $TweakMetadata; Overlaps = @($Overlaps.ToArray()) }
}

<#
.SYNOPSIS
    Registers the tweaks of a validated document through the existing constructor.
.DESCRIPTION
    Refuses to touch the catalog when anything is invalid: a partially registered document is
    worse than a rejected one. Registration only creates metadata; it never reads or writes
    Windows.
.OUTPUTS
    @{ Registered; Skipped; Errors }
#>
function Import-WtCatalogDocument
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Document,
        [Parameter(Mandatory = $false)][ValidateSet('BuiltIn', 'Pack')][string]$Source = 'BuiltIn',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$PackId = '',
        [Parameter(Mandatory = $false)][switch]$AllowExisting
    )

    $Validation = Test-WtCatalogDocument -Document $Document -Source $Source -PackId $PackId
    if ($Validation.Errors.Count -gt 0)
    {
        return @{ Registered = @(); Skipped = @(); Errors = @($Validation.Errors) }
    }

    $Registered = [System.Collections.Generic.List[string]]::new()
    $Skipped = [System.Collections.Generic.List[object]]::new()

    foreach ($Tweak in $Validation.Tweaks)
    {
        if ($Script:WtCatalog.Contains($Tweak.Id))
        {
            if (-not $AllowExisting)
            {
                return @{
                    Registered = @($Registered.ToArray())
                    Skipped    = @($Skipped.ToArray())
                    Errors     = @("Tweak '$($Tweak.Id)' is already registered; a document cannot redefine an existing id.")
                }
            }

            $Skipped.Add(@{ Id = $Tweak.Id; Reason = 'already registered' })
            continue
        }

        $Privilege = $Tweak.Privilege

        $Created = New-WtRegistryTweak -Id $Tweak.Id -Category $Tweak.Category `
            -Name $Tweak.Names -Description $Tweak.Descriptions -Impact $Tweak.Impacts `
            -States $Tweak.States -Detection $Tweak.Detection `
            -Scope $Tweak.Scope -Privilege $Privilege -SupportedOS $Tweak.SupportedOS -MinBuild $Tweak.MinBuild `
            -Requires $Tweak.RequiresCapabilities -Restart $Tweak.Restart -Rollback $Tweak.Rollback -Risk $Tweak.Risk `
            -Lifecycle $Tweak.Lifecycle -ManagedPolicy $Tweak.ManagedPolicy `
            -ReducesProtection:$Tweak.ReducesProtection -StateNames $Tweak.StateNames -DefaultState $Tweak.DefaultState

        if (-not $Created)
        {
            throw "The catalog definition '$($Tweak.Id)' could not be registered; the built-in catalog is incomplete."
        }

        # Catalog-only metadata. None of it changes how the change runs; it is what the
        # interface and the inspector show, and what the planner reads.
        foreach ($Pair in @(
                @('DefinitionSource', $Tweak.Source),
                @('DefinitionPackId', $Tweak.PackId),
                @('DefinitionRevision', $Tweak.Revision),
                @('DefinitionTags', @($Tweak.Tags)),
                @('DefinitionRequires', @($Tweak.Requires)),
                @('DefinitionRunAfter', @($Tweak.RunAfter)),
                @('DefinitionConflictsWith', @($Tweak.ConflictsWith)),
                @('DefinitionReferences', @($Tweak.References)),
                @('DefinitionEvidence', $Tweak.Evidence),
                @('DefinitionSideEffects', $Tweak.SideEffects),
                @('DefinitionConditions', @{
                        MaxBuild     = $Tweak.MaxBuild
                        Editions     = @($Tweak.Editions)
                        Architecture = $Tweak.Architecture
                        Hardware     = @($Tweak.Hardware)
                        Enforced     = @('supportedOS', 'minBuild')
                    }),
                @('DefinitionRecommendation', $Tweak.Recommendation),
                @('DefinitionEffective', $Tweak.Effective),
                @('DefinitionGroup', $Tweak.Group),
                @('DefinitionCapabilityLoss', @($Tweak.CapabilityLoss)),
                @('DefinitionDocument', $Tweak.Definition)))
        {
            $Created | Add-Member -NotePropertyName $Pair[0] -NotePropertyValue $Pair[1] -Force
        }

        # The evidence the *engine* can vouch for is recorded here and kept apart from what a
        # document claims about itself.
        $Created | Add-Member -NotePropertyName DefinitionValidation -NotePropertyValue @{
            Structural    = 'Validated'
            ProviderTests = 'See tests/Catalog.Tests.ps1'
            WindowsIntegration = $null
        } -Force

        $Registered.Add($Tweak.Id)
    }

    return @{ Registered = @($Registered.ToArray()); Skipped = @($Skipped.ToArray()); Errors = @(); Overlaps = @($Validation.Overlaps) }
}

<#
.SYNOPSIS
    Loads every catalog document in a directory (sorted, so the order is deterministic).
.OUTPUTS
    @{ Documents; Registered; Errors; Overlaps }
#>
function Import-WtCatalogDirectory
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][ValidateSet('BuiltIn', 'Pack')][string]$Source = 'BuiltIn',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$PackId = ''
    )

    $Documents = [System.Collections.Generic.List[object]]::new()
    $Registered = [System.Collections.Generic.List[string]]::new()
    $Errors = [System.Collections.Generic.List[string]]::new()
    $Overlaps = [System.Collections.Generic.List[object]]::new()

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return @{ Documents = @(); Registered = @(); Errors = @(); Overlaps = @() } }

    foreach ($File in @(Get-ChildItem -LiteralPath $Path -Filter '*.json' -File | Sort-Object -Property Name))
    {
        # Files that are not catalog documents: '*.schema.json' is documentation for authors
        # (the JSON Schema), and 'migrations.json' is the stable-ID registry, which has its own
        # loader. Neither is a definition and neither is parsed here.
        if ($File.Name -like '*.schema.json' -or $File.Name -eq 'migrations.json')
        {
            continue
        }

        $Read = Read-WtCatalogJson -Path $File.FullName
        if (-not $Read.Ok)
        {
            foreach ($Problem in $Read.Errors) { $Errors.Add("$($File.Name): $Problem") }
            continue
        }

        $Document = ConvertFrom-WtCatalogNode -Node $Read.Document.Root

        $Import = Import-WtCatalogDocument -Document $Document -Source $Source -PackId $PackId
        foreach ($Problem in @($Import.Errors)) { $Errors.Add("$($File.Name): $Problem") }
        foreach ($Id in @($Import.Registered)) { $Registered.Add($Id) }
        foreach ($Overlap in @($Import.Overlaps)) { $Overlaps.Add($Overlap) }

        $Documents.Add(@{ Path = $File.FullName; Document = $Document })
    }

    return @{
        Documents  = @($Documents.ToArray())
        Registered = @($Registered.ToArray())
        Errors     = @($Errors.ToArray())
        Overlaps   = @($Overlaps.ToArray())
    }
}
