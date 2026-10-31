# WindowsTweaker - capability-loss disclosure tests.
#
# The disclosure is metadata that may stop working after an action, declared per definition
# (catalog or PowerShell), validated at load time and aggregated across a selection by stable
# capability id. Everything here is read-only: the tests never mutate a registry, a file or
# a selection; they only check that declarations parse, attach and aggregate.

BeforeAll {
    $ModuleManifest = Join-Path $PSScriptRoot '../src/WindowsTweaker/WindowsTweaker.psd1'
    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-caploss-{0}" -f ([guid]::NewGuid().ToString('n')))

    $env:WT_DATA_ROOT = $script:TestDataRoot
    $env:WT_STATE_PATH = Join-Path $script:TestDataRoot 'state.json'
    $env:WT_LOG_DIRECTORY = Join-Path $script:TestDataRoot 'logs'
    $env:WT_PACKS_PATH = Join-Path $script:TestDataRoot 'packs'
    $env:WT_MIGRATIONS_PATH = Join-Path $script:TestDataRoot 'migrations.json'
    $env:WT_LANG = 'en'

    New-Item -ItemType Directory -Path $script:TestDataRoot -Force | Out-Null
    Import-Module $ModuleManifest -Force

    $script:WtTestParameters = @{ }
}

AfterAll {
    Remove-Item -LiteralPath $script:TestDataRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_DATA_ROOT, Env:\WT_STATE_PATH, Env:\WT_LOG_DIRECTORY, Env:\WT_PACKS_PATH, Env:\WT_MIGRATIONS_PATH, Env:\WT_LANG -ErrorAction Ignore
}

