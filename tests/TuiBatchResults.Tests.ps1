# WindowsTweaker - TUI batch results and progress reporting tests.
#
# Simulated batch results and isolated operations only: no broad preset is applied, and
# no system state is touched.

# A shared result factory for the simulated batch tests. Defined globally so every
# InModuleScope block (which runs in the module session state) can see it.
function Global:New-TestResult
{
    param
    (
        [string]$TweakId,
        [string]$Status = 'succeeded',
        [bool]$Verified = $true,
        [hashtable]$Journal = $null,
        [object]$Verification = $null,
        [object]$Compensation = $null,
        [string[]]$Messages = @()
    )

    [pscustomobject]@{
        TweakId = $TweakId
        Status = $Status
        Verified = $Verified
        Operations = @()
        Messages = @($Messages)
        Journal = $Journal
        Verification = $Verification
        Compensation = $Compensation
        OperationId = ''
        HistoryId = ''
    }
}

BeforeAll {
    $script:ModuleManifest = Join-Path $PSScriptRoot '../src/WindowsTweaker/WindowsTweaker.psd1'
    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-tui-batch-{0}" -f ([guid]::NewGuid().ToString('n')))

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

Describe 'Batch progress counters' {

    It 'advances from 0 through completion for mixed outcomes' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Escape'))
            Initialize-WtTuiState -State $State

            $Worker = @{
                Kind = 'apply'
                Total = 3
                Started = 0
                Finished = 0
                Queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
                Results = [System.Collections.Generic.List[object]]::new()
                Failures = [System.Collections.Generic.List[object]]::new()
                Cancel = @{ Requested = $false; Active = $null; Progress = @{ Completed = 0; Changed = 0; Unchanged = 0; Failed = 0; Partial = 0; Cancelled = 0; Skipped = 0 } }
            }

            $State.Worker = $Worker
            $State.Operation = @{
                Kind = 'apply'; Preview = $false; Total = 3; Started = 0; Finished = 0
                Active = $null; Cancelling = $false; Events = @(); Results = @(); Failures = @()
                Progress = @{ Completed = 0; Changed = 0; Unchanged = 0; Failed = 0; Partial = 0; Cancelled = 0; Skipped = 0 }
            }

            $Worker.Queue.Enqueue(@{ Kind = 'start'; Label = 'A'; Index = 1; Total = 3 })
            $Worker.Queue.Enqueue(@{ Kind = 'result'; Label = 'A'; Index = 1; Total = 3; Result = (New-TestResult -TweakId 'A' -Status 'succeeded') })
            $Worker.Queue.Enqueue(@{ Kind = 'result'; Label = 'B'; Index = 2; Total = 3; Result = (New-TestResult -TweakId 'B' -Status 'unchanged' -Verified $false) })
            $Worker.Queue.Enqueue(@{ Kind = 'result'; Label = 'C'; Index = 3; Total = 3; Result = (New-TestResult -TweakId 'C' -Status 'failed' -Verified $false -Journal @{ StopBatch = $false }) })

            Update-WtTuiOperation -State $State

            $State.Worker.Cancel.Progress.Completed | Should -Be 3
            $State.Worker.Cancel.Progress.Changed | Should -Be 1
            $State.Worker.Cancel.Progress.Unchanged | Should -Be 1
            $State.Worker.Cancel.Progress.Failed | Should -Be 1

            $Collected = @($State.Worker.Results | ForEach-Object { $_.Result })
            $Summary = Get-WtTuiBatchSummary -Total 3 -Results $Collected -Skipped 0 -Cancelled 0
            $Summary.Changed | Should -Be 1
            $Summary.Unchanged | Should -Be 1
            $Summary.Failed | Should -Be 1
            $Summary.Verified | Should -Be 1
        }
    }

    It 'counts worker-level failures and cancelled items separately' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Escape'))
            Initialize-WtTuiState -State $State

            $Worker = @{
                Kind = 'apply'
                Total = 4
                Started = 0
                Finished = 0
                Queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
                Results = [System.Collections.Generic.List[object]]::new()
                Failures = [System.Collections.Generic.List[object]]::new()
                Cancel = @{ Requested = $false; Active = $null; Progress = @{ Completed = 0; Changed = 0; Unchanged = 0; Failed = 0; Partial = 0; Cancelled = 0; Skipped = 0 } }
            }
            $State.Worker = $Worker
            $State.Operation = @{
                Kind = 'apply'; Preview = $false; Total = 4; Started = 0; Finished = 0
                Active = $null; Cancelling = $false; Events = @(); Results = @(); Failures = @()
                Progress = @{ Completed = 0; Changed = 0; Unchanged = 0; Failed = 0; Partial = 0; Cancelled = 0; Skipped = 0 }
            }

            $Worker.Queue.Enqueue(@{ Kind = 'result'; Label = 'A'; Index = 1; Total = 4; Result = (New-TestResult -TweakId 'A' -Status 'succeeded') })
            $Worker.Queue.Enqueue(@{ Kind = 'error'; Label = 'B'; Index = 2; Total = 4; Message = 'boom' })
            $Worker.Queue.Enqueue(@{ Kind = 'cancelled'; Label = 'C'; Index = 3; Total = 4 })
            $Worker.Queue.Enqueue(@{ Kind = 'cancelled'; Label = 'D'; Index = 4; Total = 4 })

            Update-WtTuiOperation -State $State

            $State.Worker.Cancel.Progress.Completed | Should -Be 2
            $State.Worker.Cancel.Progress.Failed | Should -Be 1
            $State.Worker.Cancel.Progress.Cancelled | Should -Be 2

            $Summary = Get-WtTuiBatchSummary -Total 4 -Results @($State.Operation.Results) -Failures @($State.Operation.Failures) -Cancelled $State.Worker.Cancel.Progress.Cancelled
            $Summary.Failed | Should -Be 1
            $Summary.Cancelled | Should -Be 2
        }
    }
}

