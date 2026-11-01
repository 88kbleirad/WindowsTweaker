# WindowsTweaker - optional automatic restart after a batch.
#
# Every test here uses the mockable adapter (Invoke-WtRestartRequest) and simulated batch
# results. No test can reboot the machine it runs on: the real adapter is asserted away
# before it could ever be reached.

function Global:New-WtRestartTestResult
{
    param
    (
        [string]$TweakId = 'Test.Change',
        [string]$Status = 'succeeded',
        [bool]$Verified = $true,
        [object]$Journal = $null,
        [object]$Verification = $null,
        [object]$Compensation = $null,
        [string]$Restart = 'Reboot',
        [string]$OperationId = 'op0001',
        [string]$SessionId = 'session1'
    )

    [pscustomobject]@{
        TweakId = $TweakId
        Status = $Status
        Verified = $Verified
        Verification = $Verification
        Compensation = $Compensation
        Journal = $Journal
        OperationId = $OperationId
        SessionId = $SessionId
        Restart = $Restart
        Operations = @()
        Messages = @()
    }
}

BeforeAll {
    $script:ModuleManifest = Join-Path $PSScriptRoot '../src/WindowsTweaker/WindowsTweaker.psd1'
    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-restart-{0}" -f ([guid]::NewGuid().ToString('n')))

    $env:WT_DATA_ROOT = $script:TestDataRoot
    $env:WT_STATE_PATH = Join-Path $script:TestDataRoot 'state.json'
    $env:WT_LOG_DIRECTORY = Join-Path $script:TestDataRoot 'logs'
    $env:WT_LANG = 'en'
    $env:WT_TEST_MODULE = $script:ModuleManifest

    New-Item -ItemType Directory -Path $script:TestDataRoot -Force | Out-Null

    Import-Module $script:ModuleManifest -Force

    InModuleScope WindowsTweaker -Parameters @{ HelperPath = (Join-Path $PSScriptRoot 'TuiTestHelpers.ps1') } {
        . $HelperPath
    }
}

AfterAll {
    Remove-Module WindowsTweaker -Force -ErrorAction Ignore
    Remove-Item -LiteralPath $script:TestDataRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_DATA_ROOT, Env:\WT_STATE_PATH, Env:\WT_LOG_DIRECTORY, Env:\WT_LANG, Env:\WT_TEST_MODULE -ErrorAction Ignore
}

Describe 'Restart requirement classification' {

    It 'keeps a full restart, an application restart, none and unknown apart' {
        InModuleScope WindowsTweaker {
            (Get-WtRestartRequirementInternal -Entries @(@{ Restart = 'None' })) | Should -Be 'None'
            (Get-WtRestartRequirementInternal -Entries @(@{ Restart = 'Explorer' })) | Should -Be 'Application'
            (Get-WtRestartRequirementInternal -Entries @(@{ Restart = 'SignOut' })) | Should -Be 'Application'
            (Get-WtRestartRequirementInternal -Entries @(@{ Restart = 'Reboot' })) | Should -Be 'Reboot'

            # A selection without restart metadata cannot be called "no restart".
            (Get-WtRestartRequirementInternal -Entries @(@{ Id = 'x' })) | Should -Be 'Unknown'
            (Get-WtRestartRequirementInternal -Entries @([pscustomobject]@{ Restart = '' })) | Should -Be 'Unknown'
        }
    }

    It 'takes the strongest requirement of a mixed selection' {
        InModuleScope WindowsTweaker {
            (Get-WtRestartRequirementInternal -Entries @(@{ Restart = 'None' }, @{ Restart = 'Explorer' })) | Should -Be 'Application'
            (Get-WtRestartRequirementInternal -Entries @(@{ Restart = 'Explorer' }, @{ Restart = 'Reboot' }, @{ Restart = 'None' })) | Should -Be 'Reboot'
            (Get-WtRestartRequirementInternal -Entries @(@{ Restart = 'None' }, @{ Id = 'no-metadata' })) | Should -Be 'Unknown'
        }
    }

    It 'renders each requirement with its own wording' {
        InModuleScope WindowsTweaker {
            $Reboot = Get-WtRestartRequirementLabelInternal -Requirement 'Reboot'
            $Application = Get-WtRestartRequirementLabelInternal -Requirement 'Application'
            $Unknown = Get-WtRestartRequirementLabelInternal -Requirement 'Unknown'
            $None = Get-WtRestartRequirementLabelInternal -Requirement 'None'

            @($Reboot, $Application, $Unknown, $None | Select-Object -Unique).Count | Should -Be 4
        }
    }
}

