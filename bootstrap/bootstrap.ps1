# WindowsTweaker launcher - the file the documented one-liner downloads.
#
# Usage (documented one-liner, Windows PowerShell 5.1 or PowerShell 7.4-7.6):
#   irm "https://raw.githubusercontent.com/88kbleirad/WindowsTweaker/main/bootstrap/bootstrap.ps1" | iex
#
# Usage (file; every option below is optional):
#   pwsh -NoProfile -File bootstrap/bootstrap.ps1 [-Language vi] [-Colour Auto] [-Ascii]
#        [-WorkerBackend Auto|Go|PowerShell] [-Icons Auto|Unicode|NerdFont|ASCII|None]
#        [-RuntimeMode auto|native|pwsh] [-NoInstall]
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File bootstrap/bootstrap.ps1
#
# `-ExecutionPolicy Bypass` is a per-process switch used to run a downloaded script on a
# machine whose policy is Restricted; it does not change the machine policy and nothing is
# written to it.
#
# ---- Why this file is ASCII-only, and why the implementation is a second file ----------
#
# `irm <url> | iex` hands the downloaded body to the parser as a *string*. A body that starts
# with a UTF-8 BOM is decoded by the HTTP stack into a leading U+FEFF, and PowerShell's parser
# then refuses the script's own attribute and param block: the first non-comment line reports
# `Unexpected attribute 'CmdletBinding'.`, the next reports `Unexpected token 'param' in
# expression or statement.`, and every parameter default below it cascades. Measured on
# PowerShell 7.6.9 in this repository (four parse errors; the same text without the leading
# U+FEFF parses cleanly) and reported on Windows PowerShell 5.1 against the published file,
# with the same line numbers.
#
# The full implementation needs its UTF-8 BOM: 5.1 decodes a BOM-less file with the ANSI code
# page and would corrupt every Vietnamese message in it. Those two requirements cannot both be
# met by one file, so:
#
#   * THIS file is the published launcher. It contains no byte above 0x7F, so it has no BOM to
#     lose, U+FEFF cannot appear in the text `iex` receives, and it parses on 5.1 and 7 alike.
#   * bootstrap/implementation.ps1 is the full installer (release selection, HTTPS/host/hash
#     verification, staging, runtime discovery and handoff, launch). It keeps its BOM.
#   * The launcher reads the implementation as *bytes* and decodes them as UTF-8 explicitly,
#     removing a leading U+FEFF when one is present, so neither the file's byte-order mark nor
#     the transport can reach the parser. It then executes the decoded text as a script block
#     in a child scope, which is the same execution mode as the old single-file bootstrap and
#     leaves nothing behind in the caller's session.
#
# Consequences of that split, stated because they are deliberate:
#
#   * The launcher's own messages (this file cannot carry Vietnamese) are English. Every
#     user-facing product message - runtime policy, release, integrity, launch - is produced by
#     the implementation and stays bilingual exactly as before.
#   * File execution runs the implementation beside this file, so a repository checkout, a
#     release review and an offline machine behave as before, with no download.
#   * Text execution has no file beside it, so it downloads the implementation from the same
#     pinned repository ref as this launcher, over HTTPS, from one hard-coded host. Redirects
#     are refused rather than followed, the body is bounded, and the decoded text must parse
#     and declare the launcher protocol this file expects. There is no unverified fallback: a
#     failure is reported and $LASTEXITCODE carries the code.
#
# This script is executed as *text* through Invoke-Expression in the one-liner form, so it must
# not rely on $PSScriptRoot, $PSCommandPath or the caller's working directory, it must never
# call exit(), and it must not leave a stray value on the pipeline. It removes the functions it
# defines from the caller's scope before returning; the only deliberate residue is
# $LASTEXITCODE.
#
# Compatibility: this file must parse and run on Windows PowerShell 5.1. tools/Test-Compatibility.ps1
# enforces that (PSScriptAnalyzer's Windows PowerShell 5.1 profile) and additionally enforces
# that this file stays pure ASCII with no BOM, because that is what makes the documented
# one-liner work.
#
# Overrides (for release engineering and tests):
#   WT_BOOTSTRAP_IMPLEMENTATION_PATH  run this local implementation file instead of downloading
#   WT_BOOTSTRAP_IMPLEMENTATION_URL   implementation URL (HTTPS, allowed hosts only)
#
# See docs/BOOTSTRAP.md for the full description of the install and launch flow.

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][ValidateSet('auto', 'native', 'pwsh')][string]$RuntimeMode = 'auto',
    [Parameter(Mandatory = $false)][string]$Language,
    [Parameter(Mandatory = $false)][string]$Colour,
    [Parameter(Mandatory = $false)][switch]$Ascii,
    [Parameter(Mandatory = $false)][ValidateSet('Auto', 'Go', 'PowerShell')][string]$WorkerBackend = 'Auto',
    [Parameter(Mandatory = $false)][ValidateSet('Auto', 'Unicode', 'NerdFont', 'ASCII', 'None')][string]$Icons = 'Auto',
    [Parameter(Mandatory = $false)][switch]$NoInstall
)

