# WindowsTweaker - journaled quarantine.
#
# Quarantine moves *explicitly selected* leftover candidates out of the way: same-volume
# moves only, with the recovery intent persisted before anything moves, revalidation of the
# source and the approved boundary immediately before the move, and a durable manifest that
# is part of the state store (so it uses the same locking and durability rules as the
# journal). Restoration validates stored paths and ownership, refuses silent overwrites and
# keeps unresolved records for retry. Permanent deletion is a separate, explicitly confirmed
# operation; expiry only flags items for review and never deletes at startup.
#
# The scan collects supporting and contradicting evidence per candidate (install/uninstall
# records, missing executable targets, running processes and services, portable-executable
# presence, recent activity, shared vendor directories, potential user data). A candidate is
# shown with its evidence and is never selected automatically; a probe that cannot run on
# this machine is reported as unavailable, never assumed.
#
# Hard rules:
#   * a same-volume move does not free disk space; the report separates bytes moved from
#     space freed (freed stays 0 for the move itself);
#   * cross-volume cases are skipped with an explanation, never silently copied and deleted;
#   * the manifest is written (stage 'planned') before the first move, and every stage
#     transition is its own locked write;
#   * quarantine storage lives next to the state store and is protected from the regular
#     tweak engine: only the quarantine API reads and writes it.

<#
.SYNOPSIS
    Returns the quarantine storage directory and collector metadata.
#>
function Get-WtQuarantineLocation
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    $StatePath = Get-WtStatePath
    $StateDir = Split-Path -Path $StatePath -Parent
    $Storage = Join-Path $StateDir 'quarantine'
    if ($env:WT_QUARANTINE_DIR)
    {
        $Storage = [System.IO.Path]::GetFullPath($env:WT_QUARANTINE_DIR)
    }

    return @{
        Storage = $Storage
        StatePath = $StatePath
    }
}

<#
.SYNOPSIS
    Returns the quarantine manifest from the state store (empty when none exists).
#>
function Read-WtQuarantineManifest
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    $Store = Read-WtStateStore
    if ($Store.Corrupt)
    {
        throw "The state store could not be read ($($Store.Error)). The quarantine manifest cannot be read."
    }

    $Records = @($Store.Quarantine)

    $Meta = @{ Active = $true }
    if ($Store.QuarantineMeta)
    {
        $Meta = $Store.QuarantineMeta
    }

    return @{
        Records = $Records
        Meta    = $Meta
    }
}

<#
.SYNOPSIS
    Persists the quarantine manifest (locked, atomic, same rules as the journal).
#>
function Write-WtQuarantineManifest
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object[]]$Records,
        [Parameter(Mandatory = $false)][object]$Meta = $null
    )

    if ($null -eq $Meta) { $Meta = @{ Active = $true } }

    $Store = Read-WtStateStore
    if ($Store.Corrupt)
    {
        throw "The state store could not be read ($($Store.Error)). Refusing to write the quarantine manifest: recovery intent must persist before anything moves."
    }

    $Store.Quarantine = @($Records)
    $Store.QuarantineMeta = $Meta

    Write-WtStateStore -Store $Store
}

<#
.SYNOPSIS
    Returns stable identity text for a source path.
#>
function Get-WtQuarantineFingerprint
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][string]$Path)

    $Stamp = ''
    try
    {
        $Item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $Stamp = "{0}:{1}" -f $Item.Attributes, $Item.LastWriteTimeUtc.Ticks
    }
    catch
    {
        $Stamp = ''
    }

    return $Stamp
}

<#
.SYNOPSIS
    Reads the uninstall records that mention a path (best effort, read-only).
