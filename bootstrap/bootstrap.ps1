# WindowsTweaker bootstrap - pipe-execution compatible installer launcher.
#
# Usage (short URL or direct raw):
#   irm "https://YOUR_DOMAIN/win" | iex
#   irm "https://raw.githubusercontent.com/YOUR_GITHUB_OWNER/WindowsTweaker/main/bootstrap/bootstrap.ps1" | iex
#
# This script is executed as *text* through Invoke-Expression. It must therefore not
# rely on $PSScriptRoot, $PSCommandPath, or the caller's working directory, and it must
# not call exit() in a way that would close the caller's session.
#
# Responsibilities:
#   1. resolve a compatible stable GitHub Release (or an explicit release metadata URL);
#   2. select the exact asset for this OS/architecture (no fuzzy matching);
#   3. verify HTTPS and allowed redirect hosts, download size, SHA-256 from the same
#      release's checksums, required package files and manifest, and worker protocol;
#   4. stage into an application-owned directory (traversal-safe extraction); the staged
#      copy is separate from user settings/metrics/journal/recovery data;
#   5. launch the TUI as a child process, wait, report its exit code, and return control
#      to the caller's shell without exit().
#
# Security notes (documented, not hidden):
#   * A hash obtained from the same release provides integrity relative to that source;
#     it is NOT independent publisher authentication.
#   * No unverified fallback. If verification cannot be completed, the bootstrap fails
#     explicitly.
#   * No elevation is requested to download or display the TUI. Per-operation elevation
#     inside WindowsTweaker is preserved unchanged.
#   * If a valid cached version exists and the network fails, an explicitly confirmed
#     offline launch may be offered - never a silent substitution.
#
# Overrides (for release engineering and tests):
#   WT_BOOTSTRAP_RELEASE_URL - URL of release metadata JSON (instead of GitHub API)
#   WT_BOOTSTRAP_STATE_DIR   - staging/state directory (default: per-user app dir)
#   WT_BOOTSTRAP_ENTRYPOINT - force an entry point (for tests / packaging validation)

<#
.SYNOPSIS
    Returns the application-owned state directory for this bootstrap.
#>
function Get-WtBootstrapStateDir {
    if ($env:WT_BOOTSTRAP_STATE_DIR) {
        return [System.IO.Path]::GetFullPath($env:WT_BOOTSTRAP_STATE_DIR)
    }
    $Base = if ($IsWindows) { $env:LOCALAPPDATA } else { if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } else { Join-Path $HOME '.cache' } }
    return (Join-Path $Base 'WindowsTweaker-bootstrap')
}

<#
.SYNOPSIS
    Normalizes a full path string to avoid traversal by using simple canonical join.
#>
function Join-WtBootstrapPath {
    param (
        [Parameter(Mandatory = $true)][string]$Base,
        [Parameter(Mandatory = $true)][string]$Child
    )
    $Norm = $Child -replace '[\\/]', [System.IO.Path]::DirectorySeparatorChar
    $Full = [System.IO.Path]::GetFullPath((Join-Path $Base $Norm))
    $BaseFull = [System.IO.Path]::GetFullPath($Base).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $Full.StartsWith($BaseFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Staging path escapes the state directory: $Child"
    }
    return $Full
}

<#
.SYNOPSIS
    Returns the platform key used to select the asset.
    Returns 'win-x64' | 'win-arm64' | 'linux-x64' | 'linux-arm64'.
#>
function Get-WtBootstrapPlatformKey {
    param (
        # Overrides for tests and release engineering; the defaults are the machine's own.
        [Parameter(Mandatory = $false)][string]$Os = $(if ($IsWindows) { 'win' } else { 'linux' }),
        [Parameter(Mandatory = $false)][string]$Architecture = ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString())
    )

    # The architecture decides the asset, and it is the architecture of the OS - not "is this a
    # 64-bit operating system": every Windows and Linux this tool ships for is 64-bit, so that
    # question can only ever answer one way and would hand an ARM64 machine the x64 build. A
    # 32-bit x86 host has no asset at all, and says so instead of downloading a wrong one.
    switch ($Architecture) {
        'X64' { $Arch = 'x64' }
        'Arm64' { $Arch = 'arm64' }
        default { throw "Unsupported architecture '$Architecture': no WindowsTweaker release is built for it." }
    }

    return "$Os-$Arch"
}

<#
.SYNOPSIS
    Downloads a URL with strict HTTPS + allowed-host redirect validation.
