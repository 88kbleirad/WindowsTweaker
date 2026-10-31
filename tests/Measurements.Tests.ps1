# WindowsTweaker - network measurement contract tests.
#
# Every probe is driven through the -Resolve and -Now seams, so these tests never touch
# the network and never depend on the wall clock. The module's only job is to measure and
# to classify; the final test asserts that neither entry point applies a tweak or writes
# anything.

BeforeAll {
    $script:RepositoryRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:ModuleManifest = Join-Path $script:RepositoryRoot 'src/WindowsTweaker/WindowsTweaker.psd1'
    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-measure-{0}" -f ([guid]::NewGuid().ToString('n')))

    $env:WT_DATA_ROOT = $script:TestDataRoot
    $env:WT_STATE_PATH = Join-Path $script:TestDataRoot 'state.json'
    $env:WT_LOG_DIRECTORY = Join-Path $script:TestDataRoot 'logs'
    $env:WT_LANG = 'en'

    Import-Module $script:ModuleManifest -Force
}

AfterAll {
    Remove-Module WindowsTweaker -Force -ErrorAction Ignore
    Remove-Item -LiteralPath $script:TestDataRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_DATA_ROOT, Env:\WT_STATE_PATH, Env:\WT_LOG_DIRECTORY, Env:\WT_LANG -ErrorAction Ignore
}