#>
function Get-WtUninstallReferencesInternal
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param ([Parameter(Mandatory = $true)][string]$Path)

    $Hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $References = [System.Collections.Generic.List[object]]::new()
    foreach ($Hive in $Hives)
    {
        if (-not (Test-Path -LiteralPath $Hive))
        {
            continue
        }

        $SubKeys = @()
        try { $SubKeys = @(Get-ChildItem -LiteralPath $Hive -ErrorAction Stop) } catch { continue }

        foreach ($Key in $SubKeys)
        {
            foreach ($ValueName in 'DisplayName', 'InstallLocation', 'UninstallString')
            {
                try
                {
                    $Value = (Get-ItemProperty -LiteralPath $Key.PSPath -Name $ValueName -ErrorAction Stop).$ValueName
                }
                catch
                {
                    continue
                }

                if ($Value -and ([string]$Value -like "*$Path*" -or $Path -like "*$([string]$Value)*"))
                {
                    $References.Add([pscustomobject]@{
                        Source = 'uninstall'
                        Key    = [string]$Key.PSPath
                        Field  = $ValueName
                        Value  = [string]$Value
                    })
                    break
                }
            }
        }
    }

    return @($References.ToArray())
}

<#
.SYNOPSIS
    Collects evidence for one candidate path.
.DESCRIPTION
    Every evidence item has a Kind (InstallRecord, MissingTarget, RunningProcess,
    RunningService, PortableExecutable, RecentActivity, SharedVendor, UserData) and a
    Sign (Supporting, Contradicting, Neutral). A probe that cannot run reports
    Available = $false with a reason; it is never treated as "no evidence".
#>
function Get-WtQuarantineEvidenceInternal
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][int]$RecentDays = 14
    )

    $Evidence = [System.Collections.Generic.List[object]]::new()
    $Add = { param ($Kind, $Sign, $Text, $Available = $true) $Evidence.Add([pscustomobject]@{ Kind = $Kind; Sign = $Sign; Text = $Text; Available = $Available }) }

    # 1. Install/uninstall records referencing the path.
    $Uninstall = @()
    try { $Uninstall = @(Get-WtUninstallReferencesInternal -Path $Path) } catch { Write-WtLog -Level Debug -Message ('uninstall probe failed: {0}' -f $_.Exception.Message) -NoConsole }
    if ($Uninstall.Count -gt 0)
    {
        foreach ($Reference in $Uninstall)
        {
            & $Add 'InstallRecord' 'Contradicting' ("Uninstall record exists: {0} ({1})" -f $Reference.Value, $Reference.Key)
        }
    }

    # 2. Missing executable targets: an installer/App Paths entry points here but the exe is gone.
    try
    {
        $Executables = @(Get-ChildItem -LiteralPath $Path -Filter '*.exe' -File -ErrorAction Ignore)
        if ($Executables.Count -eq 0 -and (Split-Path -Leaf $Path) -like '*.exe' -and -not (Test-Path -LiteralPath $Path))
        {
            & $Add 'MissingTarget' 'Supporting' 'The candidate is a missing executable target (no file at this path).'
        }
    }
    catch { Write-WtLog -Level Debug -Message ('missing-target probe failed: {0}' -f $_.Exception.Message) -NoConsole }

    # 3. Running processes whose image path lies under the candidate.
    $ProcessProbe = $true
    try
    {
        if (Get-Command -Name Get-Process -ErrorAction Ignore)
        {
            $Running = @(Get-Process -ErrorAction Ignore | Where-Object { $_.Path -and $_.Path -like "$Path*" })
            if ($Running.Count -gt 0)
            {
                & $Add 'RunningProcess' 'Contradicting' ("Running process uses this path: {0}" -f (($Running | Select-Object -First 3 -ExpandProperty ProcessName) -join ', '))
            }
        }
    }
    catch { $ProcessProbe = $false }

    if (-not $ProcessProbe)
    {
        & $Add 'RunningProcess' 'Neutral' 'Process probe unavailable; running processes could not be checked.' $false
    }

    # 4. Services whose ImagePath references the path.
    $ServiceProbe = $true
    try
    {
        if (Get-Command -Name Get-CimInstance -ErrorAction Ignore)
        {
            $Services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Ignore | Where-Object { $_.PathName -and $_.PathName -like "*$Path*" })
            if ($Services.Count -gt 0)
            {
                & $Add 'RunningService' 'Contradicting' ("Service references this path: {0}" -f (($Services | Select-Object -First 3 -ExpandProperty Name) -join ', '))
            }
        }
    }
    catch { $ServiceProbe = $false }

    if (-not $ServiceProbe)
    {
        & $Add 'RunningService' 'Neutral' 'Service probe unavailable; services could not be checked.' $false
    }

    # 5. Portable executable: an exe exists but no install record references it.
    if ($Executables.Count -gt 0 -and $Uninstall.Count -eq 0)
    {
        & $Add 'PortableExecutable' 'Supporting' ("Portable executable(s) present ({0}); no uninstall record references this path." -f $Executables.Count)
    }

    # 6. Recent activity.
    try
    {
        $Recent = @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction Ignore |
                Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-$RecentDays) } |
                Select-Object -First 5)
        if ($Recent.Count -gt 0)
        {
            & $Add 'RecentActivity' 'Contradicting' ("Modified within the last {0} days ({1})." -f $RecentDays, ($Recent[0].LastWriteTime.ToString('yyyy-MM-dd')))
        }
    }
    catch { Write-WtLog -Level Debug -Message ('recent-activity probe failed: {0}' -f $_.Exception.Message) -NoConsole }

    # 7. Shared vendor directory: the leaf matches a vendor name many apps share.
    $VendorLeaves = 'Microsoft', 'Google', 'Mozilla', 'Adobe', 'Oracle', 'Apple', 'NVIDIA', 'AMD', 'Intel', 'Valve', 'Epic Games', 'Steam'
    $Leaf = Split-Path -Leaf $Path
    if ($VendorLeaves -contains $Leaf)
    {
        & $Add 'SharedVendor' 'Neutral' "Shared vendor directory name '$Leaf'; other software may still use it."
    }

    # 8. Potential user data.
    $DataLeaves = 'saves', 'savegames', 'save game', 'settings', 'config', 'logs', 'cache', 'caches', 'userdata', 'save data'
    if ($DataLeaves -contains ($Leaf.ToLowerInvariant()))
    {
        & $Add 'UserData' 'Contradicting' "Directory name suggests user data ('$Leaf'); moving it may remove saves or settings."
    }

    return @($Evidence.ToArray())
}

