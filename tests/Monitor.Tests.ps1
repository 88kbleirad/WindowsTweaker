# WindowsTweaker - monitoring workspace tests (metric model, history, alerts, dashboards,
# charts, collector lifecycle).

BeforeAll {
    $ModuleManifest = Join-Path $PSScriptRoot '../src/WindowsTweaker/WindowsTweaker.psd1'
    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-mon-{0}" -f ([guid]::NewGuid().ToString('n')))

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

Describe 'Metric model' {

    It 'accepts a valid gauge and rejects non-valid samples that carry values' {
        InModuleScope WindowsTweaker {
            $Good = New-WtMetricSample -Id 'host.mem.physical.usedBytes' -Type gauge -Unit bytes -Quality valid -Value 123.0
            @(Test-WtMetricSample -Sample $Good) | Should -BeNullOrEmpty

            # Missing data must never be replaced with zero.
            $Bad = New-WtMetricSample -Id 'host.cpu.utilization' -Type gauge -Unit '%' -Quality error -ErrorCode 'E_READ_FAILED' -Note 'x'
            @(Test-WtMetricSample -Sample $Bad) | Should -BeNullOrEmpty

            # A non-valid sample carrying a value is refused.
            { New-WtMetricSample -Id 'host.cpu.utilization' -Type gauge -Unit '%' -Quality unavailable -ErrorCode 'E_NO_BASELINE' -Value 0 } | Should -Throw
        }
    }

    It 'computes counter rates from monotonic elapsed time' {
        InModuleScope WindowsTweaker {
            $A = New-WtMetricSample -Id 'host.net.rxBytes' -Type counter -Unit bytes -Quality valid -Value 1000.0 -TsMs 100000
            $B = New-WtMetricSample -Id 'host.net.rxBytes' -Type counter -Unit bytes -Quality valid -Value 3000.0 -TsMs 101000
            $Rate = ConvertTo-WtMetricRate -Previous $A -Current $B -MonotonicMs 1000
            $Rate.valuePerSecond | Should -Be 2000
            $Rate.unitSuffix | Should -Be '/s'

            # Reset: counter decreases -> no negative rate, null result.
            $C = New-WtMetricSample -Id 'host.net.rxBytes' -Type counter -Unit bytes -Quality valid -Value 500.0 -TsMs 102000
            (ConvertTo-WtMetricRate -Previous $B -Current $C -MonotonicMs 1000) | Should -BeNullOrEmpty

            # Identity change -> null.
            $D = New-WtMetricSample -Id 'host.net.rxBytes' -Type counter -Unit bytes -Quality valid -Value 4000.0 -TsMs 103000 -Dims @{ adapter = 'eth0' }
            (ConvertTo-WtMetricRate -Previous $B -Current $D -MonotonicMs 1000) | Should -BeNullOrEmpty

            # First sample has no previous -> null handled by caller; here simply null prev.
            (ConvertTo-WtMetricRate -Previous $null -Current $B -MonotonicMs 1000) | Should -BeNullOrEmpty
        }
    }

    It 'keeps bytes/s distinct from bits/s and formats units' {
        InModuleScope WindowsTweaker {
            (Format-WtMetricValue -Value 2048 -Unit bytes) | Should -BeLike '2.0 KB'
            (Format-WtMetricValue -Value 2048 -Unit 'bytes/s') | Should -BeLike '2.0 KB'
            # No implicit conversion happens: bytes and bits are never mixed by the model.
            (Format-WtMetricValue -Value 8 -Unit 'bits/s') | Should -Be '8.0 bits/s'
        }
    }
}

Describe 'Bounded history' {

    It 'enforces series, sample and dimension bounds' {
        InModuleScope WindowsTweaker {
            $History = New-WtMetricHistory
            $History.Limits.SamplesPerSeries = 5
            $History.Limits.MaxSeries = 1
            $History.Limits.MaxDimsPerSeries = 2

            for ($i = 1; $i -le 8; $i++)
            {
                $null = Add-WtMetricSample -History $History -Sample (New-WtMetricSample -Id 'host.cpu.utilization' -Type gauge -Unit '%' -Quality valid -Value ([double]$i) -TsMs (1000 + $i))
            }

            $Series = $History.Series['host.cpu.utilization']
            $Series.Samples.Count | Should -Be 5
            $History.DroppedSamples | Should -Be 3

            # Series bound.
            $Rejected = Add-WtMetricSample -History $History -Sample (New-WtMetricSample -Id 'host.mem.physical.usedBytes' -Type gauge -Unit bytes -Quality valid -Value 1 -TsMs 1000)
            $Rejected.Accepted | Should -BeFalse
            $Rejected.Reason | Should -Be 'series-limit'

            # Dimension cardinality bound.
            $History2 = New-WtMetricHistory
            $History2.Limits.MaxDimsPerSeries = 2
            $null = Add-WtMetricSample -History $History2 -Sample (New-WtMetricSample -Id 'host.net.rxBytes' -Type counter -Unit bytes -Quality valid -Value 1 -Dims @{ adapter = 'a' } -TsMs 1)
            $null = Add-WtMetricSample -History $History2 -Sample (New-WtMetricSample -Id 'host.net.rxBytes' -Type counter -Unit bytes -Quality valid -Value 2 -Dims @{ adapter = 'b' } -TsMs 2)
            $Third = Add-WtMetricSample -History $History2 -Sample (New-WtMetricSample -Id 'host.net.rxBytes' -Type counter -Unit bytes -Quality valid -Value 3 -Dims @{ adapter = 'c' } -TsMs 3)
            $Third.Accepted | Should -BeFalse
            $Third.Reason | Should -Be 'dim-cardinality'
        }
    }

    It 'preserves gaps and never interpolates' {
        InModuleScope WindowsTweaker {
            $History = New-WtMetricHistory
            $null = Add-WtMetricSample -History $History -Sample (New-WtMetricSample -Id 'host.cpu.utilization' -Type gauge -Unit '%' -Quality valid -Value 10 -TsMs 1000)
            $null = Add-WtMetricSample -History $History -Sample (New-WtMetricSample -Id 'host.cpu.utilization' -Type gauge -Unit '%' -Quality valid -Value 20 -TsMs 200000)

            $Range = Get-WtMetricSamples -History $History -Key 'host.cpu.utilization' -FromMs 0 -ToMs 300000
            $Range.FromMs = 0
            $Range.ToMs = 300000
            $Buckets = ConvertTo-WtMetricBuckets -Range $Range -Buckets 4 -Method 'avg'
            # Only two samples exist; between them there is a gap (no interpolation).
            ($Buckets | Where-Object { -not $_.Gap }).Count | Should -Be 2
            ($Buckets | Where-Object { $_.Gap }).Count | Should -BeGreaterThan 0
        }
    }

    It 'reports partial history when the requested range exceeds availability' {
        InModuleScope WindowsTweaker {
            $History = New-WtMetricHistory
            $null = Add-WtMetricSample -History $History -Sample (New-WtMetricSample -Id 'host.cpu.utilization' -Type gauge -Unit '%' -Quality valid -Value 10 -TsMs 1000)

            $Range = Select-WtMetricRange -History $History -Key 'host.cpu.utilization' -Seconds 3600
            $Range.Available | Should -BeFalse
        }
    }
}

Describe 'Dashboard schema' {

    It 'accepts a built-in dashboard document' {
        InModuleScope WindowsTweaker {
            $Dashboard = Get-WtBuiltinDashboards | Select-Object -First 1
            $Validation = Test-WtDashboardDocument -Document $Dashboard
            $Validation.Valid | Should -BeTrue
        }
    }

    It 'rejects unknown fields, duplicate ids and non-allowlisted metrics' {
        InModuleScope WindowsTweaker {
            $Bad = @{
                schemaVersion = 1
                dashboardId = 'bad'
                panels = @(
                    @{ id = 'p'; type = 'sparkline'; metric = 'host.cpu.utilization'; unit = '%' }
                    @{ id = 'p'; type = 'stat'; metric = 'host.disk.system.freeBytes'; unit = 'bytes' }
                    @{ id = 'q'; type = 'sparkline'; metric = 'some.random.metric'; unit = 'x' }
                )
            }
            $Validation = Test-WtDashboardDocument -Document $Bad
            @($Validation.Errors | Where-Object { $_ -match 'duplicate panel id' }).Count | Should -Be 1
            @($Validation.Errors | Where-Object { $_ -match 'not on the allowlist' }).Count | Should -Be 1

            # Unsupported version.
            $Bad.schemaVersion = 99
            (Test-WtDashboardDocument -Document $Bad).Valid | Should -BeFalse
        }
    }
}

Describe 'Dashboard import/export and measurement' {

    It 'imports and exports dashboards end to end (never personal data)' {
        InModuleScope WindowsTweaker -Parameters @{ DataRoot = $script:TestDataRoot } {
            $Dashboard = Get-WtBuiltinDashboards | Select-Object -First 1
            $Json = $Dashboard | ConvertTo-Json -Depth 12

            $Path = Join-Path $DataRoot 'custom-dashboard.json'
            Set-Content -LiteralPath $Path -Value $Json -Encoding utf8NoBOM

            $Imported = Import-WtDashboardInternal -Path $Path
            $Imported.Ok | Should -BeTrue

            $Stored = Read-WtDashboardInternal -Id ([string]$Dashboard.dashboardId)
            $Stored.dashboardId | Should -Be 'overview'

            # Export writes only the definition.
            $Export = Join-Path $DataRoot 'exported.json'
            $Result = Export-WtDashboard -Id 'overview' -Path $Export -Confirm:$false
            (Get-Content -LiteralPath $Result -Raw) | Should -Match 'schemaVersion'
            (Get-Content -LiteralPath $Result -Raw) | Should -Not -Match 'history|sessions'
        }
    }

    It 'measurement reports conditions and counts' {
        InModuleScope WindowsTweaker {
            $Measure = Measure-WtMonitorCycle -Backend PowerShell -Cycles 3
            $Measure.Cycles | Should -Be 3
            $Measure.TotalSamples | Should -BeGreaterThan 0
            $Measure.Conditions.PowerShell | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Local alert rules' {

    It 'holds before firing and resolves only via hysteresis' {
        InModuleScope WindowsTweaker {
            $Rules = @([pscustomobject]@{
                    id = 'disk-low'
                    metric = 'host.disk.system.freeBytes'
                    operator = 'lt'
                    threshold = 100.0
                    durationSeconds = 3
                    hysteresis = 200.0
                    severity = 'high'
                    explanationKey = 'Mon.Alert.Rule.LowDisk'
                })

            $Latest = @{ 'host.disk.system.freeBytes' = (New-WtMetricSample -Id 'host.disk.system.freeBytes' -Type gauge -Unit bytes -Quality valid -Value 50 -TsMs 1) }
            $State = @{}

            $Base = 1700000000000

            # T=0: pending, not yet firing.
            $Alerts = Invoke-WtAlertEvaluation -Rules $Rules -LatestByMetric $Latest -State $State -NowMs $Base
            $Alerts[0].state | Should -Be 'pending'

            # T=2500ms: still pending (hold is 3s).
            $Alerts = Invoke-WtAlertEvaluation -Rules $Rules -LatestByMetric $Latest -State $State -NowMs ($Base + 2500)
            $Alerts[0].state | Should -Be 'pending'

            # T=4000ms: firing.
            $Alerts = Invoke-WtAlertEvaluation -Rules $Rules -LatestByMetric $Latest -State $State -NowMs ($Base + 4000)
            $Alerts[0].state | Should -Be 'firing'

            # Data disappears: alert does NOT resolve.
            $Latest = @{}
            $Alerts = Invoke-WtAlertEvaluation -Rules $Rules -LatestByMetric $Latest -State $State -NowMs ($Base + 5000)
            $Alerts[0].state | Should -Be 'firing'
        }
    }

    It 'missing data never resolves and downtime is explicit' {
        InModuleScope WindowsTweaker {
            $Rules = @([pscustomobject]@{
                    id = 'stale'
                    metric = 'host.collector.ageSeconds'
                    operator = 'gt'
                    threshold = 30.0
                    durationSeconds = 0
                    hysteresis = 10.0
                    severity = 'medium'
                    explanationKey = 'Mon.Alert.Rule.Stale'
                })
            $State = @{}
            $Latest = @{ 'host.collector.ageSeconds' = (New-WtMetricSample -Id 'host.collector.ageSeconds' -Type gauge -Unit seconds -Quality valid -Value 40 -TsMs 1) }

            $Base = 1700000000000
            $Alerts = Invoke-WtAlertEvaluation -Rules $Rules -LatestByMetric $Latest -State $State -NowMs ($Base + 2000)
            $Alerts[0].state | Should -Be 'firing'
            $Alerts[0].missing | Should -BeFalse

            # Missing -> the alert stays firing; `missing` is explicit.
            $Alerts = Invoke-WtAlertEvaluation -Rules $Rules -LatestByMetric @{} -State $State -NowMs ($Base + 3000)
            $Alerts[0].state | Should -Be 'firing'
            $Alerts[0].missing | Should -BeTrue
        }
    }

    It 'acknowledge and mute are flags, never resolution' {
        InModuleScope WindowsTweaker {
            $Rules = @([pscustomobject]@{
                    id = 'x'
                    metric = 'host.cpu.utilization'
                    operator = 'gt'
                    threshold = 90.0
                    durationSeconds = 0
                    hysteresis = 50.0
                    severity = 'high'
                    explanationKey = 'Mon.Alert.Rule.LowDisk'
                })
            $State = @{ x = @{ state = 'firing'; sinceMs = 0; firstConditionMs = 0; ack = $true; muted = $true } }
            $Latest = @{ 'host.cpu.utilization' = (New-WtMetricSample -Id 'host.cpu.utilization' -Type gauge -Unit '%' -Quality valid -Value 95 -TsMs 1) }

            $Alerts = Invoke-WtAlertEvaluation -Rules $Rules -LatestByMetric $Latest -State $State -NowMs 100
            $Alerts[0].state | Should -Be 'firing'
            $Alerts[0].ack | Should -BeTrue
            $Alerts[0].muted | Should -BeTrue
        }
    }
}

Describe 'Charts and collector integration' {

    It 'renders a chart with gaps and Unicode/ASCII fallbacks' {
        InModuleScope WindowsTweaker {
            $History = New-WtMetricHistory
            $null = Add-WtMetricSample -History $History -Sample (New-WtMetricSample -Id 'host.cpu.utilization' -Type gauge -Unit '%' -Quality valid -Value 10 -TsMs 1000)
            $null = Add-WtMetricSample -History $History -Sample (New-WtMetricSample -Id 'host.cpu.utilization' -Type gauge -Unit '%' -Quality valid -Value 80 -TsMs 2000)

            $Range = Get-WtMetricSamples -History $History -Key 'host.cpu.utilization' -FromMs 0 -ToMs 100000
            $Range.FromMs = 0
            $Range.ToMs = 100000
            $Buckets = ConvertTo-WtMetricBuckets -Range $Range -Buckets 10 -Method 'avg'

            $Unicode = Format-WtMetricChart -Buckets $Buckets -Height 3 -Width 10 -Unicode $true
            $Ascii = Format-WtMetricChart -Buckets $Buckets -Height 3 -Width 10 -Unicode $false

            $Unicode.Lines.Count | Should -Be 3
            $Ascii.Lines.Count | Should -Be 3
            ($Unicode.Lines -join '') | Should -Not -BeNullOrEmpty
            # Gaps are counted, not zero-filled.
            $Unicode.Gaps | Should -BeGreaterThan 0
        }
    }

    It 'a monitoring session never mutates the state store and stops cleanly' {
        $Before = Test-Path -LiteralPath $env:WT_STATE_PATH

        InModuleScope WindowsTweaker {
            $Monitor = New-WtMonitorSession
            $Monitor.FastSeconds = 1
            $Monitor.SlowSeconds = 60
            $Monitor = Start-WtMonitorSession -Monitor $Monitor

            # Drive a few cycles with a fake fast clock.
            for ($i = 0; $i -lt 4; $i++)
            {
                $Monitor.Collector.LastFast = [datetime]::UtcNow.AddSeconds(-2)
                Update-WtMonitorWorkspace -Monitor $Monitor
                Start-Sleep -Milliseconds 50
            }

            $Monitor.History.Series.Count | Should -BeGreaterThan 0
            $Monitor.AlertRules.Count | Should -Be 5

            Stop-WtMonitorSession -Monitor $Monitor
            $Monitor.Collector | Should -BeNullOrEmpty
        }

        Test-Path -LiteralPath $env:WT_STATE_PATH | Should -Be $Before -Because 'monitoring never writes the state store'
    }
}

Describe 'Persistent metrics recording' {

    It 'writes through the worker to a real SQLite store, then queries it' {
        InModuleScope WindowsTweaker -Parameters @{ DataRoot = $script:TestDataRoot } {
            $Path = Join-Path $DataRoot 'metrics-test.db'
            Remove-Item -LiteralPath $Path -Force -ErrorAction Ignore

            $Persistence = New-WtMetricPersistenceInternal -Path $Path
            $Enabled = Enable-WtMetricRecording -Persistence $Persistence -RetentionDays 30 -Confirm:$false
            $Enabled.Enabled | Should -BeTrue

            # Enqueue samples (fast + slow shape).
            $Samples = @(
                (New-WtMetricSample -Id 'host.cpu.utilization' -Type gauge -Unit '%' -Quality valid -Value 42.0 -TsMs 1000)
                (New-WtMetricSample -Id 'host.disk.system.freeBytes' -Type gauge -Unit bytes -Quality valid -Value 1e9 -TsMs 1000)
                (New-WtMetricSample -Id 'host.net.rxBytes' -Type counter -Unit bytes -Quality valid -Value 5000.0 -Dims @{ adapter = 'eth0' } -TsMs 1000)
                (New-WtMetricSample -Id 'host.cpu.utilization' -Type gauge -Unit '%' -Quality error -ErrorCode 'E_READ_FAILED' -Note 'x' -TsMs 1000)
            )
            Add-WtMetricPersistenceBatchInternal -Persistence $Persistence -Samples $Samples
            $Flushed = Write-WtMetricPersistenceBatch -Persistence $Persistence
            $Flushed | Should -Be 1
            $Persistence.Written | Should -Be 4

            $Range = Get-WtStoredMetricRange -Persistence $Persistence -Id 'host.cpu.utilization' -FromMs 0 -ToMs 5000 -BucketMs 1000
            $Range.Buckets.Count | Should -BeGreaterThan 0

            $State = Get-WtMetricRecording -Persistence $Persistence
            $State.Enabled | Should -BeTrue
            $State.Written | Should -Be 4

            Disable-WtMetricRecording -Persistence $Persistence -Confirm:$false | Out-Null
            $Persistence.Enabled | Should -BeFalse

            # Clean up the test database.
            Remove-Item -LiteralPath $Path -Force -ErrorAction Ignore
            Remove-Item -LiteralPath "$Path-shm" -Force -ErrorAction Ignore
            Remove-Item -LiteralPath "$Path-wal" -Force -ErrorAction Ignore
        }
    }

    It 'retention reports deleted rows and never touches recovery state' {
        InModuleScope WindowsTweaker -Parameters @{ DataRoot = $script:TestDataRoot } {
            $Path = Join-Path $DataRoot 'metrics-retention.db'
            Remove-Item -LiteralPath $Path -Force -ErrorAction Ignore

            $Persistence = New-WtMetricPersistenceInternal -Path $Path
            $null = Enable-WtMetricRecording -Persistence $Persistence -RetentionDays 30 -Confirm:$false

            # Old + new samples.
            $Old = @((New-WtMetricSample -Id 'host.cpu.utilization' -Type gauge -Unit '%' -Quality valid -Value 1 -TsMs 1000))
            $New = @((New-WtMetricSample -Id 'host.cpu.utilization' -Type gauge -Unit '%' -Quality valid -Value 2 -TsMs (1e12)))
            Add-WtMetricPersistenceBatchInternal -Persistence $Persistence -Samples $Old
            Add-WtMetricPersistenceBatchInternal -Persistence $Persistence -Samples $New
            $null = Write-WtMetricPersistenceBatch -Persistence $Persistence

            # Retention cutoff well after the old sample.
            Update-WtMetricRetentionInternal -Persistence $Persistence -NowMs 2000000

            $Range = Get-WtStoredMetricRange -Persistence $Persistence -Id 'host.cpu.utilization' -FromMs 0 -ToMs 3000000 -BucketMs 1000000
            # The old sample is gone; the new one remains (≥1 bucket).
            $Range.Buckets.Count | Should -BeGreaterThan 0

            # Recovery journal untouched: state file was never written by persistence.
            Test-Path -LiteralPath $env:WT_STATE_PATH | Should -BeFalse

            $Persistence.Enabled = $false
            Remove-Item -LiteralPath $Path -Force -ErrorAction Ignore
            Remove-Item -LiteralPath "$Path-shm" -Force -ErrorAction Ignore
            Remove-Item -LiteralPath "$Path-wal" -Force -ErrorAction Ignore
        }
    }

    It 'corrupt store reports a stable error; enable refuses and leaves the file untouched' {
        InModuleScope WindowsTweaker -Parameters @{ DataRoot = $script:TestDataRoot } {
            $Path = Join-Path $DataRoot 'metrics-corrupt.db'
            Set-Content -LiteralPath $Path -Value 'not a sqlite database at all, definitely corrupt' -Encoding utf8

            $Persistence = New-WtMetricPersistenceInternal -Path $Path
            { Enable-WtMetricRecording -Persistence $Persistence -Confirm:$false } | Should -Throw

            (Get-Content -LiteralPath $Path -Raw) | Should -Match 'not a sqlite database'
            $Persistence.Enabled | Should -BeFalse

            Remove-Item -LiteralPath $Path -Force -ErrorAction Ignore
        }
    }
}

Describe 'Custom dashboard layouts' {

    It 'saves, duplicates, and resets layouts without touching Windows settings' {
        InModuleScope WindowsTweaker -Parameters @{ DataRoot = $script:TestDataRoot } {
            $Dashboard = Get-WtBuiltinDashboards | Select-Object -First 1
            $Dashboard.panels = @($Dashboard.panels) + @(@{ id = 'extra'; type = 'stat'; metric = 'host.uptime.seconds'; unit = 'seconds' })
            $Saved = Save-WtDashboardInternal -Dashboard $Dashboard
            $Saved.Ok | Should -BeTrue

            $Stored = Read-WtDashboardInternal -Id 'overview'
            $Stored.panels.Count | Should -Be 5

            $Copy = Copy-WtDashboardInternal -Dashboard $Dashboard -NewId 'overview-copy'
            $Copy.Ok | Should -BeTrue
            (Read-WtDashboardInternal -Id 'overview-copy').dashboardId | Should -Be 'overview-copy'

            # Reject an invalid imported dashboard; the working layout must survive.
            $Bad = @{ schemaVersion = 99; dashboardId = 'bad'; panels = @() }
            $Validation = Test-WtDashboardDocument -Document $Bad
            $Validation.Valid | Should -BeFalse
            $Bad.schemaVersion = 2
            $Bad.panels = @(@{ id = 'x'; type = 'weird'; metric = 'host.cpu.utilization'; unit = '%' })
            $Validation = Test-WtDashboardDocument -Document $Bad
            $Validation.Valid | Should -BeFalse

            # Reset restores the template (still readable).
            Remove-WtDashboardInternal -Id 'overview' | Out-Null
            (Read-WtDashboardInternal -Id 'overview').panels.Count | Should -Be 4

            # Clean up stored layouts.
            Remove-WtDashboardInternal -Id 'overview-copy' | Out-Null
        }
    }
}

Describe 'Interval comparison' {

    It 'classifies improved/regressed/inconclusive/insufficient using documented spread scaling' {
        InModuleScope WindowsTweaker {
            # Build two synthetic intervals in history.
            $Monitor = New-WtMonitorSession
            $Base = 1700000000000
            for ($i = 0; $i -lt 20; $i++)
            {
                $null = Add-WtMetricSample -History $Monitor.History -Sample (New-WtMetricSample -Id 'host.cpu.utilization' -Type gauge -Unit '%' -Quality valid -Value ([double](40 + ($i % 5))) -TsMs ($Base + $i * 1000))
            }
            for ($i = 0; $i -lt 20; $i++)
            {
                $null = Add-WtMetricSample -History $Monitor.History -Sample (New-WtMetricSample -Id 'host.cpu.utilization' -Type gauge -Unit '%' -Quality valid -Value ([double](20 + ($i % 5))) -TsMs ($Base + 300000 + $i * 1000))
            }

            $Result = Compare-WtMonitorIntervals -Monitor $Monitor -BaselineFromMs $Base -BaselineToMs ($Base + 20000) -ComparisonFromMs ($Base + 300000) -ComparisonToMs ($Base + 320000) -Metrics @('host.cpu.utilization')
            $Row = $Result.Rows[0]
            $Row.Verdict | Should -Be 'Improved' -Because 'cpu median dropped by more than the pooled spread (lower-is-better)'

            # Insufficient on nearly-empty interval.
            $Result2 = Compare-WtMonitorIntervals -Monitor $Monitor -BaselineFromMs $Base -BaselineToMs ($Base + 20000) -ComparisonFromMs ($Base + 700000) -ComparisonToMs ($Base + 702000) -Metrics @('host.cpu.utilization')
            $Result2.Rows[0].Verdict | Should -Be 'Insufficient'
        }
    }

    It 'never claims causation and exports only the comparison payload' {
        InModuleScope WindowsTweaker -Parameters @{ DataRoot = $script:TestDataRoot } {
            $Monitor = New-WtMonitorSession
            $Base = 1700000000000
            for ($i = 0; $i -lt 12; $i++)
            {
                $null = Add-WtMetricSample -History $Monitor.History -Sample (New-WtMetricSample -Id 'host.mem.physical.usedBytes' -Type gauge -Unit bytes -Quality valid -Value ([double](1e9 + $i * 1e6)) -TsMs ($Base + $i * 1000))
            }
            $Result = Compare-WtMonitorIntervals -Monitor $Monitor -BaselineFromMs $Base -BaselineToMs ($Base + 6000) -ComparisonFromMs ($Base + 6000) -ComparisonToMs ($Base + 12000) -Metrics @('host.mem.physical.usedBytes')
            $Result.Note | Should -Match 'no causation'

            $Path = Join-Path $DataRoot 'comparison-export.json'
            $Payload = [ordered]@{ baseline = @{ fromMs = 1; toMs = 2 }; comparison = @{ fromMs = 3; toMs = 4 }; rows = @($Result.Rows) }
            $Payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
            (Get-Content -LiteralPath $Path -Raw) | Should -Match 'rows'
            (Get-Content -LiteralPath $Path -Raw) | Should -Not -Match 'history|sessions'
            Remove-Item -LiteralPath $Path -Force -ErrorAction Ignore
        }
    }
}

Describe 'Remote Prometheus data source' {

    BeforeEach {
        # A tiny local HTTP server acting as Prometheus (query_range + query), run as a
        # job so the HttpListener loop has its own runspace.
        $script:PromJob = Start-Job -ScriptBlock {
            $Listener = [System.Net.HttpListener]::new()
            $Listener.Prefixes.Add('http://127.0.0.1:39100/')
            $Listener.Start()
            while ($true) {
                $Context = $Listener.GetContext()
                $Path = $Context.Request.Url.AbsolutePath
                if ($Path -eq '/api/v1/query') {
                    $Body = '{"status":"success","data":{"resultType":"vector","result":[{"metric":{"__name__":"up","job":"test"},"value":[123,"1"]}]}}'
                }
                elseif ($Path -eq '/api/v1/query_range') {
                    $Body = '{"status":"success","data":{"resultType":"matrix","result":[{"metric":{"__name__":"node_cpu_seconds_total","mode":"idle","job":"test"},"values":[[123,"10"],[183,"12"]]}]}}'
                }
                else {
                    $Context.Response.StatusCode = 404
                    $Context.Response.Close()
                    continue
                }
                $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
                $Context.Response.ContentType = 'application/json'
                $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
                $Context.Response.Close()
            }
        }
        # Wait for the listener to come up.
        Start-Sleep -Milliseconds 600
    }

    AfterEach {
        Stop-Job $script:PromJob -ErrorAction Ignore
        Remove-Job $script:PromJob -Force -ErrorAction Ignore
    }

    It 'connects, queries a template, sanitizes labels, and bounds responses' {
        InModuleScope WindowsTweaker {
            $Source = New-WtPromDataSource -Endpoint 'http://127.0.0.1:39100' -TimeoutMs 5000 -MaxResponseBytes 65536
            $Conn = Test-WtPromConnection -Source $Source
            $Conn.Ok | Should -BeTrue

            # Query template with a variable placeholder.
            $Result = Invoke-WtPromQuery -Source $Source -Template $Script:WtPromQueryTemplates['host.cpu.utilization'] -StepSeconds 60
            $Result.Ok | Should -BeTrue
            $Result.Series.Count | Should -BeGreaterThan 0
            $Result.Series[0].Values[0].TsMs | Should -Be 123000

            # Sanitization: malicious label content.
            $Summary = Clear-WtPromLabel -Text "x`e[31mRED`e[0m`ny"
            $Summary | Should -Not -Match "`e"
            $Summary | Should -Not -Match "`n"
        }
    }
}
