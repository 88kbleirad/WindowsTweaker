# WindowsTweaker - diagnostics ring and export tests.
#
# The diagnostics facility is private on purpose, so every body runs through
# InModuleScope. The facility only touches the file system when Export-WtDiagnostics is
# called explicitly, and then only at the path the test hands it: every export target is a
# file inside one temporary directory that is removed afterwards.
#
# The two things these tests exist to prove are the ones a reviewer cannot see by reading a
# single function: a typed character never reaches a record, and an export is always
# bounded and complete JSONL.

BeforeAll {
    $script:RepositoryRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:ModuleManifest = Join-Path $script:RepositoryRoot 'src/WindowsTweaker/WindowsTweaker.psd1'

    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-diag-{0}" -f ([guid]::NewGuid().ToString('n')))
    $env:WT_DATA_ROOT = $script:TestDataRoot
    $env:WT_STATE_PATH = Join-Path $script:TestDataRoot 'state.json'
    $env:WT_LOG_DIRECTORY = Join-Path $script:TestDataRoot 'logs'
    $env:WT_LANG = 'en'

    Import-Module $script:ModuleManifest -Force

    # The helpers live here, not at file level: Pester runs the file body in a scope the
    # test bodies cannot see, so anything they call has to be defined in BeforeAll.

    # Builds a fresh export path inside the test directory. An existing file would make
    # Export-WtDiagnostics refuse, which is exactly what the overwrite test checks.
    function script:New-WtDiagExportPath
    {
        param ([Parameter(Mandatory = $true)][string]$Name)

        $Path = Join-Path $script:TestDataRoot $Name
        Remove-Item -LiteralPath $Path -Force -ErrorAction Ignore

        return $Path
    }

    # Calls the private exporter in module scope (private commands are not visible here).
    function script:Invoke-WtDiagExport
    {
        param
        (
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $false)][string]$SessionId = 'test-session',
            [Parameter(Mandatory = $false)][switch]$Force
        )

        return InModuleScope WindowsTweaker -Parameters @{
            ExportPath      = $Path
            ExportSessionId = $SessionId
            ExportForce     = $Force.IsPresent
        } {
            Export-WtDiagnostics -Path $ExportPath -SessionId $ExportSessionId -Force:$ExportForce
        }
    }

    # Non-empty lines of an export, header first.
    function script:Get-WtDiagExportLine
    {
        param ([Parameter(Mandatory = $true)][string]$Path)

        return @(Get-Content -LiteralPath $Path -Encoding utf8 | Where-Object { $_.Trim().Length -gt 0 })
    }

    # The record lines of an export, header skipped and each line parsed back from JSON.
    function script:Get-WtDiagExportRecord
    {
        param ([Parameter(Mandatory = $true)][string]$Path)

        return @(script:Get-WtDiagExportLine -Path $Path |
            Select-Object -Skip 1 |
            ForEach-Object { ConvertFrom-Json -InputObject $_ })
    }
}

AfterAll {
    Remove-Module WindowsTweaker -Force -ErrorAction Ignore
    Remove-Item -LiteralPath $script:TestDataRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_DATA_ROOT, Env:\WT_STATE_PATH, Env:\WT_LOG_DIRECTORY, Env:\WT_LANG -ErrorAction Ignore
}

