# WindowsTweaker - state store.
#
# Purpose: record the *actual* previous state before a change, then restore exactly
# that state on rollback. Rollback is never "write a hard-coded default".
#
# Layout of the JSON store:
#   version : schema version
#   history : newest-last list of change entries, each with the captured records
#
# Each record describes one captured resource, e.g.
#   Registry  : key existence, value existence, value kind and value data
#   Service   : start type and running state
#   Scheduled : task existence and enabled state
#   Dns       : per-adapter interface index/guid and the exact server address list
#   Appx      : package identity (marked irreversible: nothing to restore)

$Script:WtStateSchemaVersion = 2
$Script:WtStateLockTimeoutMs = 5000
$Script:WtStateLockStaleSeconds = 60
$Script:WtSettingsSchemaVersion = 1

<#
.SYNOPSIS
    Reads only the schema version of the settings file on disk.
.DESCRIPTION
    Used by the write path, which must know what it is about to overwrite: a settings file written
    by a newer schema holds fields this build would drop. A missing, empty or unparseable file
    reports 0, which is never newer than a supported schema - a file that cannot be parsed carries
    nothing this build could have preserved anyway, and replacing it is the behaviour the read
    path has always had for a corrupt settings file (it is reported and ignored, never deleted).
.OUTPUTS
    [int] the schema version the file declares, or 0.
#>
function Get-WtSettingsFileVersionInternal
{
    [CmdletBinding()]
    [OutputType([int])]
    param ([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path))
    {
        return 0
    }

    try
    {
        $Raw = Read-WtTextFile -Path $Path
        if ([string]::IsNullOrWhiteSpace($Raw))
        {
            return 0
        }

        $Parsed = ConvertFrom-WtJson -Text $Raw -Depth 8
        if (@($Parsed.PSObject.Properties.Name) -contains 'version')
        {
            return [int]$Parsed.version
        }
    }
    catch
    {
        return 0
    }

    # No version field: the first schema, which is what the read path assumes too.
    return 1
}

<#
.SYNOPSIS
    Reads the user settings file (interface preferences).
.DESCRIPTION
    A missing, empty or unreadable file yields the defaults: a presentation preference
    must never stop the interface from starting. A corrupt file is reported in the log
    and ignored rather than deleted, so nothing the user wrote is destroyed silently.
    The schema version is validated instead of being carried around: a file written in this
    schema, or in an older one whose field names have not changed, is read (and reported as
    Migrated), while a file written in a NEWER schema is not read at all - the interface still
    starts, on the defaults, and Refused says that nothing was taken from the file.
#>
function Read-WtSettings
{
    [CmdletBinding()]
    param ()

    $Settings = [ordered]@{
        PSTypeName  = 'WindowsTweaker.Settings'
        Path        = Get-WtSettingsPath
        Version     = $Script:WtSettingsSchemaVersion
        FileVersion = $Script:WtSettingsSchemaVersion
        Migrated    = $false
        Refused     = $false
        Icons       = 'Auto'
        Language    = ''
        Backend     = 'Auto'
        Profile     = 'Auto'
    }

    if (-not (Test-Path -LiteralPath $Settings.Path))
    {
        return $Settings
    }

    try
    {
        $Raw = Read-WtTextFile -Path $Settings.Path
        if ([string]::IsNullOrWhiteSpace($Raw))
        {
            return $Settings
        }

        $Parsed = ConvertFrom-WtJson -Text $Raw -Depth 8
        $Names = @($Parsed.PSObject.Properties.Name)

        # A file without a version field is the first schema, exactly as Read-WtStateStore reads one.
        $FileVersion = if ($Names -contains 'version') { [int]$Parsed.version } else { 1 }
        $Settings.FileVersion = $FileVersion

        if ($FileVersion -gt $Script:WtSettingsSchemaVersion)
        {
            # Not read and not migrated: this build cannot tell which of the newer fields matter,
            # and the next write would drop them.
            $Settings.Refused = $true
            Write-WtLog -Level Error -Message "The settings file was written by a newer version of WindowsTweaker (schema $FileVersion; this build supports $($Script:WtSettingsSchemaVersion)) and was not read: $($Settings.Path). It is left untouched for that version to read." -NoConsole
            return $Settings
        }

        if ($FileVersion -lt $Script:WtSettingsSchemaVersion)
        {
            # A known older schema: every field this build knows has kept its name, so the file is
            # read as it is and the next write persists the current version.
            $Settings.Migrated = $true
        }

        if ($Names -contains 'icons' -and $Parsed.icons) { $Settings.Icons = [string]$Parsed.icons }
        if ($Names -contains 'language' -and $Parsed.language) { $Settings.Language = [string]$Parsed.language }
        if ($Names -contains 'backend' -and $Parsed.backend) { $Settings.Backend = [string]$Parsed.backend }
        if ($Names -contains 'profile' -and $Parsed.profile) { $Settings.Profile = [string]$Parsed.profile }
    }
    catch
    {
        Write-WtLog -Level Warning -Message "The settings file could not be read and was ignored: $($Settings.Path)" -Exception $_.Exception -NoConsole
    }

    return $Settings
}

