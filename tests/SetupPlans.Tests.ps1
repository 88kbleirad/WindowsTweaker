# WindowsTweaker - checkpointed setup workflow tests.
#
# Plans are data (tweak ids and states only); importing applies nothing; resume registrations
# are identity-bound and refused on tampering; failed steps stop the plan; uncertain results
# are never retried automatically; reboot counts are bounded. The engine is mocked so no
# real tweak executes.

BeforeAll {
    $ModuleManifest = Join-Path $PSScriptRoot '../src/WindowsTweaker/WindowsTweaker.psd1'
    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-plan-{0}" -f ([guid]::NewGuid().ToString('n')))

    $env:WT_DATA_ROOT = $script:TestDataRoot
    $env:WT_STATE_PATH = Join-Path $script:TestDataRoot 'state.json'
    $env:WT_LOG_DIRECTORY = Join-Path $script:TestDataRoot 'logs'
    $env:WT_SETUP_PLANS_DIR = Join-Path $script:TestDataRoot 'plans'
    $env:WT_SETUP_USER_ID = 'pester-user'
    $env:WT_LANG = 'en'

    New-Item -ItemType Directory -Path $script:TestDataRoot -Force | Out-Null
    Import-Module $ModuleManifest -Force
}

AfterAll {
    Remove-Item -LiteralPath $script:TestDataRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_DATA_ROOT, Env:\WT_STATE_PATH, Env:\WT_LOG_DIRECTORY, Env:\WT_SETUP_PLANS_DIR, Env:\WT_SETUP_USER_ID, Env:\WT_LANG -ErrorAction Ignore
}

Describe 'Setup plan creation and import' {

    It 'creates a versioned plan and applies nothing' {
        InModuleScope WindowsTweaker {
            Mock Invoke-WtTweak { throw 'must not run' }

            $Plan = New-WtSetupPlanInternal -Steps @(
                @{ stepId = 'a'; tweakId = 'Privacy.AdvertisingId'; state = 'Disabled' }
                @{ stepId = 'b'; tweakId = 'Explorer.FileExtensions'; state = 'Enabled' }
            ) -PlanId 'pester-plan'

            $Plan.schemaVersion | Should -Be 1
            $Plan.planId | Should -Be 'pester-plan'
            $Plan.planHash | Should -Not -BeNullOrEmpty
            @($Plan.steps).Count | Should -Be 2
            $Plan.steps[0].tweakId | Should -Be 'Privacy.AdvertisingId'
        }
    }

    It 'refuses steps that are not tweak ids/states' {
        InModuleScope WindowsTweaker {
            $Bad = @{
                schemaVersion = 1
                planId = 'evil'
                appVersion = '1.0.0'
                steps = @(
                    @{ stepId = 'x'; tweakId = 'powershell.exe -Command stuff'; state = 'Enabled' }
                )
            }
            $Validation = Test-WtSetupPlanDocument -Document $Bad
            $Validation.Valid | Should -BeFalse
            @($Validation.Errors | Where-Object { $_ -match 'invalid tweakId' }).Count | Should -Be 1
        }
    }

    It 'import validates and stores a JSON plan without applying steps' {
        InModuleScope WindowsTweaker -Parameters @{ DataRoot = $script:TestDataRoot } {
            Mock Invoke-WtTweak { throw 'must not run' }

            $Doc = @{
                schemaVersion = 1
                planId = 'imported-plan'
                appVersion = '1.0.0'
                createdUtc = (Get-Date).ToUniversalTime().ToString('o')
                steps = @(
                    @{ stepId = 'one'; tweakId = 'Privacy.AdvertisingId'; state = 'Disabled' }
                )
            }
            $Path = Join-Path $DataRoot 'imported.json'
            $Doc | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM

            $Imported = Import-WtSetupPlan -Path $Path -Confirm:$false
            $Imported.Applied | Should -BeFalse
            $Imported.PlanId | Should -Be 'imported-plan'

            $Stored = Read-WtSetupPlan -Id 'imported-plan'
            $Stored.planId | Should -Be 'imported-plan'
            @($Stored.steps).Count | Should -Be 1
        }
    }
}

Describe 'Setup plan review and execution' {

    BeforeEach {
        InModuleScope WindowsTweaker {
            $script:Plan = New-WtSetupPlanInternal -Steps @(
                @{ stepId = 'one'; tweakId = 'System.Hibernation'; state = 'Disabled' }
                @{ stepId = 'two'; tweakId = 'Security.WindowsScriptHost'; state = 'Disabled' }
            ) -PlanId 'run-plan'
        }
    }

    It 'preview lists step statuses and the capability-loss summary' {
        InModuleScope WindowsTweaker {
            Mock Invoke-WtTweak { throw 'must not run' }

            $Preview = Get-WtSetupPlanPreviewInternal -Plan $script:Plan
            $Preview.Rows.Count | Should -Be 2
            $Preview.CapabilityLoss.Impacts | Should -Not -BeNullOrEmpty
        }
    }

    It 'executes steps through the engine and stops after a failed prerequisite' {
        InModuleScope WindowsTweaker {
            $Calls = 0
            Mock Invoke-WtTweak {
                $script:Calls = ++$Calls
                if ($Id -eq 'System.Hibernation')
                {
                    return [pscustomobject]@{ Status = 'failed'; Message = 'boom' }
                }
                return [pscustomobject]@{ Status = 'succeeded'; Message = '' }
            }

            $Run = Invoke-WtSetupPlanInternal -Plan $script:Plan
            $Run.Completed | Should -BeFalse
            $Run.StopReason | Should -Match 'did not verify'
            # Only the first step ran; the dependent second step was not executed.
            $script:Calls | Should -Be 1
        }
    }

    It 'never retries an uncertain result automatically' {
        InModuleScope WindowsTweaker {
            Mock Invoke-WtTweak {
                return [pscustomobject]@{ Status = 'review-required'; Message = 'state changed' }
            }

            $Run = Invoke-WtSetupPlanInternal -Plan $script:Plan
            $Run.Completed | Should -BeFalse
            $Run.StopReason | Should -Match 'retried'
        }
    }
}

