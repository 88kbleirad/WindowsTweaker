# WindowsTweaker - declarative catalog, packs, planning and migrations (public API).
#
# These functions read or extend the catalog; none of them applies a tweak. Every change a
# catalog or pack definition describes still runs through Invoke-WtTweak, so preview, review,
# capture, verification, compensation and rollback are the paths they have always been.
#
# Reading is separated from acting here on purpose:
#   Test-WtCatalogFile      validates a document, prints nothing, registers nothing;
#   Get-WtTweakDefinition   shows a definition, its conditions and its evidence;
#   Get-WtDependencyPlan    plans a selection; the apply set keeps the prerequisites that are
#                           not already satisfied and leaves the satisfied ones alone;
#   Import-WtTweakPack      stores a pack (after confirmation) and registers its definitions;
#   Disable/Remove-WtTweakPack  unregister definitions without making them unrestorable.

<#
.SYNOPSIS
    Validates a catalog or pack document without reading or changing anything on this machine.
.DESCRIPTION
    The same validator the engine uses at load time, exposed for authors: every problem is
    reported with its document path, and nothing is registered, persisted or executed.
.PARAMETER Path
    Document to validate.
.PARAMETER AsPack
    Treat the file as a pack body even when it is being validated from outside the packs
    directory (namespace rules then apply).
.OUTPUTS
    Object with Valid, Errors, Bytes, Sha256, TweakCount and TweakIds.
#>
function Test-WtCatalogFile
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory = $true, Position = 0)][string]$Path,
        [Parameter(Mandatory = $false)][switch]$AsPack
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.CatalogValidation'
            Path       = $Path
            Valid      = $false
            Errors     = @((Get-WtString -Key 'Cat.FileMissing' -Arguments @($Path)))
            Bytes      = 0
            Sha256     = ''
            TweakCount = 0
            TweakIds   = @()
            Overlaps   = @()
        }
    }

    $Read = Read-WtCatalogJson -Path $Path
    if (-not $Read.Ok)
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.CatalogValidation'
            Path       = $Path
            Valid      = $false
            Errors     = @($Read.Errors)
            Bytes      = $Read.Bytes
            Sha256     = ''
            TweakCount = 0
            TweakIds   = @()
            Overlaps   = @()
        }
    }

    $Document = ConvertFrom-WtCatalogElement -Element $Read.Document.RootElement
    $Read.Document.Dispose()

    $Kind = [string]$Document['kind']
    $Source = if ($AsPack -or $Kind -eq 'Pack') { 'Pack' } else { 'BuiltIn' }
    $PackId = if ($Source -eq 'Pack') { [string]$Document['id'] } else { '' }

    $Validation = if ($Kind -eq 'Migrations')
    {
        $Tested = Test-WtMigrationDocument -Document $Document
        @{ Errors = @($Tested.Errors); Tweaks = @($Tested.Records); Overlaps = @() }
    }
    else
    {
        Test-WtCatalogDocument -Document $Document -Source $Source -PackId $PackId
    }

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.CatalogValidation'
        Path       = (Get-Item -LiteralPath $Path).FullName
        Kind       = $Kind
        Valid      = (@($Validation.Errors).Count -eq 0)
        Errors     = @($Validation.Errors)
        Bytes      = $Read.Bytes
        Sha256     = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        TweakCount = @($Validation.Tweaks).Count
        TweakIds   = @(@($Document['tweaks']) | ForEach-Object { [string]$_['id'] })
        Overlaps   = @($Validation.Overlaps)
    }
}


<#
.SYNOPSIS
    Returns one display row per tweak: definition status, scope, risk, lifecycle, support and evidence.
.DESCRIPTION
    The row is data, not text: it carries ids, enums and string-table keys, so a caller renders it
    in the language it is using. `Support` is the status that can be vouched for on this machine -
    Structural for a validated document, ProviderTested when the provider tests exercised it,
    WindowsValidated only when the evidence records a real Windows build, AuthorClaimed or
    Unverified for an imported pack. A pack never reports itself as verified here.
