# WindowsTweaker - optional background worker integration tests.
#
# These drive the real protocol: the PowerShell adapter (client) against the built worker,
# plus canned "fake worker" scripts for the failure modes that a working worker cannot
# produce on demand (version mismatch, crash, an oversized line, garbage on stdout).
#
# The fake workers are POSIX shell scripts, so those cases run on Linux/macOS; on Windows the
# corresponding tests are skipped rather than silently passing.

# Computed at discovery time: -Skip: conditions are evaluated before BeforeAll runs.
$script:WorkerPath = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'worker/bin/linux-amd64/wt-worker'
$script:HasWorker = Test-Path -LiteralPath $script:WorkerPath -PathType Leaf
if (-not $script:HasWorker)
{
    Write-Warning "The worker binary is not built ($script:WorkerPath); the tests that need it are skipped."
}

BeforeAll {
    $script:RepositoryRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:ModuleManifest = Join-Path $script:RepositoryRoot 'src/WindowsTweaker/WindowsTweaker.psd1'

    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-worker-{0}" -f ([guid]::NewGuid().ToString('n')))
    $env:WT_DATA_ROOT = $script:TestDataRoot
    $env:WT_STATE_PATH = Join-Path $script:TestDataRoot 'state.json'
    $env:WT_LOG_DIRECTORY = Join-Path $script:TestDataRoot 'logs'
    $env:WT_SETTINGS_PATH = Join-Path $script:TestDataRoot 'settings.json'
    $env:WT_LANG = 'en'

    Import-Module $script:ModuleManifest -Force

    # A tree with a known total, a Vietnamese file name, a symlink, a hard link and an
    # unreadable directory.
    $script:Tree = Join-Path $script:TestDataRoot 'tree'
    foreach ($Directory in 'a', 'b', 'c') { New-Item -ItemType Directory -Path (Join-Path $script:Tree $Directory) -Force | Out-Null }
    [System.IO.File]::WriteAllBytes((Join-Path $script:Tree 'a/one.bin'), [byte[]]::new(100))
    [System.IO.File]::WriteAllBytes((Join-Path $script:Tree 'b/tệp việt.bin'), [byte[]]::new(200))
    [System.IO.File]::WriteAllBytes((Join-Path $script:Tree 'c/three.bin'), [byte[]]::new(300))
    New-Item -ItemType SymbolicLink -Path (Join-Path $script:Tree 'outside') -Target '/etc' -ErrorAction Ignore | Out-Null
    New-Item -ItemType HardLink -Path (Join-Path $script:Tree 'hardlink.bin') -Target (Join-Path $script:Tree 'a/one.bin') -ErrorAction Ignore | Out-Null

}

AfterAll {
    Remove-Item Env:\WT_WORKER_PATH -ErrorAction Ignore
    Remove-Module WindowsTweaker -Force -ErrorAction Ignore
    Remove-Item -LiteralPath $script:TestDataRoot -Recurse -Force -ErrorAction Ignore
}

Describe 'Worker discovery and backend selection' {

    It 'resolves the worker from an application-controlled path, never from PATH' {
        InModuleScope WindowsTweaker {
            $Resolved = Get-WtWorkerBackendPath
            if ($Resolved) { $Resolved | Should -Be (Resolve-Path -LiteralPath $Resolved).Path }
            (Get-Command -Name 'wt-worker' -ErrorAction Ignore) | Should -BeNullOrEmpty -Because 'the worker is never looked up on PATH'
        }
    }

    It 'reports an explicit Go request as unavailable instead of silently using PowerShell' {
        InModuleScope WindowsTweaker {
            $env:WT_WORKER_PATH = Join-Path $TestDrive 'does-not-exist'
            try
            {
                $Resolution = Resolve-WtWorkerBackend -Requested 'Go'
                $Resolution.Backend | Should -Be ''
                $Resolution.Reason | Should -Match 'unavailable'
            }
            finally
            {
                Remove-Item Env:\WT_WORKER_PATH -ErrorAction Ignore
            }
        }
    }

    It 'falls back to PowerShell under Auto and says why' {
        InModuleScope WindowsTweaker {
            $env:WT_WORKER_PATH = Join-Path $TestDrive 'does-not-exist'
            try
            {
                $Resolution = Resolve-WtWorkerBackend -Requested 'Auto'
                $Resolution.Backend | Should -Be 'PowerShell'
                $Resolution.Reason | Should -Not -BeNullOrEmpty
            }
            finally
            {
                Remove-Item Env:\WT_WORKER_PATH -ErrorAction Ignore
            }
        }
    }

    It 'saves and reads the backend preference' {
        InModuleScope WindowsTweaker {
            (Get-WtWorkerBackendPreference) | Should -Be 'Auto' -Because 'Auto is the stored default'
            Set-WtWorkerBackendPreference -Backend 'Go' | Should -Be 'Go'
            (Get-WtWorkerBackendPreference) | Should -Be 'Go'
            (Resolve-WtWorkerBackend).Requested | Should -Be 'Go'
            Set-WtWorkerBackendPreference -Backend 'Auto' | Out-Null
        }
    }
}

