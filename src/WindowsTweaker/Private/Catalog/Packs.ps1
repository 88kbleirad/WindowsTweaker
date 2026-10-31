# WindowsTweaker - Tweak Packs: a local, data-only extension mechanism.
#
# A pack is the *same document format* as the built-in catalog (kind "Pack"), with one extra
# rule: every tweak id must live inside the pack's own namespace, so an imported pack can
# never redefine, shadow or replace a built-in tweak. Importing a pack:
#
#   validate  -> the same validator the built-in catalog uses, plus the namespace rule;
#   show      -> the registry targets, the states, the risk and the evidence are printed;
#   confirm   -> nothing is persisted or registered before the caller confirms;
#   persist   -> the document and a record (path, SHA-256, date, enabled flag) are stored
#                under the user data root, never inside the module;
#   register  -> the definitions become available through the existing constructor, so
#                preview, review, journal, verification and rollback are unchanged.
#
# What a pack can never do, whatever its document says: run code, name a hive or value type
# outside the documented vocabulary, lower the privilege or risk floor that its own scope and
# flags imply, claim Windows-validated evidence for itself (author claims are recorded as
# author claims), leave its own id namespace, or change Windows at import time. Loading a pack
# is metadata only.

$Script:WtPackIdPattern = '^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z0-9][A-Za-z0-9_-]*)+$'
$Script:WtPackReservedIds = @('builtin', 'catalog')

<#
.SYNOPSIS
    Directory that holds imported packs (document + record per pack).
#>
function Get-WtPacksPath
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    if ($env:WT_PACKS_PATH)
    {
        return [System.IO.Path]::GetFullPath($env:WT_PACKS_PATH)
    }

    return (Join-Path (Get-WtDataRoot) 'packs')
}

<#
.SYNOPSIS
    Returns the stored pack records, newest first, optionally for one pack id.
.OUTPUTS
    Objects with Id, Version, Name, Author, Source, ImportedUtc, Sha256, Bytes, TweakCount,
    Enabled, EngineVersion and TweakIds.
#>
function Get-WtTweakPackInternal
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][string]$Id)

    $Root = Get-WtPacksPath
    if (-not (Test-Path -LiteralPath $Root -PathType Container))
    {
        return @()
    }

    $Records = @()
    foreach ($File in @(Get-ChildItem -LiteralPath $Root -Filter '*.record.json' -File | Sort-Object -Property Name))
    {
        try
        {
            $Record = Get-Content -LiteralPath $File.FullName -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        }
        catch
        {
            continue
        }

        $Records += [pscustomobject]@{
            Id            = [string]$Record.id
            Version       = [string]$Record.version
            Name          = [string]$Record.name
            Author        = [string]$Record.author
            Source        = [string]$Record.source
            ImportedUtc   = [string]$Record.importedUtc
            Sha256        = [string]$Record.sha256
            Bytes         = [int]$Record.bytes
            TweakCount    = [int]$Record.tweakCount
            Enabled       = [bool]$Record.enabled
            EngineVersion = [string]$Record.engineVersion
            TweakIds      = @($Record.tweakIds)
            RecordPath    = $File.FullName
            DocumentPath  = Join-Path $Root ([string]$Record.id + '.json')
        }
    }

    if ($Id)
    {
        $Records = @($Records | Where-Object { $_.Id -eq $Id })
    }

    return @($Records)
}

function Save-WtPackRecordInternal
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][hashtable]$Record)

    $Root = Get-WtPacksPath
    if (-not (Test-Path -LiteralPath $Root -PathType Container))
    {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }

    $Path = Join-Path $Root ($Record.id + '.record.json')
    ($Record | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Path -Encoding utf8
    return $Path
}

<#
.SYNOPSIS
    Reads and fully validates one pack document without writing anything.
.DESCRIPTION
    Read-only: it parses the file, validates the document, checks the namespace of every tweak
    id and computes the SHA-256 of the exact bytes that were read. No registry access, no
    registration, no persistence.
.OUTPUTS
    @{ Ok; Errors; Metadata; Document; Sha256; Bytes; Path }
#>
function Test-WtPackFile
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Path)

    $Errors = [System.Collections.Generic.List[string]]::new()

    $Read = Read-WtCatalogJson -Path $Path
    if (-not $Read.Ok)
    {
        foreach ($Problem in $Read.Errors) { $Errors.Add($Problem) }
        return @{ Ok = $false; Errors = @($Errors.ToArray()); Metadata = $null; Document = $null; Sha256 = ''; Bytes = $Read.Bytes; Path = $Path }
    }

    $Document = ConvertFrom-WtCatalogElement -Element $Read.Document.RootElement
    $Read.Document.Dispose()

    $PackId = [string]$Document['id']
    if ($PackId -notmatch $Script:WtPackIdPattern -or $Script:WtPackReservedIds -contains $PackId.ToLowerInvariant())
    {
        $Errors.Add("$.id : '$PackId' is not a valid pack id (for example 'Contoso.Hardening'); ids reserved by the engine are refused.")
    }

    if ($Errors.Count -eq 0)
    {
        $Validation = Test-WtCatalogDocument -Document $Document -Source 'Pack' -PackId $PackId
        foreach ($Problem in $Validation.Errors) { $Errors.Add($Problem) }
    }

    $Sha = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()

    return @{
        Ok       = ($Errors.Count -eq 0)
        Errors   = @($Errors.ToArray())
        Document = $Document
        Metadata = @{
            Id          = $PackId
            Version     = [string]$Document['version']
            Name        = [string]$Document['description']
            Author      = [string]$Document['author']
            TweakIds    = @(@($Document['tweaks']) | ForEach-Object { [string]$_['id'] })
            TweakCount  = @($Document['tweaks']).Count
        }
        Sha256   = $Sha
        Bytes    = $Read.Bytes
        Path     = (Get-Item -LiteralPath $Path).FullName
    }
}