<#
.SYNOPSIS
    Writes the user settings file in one atomic swap.
.DESCRIPTION
    Refuses to write over a file this build could not have written: a newer settings file holds
    fields this schema does not know, and writing the current schema over it would drop them
    silently. Deleting that file explicitly is the only way past this, the same rule the state
    store follows.
#>
function Write-WtSettings
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Settings)

    $Path = Get-WtSettingsPath

    # Asked of the file on disk, not of the Settings object: the caller may have read it before
    # another process (or another build) replaced it.
    $ExistingVersion = Get-WtSettingsFileVersionInternal -Path $Path
    if ($ExistingVersion -gt $Script:WtSettingsSchemaVersion)
    {
        throw "The settings file was written by a newer version of WindowsTweaker (schema $ExistingVersion; this build supports $($Script:WtSettingsSchemaVersion)): $Path. Nothing was written; remove the file explicitly to start over."
    }

    $Payload = [ordered]@{
        version  = $Script:WtSettingsSchemaVersion
        icons    = [string]$Settings.Icons
        language = [string]$Settings.Language
        backend  = [string]$Settings.Backend
        profile  = [string]$Settings.Profile
    }

    $Json = ConvertTo-WtJson -InputObject $Payload -Depth 8

    # The same one-swap persistence the state store uses. A presentation file is not recovery
    # data, but a half-written one is still a file the next run cannot read, and Move-Item -Force
    # deletes the destination before it moves.
    Write-WtAtomicFile -Path $Path -Value ($Json + [System.Environment]::NewLine) | Out-Null
}

<#
.SYNOPSIS
    Reads the state store.
.DESCRIPTION
    A missing store yields an empty store. A corrupt store is reported
    (Corrupt = $true) instead of being overwritten, so captured rollback data is
    never silently destroyed. A store written by a NEWER schema is refused the same
    way (Corrupt and NewerSchema = $true, with the reason in Error): its records
    cannot be interpreted here, and reading it as current would downgrade it on the
    next write.