#>
function Get-WtBootstrapContent {
    param (
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $false)][int]$MaxBytes = 0
    )
    $AllowedHosts = @(
        'github.com', 'api.github.com', 'raw.githubusercontent.com',
        'objects.githubusercontent.com', 'github-releases.githubusercontent.com',
        'codeload.github.com'
    )

    if ($Url -notmatch '^https://') {
        throw "Refusing non-HTTPS URL: $Url"
    }

    $Redirects = 0
    $Current = $Url
    do {
        $Uri = [uri]$Current
        if ($Uri.Host -notin $AllowedHosts) {
            throw "Redirect/host not allowed: $($Uri.Host)"
        }
        $Request = [System.Net.HttpWebRequest]::Create($Uri)
        $Request.AllowAutoRedirect = $false
        $Request.Timeout = 20000
        $Request.UserAgent = 'WindowsTweaker-bootstrap/1.0'
        try {
            $Response = $Request.GetResponse()
        } catch [System.Net.WebException] {
            $Http = $_.Exception.Response
            if ($Http -and [int]$Http.StatusCode -in 301, 302, 303, 307, 308 -and $Redirects -lt 10) {
                $Location = $Http.Headers['Location']
                $Http.Close()
                if (-not $Location) { throw "Redirect without Location header." }
                $Current = if ($Location -match '^https://') { $Location } else { ([uri]::new($Uri, $Location)).AbsoluteUri }
                $Redirects++
                continue
            }
            throw $_.Exception.Message
        }
        break
    } while ($true)

    try {
        $HttpResponse = $Response
        $Stream = $HttpResponse.GetResponseStream()
        $Buffer = [byte[]]::new(65536)
        $Memory = [System.IO.MemoryStream]::new()
        try {
            while (($Read = $Stream.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
                if ($MaxBytes -gt 0 -and ($Memory.Length + $Read) -gt $MaxBytes) {
                    throw "Response exceeds the $MaxBytes byte limit."
                }
                $Memory.Write($Buffer, 0, $Read)
            }
            return $Memory.ToArray()
        } finally {
            $Memory.Dispose()
            $Stream.Dispose()
        }
    } finally {
        $Response.Close()
    }
}

<#
.SYNOPSIS
    Fetches the release metadata (GitHub API or explicit override URL).
#>
function Get-WtBootstrapRelease {
    $ReleaseUrl = if ($env:WT_BOOTSTRAP_RELEASE_URL) { $env:WT_BOOTSTRAP_RELEASE_URL }
        else { "https://api.github.com/repos/YOUR_GITHUB_OWNER/WindowsTweaker/releases/latest" }

    $Bytes = Get-WtBootstrapContent -Url $ReleaseUrl -MaxBytes 2MB
    $Json = [System.Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json
    if (-not $Json.tag_name) { throw 'Release metadata is missing tag_name.' }
    return $Json
}

<#
.SYNOPSIS
    Selects the exact asset for the current platform; unambiguous.
#>
function Get-WtBootstrapAsset {
    param (
        [Parameter(Mandatory = $true)][object]$Release
    )
    $Key = Get-WtBootstrapPlatformKey
    $Tag = [string]$Release.tag_name
    $Assets = @($Release.assets)
    if ($Assets.Count -eq 0) { throw 'Release has no assets.' }

    # Exact match: asset name must be <Name>-<Key>[-...].zip. 'WindowsTweaker-win-x64-v1.0.0.zip'
    $Candidate = $Assets | Where-Object {
        $_.name -match "^WindowsTweaker-$([regex]::Escape($Key))-(.+\.zip)$" -or
        $_.name -eq "WindowsTweaker-$Key.zip"
    }
    if ($Candidate.Count -eq 0) {
        throw "No asset for platform '$Key' in release $Tag (assets: $(($Assets.name) -join ', '))."
    }
    if ($Candidate.Count -gt 1) {
        # Prefer the versioned asset (most specific) over the bare one.
        $Versioned = @($Candidate | Where-Object { $_.name -match '-v?[0-9]+\.[0-9]+\.[0-9]+[^/]*\.zip$' })
        if ($Versioned.Count -eq 1) { return $Versioned[0] }
        throw "Ambiguous asset selection for '$Key': $(($Candidate.name) -join ', ')."
    }
    return $Candidate[0]
}

<#
.SYNOPSIS
    Downloads the asset to memory and verifies its size.
#>
function Get-WtBootstrapAssetBytes {
    param (
        [Parameter(Mandatory = $true)][object]$Asset
    )
    $Url = [string]$Asset.browser_download_url
    if (-not $Url) { throw 'Asset has no browser_download_url.' }
    $Size = [long]$Asset.size
    $Bytes = Get-WtBootstrapContent -Url $Url -MaxBytes ([math]::Max(1, $Size + 1MB))
    if ($Bytes.Length -ne $Size) {
        throw "Asset size mismatch: expected $Size, got $($Bytes.Length)."
    }
    return $Bytes
}

<#
.SYNOPSIS
    Finds the expected SHA-256 for an asset from the same release's checksums asset.
    Returns '' when unavailable (caller must fail).
#>
function Get-WtBootstrapExpectedHash {
    param (
        [Parameter(Mandatory = $true)][object]$Release,
        [Parameter(Mandatory = $true)][object]$Asset
    )
    $ChecksumAsset = @($Release.assets | Where-Object { $_.name -match '(?i)^checksums?\.txt$' }) | Select-Object -First 1
    if (-not $ChecksumAsset) { return '' }
    $Bytes = Get-WtBootstrapContent -Url ([string]$ChecksumAsset.browser_download_url) -MaxBytes 1MB
    $Text = [System.Text.Encoding]::UTF8.GetString($Bytes)
    $Needle = [regex]::Escape([System.IO.Path]::GetFileName([string]$Asset.name))
    foreach ($Line in @($Text -split "`r?`n")) {
        if ($Line -match "^\s*([0-9a-f]{64})\s+(.+)$" -and $Matches[2] -match $Needle) {
            return $Matches[1].ToLowerInvariant()
        }
    }
    return ''
}

<#
.SYNOPSIS
    Verifies the asset's SHA-256 against the same-release checksum.
    Documented: same-source integrity, not independent publisher authentication.
#>
function Test-WtBootstrapHash {
    param (
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$ExpectedHash
    )
    $Hash = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($Bytes)) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Hash -ne $ExpectedHash) {
        throw "SHA-256 mismatch (expected $ExpectedHash, got $Hash)."
    }
}

