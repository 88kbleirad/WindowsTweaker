# WindowsTweaker - stable-ID migration registry.
#
# A tweak id is a contract: it appears in presets, in exported reports and, above all, in the
# journal. When a definition is renamed, replaced or retired, the old id must keep working for
# everything that already refers to it, and nothing that already ran may lose its provenance.
#
# This registry is data (Data/Catalog/migrations.json, overridable with WT_MIGRATIONS_PATH):
#
#   { "from": "Old.Id", "to": "New.Id", "kind": "rename"|"replace"|"deprecate", ... }
#
# Rules, all enforced at load time:
#   * `from` is unique, well formed, and never equal to `to`;
#   * the target of a rename/replace must exist in this catalog (a migration that points at
#     nothing is reported, never silently accepted);
#   * chains are followed with a hard hop limit and a cycle check, so a rename loop is an
#     error rather than a hang;
#   * `deprecate` needs no target: the id stays resolvable as retired, which is what lets a
#     restoration still name it.
#
# What a migration never does: rewrite journal entries, presets or reports. Their ids are
# historical and stay exactly as written; resolution happens on lookup, so a restore keeps
# replaying the captured state of the id that was actually applied.

$Script:WtMigrationKinds = @('rename', 'replace', 'deprecate')
$Script:WtMigrationDocumentKeys = @('schemaVersion', 'kind', 'id', 'description', 'migrations')
$Script:WtMigrationRecordKeys = @('from', 'to', 'kind', 'since', 'notes', 'reason')
$Script:WtMigrationMaxHops = 8
$Script:WtMigrations = @()
$Script:WtMigrationErrors = @()

<#
.SYNOPSIS
    Path of the migration registry (WT_MIGRATIONS_PATH overrides it).
#>
function Get-WtMigrationPath
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    if ($env:WT_MIGRATIONS_PATH)
    {
        return [System.IO.Path]::GetFullPath($env:WT_MIGRATIONS_PATH)
    }

    return (Join-Path (Join-Path $Script:WtDataDirectory 'Catalog') 'migrations.json')
}

<#
.SYNOPSIS
    Validates a parsed migration document.
.OUTPUTS
    @{ Errors; Records }
