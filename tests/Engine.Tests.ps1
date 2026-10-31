# WindowsTweaker - core engine tests.
#
# These run on any platform. Platform-dependent seams are replaced by in-memory
# doubles (registry, services, scheduled tasks, firewall, DNS, Appx, Defender) so the
# framework logic - state capture, dry run, verification, rollback, logging, policy
# and dependency handling - is exercised without touching a real system.
#
# The real Windows integration checks that cannot run here are listed in
# VALIDATION.md.

BeforeAll {
    $ModuleManifest = Join-Path $PSScriptRoot '../src/WindowsTweaker/WindowsTweaker.psd1'
    $TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-tests-{0}" -f ([guid]::NewGuid().ToString('n')))

    $env:WT_DATA_ROOT = $TestDataRoot
    $env:WT_STATE_PATH = Join-Path $TestDataRoot 'state.json'
    $env:WT_LOG_DIRECTORY = Join-Path $TestDataRoot 'logs'
    $env:WT_LANG = 'en'

    # Providers use ConfirmImpact High for irreversible/destructive work. In an
    # automated run we never want an interactive confirmation prompt; tests assert
    # behaviour, not prompts.
    $ConfirmPreference = 'None'

    Import-Module $ModuleManifest -Force

    # In-memory doubles for every platform seam, plus a Windows 11 / elevated
    # environment. Invoked from BeforeEach so each test starts from a clean slate.
    $script:InitializeWtPlatformMock = {
        InModuleScope WindowsTweaker {
            $Script:TestRegistry = @{}
            $Script:TestKeys = @{}
            $Script:TestKeyContents = @{}
            $Script:TestServices = @{}
            $Script:TestDns = @{}
            $Script:TestTasks = @{}
            $Script:TestFirewall = @{}

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

            # Treat platform cmdlets as present; the missing-dependency path has its
            # own dedicated test that deliberately does not use this mock.
            Mock Test-WtCapability {
                param ($Name, $Environment)
                @{ Name = $Name; Available = $true; Reason = ''; Kind = 'Mocked' }
            }

            Mock Test-WtRegistryAvailable { $true }
            Mock Test-WtServiceAvailable { $true }
            Mock Test-WtScheduledTaskAvailable { $true }
            Mock Test-WtDnsAvailable { $true }
            Mock Test-WtAppxAvailable { $true }
            Mock Test-WtDefenderAvailable { $true }
            Mock Test-WtRegistryKeyRaw {
                param ($Path)
                $Script:TestKeys.ContainsKey($Path) -or
                    $Script:TestRegistry.ContainsKey($Path) -or
                    @($Script:TestRegistry.Keys | Where-Object { $_ -like "$Path|*" }).Count -gt 0
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
                $Script:TestRegistry["$Path|$Name"] = @{ Kind = $Kind; Value = $Value }
            }

            Mock Remove-WtRegistryPropertyRaw {
                param ($Path, $Name)
                $Script:TestRegistry.Remove("$Path|$Name")
            }

            Mock New-WtRegistryKeyRaw {
                param ($Path)
                $Script:TestKeys[$Path] = $true
            }
            Mock Remove-WtRegistryKeyRaw {
                param ($Path, [switch]$Recurse)
                $Script:TestKeys.Remove($Path)
                $Script:TestKeyContents.Remove($Path)
            }
            Mock Get-WtRegistryKeyContentRaw {
                param ($Path)

                if (-not $Script:TestKeys.ContainsKey($Path))
                {
                    return @{ Exists = $false; Values = 0; SubKeys = 0; Inspected = $false }
                }

                if ($Script:TestKeyContents.ContainsKey($Path))
                {
                    return @{ Exists = $true; Values = $Script:TestKeyContents[$Path].Values; SubKeys = $Script:TestKeyContents[$Path].SubKeys; Inspected = $true }
                }

                return @{ Exists = $true; Values = 0; SubKeys = 0; Inspected = $true }
            }

            Mock Get-WtServiceSnapshot {
                param ($Name)
                if ($Script:TestServices.ContainsKey($Name))
                {
                    $Service = $Script:TestServices[$Name]
                    return [pscustomobject]@{ PSTypeName = 'WindowsTweaker.ServiceState'; Name = $Name; Available = $true; Exists = $true; StartupType = $Service.StartupType; Status = $Service.Status }
                }

                return [pscustomobject]@{ PSTypeName = 'WindowsTweaker.ServiceState'; Name = $Name; Available = $true; Exists = $false; StartupType = $null; Status = $null }
            }

            Mock Set-WtServiceStartupTypeRaw { param ($Name, $StartupType) $Script:TestServices[$Name].StartupType = $StartupType }
            Mock Start-WtServiceRaw { param ($Name) $Script:TestServices[$Name].Status = 'Running' }
            Mock Stop-WtServiceRaw { param ($Name) $Script:TestServices[$Name].Status = 'Stopped' }

            Mock Test-WtFirewallAvailable { $true }
            Mock Get-WtFirewallGroupSnapshot {
                param ($Group)
                $Rules = if ($Script:TestFirewall.ContainsKey($Group)) { $Script:TestFirewall[$Group] } else { @() }
                [pscustomobject]@{ PSTypeName = 'WindowsTweaker.FirewallGroupState'; Group = $Group; Available = $true; Rules = @($Rules) }
            }
            Mock Set-WtFirewallRuleRaw { param ($Name, $Enabled, $Action) $Script:TestFirewallCalls += @{ Name = $Name; Enabled = $Enabled; Action = $Action } }

            $Script:TestFirewallCalls = @()

            Mock Get-WtDnsServerAddressRaw { param ($InterfaceIndex) @($Script:TestDns[$InterfaceIndex]['Addresses']) }
            Mock Set-WtDnsServerAddressRaw {
                param ($InterfaceIndex, $ServerAddresses)
                $Script:TestDns[$InterfaceIndex]['Addresses'] = @($ServerAddresses)
                $Script:TestDns[$InterfaceIndex]['Automatic'] = $false
            }
            Mock Reset-WtDnsServerAddressRaw {
                param ($InterfaceIndex)
                $Script:TestDns[$InterfaceIndex]['Addresses'] = @()
                $Script:TestDns[$InterfaceIndex]['Automatic'] = $true
            }
            Mock Clear-WtDnsResolverCacheRaw { }

            Initialize-WtLogging -Console $false -Force | Out-Null
        }
    }

    $script:ResetWtTestState = {
        Remove-Item -LiteralPath (Join-Path $TestDataRoot 'state.json') -Force -ErrorAction Ignore
    }
}