Describe 'Capability-loss declarations on catalog definitions' {

    It 'validates and attaches a well-formed capabilityLoss block' {
        InModuleScope WindowsTweaker {
            $Document = @{
                schemaVersion = 1
                kind          = 'Catalog'
                id            = 'test-caploss'
                version       = '1.0.0'
                tweaks        = @(
                    @{
                        id            = 'WtTest.Loss'
                        revision      = 1
                        category      = 'System'
                        names         = @{ en = 'Loss item'; vi = 'Muc mat' }
                        descriptions  = @{ en = 'Desc'; vi = 'Mo ta' }
                        impacts       = @{ en = 'Impact'; vi = 'Tac dong' }
                        sideEffects   = @{ en = 'Side'; vi = 'Tac dung phu' }
                        scope         = 'User'
                        lifecycle     = 'Available'
                        risk          = 'Low'
                        restart       = 'None'
                        rollback      = 'Full'
                        irreversible  = $false
                        dataDeletion  = $false
                        reducesProtection = $false
                        detection     = @{ hive = 'HKCU'; key = 'Software\WtTest\Loss'; name = 'Value'; map = @{ Enabled = @(1); Disabled = @(0) } }
                        states        = @{
                            Enabled  = @(@{ kind = 'RegistrySet'; hive = 'HKCU'; key = 'Software\WtTest\Loss'; name = 'Value'; type = 'DWord'; value = 1 })
                            Disabled = @(@{ kind = 'RegistrySet'; hive = 'HKCU'; key = 'Software\WtTest\Loss'; name = 'Value'; type = 'DWord'; value = 0 })
                        }
                        defaultState   = 'Enabled'
                        capabilityLoss = @(
                            @{
                                capability = 'power.test'
                                names      = @{ en = 'Test power loss'; vi = 'Mat nang luong test' }
                                kind       = 'Guaranteed'
                                temporary  = $false
                                restoredBy  = @{ en = 'Turn it back on'; vi = 'Bat lai' }
                                limitations = @{ en = 'Nothing else'; vi = 'Khong gi khac' }
                            }
                        )
                    }
                )
            }

            $Validation = Test-WtCatalogDocument -Document $Document -Source 'BuiltIn'
            $Validation.Errors | Should -BeNullOrEmpty
            $Validation.Tweaks.Count | Should -Be 1

            $Tweak = $Validation.Tweaks[0]
            $Tweak.CapabilityLoss.Count | Should -Be 1
            $Tweak.CapabilityLoss[0].Capability | Should -Be 'power.test'
            $Tweak.CapabilityLoss[0].Kind | Should -Be 'Guaranteed'
            $Tweak.CapabilityLoss[0].Temporary | Should -BeFalse
        }
    }

    It 'refuses duplicate capability ids within one definition' {
        InModuleScope WindowsTweaker {
            $Document = @{
                schemaVersion = 1
                kind          = 'Catalog'
                id            = 'test-caploss'
                tweaks        = @(
                    @{
                        id            = 'WtTest.Loss'
                        revision      = 1
                        category      = 'System'
                        names         = @{ en = 'Loss item'; vi = 'Muc mat' }
                        descriptions  = @{ en = 'Desc'; vi = 'Mo ta' }
                        impacts       = @{ en = 'Impact'; vi = 'Tac dong' }
                        sideEffects   = @{ en = 'Side'; vi = 'Tac dung phu' }
                        scope         = 'User'
                        lifecycle     = 'Available'
                        risk          = 'Low'
                        restart       = 'None'
                        rollback      = 'Full'
                        irreversible  = $false
                        dataDeletion  = $false
                        reducesProtection = $false
                        detection     = @{ hive = 'HKCU'; key = 'Software\WtTest\Loss'; name = 'Value'; map = @{ Enabled = @(1); Disabled = @(0) } }
                        states        = @{
                            Enabled  = @(@{ kind = 'RegistrySet'; hive = 'HKCU'; key = 'Software\WtTest\Loss'; name = 'Value'; type = 'DWord'; value = 1 })
                            Disabled = @(@{ kind = 'RegistrySet'; hive = 'HKCU'; key = 'Software\WtTest\Loss'; name = 'Value'; type = 'DWord'; value = 0 })
                        }
                        defaultState   = 'Enabled'
                        capabilityLoss = @(
                            @{ capability = 'power.test'; names = @{ en = 'One'; vi = 'Mot' }; kind = 'Guaranteed'; temporary = $false }
                            @{ capability = 'power.test'; names = @{ en = 'Two'; vi = 'Hai' }; kind = 'Conditional'; temporary = $true }
                        )
                    }
                )
            }

            $Validation = Test-WtCatalogDocument -Document $Document -Source 'BuiltIn'
            @($Validation.Errors | Where-Object { $_ -match 'declared twice' }).Count | Should -Be 1
        }
    }

    It 'refuses malformed disclosures' {
        InModuleScope WindowsTweaker {
            $Cases = @(
                @{ Name = 'unknown key'; Patch = @{ bogus = $true }; Match = 'bogus' }
                @{ Name = 'bad kind'; Patch = @{ kind = 'Maybe' }; Match = "not supported" }
                @{ Name = 'missing names'; Patch = @{ names = $null }; Match = 'names : required' }
                @{ Name = 'non-conditional with condition'; Patch = @{ kind = 'Guaranteed'; condition = @{ explanation = @{ en = 'x'; vi = 'y' } } }; Match = 'only a Conditional impact' }
                @{ Name = 'bad capability id'; Patch = @{ capability = 'Upper Case' }; Match = 'not a valid capability id' }
                @{ Name = 'condition without explanation'; Patch = @{ kind = 'Conditional'; condition = @{} }; Match = 'explanation : required' }
            )

            foreach ($Case in $Cases)
            {
                $Loss = @{
                    capability = 'power.test'
                    names      = @{ en = 'Test'; vi = 'Test' }
                    kind       = 'Conditional'
                    temporary  = $true
                }
                foreach ($Key in $Case.Patch.Keys) { $Loss[$Key] = $Case.Patch[$Key] }

                $Document = @{
                    schemaVersion = 1
                    kind          = 'Catalog'
                    id            = 'test-caploss'
                    tweaks        = @(
                        @{
                            id            = 'WtTest.Loss'
                            revision      = 1
                            category      = 'System'
                            names         = @{ en = 'Loss item'; vi = 'Muc mat' }
                            descriptions  = @{ en = 'Desc'; vi = 'Mo ta' }
                            impacts       = @{ en = 'Impact'; vi = 'Tac dong' }
                            sideEffects   = @{ en = 'Side'; vi = 'Tac dung phu' }
                            scope         = 'User'
                            lifecycle     = 'Available'
                            risk          = 'Low'
                            restart       = 'None'
                            rollback      = 'Full'
                            irreversible  = $false
                            dataDeletion  = $false
                            reducesProtection = $false
                            detection     = @{ hive = 'HKCU'; key = 'Software\WtTest\Loss'; name = 'Value'; map = @{ Enabled = @(1); Disabled = @(0) } }
                            states        = @{
                                Enabled  = @(@{ kind = 'RegistrySet'; hive = 'HKCU'; key = 'Software\WtTest\Loss'; name = 'Value'; type = 'DWord'; value = 1 })
                                Disabled = @(@{ kind = 'RegistrySet'; hive = 'HKCU'; key = 'Software\WtTest\Loss'; name = 'Value'; type = 'DWord'; value = 0 })
                            }
                            defaultState   = 'Enabled'
                            capabilityLoss = @($Loss)
                        }
                    )
                }

                $Validation = Test-WtCatalogDocument -Document $Document -Source 'BuiltIn'
                @($Validation.Errors | Where-Object { $_ -match $Case.Match }).Count | Should -Be 1 -Because $Case.Name
            }
        }
    }
}

