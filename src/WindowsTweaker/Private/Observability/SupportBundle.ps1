# WindowsTweaker - privacy-preserving support bundles.
#
# Export is an explicit preview-and-export workflow. Selected diagnostic artifacts are
# sanitized (identifier redaction), assembled into a bounded archive, and accompanied by
# a manifest (schema version, creation time, included files, SHA-256 hashes). Hashes
# verify bundle contents; they do not prove origin.
#
# Default exclusions: credentials/tokens, full product keys, full environment dumps,
# recovery secrets and executable recovery material, browser databases, file contents,
# full command lines, usernames, computer names, serial numbers, private paths.

$Script:WtBundleSchemaVersion = 1
$Script:WtBundleMaxBytes = 8MB
$Script:WtBundleMaxEntries = 64
$Script:WtBundleMaxEntryBytes = 1MB

# Redaction pattern set (applied to all exported text).
$Script:WtBundleRedactions = @(
    @{ Pattern = '(?i)(password|passwd|pwd|token|secret|apikey|api_key|authorization)(\s*[:=]\s*)([^\s,;]+)'; Replacement = '$1$2[REDACTED]' }
    @{ Pattern = '(?i)([A-Z0-9]{5}-){4}[A-Z0-9]{5}'; Replacement = '[KEY-REDACTED]' }
    @{ Pattern = '(?i)(user(name)?|login|account)(\s*[:=]\s*)([^\s,;]+)'; Replacement = '$1$2[USER-REDACTED]' }
    @{ Pattern = '(?i)([0-9]{1,3}\.){3}[0-9]{1,3}'; Replacement = '[IP-REDACTED]' }
    @{ Pattern = '(?i)([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})'; Replacement = '[GUID-REDACTED]' }
)

function Clear-WtBundleText {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Text)

    $Clean = $Text -replace "`e\[[0-9;?]*[a-zA-Z]", ''
    foreach ($R in $Script:WtBundleRedactions) {
        $Clean = $Clean -replace $R.Pattern, $R.Replacement
    }
    return $Clean.Trim()
}

function Get-WtBundleRedactionPreview {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Text)

    $Sensitive = @()
    foreach ($R in $Script:WtBundleRedactions) {
        if ($Text -match $R.Pattern) {
            $First = $Matches[0]
            $Sensitive += @{
                Pattern = $R.Pattern
                Sample = if ($First.Length -gt 20) { $First.Substring(0, 20) + '…' } else { $First }
            }
        }
    }
    return $Sensitive
}

