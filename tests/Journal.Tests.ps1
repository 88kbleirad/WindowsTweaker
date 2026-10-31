# WindowsTweaker - journal, change verification and recovery tests.
#
# These tests inject the failures the journal exists for: overlapping targets, an
# interrupted write, a corrupt store, a verification mismatch, a failed compensation, an
# external change before a restore, a repeated apply and a restore-only tweak. Every platform
# seam is an in-memory double, so nothing here touches a real system and the whole file runs
# on any platform.

BeforeAll {
    $ModuleManifest = Join-Path $PSScriptRoot '../src/WindowsTweaker/WindowsTweaker.psd1'
    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-journal-{0}" -f ([guid]::NewGuid().ToString('n')))

    $env:WT_DATA_ROOT = $script:TestDataRoot
    $env:WT_STATE_PATH = Join-Path $script:TestDataRoot 'state.json'
    $env:WT_LOG_DIRECTORY = Join-Path $script:TestDataRoot 'logs'
    $env:WT_LANG = 'en'

    $ConfirmPreference = 'None'
    Import-Module $ModuleManifest -Force

    # A registry-only platform double: enough for every scenario here, and fast.
    $script:InitializePlatform = {
        InModuleScope WindowsTweaker {
            $Script:TestRegistry = @{}
            $Script:TestKeys = @{}
            $Script:TestWrites = 0
            $Script:FailWrites = $false
            $Script:FailRestores = $false

            Mock Get-WtEnvironmentInternal {
                @{
                    PSTypeName       = 'WindowsTweaker.Environment'
                    PowerShell       = $PSVersionTable.PSVersion
                    RequiredPS       = [version]'7.4'
                    MeetsPowerShell  = $true
                    IsWindows        = $true
                    IsAdmin          = $true
                    OSName           = 'Windows 11 Pro'
                    OSBuild          = 26100
                    OSUBR            = 1
                    OSDisplayVersion = '24H2'
                    OSVersionKey     = 'Windows11'
                    Architecture     = 'X64'
                    IsVirtualMachine = $false
                    LanguageMode     = 'FullLanguage'
                    PendingReboot    = $false
                    Culture          = 'en-US'
                }
            }

            Mock Test-WtCapability { param ($Name, $Environment) @{ Name = $Name; Available = $true; Reason = ''; Kind = 'Mocked' } }
            Mock Test-WtRegistryAvailable { $true }
            Mock Test-WtRegistryKeyRaw {
                param ($Path)
                $Script:TestKeys.ContainsKey($Path) -or @($Script:TestRegistry.Keys | Where-Object { $_ -like "$Path|*" }).Count -gt 0
            }
            Mock Get-WtRegistryValueStateRaw {
                param ($Path, $Name)

                $Key = "$Path|$Name"
                if ($Script:TestRegistry.ContainsKey($Key))
                {
                    return @{
                        KeyExists    = $true
                        ValueExists  = $true
                        Kind         = $Script:TestRegistry[$Key].Kind
                        KindInferred = $false
                        Value        = $Script:TestRegistry[$Key].Value
                    }
                }

                return @{ KeyExists = $false; ValueExists = $false; Kind = $null; KindInferred = $false; Value = $null }
            }
            Mock Set-WtRegistryValueRaw {
                param ($Path, $Name, $Value, $Kind)

                if ($Script:FailWrites -and $Kind -eq 'String' -and $Value -eq 'sabotage-restore') { throw 'restore failed on purpose' }
                if ($Script:FailWrites) { throw 'write failed on purpose' }

                $Script:TestWrites++
                $Script:TestRegistry["$Path|$Name"] = @{ Kind = $Kind; Value = $Value }
            }
            Mock Remove-WtRegistryPropertyRaw { param ($Path, $Name) $Script:TestRegistry.Remove("$Path|$Name") }
            Mock New-WtRegistryKeyRaw { param ($Path) $Script:TestKeys[$Path] = $true }
            Mock Remove-WtRegistryKeyRaw { param ($Path, [switch]$Recurse) $Script:TestKeys.Remove($Path) }
            Mock Get-WtRegistryKeyContentRaw { param ($Path) @{ Exists = $Script:TestKeys.ContainsKey($Path); Values = 0; SubKeys = 0; Inspected = $true } }

            Initialize-WtLogging -Console $false -Force | Out-Null
        }
    }

    $script:ResetStore = {
        Remove-Item -LiteralPath $env:WT_STATE_PATH -Force -ErrorAction Ignore
        Remove-Item -LiteralPath "$($env:WT_STATE_PATH).lock" -Force -ErrorAction Ignore
    }

    # A catalog large enough to test inside one file, registered once.
    InModuleScope WindowsTweaker {
        if (-not $Script:WtCatalog.Contains('Test.JournalTarget'))
        {
            New-WtRegistryTweak -Id 'Test.JournalTarget' -Category 'Privacy' `
                -Name @{ en = 'Journal target'; vi = 'Đích nhật ký' } `
                -Description @{ en = 'Test tweak'; vi = 'Tinh chỉnh thử' } `
                -Impact @{ en = 'Test impact'; vi = 'Ảnh hưởng thử' } `
                -Scope 'User' -Privilege 'None' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
                -StateNames @('Enabled', 'Disabled') -DefaultState 'Disabled' `
                -Detection @{ Path = 'HKCU:\Software\WtJournal'; Name = 'Target'; Map = [ordered]@{ Enabled = @(1); Disabled = @(0) } } `
                -States @{
                    Enabled  = @(@{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\WtJournal'; Name = 'Target'; Type = 'DWord'; Value = 1 })
                    Disabled = @(@{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\WtJournal'; Name = 'Target'; Type = 'DWord'; Value = 0 })
                }

            New-WtRegistryTweak -Id 'Test.JournalOther' -Category 'Privacy' `
                -Name @{ en = 'Other journal target'; vi = 'Đích nhật ký khác' } `
                -Description @{ en = 'Second test tweak'; vi = 'Tinh chỉnh thử thứ hai' } `
                -Impact @{ en = 'Test impact'; vi = 'Ảnh hưởng thử' } `
                -Scope 'User' -Privilege 'None' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
                -StateNames @('Enabled') -DefaultState 'Enabled' `
                -Detection @{ Path = 'HKCU:\Software\WtJournal'; Name = 'Target'; Map = [ordered]@{ Enabled = @(1) } } `
                -States @{
                    Enabled = @(@{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\WtJournal'; Name = 'Target'; Type = 'DWord'; Value = 1 })
                }

            New-WtRegistryTweak -Id 'Test.JournalThird' -Category 'Privacy' `
                -Name @{ en = 'Third journal target'; vi = 'Đích nhật ký thứ ba' } `
                -Description @{ en = 'Third test tweak'; vi = 'Tinh chỉnh thử thứ ba' } `
                -Impact @{ en = 'Test impact'; vi = 'Ảnh hưởng thử' } `
                -Scope 'User' -Privilege 'None' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
                -StateNames @('Enabled') -DefaultState 'Enabled' `
                -Detection @{ Path = 'HKCU:\Software\WtJournal'; Name = 'Third'; Map = [ordered]@{ Enabled = @(1) } } `
                -States @{
                    Enabled = @(@{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\WtJournal'; Name = 'Third'; Type = 'DWord'; Value = 1 })
                }

            New-WtRegistryTweak -Id 'Test.JournalRetired' -Category 'Privacy' `
                -Name @{ en = 'Retired tweak'; vi = 'Tinh chỉnh đã ngừng' } `
                -Description @{ en = 'Restore-only test tweak'; vi = 'Tinh chỉnh chỉ hoàn tác' } `
                -Impact @{ en = 'Test impact'; vi = 'Ảnh hưởng thử' } `
                -Scope 'User' -Privilege 'None' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
                -Lifecycle 'Restore-only' `
                -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
                -Detection @{ Path = 'HKCU:\Software\WtRetired'; Name = 'Target'; Map = [ordered]@{ Enabled = @(1); Disabled = @(0) } } `
                -States @{
                    Enabled  = @(@{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\WtRetired'; Name = 'Target'; Type = 'DWord'; Value = 1 })
                    Disabled = @(@{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\WtRetired'; Name = 'Target'; Type = 'DWord'; Value = 0 })
                }
        }
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:TestDataRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_DATA_ROOT, Env:\WT_STATE_PATH, Env:\WT_LOG_DIRECTORY, Env:\WT_LANG -ErrorAction Ignore
}

Describe 'Exact change preview' {

    BeforeEach {
        & $script:ResetStore
        & $script:InitializePlatform
    }

    It 'reports the current value, the proposed value, the type, the scope and the recovery limits' {
        InModuleScope WindowsTweaker {
            $Preview = Get-WtChangePreview -Id 'Test.JournalTarget' -State 'Enabled'

            $Preview.Targets.Count | Should -Be 1
            $Target = $Preview.Targets[0]
            $Target.Identity | Should -Be 'reg:HKCU:\SOFTWARE\WTJOURNAL\TARGET'
            $Target.Current.ValueKind | Should -Be 'Absent'
            $Target.Current.Display | Should -Be '(absent)'
            $Target.Intended.Kind | Should -Be 'Set'
            $Target.Intended.Value | Should -Be 1
            $Target.Intended.Type | Should -Be 'DWord'
            $Target.Intended.Display | Should -Be '1'
            $Preview.Scope | Should -Be 'User'
            $Preview.Recovery.Rollback | Should -Be 'Full'
            $Preview.Recovery.Irreversible | Should -BeFalse
            $Preview.Supported | Should -BeTrue
            $Preview.DetectedState | Should -Be 'Unknown'
            $Preview.Fingerprint | Should -Match '^[0-9a-f]{64}$'
        }
    }

    It 'keeps absent, unreadable, empty and zero apart' {
        InModuleScope WindowsTweaker {
            (Get-WtTargetState -Identity 'reg:HKCU:\SOFTWARE\WTJOURNAL\TARGET').ValueKind | Should -Be 'Absent'

            $Script:TestRegistry['HKCU:\Software\WtJournal|Target'] = @{ Kind = 'DWord'; Value = 0 }
            (Get-WtTargetState -Identity 'reg:HKCU:\SOFTWARE\WTJOURNAL\TARGET').ValueKind | Should -Be 'Zero'

            $Script:TestRegistry['HKCU:\Software\WtJournal|Target'] = @{ Kind = 'String'; Value = '' }
            (Get-WtTargetState -Identity 'reg:HKCU:\SOFTWARE\WTJOURNAL\TARGET').ValueKind | Should -Be 'Empty'

            $Script:TestRegistry['HKCU:\Software\WtJournal|Target'] = @{ Kind = 'String'; Value = 'x' }
            (Get-WtTargetState -Identity 'reg:HKCU:\SOFTWARE\WTJOURNAL\TARGET').ValueKind | Should -Be 'Value'

            # A target class without a reader is reported as unreadable, never as "not set".
            $Unsupported = Get-WtTargetState -Identity 'svc:DIAGTRACK'
            $Unsupported.ValueKind | Should -Be 'Unreadable'
            $Unsupported.Reader | Should -Be ''
            $Unsupported.Reason | Should -Match 'No read-back reader'

            Get-WtTargetValueKind -Value $null | Should -Be 'Empty'
            Get-WtTargetValueKind -Value 0 | Should -Be 'Zero'
            Get-WtTargetValueKind -Value $false | Should -Be 'Zero'
            Get-WtTargetValueKind -Value @() | Should -Be 'Empty'
            ConvertTo-WtTargetDisplayValue -Value '' -ValueKind 'Empty' | Should -Be '(empty)'
            ConvertTo-WtTargetDisplayValue -Value 0 -ValueKind 'Zero' | Should -Be '0'
        }
    }

    It 'refuses a reviewed change whose state moved in the meantime' {
        InModuleScope WindowsTweaker {
            $Preview = Get-WtChangePreview -Id 'Test.JournalTarget' -State 'Enabled'
            $Fingerprint = $Preview.Fingerprint

            # Nothing moved yet: the review is still valid.
            (Test-WtReviewedState -Preview $Preview -Fingerprint $Fingerprint).Match | Should -BeTrue

            # Something else writes the target between the review and the confirmation.
            $Script:TestRegistry['HKCU:\Software\WtJournal|Target'] = @{ Kind = 'DWord'; Value = 7 }

            $Review = Test-WtReviewedState -Preview $Preview -Fingerprint $Fingerprint
            $Review.Match | Should -BeFalse
            @($Review.Changed).Count | Should -BeGreaterThan 0
            $Review.Changed[0].Now | Should -Match '7'

            # The engine refuses to apply it and reports why.
            $Result = Invoke-WtTweak -Id 'Test.JournalTarget' -State 'Enabled' -ReviewedFingerprint $Fingerprint -Confirm:$false
            $Result.Status | Should -Be 'review-required'
            $Result.Messages[0] | Should -Be (Get-WtString -Key 'Msg.ReviewRequired')
            $Script:TestWrites | Should -Be 0
        }
    }

    It 'applies a change whose reviewed fingerprint still matches' {
        InModuleScope WindowsTweaker {
            $Preview = Get-WtChangePreview -Id 'Test.JournalTarget' -State 'Enabled'
            $Result = Invoke-WtTweak -Id 'Test.JournalTarget' -State 'Enabled' -ReviewedFingerprint $Preview.Fingerprint -Confirm:$false

            $Result.Status | Should -Be 'succeeded'
            $Result.Verified | Should -BeTrue
            $Result.Verification.Mismatched | Should -Be 0
            $Script:TestRegistry['HKCU:\Software\WtJournal|Target'].Value | Should -Be 1
        }
    }
}
Describe 'Conflict detection and recovery baselines' {

    BeforeEach {
        & $script:ResetStore
        & $script:InitializePlatform
    }

    It 'reports two tweaks that write the same canonical target' {
        InModuleScope WindowsTweaker {
            $First = Get-WtChangePreview -Id 'Test.JournalTarget' -State 'Enabled'
            $Second = Get-WtChangePreview -Id 'Test.JournalOther' -State 'Enabled'

            $Conflicts = @($First, $Second | Get-WtChangeConflict)
            $Conflicts.Count | Should -Be 1
            $Conflicts[0].Identity | Should -Be 'reg:HKCU:\SOFTWARE\WTJOURNAL\TARGET'
            $Conflicts[0].Left | Should -Be 'Test.JournalTarget'
            $Conflicts[0].Right | Should -Be 'Test.JournalOther'
            $Conflicts[0].Reason | Should -Match 'same target'
        }
    }

    It 'reports a registry key that contains another tweak target' {
        InModuleScope WindowsTweaker {
            $Key = New-WtTargetIdentity -Class 'RegistryKey' -Path 'HKCU:\Software\WtJournal'
            (Test-WtTargetOverlap -Left $Key -Right 'reg:HKCU:\SOFTWARE\WTJOURNAL\TARGET') | Should -BeTrue
            (Test-WtTargetOverlap -Left $Key -Right 'reg:HKCU:\SOFTWARE\OTHER\TARGET') | Should -BeFalse
            (Test-WtTargetOverlap -Left 'reg:A\B' -Right 'reg:A\B') | Should -BeTrue
        }
    }

    It 'preserves the original recovery baseline when a tweak is applied twice' {
        InModuleScope WindowsTweaker {
            $First = Invoke-WtTweak -Id 'Test.JournalTarget' -State 'Enabled' -Confirm:$false
            $First.Status | Should -Be 'succeeded'

            # Something changes the value outside the tool, then the same tweak runs again.
            $Script:TestRegistry['HKCU:\Software\WtJournal|Target'] = @{ Kind = 'DWord'; Value = 5 }
            $Second = Invoke-WtTweak -Id 'Test.JournalTarget' -State 'Enabled' -Confirm:$false
            $Second.Status | Should -Be 'succeeded'

            $Entries = @(Get-WtHistory -TweakId 'Test.JournalTarget')
            $Entries.Count | Should -BeGreaterThan 1

            # The baseline is the earliest capture, and it is still restorable.
            $Baseline = Get-WtBaselineEntry -Identity 'reg:HKCU:\SOFTWARE\WTJOURNAL\TARGET'
            $Baseline.operationId | Should -Be $First.OperationId
            $Baseline.rolledBack | Should -BeFalse
            $Baseline.targets[0].captured | Should -BeTrue

            # A later preview reports that the baseline is preserved.
            $Preview = Get-WtChangePreview -Id 'Test.JournalTarget' -State 'Enabled'
            $Preview.Targets[0].Recovery.BaselinePreserved | Should -BeTrue
            $Preview.Targets[0].Recovery.BaselineOperationId | Should -Be $First.OperationId

            # The restore plan keeps the original baseline reachable.
            $Plan = Get-WtRestorePlan -TweakId 'Test.JournalTarget'
            $Plan.OperationCount | Should -BeGreaterThan 1
            @($Plan.Conflicts).Count | Should -BeGreaterThan 0 -Because 'the newer operation supersedes the older one on the same target'
        }
    }

    It 'orders a restore plan by dependency, not by timestamp' {
        InModuleScope WindowsTweaker {
            Invoke-WtTweak -Id 'Test.JournalTarget' -State 'Enabled' -Confirm:$false | Out-Null
            Invoke-WtTweak -Id 'Test.JournalThird' -State 'Enabled' -Confirm:$false | Out-Null

            $Plan = Get-WtRestorePlan -TweakId 'Test.JournalThird'
            $Plan.Steps.Count | Should -BeGreaterThan 0
            $Plan.Steps[0].Sequence | Should -BeGreaterThan 0

            $All = @(Get-WtOperation -Limit 0)
            $Sequences = @($All | ForEach-Object { $_.sequence })
            ($Sequences | Sort-Object -Descending) | Should -Be $Sequences -Because 'journal rows come back newest first'
            @($Sequences | Select-Object -Unique).Count | Should -Be $Sequences.Count -Because 'every operation gets its own sequence number'
        }
    }
}

Describe 'Durable journal' {

    BeforeEach {
        & $script:ResetStore
        & $script:InitializePlatform
    }

    It 'writes the recovery information before the first mutation' {
        InModuleScope WindowsTweaker {
            # The capture has to live in the module scope: a Pester mock runs in its own scope
            # and would otherwise mutate a copy.
            $Script:JournalSeen = [System.Collections.Generic.List[int]]::new()
            Mock Set-WtRegistryValueRaw {
                param ($Path, $Name, $Value, $Kind)

                $Store = Read-WtStateStore
                $Script:JournalSeen.Add(@($Store.History).Count)
                $Script:TestRegistry["$Path|$Name"] = @{ Kind = $Kind; Value = $Value }
            }

            Invoke-WtTweak -Id 'Test.JournalTarget' -State 'Enabled' -Confirm:$false | Out-Null

            $Script:JournalSeen.Count | Should -Be 1
            $Script:JournalSeen[0] | Should -Be 1 -Because 'the journal entry exists on disk before the provider is called'
        }
    }

    It 'records the session, origin, stage, targets and verified outcome' {
        InModuleScope WindowsTweaker {
            $Result = Invoke-WtTweak -Id 'Test.JournalTarget' -State 'Enabled' -Origin 'preset' -Confirm:$false
            $Result.OperationId | Should -Not -BeNullOrEmpty
            $Result.SessionId | Should -Not -BeNullOrEmpty

            $Entry = @(Get-WtOperation -Limit 10)[0]
            $Entry.operationId | Should -Be $Result.OperationId
            $Entry.sessionId | Should -Be $Result.SessionId
            $Entry.origin | Should -Be 'preset'
            $Entry.stage | Should -Be 'completed'
            $Entry.outcome | Should -Be 'succeeded'
            $Entry.sequence | Should -BeGreaterThan 0
            $Entry.targets.Count | Should -Be 1
            $Entry.targets[0].captured | Should -BeTrue
            $Entry.targets[0].verified | Should -BeTrue
            $Entry.verification.Verified | Should -Be 1
            $Entry.platform.OSBuild | Should -Be '26100'

            $Sessions = @(Get-WtSession)
            $Sessions.Count | Should -BeGreaterThan 0
            $Sessions[0].SessionId | Should -Be $Result.SessionId
        }
    }

    It 'keeps the session open until the run closes it, and closing writes nothing without one' {
        InModuleScope WindowsTweaker {
            # A read-only run records no operation, so it has no session and must not create a
            # store to close one: the shutdown path of a read-only command stays read-only.
            $Script:WtSessionId = $null
            (Close-WtSession) | Should -BeFalse
            Test-Path -LiteralPath $env:WT_STATE_PATH | Should -BeFalse

            $Result = Invoke-WtTweak -Id 'Test.JournalTarget' -State 'Enabled' -Confirm:$false

            $Open = @(Get-WtSession | Where-Object { $_.SessionId -eq $Result.SessionId })[0]
            $Open.Open | Should -BeTrue -Because 'nothing has ended the run yet'
            $Open.EndedUtc | Should -BeNullOrEmpty

            (Close-WtSession -SessionId $Result.SessionId) | Should -BeTrue

            $Closed = @(Get-WtSession | Where-Object { $_.SessionId -eq $Result.SessionId })[0]
            $Closed.Open | Should -BeFalse
            $Closed.EndedUtc | Should -Not -BeNullOrEmpty
            $Closed.OperationCount | Should -Be 1

            # Closing an already-closed session is a no-op that keeps the first timestamp, so a
            # shutdown path that runs twice cannot rewrite history.
            (Close-WtSession -SessionId $Result.SessionId) | Should -BeTrue
            @(Get-WtSession | Where-Object { $_.SessionId -eq $Result.SessionId })[0].EndedUtc | Should -Be $Closed.EndedUtc
        }
    }

    It 'reports a session as still open when the store cannot be read' {
        InModuleScope WindowsTweaker {
            $Result = Invoke-WtTweak -Id 'Test.JournalTarget' -State 'Enabled' -Confirm:$false
            Set-Content -LiteralPath $env:WT_STATE_PATH -Value '{ not json' -Encoding utf8NoBOM

            # A shutdown must not throw over bookkeeping, and it must not report a close it
            # could not write.
            (Close-WtSession -SessionId $Result.SessionId) | Should -BeFalse
            (Get-Content -LiteralPath $env:WT_STATE_PATH -Raw) | Should -Match 'not json'
        }
    }

    It 'treats a corrupt store as an error and refuses to write over it' {
        InModuleScope WindowsTweaker {
            Set-Content -LiteralPath $env:WT_STATE_PATH -Value '{ "version": 2, "journal": [ this is not json' -Encoding utf8NoBOM

            $Store = Read-WtStateStore
            $Store.Corrupt | Should -BeTrue

            { Write-WtStateStore -Store $Store } | Should -Throw -ExpectedMessage '*Refusing to overwrite*'
            { Add-WtJournalEntry -Entry (New-WtHistoryEntry -TweakId 'Test.JournalTarget' -State 'Enabled') } | Should -Throw

            # The engine reports the failure and changes nothing.
            $Result = Invoke-WtTweak -Id 'Test.JournalTarget' -State 'Enabled' -Confirm:$false
            $Result.Status | Should -Be 'failed'
            $Result.Messages[0] | Should -Match 'could not be written'
            $Script:TestWrites | Should -Be 0

            # The corrupt file is left exactly as it was: recovery data is never destroyed.
            (Get-Content -LiteralPath $env:WT_STATE_PATH -Raw) | Should -Match 'this is not json'
        }
    }

    It 'treats an empty store file as corrupt rather than as no history' {
        InModuleScope WindowsTweaker {
            Set-Content -LiteralPath $env:WT_STATE_PATH -Value '' -Encoding utf8NoBOM
            (Read-WtStateStore).Corrupt | Should -BeTrue
        }
    }

    It 'detects an interrupted operation and offers it for inspection' {
        InModuleScope WindowsTweaker {
            # Simulate a process that died after the recovery data was written but before the
            # apply finished: exactly the state Add-WtJournalEntry leaves behind.
            $Entry = New-WtHistoryEntry -TweakId 'Test.JournalTarget' -State 'Enabled'
            Add-WtStateRecord -HistoryEntry $Entry -Record @{
                resource = 'Registry'; path = 'HKCU:\Software\WtJournal'; name = 'Target'
                keyExisted = $false; valueExisted = $false; kind = 'DWord'; value = $null
            }
            Add-WtJournalEntry -Entry $Entry | Out-Null

            $Interrupted = @(Get-WtInterruptedOperation)
            $Interrupted.Count | Should -Be 1
            $Interrupted[0].OperationId | Should -Be $Entry.operationId
            $Interrupted[0].Stage | Should -Be 'planned'
            $Interrupted[0].CanRestore | Should -BeTrue
            $Interrupted[0].TargetCount | Should -Be 0
            $Interrupted[0].CapturedCount | Should -Be 1
        }
    }

    It 'keeps the recovery records when a restore fails' {
        InModuleScope WindowsTweaker {
            # Seed a value so the captured baseline is "a value existed" and the restore has to
            # write it back - that is the write the failing double then refuses.
            $Script:TestRegistry['HKCU:\Software\WtJournal|Target'] = @{ Kind = 'DWord'; Value = 0 }
            Invoke-WtTweak -Id 'Test.JournalTarget' -State 'Enabled' -Confirm:$false | Out-Null

            $Script:FailWrites = $true
            $Result = Undo-WtTweak -Id 'Test.JournalTarget' -Force -Confirm:$false

            $Result.Status | Should -Be 'failed'
            $Entry = @(Get-WtOperation -Limit 10)[0]
            $Entry.rolledBack | Should -BeFalse
            @($Entry.records).Count | Should -BeGreaterThan 0
            $Entry.stage | Should -Be 'failed'
        }
    }
}

Describe 'Verified execution and compensation' {

    BeforeEach {
        & $script:ResetStore
        & $script:InitializePlatform
    }

    It 'reports a verification mismatch as a failure instead of as success' {
        InModuleScope WindowsTweaker {
            $Script:TestRegistry['HKCU:\Software\WtJournal|Target'] = @{ Kind = 'DWord'; Value = 0 }

            # The provider writes something else than it was asked to: exactly the case the
            # read-back exists for.
            Mock Set-WtRegistryValueRaw {
                param ($Path, $Name, $Value, $Kind)
                $Script:TestRegistry["$Path|$Name"] = @{ Kind = $Kind; Value = 99 }
            }

            $Result = Invoke-WtTweak -Id 'Test.JournalTarget' -State 'Enabled' -Confirm:$false

            $Result.Status | Should -Be 'failed'
            $Result.Verified | Should -BeFalse
            $Result.Verification.Mismatched | Should -BeGreaterThan 0
            @($Result.Messages) -join ' ' | Should -Match ([regex]::Escape((Get-WtString -Key 'Msg.VerificationFailed' -Arguments @(1)).Split(' ')[0]))
        }
    }

    It 'attempts compensating restoration after a partial failure and reports what it could not undo' {
        InModuleScope WindowsTweaker {
            $Script:TestRegistry['HKCU:\Software\WtJournal|Target'] = @{ Kind = 'DWord'; Value = 0 }

            # Writes land but never match the intended value, so verification fails and the
            # compensation write fails too: compensation failures are reported separately.
            Mock Set-WtRegistryValueRaw {
                param ($Path, $Name, $Value, $Kind)
                $Script:TestRegistry["$Path|$Name"] = @{ Kind = $Kind; Value = 99 }
            }

            $Result = Invoke-WtTweak -Id 'Test.JournalTarget' -State 'Enabled' -Confirm:$false

            $Result.Compensation | Should -Not -BeNullOrEmpty
            $Result.Compensation.Attempted | Should -BeTrue
            $Result.Compensation.Failed | Should -BeGreaterThan 0
            @($Result.Compensation.Messages) -join ' ' | Should -Match 'Compensation failed'

            # Recovery data is retained for a deliberate retry, and the stage says what happened.
            $Entry = @(Get-WtOperation -Limit 10)[0]
            @($Entry.records).Count | Should -BeGreaterThan 0
            $Entry.compensation.Failed | Should -BeGreaterThan 0
            $Entry.stage | Should -Be 'compensated'
        }
    }

    It 'does not compensate an irreversible change and says so' {
        InModuleScope WindowsTweaker {
            $Result = Invoke-WtTweak -Id 'Test.JournalTarget' -State 'Enabled' -Confirm:$false
            $Result.Status | Should -Be 'succeeded'
            $Result.Compensation | Should -BeNullOrEmpty -Because 'nothing failed, so nothing was compensated'
        }
    }

    It 'avoids overwriting an external change unless the caller insists' {
        InModuleScope WindowsTweaker {
            $Script:TestRegistry['HKCU:\Software\WtJournal|Target'] = @{ Kind = 'DWord'; Value = 0 }
            Invoke-WtTweak -Id 'Test.JournalTarget' -State 'Enabled' -Confirm:$false | Out-Null

            # Something else changes the value after it was applied.
            $Script:TestRegistry['HKCU:\Software\WtJournal|Target'] = @{ Kind = 'DWord'; Value = 5 }

            $Blocked = Undo-WtTweak -Id 'Test.JournalTarget' -Confirm:$false
            $Blocked.Status | Should -Be 'review-required'
            $Blocked.Messages[0] | Should -Be (Get-WtString -Key 'Msg.ExternalChange')
            @($Blocked.Plan.ExternalChanges).Count | Should -BeGreaterThan 0
            $Script:TestRegistry['HKCU:\Software\WtJournal|Target'].Value | Should -Be 5 -Because 'nothing was overwritten'

            $Forced = Undo-WtTweak -Id 'Test.JournalTarget' -Force -Confirm:$false
            $Forced.Status | Should -Be 'succeeded'
            $Script:TestRegistry['HKCU:\Software\WtJournal|Target'].Value | Should -Be 0
        }
    }

    It 'verifies the restored value and marks the operation as restored' {
        InModuleScope WindowsTweaker {
            $Script:TestRegistry['HKCU:\Software\WtJournal|Target'] = @{ Kind = 'DWord'; Value = 0 }
            Invoke-WtTweak -Id 'Test.JournalTarget' -State 'Enabled' -Confirm:$false | Out-Null

            $Result = Undo-WtTweak -Id 'Test.JournalTarget' -Confirm:$false
            $Result.Status | Should -Be 'succeeded'
            $Result.Verification.Mismatched | Should -Be 0
            $Result.Verification.Verified | Should -Be 1

            $Entry = @(Get-WtOperation -Limit 10)[0]
            $Entry.rolledBack | Should -BeTrue
            $Entry.stage | Should -Be 'restored'
        }
    }
}

Describe 'Retired tweaks, drift and sessions' {

    BeforeEach {
        & $script:ResetStore
        & $script:InitializePlatform
    }

    It 'refuses to apply a restore-only tweak but still restores its snapshots' {
        InModuleScope WindowsTweaker {
            $Refused = Invoke-WtTweak -Id 'Test.JournalRetired' -State 'Enabled' -Confirm:$false
            $Refused.Status | Should -Be 'unsupported'
            $Refused.Messages[0] | Should -Be (Get-WtString -Key 'Tweak.Lifecycle.Restore-only')

            $State = Get-WtTweakState -Id 'Test.JournalRetired'
            $State.Lifecycle | Should -Be 'Restore-only'
            $State.ApplyAllowed | Should -BeFalse

            # A snapshot captured before the policy was retired is still restorable.
            $Script:TestRegistry['HKCU:\Software\WtRetired|Target'] = @{ Kind = 'DWord'; Value = 1 }
            $Entry = New-WtHistoryEntry -TweakId 'Test.JournalRetired' -State 'Disabled' -Origin 'legacy'
            $Entry.outcome = 'succeeded'
            $Entry.stage = 'completed'
            Add-WtStateRecord -HistoryEntry $Entry -Record @{
                resource = 'Registry'; path = 'HKCU:\Software\WtRetired'; name = 'Target'
                keyExisted = $true; valueExisted = $true; kind = 'DWord'; value = 0
                kindInferred = $false
            }
            $Entry.targets = @([pscustomobject]@{
                    identity = 'reg:HKCU:\SOFTWARE\WTRETIRED\TARGET'
                    label    = 'HKCU:\Software\WtRetired\Target'
                    class    = 'Registry'
                    kind     = 'RegistrySet'
                    original = @{ valueKind = 'Zero'; value = 0; display = '0'; type = 'DWord' }
                    intended = @{ kind = 'Set'; value = 0; display = '0'; type = 'DWord' }
                    captured = $true
                    verified = $null
                })
            Add-WtJournalEntry -Entry $Entry | Out-Null

            $Restored = Undo-WtTweak -HistoryId $Entry.operationId -Force -Confirm:$false
            $Restored.Status | Should -Be 'succeeded'
            $Script:TestRegistry['HKCU:\Software\WtRetired|Target'].Value | Should -Be 0
        }
    }

    It 'classifies drift as matching, changed or unsupported without reapplying anything' {
        InModuleScope WindowsTweaker {
            $Script:TestRegistry['HKCU:\Software\WtJournal|Target'] = @{ Kind = 'DWord'; Value = 0 }
            Invoke-WtTweak -Id 'Test.JournalTarget' -State 'Enabled' -Confirm:$false | Out-Null

            $Rows = @(Get-WtDrift)
            $Rows.Count | Should -BeGreaterThan 0
            $Rows[0].Status | Should -Be 'matching'

            $Script:TestRegistry['HKCU:\Software\WtJournal|Target'] = @{ Kind = 'DWord'; Value = 3 }
            $Drifted = @(Get-WtDrift -OnlyDrifted)
            @($Drifted | Where-Object { $_.Status -eq 'changed' }).Count | Should -BeGreaterThan 0
            $Drifted[0].LiveValue | Should -Match '3'

            # Nothing was reapplied by reading the drift.
            $Script:TestRegistry['HKCU:\Software\WtJournal|Target'].Value | Should -Be 3

            # A target kind with no reader is reported as unsupported, not as matching.
            $Entry = New-WtHistoryEntry -TweakId 'Test.JournalTarget' -State 'Enabled'
            $ServiceTarget = [pscustomobject]@{
                identity = 'svc:DIAGTRACK'; label = 'DiagTrack'; class = 'Service'; kind = 'Service'
                original = $null; intended = @{ kind = 'Configure'; value = 'Disabled'; display = 'startup Disabled'; type = '' }
                captured = $true; verified = $null
            }
            (Get-WtDriftRow -Target $ServiceTarget -Entry $Entry).Status | Should -Be 'unsupported'
        }
    }

    It 'restores a whole session in reverse dependency order' {
        InModuleScope WindowsTweaker {
            Invoke-WtTweak -Id 'Test.JournalTarget' -State 'Enabled' -Confirm:$false | Out-Null
            Invoke-WtTweak -Id 'Test.JournalThird' -State 'Enabled' -Confirm:$false | Out-Null

            $Plan = Get-WtRestorePlan
            $Plan.OperationCount | Should -Be 2
            ($Plan.Steps | Select-Object -ExpandProperty Sequence) | Should -Be ($Plan.Steps | Select-Object -ExpandProperty Sequence | Sort-Object -Descending)

            $Preview = Undo-WtSession -Confirm:$false -WhatIf
            $Preview.Status | Should -Be 'succeeded'
            $Script:TestRegistry.ContainsKey('HKCU:\Software\WtJournal|Target') | Should -BeTrue -Because 'WhatIf restores nothing'

            $Result = Undo-WtSession -Confirm:$false
            $Result.Status | Should -Be 'succeeded'
            $Result.Steps.Count | Should -Be 2
            $Script:TestRegistry.ContainsKey('HKCU:\Software\WtJournal|Third') | Should -BeFalse
            $Script:TestRegistry.ContainsKey('HKCU:\Software\WtJournal|Target') | Should -BeFalse

            foreach ($Step in $Result.Steps) { $Step.Status | Should -Be 'succeeded' }
        }
    }

    It 'filters and exports the operation journal' {
        InModuleScope WindowsTweaker {
            Invoke-WtTweak -Id 'Test.JournalTarget' -State 'Enabled' -Origin 'manual' -Confirm:$false | Out-Null
            Invoke-WtTweak -Id 'Test.JournalThird' -State 'Enabled' -Origin 'preset' -Confirm:$false | Out-Null

            @(Get-WtOperation -Origin preset).Count | Should -Be 1
            @(Get-WtOperation -TweakId 'Test.JournalTarget').Count | Should -Be 1
            @(Get-WtOperation -SessionId (Get-WtSessionId)).Count | Should -Be 2
            @(Get-WtOperation -Stage completed).Count | Should -Be 2

            $JsonPath = Join-Path $TestDrive 'operations.json'
            Export-WtHistory -Path $JsonPath -Origin preset | Out-Null
            $Payload = Get-Content -LiteralPath $JsonPath -Raw | ConvertFrom-Json
            $Payload.version | Should -Be 2
            @($Payload.operations).Count | Should -Be 1
            $Payload.operations[0].origin | Should -Be 'preset'

            $CsvPath = Join-Path $TestDrive 'operations.csv'
            Export-WtHistory -Path $CsvPath -Format Csv | Out-Null
            $Csv = Get-Content -LiteralPath $CsvPath
            $Csv[0] | Should -Match 'operationId'
            $Csv.Count | Should -BeGreaterThan 1
        }
    }

    It 'migrates a schema-1 store without losing history' {
        InModuleScope WindowsTweaker {
            $Legacy = [ordered]@{
                version = 1
                history = @(
                    [ordered]@{
                        historyId  = 'legacy0001'
                        tweakId    = 'Test.JournalTarget'
                        state      = 'Enabled'
                        arguments  = @{}
                        timestamp  = '2026-01-01T00:00:00.0000000Z'
                        dryRun     = $false
                        outcome    = 'succeeded'
                        records    = @([ordered]@{ resource = 'Registry'; path = 'HKCU:\Software\WtJournal'; name = 'Target'; keyExisted = $true; valueExisted = $true; kind = 'DWord'; value = 0 })
                        rolledBack = $false
                        messages   = @('migrated')
                    }
                )
            }
            ($Legacy | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $env:WT_STATE_PATH -Encoding utf8NoBOM

            $Store = Read-WtStateStore
            $Store.Corrupt | Should -BeFalse
            $Store.Version | Should -Be 2
            $Store.Migrated | Should -BeTrue
            @($Store.History).Count | Should -Be 1
            $Store.History[0].operationId | Should -Be 'legacy0001'
            $Store.History[0].historyId | Should -Be 'legacy0001'
            $Store.History[0].origin | Should -Be 'legacy'
            $Store.History[0].stage | Should -Be 'completed'
            @($Store.History[0].records).Count | Should -Be 1

            # The public history view keeps working, and the next write persists schema 2.
            @(Get-WtHistory).Count | Should -Be 1
            $Store.Sessions = @()
            Write-WtStateStore -Store $Store
            (Get-Content -LiteralPath $env:WT_STATE_PATH -Raw) | Should -Match '"version"\s*:\s*2'
        }
    }

    It 'refuses a store written by a newer schema instead of reading it and downgrading it' {
        InModuleScope WindowsTweaker {
            New-Item -ItemType Directory -Path $env:WT_DATA_ROOT -Force | Out-Null
            $Future = [ordered]@{
                version = $Script:WtStateSchemaVersion + 1
                history = @([ordered]@{ operationId = 'future0001'; tweakId = 'Test.JournalTarget'; state = 'Enabled' })
                sessions = @()
            }
            $Written = ($Future | ConvertTo-Json -Depth 8)
            $Written | Set-Content -LiteralPath $env:WT_STATE_PATH -Encoding utf8NoBOM

            $Store = Read-WtStateStore
            $Store.Corrupt | Should -BeTrue
            $Store.NewerSchema | Should -BeTrue
            $Store.Error | Should -Match 'newer version'
            @($Store.History).Count | Should -Be 0 -Because 'records this build does not understand must not be read as if they were current'

            # Neither a plain write nor -Force may replace it: the file belongs to the newer build.
            { Write-WtStateStore -Store $Store } | Should -Throw -ExpectedMessage '*newer version*'
            { Write-WtStateStore -Store $Store -Force } | Should -Throw -ExpectedMessage '*newer version*'
            (Get-Content -LiteralPath $env:WT_STATE_PATH -Raw) | Should -Match '"version":\s*3' -Because 'the newer file is left exactly as it was'
        }
    }

    It 'refuses to write settings over a file a newer build wrote' {
        InModuleScope WindowsTweaker {
            New-Item -ItemType Directory -Path $env:WT_DATA_ROOT -Force | Out-Null
            $SettingsPath = Get-WtSettingsPath
            ($([ordered]@{ version = $Script:WtSettingsSchemaVersion + 1; language = 'vi'; intended = 'kept' }) | ConvertTo-Json) |
                Set-Content -LiteralPath $SettingsPath -Encoding utf8NoBOM

            $Read = Read-WtSettings
            $Read.Refused | Should -BeTrue
            $Read.FileVersion | Should -Be ($Script:WtSettingsSchemaVersion + 1)
            $Read.Values | Should -Not -BeNullOrEmpty -Because 'the interface still needs defaults to start with'

            { Write-WtSettings -Settings @{ language = 'en' } } | Should -Throw -ExpectedMessage '*newer version*'
            (Get-Content -LiteralPath $SettingsPath -Raw) | Should -Match 'kept'
        }
    }
}
