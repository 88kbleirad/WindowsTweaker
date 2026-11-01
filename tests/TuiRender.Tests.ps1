# WindowsTweaker - TUI render/invalidation/input scheduling regression tests.
#
# These verify the input-to-render path without a terminal: the screen buffer is tested
# directly, the writers are captured through a redirected console stream, key batching is
# driven through the injected key source, and the performance diagnostics ring is bounded.

BeforeAll {
    $script:ModuleManifest = Join-Path $PSScriptRoot '../src/WindowsTweaker/WindowsTweaker.psd1'
    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-tui-render-{0}" -f ([guid]::NewGuid().ToString('n')))

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

Describe 'Screen row invalidation' {

    BeforeEach {
        InModuleScope WindowsTweaker {
            $script:TestTheme = New-WtTuiTheme -Colour 'Ansi16' -Unicode:$true -IconMode 'Unicode'
            $script:TestScreen = New-WtScreen -Width 40 -Height 10 -Theme $script:TestTheme
        }
    }

    It 'reports every row as changed before the first write, and none after it' {
        InModuleScope WindowsTweaker {
            $Changed = Get-WtScreenChangedRows -Screen $script:TestScreen
            @($Changed | Where-Object { $_ }).Count | Should -Be 10

            for ($Row = 1; $Row -le 10; $Row++) { Set-WtScreenRowWritten -Screen $script:TestScreen -Row $Row }

            $Changed = Get-WtScreenChangedRows -Screen $script:TestScreen
            @($Changed | Where-Object { $_ }).Count | Should -Be 0
        }
    }

    It 'marks only the row that actually changed' {
        InModuleScope WindowsTweaker {
            for ($Row = 1; $Row -le 10; $Row++) { Set-WtScreenRowWritten -Screen $script:TestScreen -Row $Row }

            Set-WtScreenText -Screen $script:TestScreen -Row 4 -Column 2 -Text 'changed' -Style 'Focused' -MaxWidth 20

            $Changed = Get-WtScreenChangedRows -Screen $script:TestScreen
            $Rows = @(1..10 | Where-Object { $Changed[$_ - 1] })
            $Rows | Should -Be 4

            # A style-only change is a change too: the same text in another style must repaint.
            Set-WtScreenText -Screen $script:TestScreen -Row 4 -Column 2 -Text 'changed' -Style 'Item' -MaxWidth 20
            $Changed = Get-WtScreenChangedRows -Screen $script:TestScreen
            @(1..10 | Where-Object { $Changed[$_ - 1] }) | Should -Be 4
        }
    }

    It 'reports a fresh row after Reset-WtScreenDiff (forced repaint)' {
        InModuleScope WindowsTweaker {
            for ($Row = 1; $Row -le 10; $Row++) { Set-WtScreenRowWritten -Screen $script:TestScreen -Row $Row }
            Reset-WtScreenDiff -Screen $script:TestScreen

            $Changed = Get-WtScreenChangedRows -Screen $script:TestScreen
            @($Changed | Where-Object { $_ }).Count | Should -Be 10
        }
    }
}

Describe 'Console writers (row diff)' {

    BeforeEach {
        InModuleScope WindowsTweaker {
            $script:TestTheme = New-WtTuiTheme -Colour 'Ansi16' -Unicode:$true -IconMode 'Unicode'
            $script:TestScreen = New-WtScreen -Width 40 -Height 10 -Theme $script:TestTheme
        }
    }

    It 'writes the whole first frame, nothing for an identical frame, and only the changed row after a mutation' {
        InModuleScope WindowsTweaker {
            $Path = Join-Path $env:WT_DATA_ROOT 'out.bin'
            $Stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
            $Writer = [System.IO.StreamWriter]::new($Stream)
            $OldOut = [Console]::Out
            [Console]::SetOut($Writer)

            try
            {
                Write-WtScreen -Screen $script:TestScreen
                $Writer.Flush()
                $First = $Stream.Length
                $First | Should -BeGreaterThan 0

                Write-WtScreen -Screen $script:TestScreen
                $Writer.Flush()
                $Second = $Stream.Length
                $Second | Should -Be $First -Because 'an unchanged frame must not be written again'

                Set-WtScreenText -Screen $script:TestScreen -Row 3 -Column 2 -Text 'x' -Style 'Focused' -MaxWidth 10
                Write-WtScreen -Screen $script:TestScreen
                $Writer.Flush()
                $Third = $Stream.Length
                $Third | Should -BeGreaterThan $Second -Because 'the mutated row must be rewritten'
                ($Third - $Second) | Should -BeLessThan $First -Because 'one row is far smaller than a full frame'
            }
            finally
            {
                [Console]::SetOut($OldOut)
                $Writer.Dispose()
                $Stream.Dispose()
            }
        }
    }

    It 'plain renderer segments change and never rewrites an unchanged frame' {
        InModuleScope WindowsTweaker {
            # The plain renderer needs a real console for cursor addressing, which Pester
            # does not provide; its correctness contract (row diff) is asserted through the
            # written-row counter instead of through captured bytes.
            Write-WtScreenPlain -Screen $script:TestScreen
            $script:TestScreen.LastWrittenRows | Should -Be 10

            Write-WtScreenPlain -Screen $script:TestScreen
            $script:TestScreen.LastWrittenRows | Should -Be 0 -Because 'an unchanged frame writes nothing'

            Set-WtScreenText -Screen $script:TestScreen -Row 5 -Column 2 -Text 'y' -Style 'Item' -MaxWidth 10
            Write-WtScreenPlain -Screen $script:TestScreen
            $script:TestScreen.LastWrittenRows | Should -Be 1 -Because 'only the mutated row is written'
        }
    }
}

Describe 'Key batching and frame coalescing' {

    It 'processes a queued batch of keys with a single render and loses no key' {
        InModuleScope WindowsTweaker {
            $Keys = 1..12 | ForEach-Object { New-WtTestKey -Name 'Down' }
            $State = New-WtTestState -Keys $Keys
            Initialize-WtTuiState -State $State

            # The top-level loop step renders once, then drains the waiting keys without
            # rendering in between; the injected key source empties after the batch.
            $Frames = 0
            $Renders = 0
            $Start = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not $State.Exit -and $State.EmptyFrames -lt 3)
            {
                if ($State.Screen.Dirty -or $State.ForceRepaint) { $Renders++ }
                Invoke-WtTuiLoopStep -State $State
                $Frames++
                if ($Frames -gt 30) { break }
            }
            $Start.Stop()

            $State.ItemIndex | Should -Be 12 -Because 'every queued key reached the handler'
            $Renders | Should -BeLessThan 6 -Because 'the batch is coalesced into few renders'
            $Frames | Should -BeLessThan 10
            $State.KeyQueue.Count | Should -Be 0
        }
    }

    It 'does not drop Escape or Enter while batching' {
        InModuleScope WindowsTweaker {
            $States = @(
                (New-WtTestKey -Name 'Down'),
                (New-WtTestKey -Name 'Enter'),
                (New-WtTestKey -Name 'Escape')
            )
            $State = New-WtTestState -Keys $States
            Initialize-WtTuiState -State $State

            $Frames = 0
            while (-not $State.Exit -and $Frames -lt 20)
            {
                Invoke-WtTuiLoopStep -State $State
                $Frames++
            }

            # Enter on the first tweak row opens the target-state dialog (a modal overlay),
            # which stops the batch so Escape can close it again.
            $State.Overlay | Should -BeNullOrEmpty -Because 'Escape closed the dialog'
        }
    }
}