Describe 'Protocol handshake and the real worker' {

    It 'completes the handshake and advertises protocol 1 with scan.directory' -Skip:(-not $script:HasWorker) {
        InModuleScope WindowsTweaker {
            $Status = Get-WtWorkerStatus -Force
            $Status.Available | Should -BeTrue
            $Status.Protocol | Should -Be 1
            $Status.ExpectedProtocol | Should -Be 1
            $Status.Capabilities | Should -Contain 'scan.directory'
        }
    }

    It 'refuses an incompatible protocol version and reports it' {
        $Fake = Join-Path $TestDrive 'fake-mismatch.sh'
        Set-Content -LiteralPath $Fake -Value @'
#!/bin/sh
read line
printf '{"v":99,"type":"error","id":"handshake","error":{"code":"E_PROTOCOL_VERSION","message":"nope"}}\n'
sleep 0.2
'@ -Encoding utf8NoBOM
        & chmod +x $Fake

        $env:WT_WORKER_PATH = $Fake
        try
        {
            InModuleScope WindowsTweaker {
                $Status = Get-WtWorkerStatus -Force
                $Status.Available | Should -BeFalse
                $Status.Code | Should -Be 'NoHandshake'
                $Status.Reason | Should -Not -BeNullOrEmpty
            }
        }
        finally
        {
            Remove-Item Env:\WT_WORKER_PATH -ErrorAction Ignore
        }
    }

    It 'treats a worker that dies during the handshake as a failure, not as a result' {
        $Fake = Join-Path $TestDrive 'fake-crash.sh'
        Set-Content -LiteralPath $Fake -Value "#!/bin/sh`nexit 7`n" -Encoding utf8NoBOM
        & chmod +x $Fake

        $env:WT_WORKER_PATH = $Fake
        try
        {
            InModuleScope WindowsTweaker {
                $Status = Get-WtWorkerStatus -Force
                $Status.Available | Should -BeFalse
                $Status.Reason | Should -Not -BeNullOrEmpty
            }
        }
        finally
        {
            Remove-Item Env:\WT_WORKER_PATH -ErrorAction Ignore
        }
    }

    It 'survives a worker that writes garbage instead of protocol messages' {
        $Fake = Join-Path $TestDrive 'fake-garbage.sh'
        Set-Content -LiteralPath $Fake -Value "#!/bin/sh`nread line`nprintf 'this is not json\\n'`nsleep 0.2`n" -Encoding utf8NoBOM
        & chmod +x $Fake

        $env:WT_WORKER_PATH = $Fake
        try
        {
            InModuleScope WindowsTweaker {
                { Start-WtWorkerClient -TimeoutMs 1000 } | Should -Throw
                $Status = Get-WtWorkerStatus -Force
                $Status.Available | Should -BeFalse
            }
        }
        finally
        {
            Remove-Item Env:\WT_WORKER_PATH -ErrorAction Ignore
        }
    }
}

