# WindowsTweaker - runtime compatibility tests.
#
# These tests run on PowerShell 7 and assert the properties that make Windows PowerShell
# 5.1 support real: one compatibility layer, one JSON shape, BOM-less runtime files, a BOM
# policy for sources, the documented runtime range, and a bootstrap whose discovery
# classifies a candidate exactly like the module does. They cannot prove how a console or a
# registry call behaves on a real 5.1 host; docs/COMPATIBILITY.md marks those rows unexecuted.

BeforeAll {
    $env:WT_BOOTSTRAP_TEST_ONLY = '1'
    $script:RepositoryRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:ModuleManifest = Join-Path $script:RepositoryRoot 'src/WindowsTweaker/WindowsTweaker.psd1'
    $script:EntryPoint = Join-Path $script:RepositoryRoot 'WindowsTweaker.ps1'
    # The bootstrap implementation, not the published launcher: the launcher is ASCII-only and
    # only loads this file, while the runtime-discovery helpers compared below live in it.
    $script:BootstrapPath = Join-Path $script:RepositoryRoot 'bootstrap/implementation.ps1'
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-compat-{0}" -f ([guid]::NewGuid().ToString('n')))
    [System.IO.Directory]::CreateDirectory($script:TestRoot) | Out-Null

    Import-Module $script:ModuleManifest -Force

    # The compatibility layer is a self-contained private file: dot-sourcing it makes the
    # helpers directly testable, exactly as tests/Bootstrap.Tests.ps1 dot-sources the
    # bootstrap. The module-scoped integration (the report, which needs Get-WtString) is
    # exercised through InModuleScope below.
    . (Join-Path $script:RepositoryRoot 'src/WindowsTweaker/Private/Compatibility.ps1')
}

AfterAll {
    Remove-Module WindowsTweaker -Force -ErrorAction Ignore
    Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_BOOTSTRAP_TEST_ONLY -ErrorAction Ignore
}