Describe 'Overview verification cache' {

    It 'reuses the cached drift/interrupted counts within the cadence window' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State

            # Prime the cache with sentinel values (catalog state is unchanged by this test).
            $State.OverviewVerify = @{ Utc = [datetime]::UtcNow; Drifted = 3; Interrupted = 1 }

            $Row = @(Get-WtTuiOverviewItems -State $State | Where-Object { $_.Action -eq 'Verify' })[0]
            $Row.Value | Should -BeExactly ((Get-WtString -Key 'Tui.Overview.VerifyValue' -Arguments @(3, 1)) -replace ':', ':') -Because 'the fresh cache is used as-is'

            # Backdate the cache: the next paint recomputes (and overwrites the sentinels).
            $State.OverviewVerify.Utc = [datetime]::UtcNow.AddSeconds(-6)
            $Row = @(Get-WtTuiOverviewItems -State $State | Where-Object { $_.Action -eq 'Verify' })[0]
            $Row.Value | Should -Match '0 drifted, 0 interrupted' -Because 'the recompute happens once, against the empty store'
        }
    }
}

Describe 'Performance diagnostics' {

    AfterEach {
        InModuleScope WindowsTweaker {
            Set-WtTuiPerf -Enabled $false
        }
    }

    It 'is off by default and records only when enabled' {
        InModuleScope WindowsTweaker {
            (Test-WtTuiPerf) | Should -BeFalse
            Set-WtTuiPerf -Enabled $true
            (Test-WtTuiPerf) | Should -BeTrue
        }
    }

    It 'bounds the ring and computes percentiles' {
        InModuleScope WindowsTweaker {
            Set-WtTuiPerf -Enabled $true
            for ($I = 0; $I -lt 5000; $I++)
            {
                $Sample = New-WtTuiPerfSample
                $Sample.Kind = 'key'
                $Sample.DispatchMs = $I % 100
                $Sample.HandlerMs = 1
                $Sample.Painted = ($I % 2) -eq 0
                Add-WtTuiPerfSample -Sample $Sample
            }

            $Samples = Get-WtTuiPerfSamples
            $Samples.Count | Should -Be 1024 -Because 'the ring is bounded'

            $Values = [double[]]@($Samples | ForEach-Object { $_.DispatchMs } | Sort-Object)
            (Get-WtPerfPercentile -Values $Values -Percentile 0.5) | Should -BeGreaterThan 0
            (Get-WtPerfPercentile -Values $Values -Percentile 1) | Should -BeLessThan 100
        }
    }
}