<#
.SYNOPSIS
    Extracts the release archive safely (anti-traversal) into staging.
#>
function Expand-WtBootstrapArchive {
    param (
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Staging
    )
    $ZipPath = Join-Path $Staging '_download.zip'
    [System.IO.File]::WriteAllBytes($ZipPath, $Bytes)
    try {
        $Archive = [System.IO.Compression.ZipArchive]::new(
            [System.IO.File]::OpenRead($ZipPath),
            [System.IO.Compression.ZipArchiveMode]::Read)
        try {
            foreach ($Entry in $Archive.Entries) {
                $Name = $Entry.FullName -replace '\\', '/'
                if ($Name -match '^/' -or $Name -match '(^|/)\.\.(/|$)') {
                    throw "Archive contains unsafe path: $Name"
                }
                $Target = Join-WtBootstrapPath -Base $Staging -Child $Entry.FullName
                if ($Entry.FullName.EndsWith('/')) { continue }
                $Dir = Split-Path $Target -Parent
                if ($Dir -and -not (Test-Path -LiteralPath $Dir)) {
                    [System.IO.Directory]::CreateDirectory($Dir) | Out-Null
                }
                $Stream = $Entry.Open()
                try {
                    $Out = [System.IO.File]::Create($Target)
                    try { $Stream.CopyTo($Out) } finally { $Out.Dispose() }
                } finally { $Stream.Dispose() }
            }
        } finally { $Archive.Dispose() }
    } finally {
        Remove-Item -LiteralPath $ZipPath -Force -ErrorAction Ignore
    }
}

<#
.SYNOPSIS
    Validates the staged release: manifest, required files, worker protocol.
#>
function Test-WtBootstrapRelease {
    param (
        [Parameter(Mandatory = $true)][string]$Staging,
        [Parameter(Mandatory = $true)][string]$PlatformKey
    )

    # Required by manifest: entry point, module manifest, catalogs, strings, schemas,
    # licenses and the worker binary for this platform.
    $ManifestPath = Join-Path $Staging 'manifest.json'
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw 'Release manifest.json is missing.'
    }
    $Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ([int]$Manifest.schemaVersion -ne 1) {
        throw "Unsupported release manifest schema: $($Manifest.schemaVersion)"
    }

    $RequiredFiles = @(
        'WindowsTweaker.ps1'
        'src/WindowsTweaker/WindowsTweaker.psd1'
        "worker/bin/$PlatformKey/wt-worker$(if ($IsWindows) { '.exe' } else { '' })"
        'THIRD-PARTY-NOTICES.md'
    )
    foreach ($File in $RequiredFiles) {
        $Target = Join-WtBootstrapPath -Base $Staging -Child $File
        if (-not (Test-Path -LiteralPath $Target)) {
            throw "Required release file missing: $File"
        }
    }

    # Worker protocol compatibility.
    if ($Manifest.workerProtocol -and [int]$Manifest.workerProtocol -ne 1) {
        throw "Worker protocol mismatch: manifest $($Manifest.workerProtocol), expected 1."
    }
    return $Manifest
}