# Captured before any function below is defined: the entry block removes exactly the functions
# this script added, and never one the caller already had.
$WtBootstrapLauncherPreexistingFunctions = @(
    Get-ChildItem Function:\ -ErrorAction Ignore |
        Where-Object { $_.Name -like '*WtBootstrap*' } |
        ForEach-Object { $_.Name }
)

$Script:WtBootstrapLauncherRepository = '88kbleirad/WindowsTweaker'
$Script:WtBootstrapLauncherRef = 'main'
$Script:WtBootstrapLauncherImplementationName = 'implementation.ps1'
$Script:WtBootstrapLauncherImplementationUrl =
    "https://raw.githubusercontent.com/$($Script:WtBootstrapLauncherRepository)/$($Script:WtBootstrapLauncherRef)/bootstrap/$($Script:WtBootstrapLauncherImplementationName)"
$Script:WtBootstrapLauncherUserAgent = 'WindowsTweaker-bootstrap-launcher/1.0'
$Script:WtBootstrapLauncherTimeoutSeconds = 30
$Script:WtBootstrapLauncherMaxBytes = 4MB

# The pair contract: bootstrap/implementation.ps1 must declare this number. A mismatch means the
# two files are not from the same revision (a cached or foreign launcher, or a foreign
# implementation source), so the run is refused instead of executed half-blind.
$Script:WtBootstrapLauncherProtocol = 1

$Script:WtBootstrapLauncherAllowedHosts = @(
    'raw.githubusercontent.com'
    'github.com'
    'objects.githubusercontent.com'
    'release-assets.githubusercontent.com'
)

# ---- URL policy -------------------------------------------------------------------

<#
.SYNOPSIS
    Hosts the implementation may be downloaded from.
.DESCRIPTION
    One hard-coded URL is used by default; an explicit WT_BOOTSTRAP_IMPLEMENTATION_URL must
    still be HTTPS on one of these hosts, so the override cannot point the launcher at an
    arbitrary server. Redirects are refused rather than followed, which is why no redirect
    hosts are listed beyond the ones the pinned URL itself uses.
#>
function Get-WtBootstrapLauncherAllowedHosts
{
    return @($Script:WtBootstrapLauncherAllowedHosts)
}

<#
.SYNOPSIS
    Validates a URL: absolute, HTTPS, allowed host.
#>
function Assert-WtBootstrapLauncherUrl
{
    param ([Parameter(Mandatory = $true)][string]$Url)

    $Uri = $null
    if (-not [uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$Uri)) {
        throw "NETWORK: Refusing malformed URL: $Url"
    }
    if ($Uri.Scheme -ne 'https') {
        throw "NETWORK: Refusing non-HTTPS URL: $Url"
    }
    if ($Uri.Host -notin (Get-WtBootstrapLauncherAllowedHosts)) {
        throw "NETWORK: Host not allowed: $($Uri.Host)"
    }
    return $Uri
}