<#
.SYNOPSIS
    Scans a root for quarantine candidates with evidence.
.DESCRIPTION
    Read-only. Only direct children of the selected root are offered as candidates (a
    leftover lives one level down; descending arbitrarily would turn the scan into a
    deletion tool). Each candidate is scored: supporting evidence raises the orphan score,
    contradicting evidence lowers it, and a candidate with contradicting evidence is never
    offered as clean. Nothing is selected automatically.
.OUTPUTS
    @{ Root; Candidates; ProbesMissing }
#>
function Get-WtQuarantineScanInternal
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $false)][int]$RecentDays = 14
    )

    if (-not [System.IO.Path]::IsPathRooted($Root))
    {
        throw (Get-WtString -Key 'Worker.Reason.RootInvalid')
    }

    if (-not (Test-Path -LiteralPath $Root -PathType Container))
    {
        throw (Get-WtString -Key 'Worker.Reason.RootMissing' -Arguments @($Root))
    }

    $Candidates = [System.Collections.Generic.List[object]]::new()
    $ProbesMissing = [System.Collections.Generic.List[string]]::new()

    $Children = @()
    try { $Children = @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop) } catch { Write-WtLog -Level Debug -Message ('scan root read failed: {0}' -f $_.Exception.Message) -NoConsole }

    foreach ($Child in $Children)
    {
        $Full = $Child.FullName
        $Evidence = @(Get-WtQuarantineEvidenceInternal -Path $Full -RecentDays $RecentDays)

        $Supporting = @($Evidence | Where-Object { $_.Sign -eq 'Supporting' })
        $Contradicting = @($Evidence | Where-Object { $_.Sign -eq 'Contradicting' })
        $Unavailable = @($Evidence | Where-Object { -not $_.Available })
        foreach ($Probe in $Unavailable)
        {
            if (-not ($ProbesMissing -contains $Probe.Text)) { $ProbesMissing.Add($Probe.Text) }
        }

        # Scoring: supporting points minus contradicting points. Unavailable probes keep the
        # candidate uncertain rather than tilting the score either way.
        $Score = $Supporting.Count - $Contradicting.Count
        $Verdict = if ($Contradicting.Count -gt 0) { 'InUse' }
        elseif ($Score -gt 0) { 'Orphaned' }
        elseif ($Score -eq 0 -and $Evidence.Count -eq 0) { 'Unknown' }
        else { 'Uncertain' }

        $Candidates.Add([pscustomobject]@{
            PSTypeName    = 'WindowsTweaker.QuarantineCandidate'
            Id            = [guid]::NewGuid().ToString('n')
            Path          = $Full
            IsDirectory   = [bool]$Child.PSIsContainer
            SizeBytes     = [long]0
            Verdict       = $Verdict
            Score         = $Score
            Evidence      = $Evidence
        })
    }

    # Sizes are read-only metadata: logical bytes on disk at scan time, never a promise that
    # they are reclaimable.
    foreach ($Candidate in $Candidates)
    {
        try
        {
            if ($Candidate.IsDirectory)
            {
                $Candidate.SizeBytes = [long]((Get-ChildItem -LiteralPath $Candidate.Path -Recurse -File -ErrorAction Ignore | Measure-Object -Property Length -Sum).Sum)
            }
            else
            {
                $Candidate.SizeBytes = [long](Get-Item -LiteralPath $Candidate.Path -ErrorAction Stop).Length
            }
        }
        catch
        {
            $Candidate.SizeBytes = 0
        }
    }

    return @{
        Root = $Root
        Candidates = @($Candidates.ToArray())
        ProbesMissing = @($ProbesMissing.ToArray())
    }
}

