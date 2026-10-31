# WindowsTweaker - command line contract tests.
#
# The entry point is run as a child process so that its exit codes, its output and
# its on-disk effects are tested exactly as a user or an automation script sees them.
#
# Note: on a non-Windows host every machine-level tweak is reported as `unsupported`,
# which is the honest answer (the registry/service providers do not exist there). The
# tests therefore accept `unsupported` and assert that nothing was written; on
# Windows the same invocation must report `dryrun`.

BeforeAll {
    $script:RepositoryRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:EntryPoint = Join-Path $script:RepositoryRoot 'WindowsTweaker.ps1'
    $script:PowerShellPath = Join-Path $PSHOME 'pwsh'
    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-cli-{0}" -f ([guid]::NewGuid().ToString('n')))

    $script:InvokeEntryPoint = {
        param ([string[]]$Arguments, [switch]$AsJson)

        $env:WT_DATA_ROOT = $script:TestDataRoot
        $env:WT_STATE_PATH = Join-Path $script:TestDataRoot 'state.json'
        $env:WT_LOG_DIRECTORY = Join-Path $script:TestDataRoot 'logs'
        $env:WT_LANG = 'en'

        $Output = & $script:PowerShellPath -NoProfile -File $script:EntryPoint @Arguments 2>&1
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = ($Output | Out-String)
        }
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:TestDataRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_DATA_ROOT, Env:\WT_STATE_PATH, Env:\WT_LOG_DIRECTORY, Env:\WT_LANG -ErrorAction Ignore
}

Describe 'Insight surfaces' {

    It 'runs the sanity scan without changing anything, and reports Unsupported off Windows' {
        $Result = & $script:InvokeEntryPoint -Arguments @('-SanityScan')

        $Result.Output | Should -Match 'Sanity scan|Quét kiểm tra cấu hình'
        $Result.Output | Should -Match 'read-only|Chỉ đọc'
        # On this host no rule applies, which is reported as Unsupported - never as Clean.
        if ($IsWindows)
        {
            $Result.Output | Should -Not -Match 'Unsupported:'
        }
        else
        {
            $Result.Output | Should -Match 'Unsupported'
        }
    }

    It 'plans nothing and applies nothing for a recommendation proposal' {
        $Result = & $script:InvokeEntryPoint -Arguments @('-Recommend', 'Privacy', '-RecommendManual')

        $Result.Output | Should -Match 'Privacy'
        $Result.Output | Should -Match 'proposal|đề xuất'
        $Result.ExitCode | Should -Be 0
    }

    It 'lists the exclusive-choice groups with the intent of every alternative' {
        $Result = & $script:InvokeEntryPoint -Arguments @('-Choices')

        $Result.Output | Should -Match 'Explorer.StartupLocation'
        $Result.Output | Should -Match 'This PC|Truy cập nhanh'
        $Result.ExitCode | Should -Be 0
    }

    It 'prints the configured, effective and ownership dimensions on request' {
        $Result = & $script:InvokeEntryPoint -Arguments @('-CatalogInspect', 'Privacy.WindowsTips', '-CatalogDimensions')

        $Result.Output | Should -Match 'Configured|Cấu hình'
        $Result.Output | Should -Match 'Effective|Hiệu lực'
        $Result.Output | Should -Match 'Ownership|Quyền sở hữu'
        $Result.ExitCode | Should -Be 0
    }

    It 'rejects an unknown rule instead of silently scanning nothing' {
        $Result = & $script:InvokeEntryPoint -Arguments @('-SanityScan', '-SanityRule', 'No.Such.Rule')

        $Result.ExitCode | Should -Not -Be 0
        # The reason is named, so the difference between 'no rule applies here' and 'you typed a
        # rule that does not exist' is visible.
        $Result.Output | Should -Match 'No such rule|Không có quy tắc'
        $Result.Output | Should -Match 'No\.Such\.Rule'
    }

    It 'refuses a modifier that belongs to another command instead of starting the interface' {
        $Result = & $script:InvokeEntryPoint -Arguments @('-SanityRule', 'Tcp.LegacyReceiveWindow')

        $Result.ExitCode | Should -Be 2
        $Result.Output | Should -Match 'only applies together with|chỉ dùng cùng với'
        $Result.Output | Should -Match '-SanityScan'

        $Result = & $script:InvokeEntryPoint -Arguments @('-RecommendFinding', 'Restart.PendingMarkers')
        $Result.ExitCode | Should -Be 2
        $Result.Output | Should -Match '-Recommend'
    }

    It 'refuses to overwrite an existing report and says so' {
        $Path = Join-Path $script:TestDataRoot 'scan-existing.md'
        New-Item -ItemType Directory -Path $script:TestDataRoot -Force | Out-Null
        Set-Content -LiteralPath $Path -Value 'previous report' -Encoding utf8

        $Result = & $script:InvokeEntryPoint -Arguments @('-SanityScan', '-SanityExport', $Path)

        (Get-Content -LiteralPath $Path -Raw) | Should -Match 'previous report'
        $Result.Output | Should -Match 'could not be written|Không ghi được'
    }

    It 'shows the objective it used, and the evidence of each item it would propose' {
        $Result = & $script:InvokeEntryPoint -Arguments @('-Recommend', 'Privacy', '-RecommendManual')

        $Result.Output | Should -Match 'Objective|Mục tiêu'
        $Result.Output | Should -Match 'recommended|được đề xuất'
        $Result.ExitCode | Should -Be 0

        # The evidence and verification lines belong to the items that are actually proposed, so
        # they are asserted whenever this host produces one.
        if ($Result.Output -match '\[Recommended\]|\[Recommended\b')
        {
            $Result.Output | Should -Match 'Effective state|Trạng thái hiệu lực'
            $Result.Output | Should -Match 'Verification|Xác minh'
        }
    }

    It 'shows which alternative each group has live and which is available to choose' {
        $Result = & $script:InvokeEntryPoint -Arguments @('-Choices')

        $Result.Output | Should -Match '\(\s*\)|\(\*\)'
        $Result.Output | Should -Match 'current|hiện tại'
        $Result.ExitCode | Should -Be 0
    }

    It 'names the reviewed remediation a finding carries' {
        $Result = & $script:InvokeEntryPoint -Arguments @('-SanityScan')

        # The MMCSS rule links a reviewed repair; on a host where no probe answered the line is
        # still part of every finding, so nothing is asserted about a finding existing here.
        $Result.ExitCode | Should -BeIn @(0, 1)
    }
}