#>
function Test-WtMigrationDocument
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Document)

    $Errors = [System.Collections.Generic.List[string]]::new()
    $Records = [System.Collections.Generic.List[object]]::new()
    $Add = { param ([string]$Message) if ($Errors.Count -lt $Script:WtCatalogLimits.MaxErrors) { $Errors.Add($Message) } }

    foreach ($Problem in (Test-WtCatalogKeys -Table $Document -Allowed $Script:WtMigrationDocumentKeys -Path '$')) { & $Add $Problem }

    $Version = 0
    try { $Version = [int]$Document['schemaVersion'] } catch { & $Add '$.schemaVersion : must be an integer.' }
    if ($Version -ne $Script:WtCatalogSchemaVersion) { & $Add "$.schemaVersion : version $Version is not supported (supported: $($Script:WtCatalogSchemaVersion))." }

    if ([string]$Document['kind'] -ne 'Migrations') { & $Add "$.kind : must be 'Migrations'." }

    $Seen = @{}
    foreach ($Record in @($Document['migrations']))
    {
        $From = ''
        if ($Record -isnot [System.Collections.IDictionary])
        {
            & $Add '$.migrations[] : every entry must be an object.'
            continue
        }

        foreach ($Problem in (Test-WtCatalogKeys -Table $Record -Allowed $Script:WtMigrationRecordKeys -Path '$.migrations[]')) { & $Add $Problem }

        $From = [string]$Record['from']
        $Kind = [string]$Record['kind']
        $To = if ($Record.Contains('to')) { [string]$Record['to'] } else { '' }

        if ($From -notmatch $Script:WtTweakIdPattern)
        {
            & $Add "$.migrations[].from : '$From' is not a tweak id."
        }
        elseif ($Seen.ContainsKey($From))
        {
            & $Add "$.migrations[].from : '$From' is declared twice."
        }
        else
        {
            $Seen[$From] = $true
        }

        if ($Script:WtMigrationKinds -notcontains $Kind)
        {
            & $Add "$.migrations[].kind : '$Kind' is not supported ($($Script:WtMigrationKinds -join ', '))."
        }

        if ($Kind -in 'rename', 'replace')
        {
            if (-not $To)
            {
                & $Add "$.migrations[] : '$From' ($Kind) needs a 'to' id."
            }
            elseif ($To -notmatch $Script:WtTweakIdPattern)
            {
                & $Add "$.migrations[].to : '$To' is not a tweak id."
            }
            elseif ($To -eq $From)
            {
                & $Add "$.migrations[] : '$From' cannot migrate to itself."
            }
            elseif (-not $Script:WtCatalog.Contains($To))
            {
                & $Add "$.migrations[].to : '$To' does not exist in this catalog; the migration for '$From' cannot be used."
            }
        }
        elseif ($To -and -not $Script:WtCatalog.Contains($To))
        {
            & $Add "$.migrations[].to : '$To' does not exist in this catalog."
        }

        if ($Record.Contains('notes'))
        {
            foreach ($Problem in (Test-WtCatalogLocalized -Value $Record['notes'] -Path '$.migrations[].notes')) { & $Add $Problem }
        }

        if ($Errors.Count -eq 0)
        {
            $Records.Add(@{
                    From   = $From
                    To     = $To
                    Kind   = $Kind
                    Since  = [string]$Record['since']
                    Notes  = if ($Record.Contains('notes')) { $Record['notes'] } else { $null }
                    Reason = [string]$Record['reason']
                })
        }
    }

    # Cycles: follow the chain from every record and refuse a registry that loops.
    if ($Errors.Count -eq 0)
    {
        $Map = @{}
        foreach ($Record in $Records) { $Map[$Record.From] = $Record }

        foreach ($Record in $Records)
        {
            $Visited = @($Record.From)
            $Current = $Record
            $Hops = 0

            while ($Current -and $Current.To -and $Map.ContainsKey($Current.To) -and $Hops -lt $Script:WtMigrationMaxHops)
            {
                $Next = $Map[$Current.To]
                if ($Visited -contains $Next.From)
                {
                    & $Add "$.migrations : '$($Record.From)' migrates in a cycle ($((@($Visited) + $Next.From) -join ' -> '))."
                    break
                }

                $Visited += $Next.From
                $Current = $Next
                $Hops++
            }

            if ($Hops -ge $Script:WtMigrationMaxHops)
            {
                & $Add "$.migrations : the chain starting at '$($Record.From)' is longer than $($Script:WtMigrationMaxHops) hops."
            }
        }
    }

    return @{ Errors = @($Errors.ToArray()); Records = @($Records.ToArray()) }
}

<#
.SYNOPSIS
    Loads and validates the migration registry.
.DESCRIPTION
    Read-only. A missing registry is not an error (nothing has been renamed yet). An invalid
    registry is reported and *inactive*: a broken migration must never silently turn into a
    wrong resolution.
.OUTPUTS
    @{ Path; Records; Errors; Present }
#>
function Import-WtMigrationRegistry
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][string]$Path)

    if (-not $Path) { $Path = Get-WtMigrationPath }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        $Script:WtMigrations = @()
        $Script:WtMigrationErrors = @()
        return @{ Path = $Path; Records = @(); Errors = @(); Present = $false }
    }

    $Read = Read-WtCatalogJson -Path $Path
    if (-not $Read.Ok)
    {
        $Script:WtMigrations = @()
        $Script:WtMigrationErrors = @($Read.Errors)
        return @{ Path = $Path; Records = @(); Errors = @($Read.Errors); Present = $true }
    }

    $Document = ConvertFrom-WtCatalogNode -Node $Read.Document.Root

    $Tested = Test-WtMigrationDocument -Document $Document
    if ($Tested.Errors.Count -gt 0)
    {
        $Script:WtMigrations = @()
        $Script:WtMigrationErrors = @($Tested.Errors)
        return @{ Path = $Path; Records = @(); Errors = @($Tested.Errors); Present = $true }
    }

    $Script:WtMigrations = @($Tested.Records)
    $Script:WtMigrationErrors = @()
    return @{ Path = $Path; Records = @($Tested.Records); Errors = @(); Present = $true }
}