# ---- Transport --------------------------------------------------------------------

<#
.SYNOPSIS
    Reads a bounded HTTP response body into memory.
.DESCRIPTION
    Windows PowerShell 5.1 runs on .NET Framework, where HttpContent exposes only the
    asynchronous accessors: the synchronous ReadAsStream()/ReadAsString()/ReadAsByteArray()
    members arrived with .NET 5. Calling one there fails with
    "Method invocation failed because [System.Net.Http.StreamContent] does not contain a method
    named 'ReadAsStream'." The parameterless asynchronous form is therefore awaited here. The
    CancellationToken overload is deliberately not used: its availability on the .NET Framework
    build is not guaranteed.

    Failures name the stage and carry the original exception, so a download problem is reported
    as NETWORK - or as INTEGRITY when the size bound is hit - and never as a bare LAUNCH error.
    The body stream and the buffer are disposed on every path.

    This is deliberately a second copy of the implementation's reader: the launcher must work
    before the implementation exists, so it cannot borrow anything from it. The content is owned
    by the caller (it belongs to the response), so only the body stream and the buffer are
    disposed here.
#>
function Read-WtBootstrapLauncherContentBytes
{
    param (
        [Parameter(Mandatory = $true)][System.Net.Http.HttpContent]$Content,
        [Parameter(Mandatory = $false)][int]$MaxBytes = 0,
        [Parameter(Mandatory = $false)][string]$Source = 'the server'
    )

    $Stream = $null
    try {
        try {
            # .NET Framework has ReadAsStreamAsync() only (HttpContent.ReadAsStream() is .NET 5+).
            $Stream = $Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        } catch {
            throw "NETWORK: Download failed for $($Source) while opening the response body: $($_.Exception.GetBaseException().Message)"
        }

        $Buffer = [byte[]]::new(65536)
        $Memory = [System.IO.MemoryStream]::new()
        try {
            try {
                while (($Read = $Stream.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
                    if ($MaxBytes -gt 0 -and ($Memory.Length + $Read) -gt $MaxBytes) {
                        throw "INTEGRITY: The response from $($Source) exceeds the $MaxBytes byte limit."
                    }
                    $Memory.Write($Buffer, 0, $Read)
                }
            } catch {
                # Keep an already-classified failure (the size bound above) as it is; classify
                # anything else as a download failure at the reading stage.
                if ($_.Exception.Message -match '^(RUNTIME|NETWORK|INTEGRITY|PACKAGE|LAUNCH):') { throw }
                throw "NETWORK: Download failed for $($Source) while reading the response body: $($_.Exception.GetBaseException().Message)"
            }
            return $Memory.ToArray()
        } finally {
            $Memory.Dispose()
        }
    } finally {
        if ($Stream) { $Stream.Dispose() }
    }
}

<#
.SYNOPSIS
    Downloads the implementation as bytes.
.DESCRIPTION
    Bytes, never a decoded string: the decoding decision belongs to
    Convert-WtBootstrapLauncherImplementationText, so the byte-order mark can never reach the
    parser by accident. Redirects are refused (the pinned URL serves the file directly), the
    body is bounded, and TLS 1.2 is enabled for this request only because Windows PowerShell
    5.1 on an older Windows build may otherwise negotiate TLS 1.0; the process-wide setting is
    restored before returning.
#>
function Get-WtBootstrapLauncherImplementationBytes
{
    param ([Parameter(Mandatory = $true)][string]$Url)

    $Uri = Assert-WtBootstrapLauncherUrl -Url $Url

    # Loads System.Net.Http on Windows PowerShell 5.1 (it is part of .NET Framework 4.5).
    try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { $null = $_ }

    $SavedProtocol = [System.Net.ServicePointManager]::SecurityProtocol
    try {
        try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch { $null = $_ }

        # A failure anywhere below is a download failure: it names the stage it happened at
        # (client, send, redirect, status, body) and carries the original exception, so it is
        # never reported as a generic LAUNCH error.
        $Client = $null
        try {
            $Handler = [System.Net.Http.HttpClientHandler]::new()
            $Handler.AllowAutoRedirect = $false
            $Handler.AutomaticDecompression = [System.Net.DecompressionMethods]::None
            $Client = [System.Net.Http.HttpClient]::new($Handler)
            $Client.Timeout = [timespan]::FromSeconds($Script:WtBootstrapLauncherTimeoutSeconds)

            $null = $Client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', $Script:WtBootstrapLauncherUserAgent)

            $Request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Uri)
            $Response = $null
            try {
                $Response = $Client.SendAsync($Request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            } catch {
                $Request.Dispose()
                throw "NETWORK: Download of $($Uri.AbsoluteUri) failed while sending the request: $($_.Exception.GetBaseException().Message)"
            }

            try {
                $Status = [int]$Response.StatusCode
                if ($Status -in 301, 302, 303, 307, 308) {
                    throw "NETWORK: Refusing redirect ($Status) from $($Uri.AbsoluteUri); the implementation is served from one pinned URL."
                }
                if ($Status -ne 200) {
                    throw "NETWORK: HTTP $Status for $($Uri.AbsoluteUri)."
                }

                return (Read-WtBootstrapLauncherContentBytes -Content $Response.Content -MaxBytes $Script:WtBootstrapLauncherMaxBytes -Source $Uri.AbsoluteUri)
            } finally {
                $Response.Dispose()
                $Request.Dispose()
            }
        } catch {
            $Failure = $_.Exception.Message
            if ($Failure -match '^(RUNTIME|NETWORK|INTEGRITY|PACKAGE|LAUNCH):') { throw }
            throw "NETWORK: Download of $Url failed: $($_.Exception.GetBaseException().Message)"
        } finally {
            if ($Client) { $Client.Dispose() }
        }
    } finally {
        try { [System.Net.ServicePointManager]::SecurityProtocol = $SavedProtocol } catch { $null = $_ }
    }
}

# ---- Decoding and validation ------------------------------------------------------

<#
.SYNOPSIS
    Decodes implementation bytes as UTF-8 text without a leading U+FEFF.
.DESCRIPTION
    The decoding is explicit because the parser is not allowed to see whatever the transport
    decided: a UTF-8 BOM decodes to U+FEFF, and a text that starts with U+FEFF fails to parse
    when it declares an attribute and a param block. The marker is removed here, once, for the
    download path and for the local-file path alike, so no caller of this text depends on it.
#>
function Convert-WtBootstrapLauncherImplementationText
{
    param ([Parameter(Mandatory = $true)][byte[]]$Bytes)

    if ($Bytes.Length -eq 0) {
        throw 'INTEGRITY: The implementation content is empty.'
    }

    $Text = [System.Text.Encoding]::UTF8.GetString($Bytes)
    if ($Text.Length -gt 0 -and [int][char]$Text[0] -eq 0xFEFF) {
        $Text = $Text.Substring(1)
    }
    return $Text
}

<#
.SYNOPSIS
    Refuses text that is not a usable implementation.
.DESCRIPTION
    Two properties are checked before anything from the text is executed: it parses, and it
    declares the launcher protocol this launcher was written against. Both are cheap and both
    fail loudly, so a truncated download, a corrupted file or a mismatched pair is reported as
    an integrity failure instead of surfacing later as a confusing runtime error.
#>
function Assert-WtBootstrapLauncherImplementationText
{
    param (
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Source
    )

    $Tokens = $null
    $Errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$Tokens, [ref]$Errors)
    $ErrorList = @($Errors)
    if ($ErrorList.Count -gt 0) {
        throw ("INTEGRITY: The implementation from {0} does not parse ({1} error(s)); first: line {2}: {3}" -f
            $Source, $ErrorList.Count, $ErrorList[0].Extent.StartLineNumber, $ErrorList[0].Message)
    }

    $Match = [regex]::Match($Text, '(?m)^\s*\$Script:WtBootstrapLauncherProtocol\s*=\s*(\d+)\s*$')
    $Declared = 0
    if ($Match.Success) { $Declared = [int]$Match.Groups[1].Value }
    if ($Declared -ne $Script:WtBootstrapLauncherProtocol) {
        throw ("INTEGRITY: The implementation from {0} declares launcher protocol {1}; this launcher requires {2}. Re-run the documented one-liner to fetch a matching pair." -f
            $Source, $Declared, $Script:WtBootstrapLauncherProtocol)
    }
}

