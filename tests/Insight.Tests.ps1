# WindowsTweaker - sanity scan, recommendation policy, state dimensions and choice groups.
#
# Everything here runs on any platform: the registry is an in-memory double, rule documents and
# packs are files in a temporary directory, and the boot-entry probe is doubled. The claims that
# cannot be tested on Linux - that a finding reflects a real Windows build - are exactly the
# claims these tests do not make.

BeforeAll {
    $script:ModuleManifest = Join-Path $PSScriptRoot '../src/WindowsTweaker/WindowsTweaker.psd1'
    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-insight-{0}" -f ([guid]::NewGuid().ToString('n')))

    $env:WT_DATA_ROOT = $script:TestDataRoot
    $env:WT_STATE_PATH = Join-Path $script:TestDataRoot 'state.json'
    $env:WT_LOG_DIRECTORY = Join-Path $script:TestDataRoot 'logs'
    $env:WT_PACKS_PATH = Join-Path $script:TestDataRoot 'packs'
    $env:WT_MIGRATIONS_PATH = Join-Path $script:TestDataRoot 'migrations.json'
    $env:WT_LANG = 'en'

    New-Item -ItemType Directory -Path $script:TestDataRoot -Force | Out-Null
    $ConfirmPreference = 'None'
    Import-Module $script:ModuleManifest -Force

    # A registry double: enough for the scan, the dimensions and a reviewed apply.
    $script:InitializePlatform = {
        InModuleScope WindowsTweaker {
            $Script:WtReg = @{}
            $Script:WtKeys = @{}
            $Script:WtWrites = 0

            Mock Get-WtEnvironmentInternal {
                @{
                    PSTypeName = 'WindowsTweaker.Environment'
                    PowerShell = $PSVersionTable.PSVersion
                    RequiredPS = [version]'7.4'
                    MeetsPowerShell = $true
                    IsWindows = $true
                    IsAdmin = $true
                    OSName = 'Windows 11 Pro'
                    OSBuild = 26100
                    OSUBR = 1
                    OSDisplayVersion = '24H2'
                    OSVersionKey = 'Windows11'
                    Architecture = 'X64'
                    IsVirtualMachine = $false
                    LanguageMode = 'FullLanguage'
                    PendingReboot = $false
                    Culture = 'en-US'
                }
            }

            Mock Test-WtCapability { param ($Name, $Environment) @{ Name = $Name; Available = $true; Reason = ''; Kind = 'Mocked' } }
            Mock Test-WtPrerequisite { param ($Tweak) [pscustomobject]@{ PSTypeName = 'WindowsTweaker.PrerequisiteResult'; TweakId = $Tweak.Id; Supported = $true; Reason = ''; Missing = @(); Requirements = @() } }
            Mock Test-WtRegistryAvailable { $true }
            Mock Test-WtRegistryKeyRaw { param ($Path) $Script:WtKeys.ContainsKey($Path) }
            Mock Get-WtRegistrySubKeyNamesRaw { param ($Path) @() }
            Mock Get-WtRegistryValueStateRaw {
                param ($Path, $Name)
                $Key = "$Path|$Name"
                if ($Script:WtReg.ContainsKey($Key))
                {
                    return @{ KeyExists = $true; ValueExists = $true; Kind = $Script:WtReg[$Key].Kind; KindInferred = $false; Value = $Script:WtReg[$Key].Value }
                }
                return @{ KeyExists = $false; ValueExists = $false; Kind = $null; KindInferred = $false; Value = $null }
            }
            Mock Get-WtRegistryState {
                param ($Path, $Name)
                $Key = "$Path|$Name"
                if ($Script:WtReg.ContainsKey($Key))
                {
                    return [pscustomobject]@{ PSTypeName = 'WindowsTweaker.RegistryState'; Path = $Path; Name = $Name; Available = $true; KeyExists = $true; ValueExists = $true; Kind = $Script:WtReg[$Key].Kind; Value = $Script:WtReg[$Key].Value }
                }
                return [pscustomobject]@{ PSTypeName = 'WindowsTweaker.RegistryState'; Path = $Path; Name = $Name; Available = $true; KeyExists = $false; ValueExists = $false; Kind = $null; Value = $null }
            }
            Mock Set-WtRegistryValueRaw {
                param ($Path, $Name, $Value, $Kind)
                $Script:WtWrites++
                $Script:WtReg["$Path|$Name"] = @{ Kind = $Kind; Value = $Value }
            }
            Mock Remove-WtRegistryPropertyRaw {
                param ($Path, $Name)
                $Script:WtWrites++
                $Script:WtReg.Remove("$Path|$Name")
            }
            Mock New-WtRegistryKeyRaw { param ($Path) $Script:WtKeys[$Path] = $true }
            Mock Remove-WtRegistryKeyRaw { param ($Path, [switch]$Recurse) }
            Mock Get-WtRegistryKeyContentRaw { param ($Path) @{ Exists = $Script:WtKeys.ContainsKey($Path); Values = 0; SubKeys = 0; Inspected = $true } }

            Initialize-WtLogging -Console $false -Force | Out-Null
        }
    }

    $script:ResetStore = {
        Remove-Item -LiteralPath $env:WT_STATE_PATH -Force -ErrorAction Ignore
        Remove-Item -LiteralPath "$($env:WT_STATE_PATH).lock" -Force -ErrorAction Ignore
    }

    # Writes a rule document and returns its path.
    $script:NewRules = {
        param ([string]$Name, [string]$Body)

        $Path = Join-Path $script:TestDataRoot $Name
        Set-Content -LiteralPath $Path -Value $Body -Encoding utf8
        return $Path
    }

    # One minimal registry rule, so a test can state its own expectation.
    $script:RuleBody = {
        param (
            [string]$Id = 'Test.Rule',
            [string]$ReviewWhen = 'Present',
            [string]$Values = '[]',
            [string]$Severity = 'Low',
            [string]$Source = ''
        )

        if (-not $Source)
        {
            $Source = '{"url": "https://learn.microsoft.com/", "title": "Test source", "claim": "the value means what this rule says", "checkedUtc": "2026-10-31"}'
        }

        return @"
{
  "schemaVersion": 1,
  "kind": "Rules",
  "id": "test",
  "rules": [
    {
      "id": "$Id",
      "revision": 1,
      "area": "Tcp",
      "title": { "en": "Test rule", "vi": "Quy tac thu" },
      "rationale": { "en": "Test rationale", "vi": "Ly do thu" },
      "severity": "$Severity",
      "effective": "Unknown",
      "supportedOS": ["Windows10", "Windows11"],
      "minBuild": 0,
      "source": $Source,
      "limitations": { "en": "Test limitation", "vi": "Gioi han thu" },
      "expected": { "en": "Absent", "vi": "Khong co" },
      "nextStep": { "en": "Review it", "vi": "Xem lai" },
      "remediation": { "kind": "Manual" },
      "probes": [
        {
          "id": "value",
          "required": true,
          "kind": "RegistryValue",
          "hive": "HKLM",
          "key": "SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters",
          "name": "TcpWindowSize",
          "reviewWhen": "$ReviewWhen",
          "values": $Values,
          "expect": { "en": "Absent", "vi": "Khong co" },
          "claim": "test claim"
        }
      ]
    }
  ]
}
"@
    }

    # Handed to the InModuleScope blocks that create fixtures: the module scope cannot see the
    # test script's own scope.
    $script:WtTestParameters = @{ NewRules = $script:NewRules; RuleBody = $script:RuleBody }
}

