# WindowsTweaker - device/driver inventory tests (read-only).
#
# The inventory is a provider over the CIM device/driver queries. On a non-Windows host it
# must report itself unavailable with a reason, never an empty success; on Windows the
# query is replaced by an in-memory double so states, hardware IDs, correlation confidence
# and the Driver Store split can be asserted without touching real hardware.

BeforeAll {
    $ModuleManifest = Join-Path $PSScriptRoot '../src/WindowsTweaker/WindowsTweaker.psd1'
    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-dev-{0}" -f ([guid]::NewGuid().ToString('n')))

    $env:WT_DATA_ROOT = $script:TestDataRoot
    $env:WT_STATE_PATH = Join-Path $script:TestDataRoot 'state.json'
    $env:WT_LOG_DIRECTORY = Join-Path $script:TestDataRoot 'logs'
    $env:WT_LANG = 'en'

    New-Item -ItemType Directory -Path $script:TestDataRoot -Force | Out-Null
    Import-Module $ModuleManifest -Force
}

AfterAll {
    Remove-Item -LiteralPath $script:TestDataRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_DATA_ROOT, Env:\WT_STATE_PATH, Env:\WT_LOG_DIRECTORY, Env:\WT_LANG -ErrorAction Ignore
}

Describe 'Device inventory' {

    It 'reports unavailable honestly on a non-Windows host' {
        InModuleScope WindowsTweaker {
            Mock Get-WtEnvironmentInternal {
                @{ PSTypeName = 'WindowsTweaker.Environment'; IsWindows = $false; OSBuild = 0 }
            }

            $Result = Get-WtDeviceInventoryInternal
            $Result.Available | Should -BeFalse
            $Result.Reason | Should -Not -BeNullOrEmpty
            @($Result.Devices).Count | Should -Be 0
            @($Result.Packages).Count | Should -Be 0
        }
    }

    It 'reports an unreadable query as unreadable, never as an empty success' {
        InModuleScope WindowsTweaker {
            Mock Get-WtEnvironmentInternal {
                @{ PSTypeName = 'WindowsTweaker.Environment'; IsWindows = $true; OSBuild = 26100 }
            }
            Mock Get-WtCimDriverRows {
                throw 'access denied'
            }

            $Result = Get-WtDeviceInventoryInternal
            $Result.Available | Should -BeFalse
            $Result.Reason | Should -Match 'failed'
        }
    }

    It 'separates present, non-present and problem devices and reports the binding correlation' {
        InModuleScope WindowsTweaker {
            Mock Get-WtEnvironmentInternal {
                @{ PSTypeName = 'WindowsTweaker.Environment'; IsWindows = $true; OSBuild = 26100 }
            }
            Mock Get-WtCimDriverRows {
                @(
                    [pscustomobject]@{
                        DeviceID = 'PCI\VEN_8086'; DeviceName = 'Graphics'; DeviceClass = 'Display'
                        ConfigManagerErrorCode = 0; Status = 'OK'
                        HardwareID = @('PCI\VEN_8086&DEV_9BC4'); InfName = 'display.inf'
                        DriverProviderName = 'Intel'; DriverVersion = '31.0.101.2125'; DriverDate = '2024'; SignerName = 'Microsoft Windows Hardware Compatibility Publisher'
                    }
                    [pscustomobject]@{
                        DeviceID = 'USB\VID_1234'; DeviceName = 'Old device'; DeviceClass = 'USB'
                        ConfigManagerErrorCode = 24; Status = 'Error'
                        HardwareID = @('USB\VID_1234&PID_5678'); InfName = ''; DriverProviderName = ''; DriverVersion = ''; DriverDate = ''; SignerName = ''
                    }
                    [pscustomobject]@{
                        DeviceID = 'SCSI\Disk0000'; DeviceName = 'Disk'; DeviceClass = 'SCSIAdapter'
                        ConfigManagerErrorCode = 10; Status = 'Degraded'
                        HardwareID = @('SCSI\Disk0000'); InfName = 'disk.inf'; DriverProviderName = 'Microsoft'; DriverVersion = '10.0'; DriverDate = ''; SignerName = ''
                    }
                )
            }
            Mock Get-ChildItem -ParameterFilter { $LiteralPath -like '*DriverStore*' } { @() }

            $Result = Get-WtDeviceInventoryInternal
            $Result.Available | Should -BeTrue
            $Devices = @($Result.Devices)
            $Devices.Count | Should -Be 3

            $Present = @($Devices | Where-Object { $_.State -eq 'Present' })
            $Present.Count | Should -Be 1
            $Present[0].Confidence | Should -Be 'DeviceDriverBinding'
            $Present[0].CorrelationSource | Should -Be 'Established'
            $Present[0].InfName | Should -Be 'display.inf'
            $Present[0].SignatureStatus | Should -Match 'Microsoft'

            $NonPresent = @($Devices | Where-Object { $_.State -eq 'NonPresent' })
            $NonPresent.Count | Should -Be 1
            $NonPresent[0].ConfigManagerErrorCode | Should -Be 24
            $NonPresent[0].CorrelationSource | Should -Be 'None'
            $NonPresent[0].Confidence | Should -Be 'DeviceOnly'

            $Problem = @($Devices | Where-Object { $_.State -eq 'PresentProblem' })
            $Problem.Count | Should -Be 1
        }
    }

    It 'lists Driver Store packages as packages, never as devices' {
        InModuleScope WindowsTweaker {
            Mock Get-WtEnvironmentInternal {
                @{ PSTypeName = 'WindowsTweaker.Environment'; IsWindows = $true; OSBuild = 26100 }
            }
            Mock Get-WtCimDriverRows { @() }
            Mock Test-WtDriverStorePath { $true }
            Mock Get-WtDriverStoreFolders {
                @(
                    [pscustomobject]@{ Name = 'display.inf_amd64_abc'; FullName = 'C:\Windows\System32\DriverStore\FileRepository\display.inf_amd64_abc' }
                    [pscustomobject]@{ Name = 'net.inf_amd64_def'; FullName = 'C:\Windows\System32\DriverStore\FileRepository\net.inf_amd64_def' }
                )
            }

            $Result = Get-WtDeviceInventoryInternal
            @($Result.Packages).Count | Should -Be 2
            @($Result.Packages | Where-Object { $_.IsDevice }).Count | Should -Be 0
            $Result.Packages[0].Name | Should -Be 'display.inf_amd64_abc'
        }
    }

    It 'public Get-WtDeviceInventory returns the inventory object with a state summary' {
        InModuleScope WindowsTweaker {
            Mock Get-WtDeviceInventoryInternal {
                @{
                    Available = $true
                    Reason = ''
                    Devices = @(
                        [pscustomobject]@{ State = 'Present'; Name = 'a' }
                        [pscustomobject]@{ State = 'NonPresent'; Name = 'b' }
                    )
                    Packages = @()
                }
            }

            $Inventory = Get-WtDeviceInventory
            $Inventory.Available | Should -BeTrue
            $Inventory.StateSummary.Present | Should -Be 1
            $Inventory.StateSummary.NonPresent | Should -Be 1
        }
    }
}
