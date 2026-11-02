# WindowsTweaker - Microsoft Activation Scripts external-tool tests.
#
# Everything here is inert. No test downloads or executes MAS, activates anything, requests
# elevation or reboots: the transport is replaced by a fixture writer, the process launch is
# replaced by a mock, and the "downloaded tool" used by the launch tests is a fixture file
# inside a temporary data root.
#
# The one test class that touches the network is opt-in (WT_EXTERNAL_TOOL_LIVE_TEST=1) and
# reads response headers only: it proves the pinned URL is still served and still redirects
# through allowed hosts, without saving or running the artifact.

BeforeAll {
    $script:ModuleManifest = Join-Path $PSScriptRoot '../src/WindowsTweaker/WindowsTweaker.psd1'
    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-external-tool-{0}" -f ([guid]::NewGuid().ToString('n')))

    $env:WT_DATA_ROOT = $script:TestDataRoot
    $env:WT_STATE_PATH = Join-Path $script:TestDataRoot 'state.json'
    $env:WT_LOG_DIRECTORY = Join-Path $script:TestDataRoot 'logs'
    $env:WT_LANG = 'en'

    New-Item -ItemType Directory -Path $script:TestDataRoot -Force | Out-Null
    Import-Module $script:ModuleManifest -Force

    InModuleScope WindowsTweaker -Parameters @{ HelperPath = (Join-Path $PSScriptRoot 'TuiTestHelpers.ps1') } {
        . $HelperPath
    }

    # Helpers that call the module's own private functions are dot-sourced into the module
    # session state, the same way tests/TuiTestHelpers.ps1 is. Defining them inline would put
    # them in a scope Pester discards when the BeforeAll block ends.
    InModuleScope WindowsTweaker -Parameters @{ ExternalToolHelperPath = (Join-Path $PSScriptRoot 'ExternalToolTestHelpers.ps1') } {
        . $ExternalToolHelperPath
    }

    # Empties the tool directory between tests so one test cannot inherit another's copy.
    function script:Clear-WtToolRoot
    {
        $Root = Join-Path $script:TestDataRoot 'external-tools'
        Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction Ignore
    }
}

AfterAll {
    Remove-Module WindowsTweaker -Force -ErrorAction Ignore
    Remove-Item -LiteralPath $script:TestDataRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_DATA_ROOT, Env:\WT_STATE_PATH, Env:\WT_LOG_DIRECTORY, Env:\WT_LANG -ErrorAction Ignore
}

Describe 'Upstream pin' {

    It 'pins one release commit of the official repository, not a branch' {
        InModuleScope WindowsTweaker {
            $Spec = Get-WtExternalToolSpec

            $Spec.Repository | Should -Be 'massgravel/Microsoft-Activation-Scripts'
            $Spec.Tag | Should -Be '3.12'
            $Spec.Commit | Should -Match '^[0-9a-f]{40}$'
            $Spec.RepositoryPath | Should -Be 'MAS/All-In-One-Version-KL/MAS_AIO.cmd'
            $Spec.FileName | Should -Be 'MAS_AIO.cmd'
            $Spec.License | Should -Be 'GPL-3.0'

            # The download URL names the commit: a branch name would make the artifact move.
            $Spec.DownloadUrl | Should -BeExactly ('https://raw.githubusercontent.com/massgravel/Microsoft-Activation-Scripts/{0}/{1}' -f $Spec.Commit, $Spec.RepositoryPath)
            $Spec.DownloadUrl | Should -Not -Match '/(main|master)/'
            $Spec.DownloadUrl.Contains($Spec.Commit) | Should -BeTrue

            # The digest is recorded next to the size, so a changed artifact is refused.
            $Spec.Sha256 | Should -Match '^[0-9a-f]{64}$'
            $Spec.GitBlobSha1 | Should -Match '^[0-9a-f]{40}$'
            $Spec.Bytes | Should -Be 761964

            # Bounds exist and are finite: no unbounded download, no unbounded redirect chain.
            $Spec.MaxBytes | Should -BeGreaterThan $Spec.Bytes
            $Spec.TimeoutSeconds | Should -BeGreaterThan 0
            $Spec.MaxRedirects | Should -BeGreaterOrEqual 0
        }
    }

    It 'allows only the official GitHub hosts' {
        InModuleScope WindowsTweaker {
            $Hosts = Get-WtExternalToolAllowedHosts
            $Hosts | Should -Contain 'raw.githubusercontent.com'
            $Hosts | Should -Contain 'api.github.com'
            @($Hosts | Where-Object { $_ -notmatch '^(raw\.githubusercontent\.com|api\.github\.com|github\.com|codeload\.github\.com|objects\.githubusercontent\.com|github-releases\.githubusercontent\.com|release-assets\.githubusercontent\.com)$' }) | Should -BeNullOrEmpty
        }
    }
}

Describe 'Download URL and redirect policy' {

    It 'refuses anything that is not HTTPS on an allowed host' {
        InModuleScope WindowsTweaker {
            { Assert-WtExternalToolUrl -Url 'http://raw.githubusercontent.com/a/b' } | Should -Throw -ExpectedMessage '*non-HTTPS*'
            { Assert-WtExternalToolUrl -Url 'https://example.invalid/a/b' } | Should -Throw -ExpectedMessage '*Host not allowed*'
            { Assert-WtExternalToolUrl -Url 'https://raw.githubusercontent.com.evil.invalid/a/b' } | Should -Throw -ExpectedMessage '*Host not allowed*'
            { Assert-WtExternalToolUrl -Url 'not a url' } | Should -Throw -ExpectedMessage '*malformed*'
            { Assert-WtExternalToolUrl -Url (Get-WtExternalToolSpec).DownloadUrl } | Should -Not -Throw
        }
    }

    It 'resolves a relative redirect against the current URL' {
        InModuleScope WindowsTweaker {
            $Base = [uri]'https://raw.githubusercontent.com/massgravel/Microsoft-Activation-Scripts/40c74d0d7f42146b1dd1ab59b5c7e836d6a56d1f/README.md'
            (Resolve-WtExternalToolRedirect -Base $Base -Location '../other.txt' -SourceUrl $Base.AbsoluteUri) |
                Should -Be 'https://raw.githubusercontent.com/massgravel/Microsoft-Activation-Scripts/other.txt'
        }
    }

    It 'refuses a redirect to another host, a non-HTTPS target or no Location at all' {
        InModuleScope WindowsTweaker {
            $Base = [uri]'https://github.com/massgravel/Microsoft-Activation-Scripts'

            { Resolve-WtExternalToolRedirect -Base $Base -Location 'https://evil.invalid/x' -SourceUrl $Base.AbsoluteUri } |
                Should -Throw -ExpectedMessage '*Host not allowed*'
            { Resolve-WtExternalToolRedirect -Base $Base -Location 'http://raw.githubusercontent.com/x' -SourceUrl $Base.AbsoluteUri } |
                Should -Throw -ExpectedMessage '*non-HTTPS*'
            { Resolve-WtExternalToolRedirect -Base $Base -Location '' -SourceUrl $Base.AbsoluteUri } |
                Should -Throw -ExpectedMessage '*without a Location*'
        }
    }
}