Describe 'Capability-loss aggregation' {

    It 'deduplicates the same capability across definitions and names every cause' {
        InModuleScope WindowsTweaker {
            Mock Test-WtCapability { @{ Name = $Name; Available = $true; Reason = ''; Kind = 'Mocked' } }

            $A = Get-WtTweakInternal -Id 'System.Hibernation'
            $B = Get-WtTweakInternal -Id 'Maintenance.ThumbnailCacheCleanup'

            $Selection = @(
                @{ Tweak = $A; State = 'Disabled' }
                @{ Tweak = $B; State = 'Enabled' }
            )

            $Result = Get-WtCapabilityLossInternal -Selection $Selection
            $Impacts = @($Result.Impacts)

            # Thumbnail cache is guaranteed + temporary; hibernation is guaranteed + persistent.
            $Hit = @($Impacts | Where-Object { $_.Capability -eq 'explorer.thumbnails' })
            $Hit.Count | Should -Be 1
            $Hit[0].Causes.Count | Should -Be 1
            $Hit[0].Causes[0].TweakId | Should -Be 'Maintenance.ThumbnailCacheCleanup'
            $Hit[0].Temporary | Should -BeTrue
            $Hit[0].MixedTemporary | Should -BeFalse
        }
    }

    It 'merges kinds: any guaranteed wins, any unknown is reported' {
        InModuleScope WindowsTweaker {
            $Loss = @(
                @{ capability = 'power.test'; names = @{ en = 'Power'; vi = 'Nang luong' }; kind = 'Guaranteed'; temporary = $false }
            )

            $Tweak = New-WtScriptTweak -Id 'WtTest.LossA' -Category 'System' `
                -Name @{ en = 'A'; vi = 'A' } -Description @{ en = 'A'; vi = 'A' } -Impact @{ en = 'A'; vi = 'A' } `
                -CapabilityLoss $Loss `
                -Detect { param ($Tweak, $Arguments) @{ State = 'Enabled' } } `
                -Apply { param ($Tweak, $State, $Arguments) @() }

            $Selection = @(
                @{ Tweak = $Tweak; State = 'Enabled' }
                @{ Tweak = $Tweak; State = 'Enabled' }
            )

            $Result = Get-WtCapabilityLossInternal -Selection $Selection
            $Impact = @($Result.Impacts | Where-Object { $_.Capability -eq 'power.test' })[0]
            $Impact.AnyGuaranteed | Should -BeTrue
            $Impact.AnyUnknown | Should -BeFalse
            $Impact.Causes.Count | Should -Be 2
        }
    }

    It 'keeps unknown impacts with review flagged, never treating them as harmless' {
        InModuleScope WindowsTweaker {
            $Loss = @(
                @{ capability = 'unknown.test'; names = @{ en = 'Unknown'; vi = 'Chua ro' }; kind = 'Unknown'; temporary = $false }
            )

            $Tweak = New-WtScriptTweak -Id 'WtTest.LossU' -Category 'System' `
                -Name @{ en = 'U'; vi = 'U' } -Description @{ en = 'U'; vi = 'U' } -Impact @{ en = 'U'; vi = 'U' } `
                -CapabilityLoss $Loss `
                -Detect { param ($Tweak, $Arguments) @{ State = 'Enabled' } } `
                -Apply { param ($Tweak, $State, $Arguments) @() }

            $Result = Get-WtCapabilityLossInternal -Selection @(@{ Tweak = $Tweak; State = 'Enabled' })
            $Impact = @($Result.Impacts | Where-Object { $_.Capability -eq 'unknown.test' })[0]
            $Impact | Should -Not -BeNullOrEmpty
            $Impact.AnyUnknown | Should -BeTrue
            @($Result.NotApplicable).Count | Should -Be 0
        }
    }

    It 'moves condition-missing impacts to NotApplicable and keeps unreadable conditions as impacts' {
        InModuleScope WindowsTweaker {
            # Missing token -> condition not met -> NotApplicable.
            Mock Test-WtCapability { @{ Name = $Name; Available = $false; Reason = 'missing'; Kind = 'Cmdlet' } }

            $LossMissing = @(
                @{
                    capability = 'cond.missing'
                    names      = @{ en = 'Missing'; vi = 'Thieu' }
                    kind       = 'Conditional'
                    temporary  = $true
                    condition  = @{
                        explanation          = @{ en = 'when X'; vi = 'khi X' }
                        requiresCapabilities = @('Cmdlet:Get-X')
                    }
                }
            )
            $TweakMissing = New-WtScriptTweak -Id 'WtTest.LossM' -Category 'System' `
                -Name @{ en = 'M'; vi = 'M' } -Description @{ en = 'M'; vi = 'M' } -Impact @{ en = 'M'; vi = 'M' } `
                -CapabilityLoss $LossMissing `
                -Detect { param ($Tweak, $Arguments) @{ State = 'Enabled' } } `
                -Apply { param ($Tweak, $State, $Arguments) @() }

            $Result = Get-WtCapabilityLossInternal -Selection @(@{ Tweak = $TweakMissing; State = 'Enabled' })
            @($Result.Impacts).Count | Should -Be 0
            @($Result.NotApplicable).Count | Should -Be 1
            @($Result.NotApplicable)[0].Capability | Should -Be 'cond.missing'

            # Unreadable probe (kind unknown) -> stays an impact with a reason.
            Mock Test-WtCapability { @{ Name = $Name; Available = $false; Reason = 'cannot read'; Kind = 'unknown' } }
            $LossUnreadable = @(
                @{
                    capability = 'cond.unreadable'
                    names      = @{ en = 'Unreadable'; vi = 'Khong doc duoc' }
                    kind       = 'Conditional'
                    temporary  = $true
                    condition  = @{
                        explanation          = @{ en = 'when Y'; vi = 'khi Y' }
                        requiresCapabilities = @('Cmdlet:Get-Y')
                    }
                }
            )
            $TweakUnreadable = New-WtScriptTweak -Id 'WtTest.LossR' -Category 'System' `
                -Name @{ en = 'R'; vi = 'R' } -Description @{ en = 'R'; vi = 'R' } -Impact @{ en = 'R'; vi = 'R' } `
                -CapabilityLoss $LossUnreadable `
                -Detect { param ($Tweak, $Arguments) @{ State = 'Enabled' } } `
                -Apply { param ($Tweak, $State, $Arguments) @() }

            $Result = Get-WtCapabilityLossInternal -Selection @(@{ Tweak = $TweakUnreadable; State = 'Enabled' })
            $Impact = @($Result.Impacts | Where-Object { $_.Capability -eq 'cond.unreadable' })[0]
            $Impact | Should -Not -BeNullOrEmpty
            $Impact.Causes[0].Reason | Should -Match 'could not be fully evaluated'
            @($Result.NotApplicable).Count | Should -Be 0
        }
    }

    It 'renders localized lines with causes and restoration' {
        InModuleScope WindowsTweaker {
            Mock Test-WtCapability { @{ Name = $Name; Available = $true; Reason = ''; Kind = 'Mocked' } }

            $Tweak = Get-WtTweakInternal -Id 'System.Hibernation'
            $Result = Get-WtCapabilityLossInternal -Selection @(@{ Tweak = $Tweak; State = 'Disabled' })
            $LinesResult = Get-WtCapabilityLossLinesInternal -Result $Result
            $LinesResult.Count | Should -BeGreaterThan 0
            $Lines = @($LinesResult.Lines -join "`n")
            $Lines | Should -Match 'Hibernation'
            $Lines | Should -Match 'Caused by: System.Hibernation -> Disabled'
            $Lines | Should -Match 'Restored by:'
        }
    }

    It 'public Get-WtCapabilityLoss resolves aliases through the migration registry' {
        InModuleScope WindowsTweaker {
            $Result = Get-WtCapabilityLoss -Id 'System.Hibernation'
            @($Result.Impacts).Count | Should -Be 1
            @($Result.Impacts)[0].Capability | Should -Be 'power.hibernation'
        }
    }

    It 'the review selection includes pending entries and plan prerequisites once' {
        InModuleScope WindowsTweaker {
            $State = @{ Pending = @{} }
            $State.Pending['System.Hibernation'] = @{ Id = 'System.Hibernation'; Target = 'Disabled' }
            $State.Pending['Maintenance.ThumbnailCacheCleanup'] = @{ Id = 'Maintenance.ThumbnailCacheCleanup'; Target = 'Enabled' }

            $Plan = @{ Items = @(
                    @{ Id = 'Maintenance.ThumbnailCacheCleanup'; State = 'Enabled'; Action = 'Apply' }
                    @{ Id = 'System.Hibernation'; State = 'Disabled'; Action = 'Apply' }
                    @{ Id = 'Privacy.AdvertisingId'; State = 'Disabled'; Action = 'Skip-Satisfied' }
                ) }

            $Selection = Get-WtSelectionForCapabilityLossInternal -State $State -Plan $Plan
            $Selection.Count | Should -Be 2 -Because 'the plan item already pending is not added twice, and a skipped prerequisite is not added'
            @($Selection | Where-Object { $_.Tweak.Id -eq 'System.Hibernation' }).Count | Should -Be 1
            @($Selection | Where-Object { $_.Tweak.Id -eq 'Maintenance.ThumbnailCacheCleanup' }).Count | Should -Be 1
        }
    }

    It 'a built-in tweak carries its disclosure through the details path' {
        InModuleScope WindowsTweaker {
            $Tweak = Get-WtTweakInternal -Id 'System.Hibernation'
            $Rows = Get-WtTweakCapabilityLossInternal -Tweak $Tweak -State 'Disabled'
            $Rows.Count | Should -Be 1
            $Rows[0].Capability | Should -Be 'power.hibernation'
            $Rows[0].Kind | Should -Be 'Guaranteed'
            $Rows[0].Applies | Should -BeTrue
        }
    }
}
