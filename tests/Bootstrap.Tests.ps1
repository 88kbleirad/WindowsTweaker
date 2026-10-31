# WindowsTweaker bootstrap tests.
#
# The documented `irm ... | iex` one-liner runs two files: the published launcher
# (bootstrap/bootstrap.ps1, pure ASCII, no BOM) receives the downloaded body as text, and it
# executes the full implementation (bootstrap/implementation.ps1, UTF-8 with BOM, Vietnamese
# messages) that it reads from beside itself or downloads. Both paths are exercised here, and
# they are exercised *as text* - a parse of the file says nothing about the string `iex`
# receives, which is exactly how a leading U+FEFF stayed undetected.
#
# The tests that run the text through iex/script blocks assert that no $PSScriptRoot is
# available, that the session survives a failure (nothing calls exit()), that the code is
# mirrored into $LASTEXITCODE and that no function is left behind.

BeforeAll {
    $env:WT_BOOTSTRAP_TEST_ONLY = '1'
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:BootstrapPath = Join-Path $script:RepoRoot 'bootstrap/implementation.ps1'
    $script:LauncherPath = Join-Path $script:RepoRoot 'bootstrap/bootstrap.ps1'
    $script:PublishedLauncherUrl = 'https://raw.githubusercontent.com/88kbleirad/WindowsTweaker/main/bootstrap/bootstrap.ps1'
    $script:PublishedImplementationUrl = 'https://raw.githubusercontent.com/88kbleirad/WindowsTweaker/main/bootstrap/implementation.ps1'
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-boot-{0}" -f ([guid]::NewGuid().ToString('n')))
    [System.IO.Directory]::CreateDirectory($script:TestRoot) | Out-Null
    $script:PwshPath = (Get-Command pwsh -ErrorAction Stop).Source
}

AfterAll {
    Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_BOOTSTRAP_TEST_ONLY -ErrorAction Ignore
}

