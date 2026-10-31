# WindowsTweaker release packaging tests.
#
# These tests generate a real archive with tools/New-ReleasePackage.ps1 for the host
# platform and then take it apart with the bootstrap's own code: checksum verification,
# traversal-safe extraction, manifest validation, per-file hashes, worker-path resolution
# and the worker handshake. Nothing here builds a fixture by hand - a hand-built ZIP would
# prove nothing about what the packaging tool actually writes.
#
# The worker binary is built when a Go toolchain is present; otherwise a placeholder is
# written and the packaging tool is called with -SkipWorkerBuild, so the archive contract
# (paths, manifest, hashes) is still exercised on a machine without Go.

BeforeAll {
    $env:WT_BOOTSTRAP_TEST_ONLY = '1'
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:BootstrapPath = Join-Path $script:RepoRoot 'bootstrap/implementation.ps1'
    $script:PackagingScript = Join-Path $script:RepoRoot 'tools/New-ReleasePackage.ps1'
    $script:Version = (Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'src/WindowsTweaker/WindowsTweaker.psd1')).ModuleVersion
    $script:WorkerProtocol = 1

    . $script:BootstrapPath
    $script:HostKey = Get-WtBootstrapPlatformKey
    $script:Platform = Get-WtBootstrapPlatform -PlatformKey $script:HostKey
    $script:WorkerPath = $script:Platform.WorkerPath

    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-pkg-{0}" -f ([guid]::NewGuid().ToString('n')))
    $script:OutDir = Join-Path $script:TestRoot 'dist'
    [System.IO.Directory]::CreateDirectory($script:OutDir) | Out-Null

    $script:ZipName = "WindowsTweaker-$($script:HostKey)-v$($script:Version).zip"
    $script:ZipPath = Join-Path $script:OutDir $script:ZipName

    $script:WorkerIsReal = [bool](Get-Command go -ErrorAction Ignore)
    $Arguments = @{
        Version = $script:Version
        OutDir = $script:OutDir
        Platforms = @($script:HostKey)
    }
    if (-not $script:WorkerIsReal) {
        $WorkerOnDisk = Join-Path $script:RepoRoot ($script:WorkerPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        [System.IO.Directory]::CreateDirectory((Split-Path $WorkerOnDisk -Parent)) | Out-Null
        Set-Content -LiteralPath $WorkerOnDisk -Value 'placeholder worker (no Go toolchain in this environment)' -Encoding utf8 -NoNewline
        $Arguments['SkipWorkerBuild'] = $true
    }

    # The packaging tool validates every archive it writes with the bootstrap's validator and
    # throws otherwise, so reaching this line already asserts the release contract.
    & $script:PackagingScript @Arguments | Out-Null

    # One extraction of the real archive, reused by the read-only tests below.
    $script:Staging = Join-Path $script:TestRoot 'staging'
    [System.IO.Directory]::CreateDirectory($script:Staging) | Out-Null
    $script:ZipBytes = [System.IO.File]::ReadAllBytes($script:ZipPath)
    Expand-WtBootstrapArchive -Bytes $script:ZipBytes -Staging $script:Staging
    $script:ChecksumMap = Read-WtBootstrapChecksums -Text (Get-Content -LiteralPath (Join-Path $script:OutDir 'checksums.txt') -Raw)
    $script:ReleaseManifest = Get-Content -LiteralPath (Join-Path $script:OutDir 'manifest.json') -Raw | ConvertFrom-Json
    $script:InternalManifest = Get-Content -LiteralPath (Join-Path $script:Staging 'manifest.json') -Raw | ConvertFrom-Json
}

AfterAll {
    Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_BOOTSTRAP_TEST_ONLY -ErrorAction Ignore
}