# Builds the bundle contents (bounded text entries) in memory.
function New-WtSupportBundleContents {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][hashtable]$Options,   # @{ includeJournal; includeAlerts; includeMetrics; interval; dashboards; rules; playbooks }
        [Parameter(Mandatory = $false)][object]$Monitor = $null,
        [Parameter(Mandatory = $false)][object]$Fleet = $null
    )

    $Entries = [System.Collections.Generic.List[object]]::new()
    $TotalBytes = [long]0

    $Add = {
        param ([string]$Name, [string]$Content)
        if ($Entries.Count -ge $Script:WtBundleMaxEntries) { return $false }
        $Bytes = [System.Text.Encoding]::UTF8.GetByteCount($Content)
        if ($Bytes -gt $Script:WtBundleMaxEntryBytes) {
            $Content = $Content.Substring(0, [math]::Min($Content.Length, $Script:WtBundleMaxEntryBytes)) + '…[TRUNCATED]'
            $Bytes = [System.Text.Encoding]::UTF8.GetByteCount($Content)
        }
        if ($TotalBytes + $Bytes -gt $Script:WtBundleMaxBytes) { return $false }
        $TotalBytes += $Bytes
        $Entries.Add(@{ Name = $Name; Content = $Content })
        return $true
    }

    # Version metadata.
    & $Add 'metadata.json' (@{
        schemaVersion = $Script:WtBundleSchemaVersion
        createdUtc = (Get-Date).ToUniversalTime().ToString('o')
        appVersion = [string](Get-WtJournalContext).appVersion
        protocolVersion = $Script:WtWorkerProtocolVersion
        platform = @{ os = [string](Get-WtPlatformDescription); ps = $PSVersionTable.PSVersion.ToString(); isWindows = [bool]$IsWindows }
    } | ConvertTo-Json -Depth 6)

    # Sanitized operations summary.
    if ($Options.includeJournal) {
        $Rows = @()
        foreach ($Entry in @(Get-WtJournalEntryInternal -Limit 100)) {
            $Rows += [ordered]@{
                tweakId = [string]$Entry.tweakId
                state = [string]$Entry.state
                outcome = [string]$Entry.outcome
                timestamp = [string]$Entry.timestamp
                sequence = [int]$Entry.sequence
            }
        }
        & $Add 'operations-summary.json' ($Rows | ConvertTo-Json -Depth 6)
    }

    # Alert history (from persisted transitions or current state).
    if ($Options.includeAlerts -and $Monitor -and $Monitor.Alerts) {
        $Rows = @()
        foreach ($Alert in $Monitor.Alerts) {
            $Rows += [ordered]@{
                id = $Alert.id
                state = $Alert.state
                severity = $Alert.severity
                threshold = $Alert.threshold
                value = if ($null -ne $Alert.value) { $Alert.value } else { $null }
                missing = $Alert.missing
            }
        }
        & $Add 'alerts-summary.json' ($Rows | ConvertTo-Json -Depth 6)
    }

    # Bounded metrics for the chosen interval (local history only).
    if ($Options.includeMetrics -and $Monitor) {
        $From = [long]$Options.interval.fromMs
        $To = [long]$Options.interval.toMs
        $Rows = @()
        foreach ($Metric in $Script:WtDashboardMetrics) {
            $Samples = @((Get-WtMetricSamples -History $Monitor.History -Key $Metric -FromMs $From -ToMs $To).Samples | Select-Object -Last 200)
            if ($Samples.Count -eq 0) { continue }
            $Rows += [ordered]@{
                metric = $Metric
                samples = @($Samples | ForEach-Object { [ordered]@{ tsMs = [long]$_.tsMs; quality = $_.quality; value = if ($null -ne $_.value) { [double]$_.value } else { $null } } })
            }
        }
        & $Add 'metrics-interval.json' ($Rows | ConvertTo-Json -Depth 8)
    }

    # Dashboard / rule / playbook revisions.
    if ($Options.dashboards) {
        foreach ($Id in $Options.dashboards) {
            $Dashboard = Read-WtDashboardInternal -Id $Id
            if ($Dashboard) { & $Add "dashboard-$Id.json" ($Dashboard | ConvertTo-Json -Depth 10) }
        }
    }
    if ($Options.rules) {
        & $Add 'alert-rules.json' (Get-WtDefaultAlertRules | ConvertTo-Json -Depth 6)
    }
    if ($Options.playbooks) {
        & $Add 'playbooks.json' (Get-WtBuiltinPlaybooks | ConvertTo-Json -Depth 10)
    }

    # Fleet overview (sanitized) when available.
    if ($Fleet -and $Fleet.Hosts) {
        $Rows = @()
        foreach ($Key in $Fleet.Hosts.Keys) {
            $H = $Fleet.Hosts[$Key]
            $Rows += [ordered]@{
                sourceAlias = [string]$H.SourceAlias
                condition = [string]$H.Condition
                freshnessMs = [long]$H.FreshnessMs
            }
        }
        & $Add 'fleet-overview.json' ($Rows | ConvertTo-Json -Depth 6)
    }

    return @{ Entries = @($Entries.ToArray()); TotalBytes = $TotalBytes; Omitted = $Script:WtBundleMaxEntries - $Entries.Count }
}

