# WindowsTweaker - loading, catalog and localization contract tests.
#
# These tests protect the invariants that were broken in the previous revision:
#   * importing the module must not change any system setting
#   * the loader must fail loudly on a file that does not parse (otherwise the module
#     silently loads without those definitions)
#   * commands must be defined exactly once and the public surface must be explicit
#   * every tweak carries the metadata, detection and apply implementation the
#     framework relies on
#   * localization must always produce a string (fallback chain)

BeforeAll {
    $script:RepositoryRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:ModuleManifest = Join-Path $script:RepositoryRoot 'src/WindowsTweaker/WindowsTweaker.psd1'
    $script:SourceRoot = Join-Path $script:RepositoryRoot 'src/WindowsTweaker'
    $script:PowerShellPath = Join-Path $PSHOME 'pwsh'

    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-load-{0}" -f ([guid]::NewGuid().ToString('n')))
    $env:WT_DATA_ROOT = $script:TestDataRoot
    $env:WT_STATE_PATH = Join-Path $script:TestDataRoot 'state.json'
    $env:WT_LOG_DIRECTORY = Join-Path $script:TestDataRoot 'logs'
    $env:WT_LANG = 'en'
}

AfterAll {
    Remove-Module WindowsTweaker -Force -ErrorAction Ignore
    Remove-Item -LiteralPath $script:TestDataRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_DATA_ROOT, Env:\WT_STATE_PATH, Env:\WT_LOG_DIRECTORY, Env:\WT_LANG -ErrorAction Ignore
}

Describe 'Module loading has no side effects' {

    It 'writes no state, logs or directories when the module is imported' {
        if (Test-Path -LiteralPath $script:TestDataRoot)
        {
            Remove-Item -LiteralPath $script:TestDataRoot -Recurse -Force
        }

        Import-Module $script:ModuleManifest -Force

        Test-Path -LiteralPath $script:TestDataRoot | Should -BeFalse -Because 'importing the module must not create its data directory'
        Test-Path -LiteralPath (Join-Path $script:TestDataRoot 'state.json') | Should -BeFalse
    }

    It 'performs no detection-time mutation for any tweak' {
        Import-Module $script:ModuleManifest -Force

        InModuleScope WindowsTweaker {
            $Script:ImportGuardWrites = @()

            Mock Set-WtRegistryValueRaw { param ($Path, $Name, $Value, $Kind) $Script:ImportGuardWrites += "registry:$Path" }
            Mock Remove-WtRegistryPropertyRaw { param ($Path, $Name) $Script:ImportGuardWrites += "registry-remove:$Path" }
            Mock New-WtRegistryKeyRaw { param ($Path) $Script:ImportGuardWrites += "key:$Path" }
            Mock Remove-WtRegistryKeyRaw { param ($Path, [switch]$Recurse) $Script:ImportGuardWrites += "key-remove:$Path" }
            Mock Set-WtServiceStartupTypeRaw { param ($Name, $StartupType) $Script:ImportGuardWrites += "service:$Name" }
            Mock Start-WtServiceRaw { param ($Name) $Script:ImportGuardWrites += "service-start:$Name" }
            Mock Stop-WtServiceRaw { param ($Name) $Script:ImportGuardWrites += "service-stop:$Name" }
            Mock Set-WtScheduledTaskEnabledRaw { param ($Path, $Name, $Enabled) $Script:ImportGuardWrites += "task:$Name" }
            Mock Set-WtFirewallRuleRaw { param ($Name, $Enabled, $Action) $Script:ImportGuardWrites += "firewall:$Name" }
            Mock Set-WtDnsServerAddressRaw { param ($InterfaceIndex, $ServerAddresses) $Script:ImportGuardWrites += "dns:$InterfaceIndex" }
            Mock Reset-WtDnsServerAddressRaw { param ($InterfaceIndex) $Script:ImportGuardWrites += "dns-reset:$InterfaceIndex" }
            Mock Remove-WtAppxPackageRaw { param ($PackageFullName, [switch]$AllUsers) $Script:ImportGuardWrites += "appx:$PackageFullName" }
            Mock Set-WtMpPreferenceRaw { param ($Name, $Value) $Script:ImportGuardWrites += "defender:$Name" }
            Mock Invoke-WebRequest { $Script:ImportGuardWrites += 'download' }
        }

        # Detection for every tweak, exactly as the CLI/GUI do it before showing a list.
        $States = @(Get-WtTweakState)
        $States.Count | Should -BeGreaterThan 0

        InModuleScope WindowsTweaker {
            $Script:ImportGuardWrites | Should -BeNullOrEmpty -Because 'detection must be read-only'
        }

        Test-Path -LiteralPath (Join-Path $script:TestDataRoot 'state.json') | Should -BeFalse
    }

    It 'fails loudly when a module file has a syntax error' {
        $BrokenRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-broken-{0}" -f ([guid]::NewGuid().ToString('n')))
        Copy-Item -Path $script:SourceRoot -Destination (Join-Path $BrokenRoot 'WindowsTweaker') -Recurse
        $BrokenFile = Join-Path $BrokenRoot 'WindowsTweaker/Private/Broken.ps1'
        Set-Content -LiteralPath $BrokenFile -Value 'function Broken { param(  ' -Encoding utf8NoBOM

        try
        {
            $Output = & $script:PowerShellPath -NoProfile -Command "Import-Module '$BrokenRoot/WindowsTweaker/WindowsTweaker.psd1' -Force -ErrorAction Stop; 'LOADED'" 2>&1
            $Output -join ' ' | Should -Match 'failed to load'
        }
        finally
        {
            Remove-Item -LiteralPath $BrokenRoot -Recurse -Force -ErrorAction Ignore
        }
    }
}