AfterAll {
    Remove-Item -LiteralPath $script:TestDataRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_DATA_ROOT, Env:\WT_STATE_PATH, Env:\WT_LOG_DIRECTORY, Env:\WT_PACKS_PATH, Env:\WT_MIGRATIONS_PATH, Env:\WT_LANG -ErrorAction Ignore
}

Describe 'Sanity scan' {

    BeforeEach {
        & $script:ResetStore
        & $script:InitializePlatform
    }

    It 'changes nothing while scanning' {
        InModuleScope WindowsTweaker {
            $Script:WtReg['HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile|SystemResponsiveness'] = @{ Kind = 'DWord'; Value = 25 }
            $Before = $Script:WtReg.Count
            $Writes = $Script:WtWrites

            $Scan = Invoke-WtSanityScanInternal

            $Script:WtReg.Count | Should -Be $Before
            $Script:WtWrites | Should -Be $Writes
            $Scan.WroteAnything | Should -BeFalse
            $Scan.ExportedTo | Should -Be ''
        }
    }

    It 'reports Findings when a documented value is outside its documented shape' {
        InModuleScope WindowsTweaker {
            $Script:WtReg['HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile|SystemResponsiveness'] = @{ Kind = 'DWord'; Value = 25 }
            $Scan = Invoke-WtSanityScanInternal -Rule 'Mmcss.TaskOverrides'

            $Scan.Outcome | Should -Be 'Findings'
            $Scan.FindingCount | Should -Be 1
            $Scan.Findings[0].RuleId | Should -Be 'Mmcss.TaskOverrides'
            $Scan.Findings[0].Observed | Should -Be '25'
            $Scan.Findings[0].Claim | Should -Not -BeNullOrEmpty
            $Scan.Findings[0].Source.Url | Should -Match '^https://'
        }
    }

    It 'reports Clean only when every required probe answered' {
        InModuleScope WindowsTweaker {
            $Scan = Invoke-WtSanityScanInternal -Rule 'Mmcss.TaskOverrides'
            $Scan.Outcome | Should -Be 'Clean'
        }
    }

    It 'reports Incomplete - never Clean - when a required probe cannot be read' {
        InModuleScope WindowsTweaker {
            Mock Test-WtRegistryAvailable { $false }

            $Scan = Invoke-WtSanityScanInternal -Rule 'Mmcss.TaskOverrides'
            $Scan.Outcome | Should -Be 'Incomplete'
            @($Scan.Gaps)[0].Outcome | Should -Be 'Incomplete'
            @($Scan.Gaps)[0].Reason | Should -Match 'could not be read'
        }
    }

    It 'keeps findings and the Incomplete outcome together when only part of a rule could be read' {
        InModuleScope WindowsTweaker {
            # The boot rule cannot be read (no bcdedit), while the TCP rule fires.
            $Script:WtReg['HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters|TcpWindowSize'] = @{ Kind = 'DWord'; Value = 65535 }
            Mock Read-WtBcdEntryInternal { @{ Available = $false; Settings = @{}; Error = 'access denied' } }

            $Scan = Invoke-WtSanityScanInternal
            $Scan.Outcome | Should -Be 'Incomplete'
            $Scan.FindingCount | Should -BeGreaterThan 0
            @($Scan.Gaps).Count | Should -BeGreaterThan 0
        }
    }

    It 'reports an absent value as absent, not as proof of the default behaviour' {
        InModuleScope WindowsTweaker {
            $Scan = Invoke-WtSanityScanInternal -Rule 'Tcp.LegacyReceiveWindow'
            $Probe = @($Scan.Rules[0].Probes | Where-Object { $_.ProbeId -eq 'tcp-window-size' })[0]
            $Probe.Marker | Should -Be 'Absent'
            $Probe.Fired | Should -BeFalse
        }
    }

    It 'never treats an unavailable probe as broken configuration' {
        InModuleScope WindowsTweaker {
            Mock Test-WtRegistryAvailable { $false }
            $Scan = Invoke-WtSanityScanInternal -Rule 'Tcp.LegacyReceiveWindow'
            $Scan.FindingCount | Should -Be 0
        }
    }

    It 'writes a report only when asked, and the report names the sources' {
        InModuleScope WindowsTweaker {
            $Script:WtReg['HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters|TcpWindowSize'] = @{ Kind = 'DWord'; Value = 65535 }
            $Path = Join-Path $env:WT_DATA_ROOT 'scan.md'
            Remove-Item -LiteralPath $Path -Force -ErrorAction Ignore

            $Scan = Invoke-WtSanityScanInternal -Rule 'Tcp.LegacyReceiveWindow'
            Test-Path -LiteralPath $Path | Should -BeFalse
            $Scan.WroteAnything | Should -BeFalse

            $Written = Export-WtSanityReportInternal -Scan $Scan -Path $Path
            $Written.Ok | Should -BeTrue
            $Written.Path | Should -Be $Path
            $Text = Get-Content -LiteralPath $Path -Raw
            $Text | Should -Match 'learn\.microsoft\.com'
            $Text | Should -Match 'TcpWindowSize'

            # The scan records what it actually did: the flag is not a constant.
            $Scan.WroteAnything | Should -BeTrue
            $Scan.ExportedTo | Should -Be $Path
        }
    }

    It 'refuses to overwrite an existing report and writes nothing when it refuses' {
        InModuleScope WindowsTweaker {
            $Path = Join-Path $env:WT_DATA_ROOT 'scan-existing.md'
            Set-Content -LiteralPath $Path -Value 'previous report' -Encoding utf8

            $Scan = Invoke-WtSanityScanInternal -Rule 'Mmcss.TaskOverrides'
            $Written = Export-WtSanityReportInternal -Scan $Scan -Path $Path

            $Written.Ok | Should -BeFalse
            $Written.Refused | Should -BeTrue
            $Written.Message | Should -Match 'exists'
            (Get-Content -LiteralPath $Path -Raw) | Should -Match 'previous report'
            $Scan.WroteAnything | Should -BeFalse

            $Scan | Add-Member -NotePropertyName 'ExportedTo' -NotePropertyValue '' -Force
            $Forced = Export-WtSanityReportInternal -Scan $Scan -Path $Path -Force
            $Forced.Ok | Should -BeTrue
            (Get-Content -LiteralPath $Path -Raw) | Should -Not -Match 'previous report'
        }
    }

    It 'reports a finding with its observed value type and the conditions the rule declared' {
        InModuleScope WindowsTweaker {
            $Script:WtReg['HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile|SystemResponsiveness'] = @{ Kind = 'DWord'; Value = 25 }
            $Scan = Invoke-WtSanityScanInternal -Rule 'Mmcss.TaskOverrides'
            $Finding = $Scan.Findings[0]

            $Finding.ObservedType | Should -Be 'DWord'
            @($Finding.Conditions.SupportedOS) | Should -Contain 'Windows10'
            $Finding.Conditions.MinBuild | Should -Be 0
            $Finding.Effective | Should -Be 'Inferred'
        }
    }

    It 'reports an unknown rule id instead of silently answering Unsupported' {
        InModuleScope WindowsTweaker {
            $Scan = Invoke-WtSanityScanInternal -Rule 'No.SuchRule'
            @($Scan.UnknownRules) | Should -Contain 'No.SuchRule'
            $Scan.Outcome | Should -Be 'Unsupported'
        }
    }

    It 'refuses a rule document that leaves a probe unspecified about being required' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewRules, $RuleBody)

            # A probe that omits 'required' used to default to $false, which silently removed the
            # 'never Clean after a failed required probe' guarantee. It is now a document error.
            $Body = (& $RuleBody -Id 'Test.NoRequired').Replace('"required": true,', '')
            $Read = Read-WtCatalogJson -Path (& $NewRules -Name 'rules-noreq.json' -Body $Body)
            $Document = ConvertFrom-WtCatalogElement -Element $Read.Document.RootElement
            $Read.Document.Dispose()
            $Tested = Test-WtRuleDocument -Document $Document
            ($Tested.Errors -join ' ') | Should -Match 'required'

            foreach ($Case in @(
                    @{ Name = 'revision.json'; From = '"revision": 1,'; To = ''; Match = 'revision' }
                    @{ Name = 'revision-type.json'; From = '"revision": 1,'; To = '"revision": "one",'; Match = 'revision' }
                    @{ Name = 'minbuild.json'; From = '"minBuild": 0,'; To = '"minBuild": "abc",'; Match = 'minBuild' }
                    @{ Name = 'supportedos.json'; From = '["Windows10", "Windows11"]'; To = '["Windows12"]'; Match = 'supportedOS' }
                ))
            {
                $Body = (& $RuleBody -Id 'Test.Shape').Replace($Case.From, $Case.To)
                $Read = Read-WtCatalogJson -Path (& $NewRules -Name $Case.Name -Body $Body)
                $Read.Ok | Should -BeTrue -Because "$($Case.Name) must still be readable JSON"
                $Document = ConvertFrom-WtCatalogElement -Element $Read.Document.RootElement
                $Read.Document.Dispose()

                # A shape problem is a diagnostic, never an exception.
                $Tested = Test-WtRuleDocument -Document $Document
                ($Tested.Errors -join ' ') | Should -Match $Case.Match
            }
        }
    }

    It 'rejects a rule whose evidence is missing or undated' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewRules, $RuleBody)
            $Body = (& $RuleBody -Id 'Test.NoSource' -Source '{}')
            $Path = & $NewRules -Name 'rules-nosource.json' -Body $Body
            $Read = Read-WtCatalogJson -Path $Path
            $Document = ConvertFrom-WtCatalogElement -Element $Read.Document.RootElement
            $Read.Document.Dispose()

            $Tested = Test-WtRuleDocument -Document $Document
            @($Tested.Errors).Count | Should -BeGreaterThan 0
            ($Tested.Errors -join ' ') | Should -Match 'source\.url|source\.claim'

            $Body = (& $RuleBody -Id 'Test.NoKind' -Source '{"url": "https://example.invalid/", "title": "x", "claim": "y"}').Replace('"kind": "RegistryValue"', '"kind": "RunCommand"')
            $Path = & $NewRules -Name 'rules-badkind.json' -Body $Body
            $Read = Read-WtCatalogJson -Path $Path
            $Document = ConvertFrom-WtCatalogElement -Element $Read.Document.RootElement
            $Read.Document.Dispose()
            $Tested = Test-WtRuleDocument -Document $Document
            ($Tested.Errors -join ' ') | Should -Match 'probe kind'
        }
    }
}

