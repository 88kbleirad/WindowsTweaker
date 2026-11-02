# WindowsTweaker - Licensing & Activation Diagnostics tests.
#
# All tests mock the documented Windows providers (CIM SoftwareLicensingProduct, the
# w32time service, the Software Protection Service, Start-Process for the slmgr
# adapter). Nothing here touches a real license, activates anything, or changes system
# state.

BeforeAll {
    $script:ModuleManifest = Join-Path $PSScriptRoot '../src/WindowsTweaker/WindowsTweaker.psd1'
    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-licensing-{0}" -f ([guid]::NewGuid().ToString('n')))

    $env:WT_DATA_ROOT = $script:TestDataRoot
    $env:WT_STATE_PATH = Join-Path $script:TestDataRoot 'state.json'
    $env:WT_LOG_DIRECTORY = Join-Path $script:TestDataRoot 'logs'
    $env:WT_LANG = 'en'

    New-Item -ItemType Directory -Path $script:TestDataRoot -Force | Out-Null
    Import-Module $script:ModuleManifest -Force

    InModuleScope WindowsTweaker -Parameters @{ HelperPath = (Join-Path $PSScriptRoot 'TuiTestHelpers.ps1') } {
        . $HelperPath
    }
}

AfterAll {
    Remove-Module WindowsTweaker -Force -ErrorAction Ignore
    Remove-Item -LiteralPath $script:TestDataRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_DATA_ROOT, Env:\WT_STATE_PATH, Env:\WT_LOG_DIRECTORY, Env:\WT_LANG -ErrorAction Ignore
}

function Global:New-TestLicensingProduct
{
    param
    (
        [string]$Name = 'Windows(R), Professional edition',
        [string]$ApplicationId = '55c92734-d682-4d71-983e-d6ec3f16059f',
        [int]$LicenseStatus = 1,
        [string]$LicenseChannel = 'Volume:GVLK',
        [string]$PartialProductKey = 'ABC12',
        [int]$GraceRemaining = 0,
        [string]$EvaluationEndDate = '',
        [string]$Description = '',
        [string]$LicenseDependsOn = ''
    )

    [pscustomobject]@{
        Name = $Name
        ApplicationId = $ApplicationId
        LicenseStatus = $LicenseStatus
        LicenseChannel = $LicenseChannel
        PartialProductKey = $PartialProductKey
        GraceRemaining = $GraceRemaining
        EvaluationEndDate = $EvaluationEndDate
        Description = $Description
        LicenseDependsOn = $LicenseDependsOn
    }
}