.PARAMETER Filter
    Filter expressions, all of which must match: definitions, powershell, builtin,
    pack[:<pack id>], scope:<name>, risk:<name>, lifecycle:<name>, evidence:<status>,
    support:<status>, category:<name>, tag:<name>, requires:<id>, conflicts:<id>.
.EXAMPLE
    Get-WtTweakDefinitionView -Filter lifecycle:Experimental, scope:Machine
.OUTPUTS
    Rows with Id, Category, Name, Lifecycle, Scope, Privilege, Risk, Restart, Rollback, States,
    DefaultState, Source, PackId, Revision, Support, Evidence, Requires, RunAfter, ConflictsWith,
    Tags and DisplayName (the name in the active language). An unrecognised filter expression is a
    write-error and yields no rows, so a typo cannot silently select a different set.
#>
function Get-WtTweakDefinitionView
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param ([Parameter(Mandatory = $false)][string[]]$Filter = @())

    $Rows = @(Get-WtTweak | ForEach-Object { Get-WtDefinitionRowInternal -Tweak $_ })
    $Selected = Select-WtDefinitionRowInternal -Rows $Rows -Filter @($Filter)

    if (@($Selected.Unknown).Count -gt 0)
    {
        Write-Error -Message (Get-WtString -Key 'Cat.FilterUnknown' -Arguments @(($Selected.Unknown -join ', ')))
        return
    }

    return @($Selected.Rows | ForEach-Object {
            [pscustomobject]@{
                PSTypeName    = 'WindowsTweaker.DefinitionView'
                Id            = $_.Id
                Category      = $_.Category
                Name          = $_.Name
                DisplayName   = Get-WtText -Value $_.Name
                Lifecycle     = $_.Lifecycle
                Scope         = $_.Scope
                Privilege     = $_.Privilege
                Risk          = $_.Risk
                Restart       = $_.Restart
                Rollback      = $_.Rollback
                States        = @($_.States)
                DefaultState  = $_.DefaultState
                Backed        = [bool]$_.Backed
                Source        = $_.Source
                PackId        = $_.PackId
                Revision      = $_.Revision
                Support       = $_.Support
                Evidence      = $_.Evidence
                Requires      = @($_.Requires)
                RunAfter      = @($_.RunAfter)
                ConflictsWith = @($_.ConflictsWith)
                Tags          = @($_.Tags)
            }
        })
}

<#
.SYNOPSIS
    Returns the declarative definition behind a tweak, or $null when it is not catalog-backed.
.DESCRIPTION
    Prints nothing and changes nothing. The definition is the document as loaded: operations per
    state, detection map, conditions, references and the separated evidence blocks.
.PARAMETER Id
    Tweak id (an alias recorded in the migration registry is accepted).
.OUTPUTS
    Object with Id, Source, PackId, Revision, Definition, Validation, Conditions, Evidence,
    References, Tags, Requires, RunAfter, ConflictsWith, Aliases and the Display* texts in the
    active language; $null when the tweak is not catalog-backed.
