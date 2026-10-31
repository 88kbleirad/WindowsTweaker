# WindowsTweaker release packaging (runs offline, deterministic).
#
# Usage:
#   pwsh -NoProfile -File tools/New-ReleasePackage.ps1 -Version 1.0.0 -OutDir ./dist
#
# Produces:
#   dist/WindowsTweaker-<platform>-v<version>.zip   (one per platform)
#   dist/checksums.txt                               (SHA-256 per archive)
#   dist/manifest.json                               (release manifest, schema 1)
#
# The archive is self-contained: entry point, module, catalogs, localization, schemas,
# licenses, and the compatible Go worker binary for that platform. No Git, Go toolchain
# or source checkout is required to run it.
#
# This workflow VALIDATES the archive and produces checksums; it does not publish.
# Publishing requires separate, reviewed authorization.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $false)][string]$OutDir = './dist',
    [Parameter(Mandatory = $false)][int]$WorkerProtocol = 1
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Path $PSScriptRoot -Parent

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

[System.Collections.Generic.List[string]]::new() | Out-Null
$Platforms = @(
    @{ Key = 'win-x64';   Os = 'windows'; Arch = 'amd64'; Exe = 'wt-worker.exe' }
    @{ Key = 'win-arm64'; Os = 'windows'; Arch = 'arm64'; Exe = 'wt-worker.exe' }
    @{ Key = 'linux-x64';  Os = 'linux';   Arch = 'amd64'; Exe = 'wt-worker' }
    @{ Key = 'linux-arm64'; Os = 'linux';   Arch = 'arm64'; Exe = 'wt-worker' }
)

$ChecksumLines = [System.Collections.Generic.List[string]]::new()
$ManifestEntries = [System.Collections.Generic.List[object]]::new()
$Sha = [System.Security.Cryptography.SHA256]::Create()