Describe 'Network measurements' {

    It 'clamps the sample count to 1..20' {
        InModuleScope WindowsTweaker {
            $Fixed = [datetime]::new(2024, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
            $Now = { $Fixed }
            $Resolve = { param ($Context) return 10.0 }

            $None = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 0 -Resolve $Resolve -Now $Now
            $Many = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 99 -Resolve $Resolve -Now $Now
            $Negative = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples (-7) -Resolve $Resolve -Now $Now

            $None.Conditions.Samples | Should -Be 1
            @($None.Samples).Count | Should -Be 1
            $Many.Conditions.Samples | Should -Be 20
            @($Many.Samples).Count | Should -Be 20
            $Negative.Conditions.Samples | Should -Be 1
        }
    }

    It 'clamps the per-probe timeout to 250..5000 ms and hands the clamped value to the probe' {
        InModuleScope WindowsTweaker {
            $Script:SeenTimeouts = [System.Collections.Generic.List[int]]::new()
            $Fixed = [datetime]::new(2024, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
            $Now = { $Fixed }
            $Resolve = { param ($Context) $Script:SeenTimeouts.Add($Context.TimeoutMs); return 5.0 }

            $Fast = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 2 -TimeoutMs 10 -Resolve $Resolve -Now $Now
            $Slow = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 2 -TimeoutMs 99999 -Resolve $Resolve -Now $Now

            $Fast.Conditions.TimeoutMs | Should -Be 250
            $Slow.Conditions.TimeoutMs | Should -Be 5000
            ($Script:SeenTimeouts -join ',') | Should -Be '250,250,5000,5000'
        }
    }

    It 'retains every raw sample with its own value, unit, timestamp and the call conditions' {
        InModuleScope WindowsTweaker {
            $Script:Tick = 0
            $Script:Start = [datetime]::new(2024, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
            $Now = { $Script:Tick++; return $Script:Start.AddSeconds($Script:Tick) }
            $Resolve = { param ($Context) return (10.0 * $Context.Index) }

            $M = Measure-WtNetworkDiagnostics -Target 'example.test' -Kind 'tcp' -Port 8443 -Adapter 'eth0' -Samples 3 -Resolve $Resolve -Now $Now

            $M.MeasurementId | Should -Match '^wt-[0-9a-f]{32}$'
            $M.Target | Should -Be 'example.test'
            $M.Kind | Should -Be 'tcp'
            $M.Unit | Should -Be 'ms'

            @($M.Samples).Count | Should -Be 3
            @($M.Samples | Where-Object { $_.Ok }).Count | Should -Be 3
            $M.Samples[0].Index | Should -Be 1
            $M.Samples[0].Value | Should -Be 10
            $M.Samples[0].Unit | Should -Be 'ms'
            $M.Samples[2].Value | Should -Be 30

            # StartedUtc is the first clock read; each sample takes the next one.
            $M.Samples[0].TimestampUtc | Should -Be $M.StartedUtc.AddSeconds(1)
            $M.Samples[2].TimestampUtc | Should -Be $M.StartedUtc.AddSeconds(3)
            $M.CompletedUtc | Should -BeGreaterThan $M.StartedUtc

            $M.Conditions.Samples | Should -Be 3
            $M.Conditions.TimeoutMs | Should -Be 1500
            $M.Conditions.Port | Should -Be 8443
            $M.Conditions.Adapter | Should -Be 'eth0'
            $M.Conditions.Platform | Should -Be (Get-WtMeasurementPlatform)
            $M.Conditions.PSVersion | Should -Be $PSVersionTable.PSVersion.ToString()
        }
    }

    It 'records a failed probe with its error instead of dropping it, and keeps the other samples' {
        InModuleScope WindowsTweaker {
            $Fixed = [datetime]::new(2024, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
            $Now = { $Fixed }
            $Resolve = { param ($Context) if ($Context.Index -eq 2) { throw 'connection refused' }; return (12.0 * $Context.Index) }

            $M = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 3 -Resolve $Resolve -Now $Now

            @($M.Samples).Count | Should -Be 3
            $Failed = @($M.Samples | Where-Object { -not $_.Ok })
            $Failed.Count | Should -Be 1
            $Failed[0].Index | Should -Be 2
            $Failed[0].Value | Should -BeNullOrEmpty
            $Failed[0].Unit | Should -Be 'ms'
            $Failed[0].Error | Should -Match 'connection refused'

            # The probes after the failure still ran.
            @($M.Samples | Where-Object { $_.Ok }).Count | Should -Be 2
            $M.Samples[2].Value | Should -Be 36

            $M.Summary.Count | Should -Be 3
            $M.Summary.Ok | Should -Be 2
            $M.Summary.Failed | Should -Be 1

            # A probe that times out is a failed sample carrying its reason (and the probe
            # sees the clamped timeout), not a crash and not a silent gap.
            $Timeout = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 2 -TimeoutMs 300 -Resolve { param ($Context) throw "DNS resolution of 'example.test' timed out after $($Context.TimeoutMs) ms" } -Now $Now
            $Timeout.Conditions.TimeoutMs | Should -Be 300
            $Timeout.Summary.Count | Should -Be 2
            $Timeout.Summary.Ok | Should -Be 0
            $Timeout.Summary.Failed | Should -Be 2
            $Timeout.Samples[0].Error | Should -Match 'timed out after 300 ms'
        }
    }

    It 'treats a probe that returns no value as a failed sample' {
        InModuleScope WindowsTweaker {
            $Fixed = [datetime]::new(2024, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
            $Now = { $Fixed }
            $Resolve = { param ($Context) if ($Context.Index -eq 1) { return $null }; return 7.0 }

            $M = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 2 -Resolve $Resolve -Now $Now

            $M.Summary.Ok | Should -Be 1
            $M.Summary.Failed | Should -Be 1
            $M.Samples[0].Ok | Should -BeFalse
            $M.Samples[0].Error | Should -Match 'no value'
            $M.Samples[1].Value | Should -Be 7
        }
    }

    It 'computes Min, Max and Median over the successful samples only, with a lower-middle median' {
        InModuleScope WindowsTweaker {
            $Fixed = [datetime]::new(2024, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
            $Now = { $Fixed }

            # Even count: 100, 200, 300, 400 -> lower-middle is 200 (NOT the average 250).
            $Even = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 4 -Resolve { param ($Context) return (100.0 * $Context.Index) } -Now $Now
            $Even.Summary.Count | Should -Be 4
            $Even.Summary.Ok | Should -Be 4
            $Even.Summary.Min | Should -Be 100
            $Even.Summary.Max | Should -Be 400
            $Even.Summary.Median | Should -Be 200

            # Odd count of successes (one probe failed): 100, 200, 300, 400 -> index 1 -> 200.
            $Odd = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 5 -Resolve { param ($Context) if ($Context.Index -eq 5) { throw 'timeout' }; return (100.0 * $Context.Index) } -Now $Now
            $Odd.Summary.Count | Should -Be 5
            $Odd.Summary.Ok | Should -Be 4
            $Odd.Summary.Failed | Should -Be 1
            $Odd.Summary.Min | Should -Be 100
            $Odd.Summary.Max | Should -Be 400
            $Odd.Summary.Median | Should -Be 200

            # No successful sample at all -> no statistics to invent.
            $None = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 2 -Resolve { param ($Context) throw 'offline' } -Now $Now
            $None.Summary.Ok | Should -Be 0
            $None.Summary.Failed | Should -Be 2
            $None.Summary.Min | Should -BeNullOrEmpty
            $None.Summary.Max | Should -BeNullOrEmpty
            $None.Summary.Median | Should -BeNullOrEmpty
        }
    }
}

Describe 'Measurement comparison' {

    It 'classifies a large, non-overlapping drop as improved' {
        InModuleScope WindowsTweaker {
            $Fixed = [datetime]::new(2024, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
            $Now = { $Fixed }

            $Before = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 4 -Resolve { param ($Context) return (100.0 * $Context.Index) } -Now $Now
            $After = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 4 -Resolve { param ($Context) return (80.0 * $Context.Index) } -Now $Now

            $Result = Compare-WtMeasurements -Before $Before -After $After

            $Result.Classification | Should -Be 'improved'
            $Result.BeforeMedian | Should -Be 200
            $Result.AfterMedian | Should -Be 160
            $Result.DeltaMs | Should -Be -40
            $Result.DeltaPercent | Should -Be -20
            $Result.Unit | Should -Be 'ms'
            $Result.Criteria | Should -Match '^improved:'
            $Result.Reason | Should -Match 'before median 200 ms'
            $Result.Reason | Should -Match 'after max 320 ms <= before max 400 ms'
        }
    }

    It 'classifies a large, non-overlapping rise as regressed' {
        InModuleScope WindowsTweaker {
            $Fixed = [datetime]::new(2024, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
            $Now = { $Fixed }

            $Before = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 4 -Resolve { param ($Context) return (100.0 * $Context.Index) } -Now $Now
            $After = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 4 -Resolve { param ($Context) return (120.0 * $Context.Index) } -Now $Now

            $Result = Compare-WtMeasurements -Before $Before -After $After

            $Result.Classification | Should -Be 'regressed'
            $Result.BeforeMedian | Should -Be 200
            $Result.AfterMedian | Should -Be 240
            $Result.DeltaMs | Should -Be 40
            $Result.DeltaPercent | Should -Be 20
            $Result.Criteria | Should -Match '^regressed:'
            $Result.Reason | Should -Match 'after min 120 ms >= before min 100 ms'
        }
    }

    It 'classifies a change below the threshold as inconclusive' {
        InModuleScope WindowsTweaker {
            $Fixed = [datetime]::new(2024, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
            $Now = { $Fixed }

            $Before = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 4 -Resolve { param ($Context) return (100.0 * $Context.Index) } -Now $Now
            $After = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 4 -Resolve { param ($Context) return (100.0 * $Context.Index + 1.0) } -Now $Now

            $Result = Compare-WtMeasurements -Before $Before -After $After

            $Result.Classification | Should -Be 'inconclusive'
            $Result.DeltaMs | Should -Be 1
            $Result.Criteria | Should -Match 'smaller than the threshold'

            # The same change crosses the bar only when the threshold is lowered.
            $SmallThreshold = Compare-WtMeasurements -Before $Before -After $After -Threshold 0.001 -MinimumSamples 3
            $SmallThreshold.Classification | Should -Be 'regressed'
        }
    }

    It 'classifies a comparison of different targets, kinds or units as inconclusive' {
        InModuleScope WindowsTweaker {
            $Fixed = [datetime]::new(2024, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
            $Now = { $Fixed }
            $Resolve = { param ($Context) return (100.0 * $Context.Index) }

            $Base = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 4 -Resolve $Resolve -Now $Now

            $OtherTarget = Measure-WtNetworkDiagnostics -Target 'other.test' -Samples 4 -Resolve $Resolve -Now $Now
            $TargetResult = Compare-WtMeasurements -Before $Base -After $OtherTarget
            $TargetResult.Classification | Should -Be 'inconclusive'
            $TargetResult.Criteria | Should -Match 'target, kind or unit differ'
            $TargetResult.Reason | Should -Match "target 'example\.test' vs 'other\.test'"

            $OtherKind = $Base.Clone()
            $OtherKind['Kind'] = 'tcp'
            $KindResult = Compare-WtMeasurements -Before $Base -After $OtherKind
            $KindResult.Classification | Should -Be 'inconclusive'
            $KindResult.Reason | Should -Match "kind 'dns' vs 'tcp'"

            $OtherUnit = $Base.Clone()
            $OtherUnit['Unit'] = 's'
            $UnitResult = Compare-WtMeasurements -Before $Base -After $OtherUnit
            $UnitResult.Classification | Should -Be 'inconclusive'
            $UnitResult.Reason | Should -Match "unit 'ms' vs 's'"
        }
    }

    It 'classifies a better median with overlapping samples as inconclusive' {
        InModuleScope WindowsTweaker {
            $Fixed = [datetime]::new(2024, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
            $Now = { $Fixed }

            $Before = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 4 -Resolve { param ($Context) return 100.0 } -Now $Now
            # Median drops to 10 ms but one sample spikes to 500 ms, above the before max.
            $After = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 4 -Resolve { param ($Context) if ($Context.Index -eq 4) { return 500.0 }; return 10.0 } -Now $Now

            $Before.Summary.Median | Should -Be 100
            $After.Summary.Median | Should -Be 10
            $After.Summary.Max | Should -Be 500

            $Result = Compare-WtMeasurements -Before $Before -After $After

            $Result.Classification | Should -Be 'inconclusive'
            $Result.Criteria | Should -Match 'after-side maximum exceeds'
            $Result.Reason | Should -Match 'after max 500 ms exceeds before max 100 ms'
        }
    }

    It 'classifies too few or no successful samples as insufficient' {
        InModuleScope WindowsTweaker {
            $Fixed = [datetime]::new(2024, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
            $Now = { $Fixed }
            $Resolve = { param ($Context) return (100.0 * $Context.Index) }

            $TwoSamples = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 2 -Resolve $Resolve -Now $Now
            $FourSamples = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 4 -Resolve $Resolve -Now $Now

            $TooShort = Compare-WtMeasurements -Before $TwoSamples -After $FourSamples
            $TooShort.Classification | Should -Be 'insufficient'
            $TooShort.Criteria | Should -Match 'fewer successful samples than MinimumSamples'
            $TooShort.Reason | Should -Match 'MinimumSamples=3'

            # A raised MinimumSamples makes an otherwise comparable pair insufficient.
            (Compare-WtMeasurements -Before $FourSamples -After $FourSamples -MinimumSamples 5).Classification | Should -Be 'insufficient'

            $NoSuccess = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 4 -Resolve { param ($Context) throw 'offline' } -Now $Now
            $Zero = Compare-WtMeasurements -Before $FourSamples -After $NoSuccess
            $Zero.Classification | Should -Be 'insufficient'
            $Zero.Criteria | Should -Match 'zero successful samples'
        }
    }

    It 'never mutates the measurements it compares' {
        InModuleScope WindowsTweaker {
            $Fixed = [datetime]::new(2024, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
            $Now = { $Fixed }

            $Before = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 4 -Resolve { param ($Context) return (100.0 * $Context.Index) } -Now $Now
            $After = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 4 -Resolve { param ($Context) return (80.0 * $Context.Index) } -Now $Now

            $BeforeSnapshot = $Before | ConvertTo-Json -Depth 6 -Compress
            $AfterSnapshot = $After | ConvertTo-Json -Depth 6 -Compress

            $null = Compare-WtMeasurements -Before $Before -After $After

            ($Before | ConvertTo-Json -Depth 6 -Compress) | Should -Be $BeforeSnapshot
            ($After | ConvertTo-Json -Depth 6 -Compress) | Should -Be $AfterSnapshot
        }
    }

    It 'measures and compares without applying a tweak or writing anything' {
        InModuleScope WindowsTweaker {
            Mock Invoke-WtTweak { throw 'the measurement path must never apply a tweak' }
            Mock Set-WtRegistryValue { throw 'the measurement path must never write to the registry' }

            $Fixed = [datetime]::new(2024, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
            $Now = { $Fixed }

            $Before = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 4 -Resolve { param ($Context) return (100.0 * $Context.Index) } -Now $Now
            $After = Measure-WtNetworkDiagnostics -Target 'example.test' -Samples 4 -Resolve { param ($Context) return (80.0 * $Context.Index) } -Now $Now

            (Compare-WtMeasurements -Before $Before -After $After).Classification | Should -Be 'improved'

            Should -Not -Invoke -CommandName Invoke-WtTweak
            Should -Not -Invoke -CommandName Set-WtRegistryValue
            Test-Path -LiteralPath $env:WT_DATA_ROOT | Should -BeFalse
        }
    }
}