<#
.SYNOPSIS
    Produces the implementation text: from an explicit path, or downloaded.
.DESCRIPTION
    Precedence: WT_BOOTSTRAP_IMPLEMENTATION_PATH (explicit local file, for release engineering
    and tests), then WT_BOOTSTRAP_IMPLEMENTATION_URL, then the file beside this launcher (file
    execution of a checkout), then the pinned URL (text execution, which has no file beside it).
#>
function Get-WtBootstrapLauncherImplementationText
{
    param ([Parameter(Mandatory = $false)][string]$LocalPath)

    $Bytes = $null
    $Source = ''

    if ($env:WT_BOOTSTRAP_IMPLEMENTATION_PATH) {
        $Source = $env:WT_BOOTSTRAP_IMPLEMENTATION_PATH
        $Bytes = Read-WtBootstrapLauncherFile -Path $Source
    } elseif ($env:WT_BOOTSTRAP_IMPLEMENTATION_URL) {
        $Source = $env:WT_BOOTSTRAP_IMPLEMENTATION_URL
        $Bytes = Get-WtBootstrapLauncherImplementationBytes -Url $Source
    } elseif ($LocalPath) {
        $Source = $LocalPath
        $Bytes = Read-WtBootstrapLauncherFile -Path $Source
    } else {
        $Source = $Script:WtBootstrapLauncherImplementationUrl
        $Bytes = Get-WtBootstrapLauncherImplementationBytes -Url $Source
    }

    $Text = Convert-WtBootstrapLauncherImplementationText -Bytes $Bytes
    Assert-WtBootstrapLauncherImplementationText -Text $Text -Source $Source
    return $Text
}