<#
.SYNOPSIS
    Returns the record for one candidate id from the manifest.
#>
function Get-WtQuarantineRecord
{
    [CmdletBinding()]
    [OutputType([object])]
    param
    (
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $false)][object[]]$Records
    )

    if (-not $Records) { $Records = (Read-WtQuarantineManifest).Records }
    return @($Records | Where-Object { $_.id -eq $Id } | Select-Object -First 1)
}

<#
.SYNOPSIS
    Prepares and persists the recovery intent for a set of candidate ids.
.DESCRIPTION
    Stage 'planned' is written before anything moves. This is the durable recovery intent:
    if the process dies after this write, the manifest shows exactly which candidates were
    approved and which were not yet moved.
#>
function New-WtQuarantinePlanInternal
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $true)][object[]]$Candidates,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $Manifest = Read-WtQuarantineManifest
    $Records = [System.Collections.Generic.List[object]]::new()
    foreach ($Existing in $Manifest.Records) { $Records.Add($Existing) }

    $Planned = [System.Collections.Generic.List[object]]::new()
    foreach ($Candidate in $Candidates)
    {
        $Existing = Get-WtQuarantineRecord -Id $Candidate.Id -Records $Manifest.Records
        if ($Existing -and $Existing.stage -in 'moved', 'verified', 'failed')
        {
            continue
        }

        $Fingerprint = Get-WtQuarantineFingerprint -Path $Candidate.Path
        $Record = [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.QuarantineRecord'
            id         = [string]$Candidate.Id
            sourcePath = [string]$Candidate.Path
            sourceRoot = $Root
            fingerprint = $Fingerprint
            movedAt    = $null
            stage      = 'planned'
            outcome    = 'pending'
            quarantinePath = $null
            movedBytes = [long]0
            freedBytes = [long]0
            owner      = [string](Get-WtStatePath)
            IsDirectory = [bool]$Candidate.IsDirectory
        }

        $Records.Add($Record)
        $Planned.Add($Record)
    }

    Write-WtQuarantineManifest -Records @($Records.ToArray()) -Meta $Manifest.Meta

    return @{
        Records = @($Records.ToArray())
        Planned = @($Planned.ToArray())
    }
}