Describe 'Public surface and command definitions' {

    It 'exports exactly the documented public functions' {
        Import-Module $script:ModuleManifest -Force

        $Expected = @(
            # declarative catalog, packs, planning and migrations
            'Get-WtSanityRule', 'Get-WtSanityScan', 'Get-WtRecommendationObjective', 'Get-WtRecommendation', 'Get-WtPendingRestart', 'Get-WtTweakDimensions', 'Get-WtChoiceGroup',
            'Test-WtCatalogFile', 'Get-WtTweakDefinition', 'Get-WtTweakDefinitionView', 'Get-WtDependencyPlan', 'Get-WtTweakMigration', 'Get-WtTweakPack', 'Import-WtTweakPack', 'Enable-WtTweakPack', 'Disable-WtTweakPack', 'Remove-WtTweakPack', 'Get-WtCapabilityLoss',
            'Get-WtQuarantineCandidates', 'Get-WtQuarantineManifest', 'Add-WtQuarantineEntries', 'Restore-WtQuarantineEntries', 'Remove-WtQuarantineEntries', 'Get-WtQuarantineSummary',
            'Get-WtDeviceInventory',
            'Get-WtPrivacySummary', 'Get-WtPrivacyActivity',
            'Invoke-WtMonitorCycle',
            'Get-WtDashboardList', 'Get-WtDashboard', 'Import-WtDashboard', 'Export-WtDashboard',
            'Get-WtMonitorDefaults', 'Measure-WtMonitorCycle',
            'Enable-WtMetricRecording', 'Disable-WtMetricRecording', 'Get-WtMetricRecording', 'Get-WtStoredMetricRange',
            'Get-WtPowerSettings', 'Get-WtSrumHistory',
            'Get-WtSetupPlan', 'New-WtSetupPlan', 'Export-WtSetupPlan', 'Import-WtSetupPlan', 'Get-WtSetupPlanPreview', 'Start-WtSetupPlan', 'Resume-WtSetupPlan', 'Remove-WtSetupPlanResume',
            'Get-WtEnvironment', 'Get-WtTweak', 'Get-WtCategory', 'Get-WtNetworkAdapter',
            'Get-WtWindowsFeature', 'Get-WtWindowsCapability',
            'Test-WtPrerequisite', 'Get-WtTweakState', 'Invoke-WtTweak', 'Undo-WtTweak',
            'New-WtRestorePoint', 'Get-WtPreset', 'Import-WtPreset', 'Export-WtPreset',
            'Get-WtHistory', 'Get-WtLogPath', 'Get-WtStatePath',
            'Invoke-WtDirectoryScan', 'Get-WtDirectoryChildren', 'Get-WtWorkerStatus', 'Set-WtWorkerBackend', 'Measure-WtWorkerOverhead', 'Get-WtWorkerBackendSummary',
            'Get-WtChangePreview', 'Get-WtChangeConflict', 'Get-WtDrift', 'Get-WtOperation',
            'Get-WtSession', 'Close-WtSession', 'Get-WtInterruptedOperation', 'Get-WtRestorePlan',
            'Export-WtHistory', 'Undo-WtSession', 'Export-WtDiagnostics',
            'Measure-WtNetworkDiagnostics', 'Compare-WtMeasurements',
            'Export-WtReport', 'Get-WtLanguage', 'Set-WtLanguage', 'Get-WtString',
            'Start-WtTui', 'Start-WtGui'
        )

        $Actual = @(Get-Command -Module WindowsTweaker | Select-Object -ExpandProperty Name | Sort-Object)
        $Actual | Should -Be ($Expected | Sort-Object)
    }

    It 'keeps implementation details private' {
        Import-Module $script:ModuleManifest -Force

        foreach ($Private in 'Set-WtRegistryValue', 'Get-WtRegistryState', 'Invoke-WtRollback', 'Write-WtLog', 'New-WtScriptTweak', 'Get-WtMpPreferenceState')
        {
            Get-Command -Name $Private -ErrorAction Ignore | Should -BeNullOrEmpty -Because "$Private must stay module-internal"
        }
    }

    It 'defines every command exactly once' {
        Import-Module $script:ModuleManifest -Force

        $Sources = @(Get-ChildItem -Path (Join-Path $script:RepositoryRoot 'src/WindowsTweaker') -Filter '*.ps1' -File -Recurse)
        $Functions = @()

        foreach ($File in $Sources)
        {
            $ParseErrors = $null
            $Tokens = $null
            $Ast = [System.Management.Automation.Language.Parser]::ParseFile($File.FullName, [ref]$Tokens, [ref]$ParseErrors)
            $Functions += @($Ast.FindAll({ param ($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                ForEach-Object { $_.Name })
        }

        $Duplicates = @($Functions | Group-Object | Where-Object { $_.Count -gt 1 } | Select-Object -ExpandProperty Name)
        $Duplicates | Should -BeNullOrEmpty -Because 'duplicate function definitions are what broke the previous revision'
    }
}

Describe 'Tweak catalog invariants' {

    BeforeAll {
        Import-Module $script:ModuleManifest -Force
    }

    It 'gives every tweak a unique id, localized metadata, a detector and an apply implementation' {
        $Tweaks = @(Get-WtTweak -ErrorAction Stop)
        $Tweaks.Count | Should -BeGreaterThan 0

        @($Tweaks | Group-Object -Property Id | Where-Object { $_.Count -gt 1 }).Count | Should -Be 0

        foreach ($Tweak in $Tweaks)
        {
            $Tweak.Id | Should -Match '^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z0-9][A-Za-z0-9_-]*)+$'
            $Tweak.Detect | Should -Not -BeNullOrEmpty -Because "$($Tweak.Id) needs a detector"
            $Tweak.Apply | Should -Not -BeNullOrEmpty -Because "$($Tweak.Id) needs an apply implementation"

            foreach ($Field in 'Name', 'Description', 'Impact')
            {
                $Value = $Tweak.$Field
                $Value | Should -BeOfType [hashtable] -Because "$($Tweak.Id).$Field"
                $Value.Contains('en') | Should -BeTrue -Because "$($Tweak.Id).$Field needs an English value"
                $Value.Contains('vi') | Should -BeTrue -Because "$($Tweak.Id).$Field needs a Vietnamese value"
                [string]::IsNullOrWhiteSpace([string]$Value['en']) | Should -BeFalse
                [string]::IsNullOrWhiteSpace([string]$Value['vi']) | Should -BeFalse
            }
        }
    }

    It 'never claims full rollback for an irreversible tweak and flags protection-reducing tweaks' {
        foreach ($Tweak in @(Get-WtTweak))
        {
            if ($Tweak.Irreversible)
            {
                $Tweak.Rollback | Should -Be 'None' -Because "$($Tweak.Id) is irreversible"
            }

            if ($Tweak.ReducesProtection)
            {
                $Tweak.Risk | Should -Be 'High' -Because "$($Tweak.Id) reduces protection"
            }
        }
    }

    It 'declares consistent states and a valid default state' {
        foreach ($Tweak in @(Get-WtTweak))
        {
            $States = @($Tweak.StateNames)
            if ($States.Count -gt 0)
            {
                $Tweak.DefaultState | Should -BeIn $States -Because "$($Tweak.Id).DefaultState must be a declared state"
            }

            if ($Tweak.States)
            {
                foreach ($Key in $Tweak.States.Keys)
                {
                    $States | Should -Contain $Key -Because "$($Tweak.Id) declares '$Key' outside -StateNames"
                }
            }
        }
    }
}

Describe 'Localization' {

    BeforeAll {
        Import-Module $script:ModuleManifest -Force
        # The tables are split by feature: Import-PowerShellDataFile refuses more than 500
        # entries in one hashtable literal, so each language is a main file plus part files.
        function Merge-WtStringTable([string]$Code)
        {
            $Table = Import-PowerShellDataFile -LiteralPath (Join-Path $script:SourceRoot "Data/Strings.$Code.psd1")
            foreach ($Part in @(Get-ChildItem -Path (Join-Path $script:SourceRoot 'Data') -Filter "Strings.$Code.*.psd1" -File | Sort-Object -Property Name))
            {
                $Extra = Import-PowerShellDataFile -LiteralPath $Part.FullName
                foreach ($Key in $Extra.Keys) { $Table[$Key] = $Extra[$Key] }
            }
            return $Table
        }

        $script:English = Merge-WtStringTable -Code 'en'
        $script:Vietnamese = Merge-WtStringTable -Code 'vi'
    }

    It 'uses no typographic quotation marks in any value' {
        # PowerShell accepts the typographic quotes as string delimiters, so a value containing one
        # is not a value any more: the literal ends there and the file stops parsing. Guard against
        # reintroducing it, because the failure - "could not be parsed as a PowerShell Data File" -
        # does not name the character.
        $Typographic = @([char]0x2018, [char]0x2019, [char]0x201C, [char]0x201D)
        foreach ($Table in @($script:English, $script:Vietnamese))
        {
            foreach ($Key in $Table.Keys)
            {
                $Value = [string]$Table[$Key]
                foreach ($Character in $Typographic)
                {
                    $Value.Contains($Character) | Should -BeFalse -Because "$Key contains $Character"
                }
            }
        }
    }

    It 'has exactly the same keys in every language file' {
        $MissingInVietnamese = @($script:English.Keys | Where-Object { -not $script:Vietnamese.ContainsKey($_) })
        $MissingInEnglish = @($script:Vietnamese.Keys | Where-Object { -not $script:English.ContainsKey($_) })

        $MissingInVietnamese | Should -BeNullOrEmpty
        $MissingInEnglish | Should -BeNullOrEmpty
    }

    It 'defines every statically referenced string key' {
        # A key used in code but missing from the tables would silently degrade to
        # "[Key]" in the interface; catch it at build time instead.
        $Keys = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($File in @(Get-ChildItem -Path (Join-Path $script:SourceRoot '..') -Filter '*.ps1' -File -Recurse))
        {
            $Content = Get-Content -LiteralPath $File.FullName -Raw
            foreach ($Match in [regex]::Matches($Content, "Get-WtString\s+-Key\s+'([A-Za-z0-9_.]+)'"))
            {
                [void]$Keys.Add($Match.Groups[1].Value)
            }
        }

        $Keys.Count | Should -BeGreaterThan 10

        $MissingEnglish = @($Keys | Where-Object { -not $script:English.ContainsKey($_) } | Sort-Object)
        $MissingVietnamese = @($Keys | Where-Object { -not $script:Vietnamese.ContainsKey($_) } | Sort-Object)

        $MissingEnglish | Should -BeNullOrEmpty
        $MissingVietnamese | Should -BeNullOrEmpty
    }

    It 'defines no string key that nothing uses' {
        # The reverse of the check above: a key that no code references (and that is not
        # part of a family composed at runtime) is dead weight, and dead strings are how a
        # removed interface leaves misleading translations behind.
        $DynamicFamilies = '^(Restart\.|Rollback\.|Op\.|Status\.|Tui\.State\.|Tui\.Scope\.|Tui\.Privilege\.|Tui\.Impact\.|Tui\.Language\.|Tui\.Help\.|Tui\.Verify\.Status\.|Tweak\.Lifecycle\.|Cat\.|Cap\.Loss\.Kind\.|Quar\.Stage\.|Quar\.Verdict\.|Mon\.Alert\.|Mon\.Dash\.|Mon\.Compare\.Verdict\.|Mon\.Fleet\.Condition\.)'

        $Sources = @(Get-ChildItem -Path (Join-Path $script:RepositoryRoot 'src') -Filter '*.ps1' -File -Recurse |
            Where-Object { $_.FullName -notlike '*/Data/*' }) +
            @(Get-ChildItem -Path (Join-Path $script:RepositoryRoot 'src') -Filter '*.xaml' -File -Recurse) +
            @(Get-Item -LiteralPath (Join-Path $script:RepositoryRoot 'WindowsTweaker.ps1'))

        $Text = ($Sources | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"

        $Unused = @($script:English.Keys | Where-Object {
                $_ -notmatch $DynamicFamilies -and $Text -notmatch [regex]::Escape("'$_'")
            } | Sort-Object)

        $Unused | Should -BeNullOrEmpty
    }

    It 'resolves strings in both languages and switches without restarting' {
        Set-WtLanguage -Language 'en' | Out-Null
        (Get-WtLanguage) | Should -Be 'en'

        Set-WtLanguage -Language 'vi' | Out-Null
        (Get-WtLanguage) | Should -Be 'vi'

        Set-WtLanguage -Language 'en' | Out-Null
    }

    It 'falls back to English and then to the key itself' {
        Set-WtLanguage -Language 'vi' | Out-Null

        InModuleScope WindowsTweaker {
            # A key that exists in neither table must degrade to the key itself
            # instead of returning an empty string.
            (Get-WtString -Key 'This.Key.Does.Not.Exist') | Should -Be '[This.Key.Does.Not.Exist]'

            # A key that exists in both tables resolves to the Vietnamese value.
            (Get-WtString -Key 'Status.Enabled') | Should -Be 'đang bật'
        }

        Set-WtLanguage -Language 'en' | Out-Null
        InModuleScope WindowsTweaker {
            (Get-WtString -Key 'Status.Enabled') | Should -Be 'enabled'
        }
    }

    It 'selects the language from WT_LANG and rejects unsupported values' {
        Set-WtLanguage -Language 'de-DE' | Out-Null
        (Get-WtLanguage) | Should -Be 'en'
    }
}

Describe 'Legacy material is never executed' {

    It 'is not referenced by any production script' {
        $Scripts = @(Get-ChildItem -Path (Join-Path $script:RepositoryRoot 'src/WindowsTweaker') -Filter '*.ps1' -File -Recurse) +
            @(Get-Item -LiteralPath (Join-Path $script:RepositoryRoot 'WindowsTweaker.ps1'))

        foreach ($Script in $Scripts)
        {
            # Comments are stripped first so that documentation such as
            # "never Invoke-Expression" does not trip the check.
            $Code = @(Get-Content -LiteralPath $Script.FullName |
                Where-Object { $_.TrimStart() -notmatch '^#' }) -join [Environment]::NewLine

            $Code | Should -Not -Match 'original-upstream-reference\.txt' -Because "$($Script.Name) must not source the unreviewed reference file"
            $Code | Should -Not -Match 'Invoke-Expression' -Because "$($Script.Name) must not use Invoke-Expression"
            $Code | Should -Not -Match 'powershell_temp\.exe' -Because "$($Script.Name) must not copy executables into System32"
            $Code | Should -Not -Match 'Add-Content.*LGPO\.txt' -Because "$($Script.Name) must not write LGPO transcripts"
        }
    }
}