Describe 'Runtime profile and policy' {

    It 'reports the running runtime, its platform and its tier' {
        $RuntimeProfile = Get-WtRuntimeProfile

        $RuntimeProfile.Version | Should -Be $PSVersionTable.PSVersion
        $RuntimeProfile.PSEdition | Should -Be $PSVersionTable.PSEdition
        $RuntimeProfile.IsCore | Should -Be ($PSVersionTable.PSEdition -eq 'Core')
        $RuntimeProfile.MinimumVersion | Should -Be ([version]'5.1')
        $RuntimeProfile.SupportedVersion | Should -Be ([version]'7.4')
        $RuntimeProfile.TestedRange.Minimum | Should -Be ([version]'7.4')
        $RuntimeProfile.TestedRange.Maximum | Should -Be ([version]'7.6')
        $RuntimeProfile.TestedRange.Tested | Should -Be ([version]'7.6.9')

        # One of the three platforms must be true, and exactly one.
        @(@($RuntimeProfile.IsWindows, $RuntimeProfile.IsLinux, $RuntimeProfile.IsMacOS) | Where-Object { $_ }).Count | Should -Be 1
        (Test-WtIsWindows) | Should -Be ([bool]$RuntimeProfile.IsWindows)
        (Test-WtIsLinux) | Should -Be ([bool]$RuntimeProfile.IsLinux)

        # The profile is cached, and Refresh re-probes.
        (Get-WtRuntimeProfile) | Should -Be $RuntimeProfile
    }

    It 'puts this runtime in the right tier' {
        $RuntimeProfile = Get-WtRuntimeProfile
        $Expected = if (-not $RuntimeProfile.IsCore) { 'WindowsPowerShell' }
            elseif ($RuntimeProfile.Version -ge [version]'7.4' -and $RuntimeProfile.Version -lt [version]'7.7') { 'Supported' }
            else { 'Untested' }
        $RuntimeProfile.Tier | Should -Be $Expected
    }

    It 'compares versions without failing on strings' {
        (Test-WtPowerShellVersion -Version ([version]'5.1.26100.1591') -Minimum ([version]'5.1')) | Should -BeTrue
        (Test-WtPowerShellVersion -Version ([version]'7.4.0') -Minimum ([version]'7.4')) | Should -BeTrue
        (Test-WtPowerShellVersion -Version ([version]'7.3.12') -Minimum ([version]'7.4')) | Should -BeFalse
    }

    It 'states every capability with a reason, and refuses an unknown one' {
        $Capabilities = @(Get-WtRuntimeCapabilityList)
        $Capabilities.Count | Should -BeGreaterThan 5
        foreach ($Capability in $Capabilities)
        {
            $Capability.Name | Should -Not -BeNullOrEmpty
            $Capability.Reason | Should -Not -BeNullOrEmpty
            $Capability.Runtime | Should -Be ([string]$PSVersionTable.PSVersion)
        }

        # These are the capabilities the port made runtime-independent, so they must be true
        # on every supported runtime rather than only here.
        (Test-WtRuntimeCapability -Name 'Utf8NoBomFile') | Should -BeTrue
        (Test-WtRuntimeCapability -Name 'JsonAsHashtable') | Should -BeTrue
        (Test-WtRuntimeCapability -Name 'StrictJsonDocument') | Should -BeTrue
        (Test-WtRuntimeCapability -Name 'StandardInputEncoding') | Should -BeTrue
        (Test-WtRuntimeCapability -Name 'GoWorker') | Should -BeTrue

        { Test-WtRuntimeCapability -Name 'NoSuchCapability' } | Should -Throw -ExpectedMessage '*Unknown runtime capability*'
    }

    It 'prints a runtime report with the profile and the capabilities' {
        # Module scope: the report is localized, and Get-WtString lives in the module.
        $Report = InModuleScope WindowsTweaker -Parameters @{ EntryPoint = $script:EntryPoint } {
            param ($EntryPoint)
            Get-WtRuntimeReportText -EntryPoint $EntryPoint
        }
        $Report | Should -Match ([regex]::Escape([string]$PSVersionTable.PSVersion))
        $Report | Should -Match 'Validated range'
        $Report | Should -Match 'GoWorker'
    }

    It 'builds no start-up notice on a validated runtime, and a report either way' {
        $Info = InModuleScope WindowsTweaker -Parameters @{ EntryPoint = $script:EntryPoint } {
            param ($EntryPoint)
            Get-WtRuntimeInfo -EntryPoint $EntryPoint
        }
        # This host is validated, so there is nothing to warn about and the report is built.
        $Info.Validated | Should -BeTrue
        $Info.Notice | Should -BeNullOrEmpty
        $Info.Report | Should -Match 'PowerShell'
        $Info.HandoffCommand | Should -Match 'WindowsTweaker\.ps1'
        @($Info.Capabilities).Count | Should -BeGreaterThan 5
    }

    It 'produces the bilingual notice for a runtime that is not the validated one' {
        # Built from the module's own string tables for a simulated Windows PowerShell session.
        $Notice = InModuleScope WindowsTweaker {
            $Fake = [pscustomobject]@{
                Version = [version]'5.1.26100.1591'; Tier = 'WindowsPowerShell'; IsCore = $false
                Platform = 'Windows'; SupportedVersion = [version]'7.4'
                TestedRange = (Get-WtTestedPowerShellRange)
            }
            Get-WtRuntimeStartupNotice -RuntimeProfile $Fake -EntryPoint 'C:\WindowsTweaker.ps1'
        }
        $Notice | Should -Match 'Windows PowerShell'
        $Notice | Should -Match 'pwsh -NoProfile -File'
        # Vietnamese first, English second: two lines, both naming the versions.
        @($Notice -split "`r?`n").Count | Should -Be 2
    }
}

Describe 'Text files are BOM-less UTF-8 on every runtime' {

    It 'writes and reads Vietnamese text without a byte-order mark' {
        $Path = Join-Path $script:TestRoot 'vi.txt'
        Write-WtTextFile -Path $Path -Value 'Tắt quảng cáo - Có'
        $Bytes = [System.IO.File]::ReadAllBytes($Path)
        $Bytes[0] | Should -Not -Be 0xEF
        (Read-WtTextFile -Path $Path).Trim() | Should -Be 'Tắt quảng cáo - Có'

        # Appending keeps a single file, no BOM in the middle.
        Write-WtTextFile -Path $Path -Value ('dòng ' + [char]::ConvertFromUtf32(0x1F600)) -Append
        $Lines = @(Get-Content -LiteralPath $Path -Encoding utf8)
        $Lines.Count | Should -Be 2
        $Lines[1] | Should -Match 'dòng'

        # NoNewline does not add a terminator.
        $Plain = Join-Path $script:TestRoot 'plain.txt'
        Write-WtTextFile -Path $Plain -Value 'one' -NoNewline
        [System.IO.File]::ReadAllText($Plain) | Should -BeExactly 'one'
    }

    It 'creates the parent directory of a file it writes' {
        $Path = Join-Path $script:TestRoot 'nested/deeper/file.json'
        Write-WtTextFile -Path $Path -Value '{}'
        (Test-Path -LiteralPath $Path -PathType Leaf) | Should -BeTrue
    }
}