Describe 'Restart eligibility' {

    It 'is off unless the batch explicitly asked for it' {
        InModuleScope WindowsTweaker {
            $Result = New-WtRestartTestResult
            $Eligibility = Get-WtRestartEligibilityInternal -Requested $false -Results @($Result)
            $Eligibility.Eligible | Should -BeFalse
            @($Eligibility.Reasons).Count | Should -Be 0 -Because 'not asking is not a refusal to explain'
        }
    }

    It 'allows a clean batch with at least one applied change' {
        InModuleScope WindowsTweaker {
            $Eligibility = Get-WtRestartEligibilityInternal -Requested $true -Results @(
                (New-WtRestartTestResult -TweakId 'A' -Status 'succeeded'),
                (New-WtRestartTestResult -TweakId 'B' -Status 'unchanged' -Verified $false)
            )
            $Eligibility.Eligible | Should -BeTrue
            $Eligibility.Applied | Should -Be 1
            $Eligibility.Unchanged | Should -Be 1
        }
    }

    It 'refuses a batch whose entries are all unchanged' {
        InModuleScope WindowsTweaker {
            $Eligibility = Get-WtRestartEligibilityInternal -Requested $true -Results @(
                (New-WtRestartTestResult -Status 'unchanged' -Verified $false),
                (New-WtRestartTestResult -Status 'unchanged' -Verified $false)
            )
            $Eligibility.Eligible | Should -BeFalse
            $Eligibility.Reasons | Should -Contain 'NoChange'
        }
    }

    It 'refuses failed, cancelled, skipped, partial and unsupported outcomes' {
        InModuleScope WindowsTweaker {
            foreach ($Status in @('failed', 'partial', 'unsupported', 'dryrun', 'review-required', 'skipped'))
            {
                $Eligibility = Get-WtRestartEligibilityInternal -Requested $true -Results @(
                    (New-WtRestartTestResult -Status 'succeeded'),
                    (New-WtRestartTestResult -Status $Status)
                )
                $Eligibility.Eligible | Should -BeFalse -Because "$Status must not restart"
                $Eligibility.Reasons | Should -Contain 'Outcome'
            }

            (Get-WtRestartEligibilityInternal -Requested $true -Results @((New-WtRestartTestResult)) -Skipped 1).Reasons | Should -Contain 'Outcome'
            (Get-WtRestartEligibilityInternal -Requested $true -Results @((New-WtRestartTestResult)) -Cancelled 1).Reasons | Should -Contain 'Outcome'
            (Get-WtRestartEligibilityInternal -Requested $true -Results @((New-WtRestartTestResult)) -Failures @(@{ Message = 'worker exploded' })).Reasons | Should -Contain 'Outcome'
        }
    }

    It 'refuses verification mismatches and compensating restoration' {
        InModuleScope WindowsTweaker {
            $Mismatch = New-WtRestartTestResult -Verification ([pscustomobject]@{ Verified = 0; Mismatched = 1 })
            $Eligibility = Get-WtRestartEligibilityInternal -Requested $true -Results @($Mismatch)
            $Eligibility.Eligible | Should -BeFalse
            $Eligibility.Reasons | Should -Contain 'Verification'

            $Compensated = New-WtRestartTestResult -Compensation ([pscustomobject]@{ Attempted = $true; Succeeded = 1; Failed = 0 })
            $Eligibility = Get-WtRestartEligibilityInternal -Requested $true -Results @($Compensated)
            $Eligibility.Eligible | Should -BeFalse
            $Eligibility.Reasons | Should -Contain 'Compensation'
        }
    }

    It 'refuses a journal that did not record every stage' {
        InModuleScope WindowsTweaker {
            $Uncertain = New-WtRestartTestResult -Journal (New-WtJournalState -FailedStages @('applied') -UncertainStage 'applied' -MutationStarted $true)
            $Eligibility = Get-WtRestartEligibilityInternal -Requested $true -Results @($Uncertain)
            $Eligibility.Eligible | Should -BeFalse
            $Eligibility.Reasons | Should -Contain 'Journal'

            $Repaired = New-WtRestartTestResult -Journal (New-WtJournalState -FailedStages @('applied') -UncertainStage '' -DurableRecords 1 -MutationStarted $true)
            (Get-WtRestartEligibilityInternal -Requested $true -Results @($Repaired)).Eligible | Should -BeTrue -Because 'a repaired stage left nothing uncertain'
        }
    }

    It 'refuses while an operation or another restart is still active, and on a platform that cannot restart' {
        InModuleScope WindowsTweaker {
            (Get-WtRestartEligibilityInternal -Requested $true -Results @((New-WtRestartTestResult)) -OperationActive $true).Reasons | Should -Contain 'Active'
            (Get-WtRestartEligibilityInternal -Requested $true -Results @((New-WtRestartTestResult)) -PlatformAvailable $false).Reasons | Should -Contain 'Unavailable'
        }
    }

    It 'explains every refusal with localized lines' {
        InModuleScope WindowsTweaker {
            $Lines = Get-WtRestartBlockedLinesInternal -Reasons @('Outcome', 'Journal', 'NoChange')
            @($Lines).Count | Should -Be 3
            ($Lines -join ' ') | Should -Not -Match '\[Tui\.'
        }
    }
}