Describe 'Licensing inventory and status mapping' {

    BeforeEach {
        InModuleScope WindowsTweaker {
            Clear-WtLicensingCache
        }
    }

    It 'picks the Windows product with the active status' {
        InModuleScope WindowsTweaker {
            Mock Test-WtLicensingAvailable { $true }
            Mock Get-WtLicensingCim {
                param ($ClassName)
                if ($ClassName -eq 'SoftwareLicensingProduct')
                {
                    return @(
                        (New-TestLicensingProduct -Name 'Windows(TM), Professional edition' -LicenseStatus 1),
                        (New-TestLicensingProduct -Name 'Windows(TM), Enterprise edition' -LicenseStatus 0)
                    )
                }
                return @()
            }

            $Inventory = Read-WtLicensingInventory -Refresh
            $Inventory.Unreadable | Should -BeFalse
            @($Inventory.Products).Count | Should -Be 2
            $Inventory.Active.LicenseStatus | Should -Be 'Licensed'
            $Inventory.Active.ProductName | Should -Be 'Windows(TM), Professional edition'
            $Inventory.Selection.MultipleWindowsRecords | Should -BeTrue
        }
    }

    It 'does not select an add-on or Office record, and does not force Licensed' {
        InModuleScope WindowsTweaker {
            Mock Test-WtLicensingAvailable { $true }
            Mock Get-WtLicensingCim {
                param ($ClassName)
                if ($ClassName -eq 'SoftwareLicensingProduct')
                {
                    return @(
                        # A Windows base record still in Notification state (raw 5).
                        (New-TestLicensingProduct -Name 'Windows(TM), IoTEnterpriseS edition' -LicenseStatus 5 -PartialProductKey 'GHI78'),
                        # An ESU add-on that depends on the base license.
                        (New-TestLicensingProduct -Name 'Windows ESU' -LicenseStatus 1 -LicenseDependsOn 'license-id' -PartialProductKey 'ADD9X'),
                        # An Office record with a different ApplicationId.
                        (New-TestLicensingProduct -Name 'Microsoft Office 2021' -ApplicationId '0ff1ce15-a989-479d-af46-f275c6370663' -LicenseStatus 1 -PartialProductKey 'OFF12')
                    )
                }
                return @()
            }

            $Inventory = Read-WtLicensingInventory -Refresh
            $Inventory.Active.LicenseStatus | Should -Be 'Notification'
            $Inventory.Active.LicenseStatusRaw | Should -Be 5
            @($Inventory.Dependents).Count | Should -Be 1
            $Inventory.Dependents[0].ProductName | Should -Be 'Windows ESU'
            @($Inventory.Products).Count | Should -Be 1
            $Inventory.Selection.Rule | Should -Be 'single-candidate'
        }
    }

    It 'prefers the activated record over a leftover Notification record' {
        InModuleScope WindowsTweaker {
            Mock Test-WtLicensingAvailable { $true }
            Mock Get-WtLicensingCim {
                param ($ClassName)
                if ($ClassName -eq 'SoftwareLicensingProduct')
                {
                    return @(
                        (New-TestLicensingProduct -Name 'Windows(TM), IoTEnterpriseS edition' -LicenseStatus 0 -PartialProductKey 'LEF34'),
                        (New-TestLicensingProduct -Name 'Windows(TM), IoTEnterpriseS 2024 edition' -LicenseStatus 1 -PartialProductKey 'ABC12')
                    )
                }
                return @()
            }

            $Inventory = Read-WtLicensingInventory -Refresh
            $Inventory.Active.LicenseStatus | Should -Be 'Licensed'
            $Inventory.Active.ProductName | Should -Be 'Windows(TM), IoTEnterpriseS 2024 edition'
        }
    }

    It 'reports a duplicate installed record without choosing the first one blindly' {
        InModuleScope WindowsTweaker {
            Mock Test-WtLicensingAvailable { $true }
            Mock Get-WtLicensingCim {
                param ($ClassName)
                if ($ClassName -eq 'SoftwareLicensingProduct')
                {
                    return @(
                        (New-TestLicensingProduct -Name 'Windows(TM), Pro edition' -LicenseStatus 1 -PartialProductKey 'KLM56'),
                        (New-TestLicensingProduct -Name 'Windows(TM), Pro edition' -LicenseStatus 1 -PartialProductKey 'NOP78')
                    )
                }
                return @()
            }

            $Inventory = Read-WtLicensingInventory -Refresh
            $Inventory.Active.LicenseStatus | Should -Be 'Licensed'
            $Inventory.Selection.MultipleWindowsRecords | Should -BeTrue
            $Inventory.Selection.CandidateCount | Should -BeGreaterOrEqual 2
        }
    }

    It 'maps every documented license status code to its label' {
        InModuleScope WindowsTweaker {
            $Expectations = @{
                0 = 'Unlicensed'
                1 = 'Licensed'
                2 = 'OOBGrace'
                3 = 'OOTGrace'
                4 = 'NonGenuineGrace'
                5 = 'Notification'
                6 = 'ExtendedGrace'
            }

            foreach ($Code in $Expectations.Keys)
            {
                $View = ConvertTo-WtLicensingView -Product (New-TestLicensingProduct -LicenseStatus $Code)
                $View.LicenseStatus | Should -Be $Expectations[$Code]
                $View.LicenseStatusRaw | Should -Be $Code
            }

            $Unknown = ConvertTo-WtLicensingView -Product (New-TestLicensingProduct -LicenseStatus 99)
            $Unknown.LicenseStatus | Should -Be 'Unknown'
        }
    }

    It 'does not return partial keys by default, and includes them on request' {
        InModuleScope WindowsTweaker {
            $Product = New-TestLicensingProduct -PartialProductKey 'XYZ99'
            # The view includes the partial key only when explicitly asked.
            $Default = ConvertTo-WtLicensingView -Product $Product
            $Default.PartialProductKey | Should -Be ''
            $Explicit = ConvertTo-WtLicensingView -Product $Product -IncludePartialKey:$true
            $Explicit.PartialProductKey | Should -Be 'XYZ99'

            Mock Test-WtLicensingAvailable { $true }
            Mock Get-WtLicensingCim { @((New-TestLicensingProduct -PartialProductKey 'XYZ99')) }

            $Without = Get-WtLicensingDiagnostics -Refresh
            $Without.Inventory.Active.PartialProductKey | Should -Be ''
            $Without.Inventory.Active.PartialProductKey | Should -Not -Be (New-TestLicensingProduct).PartialProductKey

            $With = Get-WtLicensingDiagnostics -Refresh -IncludePartialKey
            $With.Inventory.Active.PartialProductKey | Should -Be 'XYZ99'
        }
    }

    It 'reports unreadable provider state instead of inventing a status' {
        InModuleScope WindowsTweaker {
            Mock Test-WtLicensingAvailable { $true }
            Mock Get-WtLicensingCim { throw 'access denied' }

            $Inventory = Read-WtLicensingInventory -Refresh
            $Inventory.Unreadable | Should -BeTrue
            $Inventory.Active | Should -BeNullOrEmpty
            $Inventory.Reason | Should -Match 'access denied'
        }
    }

    It 'reports the provider as unsupported on non-Windows' {
        InModuleScope WindowsTweaker {
            Mock Test-WtLicensingAvailable { $false }
            $Inventory = Read-WtLicensingInventory -Refresh
            $Inventory.Unreadable | Should -BeTrue
            $Inventory.Reason | Should -Match 'only available on Windows'
        }
    }
}