Describe 'Diagnostics ring and export' {

    # The ring is module state and outlives a single test, so every test starts empty.
    BeforeEach {
        InModuleScope WindowsTweaker { Clear-WtDiagnosticRecord }
    }

    It 'keeps only the newest records once the ring is full' {
        $Limit = InModuleScope WindowsTweaker { $Script:WtDiagnosticLimit }

        InModuleScope WindowsTweaker -Parameters @{ Count = $Limit + 50; Limit = $Limit } {
            for ($Index = 1; $Index -le $Count; $Index++)
            {
                Add-WtDiagnosticRecord -Kind lifecycle -Target 'ring' -Data @{ Index = $Index }
            }

            (Get-WtDiagnosticSummary).Count | Should -Be $Limit
        }

        $Path = script:New-WtDiagExportPath -Name 'ring.jsonl'
        $null = script:Invoke-WtDiagExport -Path $Path

        $Records = @(script:Get-WtDiagExportRecord -Path $Path)
        $Records.Count | Should -Be $Limit
        $Records[0].data.Index | Should -Be 51 -Because 'the oldest fifty records were dropped'
        $Records[-1].data.Index | Should -Be ($Limit + 50) -Because 'the newest record always survives'
    }

    It 'never records the character carried by a key object' {
        InModuleScope WindowsTweaker {
            Add-WtDiagnosticRecord -Kind input -Key @{ Name = 'Char'; Char = 'Q'; Control = $false } -Target 'search'
        }

        $Path = script:New-WtDiagExportPath -Name 'char.jsonl'
        $null = script:Invoke-WtDiagExport -Path $Path

        $Lines = @(script:Get-WtDiagExportLine -Path $Path)
        $Lines[1] | Should -Not -Match 'Q'

        $Record = @(script:Get-WtDiagExportRecord -Path $Path)
        $Record.Count | Should -Be 1
        $Record[0].key | Should -Be 'Char'
        $Record[0].control | Should -Be $false
        @($Record[0].PSObject.Properties.Name) | Should -Be @('type', 'kind', 'utc', 'key', 'control', 'target', 'message', 'data')
    }

    It 'stores no letter for a key that came from a search field' {
        InModuleScope WindowsTweaker {
            Add-WtDiagnosticRecord -Kind input -Key @{ Name = 'Char'; Char = 'x'; Control = $false } -Target 'search'
        }

        $Path = script:New-WtDiagExportPath -Name 'search.jsonl'
        $null = script:Invoke-WtDiagExport -Path $Path

        $Lines = @(script:Get-WtDiagExportLine -Path $Path)
        $Lines[1] | Should -Not -Match 'x' -Because 'a letter typed into a search box must not reach the export'

        $Record = @(script:Get-WtDiagExportRecord -Path $Path)
        $Record[0].key | Should -Be 'Char'
        $Record[0].target | Should -Be 'search'
        $Record[0].message | Should -Be ''
        $Record[0].data | Should -BeNullOrEmpty
    }

    It 'replaces the home directory and C:\Users paths with <home>' {
        $HomeText = Join-Path $HOME 'diagnostics/notes.txt'
        $HomeResult = InModuleScope WindowsTweaker -Parameters @{ Sample = $HomeText } {
            ConvertTo-WtSanitizedText -Text $Sample
        }

        $HomeResult | Should -BeExactly ('<home>' + $HomeText.Substring($HOME.Length))
        $HomeResult | Should -Not -Match [regex]::Escape($HOME)

        $UsersResult = InModuleScope WindowsTweaker {
            ConvertTo-WtSanitizedText -Text 'C:\Users\alice\Desktop\report.txt'
        }
        $UsersResult | Should -BeExactly '<home>\Desktop\report.txt'

        $Untouched = InModuleScope WindowsTweaker {
            ConvertTo-WtSanitizedText -Text 'C:\Windows\System32\drivers'
        }
        $Untouched | Should -BeExactly 'C:\Windows\System32\drivers'
    }

    It 'redacts secret-looking text and collapses control characters' {
        $Result = InModuleScope WindowsTweaker {
            ConvertTo-WtSanitizedText -Text ("token=abc123 and password: hunter2`n`t" + 'done')
        }

        $Result | Should -BeExactly '<redacted> and <redacted> done'
        $Result | Should -Not -Match 'abc123'
        $Result | Should -Not -Match 'hunter2'

        $Collapsed = InModuleScope WindowsTweaker {
            ConvertTo-WtSanitizedText -Text "a`tb`nc"
        }
        $Collapsed | Should -BeExactly 'a b c'
    }

    It 'drops sensitive data keys entirely' {
        InModuleScope WindowsTweaker {
            Add-WtDiagnosticRecord -Kind error -Target 'state' -Data @{
                password   = 'hunter2'
                passwd     = 'p'
                token      = 'abc'
                secret     = 's'
                apikey     = 'k'
                credential = 'c'
                note       = 'kept'
            }
        }

        $Path = script:New-WtDiagExportPath -Name 'data.jsonl'
        $null = script:Invoke-WtDiagExport -Path $Path

        $Record = @(script:Get-WtDiagExportRecord -Path $Path)
        @($Record[0].data.PSObject.Properties.Name) | Should -Be @('note')
        $Record[0].data.note | Should -Be 'kept'

        (Get-Content -LiteralPath $Path -Raw) | Should -Not -Match 'hunter2'
    }

    It 'truncates data values longer than the field limit' {
        InModuleScope WindowsTweaker {
            Add-WtDiagnosticRecord -Kind lifecycle -Target 'export' -Data @{ Long = ('y' * 500); Short = 'ok' }
        }

        $Path = script:New-WtDiagExportPath -Name 'truncate.jsonl'
        $null = script:Invoke-WtDiagExport -Path $Path

        $Record = @(script:Get-WtDiagExportRecord -Path $Path)
        $Record[0].data.Long.Length | Should -Be 200
        $Record[0].data.Long | Should -Match '\.\.\.$'
        $Record[0].data.Short | Should -Be 'ok'
    }

    It 'writes a header describing the application, without any environment dump' {
        $env:WT_DIAGNOSTIC_CANARY = 'canary-value-8f3'

        try
        {
            $ExpectedPlatform = if ($IsWindows) { 'Windows' } elseif ($IsMacOS) { 'macOS' } elseif ($IsLinux) { 'Linux' } else { [string][System.Environment]::OSVersion.Platform }

            $Path = script:New-WtDiagExportPath -Name 'header.jsonl'
            $Result = script:Invoke-WtDiagExport -Path $Path -SessionId 'session-8f3'
            $Result | Should -Be $Path

            $Lines = @(script:Get-WtDiagExportLine -Path $Path)
            $Header = ConvertFrom-Json -InputObject $Lines[0]

            @($Header.PSObject.Properties.Name) | Should -Be @(
                'type', 'appVersion', 'moduleVersion', 'psVersion', 'platform',
                'osBuild', 'osVersion', 'culture', 'sessionId', 'exportedUtc')

            $Header.type | Should -Be 'header'
            $Header.appVersion | Should -Be '1.0.0'
            $Header.moduleVersion | Should -Be ([string](Import-PowerShellDataFile -LiteralPath $script:ModuleManifest).ModuleVersion)
            $Header.psVersion | Should -Be ([string]$PSVersionTable.PSVersion)
            $Header.platform | Should -Be $ExpectedPlatform
            $Header.osBuild | Should -Not -BeNullOrEmpty
            $Header.osVersion | Should -Not -BeNullOrEmpty
            $Header.culture | Should -Not -BeNullOrEmpty
            $Header.sessionId | Should -Be 'session-8f3'
            ([datetime]$Header.exportedUtc) | Should -BeGreaterThan ([datetime]::UtcNow.AddMinutes(-5))

            $Lines | Should -Not -Match 'canary-value-8f3' -Because 'no environment variable may reach an export'
        }
        finally
        {
            Remove-Item Env:\WT_DIAGNOSTIC_CANARY -ErrorAction Ignore
        }
    }

    It 'refuses to overwrite an existing export unless -Force is given' {
        $Path = script:New-WtDiagExportPath -Name 'overwrite.jsonl'
        Set-Content -LiteralPath $Path -Value 'keep me' -Encoding utf8

        InModuleScope WindowsTweaker -Parameters @{ ExportTarget = $Path } {
            { Export-WtDiagnostics -Path $ExportTarget } | Should -Throw
        }

        (Get-Content -LiteralPath $Path -Raw) | Should -Match 'keep me'

        $Result = script:Invoke-WtDiagExport -Path $Path -Force
        $Result | Should -Be $Path

        $Lines = @(script:Get-WtDiagExportLine -Path $Path)
        (ConvertFrom-Json -InputObject $Lines[0]).type | Should -Be 'header'
        $Lines | Should -Not -Match 'keep me'
    }

    It 'bounds the export by record count and by size' {
        $Limit = InModuleScope WindowsTweaker { $Script:WtDiagnosticLimit }

        # Count bound: more records than the ring can hold, all of them small.
        InModuleScope WindowsTweaker -Parameters @{ Count = $Limit + 50 } {
            for ($Index = 1; $Index -le $Count; $Index++)
            {
                Add-WtDiagnosticRecord -Kind lifecycle -Target 'bound' -Data @{ Index = $Index }
            }
        }

        $CountPath = script:New-WtDiagExportPath -Name 'bound-count.jsonl'
        $null = script:Invoke-WtDiagExport -Path $CountPath

        $CountLines = @(script:Get-WtDiagExportLine -Path $CountPath)
        $CountLines.Count | Should -Be ($Limit + 1)
        (Get-Item -LiteralPath $CountPath).Length | Should -BeLessOrEqual 262144

        # Size bound: the ring is full of large records, so the byte budget must cut the
        # export short instead of writing a partial line.
        InModuleScope WindowsTweaker {
            Clear-WtDiagnosticRecord

            $Data = @{}
            foreach ($Index in 1..12)
            {
                $Data["field$Index"] = ('y' * 200)
            }

            for ($Record = 1; $Record -le 200; $Record++)
            {
                Add-WtDiagnosticRecord -Kind error -Target 'bound' -Data $Data
            }
        }

        $SizePath = script:New-WtDiagExportPath -Name 'bound-size.jsonl'
        $null = script:Invoke-WtDiagExport -Path $SizePath

        $SizeLines = @(script:Get-WtDiagExportLine -Path $SizePath)
        (Get-Item -LiteralPath $SizePath).Length | Should -BeLessOrEqual 262144
        $SizeLines.Count | Should -BeLessThan ($Limit + 1) -Because 'the byte budget left records out'

        foreach ($Line in $SizeLines)
        {
            { ConvertFrom-Json -InputObject $Line } | Should -Not -Throw
        }
    }

    It 'writes one complete JSON record per line' {
        InModuleScope WindowsTweaker {
            Add-WtDiagnosticRecord -Kind input -Key @{ Name = 'Enter'; Control = $false } -Target 'list'
            Add-WtDiagnosticRecord -Kind error -Target 'worker' -Exception ([System.InvalidOperationException]::new('boom'))
        }

        $Path = script:New-WtDiagExportPath -Name 'jsonl.jsonl'
        $null = script:Invoke-WtDiagExport -Path $Path

        $Lines = @(script:Get-WtDiagExportLine -Path $Path)
        $Lines.Count | Should -Be 3

        $Records = @()
        foreach ($Line in $Lines)
        {
            $Records += (ConvertFrom-Json -InputObject $Line)
        }

        @($Records | ForEach-Object { $_.type }) | Should -Be @('header', 'record', 'record')
        @($Records | Select-Object -Skip 1 | ForEach-Object { $_.kind }) | Should -Be @('input', 'error')
        $Records[1].key | Should -Be 'Enter'
        $Records[1].target | Should -Be 'list'
        $Records[2].data.exceptionType | Should -Be 'System.InvalidOperationException'
        $Records[2].message | Should -Be 'boom'
    }

    It 'counts records per kind without returning record text' {
        InModuleScope WindowsTweaker {
            Add-WtDiagnosticRecord -Kind input -Target 'a'
            Add-WtDiagnosticRecord -Kind input -Target 'b'
            foreach ($Index in 1..3)
            {
                Add-WtDiagnosticRecord -Kind error -Target 'c'
            }
            Add-WtDiagnosticRecord -Kind crash -Target 'd'
            Add-WtDiagnosticRecord -Kind lifecycle -Target 'e'
            Add-WtDiagnosticRecord -Kind lifecycle -Target 'f'

            $Summary = Get-WtDiagnosticSummary

            @($Summary.Keys | Sort-Object) | Should -Be @('ByKind', 'Count', 'Limit')
            $Summary.Count | Should -Be 8
            $Summary.Limit | Should -Be 200
            @($Summary.ByKind.Keys | Sort-Object) | Should -Be @('crash', 'error', 'input', 'lifecycle')
            $Summary.ByKind.input | Should -Be 2
            $Summary.ByKind.error | Should -Be 3
            $Summary.ByKind.crash | Should -Be 1
            $Summary.ByKind.lifecycle | Should -Be 2
        }
    }

    It 'empties the ring and leaves an export with only its header' {
        InModuleScope WindowsTweaker {
            Add-WtDiagnosticRecord -Kind crash -Target 'x'
            Clear-WtDiagnosticRecord

            $Summary = Get-WtDiagnosticSummary
            $Summary.Count | Should -Be 0
            @($Summary.ByKind.Values) | Should -Be @(0, 0, 0, 0)
        }

        $Path = script:New-WtDiagExportPath -Name 'cleared.jsonl'
        $null = script:Invoke-WtDiagExport -Path $Path

        $Lines = @(script:Get-WtDiagExportLine -Path $Path)
        $Lines.Count | Should -Be 1
        (ConvertFrom-Json -InputObject $Lines[0]).type | Should -Be 'header'
    }

    It 'reports the application version from the module manifest' {
        $App = InModuleScope WindowsTweaker { Get-WtAppVersion }
        $ManifestVersion = [string](Import-PowerShellDataFile -LiteralPath $script:ModuleManifest).ModuleVersion

        @($App.Keys | Sort-Object) | Should -Be @('Culture', 'ModuleVersion', 'OSBuild', 'OSVersion', 'Platform', 'PSVersion')
        $App.ModuleVersion | Should -Be $ManifestVersion
        $App.PSVersion | Should -Be ([string]$PSVersionTable.PSVersion)
        $App.Platform | Should -Not -BeNullOrEmpty
        $App.OSBuild | Should -Not -BeNullOrEmpty
        $App.OSVersion | Should -Not -BeNullOrEmpty
        $App.Culture | Should -Not -BeNullOrEmpty
    }
}