Describe 'Restart ownership' {

    It 'allows exactly one owner at a time' {
        InModuleScope WindowsTweaker {
            $First = [guid]::NewGuid().ToString('n')
            $Second = [guid]::NewGuid().ToString('n')

            (Test-WtRestartPending) | Should -BeFalse
            (Enter-WtRestartOwnership -Owner $First) | Should -BeTrue
            (Test-WtRestartPending) | Should -BeTrue
            (Enter-WtRestartOwnership -Owner $Second) | Should -BeFalse -Because 'a second restart must not be scheduled behind the first'

            # A foreign release cannot clear the owner's claim.
            Exit-WtRestartOwnership -Owner $Second
            (Test-WtRestartPending) | Should -BeTrue

            Exit-WtRestartOwnership -Owner $First
            (Test-WtRestartPending) | Should -BeFalse
        }
    }
}

Describe 'Restart adapter' {

    It 'checks the platform before claiming restart is available' {
        InModuleScope WindowsTweaker {
            $Availability = Test-WtRestartAvailable
            $Availability.Available | Should -BeOfType [bool]
            if (-not (Get-WtRuntimeProfile).IsWindows)
            {
                $Availability.Available | Should -BeFalse
                $Availability.Reason | Should -Be 'platform'
            }
        }
    }

    It 'never forces applications to close and keeps the request in one place' {
        $Source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/WindowsTweaker/Private/Restart.ps1') -Raw
        $Source | Should -Match 'function Invoke-WtRestartRequest'
        $Source | Should -Not -Match "'/f'" -Because 'a forced restart is never requested'
        $Source | Should -Not -Match 'Restart-Computer.*-Force'
        @([regex]::Matches($Source, 'function Invoke-WtRestartRequest')).Count | Should -Be 1
    }
}