Describe 'Licensing cache and staleness' {

    BeforeEach {
        InModuleScope WindowsTweaker {
            Clear-WtLicensingCache
        }
    }

    It 'serves the cached inventory until an explicit refresh replaces it' {
        InModuleScope WindowsTweaker {
            Mock Test-WtLicensingAvailable { $true }
            $script:Calls = 0
            Mock Get-WtLicensingCim {
                $script:Calls++
                return @((New-TestLicensingProduct -LicenseStatus 0))
            }

            $null = Read-WtLicensingInventory
            $Second = Read-WtLicensingInventory
            $script:Calls | Should -Be 1

            $Third = Read-WtLicensingInventory -Refresh
            $script:Calls | Should -Be 2
            $Third.CollectedUtc | Should -BeGreaterOrEqual $Second.CollectedUtc
        }
    }

    It 'bypasses the cache on every explicit and post-operation refresh' {
        InModuleScope WindowsTweaker {
            Mock Test-WtLicensingAvailable { $true }
            $script:ProductCalls = 0
            Mock Get-WtLicensingCim {
                param ($ClassName)
                if ($ClassName -eq 'SoftwareLicensingProduct') { $script:ProductCalls++ }
                return @((New-TestLicensingProduct -LicenseStatus 1))
            }

            $null = Get-WtLicensingDiagnostics
            $null = Get-WtLicensingDiagnostics -Refresh
            $null = Get-WtLicensingDiagnostics -Refresh
            $script:ProductCalls | Should -Be 3
        }
    }

    It 'reports stale snapshots explicitly' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Width 100 -Height 30
            Initialize-WtTuiState -State $State
            $State.Licensing = [ordered]@{
                CollectedUtc = [datetime]::UtcNow.AddMinutes(-20)
                Inventory = [ordered]@{ Unreadable = $false; Active = [pscustomobject]@{ LicenseStatus = 'Licensed'; LicenseStatusRaw = 1; ProductName = 'Windows 11 Pro'; LicenseChannel = 'Retail'; GraceRemaining = $null; EvaluationEndDate = '' } }
                Time = [ordered]@{}
                Components = [ordered]@{}
                Org = [ordered]@{}
            }
            Set-WtLicensingUiSnapshot -State $State -License $State.Licensing -RawStatus $State.Licensing.Inventory.Active

            (Test-WtLicensingSnapshotFresh -State $State) | Should -BeFalse
            $Text = Get-WtObservedLicensingStatusText -State $State
            $Text | Should -Match 'Licensed'
        }
    }

    It 'keeps session outcome separate from the observed machine status' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Width 100 -Height 30
            Initialize-WtTuiState -State $State
            Set-WtLicensingUiSnapshot -State $State -License $null

            (Get-WtActivationOutcomeText -State $State) | Should -Match 'nothing run in this session'

            Set-WtLicensingUiOperation -State $State -Outcome 'activated'
            (Get-WtActivationOutcomeText -State $State) | Should -Match 'activated'
            (Get-WtLicensingUiState -State $State).OperationRanThisSession | Should -BeTrue
        }
    }

    It 'does not let an older poll overwrite a newer explicit refresh' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Width 100 -Height 30
            Initialize-WtTuiState -State $State

            # The workspace already holds a newer snapshot (CollectedUtc = now).
            $Newer = [ordered]@{
                CollectedUtc = [datetime]::UtcNow
                Inventory = [ordered]@{ Unreadable = $false; Active = [pscustomobject]@{ LicenseStatus = 'Licensed'; LicenseStatusRaw = 1; ProductName = 'Windows 11 Pro'; LicenseChannel = 'Retail' } }
                Time = [ordered]@{}
                Components = [ordered]@{}
                Org = [ordered]@{}
            }
            $State.Licensing = $Newer
            Set-WtLicensingUiSnapshot -State $State -License $Newer -RawStatus $Newer.Inventory.Active

            # The poll is a snapshot that is already older than what the workspace holds.
            $Older = [ordered]@{
                CollectedUtc = [datetime]::UtcNow.AddSeconds(-30)
                Inventory = [ordered]@{ Unreadable = $false; Active = [pscustomobject]@{ LicenseStatus = 'Notification'; LicenseStatusRaw = 5; ProductName = 'Windows(TM)'; LicenseChannel = 'Retail' } }
                Time = [ordered]@{}
                Components = [ordered]@{}
                Org = [ordered]@{}
            }
            Mock Read-WtLicensingDiagnostics { return $Older }

            $Ui = Get-WtLicensingUiState -State $State
            $Ui.OperationPollRemaining = 2
            $Ui.OperationPollNextUtc = [datetime]::UtcNow.AddSeconds(-1)

            Update-WtLicensingOperationPoll -State $State

            # The older response is discarded; the observed status stays the newer Licensed one.
            $State.Licensing.Inventory.Active.LicenseStatus | Should -Be 'Licensed'
            (Get-WtObservedLicensingStatusText -State $State) | Should -Match 'Licensed'
        }
    }
}