#>
function Get-WtTweakDefinition
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param ([Parameter(Mandatory = $true, Position = 0)][string]$Id)

    $Resolved = Resolve-WtTweakIdInternal -Id $Id
    if (-not $Resolved.Tweak -or -not $Resolved.Tweak.DefinitionDocument)
    {
        return $null
    }

    $Tweak = $Resolved.Tweak
    $Aliases = @(Get-WtTweakHistoryIdsInternal -Id $Tweak.Id | Where-Object { $_ -ne $Tweak.Id })

    return [pscustomobject]@{
        PSTypeName     = 'WindowsTweaker.TweakDefinition'
        Id             = $Tweak.Id
        RequestedId    = $Id
        Aliases        = @($Aliases)
        Source         = [string]$Tweak.DefinitionSource
        PackId         = [string]$Tweak.DefinitionPackId
        Revision       = [int]$Tweak.DefinitionRevision
        Tags           = @($Tweak.DefinitionTags)
        Lifecycle      = [string]$Tweak.Lifecycle
        Scope          = [string]$Tweak.Scope
        Privilege      = [string]$Tweak.Privilege
        Risk           = [string]$Tweak.Risk
        Restart        = [string]$Tweak.Restart
        Rollback       = [string]$Tweak.Rollback
        SideEffects    = $Tweak.DefinitionSideEffects
        Requires       = @($Tweak.DefinitionRequires)
        RunAfter       = @($Tweak.DefinitionRunAfter)
        ConflictsWith  = @($Tweak.DefinitionConflictsWith)
        Conditions     = $Tweak.DefinitionConditions
        Detection      = $Tweak.Detection
        States         = $Tweak.States
        DefaultState   = [string]$Tweak.DefaultState
        Evidence       = $Tweak.DefinitionEvidence
        References     = @($Tweak.DefinitionReferences)
        Validation     = $Tweak.DefinitionValidation
        Document       = $Tweak.DefinitionDocument
        DisplayName        = Get-WtText -Value $Tweak.Name
        DisplayDescription = Get-WtText -Value $Tweak.Description
        DisplayImpact      = Get-WtText -Value $Tweak.Impact
        DisplaySideEffects = Get-WtText -Value $Tweak.DefinitionSideEffects
        Group              = if (@($Tweak.PSObject.Properties.Name) -contains 'DefinitionGroup') { $Tweak.DefinitionGroup } else { $null }
        Recommendation     = if (@($Tweak.PSObject.Properties.Name) -contains 'DefinitionRecommendation') { $Tweak.DefinitionRecommendation } else { $null }
        Effective          = if (@($Tweak.PSObject.Properties.Name) -contains 'DefinitionEffective') { $Tweak.DefinitionEffective } else { $null }
        DisplayGroupNotes  = if ($Tweak.DefinitionGroup -and $Tweak.DefinitionGroup.Notes) { Get-WtText -Value $Tweak.DefinitionGroup.Notes } else { '' }
        DisplayRecommendationRationale = if ($Tweak.DefinitionRecommendation -and $Tweak.DefinitionRecommendation.Rationale) { Get-WtText -Value $Tweak.DefinitionRecommendation.Rationale } else { '' }
        DisplayEffectiveNote = if ($Tweak.DefinitionEffective -and $Tweak.DefinitionEffective.Note) { Get-WtText -Value $Tweak.DefinitionEffective.Note } else { '' }
    }
}

<#
.SYNOPSIS
    Plans a selection of tweaks, including the prerequisites of their dependencies.
.DESCRIPTION
    Read-only. Prerequisites that are already at their default state are excluded from the
    apply set and are never rewritten; prerequisites whose state cannot be read stay in the plan
    and are reported as unreadable. Cycles, conflicts and unknown ids are reported instead of
    being resolved by guessing.
.PARAMETER Id
    Selected tweak ids.
.PARAMETER State
    Optional map of tweak id -> requested state for the selected tweaks.
.EXAMPLE
    Get-WtDependencyPlan -Id Privacy.BingSearch, Privacy.SearchHighlights
.OUTPUTS
    Object with Items (in apply order), Order, Errors, Warnings, Conflicts and Unresolved.