Describe 'TUI restart flows' {

    It 'keeps the option off by default and refuses it for a preview or dry run' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State
            $State.RestartRequested | Should -BeFalse -Because 'the default is OFF'

            # A dry run of the pending selection must never leave the flag armed.
            $Entry = $State.States | Where-Object { $_.Id -eq 'Privacy.AdvertisingId' } | Select-Object -First 1
            $State.Pending[$Entry.Id] = New-WtTestPending -Entry $Entry -Target 'Disabled'
            $State.RestartRequested = $true
            Start-WtTuiOperation -State $State -Preview
            $State.RestartRequested | Should -BeFalse
            Close-WtTuiWorker -State $State
            $State.Operation = $null
            $State.Pending.Clear()
        }
    }

    It 'runs the countdown, cancels on Escape and never asks the operating system' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Escape'))
            Initialize-WtTuiState -State $State

            $Script:Requests = 0
            Mock Invoke-WtRestartRequest { $Script:Requests++; @{ Requested = $true; Mechanism = 'test'; Message = ''; RequestedUtc = '' } }

            $State.RestartRequested = $true
            $Result = New-WtRestartTestResult -Status 'succeeded'
            Invoke-WtTuiRestart -State $State -Results @($Result) -Seconds 30

            $Script:Requests | Should -Be 0 -Because 'a cancelled countdown must not reach the OS'
            $State.RestartRequested | Should -BeFalse -Because 'the authorisation is spent by the batch'
            (Test-WtRestartPending) | Should -BeFalse -Because 'the ownership is released'
        }
    }

    It 'asks the operating system exactly once when the countdown expires' {
        InModuleScope WindowsTweaker {
            # No keys are queued: the injected key source runs out, so the dialog loop would
            # raise. The countdown is therefore driven with a zero-second budget, which
            # expires on the first tick before any key is read.
            $State = New-WtTestState
            Initialize-WtTuiState -State $State

            # The countdown/expiry path is the Windows situation; the platform probe is
            # mocked so this Linux host can exercise it without claiming the ability.
            Mock Test-WtRestartAvailable { @{ Available = $true; Mechanism = 'test'; Reason = '' } }

            $Script:Requests = 0
            $Script:LastComment = ''
            Mock Invoke-WtRestartRequest {
                param ($DelaySeconds, $Comment)
                $Script:Requests++
                $Script:LastComment = $Comment
                @{ Requested = $true; Mechanism = 'test'; Message = 'restart requested'; RequestedUtc = '' }
            }

            $State.RestartRequested = $true
            Invoke-WtTuiRestart -State $State -Results @((New-WtRestartTestResult -Status 'succeeded')) -Seconds 0

            $Script:Requests | Should -Be 1
            $Script:LastComment | Should -Match 'WindowsTweaker'
            (Test-WtRestartPending) | Should -BeFalse
        }
    }

    It 'shows the restart option and the requirement in the review screen' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State

            $Entry = $State.States | Where-Object { $_.Id -eq 'Privacy.AdvertisingId' } | Select-Object -First 1
            $State.Pending[$Entry.Id] = New-WtTestPending -Entry $Entry -Target 'Disabled'

            $Script:ReviewLines = @()
            Mock Select-WtTuiItem {
                param ($State, $Title, $Lines, $Items, $Details, $OnKey, $EmptyText, $DetailsHeight, $Searchable, $Multi)
                $Script:ReviewLines = @($Lines)
                return $null
            }

            Show-WtTuiPendingReview -State $State

            $Text = $Script:ReviewLines -join "`n"
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Tui.Restart.Option' -Arguments @((Get-WtString -Key 'Tui.Restart.Off')))))
            # The requirement of the selection is stated, not implied.
            $Text | Should -Match ([regex]::Escape((Get-WtRestartRequirementLabelInternal -Requirement (Get-WtRestartRequirementInternal -Entries @($State.Pending[$Entry.Id])))))
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Tui.Restart.Hint')))
        }
    }

    It 'toggles the restart option with R and keeps the choice in memory only' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State

            $Entry = $State.States | Where-Object { $_.Id -eq 'Privacy.AdvertisingId' } | Select-Object -First 1
            $State.Pending[$Entry.Id] = New-WtTestPending -Entry $Entry -Target 'Disabled'

            # The platform probe is mocked so this Linux host can exercise the toggle; the
            # real probe refuses it before the state is changed (see the test above).
            Mock Test-WtRestartAvailable { @{ Available = $true; Mechanism = 'test'; Reason = '' } }

            $Script:ReviewLines = @()
            # The dialog hands the handler a normalized key, never the raw ConsoleKeyInfo.
            $Script:ToggleKeys = @((ConvertTo-WtKey -Key (New-WtTestKey -Name 'Char' -Character 'r')))
            Mock Select-WtTuiItem {
                param ($State, $Title, $Lines, $Items, $Details, $OnKey, $EmptyText, $DetailsHeight, $Searchable, $Multi)

                # Drive the review's own key handler exactly as the dialog does (it is only
                # called while the filter box does not own the keyboard).
                $Overlay = @{ Accepted = $false; Result = $null; List = @{ Cursor = 0; Items = @(@{ Payload = $Entry.Id }) } }
                foreach ($Key in $Script:ToggleKeys)
                {
                    if (& $OnKey $Overlay $Key) { break }
                }

                return $null
            }

            Show-WtTuiPendingReview -State $State
            $State.RestartRequested | Should -BeTrue -Because 'R enabled it for this batch'

            # Nothing about the choice is persisted as a global preference: the settings file
            # has no restart field at all.
            $SettingsPath = Get-WtSettingsPath
            if (Test-Path -LiteralPath $SettingsPath)
            {
                (Read-WtTextFile -Path $SettingsPath) | Should -Not -Match 'restart'
            }

            $State.RestartRequested = $false
        }
    }

    It 'never restarts when the batch is not eligible, and keeps the apply outcome' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Escape'))
            Initialize-WtTuiState -State $State

            $Script:Requests = 0
            Mock Invoke-WtRestartRequest { $Script:Requests++; @{ Requested = $true; Mechanism = 'test'; Message = ''; RequestedUtc = '' } }

            $Apply = New-WtRestartTestResult -Status 'succeeded' -OperationId 'op-1'
            $Bad = New-WtRestartTestResult -TweakId 'Test.Bad' -Status 'failed' -OperationId 'op-2'
            $State.RestartRequested = $true

            Invoke-WtTuiRestart -State $State -Results @($Apply, $Bad) -Seconds 0

            $Script:Requests | Should -Be 0
            # The batch outcome is untouched by the restart decision.
            $Apply.Status | Should -Be 'succeeded'
            $Bad.Status | Should -Be 'failed'
        }
    }

    It 'reports a failed request without changing the batch result' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Escape'))
            Initialize-WtTuiState -State $State

            Mock Test-WtRestartAvailable { @{ Available = $true; Mechanism = 'test'; Reason = '' } }
            Mock Invoke-WtRestartRequest {
                @{ Requested = $false; Mechanism = 'test'; Message = 'access denied'; RequestedUtc = '' }
            }
            $Script:Shown = @()
            Mock Show-WtTuiMessage { param ($State, $Title, $Lines, $Tone) $Script:Shown = @($Lines) }

            $Apply = New-WtRestartTestResult -Status 'succeeded'
            $State.RestartRequested = $true
            Invoke-WtTuiRestart -State $State -Results @($Apply) -Seconds 0

            ($Script:Shown -join ' ') | Should -Match 'access denied'
            $Apply.Status | Should -Be 'succeeded' -Because 'a restart failure is not an apply failure'
            $State.Status.Tone | Should -Be 'StatusError'
        }
    }
}