Describe 'Licensing edition label' {

    It 'derives the generation from the build, not the legacy registry name' {
        InModuleScope WindowsTweaker {
            $Environment = [pscustomobject]@{
                OSName = 'Windows 10 IoT Enterprise LTSC 2024'
                OSBuild = 26100
                OSEditionID = 'IoTEnterpriseS'
            }

            $Edition = Get-WtWindowsActivationEdition -Environment $Environment

            $Edition.Generation | Should -Be 'Windows11'
            $Edition.Name | Should -Match 'Windows 11'
            $Edition.Name | Should -Match 'IoT Enterprise LTSC'
            $Edition.RegistryName | Should -Be 'Windows 10 IoT Enterprise LTSC 2024'
            $Edition.EditionId | Should -Be 'IoTEnterpriseS'
        }
    }

    It 'falls back to the registry name when the edition id is missing' {
        InModuleScope WindowsTweaker {
            $Environment = [pscustomobject]@{ OSName = 'Windows 10 Enterprise'; OSBuild = 19045; OSEditionID = $null }
            $Edition = Get-WtWindowsActivationEdition -Environment $Environment
            $Edition.Generation | Should -Be 'Windows10'
            $Edition.Name | Should -Be 'Windows 10 Enterprise'
        }
    }
}

Describe 'slmgr comparison probe' {

    It 'runs the read-only probes and sanitizes the output' {
        InModuleScope WindowsTweaker {
            Mock Test-WtLicensingAvailable { $true }
            Mock Get-Command {
                param ($Name)
                if ($Name -match 'cscript') { return [pscustomobject]@{ Source = 'C:\Windows\System32\cscript.exe' } }
                if ($Name -match 'slmgr') { return [pscustomobject]@{ Source = 'C:\Windows\System32\slmgr.vbs' } }
                return $null
            }
            Mock Invoke-WtSlmgrProbe {
                param ($Argument)
                if ($Argument -eq '/xpr')
                {
                    return @{ Available = $true; Output = "ERROR CODE: 0x00000000`nWindows(R), Professional edition`nThe machine is permanently activated."; Error = '' }
                }
                return @{ Available = $true; Output = "License Status: Licensed`nPartial Product Key: ABC12`nKMS machine name from DNS: kms.example.internal"; Error = '' }
            }

            $Comparison = Get-WtSlmgrComparison
            $Comparison.Available | Should -BeTrue
            $Comparison.Xpr | Should -Match 'permanently activated'
            $Comparison.Dlv | Should -Match 'License Status'
            # Hostnames are sanitized.
            $Comparison.Dlv | Should -Not -Match 'kms\.example'
        }
    }
}