#>
function Read-WtStateStore
{
    [CmdletBinding()]
    param ()

    $Result = [ordered]@{
        PSTypeName = 'WindowsTweaker.StateStore'
        Path       = Get-WtStatePath
        Version    = $Script:WtStateSchemaVersion
        FileVersion = $Script:WtStateSchemaVersion
        History    = @()
        Sessions   = @()
        Quarantine = @()
        QuarantineMeta = $null
        Corrupt    = $false
        NewerSchema = $false
        Migrated   = $false
        Error      = $null
    }

    if (-not (Test-Path -LiteralPath $Result.Path))
    {
        return $Result
    }

    try
    {
        $Raw = Read-WtTextFile -Path $Result.Path
        if ([string]::IsNullOrWhiteSpace($Raw))
        {
            # An empty file is not a valid store: it means a write was interrupted before a
            # single byte of JSON was flushed. Treat it as an error instead of as "no history",
            # otherwise the next write would silently discard whatever was there.
            $Result.Corrupt = $true
            $Result.Error = 'The state store is empty.'
            Write-WtLog -Level Error -Message (Get-WtString -Key 'Error.StateStoreCorrupt' -Arguments @($Result.Path)) -NoConsole
            return $Result
        }

        $Parsed = ConvertFrom-WtJson -Text $Raw -Depth 32
        $Names = @($Parsed.PSObject.Properties.Name)

        $FileVersion = if ($Names -contains 'version') { [int]$Parsed.version } else { 1 }
        $Result.FileVersion = $FileVersion
        $Result.Version = $Script:WtStateSchemaVersion

        if ($FileVersion -gt $Script:WtStateSchemaVersion)
        {
            # A store written by a newer build says so in its own version field, and holds records
            # this build cannot interpret. Reading it as if it were current and then writing the
            # current schema back would silently downgrade it and destroy them, so it is refused
            # for both: Corrupt makes every caller treat it as unusable, and Write-WtStateStore
            # refuses to replace it as well.
            $Result.Corrupt = $true
            $Result.NewerSchema = $true
            $Result.Error = "The state store was written by a newer version of WindowsTweaker (schema $FileVersion; this build supports $($Script:WtStateSchemaVersion)). It was not read and it will not be overwritten: update WindowsTweaker, or remove $($Result.Path) explicitly."
            Write-WtLog -Level Error -Message $Result.Error -NoConsole
            return $Result
        }

        $Entries = @()
        if ($Names -contains 'journal' -and $Parsed.journal) { $Entries = @($Parsed.journal) }
        elseif ($Names -contains 'history' -and $Parsed.history) { $Entries = @($Parsed.history) }

        if ($Names -contains 'sessions' -and $Parsed.sessions) { $Result.Sessions = @($Parsed.sessions) }
        if ($Names -contains 'quarantine' -and $Parsed.quarantine) { $Result.Quarantine = @($Parsed.quarantine) }
        if ($Names -contains 'quarantineMeta' -and $Parsed.quarantineMeta) { $Result.QuarantineMeta = $Parsed.quarantineMeta }

        if ($FileVersion -lt $Script:WtStateSchemaVersion)
        {
            # Older schema: migrate in memory (and report it). The next write persists v2, so a
            # read never rewrites the file behind the caller's back.
            $Result.History = @($Entries | ForEach-Object { ConvertTo-WtJournalEntry -LegacyEntry $_ })
            $Result.Migrated = $true
        }
        else
        {
            $Result.History = @($Entries | ForEach-Object { ConvertTo-WtJournalEntry -Entry $_ })
        }
    }
    catch
    {
        $Result.Corrupt = $true
        $Result.Error = $_.Exception.Message
        Write-WtLog -Level Error -Message (Get-WtString -Key 'Error.StateStoreCorrupt' -Arguments @($Result.Path)) -Exception $_.Exception
    }

    return $Result
}

<#
.SYNOPSIS
    Acquires the cross-process store lock.
.DESCRIPTION
    The journal is read-modify-write: two PowerShell processes applying a tweak at the same
    time would otherwise lose one of the two writes. The lock is a sibling file created with
    CreateNew (atomic on Windows and POSIX); a lock older than the stale threshold is broken
    with a warning, so a crashed process cannot block the store forever.
.OUTPUTS
    A token hashtable to pass to Exit-WtStateLock.
#>
function Enter-WtStateLock
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][int]$TimeoutMs = 0
    )

    if ($TimeoutMs -le 0) { $TimeoutMs = $Script:WtStateLockTimeoutMs }

    $LockPath = "$Path.lock"
    $Directory = Split-Path -Path $LockPath -Parent
    if ($Directory) { New-WtDirectory -Path $Directory }

    $Deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)
    $Token = @{ Path = $LockPath; Acquired = $false }

    while ($true)
    {
        try
        {
            $Stream = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $Payload = [System.Text.Encoding]::UTF8.GetBytes("pid=$PID;utc=$([datetime]::UtcNow.ToString('o'))")
            $Stream.Write($Payload, 0, $Payload.Length)
            $Stream.Flush()
            $Stream.Dispose()
            $Token.Acquired = $true
            return $Token
        }
        catch [System.IO.IOException]
        {
            $Stale = $false
            try
            {
                $Info = Get-Item -LiteralPath $LockPath -ErrorAction Stop
                $Stale = ((Get-Date).ToUniversalTime() - $Info.LastWriteTimeUtc).TotalSeconds -gt $Script:WtStateLockStaleSeconds
            }
            catch
            {
                $Stale = $true
            }

            if ($Stale)
            {
                Write-WtLog -Level Warning -Message "Removing a stale state-store lock: $LockPath" -NoConsole
                Remove-Item -LiteralPath $LockPath -Force -ErrorAction Ignore
                continue
            }

            if ([datetime]::UtcNow -ge $Deadline)
            {
                throw "The state store is locked by another process ($LockPath). Nothing was written."
            }

            Start-Sleep -Milliseconds 50
        }
    }
}