Describe 'Public batch restart (command line path)' {

    It 'requests the restart once when the countdown expires, and reports the outcome' {
        InModuleScope WindowsTweaker {
            Mock Test-WtRestartAvailable { @{ Available = $true; Mechanism = 'test'; Reason = '' } }
            $Script:Requests = 0
            Mock Invoke-WtRestartRequest { $Script:Requests++; @{ Requested = $true; Mechanism = 'test'; Message = 'restart requested'; RequestedUtc = '' } }
            Mock Invoke-WtConsoleRestartCountdownInternal { @{ Outcome = 'Expired'; Remaining = 0 } }

            $Outcome = Invoke-WtBatchRestart -Results @((New-WtRestartTestResult -Status 'succeeded')) -Requirement 'Reboot'

            $Outcome.Outcome | Should -Be 'requested'
            $Outcome.Applied | Should -Be 1
            $Script:Requests | Should -Be 1
            (Test-WtRestartPending) | Should -BeFalse
        }
    }

    It 'blocks a batch that is not clean and never asks the operating system' {
        InModuleScope WindowsTweaker {
            Mock Test-WtRestartAvailable { @{ Available = $true; Mechanism = 'test'; Reason = '' } }
            $Script:Requests = 0
            Mock Invoke-WtRestartRequest { $Script:Requests++; @{ Requested = $true; Mechanism = 'test'; Message = ''; RequestedUtc = '' } }

            $Outcome = Invoke-WtBatchRestart -Results @(
                (New-WtRestartTestResult -Status 'succeeded'),
                (New-WtRestartTestResult -TweakId 'Bad' -Status 'failed')
            )

            $Outcome.Outcome | Should -Be 'blocked'
            $Outcome.Reasons | Should -Contain 'Outcome'
            @($Outcome.Lines).Count | Should -BeGreaterThan 0
            ($Outcome.Lines -join ' ') | Should -Not -Match '\[Tui\.'
            $Script:Requests | Should -Be 0
        }
    }

    It 'refuses duplicate scheduling and a platform that cannot restart' {
        InModuleScope WindowsTweaker {
            Mock Test-WtRestartAvailable { @{ Available = $true; Mechanism = 'test'; Reason = '' } }
            Mock Invoke-WtRestartRequest { @{ Requested = $true; Mechanism = 'test'; Message = ''; RequestedUtc = '' } }
            Mock Invoke-WtConsoleRestartCountdownInternal { @{ Outcome = 'Expired'; Remaining = 0 } }

            # A countdown owned by someone else: the second batch is refused, not queued.
            $Owner = [guid]::NewGuid().ToString('n')
            Enter-WtRestartOwnership -Owner $Owner | Out-Null
            $Outcome = Invoke-WtBatchRestart -Results @((New-WtRestartTestResult -Status 'succeeded'))
            Exit-WtRestartOwnership -Owner $Owner

            $Outcome.Outcome | Should -Be 'blocked'
            $Outcome.Reasons | Should -Contain 'Busy'

            # A platform that cannot restart is reported, not silently ignored.
            Mock Test-WtRestartAvailable { @{ Available = $false; Mechanism = ''; Reason = 'platform' } }
            $Unavailable = Invoke-WtBatchRestart -Results @((New-WtRestartTestResult -Status 'succeeded'))
            $Unavailable.Outcome | Should -Be 'blocked'
            $Unavailable.Reasons | Should -Contain 'Unavailable'
            ($Unavailable.Lines -join ' ') | Should -Not -Match '\[Tui\.'
        }
    }

    It 'reports a cancelled countdown without asking the operating system' {
        InModuleScope WindowsTweaker {
            Mock Test-WtRestartAvailable { @{ Available = $true; Mechanism = 'test'; Reason = '' } }
            $Script:Requests = 0
            Mock Invoke-WtRestartRequest { $Script:Requests++; @{ Requested = $true; Mechanism = 'test'; Message = ''; RequestedUtc = '' } }
            Mock Invoke-WtConsoleRestartCountdownInternal { @{ Outcome = 'Cancelled'; Remaining = 42 } }

            $Outcome = Invoke-WtBatchRestart -Results @((New-WtRestartTestResult -Status 'succeeded'))
            $Outcome.Outcome | Should -Be 'cancelled'
            $Script:Requests | Should -Be 0
        }
    }

    It 'reports a denied or failed OS request separately from the batch result' {
        InModuleScope WindowsTweaker {
            Mock Test-WtRestartAvailable { @{ Available = $true; Mechanism = 'test'; Reason = '' } }
            Mock Invoke-WtConsoleRestartCountdownInternal { @{ Outcome = 'Expired'; Remaining = 0 } }
            Mock Invoke-WtRestartRequest { @{ Requested = $false; Mechanism = 'shutdown.exe'; Message = 'access denied'; RequestedUtc = '' } }

            $Apply = New-WtRestartTestResult -Status 'succeeded'
            $Outcome = Invoke-WtBatchRestart -Results @($Apply)

            $Outcome.Outcome | Should -Be 'failed'
            $Outcome.Message | Should -Match 'access denied'
            $Apply.Status | Should -Be 'succeeded' -Because 'the apply outcome is not rewritten by a restart failure'
        }
    }

    It 'returns a verdict without acting when only the decision is wanted' {
        InModuleScope WindowsTweaker {
            Mock Test-WtRestartAvailable { @{ Available = $true; Mechanism = 'test'; Reason = '' } }
            $Script:Requests = 0
            Mock Invoke-WtRestartRequest { $Script:Requests++; @{ Requested = $true; Mechanism = 'test'; Message = ''; RequestedUtc = '' } }

            $Outcome = Invoke-WtBatchRestart -Results @((New-WtRestartTestResult -Status 'succeeded')) -DryVerdict
            $Outcome.Outcome | Should -Be 'eligible'
            $Script:Requests | Should -Be 0
        }
    }
}