#>
function Get-WtDependencyPlan
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipelineByPropertyName = $true)][string[]]$Id,
        [Parameter(Mandatory = $false)][hashtable]$State = @{}
    )

    process
    {
        $Plan = Get-WtDependencyPlanInternal -Ids @($Id) -State $State
    }

    end
    {
        if (-not $Plan) { return }

        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.DependencyPlan'
            Items      = @($Plan.Items)
            Order      = @($Plan.Order)
            Apply      = @($Plan.Items | Where-Object { $_.Action -eq 'Apply' })
            Satisfied  = @($Plan.Items | Where-Object { $_.Action -eq 'Skip-Satisfied' })
            Errors     = @($Plan.Errors)
            Warnings   = @($Plan.Warnings)
            Conflicts  = @($Plan.Conflicts)
            Unresolved = @($Plan.Unresolved)
        }
    }
}

<#
.SYNOPSIS
    Lists the recorded id migrations (renames, replacements, retirements).
.PARAMETER Id
    Return only the record that starts at this id.
.PARAMETER Problems
    Report ids that no longer resolve, as seen from a stored preset or an exported report.
.EXAMPLE
    Get-WtTweakMigration
.OUTPUTS
    Migration records, each with From, To, Kind, Since, Reason and whether it is active.
#>
function Get-WtTweakMigration
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory = $false, Position = 0)][string]$Id,
        [Parameter(Mandatory = $false)][switch]$Problems
    )

    if ($Problems)
    {
        $Findings = @()
        foreach ($Preset in @(Get-WtPreset))
        {
            foreach ($Entry in @($Preset.Entries))
            {
                $Resolved = Resolve-WtTweakIdInternal -Id ([string]$Entry.id)
                if ($Resolved.Tweak) { continue }

                $Findings += [pscustomobject]@{
                    PSTypeName = 'WindowsTweaker.MigrationFinding'
                    Preset     = $Preset.Name
                    Id         = [string]$Entry.id
                    Reason     = if ($Resolved.Retired) { Get-WtString -Key 'Cat.IdRetired' -Arguments @($Entry.id) } else { Get-WtString -Key 'Cat.IdUnknown' -Arguments @($Entry.id) }
                }
            }
        }

        return @($Findings)
    }

    $Records = @(Get-WtTweakMigrationInternal -Id $Id)
    return @($Records | ForEach-Object {
            [pscustomobject]@{
                PSTypeName = 'WindowsTweaker.TweakMigration'
                From       = $_.From
                To         = $_.To
                Kind       = $_.Kind
                Since      = $_.Since
                Reason     = $_.Reason
                Active     = ($_.Kind -ne 'deprecate' -and $Script:WtCatalog.Contains($_.To)) -or ($_.Kind -eq 'deprecate')
            }
        })
}

<#
.SYNOPSIS
    Lists the packs stored on this machine, enabled or not.
.PARAMETER Id
    Return only this pack.
.EXAMPLE
    Get-WtTweakPack
.OUTPUTS
    Pack objects with Id, Version, TweakCount, Enabled, Sha256, ImportedUtc and paths.
#>
function Get-WtTweakPack
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param ([Parameter(Mandatory = $false, Position = 0)][string]$Id)

    return @(Get-WtTweakPackInternal -Id $Id | ForEach-Object {
            [pscustomobject]@{
                PSTypeName   = 'WindowsTweaker.TweakPack'
                Id           = $_.Id
                Version      = $_.Version
                Name         = $_.Name
                Author       = $_.Author
                TweakCount   = $_.TweakCount
                TweakIds     = @($_.TweakIds)
                Enabled      = $_.Enabled
                Sha256       = $_.Sha256
                Bytes        = $_.Bytes
                ImportedUtc  = $_.ImportedUtc
                Source       = $_.Source
                DocumentPath = $_.DocumentPath
                RecordsPath  = $_.RecordPath
            }
        })
}

<#
.SYNOPSIS
    Imports a pack: validates it, shows what it contains, stores it and registers its definitions.
.DESCRIPTION
    No Windows change happens here - a pack only adds definitions, and applying one still goes
    through the reviewed apply path. The document is stored byte for byte with its SHA-256, and
    it is refused when it is invalid, when it declares an id outside its own namespace, or when
    its id is already installed without -Force. -WhatIf validates and shows without storing.
