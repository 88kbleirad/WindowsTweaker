# WindowsTweaker - batch-state reconciliation and profile knob tests.
#
# Simulated batches with isolated in-memory state only.

function Global:New-StateBatchResult
{
    param
    (
        [string]$Id,
        [string]$Status = 'succeeded',
        [string]$State = 'Disabled'
    )

    [pscustomobject]@{
        TweakId = $Id
        Status = $Status
        State = $State
        Verified = ($Status -eq 'succeeded')
        Operations = @()
        Messages = @()
        Journal = $null
        Verification = $null
        Compensation = $null
        OperationId = ''
        HistoryId = ''
    }
}

BeforeAll {
    $script:ModuleManifest = Join-Path $PSScriptRoot '../src/WindowsTweaker/WindowsTweaker.psd1'
    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-batchstate-{0}" -f ([guid]::NewGuid().ToString('n')))

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

Describe 'Batch pending queue reconciliation' {

    It 'clears succeeded and unchanged reviewed requests; keeps failures with no fingerprint' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State

            # Simulate the review: three requests with revisions and fingerprints.
            foreach ($Id in 'A', 'B', 'C')
            {
                $State.Pending[$Id] = @{
                    Id = $Id; Revision = "rev-$Id"; Target = 'Disabled'; From = 'Enabled'
                    Name = $Id; Arguments = $null; Risk = 'Low'; Restart = 'None'; Rollback = 'Full'
                    Irreversible = $false; ReducesProtection = $false; Intent = ''; Fingerprint = "fp-$Id"
                }
            }

            # The batch snapshot is what the worker executed.
            $State.BatchRequests = @(
                @{ Id = 'A'; Revision = 'rev-A'; Target = 'Disabled'; Arguments = $null },
                @{ Id = 'B'; Revision = 'rev-B'; Target = 'Disabled'; Arguments = $null },
                @{ Id = 'C'; Revision = 'rev-C'; Target = 'Disabled'; Arguments = $null }
            )

            $Results = @(
                (New-StateBatchResult -Id 'A' -Status 'succeeded'),
                (New-StateBatchResult -Id 'B' -Status 'unchanged'),
                (New-StateBatchResult -Id 'C' -Status 'failed')
            )

            Sync-WtTuiBatchPending -State $State -Results $Results

            $State.Pending.Contains('A') | Should -BeFalse -Because 'a succeeded request is satisfied'
            $State.Pending.Contains('B') | Should -BeFalse -Because 'an unchanged request is satisfied'
            $State.Pending.Contains('C') | Should -BeTrue -Because 'a failed request stays for an explicit retry review'
            $State.Pending['C'].Fingerprint | Should -BeNullOrEmpty -Because 'retrying requires a fresh review'
            $State.BatchRequests.Count | Should -Be 0 -Because 'the snapshot is spent'
        }
    }

    It 'does not clear a newer edit made while the batch ran' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State

            # The batch ran revision rev-old; the user edited the request afterwards.
            $State.Pending['X'] = @{
                Id = 'X'; Revision = 'rev-new'; Target = 'Enabled'; From = 'Disabled'
                Name = 'X'; Arguments = $null; Risk = 'Low'; Restart = 'None'; Rollback = 'Full'
                Irreversible = $false; ReducesProtection = $false; Intent = ''; Fingerprint = 'fp-new'
            }
            $State.BatchRequests = @(@{ Id = 'X'; Revision = 'rev-old'; Target = 'Disabled'; Arguments = $null })

            Sync-WtTuiBatchPending -State $State -Results @((New-StateBatchResult -Id 'X' -Status 'succeeded'))

            $State.Pending.Contains('X') | Should -BeTrue -Because 'a newer revision is a different request'
            $State.Pending['X'].Fingerprint | Should -Be 'fp-new' -Because 'the newer review is preserved'
        }
    }

    It 'leaves requests that were never part of the batch alone' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State

            $State.Pending['Y'] = @{
                Id = 'Y'; Revision = 'rev-y'; Target = 'Disabled'; From = 'Enabled'
                Name = 'Y'; Arguments = $null; Risk = 'Low'; Restart = 'None'; Rollback = 'Full'
                Irreversible = $false; ReducesProtection = $false; Intent = ''; Fingerprint = 'fp-y'
            }
            $State.BatchRequests = @(@{ Id = 'Z'; Revision = 'rev-z'; Target = 'Disabled'; Arguments = $null })

            Sync-WtTuiBatchPending -State $State -Results @((New-StateBatchResult -Id 'Z' -Status 'succeeded'))

            $State.Pending.Contains('Y') | Should -BeTrue
        }
    }

    It 'a full clean batch leaves the pending queue empty, so quit warns about nothing' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State

            # Three reviewed requests with fingerprints.
            foreach ($Id in 'A', 'B', 'C')
            {
                $State.Pending[$Id] = @{
                    Id = $Id; Revision = "rev-$Id"; Target = 'Disabled'; From = 'Enabled'
                    Name = $Id; Arguments = $null; Risk = 'Low'; Restart = 'None'; Rollback = 'Full'
                    Irreversible = $false; ReducesProtection = $false; Intent = ''; Fingerprint = "fp-$Id"
                }
            }

            # Execute exactly like the batched worker: snapshot, results incl. unchanged.
            $State.BatchRequests = @($State.Pending.Keys | ForEach-Object { @{ Id = [string]$_; Revision = [string]$State.Pending[$_].Revision; Target = 'Disabled'; Arguments = $null } })
            $Results = @(
                (New-StateBatchResult -Id 'A' -Status 'succeeded'),
                (New-StateBatchResult -Id 'B' -Status 'unchanged'),
                (New-StateBatchResult -Id 'C' -Status 'succeeded')
            )

            Sync-WtTuiBatchPending -State $State -Results $Results

            $State.Pending.Count | Should -Be 0

            # Quit now warns only about unapplied requests.
            $Script:QuitLines = @()
            $State.Exit = $false
            Mock Confirm-WtTui { param ($State, $Title, $Lines, $Tone, $Icon) $Script:QuitLines = @($Lines); $false }
            Invoke-WtTuiQuit -State $State
            $QuitText = $Script:QuitLines -join ' '
            $QuitText | Should -Match ([regex]::Escape((Get-WtString -Key 'Tui.Quit.Confirm')))
            $QuitText | Should -Not -Match 'will be discarded'
        }
    }

    It 'after a failed batch the quit warning reflects only the failed request, not the cleaned ones' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State

            foreach ($Id in 'A', 'B')
            {
                $State.Pending[$Id] = @{
                    Id = $Id; Revision = "rev-$Id"; Target = 'Disabled'; From = 'Enabled'
                    Name = $Id; Arguments = $null; Risk = 'Low'; Restart = 'None'; Rollback = 'Full'
                    Irreversible = $false; ReducesProtection = $false; Intent = ''; Fingerprint = "fp-$Id"
                }
            }

            $State.BatchRequests = @($State.Pending.Keys | ForEach-Object { @{ Id = [string]$_; Revision = [string]$State.Pending[$_].Revision; Target = 'Disabled'; Arguments = $null } })
            $Results = @(
                (New-StateBatchResult -Id 'A' -Status 'succeeded'),
                (New-StateBatchResult -Id 'B' -Status 'failed')
            )

            Sync-WtTuiBatchPending -State $State -Results $Results

            $State.Pending.Count | Should -Be 1
            $State.Pending.Contains('B') | Should -BeTrue

            $Script:QuitLines = @()
            Mock Confirm-WtTui { param ($State, $Title, $Lines, $Tone, $Icon) $Script:QuitLines = @($Lines); $false }
            Invoke-WtTuiQuit -State $State
            ($Script:QuitLines -join ' ') | Should -Match '1 pending change'
            ($Script:QuitLines -join ' ') | Should -Not -Match '2 pending change'
        }
    }
}