Describe 'Command-line restart request' {

    It 'refuses a preview, a read-only invocation and an unsupported platform' {
        InModuleScope WindowsTweaker {
            (Test-WtRestartCliRequestInternal -Requested $true).Allowed | Should -BeTrue
            (Test-WtRestartCliRequestInternal -Requested $true -Preview $true).Reason | Should -Be 'preview'
            (Test-WtRestartCliRequestInternal -Requested $true -ReadOnly $true).Reason | Should -Be 'readonly'
            (Test-WtRestartCliRequestInternal -Requested $true -PlatformAvailable $false).Reason | Should -Be 'unsupported'
            (Test-WtRestartCliRequestInternal -Requested $false -Preview $true).Allowed | Should -BeFalse
            (Test-WtRestartCliRequestInternal -Requested $false -Preview $true).Reason | Should -Be ''
        }
    }

    It 'cancels the command-line countdown on Escape and expires without input' {
        InModuleScope WindowsTweaker {
            $Script:Wrote = [System.Collections.Generic.List[string]]::new()

            # Escape cancels.
            $Cancelled = Invoke-WtConsoleRestartCountdownInternal -Seconds 30 -Lines @('line') -Write { param ($Text) $Script:Wrote.Add([string]$Text) } -ReadKey { 'Escape' } -Sleep { param ($Ms) }
            $Cancelled.Outcome | Should -Be 'Cancelled'
            ($Script:Wrote -join ' ') | Should -Match 'line'

            # No key at all: the countdown expires on its own.
            $Script:Wrote.Clear()
            $Ticks = 0
            $Expired = Invoke-WtConsoleRestartCountdownInternal -Seconds 2 -Write { param ($Text) $Script:Wrote.Add([string]$Text) } -ReadKey { $null } `
                -Clock { $Script:Ticks++; [datetime]::UtcNow.AddSeconds($Script:Ticks * 2) } -Sleep { param ($Ms) }
            $Expired.Outcome | Should -Be 'Expired'
            $Expired.Remaining | Should -Be 0
        }
    }
}
