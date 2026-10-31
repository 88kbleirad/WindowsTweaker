# WindowsTweaker - journaled quarantine tests.
#
# Everything here runs on any platform with temporary fixtures: a scan root, a state store
# and a quarantine storage directory. The probes that need Windows (uninstall registry,
# services) degrade to "unavailable" gracefully and are asserted as such; what is tested is
# the durability contract: persist-before-move, revalidation, same-volume rule, restore
# conflicts, interrupted-operation inspection, explicit deletion and the moved-vs-freed
# byte reporting.

BeforeAll {
    $ModuleManifest = Join-Path $PSScriptRoot '../src/WindowsTweaker/WindowsTweaker.psd1'
    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-quar-{0}" -f ([guid]::NewGuid().ToString('n')))

    $env:WT_DATA_ROOT = $script:TestDataRoot
    $env:WT_STATE_PATH = Join-Path $script:TestDataRoot 'state.json'
    $env:WT_LOG_DIRECTORY = Join-Path $script:TestDataRoot 'logs'
    $env:WT_PACKS_PATH = Join-Path $script:TestDataRoot 'packs'
    $env:WT_MIGRATIONS_PATH = Join-Path $script:TestDataRoot 'migrations.json'
    $env:WT_LANG = 'en'

    New-Item -ItemType Directory -Path $script:TestDataRoot -Force | Out-Null
    Import-Module $ModuleManifest -Force

    # A scan root with a portable leftover, a user-data-looking folder, a freshly modified
    # item and an empty folder.
    $script:ScanRoot = Join-Path $script:TestDataRoot 'scan-root'
    New-Item -ItemType Directory -Path (Join-Path $script:ScanRoot 'LeftoverApp') -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $script:ScanRoot 'LeftoverApp\app.exe'), [byte[]]::new(64))
    [System.IO.File]::WriteAllBytes((Join-Path $script:ScanRoot 'LeftoverApp\data.bin'), [byte[]]::new(16))
    New-Item -ItemType Directory -Path (Join-Path $script:ScanRoot 'Saves') -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $script:ScanRoot 'Saves\game.save'), [byte[]]::new(4))
    New-Item -ItemType Directory -Path (Join-Path $script:ScanRoot 'EmptyDir') -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $script:ScanRoot 'stale.bin'), [byte[]]::new(8))
}

AfterAll {
    Remove-Item -LiteralPath $script:TestDataRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_DATA_ROOT, Env:\WT_STATE_PATH, Env:\WT_LOG_DIRECTORY, Env:\WT_PACKS_PATH, Env:\WT_MIGRATIONS_PATH, Env:\WT_LANG, Env:\WT_QUARANTINE_DIR -ErrorAction Ignore
}

Describe 'Quarantine scan' {

    It 'is read-only: no state file and no candidate movement' {
        $Before = Test-Path -LiteralPath $env:WT_STATE_PATH
        InModuleScope WindowsTweaker -Parameters @{ ScanRoot = $script:ScanRoot } {
            $Scan = Get-WtQuarantineScanInternal -Root $ScanRoot
            $Scan.Candidates.Count | Should -Be 4
            # A portable executable with no install record is supporting evidence.
            $Leftover = @($Scan.Candidates | Where-Object { $_.Path -like '*LeftoverApp' })
            $Leftover.Count | Should -Be 1
            @($Leftover[0].Evidence | Where-Object { $_.Kind -eq 'PortableExecutable' -and $_.Sign -eq 'Supporting' }).Count | Should -BeGreaterThan 0
            # A user-data-looking name is contradicting evidence, never an automatic pick.
            $Saves = @($Scan.Candidates | Where-Object { $_.Path -like '*Saves' })
            @($Saves[0].Evidence | Where-Object { $_.Kind -eq 'UserData' -and $_.Sign -eq 'Contradicting' }).Count | Should -BeGreaterThan 0
            $Saves[0].Verdict | Should -Be 'InUse'
        }

        $After = Test-Path -LiteralPath $env:WT_STATE_PATH
        $After | Should -Be $Before
        Test-Path -LiteralPath (Join-Path $script:ScanRoot 'LeftoverApp\app.exe') | Should -BeTrue
    }

    It 'reports unavailable probes instead of assuming no evidence' {
        InModuleScope WindowsTweaker -Parameters @{ ScanRoot = $script:ScanRoot } {
            $Scan = Get-WtQuarantineScanInternal -Root $ScanRoot
            # On this host the service probe may be unavailable; if it is, it is listed, not
            # silently dropped.
            foreach ($Candidate in $Scan.Candidates)
            {
                foreach ($Evidence in $Candidate.Evidence)
                {
                    if (-not $Evidence.Available)
                    {
                        $Evidence.Kind | Should -BeIn 'RunningProcess', 'RunningService'
                    }
                }
            }
        }
    }
}