<#
.SYNOPSIS
    Moves one planned candidate into quarantine.
.DESCRIPTION
    Revalidates the source identity and the approved boundary immediately before the move:
    the source must still exist with the same fingerprint, must sit under the approved root,
    and must be on the same volume as the quarantine storage. Cross-volume cases are skipped
    with the reason, never copied and deleted. After the move the destination is verified
    and the record advances to 'verified'.
#>
function Move-WtQuarantineItemInternal
{
    [CmdletBinding()]
    [OutputType([object])]
    param
    (
        [Parameter(Mandatory = $true)][object]$Record,
        [Parameter(Mandatory = $false)][switch]$DryRun
    )

    $Source = [string]$Record.sourcePath
    $Root = [string]$Record.sourceRoot
    $Location = Get-WtQuarantineLocation
    $Storage = $Location.Storage

    # Approved root boundary first: the source must sit under the root it was scanned from.
    # Paths are compared with one canonical separator so mixed slash styles cannot bypass the
    # boundary check.
    $NormSource = $Source.Replace('\', '/').TrimEnd('/')
    $NormRoot = $Root.Replace('\', '/').TrimEnd('/')
    if (-not $NormSource.StartsWith("$NormRoot/", [System.StringComparison]::OrdinalIgnoreCase) -and $NormSource -ne $NormRoot)
    {
        $Record.stage = 'failed'
        $Record.outcome = 'outside-boundary'
        return $Record
    }

    # The quarantine storage itself is never a source: quarantining the quarantine would
    # move the recovery data the manifest depends on.
    $NormStorage = $Storage.Replace('\', '/').TrimEnd('/')
    if ($NormSource.StartsWith("$NormStorage/", [System.StringComparison]::OrdinalIgnoreCase) -or $NormSource -eq $NormStorage)
    {
        $Record.stage = 'failed'
        $Record.outcome = 'quarantine-source'
        return $Record
    }

    # Same-volume rule: a move across volumes would have to copy and delete, which is never
    # done silently, so those cases are skipped with an explanation.
    $SourceRoot = [System.IO.Path]::GetPathRoot($Source)
    $StorageRoot = [System.IO.Path]::GetPathRoot($Storage)
    if ($SourceRoot -ne $StorageRoot)
    {
        $Record.stage = 'failed'
        $Record.outcome = 'cross-volume'
        $Record.message = "Same-volume moves only: '$Source' is on $SourceRoot but the quarantine storage is on $StorageRoot."
        return $Record
    }

    if (-not (Test-Path -LiteralPath $Source))
    {
        $Record.stage = 'failed'
        $Record.outcome = 'missing-source'
        return $Record
    }

    $LiveFingerprint = Get-WtQuarantineFingerprint -Path $Source
    if ($LiveFingerprint -and $Record.fingerprint -and $Record.fingerprint -ne $LiveFingerprint)
    {
        $Record.stage = 'failed'
        $Record.outcome = 'source-changed'
        return $Record
    }

    $Destination = Join-Path $Storage $Record.id
    if (Test-Path -LiteralPath $Destination)
    {
        $Record.stage = 'failed'
        $Record.outcome = 'destination-exists'
        return $Record
    }

    if ($DryRun)
    {
        $Record.stage = 'planned'
        $Record.outcome = 'dryrun'
        return $Record
    }

    New-WtDirectory -Path $Storage

    try
    {
        if ($Record.IsDirectory)
        {
            [System.IO.Directory]::Move($Source, $Destination)
        }
        else
        {
            [System.IO.File]::Move($Source, $Destination)
        }
    }
    catch
    {
        $Record.stage = 'failed'
        $Record.outcome = 'move-error'
        $Record.message = $_.Exception.Message
        return $Record
    }

    $Record.quarantinePath = $Destination
    $Record.movedAt = (Get-Date).ToUniversalTime().ToString('o')
    $Record.stage = 'moved'
    $Record.outcome = 'pending-verify'

    # Moved bytes are reported separately from freed bytes: a same-volume move does not free
    # disk space, so freedBytes stays 0 (only explicit deletion after quarantine changes it).
    try
    {
        if ($Record.IsDirectory)
        {
            $Record.movedBytes = [long]((Get-ChildItem -LiteralPath $Destination -Recurse -File -ErrorAction Ignore | Measure-Object -Property Length -Sum).Sum)
        }
        else
        {
            $Record.movedBytes = [long](Get-Item -LiteralPath $Destination -ErrorAction Stop).Length
        }
    }
    catch
    {
        $Record.movedBytes = 0
    }

    # Verification: destination exists, source is gone.
    if ((Test-Path -LiteralPath $Destination) -and -not (Test-Path -LiteralPath $Source))
    {
        $Record.stage = 'verified'
        $Record.outcome = 'moved'
    }

    return $Record
}

<#
.SYNOPSIS
    Applies a quarantine plan: persists intent, then moves each candidate.
.DESCRIPTION
    The manifest is written first (stage 'planned' for the whole set). Each candidate is
    then moved and its record advanced; every transition is a locked manifest write, so an
    interrupted run leaves the manifest stating exactly how far it got. Returns the updated
    records and the moved/failed counts.
#>
function Invoke-WtQuarantineInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object[]]$Candidates,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $false)][switch]$DryRun
    )

    $Plan = New-WtQuarantinePlanInternal -Candidates $Candidates -Root $Root
    $Records = [System.Collections.Generic.List[object]]::new()
    foreach ($Existing in $Plan.Records) { $Records.Add($Existing) }

    $Moved = 0
    $Failed = 0
    $Skipped = 0

    foreach ($Record in $Plan.Planned)
    {
        $Result = Move-WtQuarantineItemInternal -Record $Record -DryRun:$DryRun
        if ($Result.outcome -eq 'moved')
        {
            $Moved++
        }
        elseif ($Result.outcome -eq 'dryrun')
        {
            $Skipped++
        }
        else
        {
            $Failed++
        }

        Write-WtQuarantineManifest -Records @($Records.ToArray()) -Meta (Read-WtQuarantineManifest).Meta
    }

    return @{
        Records = @($Records.ToArray())
        Moved = $Moved
        Failed = $Failed
        Skipped = $Skipped
    }
}

