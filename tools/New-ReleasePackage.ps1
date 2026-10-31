# WindowsTweaker release packaging (runs offline, deterministic inputs).
#
# Usage:
#   pwsh -NoProfile -File tools/New-ReleasePackage.ps1 -Version 1.0.1 -OutDir ./dist
#
#   # one platform only (fast path used by tests), with the worker binaries already built:
#   pwsh -NoProfile -File tools/New-ReleasePackage.ps1 -Version 1.0.1 -Platforms linux-x64 -SkipWorkerBuild
#
# Produces, beside each other in -OutDir:
#   WindowsTweaker-<platform>-v<version>.zip   one per selected platform, or all four
#   checksums.txt                              SHA-256 per archive (ASCII, `hash  name`)
#   manifest.json                              release manifest, schema 1: tag_name,
#                                              assets with size/sha256/browser_download_url
#
# Two manifests, deliberately separate:
#   * INSIDE each archive, manifest.json (schema 1) lists platform, version, workerProtocol,
#     entry point, the canonical worker path and every packaged file with its size and
#     SHA-256. It is written before the archive is closed, so it is covered by the archive
#     hash - and it carries no archive hash of its own (that would be self-referential).
#   * BESIDE the archives, manifest.json + checksums.txt describe the release. They are
#     never part of an archive, so no archive hash can depend on them.
#
# Every generated archive is verified with the same code the bootstrap runs:
# bootstrap/implementation.ps1 is dot-sourced and Expand-WtBootstrapArchive,
# Test-WtBootstrapRelease, Read-WtBootstrapChecksums and Test-WtBootstrapHash are used on
# the real bytes. A release the bootstrap would refuse is never reported as packaged.
# (The archive does not contain either bootstrap file: the launcher is fetched from the
# repository, and the implementation is fetched by it.)
#
# Worker binaries are built first, for exactly the selected platforms, so the archive can
# never contain a stale or missing worker. The build output directory and the archive entry
# are the same canonical path (`worker/bin/<goos>-<goarch>/`).
#
# This tool VALIDATES the archives and produces the checksums; it does not publish.
# Publishing requires separate, reviewed authorization (see docs/RELEASE.md).

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,

    [Parameter(Mandatory = $false)][string]$OutDir = './dist',

    # Release platform keys to package (default: every canonical platform).
    [Parameter(Mandatory = $false)][string[]]$Platforms,

    # Owner/repository the assets are published to; used for the manifest's download URLs.
    [Parameter(Mandatory = $false)][string]$Repository = '88kbleirad/WindowsTweaker',

    # Use the worker binaries already on disk instead of building them.
    [Parameter(Mandatory = $false)][switch]$SkipWorkerBuild,

    [Parameter(Mandatory = $false)][int]$WorkerProtocol = 1
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Path $PSScriptRoot -Parent
$BootstrapPath = Join-Path $Root 'bootstrap/implementation.ps1'

# ---- The canonical platform mapping lives in the bootstrap ---------------------
# Dot-sourced with the entry block disabled: one table, no second copy that can drift.
# The implementation file is dot-sourced, not the published launcher: the launcher is pure
# ASCII and only loads the implementation, while the functions used below (platform table,
# archive extraction, release validation, hash checks) live in the implementation.
$PreviousTestOnly = $env:WT_BOOTSTRAP_TEST_ONLY
$env:WT_BOOTSTRAP_TEST_ONLY = '1'
try {
    . $BootstrapPath
} finally {
    if ($null -eq $PreviousTestOnly) { Remove-Item Env:\WT_BOOTSTRAP_TEST_ONLY -ErrorAction Ignore }
    else { $env:WT_BOOTSTRAP_TEST_ONLY = $PreviousTestOnly }
}

$AllPlatforms = @(Get-WtBootstrapPlatforms)
foreach ($Platform in $AllPlatforms) {
    $Derived = "worker/bin/$($Platform.Os)-$($Platform.Arch)/$($Platform.Exe)"
    if ($Platform.WorkerPath -ne $Derived) {
        throw "Canonical mapping is inconsistent for '$($Platform.Key)': WorkerPath '$($Platform.WorkerPath)' is not '$Derived'."
    }
}

$SelectedPlatforms = if ($Platforms) { @($Platforms) } else { @($AllPlatforms.Key) }
if ($SelectedPlatforms.Count -eq 0) { throw 'No platform selected.' }
foreach ($Key in $SelectedPlatforms) {
    if ($Key -notin $AllPlatforms.Key) {
        throw "Unknown platform '$Key' (canonical keys: $($AllPlatforms.Key -join ', '))."
    }
}