<#
.SYNOPSIS
    Persists a validated pack document plus its record.
.DESCRIPTION
    Copies the file verbatim (byte for byte, so the recorded hash stays true) into the packs
    directory and writes the record next to it. Registration is the caller's decision.
#>
function Save-WtTweakPackInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$Tested,
        [Parameter(Mandatory = $false)][bool]$Enabled = $true,
        [Parameter(Mandatory = $false)][string]$SourceRoot
    )

    $Root = Get-WtPacksPath
    if (-not (Test-Path -LiteralPath $Root -PathType Container))
    {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }

    $DocumentPath = Join-Path $Root ($Tested.Metadata.Id + '.json')
    Copy-Item -LiteralPath $Tested.Path -Destination $DocumentPath -Force

    $Record = @{
        id            = $Tested.Metadata.Id
        version       = $Tested.Metadata.Version
        name          = $Tested.Metadata.Name
        author        = $Tested.Metadata.Author
        source        = if ($SourceRoot) { $SourceRoot } else { $Tested.Path }
        importedUtc   = [DateTime]::UtcNow.ToString('o')
        sha256        = $Tested.Sha256
        bytes         = $Tested.Bytes
        tweakCount    = $Tested.Metadata.TweakCount
        tweakIds      = @($Tested.Metadata.TweakIds)
        enabled       = $Enabled
        engineVersion = $Script:WtCatalogEngineVersion
    }

    $RecordPath = Save-WtPackRecordInternal -Record $Record

    if ($Enabled)
    {
        [void](Import-WtCatalogDocument -Document $Tested.Document -Source 'Pack' -PackId $Tested.Metadata.Id)
    }

    return [pscustomobject]@{
        Id           = $Record.id
        DocumentPath = $DocumentPath
        RecordPath   = $RecordPath
        Sha256       = $Record.sha256
        Enabled      = [bool]$Record.enabled
        TweakIds     = @($Record.tweakIds)
    }
}

<#
.SYNOPSIS
    Registers or unregisters the definitions of one stored pack.
.DESCRIPTION
    Registering re-validates the stored document from disk, so a pack that was edited or
    corrupted after import is refused instead of half-registered. Unregistering only removes
    the definitions: journal entries that refer to them keep their captured state and stay
    restorable.
#>
function Set-WtTweakPackStateInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )

    $Record = @(Get-WtTweakPackInternal -Id $Id)
    if ($Record.Count -eq 0)
    {
        return @{ Ok = $false; Errors = @("No pack with id '$Id' is registered."); TweakIds = @() }
    }

    $Record = $Record[0]

    if ($Enabled)
    {
        $Tested = Test-WtPackFile -Path $Record.DocumentPath
        if (-not $Tested.Ok)
        {
            return @{ Ok = $false; Errors = @($Tested.Errors) + @("The stored document of pack '$Id' no longer validates; it was not enabled."); TweakIds = @() }
        }

        if ($Tested.Sha256 -ne $Record.Sha256)
        {
            return @{ Ok = $false; Errors = @("The stored document of pack '$Id' does not match the hash recorded at import ($($Record.Sha256)); it was not enabled."); TweakIds = @() }
        }

        $Import = Import-WtCatalogDocument -Document $Tested.Document -Source 'Pack' -PackId $Id -AllowExisting
        if ($Import.Errors.Count -gt 0)
        {
            return @{ Ok = $false; Errors = @($Import.Errors); TweakIds = @() }
        }

        $Record.Enabled = $true
        [void](Save-WtPackRecordInternal -Record (@{
                    id = $Record.Id; version = $Record.Version; name = $Record.Name; author = $Record.Author
                    source = $Record.Source; importedUtc = $Record.ImportedUtc; sha256 = $Record.Sha256
                    bytes = $Record.Bytes; tweakCount = $Record.TweakCount; tweakIds = @($Record.TweakIds)
                    enabled = $true; engineVersion = $Record.EngineVersion
                }))

        return @{ Ok = $true; Errors = @(); TweakIds = @($Record.TweakIds) }
    }

    foreach ($TweakId in @($Record.TweakIds))
    {
        if ($Script:WtCatalog.Contains($TweakId))
        {
            $Script:WtCatalog.Remove($TweakId)
        }
    }

    [void](Save-WtPackRecordInternal -Record (@{
                id = $Record.Id; version = $Record.Version; name = $Record.Name; author = $Record.Author
                source = $Record.Source; importedUtc = $Record.ImportedUtc; sha256 = $Record.Sha256
                bytes = $Record.Bytes; tweakCount = $Record.TweakCount; tweakIds = @($Record.TweakIds)
                enabled = $false; engineVersion = $Record.EngineVersion
            }))

    return @{ Ok = $true; Errors = @(); TweakIds = @($Record.TweakIds) }
}