.PARAMETER Path
    Pack document to import.
.PARAMETER Enable
    Register the definitions immediately (they are available to the interface either way; this
    only decides whether the pack is loaded on the next start).
.PARAMETER Force
    Replace an already installed pack with the same id.
.EXAMPLE
    Import-WtTweakPack -Path ./samples/example-pack.json -Enable
.OUTPUTS
    Object with Id, Imported, Enabled, TweakIds, Sha256, DocumentPath and Errors.
#>
function Import-WtTweakPack
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory = $true, Position = 0)][string]$Path,
        [Parameter(Mandatory = $false)][switch]$Enable,
        [Parameter(Mandatory = $false)][switch]$Force
    )

    $Tested = Test-WtPackFile -Path $Path
    if (-not $Tested.Ok)
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.PackImport'
            Path       = $Path
            Imported   = $false
            Errors     = @($Tested.Errors)
            TweakIds   = @()
        }
    }

    $Installed = @(Get-WtTweakPackInternal -Id $Tested.Metadata.Id)
    if ($Installed.Count -gt 0 -and -not $Force)
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.PackImport'
            Path       = $Path
            Imported   = $false
            Errors     = @((Get-WtString -Key 'Cat.PackAlreadyInstalled' -Arguments @($Tested.Metadata.Id, $Installed[0].Version, $Tested.Metadata.Version)))
            TweakIds   = @()
        }
    }

    $Target = Get-WtString -Key 'Cat.PackTarget' -Arguments @($Tested.Metadata.Id, $Tested.Sha256.Substring(0, 12))
    if (-not $PSCmdlet.ShouldProcess($Target, (Get-WtString -Key 'Cat.PackImportAction' -Arguments @($Tested.Metadata.TweakIds.Count))))
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.PackImport'
            Path       = $Path
            Imported   = $false
            Enabled    = $false
            Sha256     = $Tested.Sha256
            TweakIds   = @($Tested.Metadata.TweakIds)
            Errors     = @()
            Messages   = @((Get-WtString -Key 'Cat.PackNotImported'))
        }
    }

    $Saved = Save-WtTweakPackInternal -Tested $Tested -Enabled ([bool]$Enable) -SourceRoot $Tested.Path

    return [pscustomobject]@{
        PSTypeName   = 'WindowsTweaker.PackImport'
        Path         = $Path
        Id           = $Saved.Id
        Imported     = $true
        Enabled      = [bool]$Saved.Enabled
        Sha256       = $Saved.Sha256
        TweakIds     = @($Saved.TweakIds)
        DocumentPath = $Saved.DocumentPath
        Errors       = @()
        Messages     = @((Get-WtString -Key 'Cat.PackImported' -Arguments @($Saved.Id, @($Saved.TweakIds).Count)))
    }
}

<#
.SYNOPSIS
    Registers the definitions of a stored pack.
.PARAMETER Id
    Pack id.
.OUTPUTS
    Object with Id, Enabled, TweakIds and Errors.
#>
function Enable-WtTweakPack
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param ([Parameter(Mandatory = $true, Position = 0)][string]$Id)

    $Record = @(Get-WtTweakPackInternal -Id $Id)
    if ($Record.Count -eq 0)
    {
        return [pscustomobject]@{ PSTypeName = 'WindowsTweaker.PackState'; Id = $Id; Enabled = $false; Errors = @((Get-WtString -Key 'Cat.PackNotFound' -Arguments @($Id))) }
    }

    if (-not $PSCmdlet.ShouldProcess($Id, (Get-WtString -Key 'Cat.PackEnableAction' -Arguments @(@($Record[0].TweakIds).Count))))
    {
        return [pscustomobject]@{ PSTypeName = 'WindowsTweaker.PackState'; Id = $Id; Enabled = [bool]$Record[0].Enabled; TweakIds = @($Record[0].TweakIds); Errors = @() }
    }

    $Result = Set-WtTweakPackStateInternal -Id $Id -Enabled $true
    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.PackState'
        Id         = $Id
        Enabled    = [bool]$Result.Ok
        TweakIds   = @($Result.TweakIds)
        Errors     = @($Result.Errors)
    }
}

