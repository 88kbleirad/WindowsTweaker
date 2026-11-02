# WindowsTweaker - background info collector tests.
#
# The collector is the bounded runspace that computes slow read-only probes (drift,
# dimensions, slmgr comparison) off the UI thread. These tests drive the real collector
# with a fast, inert job and assert the contract: bounded queue, generation guard, and
# that stale responses never overwrite newer state.

BeforeAll {
    $script:ModuleManifest = Join-Path $PSScriptRoot '../src/WindowsTweaker/WindowsTweaker.psd1'
    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-infocollector-{0}" -f ([guid]::NewGuid().ToString('n')))

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

Describe 'InfoCollector' {

    It 'runs a job in the background runspace and returns its answer' {
        InModuleScope WindowsTweaker {
            $Collector = New-WtInfoCollector
            Start-WtInfoCollector -Collector $Collector
            $null = Send-WtInfoCollectorRequest -Collector $Collector -Kind 'drift' -Generation 1

            $Answer = $null
            $Deadline = [datetime]::UtcNow.AddSeconds(30)
            while ([datetime]::UtcNow -lt $Deadline)
            {
                $Responses = Receive-WtInfoCollectorResponses -Collector $Collector
                if ($Responses.Count -gt 0)
                {
                    $Answer = $Responses[0]
                    break
                }
                Start-Sleep -Milliseconds 25
            }

            $Answer | Should -Not -BeNullOrEmpty
            $Answer.Kind | Should -Be 'drift'
            $Answer.Generation | Should -Be 1
            $Answer.Ok | Should -BeTrue
            $Answer.Value.ContainsKey('Drifted') | Should -BeTrue

            Close-WtInfoCollector -Collector $Collector
        }
    }

    It 'bounds the request queue by dropping the oldest' {
        InModuleScope WindowsTweaker {
            $Collector = New-WtInfoCollector
            $script:WtInfoCollectorMaxQueue = 3

            $null = Send-WtInfoCollectorRequest -Collector $Collector -Kind 'drift' -Generation 1
            $null = Send-WtInfoCollectorRequest -Collector $Collector -Kind 'drift' -Generation 2
            $null = Send-WtInfoCollectorRequest -Collector $Collector -Kind 'drift' -Generation 3
            $null = Send-WtInfoCollectorRequest -Collector $Collector -Kind 'drift' -Generation 4

            $Collector.Requests.Count | Should -Be 3
            # The oldest (generation 1) was dropped.
            $Dropped = @()
            $Item = $null
            while ($Collector.Requests.TryDequeue([ref]$Item)) { $Dropped += [int]$Item.Generation }
            $Dropped | Should -Be @(2, 3, 4)

            Close-WtInfoCollector -Collector $Collector
        }
    }

    It 'applies responses only when their generation is current' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Width 100 -Height 30
            Initialize-WtTuiState -State $State
            $State.InfoCollector = New-WtInfoCollector
            $State.DriftGeneration = 5

            # The initial OverviewVerify came from initialization; remember it.
            $Before = $State.OverviewVerify

            # A stale drift response (generation 4 < current 5) must not overwrite it.
            $State.InfoCollector.Responses.Enqueue([ordered]@{
                    Generation = 4
                    Kind       = 'drift'
                    Key        = ''
                    Ok         = $true
                    Value      = @{ Drifted = 99; Interrupted = 2 }
                    Error      = ''
                })

            Update-WtInfoCollector -State $State
            $State.OverviewVerify.Drifted | Should -Be $Before.Drifted -Because 'a stale generation is discarded'
            $State.OverviewVerify.Interrupted | Should -Be $Before.Interrupted

            # A current drift response is applied.
            $State.InfoCollector.Responses.Enqueue([ordered]@{
                    Generation = 5
                    Kind       = 'drift'
                    Key        = ''
                    Ok         = $true
                    Value      = @{ Drifted = 7; Interrupted = 1 }
                    Error      = ''
                })
            Update-WtInfoCollector -State $State
            $State.OverviewVerify.Drifted | Should -Be 7
            $State.OverviewVerify.Interrupted | Should -Be 1

            Close-WtInfoCollector -Collector $State.InfoCollector
            $State.InfoCollector = $null
        }
    }
}