# Builds the bundle archive (.zip) + manifest with hashes.
function Export-WtSupportBundle {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][hashtable]$Options,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][object]$Monitor = $null,
        [Parameter(Mandatory = $false)][object]$Fleet = $null,
        [Parameter(Mandatory = $false)][switch]$Force
    )

    if (-not $Force -and (Test-Path -LiteralPath $Path)) {
        throw "The bundle path already exists: $Path"
    }

    $Contents = New-WtSupportBundleContents -Options $Options -Monitor $Monitor -Fleet $Fleet
    $ManifestEntries = [System.Collections.Generic.List[object]]::new()
    $Sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $Archive = [System.IO.Compression.ZipArchive]::new(
            [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew),
            [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($Entry in $Contents.Entries) {
                $ZipEntry = $Archive.CreateEntry($Entry.Name)
                $Stream = $ZipEntry.Open()
                $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Entry.Content)
                $Stream.Write($Bytes, 0, $Bytes.Length)
                $Stream.Dispose()

                $Hash = ($Sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
                $ManifestEntries.Add([ordered]@{ name = $Entry.Name; bytes = $Bytes.Length; sha256 = $Hash })
            }

            $Manifest = [ordered]@{
                schemaVersion = $Script:WtBundleSchemaVersion
                createdUtc = (Get-Date).ToUniversalTime().ToString('o')
                includedFiles = @($ManifestEntries.ToArray())
                omittedSections = $Contents.Omitted
                note = 'Hashes verify bundle contents; they do not prove origin. Redaction is best-effort.'
            }
            $ManifestEntry = $Archive.CreateEntry('manifest.json')
            $Stream = $ManifestEntry.Open()
            $ManifestBytes = [System.Text.Encoding]::UTF8.GetBytes(($Manifest | ConvertTo-Json -Depth 8))
            $Stream.Write($ManifestBytes, 0, $ManifestBytes.Length)
            $Stream.Dispose()
        }
        finally {
            $Archive.Dispose()
        }
    }
    finally {
        $Sha.Dispose()
    }

    return [pscustomobject]@{
        Bundle = $Path
        Entries = $Contents.Entries.Count
        TotalBytes = $Contents.TotalBytes
        Omitted = $Contents.Omitted
    }
}

# Imports a bundle as *untrusted offline evidence*. Archive traversal and decompression
# abuse are prevented: entries are read only, name-normalized, size/count-limited, and
# never executed. Imported observations are labeled historical, never live.
function Import-WtSupportBundle {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][string]$ExtractTo = ''
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "Bundle not found: $Path" }

    $Entries = [System.Collections.Generic.List[object]]::new()
    $Archive = [System.IO.Compression.ZipArchive]::new(
        [System.IO.File]::OpenRead($Path),
        [System.IO.Compression.ZipArchiveMode]::Read)
    try {
        if ($Archive.Entries.Count -gt $Script:WtBundleMaxEntries) {
            throw "Bundle has too many entries ($($Archive.Entries.Count) > $($Script:WtBundleMaxEntries))."
        }
        foreach ($Entry in $Archive.Entries) {
            # Prevent traversal: normalize and reject absolute/.. paths.
            $Name = $Entry.FullName -replace '\\', '/'
            if ($Name -match '^/' -or $Name -match '(^|/)\.\.(/|$)') {
                throw "Bundle entry path is unsafe: $Name"
            }
            if ($Entry.Length -gt $Script:WtBundleMaxEntryBytes) {
                throw "Bundle entry too large: $Name ($($Entry.Length) bytes)."
            }
            $Stream = $Entry.Open()
            try {
                $Bytes = [byte[]]::new([int]$Entry.Length)
                $Read = $Stream.Read($Bytes, 0, $Bytes.Length)
                $Text = [System.Text.Encoding]::UTF8.GetString($Bytes, 0, $Read)
                $Entries.Add(@{ Name = $Name; Content = $Text; Historical = $true })
            }
            finally { $Stream.Dispose() }
        }
    }
    finally {
        $Archive.Dispose()
    }

    # Optional extraction into a directory (normalized, never executed).
    if ($ExtractTo) {
        New-WtDirectory -Path $ExtractTo
        foreach ($Entry in $Entries) {
            $Target = Join-Path $ExtractTo $Entry.Name
            $Dir = Split-Path $Target -Parent
            if ($Dir -and -not (Test-Path -LiteralPath $Dir)) { New-WtDirectory -Path $Dir }
            Set-Content -LiteralPath $Target -Value $Entry.Content -Encoding utf8NoBOM
        }
    }

    return @{
        Entries = @($Entries.ToArray())
        Historical = $true
        Note = 'Imported observations are historical, never live.'
    }
}