Describe 'Bootstrap text execution' {

    It 'executes from downloaded text with no script-path variables and mirrors the code instead of throwing' {
        $Text = Get-Content -LiteralPath $script:BootstrapPath -Raw
        $env:WT_BOOTSTRAP_STATE_DIR = Join-Path $script:TestRoot 'state-text'
        $env:WT_BOOTSTRAP_RELEASE_URL = 'http://invalid.example/bootstrap'
        $env:WT_BOOTSTRAP_ENTRYPOINT = 'C:\nonexistent\entry.ps1'
        # The entry block runs only when WT_BOOTSTRAP_TEST_ONLY is unset; that is the path the
        # one-liner takes, so it is the path under test. A script block created from the text
        # is the same execution mode as `irm | iex` without using Invoke-Expression: no
        # $PSScriptRoot, no $PSCommandPath, nothing from the caller's working directory.
        Remove-Item Env:\WT_BOOTSTRAP_TEST_ONLY -ErrorAction Ignore
        try {
            $global:LASTEXITCODE = 0
            { & ([scriptblock]::Create($Text)) 2>$null | Out-Null } | Should -Not -Throw
            $LASTEXITCODE | Should -Be 1
        } finally {
            Remove-Item Env:\WT_BOOTSTRAP_STATE_DIR, Env:\WT_BOOTSTRAP_RELEASE_URL, Env:\WT_BOOTSTRAP_ENTRYPOINT -ErrorAction Ignore
            $env:WT_BOOTSTRAP_TEST_ONLY = '1'
        }
    }

    It 'never calls exit(): the session that piped the text in keeps running and is left clean' {
        $StateDir = Join-Path $script:TestRoot 'state-session'
        $Script = @"
# The test session sets WT_BOOTSTRAP_TEST_ONLY (it dot-sources the same file); the child
# process inherits it and would skip the entry block, which is exactly what is under test here.
Remove-Item Env:\WT_BOOTSTRAP_TEST_ONLY -ErrorAction Ignore
`$env:WT_BOOTSTRAP_STATE_DIR = '$StateDir'
`$env:WT_BOOTSTRAP_RELEASE_URL = 'http://invalid.example/bootstrap'
`$env:WT_BOOTSTRAP_ENTRYPOINT = 'C:\nonexistent\entry.ps1'
iex (Get-Content -LiteralPath '$($script:BootstrapPath)' -Raw)
'AFTER-BOOTSTRAP ' + `$LASTEXITCODE
'LEFT-OVER-FUNCTIONS ' + (@(Get-ChildItem Function:\ | Where-Object { `$_.Name -like '*WtBootstrap*' }).Count)
'STILL-HERE'
"@
        $Output = & $script:PwshPath -NoProfile -Command $Script 2>$null
        $ExitCode = $LASTEXITCODE
        $Text = $Output -join "`n"

        # exit() anywhere in the bootstrap would end this child session before these lines.
        $ExitCode | Should -Be 0
        $Text | Should -Match 'AFTER-BOOTSTRAP 1'
        $Text | Should -Match 'LEFT-OVER-FUNCTIONS 0'
        $Text | Should -Match 'STILL-HERE'
    }
}

Describe 'Published launcher and the documented one-liner' {

    It 'is pure ASCII with no UTF-8 BOM, because iex receives its text and not the file' {
        $Bytes = [System.IO.File]::ReadAllBytes($script:LauncherPath)
        $HasBom = ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)

        # A BOM here is the defect this launcher exists to remove: irm decodes it into a
        # leading U+FEFF and the parser then refuses the body's own CmdletBinding/param block.
        $HasBom | Should -BeFalse
        @($Bytes | Where-Object { $_ -gt 0x7F }).Count | Should -Be 0
    }

    It 'parses from the text the one-liner passes to iex, with no leading U+FEFF' {
        # irm decodes the response body with the declared charset; decoding the bytes here
        # reproduces exactly the string that reaches iex in the documented command.
        $Text = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($script:LauncherPath))
        [int][char]$Text[0] | Should -Not -Be 0xFEFF

        $Tokens = $null
        $Errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$Tokens, [ref]$Errors)
        @($Errors).Count | Should -Be 0
    }

    It 'removes a leading U+FEFF from the implementation, and decodes both forms to the same text' {
        . $script:LauncherPath
        $Bytes = [System.IO.File]::ReadAllBytes($script:BootstrapPath)

        # Unfixed form, as irm would hand the implementation over: the file's UTF-8 BOM
        # decodes to a leading U+FEFF, and the text does not parse.
        $AsIs = [System.Text.Encoding]::UTF8.GetString($Bytes)
        [int][char]$AsIs[0] | Should -Be 0xFEFF
        $Tokens = $null
        $Errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($AsIs, [ref]$Tokens, [ref]$Errors)
        @($Errors).Count | Should -BeGreaterThan 0
        @($Errors)[0].Message | Should -Match "Unexpected attribute 'CmdletBinding'"

        # The launcher's decode: explicit UTF-8, marker removed, text parses.
        $Decoded = Convert-WtBootstrapLauncherImplementationText -Bytes $Bytes
        [int][char]$Decoded[0] | Should -Not -Be 0xFEFF
        $Tokens = $null
        $Errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($Decoded, [ref]$Tokens, [ref]$Errors)
        @($Errors).Count | Should -Be 0

        # The same bytes without a BOM must decode to the same text, so neither the transport
        # nor the file's byte-order mark can change what is executed.
        $WithoutBom = [byte[]]$Bytes[3..($Bytes.Length - 1)]
        (Convert-WtBootstrapLauncherImplementationText -Bytes $WithoutBom) | Should -Be $Decoded
    }

    It 'refuses an implementation from another revision, and one that does not parse' {
        . $script:LauncherPath

        { Assert-WtBootstrapLauncherImplementationText -Text '$Script:WtBootstrapLauncherProtocol = 99' -Source 'fixture' } |
            Should -Throw -ExpectedMessage '*declares launcher protocol 99*'
        { Assert-WtBootstrapLauncherImplementationText -Text 'if (' -Source 'fixture' } |
            Should -Throw -ExpectedMessage '*does not parse*'
    }

    It 'pins the implementation to the documented repository and an allowed host' {
        . $script:LauncherPath

        $Script:WtBootstrapLauncherImplementationUrl |
            Should -Be 'https://raw.githubusercontent.com/88kbleirad/WindowsTweaker/main/bootstrap/implementation.ps1'
        (Get-WtBootstrapLauncherAllowedHosts) | Should -Contain 'raw.githubusercontent.com'

        # The override may only point at HTTPS on an allowed host, and it is refused before any
        # request is made (no network in this test).
        $env:WT_BOOTSTRAP_IMPLEMENTATION_URL = 'http://invalid.example/implementation.ps1'
        try {
            { Get-WtBootstrapLauncherImplementationText } | Should -Throw -ExpectedMessage '*Refusing non-HTTPS URL*'
        } finally {
            Remove-Item Env:\WT_BOOTSTRAP_IMPLEMENTATION_URL -ErrorAction Ignore
        }
    }

    It 'forwards every documented option to the implementation and emits nothing itself' {
        . $script:LauncherPath
        $StubPath = Join-Path $script:TestRoot 'stub-implementation.ps1'
        $Record = Join-Path $script:TestRoot 'stub-forward.txt'
        $Stub = @(
            # The protocol declaration is a script element: like the implementation's own, it
            # comes after the param block, because PowerShell only accepts an attribute and
            # param block at the very start of a script.
            '[CmdletBinding()]'
            'param('
            '    [Parameter(Mandatory = $false)][string]$RuntimeMode = ''auto'','
            '    [Parameter(Mandatory = $false)][string]$Language,'
            '    [Parameter(Mandatory = $false)][string]$Colour,'
            '    [Parameter(Mandatory = $false)][switch]$Ascii,'
            '    [Parameter(Mandatory = $false)][string]$WorkerBackend = ''Auto'','
            '    [Parameter(Mandatory = $false)][string]$Icons = ''Auto'','
            '    [Parameter(Mandatory = $false)][switch]$NoInstall'
            ')'
            '$Script:WtBootstrapLauncherProtocol = 1'
            '$Value = ''{0}|{1}|{2}|{3}|{4}|{5}|{6}'' -f $RuntimeMode, $Language, $Colour, [bool]$Ascii, $WorkerBackend, $Icons, [bool]$NoInstall'
            "Set-Content -LiteralPath '$Record' -Value `$Value -Encoding utf8"
            '$global:LASTEXITCODE = 0'
        ) -join "`n"
        Set-Content -LiteralPath $StubPath -Value $Stub -Encoding utf8

        $env:WT_BOOTSTRAP_IMPLEMENTATION_PATH = $StubPath
        # The test session sets WT_BOOTSTRAP_TEST_ONLY (it dot-sources both files); the child
        # would inherit it and skip the entry block, so it is removed for the child run only.
        Remove-Item Env:\WT_BOOTSTRAP_TEST_ONLY -ErrorAction Ignore
        try {
            $Output = & $script:PwshPath -NoProfile -File $script:LauncherPath -Language vi -Colour Mono -Ascii -WorkerBackend Go -Icons ASCII -RuntimeMode native -NoInstall 2>&1
            $Code = $LASTEXITCODE
        } finally {
            $env:WT_BOOTSTRAP_TEST_ONLY = '1'
            Remove-Item Env:\WT_BOOTSTRAP_IMPLEMENTATION_PATH -ErrorAction Ignore
        }

        $Code | Should -Be 0
        @($Output).Count | Should -Be 0
        (Get-Content -LiteralPath $Record -Raw).Trim() | Should -Be 'native|vi|Mono|True|Go|ASCII|True'
    }

    It 'runs the implementation from the text the one-liner receives, mirrors the code and leaves the session clean' {
        $StateDir = Join-Path $script:TestRoot 'state-launcher'
        $Script = @"
# The documented one-liner: the launcher body is executed as text, so it has no
# `$PSScriptRoot and must find the implementation through the documented override.
Remove-Item Env:\WT_BOOTSTRAP_TEST_ONLY -ErrorAction Ignore
`$env:WT_BOOTSTRAP_IMPLEMENTATION_PATH = '$($script:BootstrapPath)'
`$env:WT_BOOTSTRAP_STATE_DIR = '$StateDir'
`$env:WT_BOOTSTRAP_RELEASE_URL = 'http://invalid.example/bootstrap'
`$env:WT_BOOTSTRAP_ENTRYPOINT = 'C:\nonexistent\entry.ps1'
iex (Get-Content -LiteralPath '$($script:LauncherPath)' -Raw)
'AFTER-LAUNCHER ' + `$LASTEXITCODE
'LEFT-OVER-FUNCTIONS ' + (@(Get-ChildItem Function:\ | Where-Object { `$_.Name -like '*WtBootstrap*' }).Count)
'STILL-HERE'
"@
        $Output = & $script:PwshPath -NoProfile -Command $Script 2>$null
        $ExitCode = $LASTEXITCODE
        $Text = $Output -join "`n"

        # Nothing in the chain may call exit(), and the failure must arrive as $LASTEXITCODE.
        $ExitCode | Should -Be 0
        $Text | Should -Match 'AFTER-LAUNCHER 1'
        $Text | Should -Match 'LEFT-OVER-FUNCTIONS 0'
        $Text | Should -Match 'STILL-HERE'
    }

    It 'reaches release discovery from file execution without downloading the implementation' {
        # File execution uses the implementation beside the launcher. The release URL is
        # refused before any request, so this proves the local selection and the error path
        # without network traffic; a download would have replaced that message with a
        # NETWORK failure about the implementation URL.
        $StateDir = Join-Path $script:TestRoot 'state-file'
        $env:WT_BOOTSTRAP_STATE_DIR = $StateDir
        $env:WT_BOOTSTRAP_RELEASE_URL = 'http://invalid.example/bootstrap'
        Remove-Item Env:\WT_BOOTSTRAP_TEST_ONLY -ErrorAction Ignore
        try {
            $Output = & $script:PwshPath -NoProfile -File $script:LauncherPath 2>&1
            $Code = $LASTEXITCODE
        } finally {
            $env:WT_BOOTSTRAP_TEST_ONLY = '1'
            Remove-Item Env:\WT_BOOTSTRAP_STATE_DIR, Env:\WT_BOOTSTRAP_RELEASE_URL -ErrorAction Ignore
        }

        $Text = @($Output) -join "`n"
        $Text | Should -Match 'NETWORK: Refusing non-HTTPS URL: http://invalid.example/bootstrap'
        $Text | Should -Not -Match 'implementation file was not found'
        # A -File run keeps the process exit code at 0 and mirrors the bootstrap code into
        # $LASTEXITCODE inside the session, exactly as the single-file bootstrap did.
        $Code | Should -Be 0
    }
}

