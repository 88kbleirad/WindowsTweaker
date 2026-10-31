# WindowsTweaker bootstrap tests.
#
# Two of the tests here execute the script as *text* through iex, which is the way the
# documented `irm ... | iex` one-liner runs it: no $PSScriptRoot, and no second chance if
# the script calls exit(). The session-preservation and "no tweak" properties are asserted
# on that path, not on a dot-source that skips the entry block.

BeforeAll {
    $env:WT_BOOTSTRAP_TEST_ONLY = '1'
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:BootstrapPath = Join-Path $script:RepoRoot 'bootstrap/bootstrap.ps1'
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-boot-{0}" -f ([guid]::NewGuid().ToString('n')))
    [System.IO.Directory]::CreateDirectory($script:TestRoot) | Out-Null
    $script:PwshPath = (Get-Command pwsh -ErrorAction Stop).Source
}

AfterAll {
    Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_BOOTSTRAP_TEST_ONLY -ErrorAction Ignore
}

Describe 'Bootstrap text execution' {

    It 'executes from downloaded text with no script-path variables and mirrors the code instead of throwing' {
        $Text = Get-Content -LiteralPath $script:BootstrapPath -Raw
        $env:WT_BOOTSTRAP_STATE_DIR = Join-Path $script:TestRoot 'state-text'
        $env:WT_BOOTSTRAP_RELEASE_URL = 'http://invalid.example/bootstrap'
        $env:WT_BOOTSTRAP_ENTRYPOINT = 'C:\nonexistent\entry.ps1'
        # The entry block runs only when WT_BOOTSTRAP_TEST_ONLY is unset; that is the path the
        # one-liner takes, so it is the path under test. A script block created from the text
        # is the same execution mode as `irm | iex` without using Invoke-Expression: no
        # $PSScriptRoot, no $PSCommandPath, nothing from the caller's working directory.
        Remove-Item Env:\WT_BOOTSTRAP_TEST_ONLY -ErrorAction Ignore
        try {
            $global:LASTEXITCODE = 0
            { & ([scriptblock]::Create($Text)) 2>$null | Out-Null } | Should -Not -Throw
            $LASTEXITCODE | Should -Be 1
        } finally {
            Remove-Item Env:\WT_BOOTSTRAP_STATE_DIR, Env:\WT_BOOTSTRAP_RELEASE_URL, Env:\WT_BOOTSTRAP_ENTRYPOINT -ErrorAction Ignore
            $env:WT_BOOTSTRAP_TEST_ONLY = '1'
        }
    }

    It 'never calls exit(): the session that piped the text in keeps running and is left clean' {
        $StateDir = Join-Path $script:TestRoot 'state-session'
        $Script = @"
# The test session sets WT_BOOTSTRAP_TEST_ONLY (it dot-sources the same file); the child
# process inherits it and would skip the entry block, which is exactly what is under test here.
Remove-Item Env:\WT_BOOTSTRAP_TEST_ONLY -ErrorAction Ignore
`$env:WT_BOOTSTRAP_STATE_DIR = '$StateDir'
`$env:WT_BOOTSTRAP_RELEASE_URL = 'http://invalid.example/bootstrap'
`$env:WT_BOOTSTRAP_ENTRYPOINT = 'C:\nonexistent\entry.ps1'
iex (Get-Content -LiteralPath '$($script:BootstrapPath)' -Raw)
'AFTER-BOOTSTRAP ' + `$LASTEXITCODE
'LEFT-OVER-FUNCTIONS ' + (@(Get-ChildItem Function:\ | Where-Object { `$_.Name -like '*WtBootstrap*' }).Count)
'STILL-HERE'
"@
        $Output = & $script:PwshPath -NoProfile -Command $Script 2>$null
        $ExitCode = $LASTEXITCODE
        $Text = $Output -join "`n"

        # exit() anywhere in the bootstrap would end this child session before these lines.
        $ExitCode | Should -Be 0
        $Text | Should -Match 'AFTER-BOOTSTRAP 1'
        $Text | Should -Match 'LEFT-OVER-FUNCTIONS 0'
        $Text | Should -Match 'STILL-HERE'
    }
}

Describe 'Release selection and verification' {

    It 'selects the asset for the architecture of the OS, never for "is it 64-bit"' {
        . $script:BootstrapPath

        # Every platform this ships for is 64-bit, so "is the OS 64-bit" can only ever answer
        # one way; it is this mapping that keeps an ARM64 machine off the x64 build.
        (Get-WtBootstrapPlatformKey -Os 'win' -Architecture 'Arm64') | Should -Be 'win-arm64'
        (Get-WtBootstrapPlatformKey -Os 'linux' -Architecture 'Arm64') | Should -Be 'linux-arm64'
        (Get-WtBootstrapPlatformKey -Os 'win' -Architecture 'X64') | Should -Be 'win-x64'
        (Get-WtBootstrapPlatformKey -Os 'linux' -Architecture 'X64') | Should -Be 'linux-x64'

        # A 32-bit host has no asset: refusing beats downloading an x64 archive it cannot run.
        { Get-WtBootstrapPlatformKey -Os 'win' -Architecture 'X86' } | Should -Throw -ExpectedMessage '*Unsupported architecture*'
    }

    It 'maps every release platform key to its own worker path (the one the client resolves)' {
        . $script:BootstrapPath

        $Expected = @{
            'win-x64'     = 'worker/bin/windows-amd64/wt-worker.exe'
            'win-arm64'   = 'worker/bin/windows-arm64/wt-worker.exe'
            'linux-x64'   = 'worker/bin/linux-amd64/wt-worker'
            'linux-arm64' = 'worker/bin/linux-arm64/wt-worker'
        }
        $Platforms = @(Get-WtBootstrapPlatforms)
        $Platforms.Count | Should -Be $Expected.Count
        foreach ($Platform in $Platforms) {
            $Platform.WorkerPath | Should -Be $Expected[$Platform.Key]
            (Get-WtBootstrapWorkerPath -PlatformKey $Platform.Key) | Should -Be $Expected[$Platform.Key]
            # The canonical path is the build output directory too: one scheme, not two.
            $Platform.WorkerPath | Should -Be "worker/bin/$($Platform.Os)-$($Platform.Arch)/$($Platform.Exe)"
        }
        @($Platforms.WorkerPath | Sort-Object -Unique).Count | Should -Be $Platforms.Count
        { Get-WtBootstrapWorkerPath -PlatformKey 'freebsd-x64' } | Should -Throw -ExpectedMessage '*Unknown release platform key*'
    }

    It 'starts on Windows PowerShell 5.1 and refuses only an older runtime' {
        . $script:BootstrapPath

        # 5.1 is the floor, not an error: it ships with Windows and has to work.
        { Assert-WtBootstrapRuntime -Version ([version]'5.1.26100.1591') } | Should -Not -Throw
        { Assert-WtBootstrapRuntime -Version ([version]'7.6.9') } | Should -Not -Throw
        { Assert-WtBootstrapRuntime -Version $PSVersionTable.PSVersion } | Should -Not -Throw

        { Assert-WtBootstrapRuntime -Version ([version]'5.0.10586.0') } | Should -Throw -ExpectedMessage 'RUNTIME:*'
        { Assert-WtBootstrapRuntime -Version ([version]'4.0.30319.0') } | Should -Throw -ExpectedMessage '*needs PowerShell*'
    }

    It 'accepts only the tested stable PowerShell 7 range as the handoff target' {
        . $script:BootstrapPath

        (Test-WtBootstrapCompatibleVersion -Version ([version]'7.4.0')) | Should -BeTrue
        (Test-WtBootstrapCompatibleVersion -Version ([version]'7.5.3')) | Should -BeTrue
        (Test-WtBootstrapCompatibleVersion -Version ([version]'7.6.9')) | Should -BeTrue

        # Untested, older or future runtimes are never selected automatically.
        (Test-WtBootstrapCompatibleVersion -Version ([version]'7.3.12')) | Should -BeFalse
        (Test-WtBootstrapCompatibleVersion -Version ([version]'7.7.0')) | Should -BeFalse
        (Test-WtBootstrapCompatibleVersion -Version ([version]'8.0.0')) | Should -BeFalse
        (Test-WtBootstrapCompatibleVersion -Version ([version]'5.1.26100.1591')) | Should -BeFalse
        # A preview of a supported version stays a preview.
        (Test-WtBootstrapCompatibleVersion -Version ([version]'7.6.0') -PreRelease '7.6.0-preview.2') | Should -BeFalse
    }

    It 'selects the exact platform asset and rejects ambiguity' {
        . $script:BootstrapPath
        $Key = Get-WtBootstrapPlatformKey
        $Other = if ($Key -like 'linux-*') { 'win-x64' } else { 'linux-x64' }
        $Release = [pscustomobject]@{
            tag_name = 'v1.0.0'
            html_url = 'https://github.com/x/y/releases/tag/v1.0.0'
            assets = @(
                [pscustomobject]@{ name = "WindowsTweaker-$Key-v1.0.0.zip"; browser_download_url = "https://github.com/x/y/releases/download/v1.0.0/WindowsTweaker-$Key-v1.0.0.zip"; size = 100; platform = $Key }
                [pscustomobject]@{ name = "WindowsTweaker-$Other-v1.0.0.zip"; browser_download_url = "https://github.com/x/y/releases/download/v1.0.0/WindowsTweaker-$Other-v1.0.0.zip"; size = 100; platform = $Other }
            )
        }
        $Asset = Get-WtBootstrapAsset -Release $Release
        $Pattern = [regex]::Escape("-$Key-")
        $Asset.name | Should -Match $Pattern

        # Ambiguity: two more candidates for the same platform key.
        $Release.assets += [pscustomobject]@{ name = "WindowsTweaker-$Key-v1.0.1.zip"; browser_download_url = 'https://github.com/x/y/releases/download/v1.0.1/x.zip'; size = 100 }
        $Release.assets += [pscustomobject]@{ name = "WindowsTweaker-$Key.zip"; browser_download_url = 'https://github.com/x/y/releases/download/v1.0.1/y.zip'; size = 100 }
        { Get-WtBootstrapAsset -Release $Release } | Should -Throw
    }

    It 'refuses an asset whose declared platform is not this host platform' {
        . $script:BootstrapPath
        $Key = Get-WtBootstrapPlatformKey
        $Other = if ($Key -like 'linux-*') { 'win-x64' } else { 'linux-x64' }
        $Release = [pscustomobject]@{
            tag_name = 'v1.0.0'
            assets = @([pscustomobject]@{ name = "WindowsTweaker-$Key-v1.0.0.zip"; browser_download_url = 'https://github.com/x/y.zip'; size = 10; platform = $Other })
        }
        { Get-WtBootstrapAsset -Release $Release } | Should -Throw -ExpectedMessage '*declares platform*'
    }

    It 'rejects non-HTTPS and non-allowed hosts' {
        . $script:BootstrapPath
        { Get-WtBootstrapContent -Url 'http://insecure.example/x' } | Should -Throw
        { Get-WtBootstrapContent -Url 'https://evil.example/x' } | Should -Throw
    }

    It 'validates every redirect hop and allows the hosts GitHub actually uses' {
        . $script:BootstrapPath

        (Get-WtBootstrapAllowedHosts) | Should -Contain 'release-assets.githubusercontent.com'
        (Get-WtBootstrapAllowedHosts) | Should -Contain 'objects.githubusercontent.com'
        (Get-WtBootstrapAllowedHosts) | Should -Contain 'github.com'

        $Base = [uri]'https://github.com/88kbleirad/WindowsTweaker/releases/download/v1.0.0/x.zip'
        # The host GitHub redirects release assets to today.
        $Relative = Resolve-WtBootstrapRedirectTarget -Base $Base -Location '/github-production-release-asset/a/b?sp=r' -SourceUrl $Base.AbsoluteUri
        $Relative | Should -Be 'https://github.com/github-production-release-asset/a/b?sp=r'
        $Absolute = Resolve-WtBootstrapRedirectTarget -Base $Base -Location 'https://release-assets.githubusercontent.com/github-production-release-asset/a/b' -SourceUrl $Base.AbsoluteUri
        $Absolute | Should -Be 'https://release-assets.githubusercontent.com/github-production-release-asset/a/b'

        # A redirect to a host that is not on the list, and a downgrade to http, are refused.
        { Resolve-WtBootstrapRedirectTarget -Base $Base -Location 'https://evil.example/x.zip' -SourceUrl $Base.AbsoluteUri } | Should -Throw -ExpectedMessage '*not allowed*'
        { Resolve-WtBootstrapRedirectTarget -Base $Base -Location 'http://release-assets.githubusercontent.com/x' -SourceUrl $Base.AbsoluteUri } | Should -Throw -ExpectedMessage '*non-HTTPS*'
        { Resolve-WtBootstrapRedirectTarget -Base $Base -Location '' -SourceUrl $Base.AbsoluteUri } | Should -Throw -ExpectedMessage '*without Location*'
    }

    It 'fails explicitly when no checksums exist' {
        . $script:BootstrapPath
        $Key = Get-WtBootstrapPlatformKey
        $Release = [pscustomobject]@{ tag_name = 'v1.0.0'; assets = @([pscustomobject]@{ name = "WindowsTweaker-$Key-v1.0.0.zip"; browser_download_url = 'https://github.com/x/y.zip'; size = 10 }) }
        $Asset = Get-WtBootstrapAsset -Release $Release
        (Get-WtBootstrapExpectedHash -Release $Release -Asset $Asset) | Should -Be ''
    }

    It 'hash verification mismatch throws' {
        . $script:BootstrapPath
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes('hello')
        { Test-WtBootstrapHash -Bytes $Bytes -ExpectedHash ('0' * 64) } | Should -Throw
    }

    It 'reads sha256sum text the way the release writes it' {
        . $script:BootstrapPath
        $Text = "e05915e2fe1f76320d8a6d3c51718c16e1607d81de5a7cb0cff0de77d699cfc0  WindowsTweaker-win-x64-v1.0.0.zip`r`n" +
            "0000000000000000000000000000000000000000000000000000000000000000 * WindowsTweaker-linux-x64-v1.0.0.zip`n" +
            "not a checksum line`n"
        $Map = Read-WtBootstrapChecksums -Text $Text
        $Map['windowstweaker-win-x64-v1.0.0.zip'] | Should -Be 'e05915e2fe1f76320d8a6d3c51718c16e1607d81de5a7cb0cff0de77d699cfc0'
        $Map['windowstweaker-linux-x64-v1.0.0.zip'] | Should -Be ('0' * 64)
        $Map.Count | Should -Be 2
    }
}

Describe 'Safe staging and no-bypass release validation' {

    It 'prevents archive path traversal' {
        . $script:BootstrapPath
        $Staging = Join-Path $script:TestRoot 'staging-safe'
        [System.IO.Directory]::CreateDirectory($Staging) | Out-Null

        $Memory = [System.IO.MemoryStream]::new()
        $Archive = [System.IO.Compression.ZipArchive]::new($Memory, 'Create')
        $Entry = $Archive.CreateEntry('../evil.txt')
        $Entry.Open().Dispose()
        $Archive.Dispose()
        $Bytes = $Memory.ToArray()

        { Expand-WtBootstrapArchive -Bytes $Bytes -Staging $Staging } | Should -Throw
        (Test-Path -LiteralPath (Join-Path (Split-Path $Staging -Parent) 'evil.txt')) | Should -BeFalse
    }

    It 'supports paths with spaces and Unicode' {
        . $script:BootstrapPath
        $Dir = Join-Path $script:TestRoot 'spaced dir üñï'
        [System.IO.Directory]::CreateDirectory($Dir) | Out-Null
        $Memory = [System.IO.MemoryStream]::new()
        $Archive = [System.IO.Compression.ZipArchive]::new($Memory, 'Create')
        $Entry = $Archive.CreateEntry('a.txt')
        $Writer = [System.IO.StreamWriter]::new($Entry.Open())
        $Writer.Write('hi'); $Writer.Dispose()
        $Archive.Dispose()
        $Bytes = $Memory.ToArray()

        Expand-WtBootstrapArchive -Bytes $Bytes -Staging $Dir
        (Test-Path -LiteralPath (Join-Path $Dir 'a.txt')) | Should -BeTrue
    }

    It 'requires manifest and key files' {
        . $script:BootstrapPath
        $Staging = Join-Path $script:TestRoot 'staging-invalid'
        [System.IO.Directory]::CreateDirectory($Staging) | Out-Null
        Set-Content -LiteralPath (Join-Path $Staging 'manifest.json') -Value '{}' -Encoding utf8
        { Test-WtBootstrapRelease -Staging $Staging -PlatformKey 'win-x64' } | Should -Throw
    }

    It 'refuses a manifest that is not the canonical worker path for the platform' {
        . $script:BootstrapPath
        $Staging = Join-Path $script:TestRoot 'staging-wrong-worker'
        foreach ($File in @('WindowsTweaker.ps1', 'THIRD-PARTY-NOTICES.md', 'src/WindowsTweaker/WindowsTweaker.psd1', 'worker/bin/windows-amd64/wt-worker.exe')) {
            $Target = Join-Path $Staging ($File -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            [System.IO.Directory]::CreateDirectory((Split-Path $Target -Parent)) | Out-Null
            Set-Content -LiteralPath $Target -Value 'x' -Encoding utf8
        }
        # The old packaging wrote worker/bin/windows-amd64 for a key that reads win-x64; a
        # release that declares it must be refused instead of staged and launched.
        $Manifest = [ordered]@{ schemaVersion = 1; version = '1.0.0'; platform = 'win-x64'; workerProtocol = 1; worker = @{ path = 'worker/bin/win-x64/wt-worker.exe' } }
        Set-Content -LiteralPath (Join-Path $Staging 'manifest.json') -Value ($Manifest | ConvertTo-Json -Depth 4) -Encoding utf8
        { Test-WtBootstrapRelease -Staging $Staging -PlatformKey 'win-x64' } | Should -Throw -ExpectedMessage '*canonical path*'
    }

    It 'refuses a manifest for another platform and one whose declared file hash disagrees' {
        . $script:BootstrapPath
        $Staging = Join-Path $script:TestRoot 'staging-bad-manifest'
        foreach ($File in @('WindowsTweaker.ps1', 'THIRD-PARTY-NOTICES.md', 'src/WindowsTweaker/WindowsTweaker.psd1', 'worker/bin/windows-amd64/wt-worker.exe')) {
            $Target = Join-Path $Staging ($File -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            [System.IO.Directory]::CreateDirectory((Split-Path $Target -Parent)) | Out-Null
            # NoNewline: one byte on every platform, so the manifest's size is right and the
            # hash is the only thing that can disagree.
            Set-Content -LiteralPath $Target -Value 'x' -Encoding utf8 -NoNewline
        }
        $ManifestPath = Join-Path $Staging 'manifest.json'
        $Base = [ordered]@{
            schemaVersion = 1; version = '1.0.0'; platform = 'linux-x64'; workerProtocol = 1
            worker = @{ path = 'worker/bin/windows-amd64/wt-worker.exe' }
            files = @(@{ path = 'WindowsTweaker.ps1'; size = 1; sha256 = ('0' * 64) })
        }
        Set-Content -LiteralPath $ManifestPath -Value ($Base | ConvertTo-Json -Depth 4) -Encoding utf8
        { Test-WtBootstrapRelease -Staging $Staging -PlatformKey 'win-x64' } | Should -Throw -ExpectedMessage '*declares platform*'

        $Base.platform = 'win-x64'
        Set-Content -LiteralPath $ManifestPath -Value ($Base | ConvertTo-Json -Depth 4) -Encoding utf8
        { Test-WtBootstrapRelease -Staging $Staging -PlatformKey 'win-x64' } | Should -Throw -ExpectedMessage '*File hash mismatch*'

        # With -SkipIntegrity the structure still has to be right, but no file is hashed.
        { Test-WtBootstrapRelease -Staging $Staging -PlatformKey 'win-x64' -SkipIntegrity } | Should -Not -Throw
    }

    It 'never reuses a staging directory that did not pass validation' {
        . $script:BootstrapPath
        $State = Join-Path $script:TestRoot 'state-cache'
        $Staging = Join-Path $State 'release-v9.9.9'
        [System.IO.Directory]::CreateDirectory($Staging) | Out-Null
        foreach ($File in @('WindowsTweaker.ps1', 'THIRD-PARTY-NOTICES.md', 'src/WindowsTweaker/WindowsTweaker.psd1', 'worker/bin/windows-amd64/wt-worker.exe')) {
            $Target = Join-Path $Staging ($File -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            [System.IO.Directory]::CreateDirectory((Split-Path $Target -Parent)) | Out-Null
            Set-Content -LiteralPath $Target -Value 'x' -Encoding utf8
        }
        $Manifest = @{ schemaVersion = 1; version = '9.9.9'; platform = 'win-x64'; workerProtocol = 1; worker = @{ path = 'worker/bin/windows-amd64/wt-worker.exe' }; entryPoint = 'WindowsTweaker.ps1' }
        Set-Content -LiteralPath (Join-Path $Staging 'manifest.json') -Value ($Manifest | ConvertTo-Json -Depth 4) -Encoding utf8

        # Files and a manifest alone are not a validated release.
        (Test-WtBootstrapStagingComplete -Staging $Staging) | Should -BeFalse
        (Find-WtBootstrapCache -State $State -PlatformKey 'win-x64') | Should -BeNullOrEmpty

        # The marker is written only after the bootstrap validated the staged release.
        Set-WtBootstrapStagingComplete -Staging $Staging -PlatformKey 'win-x64' -Version '9.9.9'
        (Test-WtBootstrapStagingComplete -Staging $Staging) | Should -BeTrue
        $Found = Find-WtBootstrapCache -State $State -PlatformKey 'win-x64'
        $Found.Tag | Should -Be 'v9.9.9'

        # A cache for another platform is not a cache for this one.
        (Find-WtBootstrapCache -State $State -PlatformKey 'linux-arm64') | Should -BeNullOrEmpty
    }
}

Describe 'No system tweaks by bootstrap' {

    It 'launches the entry point with no arguments and reports its exit code' {
        . $script:BootstrapPath
        $Entry = Join-Path $script:TestRoot 'stub-entry.ps1'
        $Record = Join-Path $script:TestRoot 'stub-args.txt'
        $Stub = @(
            "Set-Content -LiteralPath '$Record' -Value (`$Args.Count.ToString() + '|' + (`$Args -join ',')) -Encoding utf8"
            'exit 7'
        ) -join "`n"
        Set-Content -LiteralPath $Entry -Value $Stub -Encoding utf8

        # Opening the interface applies no tweak, and the bootstrap must not smuggle a switch
        # (-WhatIf, -Id, a preset) into the launch: it starts the entry point bare.
        $Code = Invoke-WtBootstrapLaunch -PwshPath '' -EntryPoint $Entry
        $Code | Should -Be 7
        (Get-Content -LiteralPath $Record -Raw).Trim() | Should -Be '0|'
    }

    It 'preserves the caller options, the working directory and the environment for the child' {
        . $script:BootstrapPath
        $Entry = Join-Path $script:TestRoot 'stub-options.ps1'
        $Record = Join-Path $script:TestRoot 'stub-options.txt'
        # One string value: an array here would make Set-Content write one line per element.
        $Stub = @(
            "`$Value = (`$Args -join '|') + ' :: ' + (Get-Location).Path + ' :: ' + `$env:WT_BOOTSTRAP_HANDOFF"
            "Set-Content -LiteralPath '$Record' -Value `$Value -Encoding utf8"
            'exit 0'
        ) -join "`n"
        Set-Content -LiteralPath $Entry -Value $Stub -Encoding utf8

        $Code = Invoke-WtBootstrapLaunch -PwshPath '' -EntryPoint $Entry -Argument @('-Language', 'vi', '-Colour', 'Mono', '-Ascii') -EnvironmentVariable @{ WT_BOOTSTRAP_HANDOFF = '1' }
        $Code | Should -Be 0
        $Recorded = (Get-Content -LiteralPath $Record -Raw).Trim()
        $Recorded | Should -Match '-Language\|vi\|\-Colour\|Mono\|\-Ascii'
        # The child runs in the caller's working directory, and the handoff marker is visible
        # to it (that is what stops a second chain).
        $Recorded | Should -Match ([regex]::Escape((Get-Location).Path))
        $Recorded | Should -Match ':: 1$'
    }

    It 'quotes arguments that a command line would otherwise split' {
        . $script:BootstrapPath

        (ConvertTo-WtBootstrapArgumentString -Argument @('-NoProfile', '-File', 'C:\Program Files\WindowsTweaker\WindowsTweaker.ps1')) |
            Should -Be '-NoProfile -File "C:\Program Files\WindowsTweaker\WindowsTweaker.ps1"'
        # A trailing backslash before the closing quote must be doubled, an embedded quote escaped.
        (ConvertTo-WtBootstrapArgumentString -Argument @('C:\dir with space\')) | Should -Be '"C:\dir with space\\"'
        (ConvertTo-WtBootstrapArgumentString -Argument @('say "hi"')) | Should -Be '"say \"hi\""'
        (ConvertTo-WtBootstrapArgumentString -Argument @('')) | Should -Be '""'
    }

    It 'writes no app state or settings file, and launches nothing before validation' {
        $env:WT_BOOTSTRAP_STATE_DIR = Join-Path $script:TestRoot 'state-notweak'
        $env:WT_BOOTSTRAP_RELEASE_URL = 'http://invalid.example/bootstrap'
        $env:WT_BOOTSTRAP_ENTRYPOINT = 'C:\nonexistent\entry.ps1'
        Remove-Item Env:\WT_BOOTSTRAP_TEST_ONLY -ErrorAction Ignore
        try {
            # No network (the URL is refused), so nothing can be staged: the entry point is
            # never reached and no tweak can be applied by a bootstrap that only launches.
            { & ([scriptblock]::Create((Get-Content -LiteralPath $script:BootstrapPath -Raw))) 2>$null | Out-Null } | Should -Not -Throw
        } finally {
            Remove-Item Env:\WT_BOOTSTRAP_STATE_DIR, Env:\WT_BOOTSTRAP_RELEASE_URL, Env:\WT_BOOTSTRAP_ENTRYPOINT -ErrorAction Ignore
            $env:WT_BOOTSTRAP_TEST_ONLY = '1'
        }
        $After = @(Get-ChildItem -LiteralPath $script:TestRoot -Recurse -File -ErrorAction Ignore | Where-Object { $_.Name -in 'state.json', 'settings.json' })
        $After.Count | Should -Be 0
    }
}

Describe 'Live GitHub redirect handling' -Skip:(-not $env:WT_BOOTSTRAP_LIVE_TEST) {

    It 'downloads a real release asset through the github.com -> release-assets redirect' {
        . $script:BootstrapPath
        # A ~1.5 KB asset of a public release: the point is the redirect chain, not the payload.
        $Bytes = Get-WtBootstrapContent -Url 'https://github.com/cli/cli/releases/download/v2.0.0/gh_2.0.0_checksums.txt' -MaxBytes 1MB
        $Bytes.Length | Should -BeGreaterThan 0
        ([System.Text.Encoding]::UTF8.GetString($Bytes)) | Should -Match 'gh_2\.0\.0_linux_amd64\.tar\.gz'
    }

    It 'reads real release metadata from the GitHub API' {
        . $script:BootstrapPath
        # Default (no WT_BOOTSTRAP_RELEASE_URL) targets the project repository; it has no
        # release yet, so the API answers 404 and the bootstrap must say so rather than
        # invent one. The success path is therefore exercised against a repository that does
        # have releases, through the same override a self-hosting user would use.
        $env:WT_BOOTSTRAP_RELEASE_URL = 'https://api.github.com/repos/cli/cli/releases/latest'
        try {
            $Topic = Get-WtBootstrapRelease
            $Topic.tag_name | Should -Match '^v?\d+\.'
            @($Topic.assets).Count | Should -BeGreaterThan 0
        } finally {
            Remove-Item Env:\WT_BOOTSTRAP_RELEASE_URL -ErrorAction Ignore
        }
    }

    It 'refuses the project metadata URL while no release is published' {
        . $script:BootstrapPath
        $env:WT_BOOTSTRAP_RELEASE_URL = 'https://api.github.com/repos/88kbleirad/WindowsTweaker/releases/latest'
        try {
            { Get-WtBootstrapRelease } | Should -Throw -ExpectedMessage '*404*'
        } finally {
            Remove-Item Env:\WT_BOOTSTRAP_RELEASE_URL -ErrorAction Ignore
        }
    }
}

Describe 'Compatible pwsh discovery and handoff' {

    BeforeAll {
        . $script:BootstrapPath
        $script:FakeRoot = Join-Path $script:TestRoot 'fake-runtimes'
        [System.IO.Directory]::CreateDirectory($script:FakeRoot) | Out-Null

        # A fake runtime is a PowerShell script that prints the probe line and nothing else;
        # discovery runs it, so a file name alone can never be what selects it.
        function script:New-FakePwsh {
            param ([string]$Name, [string]$Reported, [int]$ExitCode = 0)

            $Path = Join-Path $script:FakeRoot $Name
            $Body = @(
                "Write-Output '$Reported'"
                "exit $ExitCode"
            ) -join "`n"
            Set-Content -LiteralPath $Path -Value $Body -Encoding utf8
            return $Path
        }

        $script:Stable76 = New-FakePwsh -Name 'pwsh-7.6.9.ps1' -Reported '[7.6.9]|Core|AMD64'
        $script:Stable75 = New-FakePwsh -Name 'pwsh-7.5.3.ps1' -Reported '[7.5.3]|Core|AMD64'
        $script:Old73 = New-FakePwsh -Name 'pwsh-7.3.12.ps1' -Reported '[7.3.12]|Core|AMD64'
        $script:Future77 = New-FakePwsh -Name 'pwsh-7.7.0.ps1' -Reported '[7.7.0]|Core|AMD64'
        $script:Preview = New-FakePwsh -Name 'pwsh-7.7.0-preview3.ps1' -Reported '[7.7.0-preview.3]|Core|AMD64'
        $script:Broken = New-FakePwsh -Name 'pwsh-broken.ps1' -Reported 'not a version' -ExitCode 0
        $script:Failing = New-FakePwsh -Name 'pwsh-failing.ps1' -Reported '' -ExitCode 1
    }

    It 'probes the executable instead of trusting its file name' {
        . $script:BootstrapPath

        $Candidate = Read-WtBootstrapPwshCandidate -Path $script:Stable76
        $Candidate.Version | Should -Be ([version]'7.6.9')
        $Candidate.Edition | Should -Be 'Core'
        $Candidate.Compatible | Should -BeTrue
        $Candidate.Selected | Should -BeTrue
        $Candidate.Reason | Should -Match 'Stable'

        $Broken = Read-WtBootstrapPwshCandidate -Path $script:Broken
        $Broken.Compatible | Should -BeFalse
        $Broken.Reason | Should -Match 'Did not report a version'

        $Failing = Read-WtBootstrapPwshCandidate -Path $script:Failing
        $Failing.Compatible | Should -BeFalse
    }

    It 'never selects a preview build or an untested range' {
        . $script:BootstrapPath

        $Preview = Read-WtBootstrapPwshCandidate -Path $script:Preview
        $Preview.Preview | Should -BeTrue
        $Preview.Compatible | Should -BeFalse
        $Preview.Reason | Should -Match 'Preview build'

        (Read-WtBootstrapPwshCandidate -Path $script:Old73).Compatible | Should -BeFalse
        (Read-WtBootstrapPwshCandidate -Path $script:Future77).Compatible | Should -BeFalse
    }

    It 'selects the highest compatible version, preferring PATH order among equals' {
        . $script:BootstrapPath

        $Candidates = @(
            Read-WtBootstrapPwshCandidate -Path $script:Stable75
            Read-WtBootstrapPwshCandidate -Path $script:Stable76
            Read-WtBootstrapPwshCandidate -Path $script:Preview
            Read-WtBootstrapPwshCandidate -Path $script:Old73
        )
        $Best = Select-WtBootstrapPwsh -Candidate $Candidates
        $Best.Path | Should -Be $script:Stable76
        @($Candidates | Where-Object { $_.Selected }).Count | Should -Be 1

        # Same version in two installations: the first one (PATH order) wins.
        $Equal = @(
            Read-WtBootstrapPwshCandidate -Path $script:Stable76
            Read-WtBootstrapPwshCandidate -Path (New-FakePwsh -Name 'pwsh-7.6.9-second.ps1' -Reported '[7.6.9]|Core|AMD64')
        )
        (Select-WtBootstrapPwsh -Candidate $Equal).Path | Should -Be $script:Stable76
    }

    It 'discovers the explicit override and never duplicates one installation' {
        . $script:BootstrapPath

        $SavedOverride = $env:WT_BOOTSTRAP_PWSH
        $env:WT_BOOTSTRAP_PWSH = $script:Stable76
        try {
            # WT_BOOTSTRAP_PWSH is the release-engineering override; it is probed first.
            $Found = @(Get-WtBootstrapPwshCandidates)
            $Found.Count | Should -BeGreaterThan 0
            @($Found | Where-Object { $_.Path -eq $script:Stable76 }).Count | Should -Be 1
        } finally {
            if ($null -eq $SavedOverride) { Remove-Item Env:\WT_BOOTSTRAP_PWSH -ErrorAction Ignore }
            else { $env:WT_BOOTSTRAP_PWSH = $SavedOverride }
        }
    }

    It 'hands off only when the runtime cannot run the requested mode, and never loops' {
        . $script:BootstrapPath

        $Entry = Join-Path $script:TestRoot 'stub-handoff.ps1'
        Set-Content -LiteralPath $Entry -Value 'exit 0' -Encoding utf8

        Mock Select-WtBootstrapPwsh { $null }
        Mock Invoke-WtBootstrapLaunch { 0 }
        Mock Get-WtBootstrapPwshCandidates { @() }
        Mock Invoke-WtBootstrapInstallOffer { $null }

        # On a supported PowerShell 7 runtime there is no second process at all.
        Mock Get-WtBootstrapRuntimeProfile { [pscustomobject]@{ Version = [version]'7.6.9'; Tier = 'Supported'; IsCore = $true; Platform = 'Windows'; MinimumVersion = [version]'5.1'; SupportedVersion = [version]'7.4' } }
        Invoke-WtBootstrapApplication -EntryPoint $Entry -Mode 'auto' -NoInstall | Should -Be 0
        Should -Invoke Select-WtBootstrapPwsh -Times 0

        # Windows PowerShell 5.1: a compatible runtime is looked for and used.
        Mock Get-WtBootstrapRuntimeProfile { [pscustomobject]@{ Version = [version]'5.1.26100.1591'; Tier = 'WindowsPowerShell'; IsCore = $false; Platform = 'Windows'; MinimumVersion = [version]'5.1'; SupportedVersion = [version]'7.4' } }
        Mock Select-WtBootstrapPwsh { [pscustomobject]@{ Path = 'C:\Program Files\PowerShell\7\pwsh.exe'; Version = [version]'7.6.9' } }
        Mock Invoke-WtBootstrapLaunch { 0 }
        Invoke-WtBootstrapApplication -EntryPoint $Entry -Mode 'auto' -NoInstall | Should -Be 0
        Should -Invoke Select-WtBootstrapPwsh -Times 1
        Should -Invoke Invoke-WtBootstrapLaunch -Times 1 -ParameterFilter { $PwshPath -like '*PowerShell\7\pwsh.exe' }

        # A handoff that already happened (or a chain that is too deep) runs natively and
        # never starts another chain.
        Mock Select-WtBootstrapPwsh { $null } -ParameterFilter { $false }
        $SavedHandoff = $env:WT_BOOTSTRAP_HANDOFF
        $SavedDepth = $env:WT_BOOTSTRAP_DEPTH
        $env:WT_BOOTSTRAP_HANDOFF = '1'
        $env:WT_BOOTSTRAP_DEPTH = '1'
        try {
            Mock Select-WtBootstrapPwsh { throw 'Discovery must not run after a handoff.' }
            Invoke-WtBootstrapApplication -EntryPoint $Entry -Mode 'auto' -NoInstall | Should -Be 0
        } finally {
            if ($null -eq $SavedHandoff) { Remove-Item Env:\WT_BOOTSTRAP_HANDOFF -ErrorAction Ignore } else { $env:WT_BOOTSTRAP_HANDOFF = $SavedHandoff }
            if ($null -eq $SavedDepth) { Remove-Item Env:\WT_BOOTSTRAP_DEPTH -ErrorAction Ignore } else { $env:WT_BOOTSTRAP_DEPTH = $SavedDepth }
        }

        # WT_BOOTSTRAP_RUNTIME=native never discovers anything.
        Mock Select-WtBootstrapPwsh { throw 'Discovery must not run in native mode.' }
        Invoke-WtBootstrapApplication -EntryPoint $Entry -Mode 'native' -NoInstall | Should -Be 0
    }

    It 'fails with the manual instructions when a runtime is required and none exists' {
        . $script:BootstrapPath

        $Entry = Join-Path $script:TestRoot 'stub-required.ps1'
        Set-Content -LiteralPath $Entry -Value 'exit 0' -Encoding utf8

        Mock Get-WtBootstrapRuntimeProfile { [pscustomobject]@{ Version = [version]'5.1.26100.1591'; Tier = 'WindowsPowerShell'; IsCore = $false; Platform = 'Windows'; MinimumVersion = [version]'5.1'; SupportedVersion = [version]'7.4' } }
        Mock Select-WtBootstrapPwsh { $null }
        Mock Invoke-WtBootstrapInstallOffer { $null }
        Mock Write-WtBootstrapMessage { }

        # Mode 'pwsh' is explicit: no silent native fallback.
        Invoke-WtBootstrapApplication -EntryPoint $Entry -Mode 'pwsh' -NoInstall | Should -Be 3
        Should -Invoke Write-WtBootstrapMessage -Times 1 -ParameterFilter { $Name -eq 'PwshRequired' }
        Should -Invoke Write-WtBootstrapMessage -Times 1 -ParameterFilter { $Name -eq 'ManualInstall' }
    }
}

Describe 'Missing runtime: installation offer' {

    BeforeAll {
        . $script:BootstrapPath
        $script:InstallRoot = Join-Path $script:TestRoot 'fake-install'
        [System.IO.Directory]::CreateDirectory($script:InstallRoot) | Out-Null

        # A fake winget records its arguments and exits with the scripted code.
        function script:New-FakeWinget {
            param ([string]$Name, [int]$ExitCode)

            $Path = Join-Path $script:InstallRoot $Name
            $Log = Join-Path $script:InstallRoot ($Name + '.args')
            $Body = @(
                "Set-Content -LiteralPath '$Log' -Value (@(`$Args -join ' ')) -Encoding utf8"
                "exit $ExitCode"
            ) -join "`n"
            Set-Content -LiteralPath $Path -Value $Body -Encoding utf8
            return $Path
        }

        $script:WingetOk = New-FakeWinget -Name 'winget-ok.ps1' -ExitCode 0
        $script:WingetFail = New-FakeWinget -Name 'winget-fail.ps1' -ExitCode 1
        $script:WingetCancel = New-FakeWinget -Name 'winget-cancel.ps1' -ExitCode 0
        $script:Compatible = [pscustomobject]@{ Path = 'C:\Program Files\PowerShell\7\pwsh.exe'; Version = [version]'7.6.9'; Selected = $true; Compatible = $true }

        Mock Get-WtBootstrapRuntimeProfile { [pscustomobject]@{ Version = [version]'5.1.26100.1591'; Tier = 'WindowsPowerShell'; IsCore = $false; Platform = 'Windows'; MinimumVersion = [version]'5.1'; SupportedVersion = [version]'7.4' } }
    }

    It 'prints the manual alternative when winget is unavailable (LTSC, Server Core)' {
        . $script:BootstrapPath

        Mock Find-WtBootstrapWinget { $null }
        Mock Read-Host { throw 'Read-Host must not be called without winget.' }
        Mock Write-WtBootstrapMessage { }

        Invoke-WtBootstrapInstallOffer | Should -BeNullOrEmpty
        Should -Invoke Write-WtBootstrapMessage -Times 1 -ParameterFilter { $Name -eq 'WingetMissing' }
        Should -Invoke Write-WtBootstrapMessage -Times 1 -ParameterFilter { $Name -eq 'ManualInstall' }
        Should -Invoke Read-Host -Times 0
    }

    It 'installs only after an explicit yes, and finds the executable without trusting PATH' {
        . $script:BootstrapPath

        Mock Find-WtBootstrapWinget { $script:WingetOk }
        Mock Read-Host { 'y' }
        Mock Get-WtBootstrapPwshCandidates { @($script:Compatible) }
        Mock Write-WtBootstrapMessage { }

        $Result = Invoke-WtBootstrapInstallOffer
        $Result.Path | Should -Be $script:Compatible.Path

        $Recorded = [System.IO.File]::ReadAllText((Join-Path $script:InstallRoot 'winget-ok.ps1.args'))
        # Official source, exact id, no interactive prompts, contracts accepted: the command
        # the user consented to, and nothing beyond it.
        $Recorded | Should -Match 'install'
        $Recorded | Should -Match '--id Microsoft.PowerShell'
        $Recorded | Should -Match '--exact'
        $Recorded | Should -Match '--source winget'
        $Recorded | Should -Match '--accept-package-agreements'
    }

    It 'cancels cleanly when the user declines' {
        . $script:BootstrapPath

        Mock Find-WtBootstrapWinget { $script:WingetCancel }
        Mock Read-Host { 'n' }
        Mock Write-WtBootstrapMessage { }

        Invoke-WtBootstrapInstallOffer | Should -BeNullOrEmpty
        Should -Invoke Write-WtBootstrapMessage -Times 1 -ParameterFilter { $Name -eq 'InstallCancelled' }
        # Declining never runs the installer.
        (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'winget-cancel.ps1.args')) | Should -BeFalse
    }

    It 'reports a failed installation and returns to the shell' {
        . $script:BootstrapPath

        Mock Find-WtBootstrapWinget { $script:WingetFail }
        Mock Read-Host { 'y' }
        Mock Write-WtBootstrapMessage { }

        Invoke-WtBootstrapInstallOffer | Should -BeNullOrEmpty
        Should -Invoke Write-WtBootstrapMessage -Times 1 -ParameterFilter { $Name -eq 'InstallFailed' }
        Should -Invoke Write-WtBootstrapMessage -Times 1 -ParameterFilter { $Name -eq 'ManualInstall' }
    }

    It 'does not offer an installation when the caller disabled it' {
        . $script:BootstrapPath

        Mock Find-WtBootstrapWinget { $script:WingetOk }
        Mock Read-Host { throw 'No prompt when installation is disabled.' }
        Mock Write-WtBootstrapMessage { }

        Invoke-WtBootstrapInstallOffer -NoInstall | Should -BeNullOrEmpty
        Should -Invoke Write-WtBootstrapMessage -Times 1 -ParameterFilter { $Name -eq 'ManualInstall' }
    }
}

Describe 'Error classification' {

    It 'classifies download, integrity, package, launch and runtime failures separately' {
        . $script:BootstrapPath

        # NETWORK: refused before any request (non-HTTPS, unknown host).
        { Get-WtBootstrapContent -Url 'http://invalid.example/x' } | Should -Throw -ExpectedMessage 'NETWORK:*'
        { Get-WtBootstrapContent -Url 'https://evil.example/x' } | Should -Throw -ExpectedMessage 'NETWORK:*'

        # INTEGRITY: a hash mismatch is not a network problem.
        { Test-WtBootstrapHash -Bytes ([byte[]](1, 2, 3)) -ExpectedHash ('0' * 64) } | Should -Throw -ExpectedMessage 'INTEGRITY:*'

        # PACKAGE: a release without an asset for this platform.
        $Release = [pscustomobject]@{ tag_name = 'v1.0.0'; assets = @([pscustomobject]@{ name = 'WindowsTweaker-win-arm64-v1.0.0.zip'; browser_download_url = 'https://github.com/x/y.zip'; size = 10 }) }
        { Get-WtBootstrapAsset -Release $Release } | Should -Throw -ExpectedMessage 'PACKAGE:*'

        # LAUNCH: a missing entry point.
        { Invoke-WtBootstrapLaunch -PwshPath '' -EntryPoint (Join-Path $script:TestRoot 'nope.ps1') } | Should -Throw -ExpectedMessage 'LAUNCH:*'

        # RUNTIME: below the floor.
        { Assert-WtBootstrapRuntime -Version ([version]'4.0.30319.0') } | Should -Throw -ExpectedMessage 'RUNTIME:*'
    }

    It 'leaves the session alive and mirrors the code when the entry block fails' {
        $Text = Get-Content -LiteralPath $script:BootstrapPath -Raw
        $StateDir = Join-Path $script:TestRoot 'state-classified'
        $env:WT_BOOTSTRAP_STATE_DIR = $StateDir
        $env:WT_BOOTSTRAP_RELEASE_URL = 'http://invalid.example/bootstrap'
        $env:WT_BOOTSTRAP_ENTRYPOINT = 'C:\nonexistent\entry.ps1'
        $env:WT_BOOTSTRAP_NO_INSTALL = '1'
        Remove-Item Env:\WT_BOOTSTRAP_TEST_ONLY -ErrorAction Ignore
        try {
            $global:LASTEXITCODE = 0
            $Thrown = $null
            $Output = @()
            try {
                $Output = @(& ([scriptblock]::Create($Text)) 2>&1)
            } catch {
                $Thrown = $_
            }
            $Thrown | Should -BeNullOrEmpty
            $LASTEXITCODE | Should -Be 1
            # The failure is classified, and nothing is returned on the pipeline (the "1" that
            # used to be printed after the error is gone).
            (($Output | ForEach-Object { [string]$_ }) -join "`n") | Should -Match 'NETWORK:'
            $PipelineValues = @($Output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] -and ([string]$_).Trim() })
            $PipelineValues.Count | Should -Be 0
        } finally {
            Remove-Item Env:\WT_BOOTSTRAP_STATE_DIR, Env:\WT_BOOTSTRAP_RELEASE_URL, Env:\WT_BOOTSTRAP_ENTRYPOINT, Env:\WT_BOOTSTRAP_NO_INSTALL -ErrorAction Ignore
            $env:WT_BOOTSTRAP_TEST_ONLY = '1'
        }
    }
}