<#
.SYNOPSIS
    Prepares a staging directory (version-tagged) with a lock for concurrency.
#>
function Get-WtBootstrapStaging {
    param (
        [Parameter(Mandatory = $true)][string]$Tag
    )
    $State = Get-WtBootstrapStateDir
    [System.IO.Directory]::CreateDirectory($State) | Out-Null
    $Staging = Join-Path $State ("release-$Tag")
    [System.IO.Directory]::CreateDirectory($Staging) | Out-Null

    # Exclusive lock: CreateNew semantics (concurrent bootstrap invocations).
    $LockPath = Join-Path $Staging '.lock'
    $Deadline = [datetime]::UtcNow.AddSeconds(60)
    while ($true) {
        try {
            $Stream = [System.IO.File]::Open($LockPath, 'CreateNew', 'Write', 'None')
            $Stream.Dispose()
            break
        } catch {
            if ([datetime]::UtcNow -gt $Deadline) {
                throw "Another bootstrap is staging $Tag; timed out waiting for the lock."
            }
            Start-Sleep -Milliseconds 200
        }
    }
    return $Staging
}

<#
.SYNOPSIS
    Resolves a launch entry point (override for tests/validation).
#>
function Resolve-WtBootstrapEntryPoint {
    param ([Parameter(Mandatory = $true)][string]$Staging)
    if ($env:WT_BOOTSTRAP_ENTRYPOINT) {
        return [System.IO.Path]::GetFullPath($env:WT_BOOTSTRAP_ENTRYPOINT)
    }
    return (Join-Path $Staging 'WindowsTweaker.ps1')
}

<#
.SYNOPSIS
    Launches the TUI in a child process, waits, reports the exit code, and returns
    without exit() so the caller's session stays open.
#>
function Invoke-WtBootstrapLaunch {
    param (
        [Parameter(Mandatory = $true)][string]$EntryPoint
    )
    if (-not (Test-Path -LiteralPath $EntryPoint)) {
        throw "Entry point not found after staging: $EntryPoint"
    }
    # Not $PsHome: PowerShell variables are case-insensitive, so that name *is* the automatic
    # $PSHOME - and this script runs inside the caller's session through `irm | iex`, where
    # overwriting it would change the session, not just this function.
    $HostExe = (Get-Command pwsh -ErrorAction Ignore).Source
    if (-not $HostExe) { $HostExe = (Get-Command powershell -ErrorAction Ignore).Source }
    if (-not $HostExe) { throw 'pwsh not found on PATH.' }

    $Process = [System.Diagnostics.Process]::new()
    $Process.StartInfo.FileName = $HostExe
    # Preserve explicit path with spaces/Unicode; args array kept intact.
    $Process.StartInfo.ArgumentList.Add('-NoProfile')
    $Process.StartInfo.ArgumentList.Add('-File')
    $Process.StartInfo.ArgumentList.Add($EntryPoint)
    $Process.StartInfo.UseShellExecute = $false
    [void]$Process.Start()
    $Process.WaitForExit()
    return $Process.ExitCode
}

<#
.SYNOPSIS
    Refuses to run on a PowerShell that would resolve the wrong release.
.DESCRIPTION
    Under Windows PowerShell 5.1 `$IsWindows` does not exist, so every platform probe in this
    script reads as Linux and the bootstrap would look for a Linux asset on a Windows host.
    The interface it launches needs PowerShell 7.4 anyway, so the session is told what to do
    instead of being handed the wrong release.
.PARAMETER Version
    Version to check. Defaults to the session's own; the parameter exists so the check itself
    is testable without a Windows PowerShell host.
#>
function Assert-WtBootstrapRuntime {
    param ([Parameter(Mandatory = $false)][version]$Version = $PSVersionTable.PSVersion)

    if ($Version -lt [version]'7.4') {
        throw "WindowsTweaker requires PowerShell 7.4 or newer; this session is PowerShell $Version. Run 'pwsh' and try again."
    }
}

<#
.SYNOPSIS
    Main bootstrap flow. Returns the TUI exit code (never calls exit).