Describe 'HTTP response streaming over a real HttpContent' {
    # The defect this covers: Windows PowerShell 5.1 runs on .NET Framework, where HttpContent
    # exposes only the asynchronous accessors. The previous code called
    # $Response.Content.ReadAsStream() and failed there with "Method invocation failed because
    # [System.Net.Http.StreamContent] does not contain a method named 'ReadAsStream'".
    # These tests drive the real content-to-stream path: real HttpContent objects, and a real
    # HTTP exchange over a socket, never a mock of the failing member. They are runtime-agnostic,
    # so the same tests are the check to run on a Windows PowerShell 5.1 host.

    BeforeAll {
        try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { $null = $_ }
        $script:HttpPayload = [byte[]]::new(262144)
        [System.Random]::new(20261101).NextBytes($script:HttpPayload)
    }

    It 'reads a real ByteArrayContent through both readers and enforces the size bound' {
        . $script:BootstrapPath
        . $script:LauncherPath

        # One content per reader: an HttpContent is a single-use body, so reusing it would test
        # the wrong thing (the framework closes its stream after a completed read).
        $ImplementationContent = [System.Net.Http.ByteArrayContent]::new($script:HttpPayload)
        try {
            $Implementation = Read-WtBootstrapContentBytes -Content $ImplementationContent -Source 'fixture'
        } finally {
            $ImplementationContent.Dispose()
        }
        $LauncherContent = [System.Net.Http.ByteArrayContent]::new($script:HttpPayload)
        try {
            $Launcher = Read-WtBootstrapLauncherContentBytes -Content $LauncherContent -Source 'fixture'
        } finally {
            $LauncherContent.Dispose()
        }

        $Expected = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($script:HttpPayload)) -Algorithm SHA256).Hash
        $Implementation.Length | Should -Be $script:HttpPayload.Length
        $Launcher.Length | Should -Be $script:HttpPayload.Length
        (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($Implementation)) -Algorithm SHA256).Hash | Should -Be $Expected
        (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($Launcher)) -Algorithm SHA256).Hash | Should -Be $Expected

        # A body larger than the bound fails while it is read, and the failure is classified.
        # Same single-use rule: one content per attempt.
        $CappedImplementation = [System.Net.Http.ByteArrayContent]::new($script:HttpPayload)
        try {
            { Read-WtBootstrapContentBytes -Content $CappedImplementation -MaxBytes 1024 -Source 'fixture' } |
                Should -Throw -ExpectedMessage '*INTEGRITY*byte limit*'
        } finally {
            $CappedImplementation.Dispose()
        }
        $CappedLauncher = [System.Net.Http.ByteArrayContent]::new($script:HttpPayload)
        try {
            { Read-WtBootstrapLauncherContentBytes -Content $CappedLauncher -MaxBytes 1024 -Source 'fixture' } |
                Should -Throw -ExpectedMessage '*INTEGRITY*byte limit*'
        } finally {
            $CappedLauncher.Dispose()
        }
    }

    It 'streams a real HTTP response body from a socket through the same reader' {
        . $script:BootstrapPath

        # A real TCP listener on an ephemeral port: no URL ACL, no elevation, and a genuine HTTP
        # response whose body arrives as StreamContent - the type that failed on 5.1.
        $Listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $Listener.Start()
        $Port = ([System.Net.IPEndPoint]$Listener.LocalEndpoint).Port
        $Url = "http://127.0.0.1:$Port/payload.bin"

        $Server = [powershell]::Create()
        $null = $Server.AddScript({
                param ($Listener, $Payload, $Count)
                $Header = "HTTP/1.1 200 OK`r`nContent-Type: application/octet-stream`r`nContent-Length: $($Payload.Length)`r`nConnection: close`r`n`r`n"
                $HeaderBytes = [System.Text.Encoding]::ASCII.GetBytes($Header)
                for ($Index = 0; $Index -lt $Count; $Index++) {
                    $Connection = $Listener.AcceptTcpClient()
                    try {
                        $Stream = $Connection.GetStream()
                        $Buffer = [byte[]]::new(4096)
                        $Text = ''
                        while ($Text -notmatch "`r`n`r`n") {
                            $Read = $Stream.Read($Buffer, 0, $Buffer.Length)
                            if ($Read -le 0) { break }
                            $Text += [System.Text.Encoding]::ASCII.GetString($Buffer, 0, $Read)
                        }
                        $Stream.Write($HeaderBytes, 0, $HeaderBytes.Length)
                        $Stream.Write($Payload, 0, $Payload.Length)
                        $Stream.Flush()
                    } finally {
                        $Connection.Close()
                    }
                }
            }).AddArgument($Listener).AddArgument($script:HttpPayload).AddArgument(2)
        $Handle = $Server.BeginInvoke()

        $Client = [System.Net.Http.HttpClient]::new()
        try {
            $Response = $Client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            try {
                $Bytes = Read-WtBootstrapContentBytes -Content $Response.Content -Source $Url
            } finally {
                $Response.Dispose()
            }

            $Bytes.Length | Should -Be $script:HttpPayload.Length
            (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($Bytes)) -Algorithm SHA256).Hash |
                Should -Be (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($script:HttpPayload)) -Algorithm SHA256).Hash

            $Response = $Client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            try {
                { Read-WtBootstrapContentBytes -Content $Response.Content -MaxBytes 4096 -Source $Url } |
                    Should -Throw -ExpectedMessage '*INTEGRITY*byte limit*'
            } finally {
                $Response.Dispose()
            }
        } finally {
            $Client.Dispose()
            try { $null = $Server.EndInvoke($Handle) } catch { $null = $_ }
            $Server.Dispose()
            $Listener.Stop()
        }
    }
}

Describe 'Live published launcher' -Skip:(-not $env:WT_BOOTSTRAP_LIVE_TEST) {
    # Remote verification of the published command, kept separate from the local fixtures.
    # Until this change is on `main`, the URL still serves the previous single-file bootstrap,
    # so these two tests fail by design before the fix is published.

    It 'serves a body with no leading U+FEFF that parses as text and declares the pair protocol' {
        . $script:BootstrapPath
        $Bytes = Get-WtBootstrapContent -Url $script:PublishedLauncherUrl
        $Text = [System.Text.Encoding]::UTF8.GetString($Bytes)

        [int][char]$Text[0] | Should -Not -Be 0xFEFF
        $Tokens = $null
        $Errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$Tokens, [ref]$Errors)
        @($Errors).Count | Should -Be 0
        $Text | Should -Match '(?m)^\s*\$Script:WtBootstrapLauncherProtocol\s*=\s*1\s*$'
    }

    It 'serves the implementation whose decoded text parses' {
        . $script:BootstrapPath
        . $script:LauncherPath
        $Bytes = Get-WtBootstrapContent -Url $script:PublishedImplementationUrl
        $Decoded = Convert-WtBootstrapLauncherImplementationText -Bytes $Bytes

        [int][char]$Decoded[0] | Should -Not -Be 0xFEFF
        $Tokens = $null
        $Errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($Decoded, [ref]$Tokens, [ref]$Errors)
        @($Errors).Count | Should -Be 0
    }

    It 'downloads real bytes through the whole downloader on this runtime' {
        . $script:BootstrapPath

        # The check to run on Windows PowerShell 5.1 (`WT_BOOTSTRAP_LIVE_TEST=1`): it drives
        # Get-WtBootstrapContent end to end - client, request, status, body stream - on the
        # runtime that lacks the synchronous HttpContent accessors.
        $Bytes = Get-WtBootstrapContent -Url $script:PublishedLauncherUrl -MaxBytes 4MB
        $Bytes.Length | Should -BeGreaterThan 1024
        [System.Text.Encoding]::UTF8.GetString($Bytes, 0, 3) | Should -Be '# W'
    }
}