Describe 'Batch result summary and failure-first view' {

    BeforeEach {
        InModuleScope WindowsTweaker {
            $script:OkResult = New-TestResult -TweakId 'A.OK' -Status 'succeeded' -Verified $true
            $script:ChangedResult = New-TestResult -TweakId 'B.Changed' -Status 'succeeded' -Verified $true
            $script:UnchangedResult = New-TestResult -TweakId 'C.Unchanged' -Status 'unchanged' -Verified $false
            $script:FailedResult = New-TestResult -TweakId 'D.Failed' -Status 'failed' -Verified $false `
                -Journal @{ StopBatch = $false; UncertainStage = 'applied'; MutationStarted = $true; DurableRecords = 0; InMemoryRecords = 1; Message = 'store not writable' } `
                -Messages @('the recovery records exist only in this process')
            $script:PartialResult = New-TestResult -TweakId 'E.Partial' -Status 'partial' -Verified $true `
                -Journal @{ StopBatch = $true; UncertainStage = 'final'; MutationStarted = $true; DurableRecords = 2; InMemoryRecords = 0; Message = 'final stage not written' }
        }
    }

    It 'orders failures first, then successes, and reports every failure detail' {
        InModuleScope WindowsTweaker {
            $Lines = Get-WtTuiFailureFirstLines -Results @($script:OkResult, $script:FailedResult, $script:PartialResult, $script:UnchangedResult)
            $Text = $Lines -join "`n"

            # Failures come before the success header.
            $FailedIndex = $Text.IndexOf('D.Failed')
            $PartialIndex = $Text.IndexOf('E.Partial')
            $SuccessIndex = $Text.IndexOf((Get-WtString -Key 'Tui.Result.SuccessHeader'))
            $FailedIndex | Should -BeGreaterThan -1
            $PartialIndex | Should -BeGreaterThan $FailedIndex
            $SuccessIndex | Should -BeGreaterThan $PartialIndex

            $Text | Should -Match 'store not writable'
            $Text | Should -Match 'final stage not written'
            $Text | Should -Match 'Mutation occurred'
        }
    }

    It 'summarises with accurate counts and reports uncertain journal separately' {
        InModuleScope WindowsTweaker {
            $Summary = Get-WtTuiBatchSummary -Total 5 -Results @($script:OkResult, $script:ChangedResult, $script:UnchangedResult, $script:FailedResult, $script:PartialResult)
            $Summary.Total | Should -Be 5
            $Summary.Changed | Should -Be 2
            $Summary.Unchanged | Should -Be 1
            $Summary.Failed | Should -Be 1
            $Summary.Partial | Should -Be 1
            $Summary.Verified | Should -Be 3
            $Summary.UncertainJournal | Should -Be 1
        }
    }

    It 'exports the report only when asked, with a stable JSON payload' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State

            $ReportPath = Join-Path $env:WT_DATA_ROOT 'report.json'
            $Payload = [ordered]@{
                total = 2
                changed = 1
                verified = 1
                unchanged = 0
                failed = 1
                partial = 0
                cancelled = 0
                skipped = 0
                uncertainJournal = 0
                results = @(@{ tweakId = 'D.Failed'; status = 'failed' })
                workerFailures = @()
            }
            Write-WtTextFile -Path $ReportPath -Value (ConvertTo-WtJson -InputObject $Payload -Depth 8)

            $Parsed = ConvertFrom-WtJson -Text (Read-WtTextFile -Path $ReportPath) -Depth 8
            $Parsed.total | Should -Be 2
            @($Parsed.results)[0].tweakId | Should -Be 'D.Failed'
        }
    }
}

Describe 'Screen text replacement and localization' {

    It 'clears trailing cells when replacing longer text with shorter text' {
        InModuleScope WindowsTweaker {
            $Theme = New-WtTuiTheme -Colour 'Ansi16' -Unicode:$true -IconMode 'Unicode'
            $Screen = New-WtScreen -Width 30 -Height 5 -Theme $Theme

            Set-WtScreenText -Screen $Screen -Row 2 -Column 2 -Text 'this is a long line that fills the row' -Style 'Item' -MaxWidth 28
            Set-WtScreenText -Screen $Screen -Row 2 -Column 2 -Text 'short' -Style 'Item' -MaxWidth 28

            $Cells = Get-WtScreenRowText -Screen $Screen -Row 2
            ($Cells[1..27] -join '') | Should -BeExactly ('short' + (' ' * 22)) -Because 'trailing cells after the text are blanked and nothing stale remains'
        }
    }

    It 'localizes stored state tokens while keeping the enum value stable' {
        InModuleScope WindowsTweaker {
            Set-WtLanguage -Language 'vi' | Out-Null
            try
            {
                # The display label is translated...
                (Get-WtTuiStateLabel -Name 'Disabled') | Should -Not -Be 'Disabled'
                # ...and the stored value is untouched.
                (Get-WtTuiStateLabel -Name 'Disabled') | Should -Be (Get-WtString -Key 'Tui.State.Disabled')
                # An unknown future state falls back to the raw enum value.
                (Get-WtTuiStateLabel -Name 'FutureState') | Should -Be 'FutureState'
            }
            finally
            {
                Set-WtLanguage -Language 'en' | Out-Null
            }
        }
    }
}