Describe 'Recommendation policy' {

    BeforeEach {
        & $script:ResetStore
        & $script:InitializePlatform
    }

    It 'excludes anything without recommendation metadata' {
        InModuleScope WindowsTweaker {
            $Proposal = Get-WtRecommendationInternal -Objective Privacy -IncludeManual
            $Item = @($Proposal.Items | Where-Object { $_.Id -eq 'Apps.AutoPlay' })[0]
            $Item.Decision | Should -Be 'Excluded'
            $Item.ReasonKey | Should -Be 'Rec.Excluded.NoMetadata'
        }
    }

    It 'recommends an eligible item for the objective it names, and not for another one' {
        InModuleScope WindowsTweaker {
            $Privacy = Get-WtRecommendationInternal -Objective Privacy
            @($Privacy.Recommended | ForEach-Object { $_.Id }) | Should -Contain 'Privacy.WindowsTips'

            $Gaming = Get-WtRecommendationInternal -Objective Gaming -IncludeManual
            @($Gaming.Recommended | ForEach-Object { $_.Id }) | Should -Not -Contain 'Privacy.WindowsTips'
            $Gaming.Recommended.Count | Should -Be 0
            @($Gaming.Items | Where-Object { $_.Id -eq 'Privacy.WindowsTips' -and $_.Decision -eq 'Excluded' }).Count | Should -Be 1
        }
    }

    It 'never selects a preference automatically, even when preferences are requested for Gaming' {
        InModuleScope WindowsTweaker {
            $Without = Get-WtRecommendationInternal -Objective Balanced -IncludeManual
            $Item = @($Without.Items | Where-Object { $_.Id -eq 'Explorer.OpenFileExplorerTo' })[0]
            $Item.Decision | Should -Be 'Excluded'
            $Item.ReasonKey | Should -Be 'Rec.Excluded.Preference'

            # Explicitly asking for preferences makes it *considered*, never automatically chosen.
            $Balanced = Get-WtRecommendationInternal -Objective Balanced -IncludePreferences -IncludeManual
            $Item = @($Balanced.Items | Where-Object { $_.Id -eq 'Explorer.OpenFileExplorerTo' })[0]
            $Item.Decision | Should -Be 'Recommended'
            $Item.Kind | Should -Be 'Preference'

            $Gaming = Get-WtRecommendationInternal -Objective Gaming -IncludePreferences -IncludeManual
            @($Gaming.Recommended | ForEach-Object { $_.Id }) | Should -Not -Contain 'Explorer.OpenFileExplorerTo'
        }
    }

    It 'excludes a protection-reducing item and one that cannot be restored exactly' {
        InModuleScope WindowsTweaker {
            $Proposal = Get-WtRecommendationInternal -Objective Privacy -IncludeManual
            foreach ($Item in @($Proposal.Items))
            {
                if ($Item.Kind -eq '') { continue }
                $Tweak = Get-WtTweakInternal -Id $Item.Id
                if ($Tweak.ReducesProtection)
                {
                    $Item.Decision | Should -Be 'Excluded'
                    $Item.ReasonKey | Should -Be 'Rec.Excluded.Protection'
                }
            }

            # A definition with no policy metadata is excluded on that ground alone.
            $Pua = Get-WtRecommendationPolicyInternal -Tweak (Get-WtTweakInternal -Id 'Privacy.PuaProtection')
            $Pua.Verdict | Should -Be 'Never'
            $Pua.ReasonKey | Should -Be 'Rec.Excluded.NoMetadata'
        }
    }

    It 'keeps an unknown applicability as Unknown instead of guessing' {
        InModuleScope WindowsTweaker {
            Mock Test-WtPrerequisite { param ($Tweak) [pscustomobject]@{ TweakId = $Tweak.Id; Supported = $false; Reason = 'not on this build'; Missing = @(); Requirements = @() } }
            $Proposal = Get-WtRecommendationInternal -Objective Privacy
            $Item = @($Proposal.Items | Where-Object { $_.Id -eq 'Privacy.WindowsTips' })[0]
            $Item.Decision | Should -Be 'Unknown'
            $Item.ReasonKey | Should -Be 'Rec.Unknown.Applicability'
        }
    }

    It 'reports an already satisfied item as satisfied and does not propose it' {
        InModuleScope WindowsTweaker {
            # The value the WindowsTips definition writes is already in place.
            $Script:WtReg['HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|SubscribedContent-338389Enabled'] = @{ Kind = 'DWord'; Value = 0 }
            $Script:WtKeys['HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent\DisableSoftLanding'] = $false

            $Proposal = Get-WtRecommendationInternal -Objective Privacy
            $Item = @($Proposal.Items | Where-Object { $_.Id -eq 'Privacy.WindowsTips' })[0]
            $Item.Decision | Should -Be 'AlreadySatisfied'
            @($Proposal.Recommended | ForEach-Object { $_.Id }) | Should -Not -Contain 'Privacy.WindowsTips'
        }
    }

    It 'does not let an imported pack grant itself eligibility' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewRules, $RuleBody)
            $Body = @'
{
  "schemaVersion": 1,
  "kind": "Pack",
  "id": "WtTest.Trust",
  "version": "1.0.0",
  "author": "tests",
  "tweaks": [
    {
      "id": "WtTest.Trust.Item",
      "revision": 1,
      "category": "Privacy",
      "names": { "en": "Trust me", "vi": "Tin toi" },
      "descriptions": { "en": "Claims its own evidence", "vi": "Tu khai bang chung" },
      "impacts": { "en": "None", "vi": "Khong" },
      "sideEffects": { "en": "None", "vi": "Khong" },
      "scope": "User",
      "lifecycle": "Available",
      "risk": "Low",
      "restart": "None",
      "rollback": "Full",
      "irreversible": false,
      "dataDeletion": false,
      "reducesProtection": false,
      "detection": { "hive": "HKCU", "key": "Software\\WtTest\\Trust", "name": "Item", "map": { "Enabled": [1], "Disabled": [0] } },
      "states": {
        "Enabled": [ { "kind": "RegistrySet", "hive": "HKCU", "key": "Software\\WtTest\\Trust", "name": "Item", "type": "DWord", "value": 1 } ],
        "Disabled": [ { "kind": "RegistrySet", "hive": "HKCU", "key": "Software\\WtTest\\Trust", "name": "Item", "type": "DWord", "value": 0 } ]
      },
      "defaultState": "Enabled",
      "recommendation": {
        "kind": "Optimization",
        "policy": "Eligible",
        "objectives": ["Privacy"],
        "rationale": { "en": "Claims to be eligible", "vi": "Tu nhan la duoc xet" }
      },
      "evidence": {
        "source": "Pack",
        "structural": "Structural",
        "providerTests": "WindowsValidated",
        "windowsIntegration": { "result": "WindowsValidated", "build": "26100" }
      }
    }
  ]
}
'@
            $Path = & $NewRules -Name 'trust-pack.json' -Body $Body
            $Import = Import-WtTweakPack -Path $Path -Enable -Confirm:$false
            @($Import.Errors).Count | Should -Be 0 -Because (@($Import.Errors) -join '; ')
            $Import.Imported | Should -BeTrue

            $Policy = Get-WtRecommendationPolicyInternal -Tweak (Get-WtTweakInternal -Id 'WtTest.Trust.Item')
            $Policy.Verdict | Should -Be 'Manual'
            $Policy.ReasonKey | Should -Be 'Rec.Excluded.PackClaim'

            $Proposal = Get-WtRecommendationInternal -Objective Privacy
            @($Proposal.Recommended | ForEach-Object { $_.Id }) | Should -Not -Contain 'WtTest.Trust.Item'
        }
    }

    It 'preserves a manual selection when the objective changes' {
        InModuleScope WindowsTweaker {
            $State = New-WtTuiState -Language 'en' -Colour 'TrueColor' -Silent -KeySource { return $null } -SizeSource { return @{ Width = 120; Height = 40 } }
            $Entry = Get-WtTweakState -Id 'Privacy.WindowsTips' | Select-Object -First 1
            Add-WtTuiPending -State $State -Entry $Entry -Target 'Disabled'
            $State.Pending.Count | Should -Be 1

            [void](Get-WtRecommendationInternal -Objective Balanced)
            $State.Pending.Count | Should -Be 1
            $State.Pending['Privacy.WindowsTips'].Target | Should -Be 'Disabled'
        }
    }

    It 'makes a repair a candidate only while the finding it names is observed' {
        InModuleScope WindowsTweaker {
            # The shipped repair names the probe whose finding it fixes.
            $Without = Get-WtRecommendationInternal -Objective Responsiveness -IncludeManual
            $Item = @($Without.Items | Where-Object { $_.Id -eq 'Mmcss.SystemResponsiveness' })[0]
            $Item.Decision | Should -Be 'Excluded'
            $Item.ReasonKey | Should -Be 'Rec.Excluded.RepairNeedsFinding'

            # A finding of a different rule does not unlock it.
            $Other = Get-WtRecommendationInternal -Objective Responsiveness -IncludeManual -Finding 'Tcp.LegacyReceiveWindow'
            @($Other.Items | Where-Object { $_.Id -eq 'Mmcss.SystemResponsiveness' })[0].ReasonKey | Should -Be 'Rec.Excluded.RepairNeedsFinding'

            # The observed finding does: the item is judged like any other candidate afterwards, and
            # 'Unknown' is one of the honest outcomes of that judgement.
            $With = Get-WtRecommendationInternal -Objective Responsiveness -IncludeManual -Finding 'Mmcss.TaskOverrides/system-responsiveness'
            $Item = @($With.Items | Where-Object { $_.Id -eq 'Mmcss.SystemResponsiveness' })[0]
            $Item.Decision | Should -BeIn @('Recommended', 'AlreadySatisfied', 'Unknown')

            # A bare rule id is a rule-level observation and unlocks the same repair.
            $Bare = Get-WtRecommendationInternal -Objective Responsiveness -IncludeManual -Finding 'Mmcss.TaskOverrides'
            @($Bare.Items | Where-Object { $_.Id -eq 'Mmcss.SystemResponsiveness' })[0].Decision | Should -BeIn @('Recommended', 'AlreadySatisfied', 'Unknown')

            # A repair that cannot name its finding is never selected, whatever else it claims.
            $WithoutMetadata = Get-WtRecommendationPolicyInternal -Tweak ([pscustomobject]@{
                    Id = 'Test.Broken'; Lifecycle = 'Available'; ReducesProtection = $false; Irreversible = $false
                    DataDeletion = $false; Rollback = 'Full'; Risk = 'Low'; DefinitionSource = 'BuiltIn'
                    DefinitionRecommendation = @{ Kind = 'Repair'; Policy = 'Eligible'; Objectives = @(); Rationale = $null; RequiresFinding = '' }
                })
            $WithoutMetadata.Verdict | Should -Be 'Never'
            $WithoutMetadata.ReasonKey | Should -Be 'Rec.Excluded.InvalidMetadata'
        }
    }

    It 'offers but never auto-selects an eligible item that does not state a documented reason' {
        InModuleScope WindowsTweaker {
            $Tweak = [pscustomobject]@{
                Id = 'Test.Undocumented'; Lifecycle = 'Available'; ReducesProtection = $false
                Irreversible = $false; DataDeletion = $false; Rollback = 'Full'; Risk = 'Low'
                DefinitionSource = 'BuiltIn'
                DefinitionEvidence = @{ Structural = 'Validated'; ProviderTests = 'ProviderTested'; WindowsIntegration = $null; AuthorClaimed = $false }
                DefinitionRecommendation = @{
                    Kind = 'Optimization'; Policy = 'Eligible'; Objectives = @('Balanced')
                    Rationale = @{ en = 'Sounds good'; vi = 'Nghe hay' }
                    RequiresFinding = ''; Documented = $false
                }
            }

            $Policy = Get-WtRecommendationPolicyInternal -Tweak $Tweak
            $Policy.Verdict | Should -Be 'Manual'
            $Policy.ReasonKey | Should -Be 'Rec.Excluded.Undocumented'

            # The same item with the claim made is allowed: the flag is what decides, not the shape.
            $Tweak.DefinitionRecommendation.Documented = $true
            (Get-WtRecommendationPolicyInternal -Tweak $Tweak).Verdict | Should -Be 'Allowed'
        }
    }

    It 'refuses to recommend a change whose targets cannot be read back' {
        InModuleScope WindowsTweaker {
            # A scripted change names its targets while it runs, so no read-back can be promised.
            $Scripted = [pscustomobject]@{ Id = 'Test.Scripted'; DefaultState = 'Enabled' }
            $Verification = Test-WtVerificationSupportedInternal -Tweak $Scripted -State 'Enabled'
            $Verification.Supported | Should -BeFalse
            $Verification.Known | Should -BeFalse
            $Verification.ReasonKey | Should -Be 'Rec.Unknown.VerificationScript'

            # A declarative change whose targets have readers is verifiable.
            $Declared = Test-WtVerificationSupportedInternal -Tweak (Get-WtTweakInternal -Id 'Privacy.WindowsTips') -State 'Disabled'
            $Declared.Supported | Should -BeTrue

            # The gate is reported on the item, so a reviewer sees why something is not proposed.
            $Proposal = Get-WtRecommendationInternal -Objective Privacy -IncludeManual
            foreach ($Item in @($Proposal.Items | Where-Object { $_.Tweak }))
            {
                $Item.Verification | Should -BeIn @('Supported', 'Unsupported', 'Unknown')
                $Item.EffectiveEvidence | Should -BeIn @('Observed', 'Inferred', 'Unknown')
            }

            @($Proposal.Items | Where-Object { $_.Decision -eq 'Recommended' }).Count | Should -BeGreaterThan 0
            foreach ($Item in @($Proposal.Items | Where-Object { $_.Decision -eq 'Recommended' }))
            {
                $Item.Verification | Should -Be 'Supported'
            }
        }
    }

    It 'keeps the identifier of a migrated tweak stable so a shipped preset still resolves' {
        $Preset = Import-WtPreset -Path (Join-Path $PSScriptRoot '../src/WindowsTweaker/Data/Presets/explorer-usability.json')
        $Entry = @($Preset.Entries | Where-Object { $_.Id -eq 'Explorer.OpenFileExplorerTo' })[0]
        $Entry | Should -Not -BeNullOrEmpty

        $Tweak = Get-WtTweak -Id 'Explorer.OpenFileExplorerTo'
        @($Tweak.StateNames) | Should -Contain $Entry.State
        $Tweak.DefinitionGroup.Id | Should -Be 'Explorer.StartupLocation'
    }

    It 'rejects an unknown objective instead of substituting one' {
        InModuleScope WindowsTweaker {
            $Proposal = Get-WtRecommendationInternal -Objective 'Turbo'
            @($Proposal.Errors).Count | Should -Be 1
            @($Proposal.Recommended).Count | Should -Be 0
        }
    }
}