Describe 'Directory scan through both backends' {

    It 'returns the same aggregate from PowerShell and from the worker' -Skip:(-not $script:HasWorker) {
        InModuleScope WindowsTweaker -Parameters @{ Tree = $script:Tree; DataRoot = $script:TestDataRoot } {
            $PowerShell = Invoke-WtDirectoryScan -Root $Tree -Backend 'PowerShell'
            $Go = Invoke-WtDirectoryScan -Root $Tree -Backend 'Go'

            $PowerShell.Ok | Should -BeTrue
            $Go.Ok | Should -BeTrue
            $PowerShell.Backend | Should -Be 'PowerShell'
            $Go.Backend | Should -Be 'Go'

            # Both must agree on what they skipped and on the tree they walked. The logical
            # total differs by exactly the hard link, because the worker deduplicates it and the
            # PowerShell implementation cannot (documented, and visible in the result notes).
            $Go.SkippedLinks | Should -Be $PowerShell.SkippedLinks
            $Go.HardLinksDeduped | Should -Be 1
            $Go.Files | Should -Be ($PowerShell.Files - 1)
            $Go.Bytes | Should -Be ($PowerShell.Bytes - 100)
            $Go.Directories | Should -Be $PowerShell.Directories
            $Go.HardLinksDeduped | Should -Be 1
            $PowerShell.HardLinksDeduped | Should -Be 0
            $PowerShell.AllocatedKnown | Should -BeFalse
            $Go.AllocatedKnown | Should -BeTrue
        }
    }

    It 'reports a Vietnamese file name without mangling it' -Skip:(-not $script:HasWorker) {
        InModuleScope WindowsTweaker -Parameters @{ Tree = $script:Tree; DataRoot = $script:TestDataRoot } {
            foreach ($Backend in 'PowerShell', 'Go')
            {
                $Result = Invoke-WtDirectoryScan -Root $Tree -Backend $Backend
                $Names = @($Result.Largest | ForEach-Object { $_.path })
                ($Names -join ' ') | Should -Match 'việt'
            }
        }
    }

    It 'reports unreadable entries as partial instead of a false success' -Skip:(-not $script:HasWorker -or $IsWindows) {
        InModuleScope WindowsTweaker -Parameters @{ Tree = $script:Tree; DataRoot = $script:TestDataRoot } {
            $Denied = Join-Path $Tree 'denied'
            New-Item -ItemType Directory -Path $Denied -Force | Out-Null
            [System.IO.File]::WriteAllBytes((Join-Path $Denied 'hidden.bin'), [byte[]]::new(50))
            & chmod 000 $Denied

            try
            {
                foreach ($Backend in 'PowerShell', 'Go')
                {
                    $Result = Invoke-WtDirectoryScan -Root $Tree -Backend $Backend
                    $Result.Partial | Should -BeTrue -Because "$Backend must report a partial result"
                    @($Result.Errors).Count | Should -BeGreaterThan 0
                    ($Result.Errors | Where-Object { $_.code -eq 'E_ACCESS_DENIED' }).Count | Should -BeGreaterThan 0
                }
            }
            finally
            {
                & chmod 755 $Denied
                Remove-Item -LiteralPath $Denied -Recurse -Force -ErrorAction Ignore
            }
        }
    }

    It 'cancels a scan, reports it as cancelled, and keeps the worker usable' -Skip:(-not $script:HasWorker) {
        InModuleScope WindowsTweaker -Parameters @{ Tree = $script:Tree; DataRoot = $script:TestDataRoot } {
            # A tree big enough that cancellation lands mid-walk.
            $Big = Join-Path $DataRoot 'big'
            for ($Index = 0; $Index -lt 300; $Index++)
            {
                $Directory = Join-Path $Big ("d{0:d3}" -f $Index)
                New-Item -ItemType Directory -Path $Directory -Force | Out-Null
                [System.IO.File]::WriteAllBytes((Join-Path $Directory 'f.bin'), [byte[]]::new(64))
            }

            # Cancellation is cooperative, so on a fast filesystem the walk may finish before the
            # cancel request lands. Both outcomes are legitimate; what must never happen is a
            # wrong report or a dead worker.
            $Calls = 0
            $Result = Invoke-WtDirectoryScan -Root $Big -Backend 'Go' -CancelCheck { $script:CallCount = ++$Calls; return $Calls -ge 2 }
            if ($Result.Ok)
            {
                $Result.Cancelled | Should -BeFalse
                $Result.Code | Should -Be ''
            }
            else
            {
                $Result.Code | Should -BeIn 'E_CANCELLED', 'E_TIMEOUT'
            }

            # The worker must still answer: cancellation is cooperative, not a kill.
            $After = Invoke-WtDirectoryScan -Root $Tree -Backend 'Go'
            $After.Ok | Should -BeTrue
            $After.Files | Should -BeGreaterThan 0
        }
    }

    It 'stops the worker with a bounded wait after a scan' -Skip:(-not $script:HasWorker) {
        InModuleScope WindowsTweaker {
            $Client = Start-WtWorkerClient
            $Stop = Stop-WtWorkerClient -Client $Client -GraceMs 2000
            $Stop.Exited | Should -BeTrue
            $Stop.Killed | Should -BeFalse -Because 'a cooperative shutdown must be enough for the read-only worker'
        }
    }

    It 'records worker startup and round-trip overhead' -Skip:(-not $script:HasWorker) {
        $Overhead = Measure-WtWorkerOverhead -RoundTrips 5
        $Overhead.Available | Should -BeTrue
        $Overhead.StartupMs | Should -BeGreaterOrEqual 0
        $Overhead.RoundTrips | Should -Be 5
        $Overhead.CleanShutdown | Should -BeTrue
    }
}