Describe 'Resume registration and tampering' {

    BeforeEach {
        InModuleScope WindowsTweaker {
            $script:Plan = New-WtSetupPlanInternal -Steps @(
                @{ stepId = 'one'; tweakId = 'Privacy.AdvertisingId'; state = 'Disabled' }
                @{ stepId = 'two'; tweakId = 'System.Hibernation'; state = 'Disabled' }
            ) -PlanId 'resume-plan'
        }
    }

    It 'writes a bound registration only when explicitly opted in' {
        InModuleScope WindowsTweaker {
            Mock Invoke-WtTweak {
                return [pscustomobject]@{ Status = 'succeeded'; Message = '' }
            }

            # Without opt-in there is no registration.
            $Run = Start-WtSetupPlanInternal -Plan $script:Plan
            (Read-WtSetupResume) | Should -BeNullOrEmpty
            $Run.ResumeRegistered | Should -BeFalse
            $Run.Completed | Should -BeTrue

            # With opt-in the registration exists and records the checkpoint.
            $Plan2 = New-WtSetupPlanInternal -Steps @(
                @{ stepId = 'one'; tweakId = 'Privacy.AdvertisingId'; state = 'Disabled' }
                @{ stepId = 'two'; tweakId = 'Apps.WindowsSandbox'; state = 'Disabled' }
            ) -PlanId 'resume-plan-2'

            $Run2 = Start-WtSetupPlanInternal -Plan $Plan2 -ResumeAfterReboot -ExecutablePath '/opt/wt.ps1'
            $Run2.NeedsReboot | Should -BeTrue -Because 'the reboot-bound step stops and keeps the registration'
            $Resume = Read-WtSetupResume
            $Resume | Should -Not -BeNullOrEmpty
            $Resume.planId | Should -Be 'resume-plan-2'
            $Resume.userId | Should -Be 'pester-user'
        }
    }

    It 'refuses to resume a tampered registration' {
        InModuleScope WindowsTweaker {
            $Resume = [pscustomobject]@{
                schemaVersion = 1
                planId = 'resume-plan'
                planHash = 'deadbeef'
                userId = 'pester-user'
                appVersion = '1.0.0'
                executablePath = '/opt/wt.ps1'
                stepIndex = 1
                reboots = 0
                createdUtc = (Get-Date).ToUniversalTime().ToString('o')
            }
            Write-WtSetupResume -Resume $Resume

            $Result = Resume-WtSetupPlanInternal -ExecutablePath '/opt/wt.ps1'
            $Result.Completed | Should -BeFalse
            $Result.StopReason | Should -Match 'changed since'
        }
    }

    It 'resumes the remaining steps when the binding matches' {
        InModuleScope WindowsTweaker {
            $Calls = 0
            Mock Invoke-WtTweak {
                $script:Calls = ++$Calls
                return [pscustomobject]@{ Status = 'succeeded'; Message = '' }
            }

            # A registration whose planId matches a stored plan.
            $Plan = New-WtSetupPlanInternal -Steps @(
                @{ stepId = 'one'; tweakId = 'Privacy.AdvertisingId'; state = 'Disabled' }
                @{ stepId = 'two'; tweakId = 'System.Hibernation'; state = 'Disabled' }
            ) -PlanId 'resume-plan-3'

            $Resume = [pscustomobject]@{
                schemaVersion = 1
                planId = 'resume-plan-3'
                planHash = (Get-WtSetupPlanHash -Plan $Plan)
                userId = 'pester-user'
                appVersion = '1.0.0'
                executablePath = '/opt/wt.ps1'
                stepIndex = 1
                reboots = 0
                createdUtc = (Get-Date).ToUniversalTime().ToString('o')
            }
            Write-WtSetupResume -Resume $Resume

            $Result = Resume-WtSetupPlanInternal -ExecutablePath '/opt/wt.ps1'
            $Result.Completed | Should -BeTrue
            $script:Calls | Should -Be 1 -Because 'only the remaining step runs'
            (Read-WtSetupResume) | Should -BeNullOrEmpty -Because 'completion removes the registration'
        }
    }

    It 'removes the registration on request and respects the reboot bound' {
        InModuleScope WindowsTweaker {
            $Resume = [pscustomobject]@{
                schemaVersion = 1
                planId = 'resume-plan'
                planHash = 'x'
                userId = 'pester-user'
                appVersion = '1.0.0'
                executablePath = '/opt/wt.ps1'
                stepIndex = 0
                reboots = 0
            }
            Write-WtSetupResume -Resume $Resume
            Remove-WtSetupResume
            (Read-WtSetupResume) | Should -BeNullOrEmpty

            # Exceeding the reboot bound reports and stops instead of looping.
            $Plan = New-WtSetupPlanInternal -Steps @(
                @{ stepId = 'one'; tweakId = 'Apps.WindowsSandbox'; state = 'Disabled' }
            ) -PlanId 'reboot-plan'
            $Plan | Add-Member -NotePropertyName reboots -NotePropertyValue 3 -Force -ErrorAction Ignore

            Mock Invoke-WtTweak {
                return [pscustomobject]@{ Status = 'succeeded'; Message = '' }
            }

            $Run = Invoke-WtSetupPlanInternal -Plan $Plan -MaxReboots 3
            $Run.NeedsReboot | Should -BeFalse
            $Run.StopReason | Should -Match 'reboot bound'
        }
    }
}