Describe 'State dimensions' {

    BeforeEach {
        & $script:ResetStore
        & $script:InitializePlatform
    }

    It 'separates configured from effective: a match does not prove behaviour' {
        InModuleScope WindowsTweaker {
            $Script:WtReg['HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|SubscribedContent-338389Enabled'] = @{ Kind = 'DWord'; Value = 0 }
            $Script:WtKeys['HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent\DisableSoftLanding'] = $false

            $Dimensions = Get-WtStateDimensionsInternal -Tweak (Get-WtTweakInternal -Id 'Privacy.WindowsTips') -State 'Disabled'
            $Dimensions.Configured | Should -Be 'Matches'
            $Dimensions.EffectiveEvidence | Should -Be 'Inferred'
        }

        InModuleScope WindowsTweaker {
            # A definition without an effective declaration cannot claim behaviour at all.
            $Dimensions = Get-WtStateDimensionsInternal -Tweak (Get-WtTweakInternal -Id 'Privacy.LanguageListAccess') -State 'Disabled'
            $Dimensions.Effective | Should -Be 'Unknown'
            $Dimensions.EffectiveEvidence | Should -Be 'Unknown'
        }
    }

    It 'reports Mixed when only some targets match' {
        InModuleScope WindowsTweaker {
            # The Enabled state writes two things: it removes a machine-wide policy value and
            # writes the user value. One is already right, the other is not: that is Mixed.
            $Script:WtReg['HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|SubscribedContent-338389Enabled'] = @{ Kind = 'DWord'; Value = 1 }
            $Script:WtReg['HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent|DisableSoftLanding'] = @{ Kind = 'DWord'; Value = 1 }

            $Dimensions = Get-WtStateDimensionsInternal -Tweak (Get-WtTweakInternal -Id 'Privacy.WindowsTips') -State 'Enabled'
            $Dimensions.Configured | Should -Be 'Mixed' -Because 'the user value is right and the policy value that should be removed is still there'
        }
    }

    It 'reports a pending application restart only when the boundary is provably not crossed' {
        # The change is applied first: a boundary can only be judged against an apply this tool
        # recorded, and that record is what makes the comparison meaningful at all.
        $Applied = Invoke-WtTweak -Id 'Explorer.OpenFileExplorerTo' -State 'ThisPC' -Confirm:$false
        $Applied.Status | Should -Be 'succeeded'

        InModuleScope WindowsTweaker {
            $Tweak = Get-WtTweakInternal -Id 'Explorer.OpenFileExplorerTo'

            # Nothing read the boundary yet: the honest answer is neither 'active' nor 'pending'.
            Mock Read-WtBoundaryProbeInternal { @{ Available = $false; Crossed = $null; Source = ''; Detail = 'cannot read the process list'; StartedUtc = $null } }
            $Unknown = Get-WtStateDimensionsInternal -Tweak $Tweak -State 'ThisPC'
            $Unknown.Configured | Should -Be 'Matches'
            $Unknown.Effective | Should -Be 'Unknown'
            $Unknown.Boundary | Should -Be 'Explorer'
            $Unknown.BoundaryCrossed | Should -BeNullOrEmpty
            $Unknown.Effective | Should -Not -Be 'Active' -Because 'a match does not prove the component read the value'

            # The component has not started since the change was applied.
            Mock Read-WtBoundaryProbeInternal { @{ Available = $true; Crossed = $false; Source = 'File Explorer process'; Detail = 'Explorer started before the change'; StartedUtc = $null } }
            $Pending = Get-WtStateDimensionsInternal -Tweak $Tweak -State 'ThisPC'
            $Pending.Effective | Should -Be 'PendingRestart'
            $Pending.BoundaryCrossed | Should -BeFalse

            # It has: the declared mapping answers, and it is reported as inferred, not observed.
            # (The shipped group declares a boundary but no mapping, so its own crossed answer stays
            # Unknown - which is what the assertion above the fixture must keep showing.)
            $MappedTweak = [pscustomobject]@{
                Id = 'Explorer.OpenFileExplorerTo'; DefaultState = 'ThisPC'; Restart = 'Explorer'
                DefinitionEffective = @{ Evidence = 'Inferred'; Boundary = 'Explorer'; Map = [ordered]@{ ThisPC = 'Active'; QuickAccess = 'Inactive' }; Note = $null }
            }
            Mock Read-WtBoundaryProbeInternal { @{ Available = $true; Crossed = $true; Source = 'File Explorer process'; Detail = 'Explorer started after the change'; StartedUtc = $null } }
            $Crossed = Get-WtEffectiveStateInternal -Tweak $MappedTweak -Configured 'Matches' -Pending $null -State 'ThisPC'
            $Crossed.Effective | Should -Be 'Active'
            $Crossed.Evidence | Should -Be 'Inferred'
            $Crossed.BoundaryCrossed | Should -BeTrue
            $Crossed.BoundarySource | Should -Be 'File Explorer process'

            $CrossedNoMap = Get-WtStateDimensionsInternal -Tweak $Tweak -State 'ThisPC'
            $CrossedNoMap.Effective | Should -Be 'Unknown' -Because 'the definition declares no mapping, so a crossed boundary still does not prove which behaviour is live'
            $CrossedNoMap.BoundaryCrossed | Should -BeTrue
        }
    }

    It 'marks a sign-out boundary and a restart boundary from evidence, not from the declaration' {
        # A recorded apply gives the boundary something to compare with. The definitions below are
        # fixtures carrying that tweak's id, so the case is about the boundary evidence alone.
        $Applied = Invoke-WtTweak -Id 'Privacy.LanguageListAccess' -State 'Disabled' -Confirm:$false
        $Applied.Status | Should -Be 'succeeded'

        InModuleScope WindowsTweaker {
            $Pending = @{ Markers = @(); Present = 1; Unreadable = 0; Boundary = 'Reboot'; BoundaryKey = 'Tui.State.PendingReboot' }

            # A restart marker is Windows' own evidence, so it outranks any timestamp comparison.
            $RebootTweak = [pscustomobject]@{
                Id = 'Privacy.LanguageListAccess'; DefaultState = 'Enabled'; Restart = 'Reboot'
                DefinitionEffective = @{ Evidence = 'Inferred'; Boundary = 'Reboot'; Map = [ordered]@{ Enabled = 'Active' }; Note = $null }
            }
            $Effective = Get-WtEffectiveStateInternal -Tweak $RebootTweak -Configured 'Matches' -Pending $Pending -State 'Enabled'
            $Effective.Effective | Should -Be 'PendingReboot'
            $Effective.BoundarySource | Should -Be 'restart marker'

            $SignOutTweak = [pscustomobject]@{
                Id = 'Privacy.LanguageListAccess'; DefaultState = 'Enabled'; Restart = 'SignOut'
                DefinitionEffective = @{ Evidence = 'Inferred'; Boundary = 'SignOut'; Map = [ordered]@{ Enabled = 'Active' }; Note = $null }
            }

            # The session has not started since the change: it applies at the next sign-out.
            Mock Read-WtBoundaryProbeInternal { @{ Available = $true; Crossed = $false; Source = 'interactive logon session'; Detail = ''; StartedUtc = $null } }
            (Get-WtEffectiveStateInternal -Tweak $SignOutTweak -Configured 'Matches' -Pending $null -State 'Enabled').Effective | Should -Be 'PendingSignOut'

            # The session started after the change, so the value has been read: the mapping answers.
            Mock Read-WtBoundaryProbeInternal { @{ Available = $true; Crossed = $true; Source = 'interactive logon session'; Detail = ''; StartedUtc = $null } }
            (Get-WtEffectiveStateInternal -Tweak $SignOutTweak -Configured 'Matches' -Pending $null -State 'Enabled').Effective | Should -Be 'Active'

            # No evidence either way is reported as unknown, never as applied and never as pending.
            Mock Read-WtBoundaryProbeInternal { @{ Available = $false; Crossed = $null; Source = ''; Detail = ''; StartedUtc = $null } }
            (Get-WtEffectiveStateInternal -Tweak $SignOutTweak -Configured 'Matches' -Pending $null -State 'Enabled').Effective | Should -Be 'Unknown'
        }
    }

    It 'reports a configured state as unreadable, not as unsupported, when the preview cannot be built' {
        InModuleScope WindowsTweaker {
            Mock Get-WtChangePreviewInternal { throw 'the preview could not be built' }
            $Configured = Get-WtConfiguredStateInternal -Tweak (Get-WtTweakInternal -Id 'Privacy.WindowsTips') -State 'Disabled'
            $Configured.Configured | Should -Be 'Unreadable'
            $Configured.Configured | Should -Not -Be 'Unsupported'
            $Configured.Detail | Should -Match 'preview'
        }
    }

    It 'never reports Mixed when no readable target matches the requested state' {
        InModuleScope WindowsTweaker {
            # Two targets, one readable and mismatching, one that cannot be read: 'Mixed' would
            # claim that some targets match, and none do.
            function script:New-WtTargetFixture
            {
                param ([string]$Identity, [string]$ValueKind, [object]$Value, [object]$IntendedValue)

                return [pscustomobject]@{
                    Identity  = $Identity
                    Label     = $Identity
                    Operation = 'RegistrySet'
                    Intended  = @{ Kind = 'Set'; Value = $IntendedValue; Display = [string]$IntendedValue; Type = 'DWord'; Operation = 'RegistrySet' }
                    Current   = @{ Class = 'Registry'; ValueKind = $ValueKind; Value = $Value; Kind = 'DWord'; Reader = 'Get-WtRegistryState'; Reason = ''; Display = [string]$Value }
                    Recovery  = @{}
                }
            }

            Mock Get-WtChangePreviewInternal {
                param ($Id, $State, $Arguments)
                [pscustomobject]@{
                    TweakId       = $Id
                    State         = $State
                    DetectedState = $State
                    Targets       = @(
                        (New-WtTargetFixture -Identity 'HKCU:Test\One' -ValueKind 'Value' -Value 1 -IntendedValue 0)
                        (New-WtTargetFixture -Identity 'HKLM:Test\Two' -ValueKind 'Unreadable' -Value $null -IntendedValue 0)
                    )
                }
            }

            $Dimensions = Get-WtStateDimensionsInternal -Tweak (Get-WtTweakInternal -Id 'Privacy.WindowsTips') -State 'Enabled'
            $Dimensions.Configured | Should -Not -Be 'Mixed'
            $Dimensions.Configured | Should -Be 'Differs'
            $Dimensions.ConfiguredDetail | Should -Match 'could not be read'
        }
    }

    It 'keeps missing, empty, non-empty and unreadable restart markers apart' {
        InModuleScope WindowsTweaker {
            Mock Test-WtRegistryKeyRaw { param ($Path) $Path -eq 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' }
            Mock Get-WtRegistryState {
                param ($Path, $Name)
                return [pscustomobject]@{ Available = $true; ValueExists = $true; Kind = 'MultiString'; Value = if ($Name -eq 'PendingFileRenameOperations') { @() } else { @('\??\C:\x') } }
            }

            $Pending = Get-WtPendingRestartInternal
            $Pending.Present | Should -BeGreaterThan 0

            $Cbs = @($Pending.Markers | Where-Object { $_.Id -eq 'Cbs.RebootPending' })[0]
            $Cbs.Marker | Should -Be 'NonEmpty'

            $Rename = @($Pending.Markers | Where-Object { $_.Id -eq 'SessionManager.PendingFileRenameOperations' })[0]
            $Rename.Marker | Should -Be 'Empty' -Because 'present but empty is not the same as a pending rename'

            $Missing = @($Pending.Markers | Where-Object { $_.Id -eq 'WindowsUpdate.RebootRequired' })[0]
            $Missing.Marker | Should -Be 'Missing'

            Mock Test-WtRegistryAvailable { $false }
            $Unreadable = Get-WtPendingRestartInternal
            $Unreadable.Unreadable | Should -Be $Unreadable.Markers.Count
            $Unreadable.Present | Should -Be 0
        }
    }

    It 'reports ownership from the journal: unmanaged, owned, interrupted' {
        InModuleScope WindowsTweaker {
            $Tweak = Get-WtTweakInternal -Id 'Privacy.LanguageListAccess'
            (Get-WtOwnershipInternal -Tweak $Tweak).Ownership | Should -Be 'Unmanaged'
        }

        $Result = Invoke-WtTweak -Id 'Privacy.LanguageListAccess' -State 'Disabled' -Confirm:$false
        $Result.Status | Should -Be 'succeeded'

        InModuleScope WindowsTweaker {
            $Tweak = Get-WtTweakInternal -Id 'Privacy.LanguageListAccess'
            (Get-WtOwnershipInternal -Tweak $Tweak).Ownership | Should -Be 'Owned'
        }
    }
}

Describe 'Choice groups' {

    BeforeEach {
        & $script:ResetStore
        & $script:InitializePlatform
    }

    It 'exposes one group with its alternatives and their intent' {
        InModuleScope WindowsTweaker {
            $Groups = @(Get-WtChoiceGroupInternal)
            $Groups.Count | Should -Be 1
            $Group = $Groups[0]
            $Group.Id | Should -Be 'Explorer.StartupLocation'
            @($Group.OptionIds) | Should -Be @('ThisPC', 'QuickAccess', 'Downloads')
            @($Group.Options | Where-Object { $_.Id -eq 'QuickAccess' })[0].Intent | Should -Be 'WindowsDefault'
            @($Group.Options | Where-Object { $_.Id -eq 'ThisPC' })[0].Intent | Should -Be 'Configured'
            $Group.CurrentState | Should -Be 'Unknown' -Because 'no value is present'

            # 'Unknown' from detection is not an answer on its own: with no value present the
            # honest detail is 'Absent', not "a custom value".
            $Group.CurrentDetail | Should -Be 'Absent'
            $Group.PendingState | Should -Be ''
            foreach ($Option in @($Group.Options)) { $Option.Pending | Should -BeFalse }
        }
    }

    It 'reports a custom current value honestly instead of picking the first option' {
        InModuleScope WindowsTweaker {
            $Script:WtReg['HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|LaunchTo'] = @{ Kind = 'DWord'; Value = 9 }
            $Group = @(Get-WtChoiceGroupInternal)[0]
            $Group.CurrentState | Should -Be 'Unknown'
            $Group.CurrentState | Should -Not -Be 'ThisPC'
            $Group.CurrentDetail | Should -Be 'Custom'
            $Group.CurrentDetail | Should -Not -Be 'Absent'
        }
    }

    It 'reports which alternative is pending without hiding which one is live' {
        InModuleScope WindowsTweaker {
            $Script:WtReg['HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|LaunchTo'] = @{ Kind = 'DWord'; Value = 2 }
            $Pending = @{ 'Explorer.OpenFileExplorerTo' = @{ Target = 'ThisPC' } }
            $Group = @(Get-WtChoiceGroup -Pending $Pending)[0]

            $Group.CurrentState | Should -Be 'QuickAccess'
            $Group.CurrentDetail | Should -Be 'Matched'
            $Group.PendingState | Should -Be 'ThisPC'
            @($Group.Options | Where-Object { $_.Pending }).Id | Should -Be @('ThisPC')
            @($Group.Options | Where-Object { $_.Detected }).Id | Should -Be @('QuickAccess')
            $Group.PendingState | Should -Not -Be $Group.CurrentState

            # With no pending set handed in, nothing is reported as pending: it is never guessed.
            $Plain = @(Get-WtChoiceGroup)[0]
            $Plain.PendingState | Should -Be ''
            foreach ($Option in @($Plain.Options)) { $Option.Pending | Should -BeFalse }
        }
    }

    It 'reports a partially applied alternative as Mixed rather than as matched' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewRules, $RuleBody)

            # A group whose alternatives write two targets each: with only one of them in place the
            # live value is not "matched", and saying so is the point of the Mixed answer.
            $Body = @'
{
  "schemaVersion": 1,
  "kind": "Pack",
  "id": "WtTest.Group",
  "version": "1.0.0",
  "author": "tests",
  "tweaks": [
    {
      "id": "WtTest.Group.Place",
      "revision": 1,
      "category": "Explorer",
      "names": { "en": "Test place", "vi": "Noi thu" },
      "descriptions": { "en": "Two targets per alternative", "vi": "Hai dich moi lua chon" },
      "impacts": { "en": "None", "vi": "Khong" },
      "sideEffects": { "en": "None", "vi": "Khong" },
      "scope": "User",
      "lifecycle": "Available",
      "risk": "Low",
      "restart": "Explorer",
      "rollback": "Full",
      "irreversible": false,
      "dataDeletion": false,
      "reducesProtection": false,
      "detection": { "hive": "HKCU", "key": "Software\\WtTest\\Group", "name": "Place", "map": { "First": [1], "Second": [2] } },
      "states": {
        "First": [
          { "kind": "RegistrySet", "hive": "HKCU", "key": "Software\\WtTest\\Group", "name": "Place", "type": "DWord", "value": 1 },
          { "kind": "RegistrySet", "hive": "HKCU", "key": "Software\\WtTest\\Group", "name": "Marker", "type": "DWord", "value": 1 }
        ],
        "Second": [
          { "kind": "RegistrySet", "hive": "HKCU", "key": "Software\\WtTest\\Group", "name": "Place", "type": "DWord", "value": 2 },
          { "kind": "RegistrySet", "hive": "HKCU", "key": "Software\\WtTest\\Group", "name": "Marker", "type": "DWord", "value": 2 }
        ]
      },
      "defaultState": "First",
      "group": {
        "id": "WtTest.Group.Place",
        "revision": 1,
        "labels": { "en": "Test place", "vi": "Noi thu" },
        "options": [
          { "id": "First", "intent": "Configured", "labels": { "en": "First", "vi": "Mot" } },
          { "id": "Second", "intent": "WindowsDefault", "labels": { "en": "Second", "vi": "Hai" } }
        ]
      },
      "evidence": { "structural": "Structural" }
    }
  ]
}
'@
            $Path = & $NewRules -Name 'group-pack.json' -Body $Body
            $Import = Import-WtTweakPack -Path $Path -Enable -Confirm:$false
            @($Import.Errors).Count | Should -Be 0 -Because (@($Import.Errors) -join '; ')

            # Only the detected value is in place; the second target of the same alternative is not.
            $Script:WtReg['HKCU:\Software\WtTest\Group|Place'] = @{ Kind = 'DWord'; Value = 1 }

            $Group = @(Get-WtChoiceGroupInternal -Id 'WtTest.Group.Place')[0]
            $Group.CurrentState | Should -Be 'First'
            $Group.CurrentDetail | Should -Be 'Mixed' -Because 'one of the two targets of that alternative is not in place'
        }
    }

    It 'keeps one pending alternative per group and replaces it on request' {
        InModuleScope WindowsTweaker {
            $State = New-WtTuiState -Language 'en' -Colour 'TrueColor' -Silent -KeySource { return $null } -SizeSource { return @{ Width = 120; Height = 40 } }
            $Entry = Get-WtTweakState -Id 'Explorer.OpenFileExplorerTo' | Select-Object -First 1

            Add-WtTuiPending -State $State -Entry $Entry -Target 'ThisPC'
            $State.Pending.Count | Should -Be 1
            $State.Pending['Explorer.OpenFileExplorerTo'].Target | Should -Be 'ThisPC'

            Add-WtTuiPending -State $State -Entry $Entry -Target 'Downloads'
            $State.Pending.Count | Should -Be 1
            $State.Pending['Explorer.OpenFileExplorerTo'].Target | Should -Be 'Downloads'
            $State.Pending['Explorer.OpenFileExplorerTo'].ContainsKey('Fingerprint') | Should -BeFalse
        }
    }

    It 'applies one alternative, verifies it and restores the captured original state' {
        InModuleScope WindowsTweaker {
            # A pre-existing value: ThisPC. The original state must come back exactly.
            $Script:WtReg['HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|LaunchTo'] = @{ Kind = 'DWord'; Value = 1 }

            $Applied = Invoke-WtTweak -Id 'Explorer.OpenFileExplorerTo' -State 'Downloads' -Confirm:$false
            $Applied.Status | Should -Be 'succeeded'
            $Script:WtReg['HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|LaunchTo'].Value | Should -Be 3

            $Restored = Undo-WtTweak -Id 'Explorer.OpenFileExplorerTo' -Confirm:$false
            $Restored.Status | Should -Be 'succeeded'
            $Script:WtReg['HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|LaunchTo'].Value | Should -Be 1
        }
    }

    It 'restores a captured baseline even when the alternative asks for the Windows default' {
        InModuleScope WindowsTweaker {
            # Nothing was configured before: restoring removes the value, and asking for
            # QuickAccess writes 2. They are different actions and produce different results.
            $Script:WtReg.Remove('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|LaunchTo')

            $Applied = Invoke-WtTweak -Id 'Explorer.OpenFileExplorerTo' -State 'QuickAccess' -Confirm:$false
            $Applied.Status | Should -Be 'succeeded'
            $Script:WtReg['HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|LaunchTo'].Value | Should -Be 2

            $Restored = Undo-WtTweak -Id 'Explorer.OpenFileExplorerTo' -Confirm:$false
            $Restored.Status | Should -Be 'succeeded'
            $Script:WtReg.ContainsKey('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|LaunchTo') | Should -BeFalse
        }
    }

    It 'reports an overlapping target between a group and a pack through the conflict engine' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewRules, $RuleBody)
            $Body = @'
{
  "schemaVersion": 1,
  "kind": "Pack",
  "id": "WtTest.Overlap",
  "version": "1.0.0",
  "author": "tests",
  "tweaks": [
    {
      "id": "WtTest.Overlap.SameTarget",
      "revision": 1,
      "category": "Explorer",
      "names": { "en": "Same target", "vi": "Cung dich" },
      "descriptions": { "en": "Writes the same value", "vi": "Ghi cung gia tri" },
      "impacts": { "en": "None", "vi": "Khong" },
      "sideEffects": { "en": "None", "vi": "Khong" },
      "scope": "User",
      "lifecycle": "Available",
      "risk": "Low",
      "restart": "Explorer",
      "rollback": "Full",
      "irreversible": false,
      "dataDeletion": false,
      "reducesProtection": false,
      "detection": { "hive": "HKCU", "key": "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced", "name": "LaunchTo", "map": { "One": [1], "Two": [2] } },
      "states": {
        "One": [ { "kind": "RegistrySet", "hive": "HKCU", "key": "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced", "name": "LaunchTo", "type": "DWord", "value": 1 } ],
        "Two": [ { "kind": "RegistrySet", "hive": "HKCU", "key": "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced", "name": "LaunchTo", "type": "DWord", "value": 2 } ]
      },
      "defaultState": "One"
    }
  ]
}
'@
            $Path = & $NewRules -Name 'overlap-pack.json' -Body $Body
            (Import-WtTweakPack -Path $Path -Enable -Confirm:$false).Imported | Should -BeTrue

            $PreviewA = Get-WtChangePreviewInternal -Id 'Explorer.OpenFileExplorerTo' -State 'Downloads'
            $PreviewB = Get-WtChangePreviewInternal -Id 'WtTest.Overlap.SameTarget' -State 'Two'
            $Conflicts = @(Get-WtChangeConflictInternal -Preview @($PreviewA, $PreviewB))

            $Conflicts.Count | Should -Be 1
            @($Conflicts[0].Left, $Conflicts[0].Right) | Should -Contain 'Explorer.OpenFileExplorerTo'
            @($Conflicts[0].Left, $Conflicts[0].Right) | Should -Contain 'WtTest.Overlap.SameTarget'
        }
    }
}