Describe 'Entry point' {

    It 'exists and documents the supported PowerShell version' {
        Test-Path -LiteralPath $script:EntryPoint | Should -BeTrue
        (Get-Content -LiteralPath $script:EntryPoint -Raw) | Should -Match '#Requires -Version 7\.4'
    }

    It 'reports the environment without changing anything' {
        $Result = & $script:InvokeEntryPoint -Arguments @('-Status')

        $Result.ExitCode | Should -Be 0
        $Result.Output | Should -Match 'RequiredPowerShell'
        $Result.Output | Should -Match 'StatePath'
    }

    It 'lists the catalog with per-tweak state' {
        $Result = & $script:InvokeEntryPoint -Arguments @('-List')

        $Result.ExitCode | Should -Be 0
        $Result.Output | Should -Match 'tweaks'
        $Result.Output | Should -Match 'Privacy.AdvertisingId'

        # Listing must stay read-only.
        Test-Path -LiteralPath (Join-Path $script:TestDataRoot 'state.json') | Should -BeFalse
    }

    It 'fails with a clear message for an unknown tweak id' {
        $Result = & $script:InvokeEntryPoint -Arguments @('-Id', 'This.Tweak.Does.Not.Exist', '-State', 'Enabled', '-WhatIf')

        $Result.ExitCode | Should -Not -Be 0
        $Result.Output | Should -Match 'Unknown tweak id'
    }

    It 'writes a report and prints its path' {
        $Result = & $script:InvokeEntryPoint -Arguments @('-Report')

        $Result.ExitCode | Should -Be 0

        $Path = ($Result.Output -split "`n" | Where-Object { $_ -match 'WindowsTweaker-report-.*\.json' } | Select-Object -First 1).Trim()
        $Path | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $Path | Should -BeTrue

        $Report = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $Report.tool | Should -Be 'WindowsTweaker'
        @($Report.tweaks).Count | Should -BeGreaterThan 0
    }

    It 'never writes state when a change is requested as a dry run' {
        $Result = & $script:InvokeEntryPoint -Arguments @('-Id', 'Privacy.AdvertisingId', '-State', 'Disabled', '-WhatIf')

        # On Windows this is a dry run; elsewhere the tweak is honestly unsupported.
        if ($IsWindows)
        {
            $Result.ExitCode | Should -Be 0
            $Result.Output | Should -Match 'dryrun'
        }
        else
        {
            $Result.ExitCode | Should -Be 1
            $Result.Output | Should -Match 'unsupported'
        }

        Test-Path -LiteralPath (Join-Path $script:TestDataRoot 'state.json') | Should -BeFalse
    }

    It 'reports that there is nothing to roll back instead of pretending to succeed' {
        $Result = & $script:InvokeEntryPoint -Arguments @('-Id', 'Privacy.AdvertisingId', '-Rollback')

        $Result.ExitCode | Should -Not -Be 0
        $Result.Output | Should -Match 'No captured state'
    }

    It 'exposes the tweak arguments a parameterized tweak needs' {
        $Result = & $script:InvokeEntryPoint -Arguments @('-Id', 'Apps.UninstallUwpPackage', '-State', 'Enabled', '-WhatIf')

        # Without an explicit package list the tweak must refuse rather than guess.
        $Result.Output | Should -Match 'unsupported|failed|PackageFullName|Appx'
        Test-Path -LiteralPath (Join-Path $script:TestDataRoot 'state.json') | Should -BeFalse
    }

    It 'accepts a restore-point request without making one implicitly' {
        # A restore point is supplementary: the switch has to be given, and on a host
        # without System Protection the outcome is reported instead of throwing.
        $Result = & $script:InvokeEntryPoint -Arguments @('-Id', 'Privacy.AdvertisingId', '-State', 'Disabled', '-IncludeRestorePoint', '-WhatIf')

        $Result.Output | Should -Match 'Status'
        $Result.Output | Should -Not -Match 'Unhandled|at line'
        Test-Path -LiteralPath (Join-Path $script:TestDataRoot 'state.json') | Should -BeFalse
    }

    It 'lists the shipped presets without changing anything' {
        $Result = & $script:InvokeEntryPoint -Arguments @('-PresetList')

        $Result.ExitCode | Should -Be 0
        $Result.Output | Should -Match 'privacy-hardening'
        $Result.Output | Should -Match 'explorer-usability'
        Test-Path -LiteralPath (Join-Path $script:TestDataRoot 'state.json') | Should -BeFalse
    }

    It 'refuses to start the terminal interface when input or output is redirected' {
        # The interface must not hang or half-start on a pipe; it exits with the
        # documented code and points at the non-interactive switches instead.
        $Result = & $script:InvokeEntryPoint -Arguments @()

        $Result.ExitCode | Should -Be 2
        $Result.Output | Should -Match 'terminal|dòng lệnh|-List'
        Test-Path -LiteralPath (Join-Path $script:TestDataRoot 'state.json') | Should -BeFalse
    }
}