# ---- Validate the working tree (parse + gateway module import) -----------------
& (Join-Path $Root 'tools/Parse-All.ps1') | Out-Null
if ($LASTEXITCODE -ne 0) {
    # The report is still on the host, but packaging an archive with a file that cannot be
    # loaded would ship the failure: the parse result decides, not the import that follows.
    throw "The working tree does not parse (tools/Parse-All.ps1 exited $LASTEXITCODE); refusing to package."
}

Import-Module (Join-Path $Root 'src/WindowsTweaker/WindowsTweaker.psd1') -Force -ErrorAction Stop
$EngineVersion = (Import-PowerShellDataFile -LiteralPath (Join-Path $Root 'src/WindowsTweaker/WindowsTweaker.psd1')).ModuleVersion
if ($EngineVersion -ne $Version) {
    throw "Version mismatch: packaging $Version but module is $EngineVersion."
}

$OutDir = if ([System.IO.Path]::IsPathRooted($OutDir)) {
    # Join-Path would treat an absolute path as a relative segment and silently write the
    # archives under the current directory instead.
    [System.IO.Path]::GetFullPath($OutDir)
} else {
    [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $OutDir))
}
[System.IO.Directory]::CreateDirectory($OutDir) | Out-Null

# SOURCE_DATE_EPOCH makes the manifest timestamps reproducible; without it the current time
# is used and only the inputs are deterministic.
$CreatedUtc = if ($env:SOURCE_DATE_EPOCH -and [long]$env:SOURCE_DATE_EPOCH -gt 0) {
    [datetimeoffset]::FromUnixTimeSeconds([long]$env:SOURCE_DATE_EPOCH).UtcDateTime.ToString('o')
} else {
    (Get-Date).ToUniversalTime().ToString('o')
}
# Fixed entry timestamps keep the archives byte-comparable between runs on one machine.
$ZipTimestamp = [datetimeoffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)

$Tag = "v$Version"

# ---- Build the workers for the selected platforms ------------------------------
if (-not $SkipWorkerBuild) {
    $GoExe = (Get-Command go -ErrorAction Ignore).Source
    if (-not $GoExe) {
        throw 'The Go toolchain is not on PATH. Install Go (docs/WORKER.md) or pass -SkipWorkerBuild with prebuilt binaries in worker/bin/.'
    }
    $WorkerDir = Join-Path $Root 'worker'
    foreach ($Key in $SelectedPlatforms) {
        $Platform = Get-WtBootstrapPlatform -PlatformKey $Key
        $Target = Join-Path $Root $Platform.WorkerPath
        [System.IO.Directory]::CreateDirectory((Split-Path $Target -Parent)) | Out-Null
        Write-Host "Building worker for $Key ($($Platform.Os)/$($Platform.Arch))"
        $SavedCgo = $env:CGO_ENABLED
        $SavedGoOs = $env:GOOS
        $SavedGoArch = $env:GOARCH
        try {
            $env:CGO_ENABLED = '0'
            $env:GOOS = $Platform.Os
            $env:GOARCH = $Platform.Arch
            Push-Location $WorkerDir
            try {
                & $GoExe build -trimpath -ldflags '-s -w' -o $Target ./cmd/wt-worker
            } finally {
                Pop-Location
            }
        } finally {
            $env:CGO_ENABLED = $SavedCgo
            $env:GOOS = $SavedGoOs
            $env:GOARCH = $SavedGoArch
        }
        if ($LASTEXITCODE -ne 0) {
            throw "go build failed for $Key (exit $LASTEXITCODE)."
        }
    }
}