<#
.SYNOPSIS
    Unregisters the definitions of a stored pack without deleting it.
.DESCRIPTION
    Journal entries created by the pack stay restorable: a restore replays the captured original
    state, which does not need the definition.
.PARAMETER Id
    Pack id.
.OUTPUTS
    Object with Id, Enabled, TweakIds and Errors.
#>
function Disable-WtTweakPack
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param ([Parameter(Mandatory = $true, Position = 0)][string]$Id)

    $Record = @(Get-WtTweakPackInternal -Id $Id)
    if ($Record.Count -eq 0)
    {
        return [pscustomobject]@{ PSTypeName = 'WindowsTweaker.PackState'; Id = $Id; Enabled = $false; Errors = @((Get-WtString -Key 'Cat.PackNotFound' -Arguments @($Id))) }
    }

    $Pending = @(Get-WtPendingPackEntry -TweakIds @($Record[0].TweakIds))
    if ($Pending.Count -gt 0 -and -not $PSCmdlet.ShouldProcess($Id, (Get-WtString -Key 'Cat.PackDisablePendingAction' -Arguments @($Pending.Count))))
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.PackState'
            Id         = $Id
            Enabled    = [bool]$Record[0].Enabled
            TweakIds   = @($Record[0].TweakIds)
            Pending    = @($Pending)
            Errors     = @()
        }
    }

    $Result = Set-WtTweakPackStateInternal -Id $Id -Enabled $false
    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.PackState'
        Id         = $Id
        Enabled    = $false
        TweakIds   = @($Result.TweakIds)
        Pending    = @($Pending)
        Errors     = @($Result.Errors)
    }
}

<#
.SYNOPSIS
    Removes a stored pack and its definitions.
.PARAMETER Id
    Pack id.
.PARAMETER Force
    Remove even when changes the pack created have not been rolled back. Those changes stay
    restorable from their captured state; they are listed first so the decision is informed.
.EXAMPLE
    Remove-WtTweakPack -Id Contoso.Hardening
.OUTPUTS
    Object with Id, Removed, Pending and Errors.
#>
function Remove-WtTweakPack
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory = $true, Position = 0)][string]$Id,
        [Parameter(Mandatory = $false)][switch]$Force
    )

    $Record = @(Get-WtTweakPackInternal -Id $Id)
    if ($Record.Count -eq 0)
    {
        return [pscustomobject]@{ PSTypeName = 'WindowsTweaker.PackRemoval'; Id = $Id; Removed = $false; Errors = @((Get-WtString -Key 'Cat.PackNotFound' -Arguments @($Id))) }
    }

    $Pending = @(Get-WtPendingPackEntry -TweakIds @($Record[0].TweakIds))
    if ($Pending.Count -gt 0 -and -not $Force)
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.PackRemoval'
            Id         = $Id
            Removed    = $false
            Pending    = @($Pending)
            Errors     = @((Get-WtString -Key 'Cat.PackPendingEntries' -Arguments @($Id, $Pending.Count)))
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Id, (Get-WtString -Key 'Cat.PackRemoveAction')))
    {
        return [pscustomobject]@{ PSTypeName = 'WindowsTweaker.PackRemoval'; Id = $Id; Removed = $false; Pending = @($Pending); Errors = @() }
    }

    $Result = Remove-WtTweakPackInternal -Id $Id -Force:$Force
    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.PackRemoval'
        Id         = $Id
        Removed    = [bool]$Result.Ok
        Pending    = @($Pending)
        TweakIds   = @($Result.TweakIds)
        Errors     = @($Result.Errors)
    }
}