<#
.SYNOPSIS
    Releases the store lock.
#>
function Exit-WtStateLock
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][object]$Token)

    if ($Token -and $Token.Acquired -and $Token.Path)
    {
        Remove-Item -LiteralPath $Token.Path -Force -ErrorAction Ignore
    }
}

<#
.SYNOPSIS
    Writes the state store in one atomic swap.
.DESCRIPTION
    The full document is written to a sibling temporary file, flushed to the device and swapped
    in with one call (System.IO.File.Replace on an existing store, File.Move for the first one),
    so an interrupted write leaves either the previous store or the new one. A runtime that
    cannot do that refuses the write instead of degrading to a plain overwrite.

    Refuses to write a store whose FileVersion is newer than this build's schema, with or without
    -Force: -Force repairs a store that could not be parsed, while a newer one is well-formed and
    holds records this build cannot interpret.
#>
function Write-WtStateStore
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Store,
        [Parameter(Mandatory = $false)][switch]$Force,
        [Parameter(Mandatory = $false)][switch]$NoLock
    )

    $Path = $Store.Path

    if ([int]$Store.FileVersion -gt $Script:WtStateSchemaVersion)
    {
        # A store read from a newer schema is never replaced, not even by -Force: -Force repairs a
        # store that could not be parsed, while this one is well-formed and simply newer, so
        # writing the current schema over it would destroy records a newer build still needs.
        # FileVersion is what Read-WtStateStore found on disk, so any store that came from a read
        # carries the answer with it.
        throw "The state store was written by a newer version of WindowsTweaker (schema $([int]$Store.FileVersion); this build supports $($Script:WtStateSchemaVersion)): $Path. Refusing to overwrite it; update WindowsTweaker, or remove the file explicitly."
    }

    if (-not $Force -and $Store.Corrupt)
    {
        # A store we could not parse is an error, not an empty store: overwriting it would
        # destroy recovery data. An explicit repair path (-Force) is the only way past this.
        throw "The state store could not be read ($($Store.Error)). Refusing to overwrite it; repair it or remove it explicitly."
    }

    $Directory = Split-Path -Path $Path -Parent
    if ($Directory)
    {
        New-WtDirectory -Path $Directory
    }

    $Payload = [ordered]@{
        version  = $Script:WtStateSchemaVersion
        sessions = @($Store.Sessions)
        journal  = @($Store.History)
    }

    # The quarantine manifest lives in the same store so it inherits the same durability and
    # locking rules; it is only written when the quarantine module set it.
    $Payload.quarantine = @($Store.Quarantine)
    if ($Store.QuarantineMeta)
    {
        $Payload.quarantineMeta = $Store.QuarantineMeta
    }

    $Json = ConvertTo-WtJson -InputObject $Payload -Depth 32

    $Token = $null
    if (-not $NoLock) { $Token = Enter-WtStateLock -Path $Path }

    try
    {
        # Write the complete document, flush it to the device, then swap it in with one call:
        # an interrupted write leaves either the old store or the new one, never a half-written
        # journal, and the runtime keeps the old file until the swap has succeeded.
        Write-WtAtomicFile -Path $Path -Value $Json | Out-Null
    }
    finally
    {
        Exit-WtStateLock -Token $Token
    }
}

<#
.SYNOPSIS
    Starts a new history entry for an apply operation.