AfterAll {
    Remove-Module WindowsTweaker -Force -ErrorAction Ignore
    Remove-Item -LiteralPath $TestDataRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_DATA_ROOT, Env:\WT_STATE_PATH, Env:\WT_LOG_DIRECTORY, Env:\WT_LANG -ErrorAction Ignore
}

Describe 'In-memory providers: state capture, dry run and rollback' {

    BeforeEach {
        & $script:InitializeWtPlatformMock
        & $script:ResetWtTestState
    }

    It 'reports the state of an unset registry tweak as Unknown without writing anything' {
        $State = Get-WtTweakState -Id 'Privacy.AdvertisingId'
        $State.State | Should -Be 'Unknown'
        $State.Supported | Should -BeTrue

        InModuleScope WindowsTweaker {
            $Script:TestRegistry.Count | Should -Be 0
        }
    }

    It 'does not write registry values or capture state during a dry run' {
        $Result = Invoke-WtTweak -Id 'Privacy.AdvertisingId' -State Disabled -WhatIf

        $Result.Status | Should -Be 'dryrun'
        $Result.CapturedState | Should -BeFalse
        @($Result.Operations | Where-Object { $_.Status -eq 'dryrun' }).Count | Should -BeGreaterThan 0

        InModuleScope WindowsTweaker {
            $Script:TestRegistry.Count | Should -Be 0
        }

        Test-Path -LiteralPath (Join-Path $TestDataRoot 'state.json') | Should -BeFalse
    }

    It 'applies a change, captures the exact previous state and restores it on rollback' {
        InModuleScope WindowsTweaker {
            $Script:TestRegistry['HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo|Enabled'] = @{ Kind = 'DWord'; Value = 1 }
        }

        $Result = Invoke-WtTweak -Id 'Privacy.AdvertisingId' -State Disabled
        $Result.Status | Should -Be 'succeeded'
        $Result.CapturedState | Should -BeTrue

        InModuleScope WindowsTweaker {
            $Script:TestRegistry['HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo|Enabled'].Value | Should -Be 0
        }

        (Get-WtTweakState -Id 'Privacy.AdvertisingId').State | Should -Be 'Disabled'

        $Rollback = Undo-WtTweak -Id 'Privacy.AdvertisingId' -Confirm:$false
        $Rollback.Status | Should -Be 'succeeded'

        InModuleScope WindowsTweaker {
            # Exactly the captured value and kind, not a hard-coded default.
            $Script:TestRegistry['HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo|Enabled'].Value | Should -Be 1
            $Script:TestRegistry['HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo|Enabled'].Kind | Should -Be 'DWord'
        }

        (Get-WtHistory -TweakId 'Privacy.AdvertisingId').RolledBack | Should -BeTrue
    }

    It 'rolls back a tweak that needs elevation to the captured multi-value state' {
        InModuleScope WindowsTweaker {
            $Script:TestRegistry['HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo|DisabledByGroupPolicy'] = @{ Kind = 'DWord'; Value = 1 }
        }

        Invoke-WtTweak -Id 'Privacy.AdvertisingId' -State Enabled | Out-Null

        InModuleScope WindowsTweaker {
            $Script:TestRegistry.ContainsKey('HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo|DisabledByGroupPolicy') | Should -BeFalse
        }

        Undo-WtTweak -Id 'Privacy.AdvertisingId' -Confirm:$false | Out-Null

        InModuleScope WindowsTweaker {
            $Script:TestRegistry['HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo|DisabledByGroupPolicy'].Value | Should -Be 1
        }
    }

    It 'removes a value that did not exist before the change when rolling back' {
        $Result = Invoke-WtTweak -Id 'Privacy.AdvertisingId' -State Disabled
        $Result.Status | Should -Be 'succeeded'

        Undo-WtTweak -Id 'Privacy.AdvertisingId' -Confirm:$false | Out-Null

        InModuleScope WindowsTweaker {
            $Script:TestRegistry.ContainsKey('HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo|Enabled') | Should -BeFalse
        }
    }

    It 'does not treat an unchanged value as a new change' {
        InModuleScope WindowsTweaker {
            $Script:TestRegistry['HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo|Enabled'] = @{ Kind = 'DWord'; Value = 0 }
        }

        $Result = Invoke-WtTweak -Id 'Privacy.AdvertisingId' -State Disabled
        $Result.Status | Should -Be 'unchanged'
        $Result.CapturedState | Should -BeFalse
    }

    It 'refuses to apply a tweak whose dependencies are missing, and explains why' {
        InModuleScope WindowsTweaker {
            Mock Test-WtCapability {
                param ($Name, $Environment)
                @{ Name = $Name; Available = $false; Reason = "missing: $Name"; Kind = 'Cmdlet' }
            }
        }

        $Result = Invoke-WtTweak -Id 'Apps.UninstallUwpPackage' -State Enabled -Arguments @{ PackageFullName = @('Some.App_1.0.0.0_x64__abc') }
        $Result.Status | Should -Be 'unsupported'
        @($Result.Operations).Count | Should -Be 0
        $Result.Messages -join ' ' | Should -Match 'missing'
    }

    It 'reports a failed operation instead of a success' {
        InModuleScope WindowsTweaker {
            Mock Set-WtRegistryValueRaw { param ($Path, $Name, $Value, $Kind) throw 'access denied' }
        }

        $Result = Invoke-WtTweak -Id 'Privacy.AdvertisingId' -State Disabled
        $Result.Status | Should -Be 'failed'
        @($Result.Operations | Where-Object { $_.Status -eq 'failed' }).Count | Should -BeGreaterThan 0
        $Result.Messages -join ' ' | Should -Match 'failed'
    }

    It 'captures and restores a service configuration for scripted tweaks' {
        InModuleScope WindowsTweaker {
            $Script:TestServices['DiagTrack'] = @{ StartupType = 'Automatic'; Status = 'Running' }
            $Script:TestFirewall['DiagTrack'] = @([pscustomobject]@{ Name = 'DiagTrack-1'; DisplayName = 'DiagTrack'; Enabled = 'True'; Action = 'Allow' })
        }

        $Result = Invoke-WtTweak -Id 'System.DiagTrackService' -State Disabled
        $Result.Status | Should -Be 'succeeded'

        InModuleScope WindowsTweaker {
            $Script:TestServices['DiagTrack'].StartupType | Should -Be 'Disabled'
            $Script:TestServices['DiagTrack'].Status | Should -Be 'Stopped'
            $Script:TestFirewallCalls[-1].Action | Should -Be 'Block'
        }

        Undo-WtTweak -Id 'System.DiagTrackService' -Confirm:$false | Out-Null

        InModuleScope WindowsTweaker {
            $Script:TestServices['DiagTrack'].StartupType | Should -Be 'Automatic'
            $Script:TestServices['DiagTrack'].Status | Should -Be 'Running'
            $Script:TestFirewallCalls[-1].Action | Should -Be 'Allow'
        }
    }

    It 'reports a protection-reducing tweak as protection-reducing' {
        $State = Get-WtTweakState -Id 'Security.ControlledFolderAccess'
        $State.ReducesProtection | Should -BeTrue
        $State.Risk | Should -Be 'High'
        $State.Impact | Should -Match 'ransomware'
    }

    It 'reports a managed setting as managed by policy' {
        InModuleScope WindowsTweaker {
            $Script:TestRegistry['HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection|AllowTelemetry'] = @{ Kind = 'DWord'; Value = 1 }
        }

        $State = Get-WtTweakState -Id 'Privacy.DiagnosticDataLevel'
        $State.Managed | Should -BeTrue
        $State.ManagedBy | Should -Match 'AllowTelemetry'
    }

    It 'writes structured log records with a status per operation' {
        Invoke-WtTweak -Id 'Privacy.AdvertisingId' -State Disabled | Out-Null

        $LogFile = Get-WtLogPath
        Test-Path -LiteralPath $LogFile | Should -BeTrue

        $Records = @(Get-Content -LiteralPath $LogFile | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        @($Records | Where-Object { $_.status -eq 'succeeded' }).Count | Should -BeGreaterThan 0
    }
}

Describe 'Registry key lifecycle' {

    BeforeEach {
        & $script:InitializeWtPlatformMock
        & $script:ResetWtTestState
    }

    It 'removes a key it created when rolling back' {
        InModuleScope WindowsTweaker {
            $Entry = New-WtHistoryEntry -TweakId 'Test.KeyLifecycle' -State 'Enabled'
            Set-WtOperationContext -HistoryEntry $Entry -Phase 'apply' -SuppressConfirm $true

            $Result = New-WtRegistryKey -Path 'HKCU:\Software\WindowsTweakerTest'

            $Result.Status | Should -Be 'succeeded'
            @($Entry.records).Count | Should -Be 1
            $Entry.records[0].resource | Should -Be 'RegistryKey'
            $Entry.records[0].existed | Should -BeFalse
            $Script:TestKeys.ContainsKey('HKCU:\Software\WindowsTweakerTest') | Should -BeTrue

            Set-WtOperationContext -HistoryEntry $null -Phase 'none' -SuppressConfirm $false

            # Roll back through the same entry point the public API uses.
            $Rollback = @(Invoke-WtRollback -HistoryEntry $Entry)
            $Rollback[0].Status | Should -Be 'succeeded'
            $Rollback[0].Operation | Should -Be 'RemoveRegistryKey'
            $Script:TestKeys.ContainsKey('HKCU:\Software\WindowsTweakerTest') | Should -BeFalse
        }
    }

    It 'keeps a key it created when something else put data in it' {
        InModuleScope WindowsTweaker {
            $Entry = New-WtHistoryEntry -TweakId 'Test.KeyLifecycle' -State 'Enabled'
            Set-WtOperationContext -HistoryEntry $Entry -Phase 'apply' -SuppressConfirm $true
            New-WtRegistryKey -Path 'HKCU:\Software\WindowsTweakerTest' | Out-Null
            Set-WtOperationContext -HistoryEntry $null -Phase 'none' -SuppressConfirm $false

            # Another component wrote a value into the key in the meantime.
            $Script:TestKeyContents['HKCU:\Software\WindowsTweakerTest'] = @{ Values = 1; SubKeys = 0 }

            $Rollback = @(Invoke-WtRollback -HistoryEntry $Entry)
            $Rollback[0].Status | Should -Be 'skipped'
            $Script:TestKeys.ContainsKey('HKCU:\Software\WindowsTweakerTest') | Should -BeTrue
        }
    }

    It 'does not create the key during a dry run' {
        InModuleScope WindowsTweaker {
            $Result = New-WtRegistryKey -Path 'HKCU:\Software\WindowsTweakerTest' -WhatIf
            $Result.Status | Should -Be 'dryrun'
            $Script:TestKeys.ContainsKey('HKCU:\Software\WindowsTweakerTest') | Should -BeFalse
        }
    }
}

Describe 'UWP removal selection rules' {

    BeforeEach {
        & $script:InitializeWtPlatformMock
        & $script:ResetWtTestState
    }

    It 'selects no packages by default and refuses to apply without an explicit list' {
        InModuleScope WindowsTweaker {
            Mock Get-WtAppxPackageInfo {
                @([pscustomobject]@{
                    PSTypeName      = 'WindowsTweaker.AppxPackage'
                    Name            = 'Contoso.Sample'
                    PackageFullName = 'Contoso.Sample_1.0.0.0_x64__abc'
                    Version         = '1.0.0.0'
                    IsFramework     = $false
                    IsResourcePackage = $false
                    NonRemovable    = $false
                    Protected       = $false
                    Scope           = 'CurrentUser'
                })
            }
        }

        $State = Get-WtTweakState -Id 'Apps.UninstallUwpPackage'
        $State.State | Should -Be 'Disabled' -Because $State.Details
        $State.DefaultState | Should -Be 'Disabled'
        @($State.Instances).Count | Should -Be 1

        $Result = Invoke-WtTweak -Id 'Apps.UninstallUwpPackage' -State Enabled
        $Result.Status | Should -Be 'failed'
        $Result.Rollback | Should -Be 'None'
        $Result.Irreversible | Should -BeTrue
    }

    It 'never removes a protected package' {
        InModuleScope WindowsTweaker {
            Mock Get-WtAppxPackageRaw {
                @([pscustomobject]@{
                    Name            = 'Microsoft.WindowsStore'
                    PackageFullName = 'Microsoft.WindowsStore_1.0.0.0_x64__8wekyb3d8bbwe'
                    Version         = '1.0.0.0'
                    Publisher       = 'CN=Microsoft'
                    IsFramework     = $false
                    IsResourcePackage = $false
                    NonRemovable    = $false
                    SignatureKind   = 'Store'
                })
            }
        }

        $Result = Invoke-WtTweak -Id 'Apps.UninstallUwpPackage' -State Enabled -Arguments @{ PackageFullName = @('Microsoft.WindowsStore_1.0.0.0_x64__8wekyb3d8bbwe') }
        $Result.Status | Should -Be 'skipped'
        $Result.Operations[0].Status | Should -Be 'skipped'
        $Result.Operations[0].Message | Should -Match 'protected'
    }

    It 'removes only the package identities that were listed' {
        InModuleScope WindowsTweaker {
            $Script:TestInstalledPackages = @(
                [pscustomobject]@{ Name = 'Contoso.Sample'; PackageFullName = 'Contoso.Sample_1.0.0.0_x64__abc'; Version = '1.0.0.0'; Publisher = 'CN=Contoso'; IsFramework = $false; IsResourcePackage = $false; NonRemovable = $false; SignatureKind = 'Store' }
                [pscustomobject]@{ Name = 'Contoso.Other'; PackageFullName = 'Contoso.Other_2.0.0.0_x64__abc'; Version = '2.0.0.0'; Publisher = 'CN=Contoso'; IsFramework = $false; IsResourcePackage = $false; NonRemovable = $false; SignatureKind = 'Store' }
            )
            $Script:TestRemovedPackages = @()

            Mock Get-WtAppxPackageRaw {
                param ($Name, [switch]$AllUsers)
                @($Script:TestInstalledPackages | Where-Object { $Script:TestRemovedPackages -notcontains $_.PackageFullName })
            }
            Mock Remove-WtAppxPackageRaw {
                param ($PackageFullName, [switch]$AllUsers)
                $Script:TestRemovedPackages += $PackageFullName
            }
        }

        $Result = Invoke-WtTweak -Id 'Apps.UninstallUwpPackage' -State Enabled -Arguments @{ PackageFullName = @('Contoso.Sample_1.0.0.0_x64__abc') }
        $Result.Status | Should -Be 'succeeded'
        $Result.Operations[0].Target | Should -Be 'Contoso.Sample_1.0.0.0_x64__abc'

        InModuleScope WindowsTweaker {
            Should -Invoke Remove-WtAppxPackageRaw -Times 1 -Exactly
            $Script:TestRemovedPackages | Should -Be @('Contoso.Sample_1.0.0.0_x64__abc')
        }
    }
}

Describe 'Selected-adapter DNS changes' {

    BeforeEach {
        & $script:InitializeWtPlatformMock
        & $script:ResetWtTestState

        InModuleScope WindowsTweaker {
            $Script:TestDns = @{
                7  = @{ Automatic = $false; Addresses = @('9.9.9.9', '149.112.112.112') }
                12 = @{ Automatic = $true; Addresses = @() }
            }

            Mock Get-WtNetworkAdapterInternal {
                @(
                    [pscustomobject]@{ Name = 'Ethernet'; InterfaceIndex = 7; InterfaceGuid = 'guid-7'; Description = 'Realtek'; Status = 'Up'; IsPhysical = $true; IsVirtualOrTunnel = $false; MediaType = '802.3' }
                    [pscustomobject]@{ Name = 'VPN'; InterfaceIndex = 12; InterfaceGuid = 'guid-12'; Description = 'WireGuard'; Status = 'Up'; IsPhysical = $false; IsVirtualOrTunnel = $true; MediaType = 'Tunnel' }
                )
            }
        }
    }

    It 'changes only the adapter that was selected and restores its previous servers' {
        $Result = Invoke-WtTweak -Id 'Network.DnsOverHttps' -State Enabled -Arguments @{
            InterfaceIndex  = @(7, 12)
            ServerAddresses = @('1.1.1.1', '1.0.0.1')
        }

        $Result.Status | Should -Be 'succeeded'
        ($Result.Operations | Where-Object { $_.Status -eq 'skipped' })[0].Target | Should -Be 'VPN'

        InModuleScope WindowsTweaker {
            $Script:TestDns[7]['Addresses'][0] | Should -Be '1.1.1.1'
            # The VPN adapter keeps its own configuration.
            $Script:TestDns[12]['Automatic'] | Should -BeTrue
        }

        Undo-WtTweak -Id 'Network.DnsOverHttps' -Confirm:$false | Out-Null

        InModuleScope WindowsTweaker {
            $Script:TestDns[7]['Addresses'][0] | Should -Be '9.9.9.9'
            $Script:TestDns[7]['Addresses'][1] | Should -Be '149.112.112.112'
        }
    }

    It 'never writes DNS settings during a dry run' {
        $Result = Invoke-WtTweak -Id 'Network.DnsOverHttps' -State Enabled -Arguments @{
            InterfaceIndex  = @(7)
            ServerAddresses = @('1.1.1.1')
        } -WhatIf

        $Result.Status | Should -Be 'dryrun'
        $Result.CapturedState | Should -BeFalse

        InModuleScope WindowsTweaker {
            Should -Invoke Set-WtDnsServerAddressRaw -Times 0 -Exactly
            $Script:TestDns[7]['Addresses'][0] | Should -Be '9.9.9.9'
        }
    }

    It 'refuses to apply without an explicit adapter selection' {
        $Result = Invoke-WtTweak -Id 'Network.DnsOverHttps' -State Enabled
        $Result.Status | Should -Be 'failed'
        $Result.Operations[0].Message | Should -Match 'InterfaceIndex'
    }
}