# ---- Package ----------------------------------------------------------------
function Add-WtPackageFile {
    param (
        [Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $true)][string]$EntryName,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Records,
        [Parameter(Mandatory = $false)][switch]$Executable
    )
    $Item = Get-Item -LiteralPath $SourcePath
    $Entry = $Archive.CreateEntry($EntryName, [System.IO.Compression.CompressionLevel]::Optimal)
    $Entry.LastWriteTime = $ZipTimestamp
    # The Unix mode is stored so extraction on Linux keeps the worker executable; without it
    # a staged release could not start its worker on Linux at all.
    # 0100755 / 0100644 as one 32-bit value: the zip external attributes carry the Unix
    # st_mode in their high 16 bits. PowerShell has no octal literal, hence the hex.
    $Mode = if ($Executable) { 0x81ED } else { 0x81A4 }
    # Int32 two's complement: 0x81A40000 is a negative Int32 by the time .NET stores it,
    # and the high 16 bits still carry the mode.
    $Attributes = [int64]$Mode -shl 16
    if ($Attributes -gt [int]::MaxValue) { $Attributes -= 4294967296 }
    $Entry.ExternalAttributes = [int]$Attributes
    $Stream = $Entry.Open()
    try {
        [System.IO.File]::OpenRead($SourcePath).CopyTo($Stream)
    } finally {
        $Stream.Dispose()
    }
    $Records.Add([ordered]@{
        path = $EntryName
        size = $Item.Length
        sha256 = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    })
}

$ChecksumLines = [System.Collections.Generic.List[string]]::new()
$Assets = [System.Collections.Generic.List[object]]::new()
$ValidationRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-package-{0}" -f ([guid]::NewGuid().ToString('n')))
[System.IO.Directory]::CreateDirectory($ValidationRoot) | Out-Null