<#
.SYNOPSIS
    Returns the recorded migrations, optionally for one id.
#>
function Get-WtTweakMigrationInternal
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][string]$Id)

    if ($Id)
    {
        return @($Script:WtMigrations | Where-Object { $_.From -eq $Id })
    }

    return @($Script:WtMigrations)
}

<#
.SYNOPSIS
    Resolves a tweak id through the migration registry.
.DESCRIPTION
    Returns the current id, the definition, and whether an alias was followed. A retired id
    resolves to no definition but is still recognised (`Retired = $true`), so callers can say
    "this was retired" instead of "unknown".
.OUTPUTS
    @{ Id; Requested; Tweak; Migrated; Migration; Retired; Reason }
#>
function Resolve-WtTweakIdInternal
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Id)

    $Result = @{ Id = $Id; Requested = $Id; Tweak = $null; Migrated = $false; Migration = $null; Retired = $false; Reason = '' }

    if ([string]::IsNullOrWhiteSpace($Id)) { return $Result }

    if ($Script:WtCatalog.Contains($Id))
    {
        $Result.Tweak = $Script:WtCatalog[$Id]
        return $Result
    }

    $Current = $Id
    $Hops = 0
    while ($Hops -lt $Script:WtMigrationMaxHops)
    {
        $Record = @($Script:WtMigrations | Where-Object { $_.From -eq $Current } | Select-Object -First 1)
        if ($Record.Count -eq 0) { break }

        $Record = $Record[0]
        if ($Record.Kind -eq 'deprecate' -and -not $Record.To)
        {
            $Result.Retired = $true
            $Result.Migration = $Record
            $Result.Reason = "The id '$Id' has been retired."
            return $Result
        }

        if (-not $Record.To) { break }

        $Result.Migrated = $true
        $Result.Migration = $Record
        $Result.Reason = if ($Record.Reason) { $Record.Reason } else { "The id '$Id' was $($Record.Kind)d to '$($Record.To)'." }
        $Current = $Record.To
        $Hops++

        if ($Script:WtCatalog.Contains($Current))
        {
            $Result.Id = $Current
            $Result.Tweak = $Script:WtCatalog[$Current]
            return $Result
        }
    }

    if ($Current -ne $Id) { $Result.Id = $Current }
    return $Result
}

<#
.SYNOPSIS
    Every id that resolves to the same current tweak as the given id.
.DESCRIPTION
    Used where historical ids matter: a journal entry written before a rename stores the old
    id, and a restore must still find it without the entry being rewritten.
.OUTPUTS
    The current id plus every recorded id that migrates to it, oldest names included.
#>
function Get-WtTweakHistoryIdsInternal
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ([Parameter(Mandatory = $true)][string]$Id)

    $Resolved = Resolve-WtTweakIdInternal -Id $Id
    $Current = if ($Resolved.Tweak) { $Resolved.Id } else { $Id }

    $Ids = [System.Collections.Generic.List[string]]::new()
    $Ids.Add($Current)
    if ($Id -ne $Current) { $Ids.Add($Id) }

    foreach ($Record in @($Script:WtMigrations))
    {
        if ($Record.From -eq $Current) { continue }
        $Chain = Resolve-WtTweakIdInternal -Id $Record.From
        if ($Chain.Tweak -and $Chain.Id -eq $Current -and -not $Ids.Contains($Record.From))
        {
            $Ids.Add($Record.From)
        }
    }

    return @($Ids.ToArray())
}
