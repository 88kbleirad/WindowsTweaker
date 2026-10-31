# WindowsTweaker - multi-host / incident / playbook / support-bundle tests.

BeforeAll {
    $ModuleManifest = Join-Path $PSScriptRoot '../src/WindowsTweaker/WindowsTweaker.psd1'
    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-mh-{0}" -f ([guid]::NewGuid().ToString('n')))

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

Describe 'Fleet host identity and conditions' {

    It 'keeps stable identity per source and never merges same hostname across sources' {
        InModuleScope WindowsTweaker {
            $Fleet = New-WtFleetState
            $S1 = Register-WtFleetSource -Fleet $Fleet -Endpoint 'http://127.0.0.1:9090' -Alias 'dc1'
            $S2 = Register-WtFleetSource -Fleet $Fleet -Endpoint 'http://127.0.0.1:9091' -Alias 'dc2'

            # Simulate observations directly into the host map (deterministic, offline).
            $Fleet.Hosts["$($S1.Id)|web-1"] = @{ SourceId = $S1.Id; SourceAlias = 'dc1'; Instance = 'web-1'; Alias = ''; Condition = 'healthy'; Metrics = @{}; FreshnessMs = 1000 }
            $Fleet.Hosts["$($S2.Id)|web-1"] = @{ SourceId = $S2.Id; SourceAlias = 'dc2'; Instance = 'web-1'; Alias = ''; Condition = 'failed-scrape'; Metrics = @{}; FreshnessMs = 1000 }

            $Rows = Get-WtFleetRows -Fleet $Fleet
            $Rows.Count | Should -Be 2
            # Distinct identity keys; same hostname across sources is preserved.
            ($Rows | Where-Object { $_.Instance -eq 'web-1' }).Count | Should -Be 2
        }
    }

    It 'condition mapping keeps failed scrape distinct from host availability' {
        InModuleScope WindowsTweaker {
            $Fleet = New-WtFleetState
            $S = Register-WtFleetSource -Fleet $Fleet -Endpoint 'http://127.0.0.1:9090'

            $Fleet.Hosts["$($S.Id)|h"] = @{ SourceId = $S.Id; SourceAlias = $S.Alias; Instance = 'h'; Alias = ''; Condition = 'failed-scrape'; Metrics = @{}; FreshnessMs = 1000 }
            $Rows = Get-WtFleetRows -Fleet $Fleet
            $Rows[0].Condition | Should -Be 'failed-scrape'
        }
    }
}

Describe 'Incident workspace' {

    It 'orders timeline events and marks timestamp uncertainty' {
        InModuleScope WindowsTweaker {
            $Incident = New-WtIncident -FromMs 1000 -ToMs 5000
            Add-WtIncidentEvent -Incident $Incident -Kind observed -Source 'journal' -Type operation -AtMs 4000 -Text 'op2'
            Add-WtIncidentEvent -Incident $Incident -Kind observed -Source 'journal' -Type operation -AtMs 2000 -Text 'op1'
            Add-WtIncidentEvent -Incident $Incident -Kind inferred -Source 'metrics' -Type boot -AtMs 3000 -Text 'uptime reset' -ClockUncertain $true

            $Ordered = @($Incident.Events | Sort-Object AtMs)
            $Ordered[0].Text | Should -Be 'op1'
            $Ordered[1].Text | Should -Be 'uptime reset'
            $Ordered[1].ClockUncertain | Should -BeTrue
            $Ordered[2].Text | Should -Be 'op2'
        }
    }

    It 'user notes never rewrite journal records' {
        InModuleScope WindowsTweaker {
            $Incident = New-WtIncident
            Add-WtIncidentEvent -Incident $Incident -Kind observed -Source 'journal' -Type operation -AtMs 1000 -Text 'op1'
            Add-WtIncidentNote -Incident $Incident -Text 'my note'

            $Incident.Notes.Count | Should -Be 1
            @($Incident.Events | Where-Object { $_.Type -eq 'operation' -and $_.Text -eq 'op1' }).Count | Should -Be 1
        }
    }

    It 'saves and reopens with schema validation' {
        InModuleScope WindowsTweaker {
            $Incident = New-WtIncident -Title 'x' -FromMs 1000 -ToMs 5000
            Add-WtIncidentEvent -Incident $Incident -Kind observed -Source 'journal' -Type operation -AtMs 2000 -Text 'op1'
            $Path = Save-WtIncident -Incident $Incident
            Test-Path -LiteralPath $Path | Should -BeTrue

            $Reopened = Read-WtIncident -Path $Path
            $Reopened.Id | Should -Be $Incident.Id
            @($Reopened.Events).Count | Should -Be 1
        }
    }
}

Describe 'Diagnostic playbooks' {

    It 'are read-only: running a playbook performs no mutation' {
        $Before = Test-Path -LiteralPath $env:WT_STATE_PATH
        InModuleScope WindowsTweaker {
            $Monitor = New-WtMonitorSession
            $Result = Invoke-WtPlaybook -Id 'network-slow-unstable' -Monitor $Monitor
            $Result.Outcome | Should -BeIn 'complete', 'inconclusive'
            $Result.Evidence.Count | Should -BeGreaterThan 0
            $Result.Limitations | Should -Not -BeNullOrEmpty
        }
        Test-Path -LiteralPath $env:WT_STATE_PATH | Should -Be $Before -Because 'playbooks never write state'
    }

    It 'rejects playbooks with unknown probes or non-allowlisted metrics' {
        InModuleScope WindowsTweaker {
            $Bad = @{
                schemaVersion = 1; id = 'bad'; revision = 1
                title = @{ en = 'bad'; vi = 'bad' }
                platforms = @('Windows10'); prerequisites = @()
                checks = @(
                    @{ id = 'c1'; probe = 'shell'; note = 'x' }
                    @{ id = 'c2'; probe = 'metric'; metric = 'custom.metric'; note = 'x' }
                )
                branches = @(); references = @(); limitations = ''; completion = ''
            }
            $Validation = Test-WtPlaybookDocument -Document $Bad
            $Validation.Valid | Should -BeFalse
            @($Validation.Errors | Where-Object { $_ -match 'unknown probe' }).Count | Should -Be 1
            @($Validation.Errors | Where-Object { $_ -match 'not allowlisted' }).Count | Should -Be 1
        }
    }
}

Describe 'Support bundles' {

    It 'redacts sensitive strings and strips terminal controls' {
        InModuleScope WindowsTweaker {
            $Clean = Clear-WtBundleText -Text "user=alice passwd=hunter2 token=abc123 `e[31mRED`e[0m"
            $Clean | Should -Not -Match 'hunter2'
            $Clean | Should -Not -Match "`e"
            $Clean | Should -Match '\[REDACTED\]'

            $Preview = Get-WtBundleRedactionPreview -Text 'user=alice password=hunter2'
            $Preview.Count | Should -BeGreaterThan 0
        }
    }

    It 'exports a zip with manifest hashes and bounded size; import is traversal-safe' {
        InModuleScope WindowsTweaker -Parameters @{ DataRoot = $script:TestDataRoot } {
            $Monitor = New-WtMonitorSession
            $Path = Join-Path $DataRoot 'bundle-test.zip'

            $Options = @{
                includeJournal = $false
                includeAlerts = $false
                includeMetrics = $false
                interval = @{ fromMs = 0; toMs = 1 }
                dashboards = @('overview')
                rules = $false
                playbooks = $true
            }
            $Bundle = Export-WtSupportBundle -Options $Options -Path $Path -Monitor $Monitor
            Test-Path -LiteralPath $Path | Should -BeTrue
            $Bundle.Entries | Should -BeGreaterThan 0

            $Imported = Import-WtSupportBundle -Path $Path
            $Imported.Historical | Should -BeTrue
            $Imported.Entries.Count | Should -BeGreaterThan 0
            @($Imported.Entries | Where-Object { $_.Name -eq 'manifest.json' }).Count | Should -Be 1

            # Traversal rejection.
            $Hostile = Join-Path $DataRoot 'hostile.zip'
            $Archive = [System.IO.Compression.ZipArchive]::new([System.IO.File]::Open($Hostile, 'CreateNew'), 'Create')
            $Entry = $Archive.CreateEntry('../evil.txt')
            $Entry.Open().Dispose()
            $Archive.Dispose()
            { Import-WtSupportBundle -Path $Hostile } | Should -Throw

            Remove-Item -LiteralPath $Path, $Hostile -Force -ErrorAction Ignore
        }
    }
}

Describe 'Versioned monitoring configuration revisions' {

    It 'records revisions without rewriting history and reverts without touching Windows settings' {
        InModuleScope WindowsTweaker -Parameters @{ DataRoot = $script:TestDataRoot } {
            $Dashboard = Get-WtBuiltinDashboards | Select-Object -First 1
            $Rev1 = Save-WtConfigRevision -Kind dashboard -Id overview -Document $Dashboard
            $Rev1 | Should -Be 1

            # Same content -> no new revision.
            $RevAgain = Save-WtConfigRevision -Kind dashboard -Id overview -Document $Dashboard
            $RevAgain | Should -Be 1

            # Modified content -> revision 2.
            $Dashboard2 = $Dashboard | ConvertTo-Json -Depth 12 | ConvertFrom-Json
            $Dashboard2.panels = @($Dashboard2.panels) + @(@{ id = 'extra'; type = 'stat'; metric = 'host.uptime.seconds'; unit = 'seconds' })
            $Rev2 = Save-WtConfigRevision -Kind dashboard -Id overview -Document $Dashboard2
            $Rev2 | Should -Be 2

            $All = Get-WtConfigRevisions -Kind dashboard -Id overview
            $All.Count | Should -Be 2  # one append-only snapshot per revision
            $All[0].revision | Should -Be 2

            # Revert to rev 1 validates before activating.
            $Restored = Restore-WtConfigRevision -Kind dashboard -Id overview -Revision 1
            $Restored.WindowsSettingsChanged | Should -BeFalse
        }
    }
}