try {
    foreach ($Platform in $Platforms) {
        $ZipName = "WindowsTweaker-$($Platform.Key)-v$Version.zip"
        $ZipPath = Join-Path $OutDir $ZipName
        if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }

        $Archive = [System.IO.Compression.ZipArchive]::new(
            [System.IO.File]::Open($ZipPath, 'CreateNew'),
            [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            # Add files relative to the repo root (forward slashes).
            $Files = @(
                'WindowsTweaker.ps1'
                'THIRD-PARTY-NOTICES.md'
                'PSScriptAnalyzerSettings.psd1'
                'LICENSE'   # optional; only add if present
            )
            foreach ($File in $Files) {
                if (Test-Path -LiteralPath (Join-Path $Root $File)) {
                    # The name is computed first: `-replace` takes exactly two operands, and
                    # passing the compression level to it as a third makes the call ambiguous
                    # (CreateEntry then received three arguments and the package step died).
                    $EntryName = $File -replace '\\', '/'
                    $Entry = $Archive.CreateEntry($EntryName, [System.IO.Compression.CompressionLevel]::Optimal)
                    $Stream = $Entry.Open()
                    try {
                        [System.IO.File]::OpenRead((Join-Path $Root $File)).CopyTo($Stream)
                    } finally { $Stream.Dispose() }
                }
            }

            # Module tree.
            $ModuleRoot = Join-Path $Root 'src/WindowsTweaker'
            foreach ($File in @(Get-ChildItem -LiteralPath $ModuleRoot -Recurse -File | Where-Object { $_.FullName -notmatch '\\(Data|GUI)\\' -or $_.Extension -in '.json', '.psd1', '.ps1', '.xaml' })) {
                $Relative = $File.FullName.Substring($ModuleRoot.Length + 1) -replace '\\', '/'
                $Entry = $Archive.CreateEntry("src/WindowsTweaker/$Relative", [System.IO.Compression.CompressionLevel]::Optimal)
                $Stream = $Entry.Open()
                try {
                    [System.IO.File]::OpenRead($File.FullName).CopyTo($Stream)
                } finally { $Stream.Dispose() }
            }

            # Licence texts. The archive ships a compiled Go worker that statically links the
            # modules named in THIRD-PARTY-NOTICES.md, so their notices travel with it: MIT,
            # BSD and Apache-2.0 all require the notice to be reproduced when the work is
            # distributed.
            $LicenseRoot = Join-Path $Root 'licenses'
            foreach ($File in @(Get-ChildItem -LiteralPath $LicenseRoot -Recurse -File)) {
                $Relative = $File.FullName.Substring($LicenseRoot.Length + 1) -replace '\\', '/'
                $Entry = $Archive.CreateEntry("licenses/$Relative", [System.IO.Compression.CompressionLevel]::Optimal)
                $Stream = $Entry.Open()
                try {
                    [System.IO.File]::OpenRead($File.FullName).CopyTo($Stream)
                } finally { $Stream.Dispose() }
            }

            # Worker binary (exact platform).
            $WorkerBin = Join-Path $Root "worker/bin/$($Platform.Os)-$($Platform.Arch)/$($Platform.Exe)"
            if (-not (Test-Path -LiteralPath $WorkerBin)) {
                throw "Worker binary missing for $($Platform.Key): $WorkerBin (build worker first)."
            }
            $Entry = $Archive.CreateEntry("worker/bin/$($Platform.Os)-$($Platform.Arch)/$($Platform.Exe)", [System.IO.Compression.CompressionLevel]::Optimal)
            $Stream = $Entry.Open()
            try { [System.IO.File]::OpenRead($WorkerBin).CopyTo($Stream) } finally { $Stream.Dispose() }
        } finally {
            $Archive.Dispose()
        }

        # Hash the archive.
        $Hash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $ChecksumLines.Add("$Hash  $ZipName")
        $ManifestEntries.Add([ordered]@{
            name = $ZipName
            platform = $Platform.Key
            os = $Platform.Os
            arch = $Platform.Arch
            version = $Version
            bytes = (Get-Item -LiteralPath $ZipPath).Length
            sha256 = $Hash
        })
        Write-Host "Packaged $ZipName ($hash)"
    }

    # Manifest (schema 1) + checksums.
    $Manifest = [ordered]@{
        schemaVersion = 1
        version = $Version
        engineVersion = $EngineVersion
        workerProtocol = $WorkerProtocol
        createdUtc = (Get-Date).ToUniversalTime().ToString('o')
        assets = @($ManifestEntries.ToArray())
        note = 'Same-release checksums provide integrity relative to this archive; they are not independent publisher authentication.'
    }
    $Manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutDir 'manifest.json') -Encoding utf8NoBOM
    $ChecksumLines | Set-Content -LiteralPath (Join-Path $OutDir 'checksums.txt') -Encoding ascii

    # Validate each archive: required files + traversal safety.
    foreach ($Entry2 in $ManifestEntries) {
        $ZipPath = Join-Path $OutDir $Entry2.name
        $Archive = [System.IO.Compression.ZipArchive]::new([System.IO.File]::OpenRead($ZipPath), 'Read')
        try {
            $Names = @($Archive.Entries | ForEach-Object { $_.FullName })
            # The manifest records os/arch, not the executable name; deriving it here keeps
            # the manifest schema unchanged and the check honest for both platforms.
            $PlatformExe = if ($Entry2.os -eq 'windows') { 'wt-worker.exe' } else { 'wt-worker' }
            $RequiredFiles = @(
                'WindowsTweaker.ps1'
                'THIRD-PARTY-NOTICES.md'
                'src/WindowsTweaker/WindowsTweaker.psd1'
                "worker/bin/$($Entry2.os)-$($Entry2.arch)/$PlatformExe"
                # The worker links these two; their notices must be in the archive.
                'licenses/go-worker/modernc-sqlite-BSD-3-Clause.txt'
                'licenses/go-worker/prometheus-client_golang-Apache-2.0.txt'
            )
            foreach ($Required in $RequiredFiles) {
                if ($Names -notcontains $Required) { throw "Validation failed: $Required missing in $($Entry2.name)" }
            }
            foreach ($Name in $Names) {
                if ($Name -match '(^|/)\.\.(/|$)' -or $Name -match '^/') { throw "Validation failed: unsafe path in $($Entry2.name): $Name" }
            }
        } finally { $Archive.Dispose() }
    }

    Write-Host "Release package set written to $OutDir"
    Write-Host "Checksums: $(Join-Path $OutDir 'checksums.txt')"
    Write-Host "Manifest:  $(Join-Path $OutDir 'manifest.json')"
} finally {
    $Sha.Dispose()
}