Describe 'Licensing time and components' {

    It 'reports time synchronization state and service start type' {
        InModuleScope WindowsTweaker {
            Mock Get-WtLicensingService {
                param ($Name)
                if ($Name -eq 'w32time') { return [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' } }
                return $null
            }
            Mock Get-WtLicensingCim { @() }
            Mock Get-WtLicensingTimeQuery { 'synchronized' }

            $Time = Read-WtLicensingTimeState
            $Time.Service | Should -Be 'Running'
            $Time.StartType | Should -Be 'Automatic'
        }
    }

    It 'reports a stopped time service as a finding, not a fault' {
        InModuleScope WindowsTweaker {
            Mock Get-WtLicensingService {
                param ($Name)
                return [pscustomobject]@{ Status = 'Stopped'; StartType = 'Manual' }
            }
            Mock Get-WtLicensingCim { @() }

            $Time = Read-WtLicensingTimeState
            $Time.Service | Should -Be 'Stopped'
            $Time.StartType | Should -Be 'Manual'
        }
    }

    It 'reads the Software Protection Service and the latest structured activation error' {
        InModuleScope WindowsTweaker {
            Mock Get-WtLicensingService {
                param ($Name)
                return [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' }
            }
            Mock Get-WtLicensingWinEvent {
                [pscustomobject]@{ Message = '0xC004F074'; TimeCreated = [datetime]::UtcNow }
            }

            $Components = Read-WtLicensingComponents
            $Components.Service | Should -Be 'Running'
            $Components.LastActivationError | Should -Match '0xC004F074'
        }
    }
}

Describe 'Organization-managed configuration' {

    It 'detects presence without exposing hostnames or keys' {
        InModuleScope WindowsTweaker {
            Mock Test-Path { param ($LiteralPath) $LiteralPath -match 'SoftwareProtectionPlatform' }
            $Org = Read-WtLicensingOrgConfig
            $Org.Managed | Should -BeTrue
            @($Org.Sources).Count | Should -BeGreaterThan 0
        }
    }

    It 'reports absence cleanly' {
        InModuleScope WindowsTweaker {
            Mock Test-Path { $false }
            $Org = Read-WtLicensingOrgConfig
            $Org.Managed | Should -BeFalse
        }
    }
}

Describe 'Activation request' {

    It 'publishes the accepted outcome and re-reads status; does not promise activation' {
        InModuleScope WindowsTweaker {
            Mock Test-WtLicensingAvailable { $true }
            Mock Get-Command {
                param ($Name)
                if ($Name -match 'cscript') { return [pscustomobject]@{ Source = 'C:\Windows\System32\cscript.exe' } }
                if ($Name -match 'slmgr') { return [pscustomobject]@{ Source = 'C:\Windows\System32\slmgr.vbs' } }
                return $null
            }
            $Script:Started = @()
            Mock Start-Process {
                param ($FilePath, $ArgumentList)
                $Script:Started += "$FilePath $($ArgumentList -join ' ')"
                return [pscustomobject]@{ ExitCode = 0 }
            }
            Mock Get-WtLicensingCim {
                @((New-TestLicensingProduct -LicenseStatus 1))
            }

            $Result = Invoke-WtLicensingActivationRequest -Refresh
            $Result.Requested | Should -BeTrue
            $Result.Accepted | Should -BeTrue
            @($Script:Started).Count | Should -Be 1
            ($Script:Started[0]) | Should -Match '/ato'
            $Result.StatusAfter.Active.LicenseStatus | Should -Be 'Licensed'
        }
    }

    It 'reports a failed request with its structured code and never claims success' {
        InModuleScope WindowsTweaker {
            Mock Test-WtLicensingAvailable { $true }
            Mock Get-Command {
                param ($Name)
                if ($Name -match 'cscript') { return [pscustomobject]@{ Source = 'C:\Windows\System32\cscript.exe' } }
                if ($Name -match 'slmgr') { return [pscustomobject]@{ Source = 'C:\Windows\System32\slmgr.vbs' } }
                return $null
            }
            Mock Start-Process { return [pscustomobject]@{ ExitCode = -1073418124 } }

            $Result = Invoke-WtLicensingActivationRequest
            $Result.Accepted | Should -BeFalse
            $Result.ErrorDetail | Should -Match '0xC004F074'
        }
    }

    It 'refuses the request when the provider is unavailable' {
        InModuleScope WindowsTweaker {
            Mock Test-WtLicensingAvailable { $false }
            $Result = Invoke-WtLicensingActivationRequest
            $Result.Requested | Should -BeFalse
            $Result.Reason | Should -Match 'only available on Windows'
        }
    }
}

Describe 'Activation evidence' {

    It 'takes a read-only snapshot without inventing validity' {
        InModuleScope WindowsTweaker {
            $License = [ordered]@{
                CollectedUtc = [datetime]::UtcNow
                Inventory = [ordered]@{
                    Unreadable = $false
                    Active = New-TestLicensingProduct -LicenseStatus 1 -GraceRemaining 90 -PartialProductKey 'ABC12'
                }
            }

            $Snapshot = Get-WtLicensingSnapshot -License $License

            $Snapshot.Readable | Should -BeTrue
            $Snapshot.Status | Should -Be 'Licensed'
            $Snapshot.StatusRaw | Should -Be 1
            $Snapshot.GraceRemaining | Should -Be 90
            $Snapshot.PartialKeyPresent | Should -BeTrue

            # The snapshot never carries the partial key value itself.
            ($Snapshot.PSObject.Properties.Name) | Should -Not -Contain 'PartialProductKey'
        }
    }

    It 'reports unreadable when the provider was unavailable' {
        InModuleScope WindowsTweaker {
            $Snapshot = Get-WtLicensingSnapshot -License ([ordered]@{ Inventory = [ordered]@{ Unreadable = $true; Reason = 'provider missing'; Active = $null } })

            $Snapshot.Readable | Should -BeFalse
            $Snapshot.Status | Should -Be 'Unknown'
        }
    }

    It 'recognises the activated state in the after-read, even when the before-read was unavailable' {
        InModuleScope WindowsTweaker {
            $Before = Get-WtLicensingSnapshot -License ([ordered]@{ Inventory = [ordered]@{ Unreadable = $true; Reason = 'before'; Active = $null } })
            $After = Get-WtLicensingSnapshot -License ([ordered]@{
                    CollectedUtc = [datetime]::UtcNow
                    Inventory = [ordered]@{ Unreadable = $false; Active = New-TestLicensingProduct -LicenseStatus 1 }
                })

            $Verdict = Get-WtWindowsActivationResult -Completion 'Completed' -Before $Before -After $After

            $Verdict.CompletionDetermined | Should -BeTrue
            $Verdict.Activated | Should -BeTrue
            $Verdict.Verified | Should -BeTrue
            $Verdict.ReasonKey | Should -Be 'Act.Result.Activated'
        }
    }

    It 'never claims success when completion could not be determined' {
        InModuleScope WindowsTweaker {
            $After = Get-WtLicensingSnapshot -License ([ordered]@{
                    CollectedUtc = [datetime]::UtcNow
                    Inventory = [ordered]@{ Unreadable = $false; Active = New-TestLicensingProduct -LicenseStatus 1 }
                })

            $Verdict = Get-WtWindowsActivationResult -Completion 'Unknown' -ExitCode 0 -After $After

            $Verdict.CompletionDetermined | Should -BeFalse
            $Verdict.Verified | Should -BeFalse
            $Verdict.ReasonKey | Should -Be 'Act.Result.NotDetermined'

            # An exit code of 0 is recorded, never believed.
            $Verdict.ExitCode | Should -Be 0
        }
    }

    It 'reports already-active only when both reads agree and the state did not change' {
        InModuleScope WindowsTweaker {
            $License = [ordered]@{
                CollectedUtc = [datetime]::UtcNow
                Inventory = [ordered]@{ Unreadable = $false; Active = New-TestLicensingProduct -LicenseStatus 1 }
            }

            $Before = Get-WtLicensingSnapshot -License $License
            $After = Get-WtLicensingSnapshot -License $License
            $Verdict = Get-WtWindowsActivationResult -Completion 'Completed' -Before $Before -After $After

            $Verdict.AlreadyActive | Should -BeTrue
            $Verdict.Verified | Should -BeTrue
            $Verdict.ReasonKey | Should -Be 'Act.Result.AlreadyActive'
        }
    }

    It 'copies the structured error code the Software Protection service logged, verbatim' {
        InModuleScope WindowsTweaker {
            $After = Get-WtLicensingSnapshot -License ([ordered]@{
                    CollectedUtc = [datetime]::UtcNow
                    Inventory = [ordered]@{ Unreadable = $false; Active = New-TestLicensingProduct -LicenseStatus 0 }
                })
            $Components = [ordered]@{ LastActivationError = 'SL_ERROR_ACTIVATION_IN_PROGRESS 0xC004F074' }

            $Verdict = Get-WtWindowsActivationResult -Completion 'Completed' -After $After -Components $Components

            $Verdict.ErrorCode | Should -Be '0xC004F074'
        }
    }

    It 'reports a failure to activate when the completed run did not change the licensing state' {
        InModuleScope WindowsTweaker {
            $Before = Get-WtLicensingSnapshot -License ([ordered]@{
                    CollectedUtc = [datetime]::UtcNow
                    Inventory = [ordered]@{ Unreadable = $false; Active = New-TestLicensingProduct -LicenseStatus 0 }
                })
            $After = Get-WtLicensingSnapshot -License ([ordered]@{
                    CollectedUtc = [datetime]::UtcNow.AddSeconds(5)
                    Inventory = [ordered]@{ Unreadable = $false; Active = New-TestLicensingProduct -LicenseStatus 0 }
                })

            $Verdict = Get-WtWindowsActivationResult -Completion 'Completed' -Before $Before -After $After

            $Verdict.Activated | Should -BeFalse
            $Verdict.Verified | Should -BeFalse
            $Verdict.ReasonKey | Should -Be 'Act.Result.NotActivated'
        }
    }
}

Describe 'Licensing export' {

    It 'redacts keys and previews before export' {
        InModuleScope WindowsTweaker {
            Clear-WtLicensingCache
            Mock Test-WtLicensingAvailable { $true }
            Mock Get-WtLicensingCim { @((New-TestLicensingProduct -PartialProductKey 'XYZ99')) }

            $Diagnostics = Get-WtLicensingDiagnostics -Refresh
            $Payload = Get-WtLicensingExportPayload -License $Diagnostics

            $Payload.active.partialProductKey | Should -Be '<redacted>'
            $Payload.active.licenseStatus | Should -Be 'Licensed'

            # Full keys never appear in the payload at all.
            $Json = ConvertTo-WtJson -InputObject $Payload -Depth 8
            $Json | Should -Not -Match 'XYZ99'
        }
    }

    It 'writes a report to a path on demand' {
        InModuleScope WindowsTweaker {
            Clear-WtLicensingCache
            Mock Test-WtLicensingAvailable { $true }
            Mock Get-WtLicensingCim { @((New-TestLicensingProduct)) }

            $Path = Join-Path $env:WT_DATA_ROOT 'license-report.json'
            $Written = Export-WtLicensingDiagnostics -Path $Path -Refresh
            $Written | Should -Be $Path
            Test-Path -LiteralPath $Path | Should -BeTrue

            $Parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            $Parsed.active.licenseStatus | Should -Be 'Licensed'
            $Parsed.active.partialProductKey | Should -Be '<redacted>'
        }
    }
}

Describe 'Licensing redaction and the cached inventory' {

    # A keyed read and a redacted read are two different contracts over one cached provider
    # answer. Neither order may let the redacted read erase the keyed one, and neither may
    # rewrite records a caller already holds.
    It 'serves the partial key to a later read that asks for it' {
        InModuleScope WindowsTweaker {
            Clear-WtLicensingCache
            Mock Test-WtLicensingAvailable { $true }
            Mock Get-WtLicensingCim { @((New-TestLicensingProduct -PartialProductKey 'XYZ99')) }

            $WithKey = (Get-WtLicensingDiagnostics -IncludePartialKey).Inventory.Active.PartialProductKey
            $Redacted = (Get-WtLicensingDiagnostics).Inventory.Active.PartialProductKey
            $Again = (Get-WtLicensingDiagnostics -IncludePartialKey).Inventory.Active.PartialProductKey

            $WithKey | Should -Be 'XYZ99'
            $Redacted | Should -Be ''
            $Again | Should -Be 'XYZ99'
        }
    }

    It 'never blanks the records an earlier caller already holds' {
        InModuleScope WindowsTweaker {
            Clear-WtLicensingCache
            Mock Test-WtLicensingAvailable { $true }
            Mock Get-WtLicensingCim { @((New-TestLicensingProduct -PartialProductKey 'XYZ99')) }

            $Held = Get-WtLicensingDiagnostics -IncludePartialKey
            $null = Get-WtLicensingDiagnostics

            $Held.Inventory.Active.PartialProductKey | Should -Be 'XYZ99'
            @($Held.Inventory.Products)[0].PartialProductKey | Should -Be 'XYZ99'
        }
    }

    It 'still answers a repeated read of the same shape from the cache' {
        InModuleScope WindowsTweaker {
            Clear-WtLicensingCache
            $Script:ProductReads = 0
            Mock Test-WtLicensingAvailable { $true }
            Mock Get-WtLicensingCim {
                param ($ClassName)
                if ($ClassName -eq 'SoftwareLicensingProduct') { $Script:ProductReads++ }
                @((New-TestLicensingProduct -PartialProductKey 'XYZ99'))
            }

            $null = Get-WtLicensingDiagnostics
            $null = Get-WtLicensingDiagnostics

            # The provider is queried once: the cache is not defeated by the mode check.
            $Script:ProductReads | Should -Be 1
        }
    }
}

Describe 'Licensing TUI workspace rendering' {

    It 'paints the workspace without touching the system' {
        InModuleScope WindowsTweaker {
            Clear-WtLicensingCache
            Mock Test-WtLicensingAvailable { $true }
            Mock Get-WtLicensingCim { @((New-TestLicensingProduct -LicenseStatus 1)) }
            Mock Get-WtLicensingService { [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' } }
            Mock Get-WtLicensingWinEvent { @() }
            Mock Get-WtLicensingTimeQuery { 'synchronized' }

            $License = Read-WtLicensingDiagnostics -Refresh

            $State = New-WtTestState
            Initialize-WtTuiState -State $State
            $State.Licensing = $License
            $State.ForceRepaint = $true

            Update-WtTuiView -State $State
            $Text = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Lic.Title')))
            $Text | Should -Match 'Licensed'

            # The workspace paints without starting operations or workers.
            $State.Operation | Should -BeNullOrEmpty
            $State.Licensing = $null
        }
    }
}