Describe 'Quarantine move and manifest durability' {

    BeforeEach {
        # Each test gets a clean state store so the manifest can never bleed between tests.
        Remove-Item -LiteralPath $env:WT_STATE_PATH -Force -ErrorAction Ignore
        Remove-Item -LiteralPath "$($env:WT_STATE_PATH).lock" -Force -ErrorAction Ignore
    }

    It 'persists the recovery intent before moving anything' {
        InModuleScope WindowsTweaker -Parameters @{ ScanRoot = $script:ScanRoot } {
            $Scan = Get-WtQuarantineScanInternal -Root $ScanRoot
            $Candidate = @($Scan.Candidates | Where-Object { $_.Path -like '*LeftoverApp' })[0]

            # Corrupt the state store: recovery intent cannot be persisted, so the move is
            # refused and nothing changes.
            Set-Content -LiteralPath (Get-WtStatePath) -Value '{not json' -Encoding utf8
            { Add-WtQuarantineEntries -Candidates @($Candidate) -Root $ScanRoot -Confirm:$false } | Should -Throw
            Test-Path -LiteralPath $Candidate.Path | Should -BeTrue -Because 'nothing moves when the manifest cannot be written'
            Test-Path -LiteralPath (Join-Path (Get-WtQuarantineLocation).Storage "$($Candidate.Id)") | Should -BeFalse

            # Repair the store and re-run: now the plan persists before the move.
            Remove-Item -LiteralPath (Get-WtStatePath) -Force -ErrorAction Ignore
            $Result = Add-WtQuarantineEntries -Candidates @($Candidate) -Root $ScanRoot -Confirm:$false
            $Result.Moved | Should -Be 1
            $Result.FreedBytes | Should -Be 0 -Because 'a same-volume move does not free disk space'

            $Manifest = Read-WtQuarantineManifest
            $Record = Get-WtQuarantineRecord -Id $Candidate.Id -Records $Manifest.Records
            $Record.stage | Should -Be 'verified'
            $Record.outcome | Should -Be 'moved'
            $Record.movedBytes | Should -BeGreaterThan 0
            $Record.freedBytes | Should -Be 0
            $Record.quarantinePath | Should -Not -BeNullOrEmpty
        }
    }

    It 'refuses to move outside the approved root or from the quarantine storage' {
        InModuleScope WindowsTweaker -Parameters @{ ScanRoot = $script:ScanRoot } {
            $Scan = Get-WtQuarantineScanInternal -Root $ScanRoot

            # Outside boundary: a planned record whose source is not under the root.
            $Outside = @($Scan.Candidates | Where-Object { $_.Path -like '*stale.bin' })[0]
            $Plan = New-WtQuarantinePlanInternal -Candidates @($Outside) -Root (Join-Path $ScanRoot 'DifferentRoot')
            $Planned = $Plan.Planned[0]
            $Result = Move-WtQuarantineItemInternal -Record $Planned
            $Result.outcome | Should -Be 'outside-boundary'
            $Result.stage | Should -Be 'failed'

            # Quarantine storage as source.
            $Q = Get-WtQuarantineLocation
            $StorageCandidate = [pscustomobject]@{
                Id = [guid]::NewGuid().ToString('n')
                Path = $Q.Storage
                IsDirectory = $true
                SizeBytes = 0
            }
            $Plan2 = New-WtQuarantinePlanInternal -Candidates @($StorageCandidate) -Root (Split-Path $Q.Storage -Parent)
            $Result2 = Move-WtQuarantineItemInternal -Record $Plan2.Planned[0]
            $Result2.outcome | Should -Be 'quarantine-source'
        }
    }

    It 'skips cross-volume cases with an explanation instead of copying and deleting' {
        InModuleScope WindowsTweaker {
            # A record on a different volume root: the rule fires before any existence check.
            $Record = [pscustomobject]@{
                id = 'cross'
                sourcePath = 'C:\Some\Leftover'
                sourceRoot = 'C:\Some'
                fingerprint = ''
                IsDirectory = $true
                quarantinePath = $null
                movedBytes = 0
                freedBytes = 0
                owner = (Get-WtStatePath)
                stage = 'planned'
                outcome = 'pending'
                message = ''
            }
            $Result = Move-WtQuarantineItemInternal -Record $Record
            $Result.outcome | Should -Be 'cross-volume'
            $Result.stage | Should -Be 'failed'
            $Result.message | Should -Match 'Same-volume moves only'
        }
    }

    It 'rejects a source that changed since the plan was written' {
        InModuleScope WindowsTweaker -Parameters @{ ScanRoot = $script:ScanRoot } {
            $Scan = Get-WtQuarantineScanInternal -Root $ScanRoot
            $Candidate = @($Scan.Candidates | Where-Object { $_.Path -like '*EmptyDir' })[0]
            $Plan = New-WtQuarantinePlanInternal -Candidates @($Candidate) -Root $ScanRoot
            $Record = $Plan.Planned[0]

            [System.IO.File]::WriteAllBytes((Join-Path $Record.sourcePath 'late.bin'), [byte[]]::new(1))

            $Result = Move-WtQuarantineItemInternal -Record $Record
            $Result.outcome | Should -Be 'source-changed'
            Test-Path -LiteralPath $Record.sourcePath | Should -BeTrue
        }
    }
}