Describe 'Release selection and verification' {

    It 'selects the asset for the architecture of the OS, never for "is it 64-bit"' {
        . $script:BootstrapPath

        # Every platform this ships for is 64-bit, so "is the OS 64-bit" can only ever answer
        # one way; it is this mapping that keeps an ARM64 machine off the x64 build.
        (Get-WtBootstrapPlatformKey -Os 'win' -Architecture 'Arm64') | Should -Be 'win-arm64'
        (Get-WtBootstrapPlatformKey -Os 'linux' -Architecture 'Arm64') | Should -Be 'linux-arm64'
        (Get-WtBootstrapPlatformKey -Os 'win' -Architecture 'X64') | Should -Be 'win-x64'
        (Get-WtBootstrapPlatformKey -Os 'linux' -Architecture 'X64') | Should -Be 'linux-x64'

        # A 32-bit host has no asset: refusing beats downloading an x64 archive it cannot run.
        { Get-WtBootstrapPlatformKey -Os 'win' -Architecture 'X86' } | Should -Throw -ExpectedMessage '*Unsupported architecture*'
    }

    It 'maps every release platform key to its own worker path (the one the client resolves)' {
        . $script:BootstrapPath

        $Expected = @{
            'win-x64'     = 'worker/bin/windows-amd64/wt-worker.exe'
            'win-arm64'   = 'worker/bin/windows-arm64/wt-worker.exe'
            'linux-x64'   = 'worker/bin/linux-amd64/wt-worker'
            'linux-arm64' = 'worker/bin/linux-arm64/wt-worker'
        }
        $Platforms = @(Get-WtBootstrapPlatforms)
        $Platforms.Count | Should -Be $Expected.Count
        foreach ($Platform in $Platforms) {
            $Platform.WorkerPath | Should -Be $Expected[$Platform.Key]
            (Get-WtBootstrapWorkerPath -PlatformKey $Platform.Key) | Should -Be $Expected[$Platform.Key]
            # The canonical path is the build output directory too: one scheme, not two.
            $Platform.WorkerPath | Should -Be "worker/bin/$($Platform.Os)-$($Platform.Arch)/$($Platform.Exe)"
        }
        @($Platforms.WorkerPath | Sort-Object -Unique).Count | Should -Be $Platforms.Count
        { Get-WtBootstrapWorkerPath -PlatformKey 'freebsd-x64' } | Should -Throw -ExpectedMessage '*Unknown release platform key*'
    }

    It 'starts on Windows PowerShell 5.1 and refuses only an older runtime' {
        . $script:BootstrapPath

        # 5.1 is the floor, not an error: it ships with Windows and has to work.
        { Assert-WtBootstrapRuntime -Version ([version]'5.1.26100.1591') } | Should -Not -Throw
        { Assert-WtBootstrapRuntime -Version ([version]'7.6.9') } | Should -Not -Throw
        { Assert-WtBootstrapRuntime -Version $PSVersionTable.PSVersion } | Should -Not -Throw

        { Assert-WtBootstrapRuntime -Version ([version]'5.0.10586.0') } | Should -Throw -ExpectedMessage 'RUNTIME:*'
        { Assert-WtBootstrapRuntime -Version ([version]'4.0.30319.0') } | Should -Throw -ExpectedMessage '*needs PowerShell*'
    }

    It 'accepts only the tested stable PowerShell 7 range as the handoff target' {
        . $script:BootstrapPath

        (Test-WtBootstrapCompatibleVersion -Version ([version]'7.4.0')) | Should -BeTrue
        (Test-WtBootstrapCompatibleVersion -Version ([version]'7.5.3')) | Should -BeTrue
        (Test-WtBootstrapCompatibleVersion -Version ([version]'7.6.9')) | Should -BeTrue

        # Untested, older or future runtimes are never selected automatically.
        (Test-WtBootstrapCompatibleVersion -Version ([version]'7.3.12')) | Should -BeFalse
        (Test-WtBootstrapCompatibleVersion -Version ([version]'7.7.0')) | Should -BeFalse
        (Test-WtBootstrapCompatibleVersion -Version ([version]'8.0.0')) | Should -BeFalse
        (Test-WtBootstrapCompatibleVersion -Version ([version]'5.1.26100.1591')) | Should -BeFalse
        # A preview of a supported version stays a preview.
        (Test-WtBootstrapCompatibleVersion -Version ([version]'7.6.0') -PreRelease '7.6.0-preview.2') | Should -BeFalse
    }

    It 'selects the exact platform asset and rejects ambiguity' {
        . $script:BootstrapPath
        $Key = Get-WtBootstrapPlatformKey
        $Other = if ($Key -like 'linux-*') { 'win-x64' } else { 'linux-x64' }
        $Release = [pscustomobject]@{
            tag_name = 'v1.0.0'
            html_url = 'https://github.com/x/y/releases/tag/v1.0.0'
            assets = @(
                [pscustomobject]@{ name = "WindowsTweaker-$Key-v1.0.0.zip"; browser_download_url = "https://github.com/x/y/releases/download/v1.0.0/WindowsTweaker-$Key-v1.0.0.zip"; size = 100; platform = $Key }
                [pscustomobject]@{ name = "WindowsTweaker-$Other-v1.0.0.zip"; browser_download_url = "https://github.com/x/y/releases/download/v1.0.0/WindowsTweaker-$Other-v1.0.0.zip"; size = 100; platform = $Other }
            )
        }
        $Asset = Get-WtBootstrapAsset -Release $Release
        $Pattern = [regex]::Escape("-$Key-")
        $Asset.name | Should -Match $Pattern

        # Ambiguity: two more candidates for the same platform key.
        $Release.assets += [pscustomobject]@{ name = "WindowsTweaker-$Key-v1.0.1.zip"; browser_download_url = 'https://github.com/x/y/releases/download/v1.0.1/x.zip'; size = 100 }
        $Release.assets += [pscustomobject]@{ name = "WindowsTweaker-$Key.zip"; browser_download_url = 'https://github.com/x/y/releases/download/v1.0.1/y.zip'; size = 100 }
        { Get-WtBootstrapAsset -Release $Release } | Should -Throw
    }

    It 'refuses an asset whose declared platform is not this host platform' {
        . $script:BootstrapPath
        $Key = Get-WtBootstrapPlatformKey
        $Other = if ($Key -like 'linux-*') { 'win-x64' } else { 'linux-x64' }
        $Release = [pscustomobject]@{
            tag_name = 'v1.0.0'
            assets = @([pscustomobject]@{ name = "WindowsTweaker-$Key-v1.0.0.zip"; browser_download_url = 'https://github.com/x/y.zip'; size = 10; platform = $Other })
        }
        { Get-WtBootstrapAsset -Release $Release } | Should -Throw -ExpectedMessage '*declares platform*'
    }

    It 'rejects non-HTTPS and non-allowed hosts' {
        . $script:BootstrapPath
        { Get-WtBootstrapContent -Url 'http://insecure.example/x' } | Should -Throw
        { Get-WtBootstrapContent -Url 'https://evil.example/x' } | Should -Throw
    }

    It 'validates every redirect hop and allows the hosts GitHub actually uses' {
        . $script:BootstrapPath

        (Get-WtBootstrapAllowedHosts) | Should -Contain 'release-assets.githubusercontent.com'
        (Get-WtBootstrapAllowedHosts) | Should -Contain 'objects.githubusercontent.com'
        (Get-WtBootstrapAllowedHosts) | Should -Contain 'github.com'

        $Base = [uri]'https://github.com/88kbleirad/WindowsTweaker/releases/download/v1.0.0/x.zip'
        # The host GitHub redirects release assets to today.
        $Relative = Resolve-WtBootstrapRedirectTarget -Base $Base -Location '/github-production-release-asset/a/b?sp=r' -SourceUrl $Base.AbsoluteUri
        $Relative | Should -Be 'https://github.com/github-production-release-asset/a/b?sp=r'
        $Absolute = Resolve-WtBootstrapRedirectTarget -Base $Base -Location 'https://release-assets.githubusercontent.com/github-production-release-asset/a/b' -SourceUrl $Base.AbsoluteUri
        $Absolute | Should -Be 'https://release-assets.githubusercontent.com/github-production-release-asset/a/b'

        # A redirect to a host that is not on the list, and a downgrade to http, are refused.
        { Resolve-WtBootstrapRedirectTarget -Base $Base -Location 'https://evil.example/x.zip' -SourceUrl $Base.AbsoluteUri } | Should -Throw -ExpectedMessage '*not allowed*'
        { Resolve-WtBootstrapRedirectTarget -Base $Base -Location 'http://release-assets.githubusercontent.com/x' -SourceUrl $Base.AbsoluteUri } | Should -Throw -ExpectedMessage '*non-HTTPS*'
        { Resolve-WtBootstrapRedirectTarget -Base $Base -Location '' -SourceUrl $Base.AbsoluteUri } | Should -Throw -ExpectedMessage '*without Location*'
    }

    It 'fails explicitly when no checksums exist' {
        . $script:BootstrapPath
        $Key = Get-WtBootstrapPlatformKey
        $Release = [pscustomobject]@{ tag_name = 'v1.0.0'; assets = @([pscustomobject]@{ name = "WindowsTweaker-$Key-v1.0.0.zip"; browser_download_url = 'https://github.com/x/y.zip'; size = 10 }) }
        $Asset = Get-WtBootstrapAsset -Release $Release
        (Get-WtBootstrapExpectedHash -Release $Release -Asset $Asset) | Should -Be ''
    }

    It 'hash verification mismatch throws' {
        . $script:BootstrapPath
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes('hello')
        { Test-WtBootstrapHash -Bytes $Bytes -ExpectedHash ('0' * 64) } | Should -Throw
    }

    It 'reads sha256sum text the way the release writes it' {
        . $script:BootstrapPath
        $Text = "e05915e2fe1f76320d8a6d3c51718c16e1607d81de5a7cb0cff0de77d699cfc0  WindowsTweaker-win-x64-v1.0.0.zip`r`n" +
            "0000000000000000000000000000000000000000000000000000000000000000 * WindowsTweaker-linux-x64-v1.0.0.zip`n" +
            "not a checksum line`n"
        $Map = Read-WtBootstrapChecksums -Text $Text
        $Map['windowstweaker-win-x64-v1.0.0.zip'] | Should -Be 'e05915e2fe1f76320d8a6d3c51718c16e1607d81de5a7cb0cff0de77d699cfc0'
        $Map['windowstweaker-linux-x64-v1.0.0.zip'] | Should -Be ('0' * 64)
        $Map.Count | Should -Be 2
    }
}