Describe 'Release package set' {

    It 'writes the versioned archive, checksums and release manifest' {
        (Test-Path -LiteralPath $script:ZipPath -PathType Leaf) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $script:OutDir 'checksums.txt') -PathType Leaf) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $script:OutDir 'manifest.json') -PathType Leaf) | Should -BeTrue

        $script:ReleaseManifest.schemaVersion | Should -Be 1
        $script:ReleaseManifest.tag_name | Should -Be "v$($script:Version)"
        $script:ReleaseManifest.version | Should -Be $script:Version
        $script:ReleaseManifest.workerProtocol | Should -Be $script:WorkerProtocol
        @($script:ReleaseManifest.assets).Count | Should -Be 1
    }

    It 'names the asset for its platform key and records the one download URL GitHub will serve' {
        $Asset = @($script:ReleaseManifest.assets)[0]
        $Asset.name | Should -Be $script:ZipName
        $Asset.platform | Should -Be $script:HostKey
        $Asset.workerPath | Should -Be $script:WorkerPath
        $Asset.browser_download_url | Should -Be "https://github.com/88kbleirad/WindowsTweaker/releases/download/v$($script:Version)/$($script:ZipName)"
        $Asset.size | Should -Be (Get-Item -LiteralPath $script:ZipPath).Length
    }

    It 'agrees between checksums.txt, the release manifest and the archive bytes' {
        $Asset = @($script:ReleaseManifest.assets)[0]
        $Expected = $script:ChecksumMap[$script:ZipName.ToLowerInvariant()]
        $Expected | Should -Not -BeNullOrEmpty
        $Expected | Should -Be $Asset.sha256
        { Test-WtBootstrapHash -Bytes $script:ZipBytes -ExpectedHash $Expected } | Should -Not -Throw

        # checksums.txt lists archives only: a hash of the manifest itself would be the one
        # thing the release could not check against anything.
        @($script:ChecksumMap.Keys) | Should -Be @($script:ZipName.ToLowerInvariant())
        $script:ChecksumMap.ContainsKey('manifest.json') | Should -BeFalse
    }

    It 'keeps the internal package manifest inside the archive and free of archive hashes' {
        $ReadArchive = [System.IO.Compression.ZipFile]::OpenRead($script:ZipPath)
        try {
            $Names = @($ReadArchive.Entries | ForEach-Object { $_.FullName })
        } finally {
            $ReadArchive.Dispose()
        }
        $Names | Should -Contain 'manifest.json'

        # Written before the archive was hashed (it is inside it) and self-referential-free.
        foreach ($Forbidden in @('sha256', 'bytes', 'archiveSha256', 'archive')) {
            $script:InternalManifest.PSObject.Properties[$Forbidden] | Should -BeNullOrEmpty
        }
        $script:InternalManifest.schemaVersion | Should -Be 1
        $script:InternalManifest.platform | Should -Be $script:HostKey
        $script:InternalManifest.version | Should -Be $script:Version
        $script:InternalManifest.workerProtocol | Should -Be $script:WorkerProtocol
        $script:InternalManifest.entryPoint | Should -Be 'WindowsTweaker.ps1'
        $script:InternalManifest.worker.path | Should -Be $script:WorkerPath

        # The manifest describes every entry of the archive except itself.
        $Declared = @($script:InternalManifest.files | ForEach-Object { $_.path })
        $Declared.Count | Should -Be ($Names.Count - 1)
        (@($Names | Where-Object { $_ -ne 'manifest.json' }) | Sort-Object) | Should -Be ($Declared | Sort-Object)
    }

    It 'hashes every declared file and the worker exactly as the archive carries it' {
        $WorkerRecord = @($script:InternalManifest.files | Where-Object { $_.path -eq $script:WorkerPath })[0]
        $WorkerRecord | Should -Not -BeNullOrEmpty
        $WorkerRecord.sha256 | Should -Be $script:InternalManifest.worker.sha256
        $WorkerRecord.size | Should -Be $script:InternalManifest.worker.size

        $StagedWorker = Join-Path $script:Staging ($script:WorkerPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        (Get-FileHash -LiteralPath $StagedWorker -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $WorkerRecord.sha256
        (Get-Item -LiteralPath $StagedWorker).Length | Should -Be $WorkerRecord.size
    }

    It 'keeps the worker executable on the platform that needs a mode bit' {
        if ($IsWindows) {
            Set-ItResult -Skipped -Because 'Windows does not use the Unix mode bits'
            return
        }
        $StagedWorker = Join-Path $script:Staging ($script:WorkerPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        ([System.IO.File]::GetUnixFileMode($StagedWorker) -band [System.IO.UnixFileMode]::UserExecute) |
            Should -Be ([System.IO.UnixFileMode]::UserExecute)
    }
}

Describe 'Validation with the bootstrap code' {

    It 'validates the real archive through manifest, required files and every file hash' {
        $Manifest = Test-WtBootstrapRelease -Staging $script:Staging -PlatformKey $script:HostKey
        $Manifest.platform | Should -Be $script:HostKey
        @($Manifest.files).Count | Should -BeGreaterThan 100
        # Extraction alone is not validation: no completion marker exists until a validator wrote it.
        (Test-WtBootstrapStagingComplete -Staging $script:Staging) | Should -BeFalse
    }

    It 'resolves the worker to the canonical path the client resolves' {
        if (-not $script:WorkerIsReal) {
            Set-ItResult -Skipped -Because 'no Go toolchain: the staged worker is a placeholder that cannot answer the handshake'
            return
        }
        $StagedWorker = Join-Path $script:Staging ($script:WorkerPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)

        # In a child process: the client resolves the worker relative to the module root, and
        # the staging directory has to be that root for the check to mean anything.
        $Script = @"
Import-Module (Join-Path '$($script:Staging)' 'src/WindowsTweaker/WindowsTweaker.psd1') -Force
Get-WtWorkerStatus -Force | ConvertTo-Json -Compress
"@
        $Status = (& (Get-Command pwsh -ErrorAction Stop).Source -NoProfile -Command $Script 2>$null) | ConvertFrom-Json
        $Status.Path | Should -Be $StagedWorker
        $Status.Available | Should -BeTrue
        $Status.Protocol | Should -Be $script:WorkerProtocol
        $Status.Installed | Should -BeTrue
    }
}

Describe 'Tampered and stale packages are refused' {

    It 'rejects an archive whose bytes no longer match the published hash' {
        $Tampered = Join-Path $script:TestRoot 'tampered.zip'
        $Bytes = [byte[]]::new($script:ZipBytes.Length)
        [array]::Copy($script:ZipBytes, $Bytes, $script:ZipBytes.Length)
        $Bytes[$Bytes.Length - 1] = $Bytes[$Bytes.Length - 1] -bxor 0xFF
        [System.IO.File]::WriteAllBytes($Tampered, $Bytes)

        $Expected = $script:ChecksumMap[$script:ZipName.ToLowerInvariant()]
        $TamperedBytes = [System.IO.File]::ReadAllBytes($Tampered)
        { Test-WtBootstrapHash -Bytes $TamperedBytes -ExpectedHash $Expected } | Should -Throw -ExpectedMessage '*SHA-256 mismatch*'
    }

    It 'rejects a staged release whose worker binary was replaced' {
        $Copy = Join-Path $script:TestRoot 'staging-tampered'
        [System.IO.Directory]::CreateDirectory($Copy) | Out-Null
        Expand-WtBootstrapArchive -Bytes $script:ZipBytes -Staging $Copy
        $StagedWorker = Join-Path $Copy ($script:WorkerPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        # Same length, different bytes: the size check cannot be what catches this.
        $Length = (Get-Item -LiteralPath $StagedWorker).Length
        [System.IO.File]::WriteAllText($StagedWorker, ('x' * $Length))
        (Get-Item -LiteralPath $StagedWorker).Length | Should -Be $Length

        { Test-WtBootstrapRelease -Staging $Copy -PlatformKey $script:HostKey } | Should -Throw -ExpectedMessage '*File hash mismatch*'
    }

    It 'rejects a staged release whose manifest disagrees with the archive' {
        $Copy = Join-Path $script:TestRoot 'staging-manifest'
        [System.IO.Directory]::CreateDirectory($Copy) | Out-Null
        Expand-WtBootstrapArchive -Bytes $script:ZipBytes -Staging $Copy
        $ManifestPath = Join-Path $Copy 'manifest.json'
        $Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json

        $Manifest.workerProtocol = 2
        Set-Content -LiteralPath $ManifestPath -Value ($Manifest | ConvertTo-Json -Depth 8) -Encoding utf8
        { Test-WtBootstrapRelease -Staging $Copy -PlatformKey $script:HostKey } | Should -Throw -ExpectedMessage '*Worker protocol mismatch*'

        $Manifest.workerProtocol = 1
        $Manifest.platform = 'win-arm64'
        Set-Content -LiteralPath $ManifestPath -Value ($Manifest | ConvertTo-Json -Depth 8) -Encoding utf8
        { Test-WtBootstrapRelease -Staging $Copy -PlatformKey $script:HostKey } | Should -Throw -ExpectedMessage '*declares platform*'

        $Manifest.platform = $script:HostKey
        $Manifest.worker.path = 'worker/bin/win-x64/wt-worker.exe'
        Set-Content -LiteralPath $ManifestPath -Value ($Manifest | ConvertTo-Json -Depth 8) -Encoding utf8
        { Test-WtBootstrapRelease -Staging $Copy -PlatformKey $script:HostKey } | Should -Throw -ExpectedMessage '*canonical path*'
    }

    It 'rejects a staged release that is missing the worker for its platform' {
        $Copy = Join-Path $script:TestRoot 'staging-noworker'
        [System.IO.Directory]::CreateDirectory($Copy) | Out-Null
        Expand-WtBootstrapArchive -Bytes $script:ZipBytes -Staging $Copy
        Remove-Item -LiteralPath (Join-Path $Copy ($script:WorkerPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)) -Force

        { Test-WtBootstrapRelease -Staging $Copy -PlatformKey $script:HostKey } | Should -Throw -ExpectedMessage '*Required release file missing*'
    }
}