<#
.SYNOPSIS
    Removes a stored pack (document + record) and its definitions.
.PARAMETER Force
    Remove even when journal entries created by the pack have not been rolled back. Those
    entries stay restorable, because a restore replays the captured original state.
.OUTPUTS
    @{ Ok; Errors; Pending; TweakIds }
#>
function Remove-WtTweakPackInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $false)][switch]$Force
    )

    $Record = @(Get-WtTweakPackInternal -Id $Id)
    if ($Record.Count -eq 0)
    {
        return @{ Ok = $false; Errors = @("No pack with id '$Id' is registered."); Pending = @(); TweakIds = @() }
    }

    $Record = $Record[0]

    $Pending = @(Get-WtPendingPackEntry -TweakIds @($Record.TweakIds))
    if ($Pending.Count -gt 0 -and -not $Force)
    {
        return @{ Ok = $false; Errors = @(); Pending = $Pending; TweakIds = @($Record.TweakIds) }
    }

    [void](Set-WtTweakPackStateInternal -Id $Id -Enabled $false)

    foreach ($Path in @($Record.DocumentPath, $Record.RecordPath))
    {
        if (Test-Path -LiteralPath $Path)
        {
            Remove-Item -LiteralPath $Path -Force
        }
    }

    return @{ Ok = $true; Errors = @(); Pending = @(); TweakIds = @($Record.TweakIds) }
}

<#
.SYNOPSIS
    Journal entries created by the given tweaks that have not been rolled back.
.OUTPUTS
    Objects with HistoryId, TweakId, CreatedUtc, TargetCount.
#>
function Get-WtPendingPackEntry
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string[]]$TweakIds)

    $Store = Read-WtStateStore
    if (-not $Store -or $Store.Corrupt) { return @() }

    $Pending = @()
    foreach ($Entry in @($Store.History))
    {
        if ($Entry.rolledBack) { continue }
        if (-not $Entry.tweakId) { continue }
        if ($TweakIds -notcontains $Entry.tweakId) { continue }

        $Pending += [pscustomobject]@{
            HistoryId   = [string]$Entry.historyId
            TweakId     = [string]$Entry.tweakId
            CreatedUtc  = [string]$Entry.createdUtc
            TargetCount = @($Entry.targets).Count
        }
    }

    return @($Pending)
}

<#
.SYNOPSIS
    Registers every enabled pack stored on this machine. Called once at module load.
.DESCRIPTION
    A pack that no longer validates (edited, truncated, hand-modified) is skipped and logged;
    the module still loads, and the pack stays listed as disabled-but-present so the user can
    inspect or remove it.
.OUTPUTS
    @{ Registered; Skipped; Errors }
#>
function Import-WtTweakPackRegistry
{
    [CmdletBinding()]
    param ()

    $Registered = [System.Collections.Generic.List[string]]::new()
    $Skipped = [System.Collections.Generic.List[object]]::new()
    $Errors = [System.Collections.Generic.List[string]]::new()

    foreach ($Record in @(Get-WtTweakPackInternal))
    {
        if (-not $Record.Enabled)
        {
            $Skipped.Add(@{ Id = $Record.Id; Reason = 'disabled' })
            continue
        }

        $Tested = Test-WtPackFile -Path $Record.DocumentPath
        if (-not $Tested.Ok)
        {
            foreach ($Problem in $Tested.Errors) { $Errors.Add("Pack $($Record.Id): $Problem") }
            $Skipped.Add(@{ Id = $Record.Id; Reason = 'invalid' })
            continue
        }

        if ($Tested.Sha256 -ne $Record.Sha256)
        {
            $Errors.Add("Pack $($Record.Id): the stored document does not match the hash recorded at import; it was not loaded.")
            $Skipped.Add(@{ Id = $Record.Id; Reason = 'hash-mismatch' })
            continue
        }

        $Import = Import-WtCatalogDocument -Document $Tested.Document -Source 'Pack' -PackId $Record.Id -AllowExisting
        foreach ($Problem in @($Import.Errors)) { $Errors.Add("Pack $($Record.Id): $Problem") }
        foreach ($Id in @($Import.Registered)) { $Registered.Add($Id) }
        if ($Import.Errors.Count -gt 0) { $Skipped.Add(@{ Id = $Record.Id; Reason = 'registration-failed' }) }
    }

    return @{
        Registered = @($Registered.ToArray())
        Skipped    = @($Skipped.ToArray())
        Errors     = @($Errors.ToArray())
    }
}