Describe 'Safe staging and no-bypass release validation' {

    It 'prevents archive path traversal' {
        . $script:BootstrapPath
        $Staging = Join-Path $script:TestRoot 'staging-safe'
        [System.IO.Directory]::CreateDirectory($Staging) | Out-Null

        $Memory = [System.IO.MemoryStream]::new()
        $Archive = [System.IO.Compression.ZipArchive]::new($Memory, 'Create')
        $Entry = $Archive.CreateEntry('../evil.txt')
        $Entry.Open().Dispose()
        $Archive.Dispose()
        $Bytes = $Memory.ToArray()

        { Expand-WtBootstrapArchive -Bytes $Bytes -Staging $Staging } | Should -Throw
        (Test-Path -LiteralPath (Join-Path (Split-Path $Staging -Parent) 'evil.txt')) | Should -BeFalse
    }

    It 'supports paths with spaces and Unicode' {
        . $script:BootstrapPath
        $Dir = Join-Path $script:TestRoot 'spaced dir üñï'
        [System.IO.Directory]::CreateDirectory($Dir) | Out-Null
        $Memory = [System.IO.MemoryStream]::new()
        $Archive = [System.IO.Compression.ZipArchive]::new($Memory, 'Create')
        $Entry = $Archive.CreateEntry('a.txt')
        $Writer = [System.IO.StreamWriter]::new($Entry.Open())
        $Writer.Write('hi'); $Writer.Dispose()
        $Archive.Dispose()
        $Bytes = $Memory.ToArray()

        Expand-WtBootstrapArchive -Bytes $Bytes -Staging $Dir
        (Test-Path -LiteralPath (Join-Path $Dir 'a.txt')) | Should -BeTrue
    }

    It 'requires manifest and key files' {
        . $script:BootstrapPath
        $Staging = Join-Path $script:TestRoot 'staging-invalid'
        [System.IO.Directory]::CreateDirectory($Staging) | Out-Null
        Set-Content -LiteralPath (Join-Path $Staging 'manifest.json') -Value '{}' -Encoding utf8
        { Test-WtBootstrapRelease -Staging $Staging -PlatformKey 'win-x64' } | Should -Throw
    }

    It 'refuses a manifest that is not the canonical worker path for the platform' {
        . $script:BootstrapPath
        $Staging = Join-Path $script:TestRoot 'staging-wrong-worker'
        foreach ($File in @('WindowsTweaker.ps1', 'THIRD-PARTY-NOTICES.md', 'src/WindowsTweaker/WindowsTweaker.psd1', 'worker/bin/windows-amd64/wt-worker.exe')) {
            $Target = Join-Path $Staging ($File -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            [System.IO.Directory]::CreateDirectory((Split-Path $Target -Parent)) | Out-Null
            Set-Content -LiteralPath $Target -Value 'x' -Encoding utf8
        }
        # The old packaging wrote worker/bin/windows-amd64 for a key that reads win-x64; a
        # release that declares it must be refused instead of staged and launched.
        $Manifest = [ordered]@{ schemaVersion = 1; version = '1.0.0'; platform = 'win-x64'; workerProtocol = 1; worker = @{ path = 'worker/bin/win-x64/wt-worker.exe' } }
        Set-Content -LiteralPath (Join-Path $Staging 'manifest.json') -Value ($Manifest | ConvertTo-Json -Depth 4) -Encoding utf8
        { Test-WtBootstrapRelease -Staging $Staging -PlatformKey 'win-x64' } | Should -Throw -ExpectedMessage '*canonical path*'
    }

    It 'refuses a manifest for another platform and one whose declared file hash disagrees' {
        . $script:BootstrapPath
        $Staging = Join-Path $script:TestRoot 'staging-bad-manifest'
        foreach ($File in @('WindowsTweaker.ps1', 'THIRD-PARTY-NOTICES.md', 'src/WindowsTweaker/WindowsTweaker.psd1', 'worker/bin/windows-amd64/wt-worker.exe')) {
            $Target = Join-Path $Staging ($File -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            [System.IO.Directory]::CreateDirectory((Split-Path $Target -Parent)) | Out-Null
            # NoNewline: one byte on every platform, so the manifest's size is right and the
            # hash is the only thing that can disagree.
            Set-Content -LiteralPath $Target -Value 'x' -Encoding utf8 -NoNewline
        }
        $ManifestPath = Join-Path $Staging 'manifest.json'
        $Base = [ordered]@{
            schemaVersion = 1; version = '1.0.0'; platform = 'linux-x64'; workerProtocol = 1
            worker = @{ path = 'worker/bin/windows-amd64/wt-worker.exe' }
            files = @(@{ path = 'WindowsTweaker.ps1'; size = 1; sha256 = ('0' * 64) })
        }
        Set-Content -LiteralPath $ManifestPath -Value ($Base | ConvertTo-Json -Depth 4) -Encoding utf8
        { Test-WtBootstrapRelease -Staging $Staging -PlatformKey 'win-x64' } | Should -Throw -ExpectedMessage '*declares platform*'

        $Base.platform = 'win-x64'
        Set-Content -LiteralPath $ManifestPath -Value ($Base | ConvertTo-Json -Depth 4) -Encoding utf8
        { Test-WtBootstrapRelease -Staging $Staging -PlatformKey 'win-x64' } | Should -Throw -ExpectedMessage '*File hash mismatch*'

        # With -SkipIntegrity the structure still has to be right, but no file is hashed.
        { Test-WtBootstrapRelease -Staging $Staging -PlatformKey 'win-x64' -SkipIntegrity } | Should -Not -Throw
    }

    It 'never reuses a staging directory that did not pass validation' {
        . $script:BootstrapPath
        $State = Join-Path $script:TestRoot 'state-cache'
        $Staging = Join-Path $State 'release-v9.9.9'
        [System.IO.Directory]::CreateDirectory($Staging) | Out-Null
        foreach ($File in @('WindowsTweaker.ps1', 'THIRD-PARTY-NOTICES.md', 'src/WindowsTweaker/WindowsTweaker.psd1', 'worker/bin/windows-amd64/wt-worker.exe')) {
            $Target = Join-Path $Staging ($File -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            [System.IO.Directory]::CreateDirectory((Split-Path $Target -Parent)) | Out-Null
            Set-Content -LiteralPath $Target -Value 'x' -Encoding utf8
        }
        $Manifest = @{ schemaVersion = 1; version = '9.9.9'; platform = 'win-x64'; workerProtocol = 1; worker = @{ path = 'worker/bin/windows-amd64/wt-worker.exe' }; entryPoint = 'WindowsTweaker.ps1' }
        Set-Content -LiteralPath (Join-Path $Staging 'manifest.json') -Value ($Manifest | ConvertTo-Json -Depth 4) -Encoding utf8

        # Files and a manifest alone are not a validated release.
        (Test-WtBootstrapStagingComplete -Staging $Staging) | Should -BeFalse
        (Find-WtBootstrapCache -State $State -PlatformKey 'win-x64') | Should -BeNullOrEmpty

        # The marker is written only after the bootstrap validated the staged release.
        Set-WtBootstrapStagingComplete -Staging $Staging -PlatformKey 'win-x64' -Version '9.9.9'
        (Test-WtBootstrapStagingComplete -Staging $Staging) | Should -BeTrue
        $Found = Find-WtBootstrapCache -State $State -PlatformKey 'win-x64'
        $Found.Tag | Should -Be 'v9.9.9'

        # A cache for another platform is not a cache for this one.
        (Find-WtBootstrapCache -State $State -PlatformKey 'linux-arm64') | Should -BeNullOrEmpty
    }
}

Describe 'No system tweaks by bootstrap' {

    It 'launches the entry point with no arguments and reports its exit code' {
        . $script:BootstrapPath
        $Entry = Join-Path $script:TestRoot 'stub-entry.ps1'
        $Record = Join-Path $script:TestRoot 'stub-args.txt'
        $Stub = @(
            "Set-Content -LiteralPath '$Record' -Value (`$Args.Count.ToString() + '|' + (`$Args -join ',')) -Encoding utf8"
            'exit 7'
        ) -join "`n"
        Set-Content -LiteralPath $Entry -Value $Stub -Encoding utf8

        # Opening the interface applies no tweak, and the bootstrap must not smuggle a switch
        # (-WhatIf, -Id, a preset) into the launch: it starts the entry point bare.
        $Code = Invoke-WtBootstrapLaunch -PwshPath '' -EntryPoint $Entry
        $Code | Should -Be 7
        (Get-Content -LiteralPath $Record -Raw).Trim() | Should -Be '0|'
    }

    It 'preserves the caller options, the working directory and the environment for the child' {
        . $script:BootstrapPath
        $Entry = Join-Path $script:TestRoot 'stub-options.ps1'
        $Record = Join-Path $script:TestRoot 'stub-options.txt'
        # One string value: an array here would make Set-Content write one line per element.
        $Stub = @(
            "`$Value = (`$Args -join '|') + ' :: ' + (Get-Location).Path + ' :: ' + `$env:WT_BOOTSTRAP_HANDOFF"
            "Set-Content -LiteralPath '$Record' -Value `$Value -Encoding utf8"
            'exit 0'
        ) -join "`n"
        Set-Content -LiteralPath $Entry -Value $Stub -Encoding utf8

        $Code = Invoke-WtBootstrapLaunch -PwshPath '' -EntryPoint $Entry -Argument @('-Language', 'vi', '-Colour', 'Mono', '-Ascii') -EnvironmentVariable @{ WT_BOOTSTRAP_HANDOFF = '1' }
        $Code | Should -Be 0
        $Recorded = (Get-Content -LiteralPath $Record -Raw).Trim()
        $Recorded | Should -Match '-Language\|vi\|\-Colour\|Mono\|\-Ascii'
        # The child runs in the caller's working directory, and the handoff marker is visible
        # to it (that is what stops a second chain).
        $Recorded | Should -Match ([regex]::Escape((Get-Location).Path))
        $Recorded | Should -Match ':: 1$'
    }

    It 'quotes arguments that a command line would otherwise split' {
        . $script:BootstrapPath

        (ConvertTo-WtBootstrapArgumentString -Argument @('-NoProfile', '-File', 'C:\Program Files\WindowsTweaker\WindowsTweaker.ps1')) |
            Should -Be '-NoProfile -File "C:\Program Files\WindowsTweaker\WindowsTweaker.ps1"'
        # A trailing backslash before the closing quote must be doubled, an embedded quote escaped.
        (ConvertTo-WtBootstrapArgumentString -Argument @('C:\dir with space\')) | Should -Be '"C:\dir with space\\"'
        (ConvertTo-WtBootstrapArgumentString -Argument @('say "hi"')) | Should -Be '"say \"hi\""'
        (ConvertTo-WtBootstrapArgumentString -Argument @('')) | Should -Be '""'
    }

    It 'writes no app state or settings file, and launches nothing before validation' {
        $env:WT_BOOTSTRAP_STATE_DIR = Join-Path $script:TestRoot 'state-notweak'
        $env:WT_BOOTSTRAP_RELEASE_URL = 'http://invalid.example/bootstrap'
        $env:WT_BOOTSTRAP_ENTRYPOINT = 'C:\nonexistent\entry.ps1'
        Remove-Item Env:\WT_BOOTSTRAP_TEST_ONLY -ErrorAction Ignore
        try {
            # No network (the URL is refused), so nothing can be staged: the entry point is
            # never reached and no tweak can be applied by a bootstrap that only launches.
            { & ([scriptblock]::Create((Get-Content -LiteralPath $script:BootstrapPath -Raw))) 2>$null | Out-Null } | Should -Not -Throw
        } finally {
            Remove-Item Env:\WT_BOOTSTRAP_STATE_DIR, Env:\WT_BOOTSTRAP_RELEASE_URL, Env:\WT_BOOTSTRAP_ENTRYPOINT -ErrorAction Ignore
            $env:WT_BOOTSTRAP_TEST_ONLY = '1'
        }
        $After = @(Get-ChildItem -LiteralPath $script:TestRoot -Recurse -File -ErrorAction Ignore | Where-Object { $_.Name -in 'state.json', 'settings.json' })
        $After.Count | Should -Be 0
    }
}

Describe 'Live GitHub redirect handling' -Skip:(-not $env:WT_BOOTSTRAP_LIVE_TEST) {

    It 'downloads a real release asset through the github.com -> release-assets redirect' {
        . $script:BootstrapPath
        # A ~1.5 KB asset of a public release: the point is the redirect chain, not the payload.
        $Bytes = Get-WtBootstrapContent -Url 'https://github.com/cli/cli/releases/download/v2.0.0/gh_2.0.0_checksums.txt' -MaxBytes 1MB
        $Bytes.Length | Should -BeGreaterThan 0
        ([System.Text.Encoding]::UTF8.GetString($Bytes)) | Should -Match 'gh_2\.0\.0_linux_amd64\.tar\.gz'
    }

    It 'reads real release metadata from the GitHub API' {
        . $script:BootstrapPath
        # Default (no WT_BOOTSTRAP_RELEASE_URL) targets the project repository; it has no
        # release yet, so the API answers 404 and the bootstrap must say so rather than
        # invent one. The success path is therefore exercised against a repository that does
        # have releases, through the same override a self-hosting user would use.
        $env:WT_BOOTSTRAP_RELEASE_URL = 'https://api.github.com/repos/cli/cli/releases/latest'
        try {
            $Topic = Get-WtBootstrapRelease
            $Topic.tag_name | Should -Match '^v?\d+\.'
            @($Topic.assets).Count | Should -BeGreaterThan 0
        } finally {
            Remove-Item Env:\WT_BOOTSTRAP_RELEASE_URL -ErrorAction Ignore
        }
    }

    It 'refuses the project metadata URL while no release is published' {
        . $script:BootstrapPath
        $env:WT_BOOTSTRAP_RELEASE_URL = 'https://api.github.com/repos/88kbleirad/WindowsTweaker/releases/latest'
        try {
            { Get-WtBootstrapRelease } | Should -Throw -ExpectedMessage '*404*'
        } finally {
            Remove-Item Env:\WT_BOOTSTRAP_RELEASE_URL -ErrorAction Ignore
        }
    }
}

Describe 'Compatible pwsh discovery and handoff' {

    BeforeAll {
        . $script:BootstrapPath
        $script:FakeRoot = Join-Path $script:TestRoot 'fake-runtimes'
        [System.IO.Directory]::CreateDirectory($script:FakeRoot) | Out-Null

        # A fake runtime is a PowerShell script that prints the probe line and nothing else;
        # discovery runs it, so a file name alone can never be what selects it.
        function script:New-FakePwsh {
            param ([string]$Name, [string]$Reported, [int]$ExitCode = 0)

            $Path = Join-Path $script:FakeRoot $Name
            $Body = @(
                "Write-Output '$Reported'"
                "exit $ExitCode"
            ) -join "`n"
            Set-Content -LiteralPath $Path -Value $Body -Encoding utf8
            return $Path
        }

        $script:Stable76 = New-FakePwsh -Name 'pwsh-7.6.9.ps1' -Reported '[7.6.9]|Core|AMD64'
        $script:Stable75 = New-FakePwsh -Name 'pwsh-7.5.3.ps1' -Reported '[7.5.3]|Core|AMD64'
        $script:Old73 = New-FakePwsh -Name 'pwsh-7.3.12.ps1' -Reported '[7.3.12]|Core|AMD64'
        $script:Future77 = New-FakePwsh -Name 'pwsh-7.7.0.ps1' -Reported '[7.7.0]|Core|AMD64'
        $script:Preview = New-FakePwsh -Name 'pwsh-7.7.0-preview3.ps1' -Reported '[7.7.0-preview.3]|Core|AMD64'
        $script:Broken = New-FakePwsh -Name 'pwsh-broken.ps1' -Reported 'not a version' -ExitCode 0
        $script:Failing = New-FakePwsh -Name 'pwsh-failing.ps1' -Reported '' -ExitCode 1
    }

    It 'probes the executable instead of trusting its file name' {
        . $script:BootstrapPath

        $Candidate = Read-WtBootstrapPwshCandidate -Path $script:Stable76
        $Candidate.Version | Should -Be ([version]'7.6.9')
        $Candidate.Edition | Should -Be 'Core'
        $Candidate.Compatible | Should -BeTrue
        $Candidate.Selected | Should -BeTrue
        $Candidate.Reason | Should -Match 'Stable'

        $Broken = Read-WtBootstrapPwshCandidate -Path $script:Broken
        $Broken.Compatible | Should -BeFalse
        $Broken.Reason | Should -Match 'Did not report a version'

        $Failing = Read-WtBootstrapPwshCandidate -Path $script:Failing
        $Failing.Compatible | Should -BeFalse
    }

    It 'never selects a preview build or an untested range' {
        . $script:BootstrapPath

        $Preview = Read-WtBootstrapPwshCandidate -Path $script:Preview
        $Preview.Preview | Should -BeTrue
        $Preview.Compatible | Should -BeFalse
        $Preview.Reason | Should -Match 'Preview build'

        (Read-WtBootstrapPwshCandidate -Path $script:Old73).Compatible | Should -BeFalse
        (Read-WtBootstrapPwshCandidate -Path $script:Future77).Compatible | Should -BeFalse
    }

    It 'selects the highest compatible version, preferring PATH order among equals' {
        . $script:BootstrapPath

        $Candidates = @(
            Read-WtBootstrapPwshCandidate -Path $script:Stable75
            Read-WtBootstrapPwshCandidate -Path $script:Stable76
            Read-WtBootstrapPwshCandidate -Path $script:Preview
            Read-WtBootstrapPwshCandidate -Path $script:Old73
        )
        $Best = Select-WtBootstrapPwsh -Candidate $Candidates
        $Best.Path | Should -Be $script:Stable76
        @($Candidates | Where-Object { $_.Selected }).Count | Should -Be 1

        # Same version in two installations: the first one (PATH order) wins.
        $Equal = @(
            Read-WtBootstrapPwshCandidate -Path $script:Stable76
            Read-WtBootstrapPwshCandidate -Path (New-FakePwsh -Name 'pwsh-7.6.9-second.ps1' -Reported '[7.6.9]|Core|AMD64')
        )
        (Select-WtBootstrapPwsh -Candidate $Equal).Path | Should -Be $script:Stable76
    }

    It 'discovers the explicit override and never duplicates one installation' {
        . $script:BootstrapPath

        $SavedOverride = $env:WT_BOOTSTRAP_PWSH
        $env:WT_BOOTSTRAP_PWSH = $script:Stable76
        try {
            # WT_BOOTSTRAP_PWSH is the release-engineering override; it is probed first.
            $Found = @(Get-WtBootstrapPwshCandidates)
            $Found.Count | Should -BeGreaterThan 0
            @($Found | Where-Object { $_.Path -eq $script:Stable76 }).Count | Should -Be 1
        } finally {
            if ($null -eq $SavedOverride) { Remove-Item Env:\WT_BOOTSTRAP_PWSH -ErrorAction Ignore }
            else { $env:WT_BOOTSTRAP_PWSH = $SavedOverride }
        }
    }

    It 'hands off only when the runtime cannot run the requested mode, and never loops' {
        . $script:BootstrapPath

        $Entry = Join-Path $script:TestRoot 'stub-handoff.ps1'
        Set-Content -LiteralPath $Entry -Value 'exit 0' -Encoding utf8

        Mock Select-WtBootstrapPwsh { $null }
        Mock Invoke-WtBootstrapLaunch { 0 }
        Mock Get-WtBootstrapPwshCandidates { @() }
        Mock Invoke-WtBootstrapInstallOffer { $null }

        # On a supported PowerShell 7 runtime there is no second process at all.
        Mock Get-WtBootstrapRuntimeProfile { [pscustomobject]@{ Version = [version]'7.6.9'; Tier = 'Supported'; IsCore = $true; Platform = 'Windows'; MinimumVersion = [version]'5.1'; SupportedVersion = [version]'7.4' } }
        Invoke-WtBootstrapApplication -EntryPoint $Entry -Mode 'auto' -NoInstall | Should -Be 0
        Should -Invoke Select-WtBootstrapPwsh -Times 0

        # Windows PowerShell 5.1: a compatible runtime is looked for and used.
        Mock Get-WtBootstrapRuntimeProfile { [pscustomobject]@{ Version = [version]'5.1.26100.1591'; Tier = 'WindowsPowerShell'; IsCore = $false; Platform = 'Windows'; MinimumVersion = [version]'5.1'; SupportedVersion = [version]'7.4' } }
        Mock Select-WtBootstrapPwsh { [pscustomobject]@{ Path = 'C:\Program Files\PowerShell\7\pwsh.exe'; Version = [version]'7.6.9' } }
        Mock Invoke-WtBootstrapLaunch { 0 }
        Invoke-WtBootstrapApplication -EntryPoint $Entry -Mode 'auto' -NoInstall | Should -Be 0
        Should -Invoke Select-WtBootstrapPwsh -Times 1
        Should -Invoke Invoke-WtBootstrapLaunch -Times 1 -ParameterFilter { $PwshPath -like '*PowerShell\7\pwsh.exe' }

        # A handoff that already happened (or a chain that is too deep) runs natively and
        # never starts another chain.
        Mock Select-WtBootstrapPwsh { $null } -ParameterFilter { $false }
        $SavedHandoff = $env:WT_BOOTSTRAP_HANDOFF
        $SavedDepth = $env:WT_BOOTSTRAP_DEPTH
        $env:WT_BOOTSTRAP_HANDOFF = '1'
        $env:WT_BOOTSTRAP_DEPTH = '1'
        try {
            Mock Select-WtBootstrapPwsh { throw 'Discovery must not run after a handoff.' }
            Invoke-WtBootstrapApplication -EntryPoint $Entry -Mode 'auto' -NoInstall | Should -Be 0
        } finally {
            if ($null -eq $SavedHandoff) { Remove-Item Env:\WT_BOOTSTRAP_HANDOFF -ErrorAction Ignore } else { $env:WT_BOOTSTRAP_HANDOFF = $SavedHandoff }
            if ($null -eq $SavedDepth) { Remove-Item Env:\WT_BOOTSTRAP_DEPTH -ErrorAction Ignore } else { $env:WT_BOOTSTRAP_DEPTH = $SavedDepth }
        }

        # WT_BOOTSTRAP_RUNTIME=native never discovers anything.
        Mock Select-WtBootstrapPwsh { throw 'Discovery must not run in native mode.' }
        Invoke-WtBootstrapApplication -EntryPoint $Entry -Mode 'native' -NoInstall | Should -Be 0
    }

    It 'fails with the manual instructions when a runtime is required and none exists' {
        . $script:BootstrapPath

        $Entry = Join-Path $script:TestRoot 'stub-required.ps1'
        Set-Content -LiteralPath $Entry -Value 'exit 0' -Encoding utf8

        Mock Get-WtBootstrapRuntimeProfile { [pscustomobject]@{ Version = [version]'5.1.26100.1591'; Tier = 'WindowsPowerShell'; IsCore = $false; Platform = 'Windows'; MinimumVersion = [version]'5.1'; SupportedVersion = [version]'7.4' } }
        Mock Select-WtBootstrapPwsh { $null }
        Mock Invoke-WtBootstrapInstallOffer { $null }
        Mock Write-WtBootstrapMessage { }

        # Mode 'pwsh' is explicit: no silent native fallback.
        Invoke-WtBootstrapApplication -EntryPoint $Entry -Mode 'pwsh' -NoInstall | Should -Be 3
        Should -Invoke Write-WtBootstrapMessage -Times 1 -ParameterFilter { $Name -eq 'PwshRequired' }
        Should -Invoke Write-WtBootstrapMessage -Times 1 -ParameterFilter { $Name -eq 'ManualInstall' }
    }
}

Describe 'Missing runtime: installation offer' {

    BeforeAll {
        . $script:BootstrapPath
        $script:InstallRoot = Join-Path $script:TestRoot 'fake-install'
        [System.IO.Directory]::CreateDirectory($script:InstallRoot) | Out-Null

        # A fake winget records its arguments and exits with the scripted code.
        function script:New-FakeWinget {
            param ([string]$Name, [int]$ExitCode)

            $Path = Join-Path $script:InstallRoot $Name
            $Log = Join-Path $script:InstallRoot ($Name + '.args')
            $Body = @(
                "Set-Content -LiteralPath '$Log' -Value (@(`$Args -join ' ')) -Encoding utf8"
                "exit $ExitCode"
            ) -join "`n"
            Set-Content -LiteralPath $Path -Value $Body -Encoding utf8
            return $Path
        }

        $script:WingetOk = New-FakeWinget -Name 'winget-ok.ps1' -ExitCode 0
        $script:WingetFail = New-FakeWinget -Name 'winget-fail.ps1' -ExitCode 1
        $script:WingetCancel = New-FakeWinget -Name 'winget-cancel.ps1' -ExitCode 0
        $script:Compatible = [pscustomobject]@{ Path = 'C:\Program Files\PowerShell\7\pwsh.exe'; Version = [version]'7.6.9'; Selected = $true; Compatible = $true }

        Mock Get-WtBootstrapRuntimeProfile { [pscustomobject]@{ Version = [version]'5.1.26100.1591'; Tier = 'WindowsPowerShell'; IsCore = $false; Platform = 'Windows'; MinimumVersion = [version]'5.1'; SupportedVersion = [version]'7.4' } }
    }

    It 'prints the manual alternative when winget is unavailable (LTSC, Server Core)' {
        . $script:BootstrapPath

        Mock Find-WtBootstrapWinget { $null }
        Mock Read-Host { throw 'Read-Host must not be called without winget.' }
        Mock Write-WtBootstrapMessage { }

        Invoke-WtBootstrapInstallOffer | Should -BeNullOrEmpty
        Should -Invoke Write-WtBootstrapMessage -Times 1 -ParameterFilter { $Name -eq 'WingetMissing' }
        Should -Invoke Write-WtBootstrapMessage -Times 1 -ParameterFilter { $Name -eq 'ManualInstall' }
        Should -Invoke Read-Host -Times 0
    }

    It 'installs only after an explicit yes, and finds the executable without trusting PATH' {
        . $script:BootstrapPath

        Mock Find-WtBootstrapWinget { $script:WingetOk }
        Mock Read-Host { 'y' }
        Mock Get-WtBootstrapPwshCandidates { @($script:Compatible) }
        Mock Write-WtBootstrapMessage { }

        $Result = Invoke-WtBootstrapInstallOffer
        $Result.Path | Should -Be $script:Compatible.Path

        $Recorded = [System.IO.File]::ReadAllText((Join-Path $script:InstallRoot 'winget-ok.ps1.args'))
        # Official source, exact id, no interactive prompts, contracts accepted: the command
        # the user consented to, and nothing beyond it.
        $Recorded | Should -Match 'install'
        $Recorded | Should -Match '--id Microsoft.PowerShell'
        $Recorded | Should -Match '--exact'
        $Recorded | Should -Match '--source winget'
        $Recorded | Should -Match '--accept-package-agreements'
    }

    It 'cancels cleanly when the user declines' {
        . $script:BootstrapPath

        Mock Find-WtBootstrapWinget { $script:WingetCancel }
        Mock Read-Host { 'n' }
        Mock Write-WtBootstrapMessage { }

        Invoke-WtBootstrapInstallOffer | Should -BeNullOrEmpty
        Should -Invoke Write-WtBootstrapMessage -Times 1 -ParameterFilter { $Name -eq 'InstallCancelled' }
        # Declining never runs the installer.
        (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'winget-cancel.ps1.args')) | Should -BeFalse
    }

    It 'reports a failed installation and returns to the shell' {
        . $script:BootstrapPath

        Mock Find-WtBootstrapWinget { $script:WingetFail }
        Mock Read-Host { 'y' }
        Mock Write-WtBootstrapMessage { }

        Invoke-WtBootstrapInstallOffer | Should -BeNullOrEmpty
        Should -Invoke Write-WtBootstrapMessage -Times 1 -ParameterFilter { $Name -eq 'InstallFailed' }
        Should -Invoke Write-WtBootstrapMessage -Times 1 -ParameterFilter { $Name -eq 'ManualInstall' }
    }

    It 'does not offer an installation when the caller disabled it' {
        . $script:BootstrapPath

        Mock Find-WtBootstrapWinget { $script:WingetOk }
        Mock Read-Host { throw 'No prompt when installation is disabled.' }
        Mock Write-WtBootstrapMessage { }

        Invoke-WtBootstrapInstallOffer -NoInstall | Should -BeNullOrEmpty
        Should -Invoke Write-WtBootstrapMessage -Times 1 -ParameterFilter { $Name -eq 'ManualInstall' }
    }
}

Describe 'Error classification' {

    It 'classifies download, integrity, package, launch and runtime failures separately' {
        . $script:BootstrapPath

        # NETWORK: refused before any request (non-HTTPS, unknown host).
        { Get-WtBootstrapContent -Url 'http://invalid.example/x' } | Should -Throw -ExpectedMessage 'NETWORK:*'
        { Get-WtBootstrapContent -Url 'https://evil.example/x' } | Should -Throw -ExpectedMessage 'NETWORK:*'

        # INTEGRITY: a hash mismatch is not a network problem.
        { Test-WtBootstrapHash -Bytes ([byte[]](1, 2, 3)) -ExpectedHash ('0' * 64) } | Should -Throw -ExpectedMessage 'INTEGRITY:*'

        # PACKAGE: a release without an asset for this platform.
        $Release = [pscustomobject]@{ tag_name = 'v1.0.0'; assets = @([pscustomobject]@{ name = 'WindowsTweaker-win-arm64-v1.0.0.zip'; browser_download_url = 'https://github.com/x/y.zip'; size = 10 }) }
        { Get-WtBootstrapAsset -Release $Release } | Should -Throw -ExpectedMessage 'PACKAGE:*'

        # LAUNCH: a missing entry point.
        { Invoke-WtBootstrapLaunch -PwshPath '' -EntryPoint (Join-Path $script:TestRoot 'nope.ps1') } | Should -Throw -ExpectedMessage 'LAUNCH:*'

        # RUNTIME: below the floor.
        { Assert-WtBootstrapRuntime -Version ([version]'4.0.30319.0') } | Should -Throw -ExpectedMessage 'RUNTIME:*'
    }

    It 'leaves the session alive and mirrors the code when the entry block fails' {
        $Text = Get-Content -LiteralPath $script:BootstrapPath -Raw
        $StateDir = Join-Path $script:TestRoot 'state-classified'
        $env:WT_BOOTSTRAP_STATE_DIR = $StateDir
        $env:WT_BOOTSTRAP_RELEASE_URL = 'http://invalid.example/bootstrap'
        $env:WT_BOOTSTRAP_ENTRYPOINT = 'C:\nonexistent\entry.ps1'
        $env:WT_BOOTSTRAP_NO_INSTALL = '1'
        Remove-Item Env:\WT_BOOTSTRAP_TEST_ONLY -ErrorAction Ignore
        try {
            $global:LASTEXITCODE = 0
            $Thrown = $null
            $Output = @()
            try {
                $Output = @(& ([scriptblock]::Create($Text)) 2>&1)
            } catch {
                $Thrown = $_
            }
            $Thrown | Should -BeNullOrEmpty
            $LASTEXITCODE | Should -Be 1
            # The failure is classified, and nothing is returned on the pipeline (the "1" that
            # used to be printed after the error is gone).
            (($Output | ForEach-Object { [string]$_ }) -join "`n") | Should -Match 'NETWORK:'
            $PipelineValues = @($Output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] -and ([string]$_).Trim() })
            $PipelineValues.Count | Should -Be 0
        } finally {
            Remove-Item Env:\WT_BOOTSTRAP_STATE_DIR, Env:\WT_BOOTSTRAP_RELEASE_URL, Env:\WT_BOOTSTRAP_ENTRYPOINT, Env:\WT_BOOTSTRAP_NO_INSTALL -ErrorAction Ignore
            $env:WT_BOOTSTRAP_TEST_ONLY = '1'
        }
    }
}