Describe 'JSON is one shape on every runtime' {

    It 'normalises the escaping Windows PowerShell 5.1 produces' {
        # PowerShell 5.1 escapes non-ASCII as \uXXXX; 7 writes the characters. The normaliser
        # turns the 5.1 spelling back into the 7 spelling.
        $Object = [pscustomobject]@{ name = 'xin chào'; emoji = [char]::ConvertFromUtf32(0x1F600); nested = @{ a = @(1, 2) } }
        $Native = ConvertTo-Json -InputObject $Object -Depth 6 -Compress
        $Normalised = ConvertTo-WtJson -InputObject $Object -Depth 6 -Compress
        $Normalised | Should -Be $Native
        $Normalised | Should -Match 'xin chào'
        $Normalised | Should -Match 'chào'

        # An escaped backslash and an escaped quote are not unicode escapes.
        (ConvertFrom-WtJsonEscape -Text '{"path":"a\\\\b","q":"\\"x\\""}') | Should -Be '{"path":"a\\\\b","q":"\\"x\\""}'
        # A surrogate pair becomes one character.
        (ConvertFrom-WtJsonEscape -Text '"\ud83d\ude00"') | Should -Be ('"' + [char]::ConvertFromUtf32(0x1F600) + '"')
        # Text that is not a valid escape is left as written.
        (ConvertFrom-WtJsonEscape -Text '"\uZZZZ"') | Should -Be '"\uZZZZ"'
        # No escape at all: the string is returned unchanged (fast path).
        (ConvertFrom-WtJsonEscape -Text 'plain') | Should -Be 'plain'
    }

    It 'round-trips JSON with the wrapper' {
        $Text = '{"id":"Privacy.AdvertisingId","count":3,"nested":{"flag":true,"list":[1,2,3]},"vi":"Tắt"}'
        $Value = ConvertFrom-WtJson -Text $Text -Depth 8
        $Value.id | Should -Be 'Privacy.AdvertisingId'
        $Value.nested.list.Count | Should -Be 3
        $Value.vi | Should -Be 'Tắt'

        (ConvertTo-WtJson -InputObject $Value -Depth 8 -Compress) | Should -Be $Text
        (ConvertFrom-WtJson -Text '   ') | Should -BeNullOrEmpty
        { ConvertFrom-WtJson -Text '{not json' } | Should -Throw
    }

    It 'emulates -AsHashtable with the same shape as PowerShell 7' {
        $Value = ConvertFrom-WtJson -Text '{"Id":1,"Inner":{"x":"y"},"Items":[{"a":1}]}' -AsHashtable
        $Value | Should -BeOfType [System.Collections.IDictionary]
        $Value['Id'] | Should -Be 1
        # 7.3+ returns an OrderedHashtable whose keys are case-sensitive; the emulation does too.
        $Value['ID'] | Should -BeNullOrEmpty
        $Value['Inner'] | Should -BeOfType [System.Collections.IDictionary]
        $Value['Inner']['x'] | Should -Be 'y'
        $Value['Items'].Count | Should -Be 1
        $Value['Items'][0]['a'] | Should -Be 1
    }

    It 'converts a whole object tree to hashtables' {
        $Object = [pscustomobject]@{ a = 1; b = [pscustomobject]@{ c = 'x' }; d = @([pscustomobject]@{ e = $true }) }
        $Table = ConvertTo-WtHashtable -InputObject $Object
        $Table['a'] | Should -Be 1
        $Table['b']['c'] | Should -Be 'x'
        $Table['d'][0]['e'] | Should -BeTrue
    }
}