<#
.SYNOPSIS
    Reads a local file as bytes, reporting a missing or unreadable file as a package failure.
#>
function Read-WtBootstrapLauncherFile
{
    param ([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "PACKAGE: The implementation file was not found: $Path"
    }
    try {
        return [System.IO.File]::ReadAllBytes($Path)
    } catch {
        throw "PACKAGE: The implementation file could not be read: $Path ($($_.Exception.Message))"
    }
}

# ---- Execution --------------------------------------------------------------------

<#
.SYNOPSIS
    Runs the implementation text and returns the code it mirrored into $LASTEXITCODE.
.DESCRIPTION
    A script block built from the text is the same execution mode the single-file bootstrap
    used: no $PSScriptRoot, no caller working directory, and the implementation's own
    $LASTEXITCODE self-check keeps working because it assigns the global. The block runs in a
    child scope, so nothing it defines survives; its return value is discarded on purpose - the
    only value a caller may observe is $LASTEXITCODE.
#>
function Invoke-WtBootstrapLauncherImplementation
{
    param (
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $false)][hashtable]$Argument = @{}
    )

    $Block = [scriptblock]::Create($Text)
    $global:LASTEXITCODE = 0
    $null = & $Block @Argument
    return [int]$global:LASTEXITCODE
}

# ---- Entry ------------------------------------------------------------------------

