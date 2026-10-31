# WindowsTweaker - privacy profile, power settings, SRUM and Explorer copy-path tests.

BeforeAll {
    $ModuleManifest = Join-Path $PSScriptRoot '../src/WindowsTweaker/WindowsTweaker.psd1'
    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-priv-{0}" -f ([guid]::NewGuid().ToString('n')))

    $env:WT_DATA_ROOT = $script:TestDataRoot
    $env:WT_STATE_PATH = Join-Path $script:TestDataRoot 'state.json'
    $env:WT_LOG_DIRECTORY = Join-Path $script:TestDataRoot 'logs'
    $env:WT_LANG = 'en'
    $ConfirmPreference = 'None'

    New-Item -ItemType Directory -Path $script:TestDataRoot -Force | Out-Null
    Import-Module $ModuleManifest -Force
}

AfterAll {
    Remove-Item -LiteralPath $script:TestDataRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_DATA_ROOT, Env:\WT_STATE_PATH, Env:\WT_LOG_DIRECTORY, Env:\WT_LANG -ErrorAction Ignore
}

Describe 'Privacy profile and activity views' {

    It 'reports privacy metadata without changing anything' {
        $Before = Test-Path -LiteralPath $env:WT_STATE_PATH

        InModuleScope WindowsTweaker {
            $Summary = Get-WtPrivacySummary
            $Summary.Rows.Count | Should -BeGreaterThan 0
            foreach ($Row in $Summary.Rows)
            {
                $Row.SettingsEditable | Should -BeIn 'Editable', 'PolicyReadOnly', 'Unknown'
                $Row.TweakId | Should -Not -BeNullOrEmpty
            }

            # A profile row carries the diagnostics consequence (stable capability id or empty).
            $Diag = @($Summary.Rows | Where-Object { $_.DiagnosticsConsequence })
            $Diag.Count | Should -BeGreaterThan 0
        }

        Test-Path -LiteralPath $env:WT_STATE_PATH | Should -Be $Before -Because 'the profile is read-only'
    }

    It 'activity views report themselves unavailable instead of fabricating logs' {
        InModuleScope WindowsTweaker {
            foreach ($View in 'camera', 'microphone', 'location', 'screenCapture')
            {
                $Row = Get-WtPrivacyActivity -View $View
                $Row.Count | Should -Be 1
                $Row[0].View | Should -Be $View
                $Row[0].Status | Should -Be 'Unavailable'
                $Row[0].Reason | Should -Not -BeNullOrEmpty
                $Row[0].ObservedFrom | Should -BeNullOrEmpty
                $Row[0].Coverage | Should -Be 'None'
            }

            $All = @(Get-WtPrivacyActivity)
            $All.Count | Should -Be 4
        }
    }
}

Describe 'Power settings explorer and SRUM' {

    It 'parses powercfg /q text into AC/DC rows' {
        $Fixture = @'
Subgroup GUID: 0012ee47-9041-4b5d-9b77-535fba8b1442  (Processor power management)
  Power Setting GUID: 0012ee47-9041-4b5d-9b77-535fba8b1444  (Processor idle)
    Possible Setting Index Friendly Name: 5%
    Possible Setting Index Friendly Name: 10%
    Possible Setting Index: 0x00000005
    Possible Setting Index: 0x0000000a
    Current AC Power Setting Index: 0x00000005
    Current DC Power Setting Index: 0x0000000a
  Power Setting GUID: 0012ee47-9041-4b5d-9b77-535fba8b1445  (Processor idle disable)
    Current AC Power Setting Index: 0x00000000
    Current DC Power Setting Index: 0x00000000
'@

        InModuleScope WindowsTweaker -Parameters @{ Fixture = $Fixture } {
            $Rows = ConvertFrom-WtPowerCfgText -Text $Fixture
            $Rows.Count | Should -Be 2
            $Rows[0].Name | Should -Be 'Processor idle'
            $Rows[0].AcValue | Should -Be '0x00000005'
            $Rows[0].DcValue | Should -Be '0x0000000a'
            $Rows[0].Possible.Count | Should -Be 2
            $Rows[0].Source | Should -Be 'powercfg /q'
            $Rows[1].Name | Should -Be 'Processor idle disable'
        }
    }

    It 'power settings are unavailable off Windows and SRUM is never fabricated' {
        InModuleScope WindowsTweaker {
            Mock Get-WtEnvironmentInternal {
                @{ PSTypeName = 'WindowsTweaker.Environment'; IsWindows = $false }
            }

            $Power = Get-WtPowerSettings
            $Power.Available | Should -BeFalse
            $Power.Reason | Should -Not -BeNullOrEmpty
            $Power.Settings.Count | Should -Be 0

            $Srum = Get-WtSrumHistory
            $Srum.Available | Should -BeFalse
            $Srum.Records.Count | Should -Be 0
            $Srum.Notes | Should -Not -BeNullOrEmpty
            ($Srum.Notes -join ' ') | Should -Match 'missing records are not proof'
        }
    }
}