try {
    foreach ($Key in $SelectedPlatforms) {
        $Platform = Get-WtBootstrapPlatform -PlatformKey $Key
        $ZipName = "WindowsTweaker-$Key-v$Version.zip"
        $ZipPath = Join-Path $OutDir $ZipName
        if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }

        $Records = [System.Collections.Generic.List[object]]::new()

        $Archive = [System.IO.Compression.ZipArchive]::new(
            [System.IO.File]::Open($ZipPath, 'CreateNew'),
            [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            # Root files (forward slashes in the archive; optional ones only when present).
            foreach ($File in @('WindowsTweaker.ps1', 'THIRD-PARTY-NOTICES.md', 'PSScriptAnalyzerSettings.psd1', 'LICENSE')) {
                $Source = Join-Path $Root $File
                if (Test-Path -LiteralPath $Source -PathType Leaf) {
                    Add-WtPackageFile -Archive $Archive -EntryName ($File -replace '\\', '/') -SourcePath $Source -Records $Records
                }
            }

            # Module tree.
            $ModuleRoot = Join-Path $Root 'src/WindowsTweaker'
            foreach ($File in @(Get-ChildItem -LiteralPath $ModuleRoot -Recurse -File |
                Where-Object { $_.FullName -notmatch '\\(Data|GUI)\\' -or $_.Extension -in '.json', '.psd1', '.ps1', '.xaml' } |
                Sort-Object FullName)) {
                $Relative = $File.FullName.Substring($ModuleRoot.Length + 1) -replace '\\', '/'
                Add-WtPackageFile -Archive $Archive -EntryName "src/WindowsTweaker/$Relative" -SourcePath $File.FullName -Records $Records
            }

            # Licence texts. The archive ships a compiled Go worker that statically links the
            # modules named in THIRD-PARTY-NOTICES.md, so their notices travel with it: MIT,
            # BSD and Apache-2.0 all require the notice to be reproduced when the work is
            # distributed.
            $LicenseRoot = Join-Path $Root 'licenses'
            foreach ($File in @(Get-ChildItem -LiteralPath $LicenseRoot -Recurse -File | Sort-Object FullName)) {
                $Relative = $File.FullName.Substring($LicenseRoot.Length + 1) -replace '\\', '/'
                Add-WtPackageFile -Archive $Archive -EntryName "licenses/$Relative" -SourcePath $File.FullName -Records $Records
            }

            # Worker binary: the canonical path for this platform key, built above.
            $WorkerSource = Join-Path $Root ($Platform.WorkerPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $WorkerSource -PathType Leaf)) {
                throw "Worker binary missing for ${Key}: $WorkerSource (build the worker first, or drop -SkipWorkerBuild)."
            }
            if ((Get-Item -LiteralPath $WorkerSource).Length -eq 0) {
                throw "Worker binary for $Key is empty: $WorkerSource"
            }
            Add-WtPackageFile -Archive $Archive -EntryName $Platform.WorkerPath -SourcePath $WorkerSource -Records $Records -Executable

            # Package manifest, written last so it describes every file above, and written
            # *inside* the archive so the archive hash published afterwards covers it.
            $WorkerRecord = @($Records | Where-Object { $_.path -eq $Platform.WorkerPath })[0]
            $Manifest = [ordered]@{
                schemaVersion = 1
                package = 'WindowsTweaker'
                version = $Version
                engineVersion = $EngineVersion
                platform = $Key
                os = $Platform.Os
                arch = $Platform.Arch
                entryPoint = 'WindowsTweaker.ps1'
                workerProtocol = $WorkerProtocol
                worker = [ordered]@{
                    path = $Platform.WorkerPath
                    size = $WorkerRecord.size
                    sha256 = $WorkerRecord.sha256
                }
                files = @($Records.ToArray())
                createdUtc = $CreatedUtc
                note = 'This manifest is part of the archive and intentionally carries no archive hash; release integrity is published separately in checksums.txt and the release manifest.'
            }
            $ManifestJson = $Manifest | ConvertTo-Json -Depth 8
            $ManifestEntry = $Archive.CreateEntry('manifest.json', [System.IO.Compression.CompressionLevel]::Optimal)
            $ManifestEntry.LastWriteTime = $ZipTimestamp
            $Writer = [System.IO.StreamWriter]::new($ManifestEntry.Open(), [System.Text.UTF8Encoding]::new($false))
            try { $Writer.Write($ManifestJson) } finally { $Writer.Dispose() }
        } finally {
            $Archive.Dispose()
        }

        # Final archive hash, computed only now that the manifest is inside the archive.
        $Hash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $Size = (Get-Item -LiteralPath $ZipPath).Length
        $ChecksumLines.Add("$Hash  $ZipName")
        $Assets.Add([ordered]@{
            name = $ZipName
            platform = $Key
            os = $Platform.Os
            arch = $Platform.Arch
            workerPath = $Platform.WorkerPath
            version = $Version
            size = $Size
            sha256 = $Hash
            browser_download_url = "https://github.com/$Repository/releases/download/$Tag/$ZipName"
        })
        Write-Host "Packaged $ZipName ($Hash, $Size bytes)"
    }

    # ---- External release manifest + checksums ----------------------------------
    # Neither file is inside an archive, so no archive hash can depend on them.
    $ReleaseManifest = [ordered]@{
        schemaVersion = 1
        package = 'WindowsTweaker'
        tag_name = $Tag
        name = "WindowsTweaker $Tag"
        html_url = "https://github.com/$Repository/releases/tag/$Tag"
        repository = $Repository
        version = $Version
        engineVersion = $EngineVersion
        workerProtocol = $WorkerProtocol
        createdUtc = $CreatedUtc
        assets = @($Assets.ToArray())
        note = 'Same-release checksums provide integrity relative to this release; they are not independent publisher authentication. This manifest and checksums.txt are not part of any archive.'
    }
    $ReleaseManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutDir 'manifest.json') -Encoding utf8NoBOM
    $ChecksumLines | Set-Content -LiteralPath (Join-Path $OutDir 'checksums.txt') -Encoding ascii

    # ---- Validate every archive with the bootstrap's own logic ------------------
    $ChecksumMap = Read-WtBootstrapChecksums -Text (Get-Content -LiteralPath (Join-Path $OutDir 'checksums.txt') -Raw)
    $HostKey = Get-WtBootstrapPlatformKey

    foreach ($Asset in $Assets) {
        $ZipPath = Join-Path $OutDir $Asset.name
        $Bytes = [System.IO.File]::ReadAllBytes($ZipPath)

        $Expected = if ($ChecksumMap.ContainsKey($Asset.name.ToLowerInvariant())) { $ChecksumMap[$Asset.name.ToLowerInvariant()] } else { '' }
        if (-not $Expected) { throw "Validation failed: checksums.txt has no entry for $($Asset.name)." }
        if ($Expected -ne $Asset.sha256) { throw "Validation failed: checksums.txt disagrees with the manifest for $($Asset.name)." }
        if ($Bytes.Length -ne $Asset.size) { throw "Validation failed: size recorded for $($Asset.name) does not match the file." }
        Test-WtBootstrapHash -Bytes $Bytes -ExpectedHash $Expected

        $Staging = Join-Path $ValidationRoot "stage-$($Asset.platform)"
        if (Test-Path -LiteralPath $Staging) { Remove-Item -LiteralPath $Staging -Recurse -Force }
        [System.IO.Directory]::CreateDirectory($Staging) | Out-Null
        Expand-WtBootstrapArchive -Bytes $Bytes -Staging $Staging

        $Internal = Test-WtBootstrapRelease -Staging $Staging -PlatformKey $Asset.platform
        if (-not (Test-WtBootstrapStagingComplete -Staging $Staging)) {
            # The staging marker is what makes a cache entry launchable; packaging proves the
            # same marker logic works on the archive it just wrote.
            Set-WtBootstrapStagingComplete -Staging $Staging -PlatformKey $Asset.platform -Version ([string]$Internal.version)
        }
        if (-not (Test-WtBootstrapStagingComplete -Staging $Staging)) {
            throw "Validation failed: the staged $($Asset.name) is not markable as complete."
        }

        # No self-referential hash: the internal manifest must not carry the archive's hash.
        foreach ($Forbidden in @('sha256', 'bytes', 'archiveSha256', 'archive')) {
            if ($Internal.PSObject.Properties[$Forbidden]) {
                throw "Validation failed: the internal manifest of $($Asset.name) carries '$Forbidden' (self-referential)."
            }
        }
        if ([string]$Internal.platform -ne $Asset.platform) {
            throw "Validation failed: $($Asset.name) declares platform '$($Internal.platform)'."
        }
        if ([string]$Internal.worker.path -ne $Asset.workerPath) {
            throw "Validation failed: $($Asset.name) declares worker '$($Internal.worker.path)', expected '$($Asset.workerPath)'."
        }
        $DeclaredFiles = @($Internal.files)
        $ReadArchive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            $EntryCount = $ReadArchive.Entries.Count
        } finally {
            $ReadArchive.Dispose()
        }
        if ($DeclaredFiles.Count -ne ($EntryCount - 1)) {
            throw "Validation failed: $($Asset.name) has $EntryCount entries but the manifest declares $($DeclaredFiles.Count) files (plus itself)."
        }

        # The shipped client must resolve the worker from the same path the manifest declares,
        # and - on a host that can run it - the worker must answer the protocol handshake.
        $StagedWorker = Join-Path $Staging ($Asset.workerPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $StagedWorker -PathType Leaf)) {
            throw "Validation failed: $($Asset.name) has no worker at $($Asset.workerPath)."
        }
        if ($Asset.platform -eq $HostKey) {
            # In a child process on purpose: importing the module from the staging directory into
            # this session would leave a second instance of a module of the same name loaded, and
            # every later Import-Module/InModuleScope in the session would have to cope with that.
            $ChildScript = @"
Import-Module (Join-Path '$Staging' 'src/WindowsTweaker/WindowsTweaker.psd1') -Force -ErrorAction Stop
Get-WtWorkerStatus -Force | ConvertTo-Json -Compress
"@
            $SavedWorkerPath = $env:WT_WORKER_PATH
            Remove-Item Env:\WT_WORKER_PATH -ErrorAction Ignore
            try {
                $ChildOutput = & (Get-Command pwsh -ErrorAction Stop).Source -NoProfile -Command $ChildScript 2>$null
            } finally {
                if ($null -ne $SavedWorkerPath) { $env:WT_WORKER_PATH = $SavedWorkerPath }
            }
            $Status = $ChildOutput | ConvertFrom-Json
            if (-not $Status) { throw "Validation failed: the staged client could not report its worker for $($Asset.name)." }
            if ($Status.Path -ne $StagedWorker) {
                throw "Validation failed: the client resolves the worker to '$($Status.Path)', the archive declares '$StagedWorker'."
            }
            if (-not $Status.Available) {
                throw "Validation failed: the packaged worker is not usable ($($Status.Code)): $($Status.Reason)"
            }
            if ([int]$Status.Protocol -ne $WorkerProtocol) {
                throw "Validation failed: the packaged worker speaks protocol $($Status.Protocol), expected $WorkerProtocol."
            }
            Write-Host "  worker handshake: $($Status.Version), protocol $($Status.Protocol), $($Status.Capabilities.Count) capabilit$(if ($Status.Capabilities.Count -eq 1) { 'y' } else { 'ies' })"
        }

        Write-Host "Validated $($Asset.name): checksum, safe extraction, manifest, $($DeclaredFiles.Count) file hashes, worker path"
        Remove-Item -LiteralPath $Staging -Recurse -Force -ErrorAction Ignore
    }

    Write-Host ''
    Write-Host "Release package set written to $OutDir"
    Write-Host "Checksums: $(Join-Path $OutDir 'checksums.txt')"
    Write-Host "Manifest:  $(Join-Path $OutDir 'manifest.json')"
} finally {
    Remove-Item -LiteralPath $ValidationRoot -Recurse -Force -ErrorAction Ignore
}