Describe 'Bounded transfer' {

    It 'copies exactly the bytes and stops at the size bound' {
        InModuleScope WindowsTweaker {
            $Source = [System.IO.MemoryStream]::new([byte[]]::new(2048))
            $Target = [System.IO.MemoryStream]::new()
            (Copy-WtExternalToolResponseStream -Source $Source -Target $Target -MaxBytes 2048) | Should -Be 2048
            $Target.Length | Should -Be 2048

            { Copy-WtExternalToolResponseStream -Source ([System.IO.MemoryStream]::new([byte[]]::new(2048))) -Target ([System.IO.MemoryStream]::new()) -MaxBytes 1024 } |
                Should -Throw -ExpectedMessage '*exceeds the 1024 byte limit*'
        }
    }

    It 'classifies a size overflow as an integrity failure, naming the source' {
        InModuleScope WindowsTweaker {
            $Message = $null
            try
            {
                $null = Copy-WtExternalToolResponseStream -Source ([System.IO.MemoryStream]::new([byte[]]::new(64))) `
                    -Target ([System.IO.MemoryStream]::new()) -MaxBytes 8 -SourceLabel 'https://raw.githubusercontent.com/x'
            }
            catch { $Message = $_.Exception.Message }

            $Message | Should -Match '^INTEGRITY:'
            $Message | Should -Match 'raw\.githubusercontent\.com'
        }
    }

    It 'computes the SHA-256 and the git blob id of a file' {
        InModuleScope WindowsTweaker {
            $Path = Join-Path $env:WT_DATA_ROOT 'digest-fixture.bin'
            $Bytes = [System.Text.Encoding]::UTF8.GetBytes('digest fixture')
            [System.IO.File]::WriteAllBytes($Path, $Bytes)
            $Expected = Get-WtTestDigest -Bytes $Bytes

            (Get-WtExternalToolHash -Path $Path -Algorithm 'SHA256') | Should -Be $Expected.Sha256
            (Get-WtExternalToolGitBlobHash -Path $Path) | Should -Be $Expected.GitBlobSha1
            (Get-WtExternalToolHash -Path (Join-Path $env:WT_DATA_ROOT 'missing.bin') -Algorithm 'SHA256') | Should -Be ''
        }
    }
}

Describe 'Download, verification and staging' {

    BeforeEach {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            Mock Test-WtExternalToolSupported { $true }
        }
    }

    It 'publishes only bytes that match the size, the upstream blob id and the digest' {
        InModuleScope WindowsTweaker {
            $Spec = New-WtTestSpec
            $script:Fixture = [System.Text.Encoding]::UTF8.GetBytes($Spec.Content)

            Mock Save-WtExternalToolDownload {
                param ($Url, $Path)
                [System.IO.File]::WriteAllBytes($Path, $script:Fixture)
                return [ordered]@{ Status = 'succeeded'; Bytes = [long]$script:Fixture.Length; FinalUri = $Url; Redirects = 0; ContentLength = [long]$script:Fixture.Length }
            }

            $Result = Invoke-WtExternalToolDownload -Spec $Spec

            $Result.Status | Should -Be 'succeeded'
            $Result.Code | Should -Be 'Downloaded'
            Test-Path -LiteralPath (Get-WtExternalToolEntryPointPath -Spec $Spec) | Should -BeTrue
            Test-Path -LiteralPath (Get-WtExternalToolProvenancePath) | Should -BeTrue

            # Nothing is left in staging, and the published record names what was verified.
            @(Get-ChildItem -LiteralPath (Get-WtExternalToolStagingRoot) -Filter '*.part' -ErrorAction Ignore).Count | Should -Be 0
            $Provenance = Read-WtExternalToolProvenance
            $Provenance['sha256'] | Should -Be $Spec.Sha256
            $Provenance['bytes'] | Should -Be $Spec.Bytes
            $Provenance['commit'] | Should -Be $Spec.Commit
            $Provenance['tag'] | Should -Be $Spec.Tag
            $Provenance['pinSource'] | Should -Be 'shipped'
            $Provenance['schema'] | Should -Be 'windows-tweaker.external-tool/1'

            $State = Get-WtExternalToolState -Spec $Spec
            $State.Ready | Should -BeTrue
            $State.Status | Should -Be 'Ready'
            $State.ProvenanceSource | Should -Be 'file'
        }
    }

    It 'refuses a digest mismatch and leaves nothing published' {
        InModuleScope WindowsTweaker {
            $Spec = New-WtTestSpec -BreakDigests
            $script:Fixture = [System.Text.Encoding]::UTF8.GetBytes($Spec.Content)

            Mock Save-WtExternalToolDownload {
                param ($Url, $Path)
                [System.IO.File]::WriteAllBytes($Path, $script:Fixture)
                return [ordered]@{ Status = 'succeeded'; Bytes = [long]$script:Fixture.Length; FinalUri = $Url; Redirects = 0; ContentLength = -1 }
            }

            $Result = Invoke-WtExternalToolDownload -Spec $Spec

            $Result.Status | Should -Be 'failed'
            $Result.Code | Should -Be 'Integrity'
            $Result.Reason | Should -Match 'git blob id'
            Test-Path -LiteralPath (Get-WtExternalToolEntryPointPath -Spec $Spec) | Should -BeFalse
            Test-Path -LiteralPath (Get-WtExternalToolProvenancePath) | Should -BeFalse
            @(Get-ChildItem -LiteralPath (Get-WtExternalToolStagingRoot) -Filter '*.part' -ErrorAction Ignore).Count | Should -Be 0
        }
    }

    It 'refuses content whose SHA-256 does not match even when the blob id does' {
        InModuleScope WindowsTweaker {
            # Same bytes, correct size and correct upstream blob id, but a digest that does
            # not describe them: the recorded-pin check is what must catch it.
            $Spec = New-WtTestSpec
            $Spec.Sha256 = ('0' * 64)
            $script:Fixture = [System.Text.Encoding]::UTF8.GetBytes($Spec.Content)

            Mock Save-WtExternalToolDownload {
                param ($Url, $Path)
                [System.IO.File]::WriteAllBytes($Path, $script:Fixture)
                return [ordered]@{ Status = 'succeeded'; Bytes = [long]$script:Fixture.Length; FinalUri = $Url; Redirects = 0; ContentLength = -1 }
            }

            $Result = Invoke-WtExternalToolDownload -Spec $Spec

            $Result.Status | Should -Be 'failed'
            $Result.Code | Should -Be 'Integrity'
            $Result.Reason | Should -Match 'pinned digest'
            Test-Path -LiteralPath (Get-WtExternalToolProvenancePath) | Should -BeFalse
        }
    }

    It 'still enforces the pinned digest when an update resolves to the pinned commit' {
        InModuleScope WindowsTweaker {
            $Spec = New-WtTestSpec
            $script:Fixture = [System.Text.Encoding]::UTF8.GetBytes('payload that is not the pin')
            Mock Save-WtExternalToolDownload {
                param ($Url, $Path)
                [System.IO.File]::WriteAllBytes($Path, $script:Fixture)
                return [ordered]@{ Status = 'succeeded'; Bytes = [long]$script:Fixture.Length; FinalUri = $Url; Redirects = 0; ContentLength = -1 }
            }

            $Release = [ordered]@{
                Ok           = $true
                Tag          = '3.12'
                Commit       = $Spec.Commit
                Bytes        = [long]$script:Fixture.Length
                GitBlobSha1  = ''
                DownloadUrl  = $Spec.DownloadUrl
                # The action decided to download (the local copy was a different commit), and
                # the resolution landed on the shipped commit again.
                UpToDate     = $false
                Reason       = ''
            }

            $Result = Invoke-WtExternalToolDownload -Spec $Spec -Release $Release

            $Result.Status | Should -Be 'failed'
            $Result.Code | Should -Be 'Integrity'
            $Result.Reason | Should -Match 'pinned digest'
        }
    }

    It 'keeps the previous copy when a re-download fails verification' {
        InModuleScope WindowsTweaker {
            $Good = New-WtTestSpec
            $script:Fixture = [System.Text.Encoding]::UTF8.GetBytes($Good.Content)
            Mock Save-WtExternalToolDownload {
                param ($Url, $Path)
                [System.IO.File]::WriteAllBytes($Path, $script:Fixture)
                return [ordered]@{ Status = 'succeeded'; Bytes = [long]$script:Fixture.Length; FinalUri = $Url; Redirects = 0; ContentLength = -1 }
            }

            $null = Invoke-WtExternalToolDownload -Spec $Good
            $Path = Get-WtExternalToolEntryPointPath -Spec $Good
            $Before = [System.IO.File]::ReadAllBytes($Path)

            # The next download is a pin the fixture does not describe: the transport now
            # writes the payload that is already installed, so the digests must be refused.
            $Bad = New-WtTestSpec -Content 'a different payload entirely'
            $script:Fixture = [System.Text.Encoding]::UTF8.GetBytes($Good.Content)
            $Result = Invoke-WtExternalToolDownload -Spec $Bad

            $Result.Status | Should -Be 'failed'
            @([System.IO.File]::ReadAllBytes($Path)) | Should -Be $Before
        }
    }

    It 'refuses a pinned size above the download limit without contacting the network' {
        InModuleScope WindowsTweaker {
            $Spec = New-WtTestSpec -MaxBytes 4
            Mock Save-WtExternalToolDownload { throw 'the transport must not run' }

            $Result = Invoke-WtExternalToolDownload -Spec $Spec

            $Result.Status | Should -Be 'failed'
            $Result.Code | Should -Be 'Integrity'
            $Result.Reason | Should -Match 'above the 4 byte download limit'
            Should -Invoke Save-WtExternalToolDownload -Times 0 -Exactly
        }
    }

    It 'reports an unsupported platform instead of downloading' {
        InModuleScope WindowsTweaker {
            Mock Test-WtExternalToolSupported { $false }
            Mock Save-WtExternalToolDownload { throw 'the transport must not run' }

            $Result = Invoke-WtExternalToolDownload -Spec (New-WtTestSpec)

            $Result.Status | Should -Be 'failed'
            $Result.Code | Should -Be 'Unsupported'
            Should -Invoke Save-WtExternalToolDownload -Times 0 -Exactly
        }
    }
}

Describe 'Background execution plumbing' {

    It 'reports progress and honours a cancellation request while reading' {
        InModuleScope WindowsTweaker {
            $Progress = [hashtable]::Synchronized(@{ Phase = 'downloading'; Received = [long]0; Total = [long]4096; Percent = -1 })
            $Target = [System.IO.MemoryStream]::new()
            $Copied = Copy-WtExternalToolResponseStream -Source ([System.IO.MemoryStream]::new([byte[]]::new(4096))) `
                -Target $Target -MaxBytes 8192 -Progress $Progress

            $Copied | Should -Be 4096
            $Progress.Received | Should -Be 4096
            $Progress.Percent | Should -Be 100

            $Cancel = [hashtable]::Synchronized(@{ Requested = $true })
            $Message = $null
            try
            {
                $null = Copy-WtExternalToolResponseStream -Source ([System.IO.MemoryStream]::new([byte[]]::new(65536))) `
                    -Target ([System.IO.MemoryStream]::new()) -Cancel $Cancel
            }
            catch { $Message = $_.Exception.Message }

            $Message | Should -Match '^CANCELLED:'
        }
    }

    It 'turns a cancelled transfer into a cancelled result and removes the staging file' {
        InModuleScope WindowsTweaker {
            Mock Test-WtExternalToolSupported { $true }
            Mock Save-WtExternalToolDownload { throw 'CANCELLED: the transfer was stopped' }

            $Result = Invoke-WtExternalToolDownload -Spec (New-WtTestSpec)

            $Result.Status | Should -Be 'cancelled'
            $Result.Code | Should -Be 'Cancelled'
            Test-Path -LiteralPath (Get-WtExternalToolProvenancePath) | Should -BeFalse
            @(Get-ChildItem -LiteralPath (Get-WtExternalToolStagingRoot) -Filter '*.part' -ErrorAction Ignore).Count | Should -Be 0
        }
    }

    It 'delivers the backend result from the runspace and releases the handle' {
        InModuleScope WindowsTweaker {
            $Spec = New-WtTestSpec
            # A host the pin would never allow: the refusal happens before any request, so this
            # test cannot touch the network (every check inside the runspace is the real code).
            $Spec.DownloadUrl = 'https://example.invalid/MAS_AIO.cmd'

            $Task = New-WtExternalToolTask
            try
            {
                $Start = Start-WtExternalToolTask -Task $Task -Spec $Spec -Mode 'download' -TimeoutSeconds 60
                $Start.Started | Should -BeTrue

                $Wait = [System.Diagnostics.Stopwatch]::StartNew()
                $Outcome = $null
                while ($Wait.Elapsed.TotalSeconds -lt 60)
                {
                    $Outcome = Complete-WtExternalToolTask -Task $Task
                    if ($Outcome.Completed) { break }
                    Start-Sleep -Milliseconds 50
                }

                $Outcome.Completed | Should -BeTrue
                $Outcome.Result | Should -Not -BeNullOrEmpty
                $Outcome.Result.Status | Should -Be 'failed'
                $Outcome.Result.Code | Should -BeIn @('Network', 'Unsupported')
                (Test-WtExternalToolTaskBusy -Task $Task) | Should -BeFalse
                $Task.Handle | Should -BeNullOrEmpty -Because 'the next action can start a new task'
                (Test-Path -LiteralPath (Get-WtExternalToolProvenancePath)) | Should -BeFalse
            }
            finally
            {
                Close-WtExternalToolTask -Task $Task
            }
        }
    }

    It 'refuses a second task while one is running and reports what a stop targets' {
        InModuleScope WindowsTweaker {
            $Task = New-WtExternalToolTask
            try
            {
                $Task.Handle = [pscustomobject]@{ IsCompleted = $false }
                $Task.Progress.Phase = 'downloading'
                $Task.Progress.Received = [long]2048

                $Start = Start-WtExternalToolTask -Task $Task -Spec (New-WtTestSpec) -Mode 'download'
                $Start.Started | Should -BeFalse
                $Start.Reason | Should -Be 'AlreadyRunning'

                $Stop = Stop-WtExternalToolTask -Task $Task
                $Stop.Busy | Should -BeTrue
                $Stop.Phase | Should -Be 'downloading'
                $Task.Cancel.Requested | Should -BeTrue
            }
            finally
            {
                Close-WtExternalToolTask -Task $Task
            }
        }
    }

    It 'never paints from the runspace: the workspace owns the terminal' {
        $Source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/WindowsTweaker/Private/Tui/ExternalToolTask.ps1') -Raw

        foreach ($Pattern in 'Set-WtScreenText', 'Set-WtScreenIconText', 'Write-WtScreen', 'Add-WtScreenBox', 'Show-WtTuiMessage', 'Show-WtTuiDialog', 'Write-Host', '\[Console\]')
        {
            $Source | Should -Not -Match $Pattern -Because "the background task must not write to the terminal ($Pattern)"
        }

        # It is a runspace task, and it is the only place that starts one for this feature.
        $Source | Should -Match 'Runspace'
    }
}

Describe 'Dry run and WhatIf refusal' {

    BeforeEach { Clear-WtToolRoot }

    It 'refuses a download under -WhatIf without touching the network or the disk' {
        InModuleScope WindowsTweaker {
            Mock Test-WtExternalToolSupported { $true }
            Mock Save-WtExternalToolDownload { throw 'nothing may be fetched in a dry run' }

            $Result = Invoke-WtExternalToolDownload -Spec (New-WtTestSpec) -WhatIf

            $Result.Status | Should -Be 'dryrun'
            $Result.Code | Should -Be 'Preview'
            $Result.Plan.Url | Should -Be (New-WtTestSpec).DownloadUrl
            $Result.Plan.Bytes | Should -BeGreaterThan 0
            Should -Invoke Save-WtExternalToolDownload -Times 0 -Exactly
            Test-Path -LiteralPath (Get-WtExternalToolStagingRoot) | Should -BeFalse
        }
    }

    It 'refuses an activation under -WhatIf and still reports the exact command line' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            New-WtTestInstalledCopy
            Mock Test-WtExternalToolSupported { $true }
            Mock Invoke-WtExternalToolProcess { throw 'nothing may be started in a dry run' }

            $Result = Start-WtWindowsActivation -Spec (Get-WtExternalToolSpec) -Method 'HWID' -WhatIf

            $Result.Status | Should -Be 'refused'
            $Result.Code | Should -Be 'DryRun'
            $Result.Plan.Ok | Should -BeTrue
            $Result.Plan.CommandLine | Should -Match '/c'
            $Result.Plan.CommandLine | Should -Match '/HWID /HWID-NoEditionChange'
            Should -Invoke Invoke-WtExternalToolProcess -Times 0 -Exactly
            (Test-WtExternalToolLaunching) | Should -BeFalse -Because 'the guard is not left set by a refusal'
            (Test-Path -LiteralPath (Get-WtWindowsActivationRecordPath)) | Should -BeFalse -Because 'a refusal starts nothing that could still be running'
        }
    }

    It 'refuses an activation with no method selected before anything is planned' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            New-WtTestInstalledCopy
            Mock Test-WtExternalToolSupported { $true }
            Mock Invoke-WtExternalToolProcess { throw 'nothing may be started' }

            $Result = Start-WtWindowsActivation -Spec (Get-WtExternalToolSpec)

            $Result.Status | Should -Be 'refused'
            $Result.Code | Should -Be 'NoMethod'
            $Result.Plan | Should -BeNullOrEmpty
            Should -Invoke Invoke-WtExternalToolProcess -Times 0 -Exactly
        }
    }

    It 'lists the files a removal would delete without deleting anything' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            New-WtTestInstalledCopy
            $Spec = Get-WtExternalToolSpec

            $Preview = Remove-WtExternalToolFiles -Spec $Spec -WhatIf

            $Preview.Status | Should -Be 'dryrun'
            @($Preview.WouldRemove).Count | Should -Be 2
            @($Preview.WouldRemove) | Should -Contain (Get-WtExternalToolEntryPointPath -Spec $Spec)
            Test-Path -LiteralPath (Get-WtExternalToolEntryPointPath -Spec $Spec) | Should -BeTrue
            Test-Path -LiteralPath (Get-WtExternalToolProvenancePath) | Should -BeTrue
        }
    }

    It 'lists only the files that exist' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            @(Get-WtExternalToolRemovableFiles -Spec (Get-WtExternalToolSpec)).Count | Should -Be 0

            New-WtTestInstalledCopy
            @(Get-WtExternalToolRemovableFiles -Spec (Get-WtExternalToolSpec)).Count | Should -Be 2
        }
    }
}

Describe 'Provenance and local state' {

    It 'reports a missing copy without touching the network' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            $State = Get-WtExternalToolState -Spec (Get-WtExternalToolSpec)
            $State.Status | Should -Be 'Missing'
            $State.Installed | Should -BeFalse
            $State.Ready | Should -BeFalse
            $State.Pin.Commit | Should -Be (Get-WtExternalToolSpec).Commit
        }
    }

    It 'treats an unreadable provenance record as untrusted and falls back to the shipped pin' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            $Spec = New-WtTestSpec
            New-WtDirectory -Path (Get-WtExternalToolRoot)
            [System.IO.File]::WriteAllText((Get-WtExternalToolProvenancePath), '{ not json')
            [System.IO.File]::WriteAllBytes((Get-WtExternalToolEntryPointPath -Spec $Spec), [System.Text.Encoding]::UTF8.GetBytes($Spec.Content))

            $State = Get-WtExternalToolState -Spec $Spec
            $State.ProvenanceProblem | Should -Not -BeNullOrEmpty
            $State.ProvenanceSource | Should -Be 'shipped'
            $State.Ready | Should -BeTrue -Because 'the bytes match the pin the caller passed'
        }
    }

    It 'verifies against the pin recorded when a user updated the tool' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            $Spec = New-WtTestSpec
            $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Spec.Content)
            New-WtDirectory -Path (Get-WtExternalToolRoot)
            [System.IO.File]::WriteAllBytes((Get-WtExternalToolEntryPointPath -Spec $Spec), $Bytes)

            $Record = [ordered]@{
                schema       = 'windows-tweaker.external-tool/1'
                toolId       = 'microsoft-activation-scripts'
                repository   = 'https://github.com/massgravel/Microsoft-Activation-Scripts'
                tag          = '9.99'
                commit       = 'ffffffffffffffffffffffffffffffffffffffff'
                fileName     = $Spec.FileName
                downloadUrl  = $Spec.DownloadUrl
                bytes        = $Bytes.Length
                sha256       = $Spec.Sha256
                gitBlobSha1  = $Spec.GitBlobSha1
                pinSource    = 'user-update'
                downloadedUtc = '2026-01-01T00:00:00.0000000Z'
            }
            $null = Write-WtAtomicFile -Path (Get-WtExternalToolProvenancePath) -Value (ConvertTo-WtJson -InputObject $Record -Depth 6)

            $State = Get-WtExternalToolState -Spec $Spec
            $State.Ready | Should -BeTrue
            $State.Pin.Tag | Should -Be '9.99'
            $State.Pin.PinSource | Should -Be 'user-update'
            $State.ProvenanceSource | Should -Be 'file'
        }
    }

    It 'flags a copy whose bytes no longer match its pin' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            $Spec = New-WtTestSpec
            New-WtDirectory -Path (Get-WtExternalToolRoot)
            $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Spec.Content)
            [System.IO.File]::WriteAllBytes((Get-WtExternalToolEntryPointPath -Spec $Spec), $Bytes)
            $Stream = [System.IO.File]::Open((Get-WtExternalToolEntryPointPath -Spec $Spec), [System.IO.FileMode]::Append)
            try { $Stream.WriteByte([byte]0x41) } finally { $Stream.Dispose() }

            $State = Get-WtExternalToolState -Spec $Spec
            $State.Status | Should -Be 'Mismatch'
            $State.Ready | Should -BeFalse
            $State.Reason | Should -Not -BeNullOrEmpty
        }
    }

    It 'removes only the files this feature created' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            $Spec = New-WtTestSpec
            New-WtDirectory -Path (Get-WtExternalToolRoot)
            New-WtDirectory -Path (Get-WtExternalToolStagingRoot)
            [System.IO.File]::WriteAllBytes((Get-WtExternalToolEntryPointPath -Spec $Spec), [System.Text.Encoding]::UTF8.GetBytes($Spec.Content))
            [System.IO.File]::WriteAllText((Get-WtExternalToolProvenancePath), '{}')
            $Leftover = Join-Path (Get-WtExternalToolStagingRoot) 'MAS_AIO.cmd.abc.part'
            [System.IO.File]::WriteAllText($Leftover, 'partial')
            $Foreign = Join-Path (Get-WtExternalToolRoot) 'user-note.txt'
            [System.IO.File]::WriteAllText($Foreign, 'not ours')

            $Result = Remove-WtExternalToolFiles -Spec $Spec

            $Result.Status | Should -Be 'succeeded'
            @($Result.Removed).Count | Should -Be 3
            Test-Path -LiteralPath (Get-WtExternalToolEntryPointPath -Spec $Spec) | Should -BeFalse
            Test-Path -LiteralPath (Get-WtExternalToolProvenancePath) | Should -BeFalse
            Test-Path -LiteralPath $Leftover | Should -BeFalse
            Test-Path -LiteralPath $Foreign | Should -BeTrue -Because 'a file this feature did not create is never deleted'
            Test-Path -LiteralPath (Get-WtExternalToolRoot) | Should -BeTrue

            Remove-Item -LiteralPath $Foreign -Force -ErrorAction Ignore
        }
    }
}

Describe 'Activation methods, launch plan and operation lifetime' {

    BeforeEach { Clear-WtToolRoot }

    It 'offers only the Windows-only methods the pinned revision implements' {
        InModuleScope WindowsTweaker {
            $Methods = @(Get-WtWindowsActivationMethod)
            @($Methods | ForEach-Object { $_.Id }) | Should -Be @('HWID', 'TSforge', 'OnlineKMS')

            foreach ($Method in $Methods)
            {
                [string]$Method.Switch | Should -BeIn @('/HWID', '/Z-Windows', '/K-Windows')
                [string]$Method.DurationModel | Should -BeIn @('Permanent', 'TimeLimited')
                [string]$Method.Evidence | Should -Match 'MAS_AIO\.cmd'
            }

            # The duration models are the upstream ones: Online KMS is the time-limited method.
            (Get-WtWindowsActivationMethod -Id 'HWID').DurationModel | Should -Be 'Permanent'
            (Get-WtWindowsActivationMethod -Id 'OnlineKMS').DurationModel | Should -Be 'TimeLimited'

            # The switches that forbid an edition change travel with the methods that can cause one.
            @((Get-WtWindowsActivationMethod -Id 'HWID').ExtraSwitches) | Should -Be @('/HWID-NoEditionChange')
            @((Get-WtWindowsActivationMethod -Id 'OnlineKMS').ExtraSwitches) | Should -Be @('/K-NoEditionChange')
            @((Get-WtWindowsActivationMethod -Id 'TSforge').ExtraSwitches).Count | Should -Be 0

            # Nothing outside the table is reachable, including the Office/ESU/edition-change ones.
            # An empty id returns the whole table (which the plan and the action refuse); an unknown
            # id returns nothing.
            @(Get-WtWindowsActivationMethod -Id '').Count | Should -Be 3
            foreach ($Unknown in 'Ohook', '/Ohook', 'KMS38', 'Z-ESU', 'ChangeEdition', '/S')
            {
                (Get-WtWindowsActivationMethod -Id $Unknown) | Should -BeNullOrEmpty
            }
        }
    }

    It 'composes the command line from the selected method switches and nothing else' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            $Spec = New-WtTestSpec
            New-WtDirectory -Path (Get-WtExternalToolRoot)
            $Path = Get-WtExternalToolEntryPointPath -Spec $Spec
            [System.IO.File]::WriteAllBytes($Path, [System.Text.Encoding]::UTF8.GetBytes($Spec.Content))

            $Plan = Get-WtExternalToolLaunchPlan -Spec $Spec -Interpreter '/bin/sh' -Elevated $false -Method 'HWID'

            $Plan.Ok | Should -BeTrue
            $Plan.MethodId | Should -Be 'HWID'
            $Plan.FilePath | Should -Be '/bin/sh'
            @($Plan.ArgumentList) | Should -Be @('/c', ('"{0}"' -f $Path), '/HWID', '/HWID-NoEditionChange')
            $Plan.WorkingDirectory | Should -Be (Get-WtExternalToolRoot)
            $Plan.CommandLine | Should -Match '/HWID /HWID-NoEditionChange$'

            # The switches of a method are the table's, never a caller's string.
            $Online = Get-WtExternalToolLaunchPlan -Spec $Spec -Interpreter '/bin/sh' -Elevated $false -Method 'OnlineKMS'
            @($Online.ArgumentList) | Should -Be @('/c', ('"{0}"' -f $Path), '/K-Windows', '/K-NoEditionChange')

            # Office, ESU, KMS-host and reset switches are not in this feature at all.
            ($Plan.ArgumentList -join ' ') | Should -Not -Match '(?i)ohook|/z-esu|/z-off|/z-reset|/ipk|/skms|/rearm|/ato|/s\b'
        }
    }

    It 'refuses a plan without a method, and one whose method object carries an unknown id' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            $Spec = New-WtTestSpec
            New-WtDirectory -Path (Get-WtExternalToolRoot)
            [System.IO.File]::WriteAllBytes((Get-WtExternalToolEntryPointPath -Spec $Spec), [System.Text.Encoding]::UTF8.GetBytes($Spec.Content))

            $NoMethod = Get-WtExternalToolLaunchPlan -Spec $Spec -Interpreter '/bin/sh'
            $NoMethod.Ok | Should -BeFalse
            $NoMethod.Reason | Should -Match 'No Windows activation method'
            @($NoMethod.ArgumentList).Count | Should -Be 0

            $Forged = Get-WtExternalToolLaunchPlan -Spec $Spec -Interpreter '/bin/sh' -Method @{ Id = 'Ohook' }
            $Forged.Ok | Should -BeFalse
            $Forged.Reason | Should -Match 'No Windows activation method'
        }
    }

    It 'refuses a path outside its own directory, another file name, or an unsafe character' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            $Spec = New-WtTestSpec
            New-WtDirectory -Path (Get-WtExternalToolRoot)
            $Path = Get-WtExternalToolEntryPointPath -Spec $Spec
            [System.IO.File]::WriteAllBytes($Path, [System.Text.Encoding]::UTF8.GetBytes($Spec.Content))

            $Outside = Join-Path $env:WT_DATA_ROOT 'MAS_AIO.cmd'
            [System.IO.File]::WriteAllText($Outside, 'x')
            (Get-WtExternalToolLaunchPlan -Spec $Spec -ToolPath $Outside -Method 'HWID').Ok | Should -BeFalse
            (Get-WtExternalToolLaunchPlan -Spec $Spec -ToolPath $Outside -Method 'HWID').Reason | Should -Match 'not inside'

            $Renamed = Join-Path (Get-WtExternalToolRoot) 'other.cmd'
            [System.IO.File]::WriteAllText($Renamed, 'x')
            (Get-WtExternalToolLaunchPlan -Spec $Spec -ToolPath $Renamed -Method 'HWID').Ok | Should -BeFalse
            (Get-WtExternalToolLaunchPlan -Spec $Spec -ToolPath $Renamed -Method 'HWID').Reason | Should -Match 'pinned entry point'

            (Get-WtExternalToolLaunchPlan -Spec $Spec -ToolPath (Join-Path (Get-WtExternalToolRoot) 'missing.cmd') -Method 'HWID').Ok | Should -BeFalse

            # A percent sign is expanded by the command interpreter even inside double quotes.
            $Expando = Join-Path (Get-WtExternalToolRoot) '%TEMP%.cmd'
            [System.IO.File]::WriteAllText($Expando, 'x')
            (Get-WtExternalToolLaunchPlan -Spec $Spec -ToolPath $Expando -Method 'HWID').Ok | Should -BeFalse
        }
    }

    It 'maps a refused elevation prompt to a cancellation and starts nothing else' {
        InModuleScope WindowsTweaker {
            Mock Start-Process { throw [System.ComponentModel.Win32Exception]::new(1223) }

            $Result = Invoke-WtExternalToolProcess -FilePath 'cmd.exe' -ArgumentList @('/c', '"x"') -Elevate $true

            $Result.Started | Should -BeFalse
            $Result.Cancelled | Should -BeTrue
            $Result.Reason | Should -Match 'elevation prompt'
            Should -Invoke Start-Process -Times 1 -Exactly
        }
    }

    It 'reads the process table only on Windows' {
        InModuleScope WindowsTweaker {
            if (Test-WtIsWindows)
            {
                # A live Windows table always contains this process.
                @(Get-WtExternalToolProcessTable | ForEach-Object { $_.ProcessId }) | Should -Contain $PID
            }
            else
            {
                # No table means "completion unknown", never "nothing is running".
                (Get-WtExternalToolProcessTable) | Should -BeNullOrEmpty
            }
        }
    }

    It 'follows a detached grandchild whose parent already left the process table' {
        InModuleScope WindowsTweaker {
            $Start = [datetime]::UtcNow.AddMinutes(-1)

            # First poll: the launcher, the interpreter it spawned and the elevated console it left
            # behind. Later polls: the launcher and the interpreter are gone, the console is not.
            $script:Polls = 0
            $Table = {
                $script:Polls++
                if ($script:Polls -le 1)
                {
                    return @(
                        [pscustomobject]@{ ProcessId = 100; ParentProcessId = 0; StartUtc = $Start },
                        [pscustomobject]@{ ProcessId = 200; ParentProcessId = 100; StartUtc = $Start },
                        [pscustomobject]@{ ProcessId = 300; ParentProcessId = 200; StartUtc = $Start }
                    )
                }

                return @([pscustomobject]@{ ProcessId = 300; ParentProcessId = 200; StartUtc = $Start })
            }.GetNewClosure()

            $Wait = Wait-WtWindowsActivationCompletion -RootProcessId 100 -RootStartUtc $Start -TimeoutSeconds 1 -NoSleep -TableSource $Table

            # This is the observed bug: the launcher exited, the console it left behind did not.
            $Wait.Completion | Should -Be 'Timeout' -Because 'a launcher that exited is not the end of the operation'
            $Wait.Completion | Should -Not -Be 'Completed'
            $Wait.Remaining | Should -Be 1
            @($Wait.Members) | Should -Contain 300
        }
    }

    It 'reports completion once the whole tree has ended' {
        InModuleScope WindowsTweaker {
            $Start = [datetime]::UtcNow.AddMinutes(-1)

            $script:Polls = 0
            $Table = {
                $script:Polls++
                if ($script:Polls -le 1)
                {
                    return @(
                        [pscustomobject]@{ ProcessId = 100; ParentProcessId = 0; StartUtc = $Start },
                        [pscustomobject]@{ ProcessId = 200; ParentProcessId = 100; StartUtc = $Start }
                    )
                }

                # A live but unrelated process keeps the table non-empty; it is not a member of the
                # operation's tree, and the tree itself is gone.
                return @([pscustomobject]@{ ProcessId = 999; ParentProcessId = 0; StartUtc = $Start })
            }.GetNewClosure()

            $Wait = Wait-WtWindowsActivationCompletion -RootProcessId 100 -RootStartUtc $Start -TimeoutSeconds 5 -NoSleep -TableSource $Table

            $Wait.Completion | Should -Be 'Completed'
            $Wait.Remaining | Should -Be 0
            $Wait.Elapsed | Should -BeFalse
        }
    }

    It 'reports completion unknown when the process table cannot be read at all' {
        InModuleScope WindowsTweaker {
            $Wait = Wait-WtWindowsActivationCompletion -RootProcessId 100 -TimeoutSeconds 5 -NoSleep -TableSource { $null }

            $Wait.Completion | Should -Be 'Unknown'
            $Wait.Reason | Should -Match 'process table'
            $Wait.ExitCode | Should -BeNullOrEmpty
        }
    }

    It 'ignores a recycled process id that predates the operation' {
        InModuleScope WindowsTweaker {
            $Root = [datetime]::UtcNow.AddMinutes(-5)

            # A pid the tree once used, held by an unrelated process that started before the
            # operation did: it must not keep the operation "alive" for ever.
            $Table = {
                return @([pscustomobject]@{ ProcessId = 200; ParentProcessId = 100; StartUtc = $Root.AddMinutes(-25) })
            }.GetNewClosure()

            $Wait = Wait-WtWindowsActivationCompletion -RootProcessId 100 -RootStartUtc $Root -TimeoutSeconds 5 -NoSleep -TableSource $Table

            $Wait.Completion | Should -Be 'Completed'
            $Wait.Remaining | Should -Be 0
        }
    }
}

Describe 'Activation action and duplicate guard' {

    BeforeEach { Clear-WtToolRoot }

    It 'runs the verified copy with the selected method switches and reports the observed exit code' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            New-WtTestInstalledCopy
            Mock Test-WtExternalToolSupported { $true }

            $script:Capture = $null
            Mock Invoke-WtExternalToolProcess {
                param ($FilePath, $ArgumentList, $WorkingDirectory, $Elevate)
                $script:Capture = @{ FilePath = $FilePath; ArgumentList = $ArgumentList; WorkingDirectory = $WorkingDirectory; Elevate = $Elevate }
                return [ordered]@{ Started = $true; Cancelled = $false; Reason = ''; Process = $null; ProcessId = 4242 }
            }
            Mock Wait-WtWindowsActivationCompletion {
                return [ordered]@{ Completion = 'Completed'; ExitCode = 7; Remaining = 0; Members = @(); Reason = ''; ObservedSeconds = 2; Elapsed = $false }
            }

            $Result = Start-WtWindowsActivation -Spec (Get-WtExternalToolSpec) -Method 'HWID' -Interpreter '/bin/sh' -Elevated $false

            $Result.Status | Should -Be 'succeeded'
            $Result.Code | Should -Be 'Completed'
            $Result.ExitCode | Should -Be 7
            $Result.CompletionDetermined | Should -BeTrue
            $Result.Method.Id | Should -Be 'HWID'
            $script:Capture.FilePath | Should -Be '/bin/sh'
            $script:Capture.Elevate | Should -BeFalse
            @($script:Capture.ArgumentList) | Should -Be @('/c', ('"{0}"' -f (Get-WtExternalToolEntryPointPath -Spec (Get-WtExternalToolSpec))), '/HWID', '/HWID-NoEditionChange')
            Should -Invoke Wait-WtWindowsActivationCompletion -Times 1 -Exactly

            # A determined completion releases the record: nothing is left claiming an open operation.
            (Test-Path -LiteralPath (Get-WtWindowsActivationRecordPath)) | Should -BeFalse
            (Test-WtExternalToolLaunching) | Should -BeFalse
        }
    }

    It 'asks for an explicit elevation handoff when the session is not elevated' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            New-WtTestInstalledCopy
            Mock Test-WtExternalToolSupported { $true }

            $script:Elevated = $null
            Mock Invoke-WtExternalToolProcess {
                param ($FilePath, $ArgumentList, $WorkingDirectory, $Elevate)
                $script:Elevated = $Elevate
                return [ordered]@{ Started = $true; Cancelled = $false; Reason = ''; Process = $null; ProcessId = 99 }
            }
            Mock Wait-WtWindowsActivationCompletion { return [ordered]@{ Completion = 'Completed'; ExitCode = 0; Remaining = 0; Members = @(); Reason = '' } }

            $null = Start-WtWindowsActivation -Spec (Get-WtExternalToolSpec) -Method 'TSforge' -Interpreter '/bin/sh' -Elevated $true
            $script:Elevated | Should -BeTrue

            $null = Start-WtWindowsActivation -Spec (Get-WtExternalToolSpec) -Method 'TSforge' -Interpreter '/bin/sh' -Elevated $false
            $script:Elevated | Should -BeFalse
        }
    }

    It 'reports a launch failure without retrying' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            New-WtTestInstalledCopy
            Mock Test-WtExternalToolSupported { $true }
            Mock Invoke-WtExternalToolProcess { return [ordered]@{ Started = $false; Cancelled = $false; Reason = 'cannot start'; Process = $null; ProcessId = 0 } }
            Mock Wait-WtWindowsActivationCompletion { throw 'the wait must not run when nothing started' }

            $Result = Start-WtWindowsActivation -Spec (Get-WtExternalToolSpec) -Method 'HWID' -Interpreter '/bin/sh' -Elevated $false

            $Result.Status | Should -Be 'failed'
            $Result.Code | Should -Be 'LaunchFailed'
            Should -Invoke Invoke-WtExternalToolProcess -Times 1 -Exactly
            Should -Invoke Wait-WtWindowsActivationCompletion -Times 0 -Exactly
            (Test-Path -LiteralPath (Get-WtWindowsActivationRecordPath)) | Should -BeFalse
        }
    }

    It 'starts nothing when the elevation prompt is refused' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            New-WtTestInstalledCopy
            Mock Test-WtExternalToolSupported { $true }
            Mock Invoke-WtExternalToolProcess { return [ordered]@{ Started = $false; Cancelled = $true; Reason = 'refused'; Process = $null; ProcessId = 0 } }
            Mock Wait-WtWindowsActivationCompletion { throw 'nothing may be waited for' }

            $Result = Start-WtWindowsActivation -Spec (Get-WtExternalToolSpec) -Method 'HWID' -Interpreter '/bin/sh' -Elevated $false

            $Result.Status | Should -Be 'cancelled'
            $Result.Code | Should -Be 'UacCancelled'
            $Result.Started | Should -BeFalse
            (Test-Path -LiteralPath (Get-WtWindowsActivationRecordPath)) | Should -BeFalse
        }
    }

    It 'refuses to run a copy that is not verified' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            Mock Test-WtExternalToolSupported { $true }
            Mock Invoke-WtExternalToolProcess { throw 'nothing may be started' }

            $Result = Start-WtWindowsActivation -Spec (Get-WtExternalToolSpec) -Method 'HWID' -Interpreter '/bin/sh' -Elevated $false

            $Result.Status | Should -Be 'refused'
            $Result.Code | Should -Be 'NotDownloaded'
            Should -Invoke Invoke-WtExternalToolProcess -Times 0 -Exactly
        }
    }

    It 'never starts a second activation while one is in progress in this session' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            New-WtTestInstalledCopy
            Mock Test-WtExternalToolSupported { $true }

            $script:Inner = $null
            $script:Calls = 0
            Mock Invoke-WtExternalToolProcess {
                $script:Calls++
                # While this activation is running, a second one is attempted.
                $script:Inner = Start-WtWindowsActivation -Spec (Get-WtExternalToolSpec) -Method 'HWID' -Interpreter '/bin/sh' -Elevated $false
                return [ordered]@{ Started = $true; Cancelled = $false; Reason = ''; Process = $null; ProcessId = 1234 }
            }
            Mock Wait-WtWindowsActivationCompletion { return [ordered]@{ Completion = 'Completed'; ExitCode = 0; Remaining = 0; Members = @(); Reason = '' } }

            $First = Start-WtWindowsActivation -Spec (Get-WtExternalToolSpec) -Method 'HWID' -Interpreter '/bin/sh' -Elevated $false

            $First.Status | Should -Be 'succeeded'
            $script:Inner.Status | Should -Be 'refused'
            $script:Inner.Code | Should -Be 'AlreadyLaunched'
            $script:Calls | Should -Be 1 -Because 'the nested attempt must not reach the process seam'
            (Test-WtExternalToolLaunching) | Should -BeFalse -Because 'the guard is released when the activation returns'
        }
    }

    It 'keeps the record and reports completion unknown when the lifetime cannot be observed' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            New-WtTestInstalledCopy
            Mock Test-WtExternalToolSupported { $true }
            Mock Invoke-WtExternalToolProcess { return [ordered]@{ Started = $true; Cancelled = $false; Reason = ''; Process = $null; ProcessId = 777 } }
            Mock Wait-WtWindowsActivationCompletion {
                return [ordered]@{ Completion = 'Unknown'; ExitCode = $null; Remaining = 1; Members = @(777, 778); Reason = 'the process table could not be read'; ObservedSeconds = 3; Elapsed = $false }
            }

            $Result = Start-WtWindowsActivation -Spec (Get-WtExternalToolSpec) -Method 'OnlineKMS' -Interpreter '/bin/sh' -Elevated $false

            $Result.Status | Should -Be 'unknown'
            $Result.Code | Should -Be 'CompletionUnknown'
            $Result.CompletionDetermined | Should -BeFalse
            $Result.ExitCode | Should -BeNullOrEmpty

            $Record = Read-WtWindowsActivationRecord
            $Record | Should -Not -BeNullOrEmpty
            [string](Get-WtExternalToolJsonProperty -Document $Record -Name 'completion') | Should -Be 'unknown'
            @((Get-WtExternalToolJsonProperty -Document $Record -Name 'observedPids')) | Should -Contain 778
        }
    }

    It 'refuses a new activation while a recorded operation is still alive' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            New-WtTestInstalledCopy
            Mock Test-WtExternalToolSupported { $true }
            Mock Invoke-WtExternalToolProcess { throw 'nothing may be started while an operation is open' }

            # The record names this very process, so the tree is alive by construction.
            Write-WtWindowsActivationRecord -Record ([ordered]@{
                    schema       = 'windows-tweaker.activation-operation/1'
                    method       = 'HWID'
                    launchedUtc  = [datetime]::UtcNow.ToString('o')
                    rootPid      = $PID
                    rootStartUtc = ''
                    completion   = 'running'
                    exitCode     = $null
                    observedPids = @()
                })

            $Table = { return @([pscustomobject]@{ ProcessId = $PID; ParentProcessId = 0; StartUtc = [datetime]::MinValue }) }.GetNewClosure()

            $Result = Start-WtWindowsActivation -Spec (Get-WtExternalToolSpec) -Method 'HWID' -Interpreter '/bin/sh' -Elevated $false -TableSource $Table

            $Result.Status | Should -Be 'refused'
            $Result.Code | Should -Be 'OperationActive'
            Should -Invoke Invoke-WtExternalToolProcess -Times 0 -Exactly
        }
    }

    It 'releases the guard once the recorded tree is gone' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            New-WtTestInstalledCopy
            Mock Test-WtExternalToolSupported { $true }
            Mock Invoke-WtExternalToolProcess { return [ordered]@{ Started = $true; Cancelled = $false; Reason = ''; Process = $null; ProcessId = 5000 } }
            Mock Wait-WtWindowsActivationCompletion { return [ordered]@{ Completion = 'Completed'; ExitCode = 0; Remaining = 0; Members = @(); Reason = '' } }

            Write-WtWindowsActivationRecord -Record ([ordered]@{
                    schema       = 'windows-tweaker.activation-operation/1'
                    method       = 'HWID'
                    launchedUtc  = [datetime]::UtcNow.AddMinutes(-30).ToString('o')
                    rootPid      = 4242
                    rootStartUtc = ([datetime]::UtcNow.AddMinutes(-30)).ToString('o')
                    completion   = 'running'
                    exitCode     = $null
                    observedPids = @()
                })

            $Result = Start-WtWindowsActivation -Spec (Get-WtExternalToolSpec) -Method 'HWID' -Interpreter '/bin/sh' -Elevated $false -TableSource { @([pscustomobject]@{ ProcessId = 1; ParentProcessId = 0; StartUtc = [datetime]::UtcNow }) }

            $Result.Status | Should -Be 'succeeded'
            Should -Invoke Invoke-WtExternalToolProcess -Times 1 -Exactly
        }
    }
}

Describe 'Documentation action' {

    It 'opens only the pinned documentation URL, on its own host' {
        InModuleScope WindowsTweaker {
            (Assert-WtExternalToolDocumentationUrl -Url (Get-WtExternalToolSpec).DocumentationUrl).Host | Should -Be 'massgrave.dev'
            { Assert-WtExternalToolDocumentationUrl -Url 'https://github.com/massgravel/Microsoft-Activation-Scripts' } | Should -Throw -ExpectedMessage '*not allowed*'
            { Assert-WtExternalToolDocumentationUrl -Url 'http://massgrave.dev/' } | Should -Throw -ExpectedMessage '*non-HTTPS*'
            { Assert-WtExternalToolDocumentationUrl -Url 'not a url' } | Should -Throw -ExpectedMessage '*malformed*'
        }
    }

    It 'never opens a browser for a URL the pin does not allow' {
        InModuleScope WindowsTweaker {
            Mock Start-Process { throw 'no process may be started' }

            $Spec = Get-WtExternalToolSpec
            $Spec.DocumentationUrl = 'https://example.invalid/docs'
            $Result = Open-WtExternalToolDocumentation -Spec $Spec

            $Result.Status | Should -Be 'failed'
            Should -Invoke Start-Process -Times 0 -Exactly
        }
    }

    It 'reports the platform instead of opening a browser off Windows' {
        InModuleScope WindowsTweaker {
            Mock Start-Process { throw 'no process may be started' }

            $Result = Open-WtExternalToolDocumentation -Spec (Get-WtExternalToolSpec)

            $Result.Status | Should -Be 'unsupported'
            Should -Invoke Start-Process -Times 0 -Exactly
        }
    }
}

Describe 'Interface view' {

    BeforeEach { Clear-WtToolRoot }

    It 'shows the source, the pin, the local status and every action' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Width 100 -Height 30
            Initialize-WtTuiState -State $State
            $State.Licensing = Read-WtLicensingDiagnostics
            $State.ExternalTool = Get-WtExternalToolState -Spec (Get-WtExternalToolSpec)
            $State.ForceRepaint = $true

            Update-WtTuiView -State $State
            $Text = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"

            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Mas.Title')))
            $Text | Should -Match 'github\.com/massgravel/Microsoft-Activation-Scripts'
            $Text | Should -Match ([regex]::Escape((Get-WtExternalToolSpec).Commit))
            $Text | Should -Match 'GPL-3\.0'
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Mas.Action.RequestActivation')))
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Mas.Action.Download')))
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Mas.Action.Remove')))
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Mas.Action.Docs')))
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Mas.Section.Methods')))
            $Text | Should -Match '850f979665fb93999acae93f4790c1ff8ed2041532060b7966a121c2d29a0bfa'

            # The warning that activation is not entitlement is on the review screen itself.
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Mas.Warning.Summary')).Substring(0, 40))

            # Nothing was downloaded, started or changed by looking at it.
            $State.Operation | Should -BeNullOrEmpty
        }
    }

    It 'replaces the main-screen hints with the workspace keys while it is active' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Width 100 -Height 30
            Initialize-WtTuiState -State $State
            $State.Licensing = Read-WtLicensingDiagnostics
            $State.ExternalTool = Get-WtExternalToolState -Spec (Get-WtExternalToolSpec)
            $State.ForceRepaint = $true
            Update-WtTuiView -State $State
            $Text = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Mas.Hint')))
            $Text | Should -Not -Match ([regex]::Escape((Get-WtString -Key 'Tui.Keys.Main')))

            # The licensing diagnostics own their own hints in the same way.
            $State.ExternalTool = $null
            $State.ForceRepaint = $true
            Update-WtTuiView -State $State
            $Diagnostics = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"
            $Diagnostics | Should -Match ([regex]::Escape((Get-WtString -Key 'Lic.Hint')))
            $State.Licensing = $null
        }
    }

    It 'renders both interface languages' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Width 100 -Height 30
            Initialize-WtTuiState -State $State
            $State.Licensing = Read-WtLicensingDiagnostics
            $State.ExternalTool = Get-WtExternalToolState -Spec (Get-WtExternalToolSpec)

            foreach ($Language in 'en', 'vi')
            {
                Set-WtLanguage -Language $Language | Out-Null
                $State.ForceRepaint = $true
                Update-WtTuiView -State $State
                $Text = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"
                $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Mas.Title' -Language $Language)))
                $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Mas.Action.RequestActivation' -Language $Language)))
                $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Mas.Section.Methods' -Language $Language)))
            }

            Set-WtLanguage -Language 'en' | Out-Null
            $State.Licensing = $null
            $State.ExternalTool = $null
        }
    }

    It 'keeps the ASCII frames and icon fallbacks readable' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Width 100 -Height 30 -Ascii
            Initialize-WtTuiState -State $State
            $State.Licensing = Read-WtLicensingDiagnostics
            $State.ExternalTool = Get-WtExternalToolState -Spec (Get-WtExternalToolSpec)
            $State.ForceRepaint = $true
            Update-WtTuiView -State $State
            $Text = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"

            $Text | Should -Match '\+.*Local copy'
            $Text | Should -Match '\[EXT\]|\[IN\]|\[GO\]|\[OUT\]|\[STOP\]|\[KEY\]|\[N/A\]|\[OFF\]'
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Mas.Action.RequestActivation')))
            $State.Licensing = $null
            $State.ExternalTool = $null
        }
    }

    It 'shows the installed edition, the status, the selected method, the tool and the two actions' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Width 100 -Height 34
            Initialize-WtTuiState -State $State
            $State.Licensing = Read-WtLicensingDiagnostics
            $State.ActivationTool = Get-WtExternalToolState -Spec (Get-WtExternalToolSpec)
            $State.ForceRepaint = $true
            Update-WtTuiView -State $State
            $Text = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"

            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Lic.Section.Activation')))
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Lic.Edition').Split('{')[0].Trim()))
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Lic.ActStatus').Split('{')[0].Trim()))
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Lic.SelectedMethod').Split('{')[0].Trim()))
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Lic.ToolStatus').Split('{')[0].Trim()))

            # The single primary action, and the settings screen that holds everything else.
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Lic.Action.Activate')))
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Lic.Action.Settings')))
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Lic.Hint')))

            # No menu launch and no other method is offered from the main screen.
            $Text | Should -Not -Match ([regex]::Escape((Get-WtString -Key 'Mas.Action.Download')))
            $State.Licensing = $null
            $State.ActivationTool = $null
        }
    }

    It 'states on the main screen that nothing is selected before a method is chosen' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Width 100 -Height 34
            Initialize-WtTuiState -State $State
            $State.Licensing = Read-WtLicensingDiagnostics
            $State.ActivationTool = Get-WtExternalToolState -Spec (Get-WtExternalToolSpec)
            $State.ForceRepaint = $true
            Update-WtTuiView -State $State
            $Text = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"

            # No method has been selected in this test's settings root.
            (Get-WtWindowsActivationMethodSetting) | Should -BeNullOrEmpty
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Lic.Method.None')))
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Lic.Outcome.None')))
            $State.Licensing = $null
            $State.ActivationTool = $null
        }
    }
}

Describe 'Workspace actions' {

    BeforeEach { Clear-WtToolRoot }

    It 'downloads nothing while the workspace is only being viewed' {
        InModuleScope WindowsTweaker {
            Mock Save-WtExternalToolDownload { throw 'no download may happen by viewing the workspace' }
            Mock Invoke-WtExternalToolProcess { throw 'nothing may start by viewing the workspace' }
            Mock Open-WtExternalToolDocumentation { throw 'no browser may open by viewing the workspace' }

            $State = New-WtTestState -Width 100 -Height 30 -Keys @(,(New-WtTestKey -Name 'Escape'))
            Initialize-WtTuiState -State $State
            $State.Licensing = Read-WtLicensingDiagnostics

            Show-WtTuiActivationSettings -State $State

            Should -Invoke Save-WtExternalToolDownload -Times 0 -Exactly
            Should -Invoke Invoke-WtExternalToolProcess -Times 0 -Exactly
            Should -Invoke Open-WtExternalToolDocumentation -Times 0 -Exactly
            $State.ExternalTool | Should -BeNullOrEmpty -Because 'leaving the view clears it'
        }
    }

    It 'downloads nothing unless the download dialog is confirmed' {
        InModuleScope WindowsTweaker {
            Mock Test-WtExternalToolSupported { $true }
            Mock Save-WtExternalToolDownload { throw 'the transport must not run' }

            # D opens the confirmation; Escape answers "no".
            $State = New-WtTestState -Width 100 -Height 30 -Keys @(
                (New-WtTestKey -Name 'Char' -Character 'd'),
                (New-WtTestKey -Name 'Escape'),
                (New-WtTestKey -Name 'Escape')
            )
            Initialize-WtTuiState -State $State
            $State.Licensing = Read-WtLicensingDiagnostics

            Show-WtTuiActivationSettings -State $State

            Should -Invoke Save-WtExternalToolDownload -Times 0 -Exactly
            Test-Path -LiteralPath (Get-WtExternalToolProvenancePath) | Should -BeFalse
        }
    }

    It 'downloads in the background after an explicit confirmation' {
        InModuleScope WindowsTweaker {
            Mock Test-WtExternalToolSupported { $true }
            $script:Started = $null
            Mock Start-WtExternalToolTask {
                param ($Task, $Spec, $Mode, $Latest, $Release, $TimeoutSeconds)
                $script:Started = @{ Mode = $Mode; HasRelease = [bool]$Release }
                return [pscustomobject]@{ Started = $true; Reason = '' }
            }
            Mock Save-WtExternalToolDownload { throw 'the transport must run in the task, not on this thread' }

            # D opens the confirmation, Y accepts it, Escape leaves the view afterwards.
            $State = New-WtTestState -Width 100 -Height 30 -Keys @(
                (New-WtTestKey -Name 'Char' -Character 'd'),
                (New-WtTestKey -Name 'Char' -Character 'y'),
                (New-WtTestKey -Name 'Escape')
            )
            Initialize-WtTuiState -State $State

            Invoke-WtExternalToolDownloadAction -State $State

            $script:Started.Mode | Should -Be 'download'
            $script:Started.HasRelease | Should -BeFalse
            Should -Invoke Start-WtExternalToolTask -Times 1 -Exactly

            # Nothing ran on the interface thread: the whole transfer belongs to the task.
            Should -Invoke Save-WtExternalToolDownload -Times 0 -Exactly
        }
    }

    It 'refuses a second download while one is running' {
        InModuleScope WindowsTweaker {
            Mock Test-WtExternalToolSupported { $true }
            Mock Start-WtExternalToolTask { return [pscustomobject]@{ Started = $true; Reason = '' } }

            $State = New-WtTestState -Width 100 -Height 30
            Initialize-WtTuiState -State $State
            $null = Get-WtTuiExternalToolTask -State $State
            $State.ExternalToolTask.Handle = [pscustomobject]@{ IsCompleted = $false }

            $script:Messages = @()
            Mock Show-WtTuiMessage {
                param ($State, $Title, $Lines, $Tone)
                $script:Messages += ($Lines -join ' ')
            }

            Invoke-WtExternalToolDownloadAction -State $State

            Should -Invoke Start-WtExternalToolTask -Times 0 -Exactly
            ($script:Messages -join ' ') | Should -Match ([regex]::Escape((Get-WtString -Key 'Mas.Busy.Download').Substring(0, 30)))
        }
    }

    It 'asks a running transfer to stop when Esc is pressed, and keeps the view open' {
        InModuleScope WindowsTweaker {
            # A script-scoped queue: the mock below runs in the module scope, so a local of this
            # block would not be visible to it.
            $script:Keys = [System.Collections.Generic.Queue[object]]::new()
            $script:Keys.Enqueue((New-WtTestKey -Name 'Escape'))
            $script:Keys.Enqueue((New-WtTestKey -Name 'Escape'))

            $script:Stops = 0
            $script:Frames = 0
            Mock Invoke-WtTuiFrame {
                param ($State, $TimeoutMs)
                $script:Frames++
                if ($script:Keys.Count -gt 0) { return (ConvertTo-WtKey -Key $script:Keys.Dequeue()) }
                $State.Exit = $true
                return $null
            }
            Mock Stop-WtExternalToolTask {
                $script:Stops++
                return [pscustomobject]@{ Busy = $true; Phase = 'downloading'; Received = 1024; Forced = $false }
            }

            $State = New-WtTestState -Width 100 -Height 30
            Initialize-WtTuiState -State $State
            $null = Get-WtTuiExternalToolTask -State $State
            $State.ExternalToolTask.Handle = [pscustomobject]@{ IsCompleted = $false }

            Show-WtTuiActivationSettings -State $State

            # Both Escape presses asked the transfer to stop (a third stop comes from closing a
            # task that is still busy), and neither of them left the view.
            $script:Frames | Should -BeGreaterOrEqual 3
            $script:Stops | Should -BeGreaterOrEqual 2
            $State.ExternalToolTask | Should -BeNullOrEmpty -Because 'the view disposes the task when it closes'
        }
    }

    It 'paints real byte counts for a running transfer and names the cancel key' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Width 100 -Height 34
            Initialize-WtTuiState -State $State
            $State.Licensing = Read-WtLicensingDiagnostics
            $State.ExternalTool = Get-WtExternalToolState -Spec (Get-WtExternalToolSpec)

            $Task = New-WtExternalToolTask
            try
            {
                $Task.Handle = [pscustomobject]@{ IsCompleted = $false }
                $Task.Progress.Phase = 'downloading'
                $Task.Progress.Received = [long]524288
                $Task.Progress.Total = [long]761964
                $Task.Progress.Percent = 68
                $Task.Progress.StartedUtc = [datetime]::UtcNow.AddSeconds(-3)
                $State.ExternalToolTask = $Task

                $State.ForceRepaint = $true
                Update-WtTuiView -State $State
                $Text = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"

                $Text | Should -Match '512\.0 KB of 744\.1 KB \(68%\)'
                $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Mas.Hint.Busy').Substring(0, 12)))
            }
            finally
            {
                Close-WtExternalToolTask -Task $Task
                $State.ExternalToolTask = $null
                $State.ExternalTool = $null
                $State.Licensing = $null
            }
        }
    }

    It 'reports the platform instead of downloading on a system that cannot run the tool' {
        InModuleScope WindowsTweaker {
            Mock Test-WtExternalToolSupported { $false }
            Mock Save-WtExternalToolDownload { throw 'the transport must not run' }

            $State = New-WtTestState -Width 100 -Height 30 -Keys @(
                (New-WtTestKey -Name 'Char' -Character 'd'),
                (New-WtTestKey -Name 'Enter'),
                (New-WtTestKey -Name 'Escape')
            )
            Initialize-WtTuiState -State $State
            $State.Licensing = Read-WtLicensingDiagnostics

            Show-WtTuiActivationSettings -State $State

            Should -Invoke Save-WtExternalToolDownload -Times 0 -Exactly
        }
    }

    It 'suspends the console around the activation, resumes it afterwards and re-reads licensing' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            New-WtTestInstalledCopy
            Mock Test-WtExternalToolSupported { $true }
            $null = Set-WtWindowsActivationMethodSetting -Id 'HWID'

            $script:Order = [System.Collections.Generic.List[string]]::new()
            Mock Suspend-WtTuiConsole { $script:Order.Add('suspend'); return @{ Suspended = $true; Vt = $false } }
            Mock Resume-WtTuiConsole { $script:Order.Add('resume') }
            Mock Invoke-WtExternalToolProcess {
                $script:Order.Add('launch')
                return [ordered]@{ Started = $true; Cancelled = $false; Reason = ''; Process = $null; ProcessId = 321 }
            }
            Mock Wait-WtWindowsActivationCompletion {
                # The operation's lifetime is observed while the child console owns the foreground.
                $script:Order.Add('wait')
                return [ordered]@{ Completion = 'Completed'; ExitCode = 3; Remaining = 0; Members = @(); Reason = '' }
            }
            $script:LicenseBefore = [ordered]@{ CollectedUtc = [datetime]::UtcNow; Inventory = [ordered]@{ Unreadable = $true; Reason = 'before'; Active = $null } }
            $script:LicenseAfter = [ordered]@{
                CollectedUtc = [datetime]::UtcNow.AddSeconds(5)
                Inventory    = [ordered]@{
                    Unreadable = $false
                    Reason     = ''
                    Active     = [pscustomobject]@{
                        ProductName       = 'Windows 11 Pro'
                        LicenseStatus     = 'Licensed'
                        LicenseStatusRaw  = 1
                        LicenseChannel    = 'Retail'
                        GraceRemaining    = $null
                        EvaluationEndDate = ''
                        PartialProductKey = ''
                    }
                }
            }
            Mock Read-WtLicensingDiagnostics { $script:LicenseAfter }

            $State = New-WtTestState -Width 100 -Height 30 -Keys @(
                (New-WtTestKey -Name 'Char' -Character 'a'),
                (New-WtTestKey -Name 'Char' -Character 'y'),
                (New-WtTestKey -Name 'Enter'),
                (New-WtTestKey -Name 'Escape')
            )
            Initialize-WtTuiState -State $State
            $State.Environment = [pscustomobject]@{ OSName = 'Windows 11 Pro'; OSBuild = 22631 }
            $State.ActivationTool = Get-WtExternalToolState -Spec (Get-WtExternalToolSpec)
            $State.Licensing = $script:LicenseBefore

            Invoke-WtWindowsActivationAction -State $State -License $script:LicenseBefore

            ($script:Order -join '->') | Should -Be 'suspend->launch->wait->resume'
            Should -Invoke Suspend-WtTuiConsole -Times 1 -Exactly
            Should -Invoke Resume-WtTuiConsole -Times 1 -Exactly
            $State.Licensing | Should -Be $script:LicenseAfter
            $State.ActivationOutcome | Should -Be (Get-WtString -Key 'Act.Outcome.Activated')
        }
    }

    It 'restores the console even when the activation backend throws' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            New-WtTestInstalledCopy
            Mock Test-WtExternalToolSupported { $true }
            $null = Set-WtWindowsActivationMethodSetting -Id 'HWID'

            Mock Suspend-WtTuiConsole { return @{ Suspended = $true; Vt = $false } }
            $script:Resumed = 0
            Mock Resume-WtTuiConsole { $script:Resumed++ }
            Mock Start-WtWindowsActivation { throw 'unexpected backend failure' }
            Mock Read-WtLicensingDiagnostics { [ordered]@{ Inventory = [ordered]@{ Unreadable = $true; Reason = 'unreadable'; Active = $null } } }

            $State = New-WtTestState -Width 100 -Height 30 -Keys @(
                (New-WtTestKey -Name 'Char' -Character 'a'),
                (New-WtTestKey -Name 'Char' -Character 'y'),
                (New-WtTestKey -Name 'Enter')
            )
            Initialize-WtTuiState -State $State
            $State.Environment = [pscustomobject]@{ OSName = 'Windows 11 Pro'; OSBuild = 22631 }
            $State.ActivationTool = Get-WtExternalToolState -Spec (Get-WtExternalToolSpec)
            $State.Licensing = [ordered]@{ Inventory = [ordered]@{ Unreadable = $false; Active = $null } }

            { Invoke-WtWindowsActivationAction -State $State -License $State.Licensing } | Should -Not -Throw
            $script:Resumed | Should -Be 1
        }
    }

    It 'marks the frame dirty when the console is resumed' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Width 80 -Height 24
            $State.Screen.Dirty = $false
            $State.ForceRepaint = $false

            Resume-WtTuiConsole -State $State -Suspended @{ Suspended = $true; Vt = $false }

            $State.Screen.Dirty | Should -BeTrue
            $State.ForceRepaint | Should -BeTrue
        }
    }

    It 'reports a finished background download without claiming anything else' {
        InModuleScope WindowsTweaker {
            New-WtTestInstalledCopy
            $script:Messages = @()
            Mock Show-WtTuiMessage { param ($State, $Title, $Lines, $Tone) $script:Messages += ($Lines -join "`n") }
            Mock Complete-WtExternalToolTask {
                return [pscustomobject]@{
                    Completed = $true
                    Error     = ''
                    Cancelled = $false
                    Result    = [ordered]@{ Status = 'succeeded'; Code = 'Downloaded'; Reason = '' }
                }
            }

            $State = New-WtTestState -Width 100 -Height 30
            Initialize-WtTuiState -State $State
            $Task = Get-WtTuiExternalToolTask -State $State
            $Task.Handle = [pscustomobject]@{ IsCompleted = $true }
            $Task.Mode = 'download'

            Update-WtExternalToolTask -State $State

            ($script:Messages -join "`n") | Should -Match ([regex]::Escape((Get-WtString -Key 'Mas.Status.Verified')))
        }
    }

    It 'reports a cancelled transfer as a cancellation, not as a failure' {
        InModuleScope WindowsTweaker {
            $script:Messages = @()
            Mock Show-WtTuiMessage { param ($State, $Title, $Lines, $Tone) $script:Messages += ($Lines -join "`n") }
            Mock Complete-WtExternalToolTask {
                return [pscustomobject]@{ Completed = $true; Error = ''; Cancelled = $true; Result = $null }
            }

            $State = New-WtTestState -Width 100 -Height 30
            Initialize-WtTuiState -State $State
            $Task = Get-WtTuiExternalToolTask -State $State
            $Task.Handle = [pscustomobject]@{ IsCompleted = $true }
            $Task.Mode = 'download'

            Update-WtExternalToolTask -State $State

            ($script:Messages -join "`n") | Should -Match ([regex]::Escape((Get-WtString -Key 'Mas.Download.Cancelled')))
        }
    }

    It 'offers the resolved release and downloads only the commit that was confirmed' {
        InModuleScope WindowsTweaker {
            $script:Started = $null
            Mock Start-WtExternalToolTask { param ($Task, $Spec, $Mode, $Latest, $Release, $TimeoutSeconds) $script:Started = $Release; return [pscustomobject]@{ Started = $true; Reason = '' } }
            Mock Confirm-WtTui { $true }
            Mock Show-WtTuiMessage { }
            Mock Update-WtExternalToolState { return [ordered]@{ Pin = [ordered]@{ Commit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' } } }
            Mock Complete-WtExternalToolTask {
                return [pscustomobject]@{
                    Completed = $true
                    Error     = ''
                    Cancelled = $false
                    Result    = [ordered]@{ Ok = $true; Tag = '9.99'; Commit = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'; Bytes = 1234; UpToDate = $false; Reason = '' }
                }
            }

            $State = New-WtTestState -Width 100 -Height 30
            Initialize-WtTuiState -State $State
            $Task = Get-WtTuiExternalToolTask -State $State
            $Task.Handle = [pscustomobject]@{ IsCompleted = $true }
            $Task.Mode = 'resolve'

            Update-WtExternalToolTask -State $State

            $script:Started.Commit | Should -Be 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
            Should -Invoke Start-WtExternalToolTask -Times 1 -Exactly
        }
    }

    It 'refuses the download, the activation and the removal in dry-run mode and states what would run' {
        InModuleScope WindowsTweaker {
            New-WtTestInstalledCopy
            Mock Test-WtExternalToolSupported { $true }
            Mock Start-WtExternalToolTask { throw 'a dry run must not start a task' }
            Mock Invoke-WtExternalToolProcess { throw 'a dry run must not start a process' }
            $script:Messages = @()
            Mock Show-WtTuiMessage { param ($State, $Title, $Lines, $Tone) $script:Messages += ($Lines -join "`n") }

            $null = Set-WtWindowsActivationMethodSetting -Id 'HWID'

            $State = New-WtTestState -Width 100 -Height 30 -DryRun
            Initialize-WtTuiState -State $State
            $State.ExternalTool = Get-WtExternalToolState -Spec (Get-WtExternalToolSpec)
            $State.ActivationTool = Get-WtExternalToolState -Spec (Get-WtExternalToolSpec)
            $State.Licensing = Read-WtLicensingDiagnostics

            Invoke-WtExternalToolDownloadAction -State $State
            Invoke-WtExternalToolDownloadAction -State $State -Latest
            Invoke-WtWindowsActivationAction -State $State -License $State.Licensing
            Invoke-WtExternalToolRemoveAction -State $State

            Should -Invoke Start-WtExternalToolTask -Times 0 -Exactly
            Should -Invoke Invoke-WtExternalToolProcess -Times 0 -Exactly

            $Text = $script:Messages -join "`n"
            $Text | Should -Match ([regex]::Escape(((Get-WtString -Key 'Mas.DryRun.Download') -split '\{0\}')[0].Trim()))
            $Text | Should -Match '/c'
            $Text | Should -Match '/HWID'
            $Text | Should -Match ([regex]::Escape(((Get-WtString -Key 'Mas.DryRun.Remove') -split '\{0\}')[0].Trim()))

            # Nothing changed on disk either, and no operation record was left behind.
            Test-Path -LiteralPath (Get-WtExternalToolEntryPointPath -Spec (Get-WtExternalToolSpec)) | Should -BeTrue
            Test-Path -LiteralPath (Get-WtExternalToolProvenancePath) | Should -BeTrue
            Test-Path -LiteralPath (Get-WtWindowsActivationRecordPath) | Should -BeFalse
        }
    }

    It 'removes the local copy from the workspace only after confirmation' {
        Clear-WtToolRoot
        InModuleScope WindowsTweaker {
            $Spec = Get-WtExternalToolSpec
            New-WtDirectory -Path (Get-WtExternalToolRoot)
            [System.IO.File]::WriteAllBytes((Get-WtExternalToolEntryPointPath -Spec $Spec), [System.Text.Encoding]::UTF8.GetBytes('x'))

            # R then Escape: the confirmation is declined.
            $State = New-WtTestState -Width 100 -Height 30 -Keys @(
                (New-WtTestKey -Name 'Char' -Character 'r'),
                (New-WtTestKey -Name 'Escape'),
                (New-WtTestKey -Name 'Escape')
            )
            Initialize-WtTuiState -State $State
            $State.Licensing = Read-WtLicensingDiagnostics

            Show-WtTuiActivationSettings -State $State

            Test-Path -LiteralPath (Get-WtExternalToolEntryPointPath -Spec $Spec) | Should -BeTrue
        }
    }
}

Describe 'Live upstream endpoints' -Skip:(-not $env:WT_EXTERNAL_TOOL_LIVE_TEST) {
    # Response headers only: the artifact is never saved and never executed here.

    It 'still serves the pinned file at the pinned commit with the pinned size' {
        InModuleScope WindowsTweaker {
            $Spec = Get-WtExternalToolSpec
            $Headers = Get-WtExternalToolContent -Url $Spec.DownloadUrl -HeadersOnly -MaxBytes $Spec.MaxBytes -TimeoutSeconds 60

            $Headers.Status | Should -Be 'succeeded'
            $Headers.ContentLength | Should -Be $Spec.Bytes
        }
    }

    It 'follows only allowed hosts when a redirect is served' {
        InModuleScope WindowsTweaker {
            $Spec = Get-WtExternalToolSpec
            $GitHubUrl = 'https://github.com/massgravel/Microsoft-Activation-Scripts/raw/{0}/README.md' -f $Spec.Commit
            $Headers = Get-WtExternalToolContent -Url $GitHubUrl -HeadersOnly -MaxBytes 1MB -TimeoutSeconds 60

            $Headers.Redirects | Should -BeGreaterThan 0
            ([uri]$Headers.FinalUri).Host | Should -BeIn (Get-WtExternalToolAllowedHosts)
        }
    }

    It 'refuses a redirect chain longer than the limit' {
        InModuleScope WindowsTweaker {
            $Spec = Get-WtExternalToolSpec
            $GitHubUrl = 'https://github.com/massgravel/Microsoft-Activation-Scripts/raw/{0}/README.md' -f $Spec.Commit

            { Get-WtExternalToolContent -Url $GitHubUrl -HeadersOnly -MaxBytes 1MB -TimeoutSeconds 60 -MaxRedirects 0 } |
                Should -Throw -ExpectedMessage '*Too many redirects*'
        }
    }
}