#>
function Invoke-WtBootstrap {
    # Before anything else: a wrong runtime cannot select a right release.
    Assert-WtBootstrapRuntime

    $State = Get-WtBootstrapStateDir
    $PlatformKey = Get-WtBootstrapPlatformKey
    $CachedTag = ''
    $CachedStaging = ''

    # Find an existing valid cache (tag directory containing manifest) for offline.
    if (Test-Path -LiteralPath $State) {
        foreach ($Dir in @(Get-ChildItem -LiteralPath $State -Directory | Where-Object { $_.Name -like 'release-*' })) {
            $M = Join-Path $Dir.FullName 'manifest.json'
            if (Test-Path -LiteralPath $M -and (Test-Path -LiteralPath (Join-Path $Dir.FullName 'WindowsTweaker.ps1'))) {
                $CachedTag = $Dir.Name.Substring(8)
                $CachedStaging = $Dir.FullName
                break
            }
        }
    }

    try {
        $Release = Get-WtBootstrapRelease
    } catch {
        if ($CachedTag) {
            # Network failed: offer explicitly confirmed offline launch - never silent.
            if ($env:WT_BOOTSTRAP_ENTRYPOINT -or $env:WT_BOOTSTRAP_RELEASE_URL) {
                # Test/CI environment: proceed with cache only when explicitly enabled.
                if ($env:WT_BOOTSTRAP_ALLOW_OFFLINE) {
                    return (Invoke-WtBootstrapLaunch -EntryPoint (Resolve-WtBootstrapEntryPoint -Staging $CachedStaging))
                }
                throw "Network unavailable and offline cache not enabled by override: $($_.Exception.Message)"
            }
            Write-Host "Network error: $($_.Exception.Message)"
            Write-Host "A validated cached release exists ($CachedTag). Launch it offline? [y/N] " -NoNewline
            $Answer = (Read-Host).Trim().ToLowerInvariant()
            if ($Answer -in 'y', 'yes') {
                return (Invoke-WtBootstrapLaunch -EntryPoint (Resolve-WtBootstrapEntryPoint -Staging $CachedStaging))
            }
            throw 'Bootstrap cancelled by the user (offline refused).'
        }
        throw "Could not resolve release metadata: $($_.Exception.Message)"
    }

    $Tag = [string]$Release.tag_name
    $Asset = Get-WtBootstrapAsset -Release $Release

    # Exact architecture-specific asset identity check.
    if ($Asset.name -notmatch [regex]::Escape("-$PlatformKey")) {
        throw "Asset '$($Asset.name)' does not match the required platform key '$PlatformKey'."
    }

    # Cache hit: same tag already staged -> launch directly.
    if ($CachedTag -eq $Tag) {
        return (Invoke-WtBootstrapLaunch -EntryPoint (Resolve-WtBootstrapEntryPoint -Staging $CachedStaging))
    }

    $Staging = Get-WtBootstrapStaging -Tag $Tag
    try {
        Write-Host "Resolved WindowsTweaker $Tag ($PlatformKey) from $($Release.html_url)"
        $Bytes = Get-WtBootstrapAssetBytes -Asset $Asset
        $ExpectedHash = Get-WtBootstrapExpectedHash -Release $Release -Asset $Asset
        if (-not $ExpectedHash) {
            throw 'No checksums.txt in the release: integrity verification unavailable, refusing to download unverified content.'
        }
        Test-WtBootstrapHash -Bytes $Bytes -ExpectedHash $ExpectedHash
        Write-Host 'SHA-256 verified against the release checksums (same-source integrity; not independent publisher authentication).'

        Expand-WtBootstrapArchive -Bytes $Bytes -Staging $Staging
        $null = Test-WtBootstrapRelease -Staging $Staging -PlatformKey $PlatformKey
        Write-Host "Release staged at $Staging"

        return (Invoke-WtBootstrapLaunch -EntryPoint (Resolve-WtBootstrapEntryPoint -Staging $Staging))
    } finally {
        # Cleanup only staging leftovers; never user settings/metrics/journal/recovery.
        $LockPath = Join-Path $Staging '.lock'
        Remove-Item -LiteralPath $LockPath -Force -ErrorAction Ignore
    }
}

# Entry: run the bootstrap only when not dot-sourced for tests/authoring.
# No exit(); a non-zero returned code is mirrored into $LASTEXITCODE so the caller's
# session stays alive.
if (-not $env:WT_BOOTSTRAP_TEST_ONLY) {
    $script:WtBootstrapExitCode = 0
    try {
        $script:WtBootstrapExitCode = [int](Invoke-WtBootstrap)
    } catch {
        Write-Error $_.Exception.Message
        $script:WtBootstrapExitCode = 1
    }
    $global:LASTEXITCODE = $script:WtBootstrapExitCode
    return $script:WtBootstrapExitCode
}
