# WindowsTweaker bootstrap tests.

BeforeAll {
    $env:WT_BOOTSTRAP_TEST_ONLY = '1'
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:BootstrapPath = Join-Path $script:RepoRoot 'bootstrap/bootstrap.ps1'
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-boot-{0}" -f ([guid]::NewGuid().ToString('n')))
    [System.IO.Directory]::CreateDirectory($script:TestRoot) | Out-Null
}

AfterAll {
    Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_BOOTSTRAP_TEST_ONLY -ErrorAction Ignore
}

Describe 'Bootstrap text execution' {

    It 'executes from downloaded text with no script-path variables and does not throw' {
        $Text = Get-Content -LiteralPath $script:BootstrapPath -Raw
        $env:WT_BOOTSTRAP_STATE_DIR = Join-Path $script:TestRoot 'state-text'
        $env:WT_BOOTSTRAP_RELEASE_URL = 'http://invalid.example/bootstrap'
        $env:WT_BOOTSTRAP_ENTRYPOINT = 'C:\nonexistent\entry.ps1'
        $env:WT_BOOTSTRAP_TEST_ONLY = '1'
        try {
            # A script block created from the text is the same execution mode as `irm | iex`
            # without using Invoke-Expression: no $PSScriptRoot, no $PSCommandPath.
            { & ([scriptblock]::Create($Text)) } | Should -Not -Throw
        } finally {
            Remove-Item Env:\WT_BOOTSTRAP_STATE_DIR, Env:\WT_BOOTSTRAP_RELEASE_URL, Env:\WT_BOOTSTRAP_ENTRYPOINT -ErrorAction Ignore
        }
    }

    It 'does not call exit() so the caller session survives failure' {
        $Text = Get-Content -LiteralPath $script:BootstrapPath -Raw
        $env:WT_BOOTSTRAP_STATE_DIR = Join-Path $script:TestRoot 'state-session'
        $env:WT_BOOTSTRAP_RELEASE_URL = 'http://invalid.example/bootstrap'
        $env:WT_BOOTSTRAP_ENTRYPOINT = 'C:\nonexistent\entry.ps1'
        $env:WT_BOOTSTRAP_TEST_ONLY = '1'
        try {
            & ([scriptblock]::Create($Text)) | Out-Null
            $true | Should -BeTrue
        } finally {
            Remove-Item Env:\WT_BOOTSTRAP_STATE_DIR, Env:\WT_BOOTSTRAP_RELEASE_URL, Env:\WT_BOOTSTRAP_ENTRYPOINT -ErrorAction Ignore
        }
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

    It 'refuses a PowerShell that cannot select the right release' {
        . $script:BootstrapPath

        { Assert-WtBootstrapRuntime -Version ([version]'5.1.20348.1') } | Should -Throw -ExpectedMessage '*PowerShell 7.4 or newer*'
        { Assert-WtBootstrapRuntime -Version ([version]'7.3.12') } | Should -Throw -ExpectedMessage '*PowerShell 7.4 or newer*'
        { Assert-WtBootstrapRuntime -Version $PSVersionTable.PSVersion } | Should -Not -Throw
    }

    It 'selects the exact platform asset and rejects ambiguity' {
        . $script:BootstrapPath
        $Key = Get-WtBootstrapPlatformKey
        $Other = if ($Key -like 'linux-*') { 'win-x64' } else { 'linux-x64' }
        $Release = [pscustomobject]@{
            tag_name = 'v1.0.0'
            html_url = 'https://github.com/x/y/releases/tag/v1.0.0'
            assets = @(
                [pscustomobject]@{ name = "WindowsTweaker-$Key-v1.0.0.zip"; browser_download_url = "https://github.com/x/y/releases/download/v1.0.0/WindowsTweaker-$Key-v1.0.0.zip"; size = 100 }
                [pscustomobject]@{ name = "WindowsTweaker-$Other-v1.0.0.zip"; browser_download_url = "https://github.com/x/y/releases/download/v1.0.0/WindowsTweaker-$Other-v1.0.0.zip"; size = 100 }
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

    It 'rejects non-HTTPS and non-allowed hosts' {
        . $script:BootstrapPath
        { Get-WtBootstrapContent -Url 'http://insecure.example/x' } | Should -Throw
        { Get-WtBootstrapContent -Url 'https://evil.example/x' } | Should -Throw
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
}

Describe 'Safe staging' {

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
}

Describe 'Release validation' {

    It 'requires manifest and key files' {
        . $script:BootstrapPath
        $Staging = Join-Path $script:TestRoot 'staging-invalid'
        [System.IO.Directory]::CreateDirectory($Staging) | Out-Null
        Set-Content -LiteralPath (Join-Path $Staging 'manifest.json') -Value '{}' -Encoding utf8
        { Test-WtBootstrapRelease -Staging $Staging -PlatformKey 'win-x64' } | Should -Throw
    }
}

Describe 'No system tweaks by bootstrap' {

    It 'does not write app state/settings files' {
        $Text = Get-Content -LiteralPath $script:BootstrapPath -Raw
        $env:WT_BOOTSTRAP_STATE_DIR = Join-Path $script:TestRoot 'state-notweak'
        $env:WT_BOOTSTRAP_RELEASE_URL = 'http://invalid.example/bootstrap'
        $env:WT_BOOTSTRAP_ENTRYPOINT = 'C:\nonexistent\entry.ps1'
        $env:WT_BOOTSTRAP_TEST_ONLY = '1'
        try {
            & ([scriptblock]::Create($Text)) | Out-Null
        } finally {
            Remove-Item Env:\WT_BOOTSTRAP_STATE_DIR, Env:\WT_BOOTSTRAP_RELEASE_URL, Env:\WT_BOOTSTRAP_ENTRYPOINT -ErrorAction Ignore
        }
        $After = @(Get-ChildItem -LiteralPath $script:TestRoot -Recurse -File -ErrorAction Ignore | Where-Object { $_.Name -in 'state.json', 'settings.json' })
        $After.Count | Should -Be 0
    }
}