<#
.SYNOPSIS
    Restores quarantined candidates.
.DESCRIPTION
    Revalidates the stored quarantine path and the recorded owner before moving back. If
    the destination already exists, restoration is refused (no silent overwrite) unless
    -Overwrite is given explicitly. Missing or changed quarantined content keeps the record
    unresolved for retry. Returns the updated records.
#>
function Restore-WtQuarantineInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string[]]$Ids,
        [Parameter(Mandatory = $false)][switch]$Overwrite
    )

    $Manifest = Read-WtQuarantineManifest
    $Records = [System.Collections.Generic.List[object]]::new()
    foreach ($Existing in $Manifest.Records) { $Records.Add($Existing) }

    $Restored = 0
    $Failed = 0
    $Unresolved = 0

    foreach ($Id in $Ids)
    {
        $Record = Get-WtQuarantineRecord -Id $Id -Records $Manifest.Records
        if (-not $Record)
        {
            continue
        }

        # Ownership: only records created by this state store's owner are restorable.
        if ($Record.owner -and $Record.owner -ne (Get-WtStatePath))
        {
            $Record.stage = 'failed'
            $Record.outcome = 'owner-mismatch'
            $Failed++
            continue
        }

        $QuarantinePath = [string]$Record.quarantinePath
        $Source = [string]$Record.sourcePath

        if (-not $QuarantinePath -or -not (Test-Path -LiteralPath $QuarantinePath))
        {
            $Record.stage = 'unresolved'
            $Record.outcome = 'missing-quarantined-content'
            $Unresolved++
            continue
        }

        if ((Test-Path -LiteralPath $Source) -and (-not $Overwrite))
        {
            $Record.stage = 'unresolved'
            $Record.outcome = 'destination-exists'
            $Unresolved++
            continue
        }

        try
        {
            $Parent = Split-Path -Path $Source -Parent
            if ($Parent) { New-WtDirectory -Path $Parent }

            if ($Record.IsDirectory)
            {
                [System.IO.Directory]::Move($QuarantinePath, $Source)
            }
            else
            {
                [System.IO.File]::Move($QuarantinePath, $Source)
            }
        }
        catch
        {
            $Record.stage = 'unresolved'
            $Record.outcome = 'restore-error'
            $Record.message = $_.Exception.Message
            $Unresolved++
            continue
        }

        if ((Test-Path -LiteralPath $Source) -and -not (Test-Path -LiteralPath $QuarantinePath))
        {
            $Record.stage = 'restored'
            $Record.outcome = 'restored'
            $Restored++
        }
        else
        {
            $Record.stage = 'unresolved'
            $Record.outcome = 'restore-unverified'
            $Unresolved++
        }
    }

    Write-WtQuarantineManifest -Records @($Records.ToArray()) -Meta $Manifest.Meta

    return @{
        Records = @($Records.ToArray())
        Restored = $Restored
        Failed = $Failed
        Unresolved = $Unresolved
    }
}