Describe 'Bootstrap and module agree on runtime discovery' {

    BeforeAll {
        . $script:BootstrapPath

        $script:Fakes = Join-Path $script:TestRoot 'fakes'
        [System.IO.Directory]::CreateDirectory($script:Fakes) | Out-Null

        function script:New-ProbeRuntime {
            param ([string]$Name, [string]$Reported)

            $Path = Join-Path $script:Fakes $Name
            Set-Content -LiteralPath $Path -Value ("Write-Output '{0}'`nexit 0" -f $Reported) -Encoding utf8
            return $Path
        }

        $script:Cases = @(
            @{ Name = 'stable-7.6.9.ps1'; Reported = '[7.6.9]|Core|AMD64' }
            @{ Name = 'stable-7.4.0.ps1'; Reported = '[7.4.0]|Core|AMD64' }
            @{ Name = 'old-7.3.12.ps1'; Reported = '[7.3.12]|Core|AMD64' }
            @{ Name = 'future-7.7.0.ps1'; Reported = '[7.7.0]|Core|AMD64' }
            @{ Name = 'preview-7.7.0-preview.3.ps1'; Reported = '[7.7.0-preview.3]|Core|AMD64' }
            @{ Name = 'desktop-5.1.ps1'; Reported = '[5.1.26100.1591]|Desktop|AMD64' }
            @{ Name = 'garbage.ps1'; Reported = 'not a version' }
        )
        $script:CandidatePaths = @($script:Cases | ForEach-Object { New-ProbeRuntime -Name $_.Name -Reported $_.Reported })
    }

    It 'classifies every probed candidate identically in both implementations' {
        for ($Index = 0; $Index -lt $script:CandidatePaths.Count; $Index++)
        {
            $Path = $script:CandidatePaths[$Index]
            $FromModule = Read-WtPwshCandidate -Path $Path -Minimum ([version]'7.4') -Range (Get-WtTestedPowerShellRange)
            $FromBootstrap = Read-WtBootstrapPwshCandidate -Path $Path

            $FromBootstrap.Path | Should -Be $FromModule.Path
            $FromBootstrap.Version | Should -Be $FromModule.Version
            $FromBootstrap.Preview | Should -Be $FromModule.Preview
            $FromBootstrap.Compatible | Should -Be $FromModule.Compatible
            $FromBootstrap.Selected | Should -Be $FromModule.Selected
        }
    }

    It 'never selects a preview build, an untested range or an old runtime' {
        foreach ($Name in @('old-7.3.12.ps1', 'future-7.7.0.ps1', 'preview-7.7.0-preview.3.ps1', 'garbage.ps1'))
        {
            $Path = Join-Path $script:Fakes $Name
            (Read-WtPwshCandidate -Path $Path -Minimum ([version]'7.4') -Range (Get-WtTestedPowerShellRange)).Compatible |
                Should -BeFalse -Because "$Name must not be selected automatically"
            (Read-WtBootstrapPwshCandidate -Path $Path).Compatible | Should -BeFalse
        }
    }

    It 'composes a quoted handoff command for a path with spaces' {
        $Command = Get-WtRuntimeHandoffCommand -EntryPoint 'C:\Program Files\WindowsTweaker\WindowsTweaker.ps1' -Arguments @('-Language', 'vi')
        $Command | Should -Match ([regex]::Escape("pwsh -NoProfile -File 'C:\Program Files\WindowsTweaker\WindowsTweaker.ps1'"))
        $Command | Should -Match "'-Language' 'vi'"
    }
}

Describe 'Source encoding and manifest contract' {

    It 'declares a 5.1 floor and both editions' {
        $Manifest = Import-PowerShellDataFile -LiteralPath $script:ModuleManifest
        $Manifest.PowerShellVersion | Should -Be '5.1'
        @($Manifest.CompatiblePSEditions) | Should -Contain 'Desktop'
        @($Manifest.CompatiblePSEditions) | Should -Contain 'Core'

        [System.IO.File]::ReadAllText($script:EntryPoint) | Should -Match '(?m)^#Requires -Version 5\.1'
        [System.IO.File]::ReadAllText($script:BootstrapPath) | Should -Match '(?m)^#Requires -Version 5\.1'
    }

    It 'gives every non-ASCII shipped script a UTF-8 BOM' {
        # 5.1 decodes a BOM-less file with the ANSI code page; a Vietnamese string table
        # without a BOM is therefore mojibake, not a translation.
        $Roots = @('src', 'bootstrap', 'tools', 'tests') | ForEach-Object { Join-Path $script:RepositoryRoot $_ }
        $Missing = @()
        foreach ($Root in $Roots)
        {
            foreach ($File in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Include '*.ps1', '*.psd1', '*.psm1'))
            {
                $Bytes = [System.IO.File]::ReadAllBytes($File.FullName)
                $HasNonAscii = @($Bytes | Where-Object { $_ -gt 0x7F }).Count -gt 0
                if (-not $HasNonAscii) { continue }
                $HasBom = ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
                if (-not $HasBom) { $Missing += $File.FullName.Substring($script:RepositoryRoot.Length) }
            }
        }
        $Missing | Should -BeNullOrEmpty
    }

    It 'keeps the runtime strings in both languages' {
        $English = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepositoryRoot 'src/WindowsTweaker/Data/Strings.en.psd1')
        $Vietnamese = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepositoryRoot 'src/WindowsTweaker/Data/Strings.vi.psd1')

        foreach ($Key in @('Runtime.Notice.WindowsPowerShell', 'Runtime.Notice.Untested', 'Runtime.Notice.Preview', 'Runtime.Report.Title', 'Runtime.Report.Capability'))
        {
            $English.ContainsKey($Key) | Should -BeTrue -Because "$Key must exist in English"
            $Vietnamese.ContainsKey($Key) | Should -BeTrue -Because "$Key must exist in Vietnamese"
        }
        # The Vietnamese table must actually be Vietnamese, not a copy of the English text.
        $Vietnamese['Runtime.Notice.WindowsPowerShell'] | Should -Not -Be $English['Runtime.Notice.WindowsPowerShell']
        $Vietnamese['Runtime.Notice.WindowsPowerShell'] | Should -Match 'PowerShell'
    }
}