# Entry: run the launcher only when not dot-sourced for tests/authoring.
# No exit(); the code the implementation produced is mirrored into $LASTEXITCODE so the caller's
# session stays alive, and the functions this launcher defined are removed again.
if (-not $env:WT_BOOTSTRAP_TEST_ONLY) {
    $WtBootstrapLauncherExitCode = 0
    try {
        if ($PSVersionTable.PSVersion -lt [version]'5.1') {
            # English on purpose: this file carries no non-ASCII character, so it cannot print
            # the bilingual runtime message the implementation produces on a supported runtime.
            Write-Error -Message ("RUNTIME: WindowsTweaker requires Windows PowerShell 5.1 or PowerShell 7.4-7.6; this session runs PowerShell $($PSVersionTable.PSVersion). See https://github.com/$($Script:WtBootstrapLauncherRepository)") -ErrorAction Continue
            $WtBootstrapLauncherExitCode = 2
        } else {
            # File execution: the implementation shipped beside this launcher is authoritative.
            # Text execution ($PSScriptRoot is empty) falls through to the pinned URL.
            $WtBootstrapLauncherLocal = ''
            if ($PSScriptRoot) {
                $WtBootstrapLauncherCandidate = Join-Path -Path $PSScriptRoot -ChildPath $Script:WtBootstrapLauncherImplementationName
                if (Test-Path -LiteralPath $WtBootstrapLauncherCandidate -PathType Leaf) {
                    $WtBootstrapLauncherLocal = $WtBootstrapLauncherCandidate
                }
            }

            $WtBootstrapLauncherText = Get-WtBootstrapLauncherImplementationText -LocalPath $WtBootstrapLauncherLocal

            # Every option is forwarded explicitly; the implementation applies its own
            # environment fallbacks (WT_BOOTSTRAP_LANGUAGE, WT_BOOTSTRAP_ASCII, ...) for the ones
            # this caller did not pass, which is how options arrive through `irm | iex`.
            $WtBootstrapLauncherArgument = @{
                RuntimeMode   = $RuntimeMode
                Language      = $Language
                Colour        = $Colour
                Ascii         = [bool]$Ascii
                WorkerBackend = $WorkerBackend
                Icons         = $Icons
                NoInstall     = [bool]$NoInstall
            }

            $WtBootstrapLauncherExitCode = Invoke-WtBootstrapLauncherImplementation -Text $WtBootstrapLauncherText -Argument $WtBootstrapLauncherArgument
        }
    } catch {
        $Message = $_.Exception.Message
        if ($Message -notmatch '^(RUNTIME|NETWORK|INTEGRITY|PACKAGE|LAUNCH):') {
            $Message = "LAUNCH: $Message"
        }
        # Non-terminating on purpose: a caller whose $ErrorActionPreference is Stop would
        # otherwise have the launcher terminate their pipeline instead of receiving the code in
        # $LASTEXITCODE.
        Write-Error -Message $Message -ErrorAction Continue
        $WtBootstrapLauncherExitCode = 1
    } finally {
        foreach ($WtBootstrapLauncherFunction in @(Get-ChildItem Function:\ -ErrorAction Ignore |
            Where-Object { $_.Name -like '*WtBootstrap*' })) {
            if ($WtBootstrapLauncherFunction.Name -notin $WtBootstrapLauncherPreexistingFunctions) {
                Remove-Item -LiteralPath ('function:' + $WtBootstrapLauncherFunction.Name) -Force -ErrorAction Ignore
            }
        }
        Remove-Variable -Name WtBootstrapLauncherPreexistingFunctions -ErrorAction Ignore
        Remove-Variable -Name WtBootstrapLauncherCandidate, WtBootstrapLauncherLocal, WtBootstrapLauncherText, WtBootstrapLauncherArgument, WtBootstrapLauncherFunction -ErrorAction Ignore
    }
    $global:LASTEXITCODE = $WtBootstrapLauncherExitCode
    Remove-Variable -Name WtBootstrapLauncherExitCode -ErrorAction Ignore
}