Describe 'Interface and localization' {

    BeforeEach {
        & $script:ResetStore
        & $script:InitializePlatform
    }

    It 'renders the new views in English and Vietnamese without falling back to raw keys' {
        InModuleScope WindowsTweaker {
            foreach ($Language in 'en', 'vi')
            {
                Set-WtLanguage -Language $Language | Out-Null
                $Groups = @(Get-WtChoiceGroupInternal)
                $Label = Get-WtGroupStateLabelInternal -Group $Groups[0]
                $Label | Should -Not -BeNullOrEmpty
                $Label | Should -Not -Match '^\[Cat\.'
                (Get-WtString -Key 'Cat.Tui.Rec.Summary' -Arguments @(1, 0, 0, 0, 0)) | Should -Not -Match '^\[Cat\.'
                (Get-WtDimensionLabelInternal -Dimension 'Configured' -Value 'Mixed') | Should -Not -Match '^\[Cat\.'
            }

            Set-WtLanguage -Language 'en' | Out-Null
        }
    }

    It 'draws the configured, effective and ownership lines in the details pane' {
        InModuleScope WindowsTweaker {
            $Script:WtReg['HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|SubscribedContent-338389Enabled'] = @{ Kind = 'DWord'; Value = 0 }
            $State = New-WtTuiState -Language 'en' -Colour 'TrueColor' -Silent -KeySource { return $null } -SizeSource { return @{ Width = 140; Height = 45 } }
            $State.Search = 'Privacy.WindowsTips'
            Sync-WtTuiCatalog -State $State
            $State.ItemIndex = 0

            Add-WtTuiDetails -State $State -Layout @{ Top = 1; Bottom = 45 } -Column 1 -Width 130
            $Text = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"

            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Cat.Tui.Configured')))
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Cat.Tui.Effective')))
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Cat.Tui.Ownership')))
        }
    }

    It 'opens the sanity scan with S and closes it without touching the pending set' {
        InModuleScope WindowsTweaker {
            $State = New-WtTuiState -Language 'en' -Colour 'TrueColor' -Silent -KeySource { return $null } -SizeSource { return @{ Width = 120; Height = 40 } }
            $Entry = Get-WtTweakState -Id 'Privacy.LanguageListAccess' | Select-Object -First 1
            Add-WtTuiPending -State $State -Entry $Entry -Target 'Disabled'

            $Keys = [System.Collections.Generic.Queue[object]]::new()
            $Keys.Enqueue(([System.ConsoleKeyInfo]::new('s', [System.ConsoleKey]::S, $false, $false, $false)))
            $Keys.Enqueue(([System.ConsoleKeyInfo]::new([char]27, [System.ConsoleKey]::Escape, $false, $false, $false)))
            $State.KeyQueue = $Keys
            $State.KeySource = { if ($Keys.Count -eq 0) { return $null }; return $Keys.Dequeue() }.GetNewClosure()

            Invoke-WtTuiFrame -State $State | Out-Null
            $State.Pending.Count | Should -Be 1
            $State.Pending['Privacy.LanguageListAccess'].Target | Should -Be 'Disabled'
            $State.Overlay | Should -BeNullOrEmpty
        }
    }
}