#>
function New-WtHistoryEntry
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$TweakId,
        [Parameter(Mandatory = $false)][string]$State,
        [Parameter(Mandatory = $false)][hashtable]$Arguments,
        [Parameter(Mandatory = $false)][switch]$DryRun,
        [Parameter(Mandatory = $false)][ValidateSet('manual', 'preset', 'recovery', 'reapply', 'legacy')][string]$Origin = 'manual',
        [Parameter(Mandatory = $false)][string]$SessionId = '',
        [Parameter(Mandatory = $false)][string]$ParentOperationId = '',
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$Targets = @()
    )

    $OperationId = [guid]::NewGuid().ToString('n')
    $Context = Get-WtJournalContext
    $Now = (Get-Date).ToUniversalTime().ToString('o')

    return [pscustomobject]@{
        PSTypeName       = 'WindowsTweaker.JournalEntry'
        # Journal identity (schema 2). historyId mirrors operationId so existing callers,
        # stored files and tests keep working unchanged.
        operationId      = $OperationId
        historyId        = $OperationId
        parentOperationId = $(if ($ParentOperationId) { $ParentOperationId } else { $null })
        sessionId        = $(if ($SessionId) { $SessionId } else { Get-WtSessionId -Start })
        sequence         = 0
        origin           = $Origin
        stage            = 'planned'
        appVersion       = [string]$Context.appVersion
        platform         = $Context.platform
        tweakId          = $TweakId
        state            = $State
        arguments        = if ($Arguments) { $Arguments } else { @{} }
        timestamp        = $Now
        updatedUtc       = $Now
        dryRun           = [bool]$DryRun
        targets          = @($Targets)
        outcome          = 'pending'
        records          = @()
        rolledBack       = $false
        rolledBackAt     = $null
        verification     = $null
        compensation     = $null
        messages         = @()
    }
}

<#
.SYNOPSIS
    Adds a captured pre-change record to the active history entry.
#>
function Add-WtStateRecord
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$HistoryEntry,
        [Parameter(Mandatory = $true)][hashtable]$Record
    )

    if ($null -eq $HistoryEntry)
    {
        return
    }

    $HistoryEntry.records = @($HistoryEntry.records) + @([pscustomobject]$Record)
}

<#
.SYNOPSIS
    Returns history entries, newest first.
#>
function Get-WtHistoryEntry
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][string]$TweakId,
        [Parameter(Mandatory = $false)][int]$Limit = 50,
        [Parameter(Mandatory = $false)][switch]$IncludeDryRun
    )

    $Store = Read-WtStateStore
    $History = @($Store.History)

    if ($TweakId)
    {
        $History = @($History | Where-Object { $_.tweakId -eq $TweakId })
    }

    if (-not $IncludeDryRun)
    {
        $History = @($History | Where-Object { -not $_.dryRun })
    }

    return @($History | Sort-Object -Property timestamp -Descending | Select-Object -First $Limit)
}

<#
.SYNOPSIS
    Finds the newest entry that can still be rolled back for a tweak.
#>
function Get-WtRollbackCandidate
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][string]$TweakId,
        [Parameter(Mandatory = $false)][string]$HistoryId
    )

    $Entries = if ($HistoryId)
    {
        @(Get-WtHistoryEntry -Limit 500 -IncludeDryRun | Where-Object { $_.historyId -eq $HistoryId })
    }
    else
    {
        $Entries = @(Get-WtHistoryEntry -TweakId $TweakId -Limit 500)

        # Journal entries keep the id they were created with. When that id has since been
        # renamed, the entry is still found - by resolving history ids for the lookup only,
        # never by rewriting the entry.
        if ($Entries.Count -eq 0 -and $TweakId)
        {
            $Historical = @(Get-WtTweakHistoryIdsInternal -Id $TweakId | Where-Object { $_ -ne $TweakId })
            if ($Historical.Count -gt 0)
            {
                $Entries = @(Get-WtHistoryEntry -Limit 500 | Where-Object { $Historical -contains [string]$_.tweakId })
            }
        }

        return @($Entries |
            Where-Object { Test-WtJournalRestorable -Entry $_ } |
            Select-Object -First 1)
    }

    return @($Entries |
        Where-Object { Test-WtJournalRestorable -Entry $_ } |
        Select-Object -First 1)
}

<#
.SYNOPSIS
    Marks a history entry as rolled back.
#>
function Set-WtHistoryRolledBack
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$HistoryId)

    $Store = Read-WtStateStore
    if ($Store.Corrupt)
    {
        return $false
    }

    $Found = $false
    foreach ($Entry in $Store.History)
    {
        if ($Entry.historyId -eq $HistoryId)
        {
            $Entry.rolledBack = $true
            $Entry.rolledBackAt = (Get-Date).ToUniversalTime().ToString('o')
            $Found = $true
        }
    }

    if ($Found)
    {
        Write-WtStateStore -Store $Store
    }

    return $Found
}

<#
.SYNOPSIS
    Records an out-of-band note (e.g. "restore point created") on the active entry.
#>
function Add-WtHistoryMessage
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$HistoryEntry,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($HistoryEntry)
    {
        $HistoryEntry.messages = @($HistoryEntry.messages) + @($Message)
    }
}