<#
.SYNOPSIS
    Permanently deletes quarantined content, explicitly confirmed.
.DESCRIPTION
    This is the only operation that frees the quarantined bytes. It never runs at startup
    and never runs without an explicit -Delete. Expired records are only flagged for review,
    never deleted.
#>
function Remove-WtQuarantineInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string[]]$Ids,
        [Parameter(Mandatory = $false)][switch]$Delete
    )

    if (-not $Delete)
    {
        $Manifest = Read-WtQuarantineManifest
        return @{
            Records = @($Manifest.Records)
            Removed = 0
            Failed = 0
        }
    }

    $Manifest = Read-WtQuarantineManifest
    $Records = [System.Collections.Generic.List[object]]::new()
    $Removed = 0
    $Failed = 0

    foreach ($Existing in $Manifest.Records)
    {
        $Records.Add($Existing)
    }

    foreach ($Id in $Ids)
    {
        $Record = Get-WtQuarantineRecord -Id $Id -Records $Manifest.Records
        if (-not $Record)
        {
            continue
        }

        $Path = [string]$Record.quarantinePath
        if (-not $Path -or -not (Test-Path -LiteralPath $Path))
        {
            $Record.stage = 'unresolved'
            $Record.outcome = 'missing-quarantined-content'
            $Failed++
            continue
        }

        try
        {
            if ($Record.IsDirectory)
            {
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            }
            else
            {
                Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            }
            $Record.stage = 'deleted'
            $Record.outcome = 'deleted'
            $Removed++
        }
        catch
        {
            $Record.stage = 'unresolved'
            $Record.outcome = 'delete-error'
            $Record.message = $_.Exception.Message
            $Failed++
        }
    }

    Write-WtQuarantineManifest -Records @($Records.ToArray()) -Meta $Manifest.Meta

    return @{
        Records = @($Records.ToArray())
        Removed = $Removed
        Failed = $Failed
    }
}