Describe 'Quarantine restore' {

    BeforeEach {
        Remove-Item -LiteralPath $env:WT_STATE_PATH -Force -ErrorAction Ignore
        Remove-Item -LiteralPath "$($env:WT_STATE_PATH).lock" -Force -ErrorAction Ignore

        # Earlier describes may have moved the fixture; recreate it for this describe.
        $Leftover = Join-Path $script:ScanRoot 'LeftoverApp'
        if (-not (Test-Path -LiteralPath $Leftover))
        {
            New-Item -ItemType Directory -Path $Leftover -Force | Out-Null
            [System.IO.File]::WriteAllBytes((Join-Path $Leftover 'app.exe'), [byte[]]::new(64))
            [System.IO.File]::WriteAllBytes((Join-Path $Leftover 'data.bin'), [byte[]]::new(16))
        }

        InModuleScope WindowsTweaker -Parameters @{ ScanRoot = $script:ScanRoot } {
            $script:QScan = Get-WtQuarantineScanInternal -Root $ScanRoot
            $script:QCandidate = @($script:QScan.Candidates | Where-Object { $_.Path -like '*LeftoverApp' })[0]
            $null = Add-WtQuarantineEntries -Candidates @($script:QCandidate) -Root $ScanRoot -Confirm:$false
        }
    }

    It 'restores to the original path and refuses a silent overwrite' {
        InModuleScope WindowsTweaker {
            $Manifest = Read-WtQuarantineManifest
            $Record = Get-WtQuarantineRecord -Id $script:QCandidate.Id -Records $Manifest.Records

            # Destination exists again (simulates an external recreation): restore is refused.
            New-Item -ItemType Directory -Path $Record.sourcePath -Force | Out-Null
            $Refused = Restore-WtQuarantineInternal -Ids @($Record.id)
            $Refused.Unresolved | Should -Be 1
            @($Refused.Records | Where-Object { $_.id -eq $Record.id -and $_.outcome -eq 'destination-exists' }).Count | Should -Be 1

            # Explicit overwrite consent allows it.
            Remove-Item -LiteralPath $Record.sourcePath -Recurse -Force | Out-Null
            $Restored = Restore-WtQuarantineInternal -Ids @($Record.id) -Overwrite
            $Restored.Restored | Should -Be 1
            Test-Path -LiteralPath $Record.sourcePath | Should -BeTrue
            Test-Path -LiteralPath $Record.quarantinePath | Should -BeFalse
        }
    }

    It 'keeps a record unresolved when the quarantined content is missing' {
        InModuleScope WindowsTweaker {
            $Manifest = Read-WtQuarantineManifest
            $Record = Get-WtQuarantineRecord -Id $script:QCandidate.Id -Records $Manifest.Records

            # Simulate an interrupted or tampered state: the content is gone.
            Remove-Item -LiteralPath $Record.quarantinePath -Recurse -Force -ErrorAction Ignore

            $Result = Restore-WtQuarantineInternal -Ids @($Record.id)
            $Result.Unresolved | Should -Be 1
            $Result.Restored | Should -Be 0
            $Record.stage | Should -BeIn 'moved', 'verified', 'unresolved'
        }
    }

    It 'reports interrupted operations and supports retry after the content reappears' {
        InModuleScope WindowsTweaker {
            $Manifest = Read-WtQuarantineManifest
            $Record = Get-WtQuarantineRecord -Id $script:QCandidate.Id -Records $Manifest.Records

            # Simulate a crash between move and verification: the record says moved but the
            # outcome was never verified.
            $Record.stage = 'moved'
            $Record.outcome = 'pending-verify'
            Write-WtQuarantineManifest -Records @($Manifest.Records) -Meta $Manifest.Meta

            $Interrupted = @((Read-WtQuarantineManifest).Records | Where-Object { $_.stage -eq 'moved' -and $_.outcome -eq 'pending-verify' })
            $Interrupted.Count | Should -Be 1

            # The content is present, so retry restores it.
            $Result = Restore-WtQuarantineInternal -Ids @($Record.id)
            $Result.Restored | Should -Be 1
        }
    }

    It 'frees bytes only through explicit deletion' {
        InModuleScope WindowsTweaker {
            $Manifest = Read-WtQuarantineManifest
            $Record = Get-WtQuarantineRecord -Id $script:QCandidate.Id -Records $Manifest.Records

            # Without -Delete nothing is deleted.
            $NoOp = Remove-WtQuarantineInternal -Ids @($Record.id)
            $NoOp.Removed | Should -Be 0
            Test-Path -LiteralPath $Record.quarantinePath | Should -BeTrue

            # With explicit -Delete the stored content is gone and the record says deleted.
            $Deleted = Remove-WtQuarantineInternal -Ids @($Record.id) -Delete
            $Deleted.Removed | Should -Be 1
            Test-Path -LiteralPath $Record.quarantinePath | Should -BeFalse
            @($Deleted.Records | Where-Object { $_.id -eq $Record.id -and $_.stage -eq 'deleted' }).Count | Should -Be 1
        }
    }

    It 'flags expired records for review and never deletes them at startup' {
        InModuleScope WindowsTweaker {
            $Manifest = Read-WtQuarantineManifest
            $Record = Get-WtQuarantineRecord -Id $script:QCandidate.Id -Records $Manifest.Records
            $Record.movedAt = (Get-Date).ToUniversalTime().AddDays(-95).ToString('o')
            Write-WtQuarantineManifest -Records @($Manifest.Records) -Meta $Manifest.Meta

            $Summary = Get-WtQuarantineSummary
            $Summary.ExpiredReview | Should -BeGreaterThan 0
            $Summary.Deleted | Should -Be 0 -Because 'expiry only flags for review'
            Test-Path -LiteralPath $Record.quarantinePath | Should -BeTrue
        }
    }
}