Describe 'Performance profile knobs' {

    It 'never lets a profile touch safety or recovery' {
        $Source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/WindowsTweaker/Private/Tui/PerfProfile.ps1') -Raw
        $Source | Should -Match 'Get-WtTuiProfileKnobs'
        $Source | Should -Not -Match 'powercfg'
        $Source | Should -Not -Match 'Set-Service'
        $Source | Should -Not -Match 'Restart-Computer'
        $Source | Should -Not -Match 'Invoke-WtRestartRequest'
    }

    It 'resolves profiles and chooses low-resource for a non-VT console' {
        InModuleScope WindowsTweaker {
            (Resolve-WtTuiProfile -Requested 'low-resource') | Should -Be 'Low-resource'
            (Resolve-WtTuiProfile -Requested 'bogus') | Should -Be 'Auto'
            (Get-WtTuiProfileEffective -UseVt $false) | Should -Be 'Low-resource'
            (Get-WtTuiProfileEffective -UseVt $true) | Should -Be 'Balanced'
            (Get-WtTuiProfileEffective -Requested 'Low-resource' -UseVt $true) | Should -Be 'Low-resource'

            $Knobs = Get-WtTuiProfileKnobs -Profile 'Low-resource'
            $Knobs.ShowRowIcons | Should -BeFalse
            $Knobs.MaxKeyBatch | Should -BeLessThan 10
            $Knobs.FrameTimeoutMs | Should -BeGreaterThan 40
        }
    }
}