Describe 'Explorer copy-path tweak' {

    BeforeEach {
        InModuleScope WindowsTweaker -Parameters @{ Confirm = $ConfirmPreference } {
            $Script:TestRegistry = @{}
            $Script:TestKeys = @{}
            $Script:TestKeyContents = @{}

            Mock Get-WtEnvironmentInternal {
                @{
                    PSTypeName = 'WindowsTweaker.Environment'
                    IsWindows = $true
                    IsAdmin = $false
                    OSBuild = 26100
                    OSVersionKey = 'Windows11'
                    OSName = 'Windows 11 Pro'
                    RequiredPS = [version]'7.4'
                    MeetsPowerShell = $true
                    LanguageMode = 'FullLanguage'
                    PendingReboot = $false
                    Culture = 'en-US'
                }
            }
            Mock Test-WtCapability { param ($Name, $Environment) @{ Name = $Name; Available = $true; Reason = ''; Kind = 'Mocked' } }
            Mock Test-WtRegistryAvailable { $true }
            Mock Test-WtRegistryKeyRaw { param ($Path) $Script:TestKeys.ContainsKey($Path) }
            Mock Get-WtRegistryValueStateRaw {
                param ($Path, [AllowEmptyString()][string]$Name)
                $Key = "$Path|$Name"
                if ($Script:TestRegistry.ContainsKey($Key))
                {
                    return @{ KeyExists = $true; ValueExists = $true; Kind = $Script:TestRegistry[$Key].Kind; KindInferred = $false; Value = $Script:TestRegistry[$Key].Value }
                }
                return @{ KeyExists = $false; ValueExists = $false; Kind = $null; KindInferred = $false; Value = $null }
            }
            Mock Set-WtRegistryValueRaw { param ($Path, [AllowEmptyString()][string]$Name, $Value, $Kind) $Script:TestRegistry["$Path|$Name"] = @{ Kind = $Kind; Value = $Value } }
            Mock Remove-WtRegistryPropertyRaw { param ($Path, [AllowEmptyString()][string]$Name) $Script:TestRegistry.Remove("$Path|$Name") }
            Mock New-WtRegistryKeyRaw { param ($Path) $Script:TestKeys[$Path] = $true }
            Mock Remove-WtRegistryKeyRaw { param ($Path, [switch]$Recurse) $Script:TestKeys.Remove($Path); $Script:TestKeyContents.Remove($Path) }
            Mock Get-WtRegistryKeyContentRaw { param ($Path) if ($Script:TestKeys.ContainsKey($Path)) { @{ Exists = $true; Values = 0; SubKeys = 0; Inspected = $true } } else { @{ Exists = $false; Values = 0; SubKeys = 0; Inspected = $false } } }

            Initialize-WtLogging -Console $false -Force | Out-Null
        }
    }

    It 'registers the verb for the current user only and restores exactly' {
        InModuleScope WindowsTweaker {
            $Apply = Invoke-WtTweak -Id 'Explorer.CopyPathCommand' -State Enabled -Confirm:$false
            $Apply.Status | Should -Be 'succeeded'

            $Verb = 'HKCU:\Software\Classes\Directory\shell\WindowsTweakerCopyPath'
            $Tag = 'HKCU:\Software\Classes\*\shell\WindowsTweakerCopyPath'
            $Script:TestKeys.ContainsKey($Verb) | Should -BeTrue
            $Script:TestKeys.ContainsKey($Tag) | Should -BeTrue
            $Script:TestRegistry.ContainsKey("$Verb\command|") | Should -BeTrue
            $Script:TestRegistry["$Verb\command|"].Value | Should -Match 'cmd.exe /d /c echo %W\|clip'

            # Rollback removes exactly the created registration.
            $Undo = Undo-WtTweak -Id 'Explorer.CopyPathCommand' -Confirm:$false
            $Undo.Status | Should -Be 'succeeded'
            $Script:TestKeys.ContainsKey($Verb) | Should -BeFalse
            $Script:TestKeys.ContainsKey($Tag) | Should -BeFalse
        }
    }

    It 'uses the quoted %W placeholder, never an unquoted path' {
        InModuleScope WindowsTweaker {
            $Apply = Invoke-WtTweak -Id 'Explorer.CopyPathCommand' -State Enabled -Confirm:$false
            $Apply.Status | Should -Be 'succeeded'
            $Command = $Script:TestRegistry["HKCU:\Software\Classes\Directory\shell\WindowsTweakerCopyPath\command|"].Value
            $Command | Should -Match 'echo %W\|clip'
            $Command | Should -Not -Match 'echo\s+[^%\s]'
        }
    }
}