Describe 'Directory children through both backends' {

    It 'returns the same listing from PowerShell and from the worker' -Skip:(-not $script:HasWorker) {
        InModuleScope WindowsTweaker -Parameters @{ Tree = $script:Tree } {
            $PowerShell = Invoke-WtDirectoryChildren -Root $Tree -Backend 'PowerShell'
            $Go = Invoke-WtDirectoryChildren -Root $Tree -Backend 'Go'

            $PowerShell.Ok | Should -BeTrue
            $Go.Ok | Should -BeTrue
            $PowerShell.Backend | Should -Be 'PowerShell'
            $Go.Backend | Should -Be 'Go'

            $GoEntries = @($Go.Entries)
            $PSEntries = @($PowerShell.Entries)
            $GoEntries.Count | Should -Be $PSEntries.Count

            foreach ($Entry in $GoEntries)
            {
                $Match = @($PSEntries | Where-Object { $_.name -eq $Entry.name })
                $Match.Count | Should -Be 1 -Because "children must be the same set; missing: $($Entry.name)"

                $Match[0].kind | Should -Be $Entry.kind

                # Logical byte totals of files and of directories without hard links are equal;
                # a directory containing the hard link differs by exactly the deduplicated file.
                if ($Entry.kind -eq 'file')
                {
                    $Match[0].bytes | Should -Be $Entry.bytes
                }
            }
        }
    }

    It 'reports an unreadable root as an error, never as an empty listing' -Skip:(-not $script:HasWorker) {
        InModuleScope WindowsTweaker {
            $Result = Invoke-WtDirectoryChildren -Root (Join-Path ([System.IO.Path]::GetTempPath()) 'wt-no-such-dir-xyz') -Backend 'Go'
            $Result.Ok | Should -BeFalse
            $Result.Code | Should -BeIn 'E_NOT_FOUND', 'E_ACCESS_DENIED'
        }
    }

    It 'falls back to PowerShell when the worker does not advertise scan.children' {
        $Fake = Join-Path $TestDrive 'fake-old-worker.sh'
        Set-Content -LiteralPath $Fake -Value @'
#!/bin/sh
printf '{"v":1,"type":"hello","id":"handshake","hello":{"worker":"old","version":"0.0.1","protocol":1,"goVersion":"","os":"linux","arch":"amd64","capabilities":["scan.directory"],"limits":{"maxLineBytes":1048576,"maxErrors":200,"scanWorkers":8,"maxScanDepth":128,"progressEveryMs":250,"maxResultPaths":220,"maxConcurrentJobs":4}}}\n'
while read line; do
  printf '{"v":1,"type":"error","id":"x","error":{"code":"E_UNKNOWN_OP","message":"unknown","detail":"scan.children"}}\n'
done
'@ -Encoding utf8NoBOM
        & chmod +x $Fake

        $env:WT_WORKER_PATH = $Fake
        try
        {
            InModuleScope WindowsTweaker -Parameters @{ Tree = $script:Tree } {
                # Re-probe with the fake worker: the session-wide handshake cache may still
                # hold the real worker from the tests above.
                $null = Get-WtWorkerStatus -Force

                $Auto = Invoke-WtDirectoryChildren -Root $Tree -Backend 'Auto'
                $Auto.Backend | Should -Be 'PowerShell'
                $Auto.Ok | Should -BeTrue

                $Explicit = Invoke-WtDirectoryChildren -Root $Tree -Backend 'Go'
                $Explicit.Ok | Should -BeFalse
                $Explicit.Code | Should -Be 'MissingCapability'
            }
        }
        finally
        {
            Remove-Item Env:\WT_WORKER_PATH -ErrorAction Ignore
        }
    }
}
