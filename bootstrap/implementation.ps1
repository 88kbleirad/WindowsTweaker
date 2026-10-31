# WindowsTweaker bootstrap implementation - the full installer, loaded by bootstrap/bootstrap.ps1.
#
# This file is NOT the documented entry point. The published launcher
# bootstrap/bootstrap.ps1 (pure ASCII, no BOM) is what `irm ... | iex` downloads; it reads this
# file as bytes, decodes it as UTF-8 explicitly, removes a leading U+FEFF, checks that the text
# parses and declares $Script:WtBootstrapLauncherProtocol, and then runs it as a script block in
# a child scope.
#
# The split exists because the two requirements cannot be met by one file:
#   * the body `irm | iex` receives must not start with U+FEFF - PowerShell's parser refuses the
#     attribute and param block of a text that begins with the decoded UTF-8 BOM (measured: four
#     parse errors starting at `Unexpected attribute 'CmdletBinding'.`);
#   * this file must keep its UTF-8 BOM, because Windows PowerShell 5.1 decodes a BOM-less file
#     with the ANSI code page and would corrupt every Vietnamese message below.
# See the launcher's header and docs/BOOTSTRAP.md.
#
# Usage (file; every option below is optional) - the same options the launcher accepts:
#   pwsh -NoProfile -File bootstrap/implementation.ps1 [-Language vi] [-Colour Auto] [-Ascii]
#        [-WorkerBackend Auto|Go|PowerShell] [-Icons Auto|Unicode|NerdFont|ASCII|None]
#        [-RuntimeMode auto|native|pwsh] [-NoInstall]
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File bootstrap/implementation.ps1
#
# `-ExecutionPolicy Bypass` is a per-process switch used to run a downloaded script on a
# machine whose policy is Restricted; it does not change the machine policy and nothing is
# written to it.
#
# Execution mode: the launcher executes this file as *text* through a script block, so it must
# not rely on $PSScriptRoot, $PSCommandPath or the caller's working directory, it must never call
# exit() in that mode, and it must not leave a stray value on the pipeline. It also removes the
# functions it defines from the caller's scope before returning; the only deliberate residue is
# $LASTEXITCODE. (Running this file directly with -File binds the parameters below the same way.)
#
# This file must parse and run on Windows PowerShell 5.1: no ternary operator, no
# null-coalescing, no pipeline chains, no 7-only cmdlet parameters, no .NET members that do
# not exist on .NET Framework. tools/Test-Compatibility.ps1 enforces that with
# PSScriptAnalyzer's Windows PowerShell 5.1 profile.
#
# Runtime policy (see docs/COMPATIBILITY.md):
#   * below 5.1        -> stopped before this file runs: the launcher checks the runtime first
#     (its message is English because that file is ASCII-only) and `#Requires -Version 5.1`
#     stops a direct file run; the session is left intact;
#   * Windows PowerShell 5.1 -> the release is staged and validated, then the application is
#     started on an installed compatible stable PowerShell 7 (7.4-7.6) when one exists -
#     after an explicit installation offer when it does not - and natively on 5.1 when the
#     user declines, cancels or cannot install. Native 5.1 execution is capability-gated;
#   * PowerShell 7.4-7.6 -> native, no second process;
#   * other PS7/preview -> native with a notice; preview builds are never selected
#     automatically by discovery.
#
# Responsibilities:
#   1. resolve a compatible stable GitHub Release (or an explicit release metadata URL);
#   2. select the exact asset for this OS/architecture (no fuzzy matching);
#   3. verify HTTPS and allowed redirect hosts, size, SHA-256, the package manifest, every
#      file hash it declares, and the worker protocol;
#   4. stage into an application-owned directory (traversal-safe extraction), marking the
#      staging complete only after validation passed;
#   5. start the interface on the best runtime, as a child process that inherits the
#      terminal, with no arguments beyond the ones the caller asked for. Starting the
#      interface applies no tweak.
#
# Security notes (documented, not hidden):
#   * A hash obtained from the same release provides integrity relative to that source; it is
#     NOT independent publisher authentication.
#   * No unverified fallback: if verification cannot complete, the bootstrap fails
#     explicitly, classified as RUNTIME, NETWORK, INTEGRITY, PACKAGE or LAUNCH.
#   * No elevation is requested to download or start the interface. Installing PowerShell
#     is a separate, explicitly confirmed action through winget; declining returns to the
#     shell. The console code page and TLS protocol setting are restored on every path.
#   * No execution policy is changed and no certificate validation is disabled.
#
# Overrides (for release engineering, tests and automation):
#   WT_BOOTSTRAP_RELEASE_URL   metadata JSON URL (default: the GitHub API release endpoint)
#   WT_BOOTSTRAP_STATE_DIR     staging/state directory
#   WT_BOOTSTRAP_ENTRYPOINT    force an entry point (tests / packaging validation)
#   WT_BOOTSTRAP_ALLOW_OFFLINE with one of the above, launch the validated cache without asking
#   WT_BOOTSTRAP_RUNTIME       auto (default) | native | pwsh
#   WT_BOOTSTRAP_NO_INSTALL    never offer to install PowerShell
#   WT_BOOTSTRAP_PWSH          explicit pwsh executable to launch (skips discovery)
#   WT_BOOTSTRAP_LANGUAGE      en | vi passed to the interface (WT_LANG is the fallback)
#   WT_BOOTSTRAP_COLOUR        Colour value passed to the interface
#   WT_BOOTSTRAP_TEST_ONLY     define the functions and skip the entry block (dot-source)
#
# The launcher adds two overrides of its own, documented in its header:
#   WT_BOOTSTRAP_IMPLEMENTATION_PATH  a local implementation file instead of the downloaded one
#   WT_BOOTSTRAP_IMPLEMENTATION_URL   an implementation URL (HTTPS, allowed hosts only)
#
# Canonical release layout - the single mapping between a release platform key and the
# worker path inside the archive. tools/New-ReleasePackage.ps1 reads this table from this
# file instead of keeping a second copy, and the shipped client resolves the same path:
#
#   platform key | os      | arch  | worker path inside the archive
#   win-x64      | windows | amd64 | worker/bin/windows-amd64/wt-worker.exe
#   win-arm64    | windows | arm64 | worker/bin/windows-arm64/wt-worker.exe
#   linux-x64    | linux   | amd64 | worker/bin/linux-amd64/wt-worker
#   linux-arm64  | linux   | arm64 | worker/bin/linux-arm64/wt-worker

#Requires -Version 5.1

[CmdletBinding()]
param
(
    [Parameter(Mandatory = $false)][ValidateSet('auto', 'native', 'pwsh')][string]$RuntimeMode = 'auto',
    [Parameter(Mandatory = $false)][string]$Language,
    [Parameter(Mandatory = $false)][string]$Colour,
    [Parameter(Mandatory = $false)][switch]$Ascii,
    [Parameter(Mandatory = $false)][ValidateSet('Auto', 'Go', 'PowerShell')][string]$WorkerBackend = 'Auto',
    [Parameter(Mandatory = $false)][ValidateSet('Auto', 'Unicode', 'NerdFont', 'ASCII', 'None')][string]$Icons = 'Auto',
    [Parameter(Mandatory = $false)][switch]$NoInstall
)

# Captured before any function below is defined: the entry block removes exactly the
# functions this script added, and never one the caller already had.
$WtBootstrapPreexistingFunctions = @(
    Get-ChildItem Function:\ -ErrorAction Ignore |
        Where-Object { $_.Name -like '*WtBootstrap*' } |
        ForEach-Object { $_.Name }
)

# The launcher protocol this file is written against. bootstrap/bootstrap.ps1 refuses any other
# number, so a cached or foreign launcher cannot execute an implementation it does not know, and
# a mixed pair is reported as an integrity failure with the fix (re-run the documented one-liner)
# instead of surfacing later as a confusing runtime error.
$Script:WtBootstrapLauncherProtocol = 1

$Script:WtBootstrapRepository = '88kbleirad/WindowsTweaker'
$Script:WtBootstrapUserAgent = 'WindowsTweaker-bootstrap/1.1'
$Script:WtBootstrapMaxRedirects = 10
$Script:WtBootstrapMinimumVersion = [version]'5.1'
$Script:WtBootstrapSupportedVersion = [version]'7.4'
$Script:WtBootstrapTestedMaximum = [version]'7.6'
$Script:WtBootstrapTestedMaximumExclusive = [version]'7.7'
$Script:WtBootstrapTestedVersion = [version]'7.6.9'

# ---- Runtime detection (5.1-safe; no $IsWindows) ---------------------------------

<#
.SYNOPSIS
    Returns the host runtime facts this bootstrap makes decisions on.
.DESCRIPTION
    $IsWindows/$IsLinux/$IsMacOS do not exist in Windows PowerShell 5.1; they are read
    through Get-Variable, so this file still works there, and .NET Framework answers for
    the platform. The numeric version is parsed from the version string, because PowerShell 7
    preview builds report a semantic version that [version] cannot parse.
#>
function Get-WtBootstrapRuntimeProfile {
    $Version = $PSVersionTable.PSVersion
    $Edition = 'Desktop'
    if ($PSVersionTable.PSEdition) { $Edition = [string]$PSVersionTable.PSEdition }
    $IsCore = ($Edition -eq 'Core')

    $Platform = 'Unknown'
    $WindowsVariable = Get-Variable -Name 'IsWindows' -ValueOnly -ErrorAction Ignore
    if ($null -ne $WindowsVariable) {
        if ($WindowsVariable) {
            $Platform = 'Windows'
        } elseif (Get-Variable -Name 'IsLinux' -ValueOnly -ErrorAction Ignore) {
            $Platform = 'Linux'
        } else {
            $Platform = 'MacOS'
        }
    } else {
        try {
            if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { $Platform = 'Windows' }
        } catch {
            $null = $_
        }
    }

    $RawVersion = [string]$Version
    $Numeric = ($RawVersion -split '-')[0]
    $Parsed = $null
    if (-not [version]::TryParse($Numeric, [ref]$Parsed)) { $Parsed = $Version }

    $PreRelease = ''
    try {
        if ($Version.PreReleaseLabel) { $PreRelease = [string]$Version.PreReleaseLabel }
    } catch {
        $PreRelease = ''
    }
    if ($RawVersion -match '-') { $PreRelease = $RawVersion }

    $Tier = 'Untested'
    if ($Parsed -lt $Script:WtBootstrapMinimumVersion) {
        $Tier = 'Unsupported'
    } elseif (-not $IsCore) {
        $Tier = 'WindowsPowerShell'
    } elseif ($PreRelease) {
        $Tier = 'Preview'
    } elseif ($Parsed -ge $Script:WtBootstrapSupportedVersion -and $Parsed -lt $Script:WtBootstrapTestedMaximumExclusive) {
        $Tier = 'Supported'
    }

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.BootstrapRuntime'
        Version    = $Parsed
        RawVersion = $RawVersion
        PSEdition  = $Edition
        IsCore     = $IsCore
        Platform   = $Platform
        IsWindows  = ($Platform -eq 'Windows')
        IsLinux    = ($Platform -eq 'Linux')
        IsMacOS    = ($Platform -eq 'MacOS')
        PreRelease = $PreRelease
        Tier       = $Tier
        MinimumVersion    = $Script:WtBootstrapMinimumVersion
        SupportedVersion  = $Script:WtBootstrapSupportedVersion
        TestedMaximum     = $Script:WtBootstrapTestedMaximum
        TestedVersion     = $Script:WtBootstrapTestedVersion
    }
}

<#
.SYNOPSIS
    Refuses a runtime older than the floor.
.DESCRIPTION
    A runtime below Windows PowerShell 5.1 cannot run the application at all, so this is the
    only version check that throws. It is a function so the check itself is testable without
    an old host.
.PARAMETER Version
    Version to check. Defaults to the running session's.
#>
function Assert-WtBootstrapRuntime {
    param ([Parameter(Mandatory = $false)][version]$Version = $PSVersionTable.PSVersion)

    if ($Version -lt $Script:WtBootstrapMinimumVersion) {
        throw "RUNTIME: WindowsTweaker needs PowerShell $($Script:WtBootstrapMinimumVersion) or newer; this session is PowerShell $Version."
    }
}

<#
.SYNOPSIS
    Reports whether a version is a supported stable PowerShell 7.
.DESCRIPTION
    Only the range this project has evidence for: 7.4 through 7.6. A 7.7 preview, a future
    major version and an untested minor are never selected automatically.
#>
function Test-WtBootstrapCompatibleVersion {
    param (
        [Parameter(Mandatory = $true)][version]$Version,
        [Parameter(Mandatory = $false)][string]$PreRelease = ''
    )

    if ($PreRelease) { return $false }
    return ($Version -ge $Script:WtBootstrapSupportedVersion -and $Version -lt $Script:WtBootstrapTestedMaximumExclusive)
}

# ---- Bilingual messages -----------------------------------------------------------
# Inline on purpose: the bootstrap runs before anything is downloaded, so it cannot use the
# module's string tables. Vietnamese first (the project's default interface language), then
# English; the English half is what a console with a legacy code page can still read.

$Script:WtBootstrapMessages = @{
    'UnsupportedRuntime' = @{
        vi = 'WindowsTweaker cần PowerShell {0} trở lên. Phiên hiện tại là PowerShell {1}. Hãy mở PowerShell {0} hoặc mới hơn rồi chạy lại lệnh.'
        en = 'WindowsTweaker needs PowerShell {0} or newer. This session is PowerShell {1}. Start PowerShell {0} or newer and run the command again.'
    }
    'Handoff' = @{
        vi = 'Đang chuyển sang PowerShell {0}: {1}'
        en = 'Handing off to PowerShell {0}: {1}'
    }
    'NativeWindowsPowerShell' = @{
        vi = 'Không tìm thấy PowerShell {1} tương thích, tiếp tục chạy trực tiếp trên Windows PowerShell {0}. Một số tính năng có thể bị hạn chế; xem báo cáo bằng: {2}'
        en = 'No compatible PowerShell {1} was found; continuing natively on Windows PowerShell {0}. Some features may be limited; see the report with: {2}'
    }
    'InstallOffer' = @{
        vi = 'Có thể cài PowerShell {0} (Microsoft.PowerShell) bằng winget để dùng đầy đủ tính năng. Cài ngay? [y/N] '
        en = 'PowerShell {0} (Microsoft.PowerShell) can be installed with winget for full capability. Install now? [y/N] '
    }
    'InstallStarting' = @{
        vi = 'Đang cài PowerShell bằng winget. Quá trình này có thể hỏi quyền quản trị; từ chối sẽ quay lại shell an toàn.'
        en = 'Installing PowerShell with winget. It may ask for elevation; declining returns to the shell safely.'
    }
    'InstallFailed' = @{
        vi = 'Cài đặt không thành công (mã {0}). Không thay đổi gì thêm; shell vẫn hoạt động.'
        en = 'Installation did not succeed (exit code {0}). Nothing else was changed; the shell is intact.'
    }
    'InstallCancelled' = @{
        vi = 'Đã hủy cài đặt. Không có thay đổi nào được thực hiện.'
        en = 'Installation cancelled. Nothing was changed.'
    }
    'ManualInstall' = @{
        vi = 'Cài thủ công từ nguồn chính thức của Microsoft: {0} (chọn gói đúng kiến trúc), hoặc chạy: winget install --id Microsoft.PowerShell --exact --source winget'
        en = 'Install manually from the official Microsoft source: {0} (pick the package for this architecture), or run: winget install --id Microsoft.PowerShell --exact --source winget'
    }
    'WingetMissing' = @{
        vi = 'winget không có trên máy này (ví dụ Windows IoT LTSC). Hãy cài PowerShell {0} theo hướng dẫn thủ công.'
        en = 'winget is not available on this machine (for example Windows IoT LTSC). Install PowerShell {0} using the manual instructions.'
    }
    'NativeForced' = @{
        vi = 'Đang chạy trực tiếp trên PowerShell {0} theo yêu cầu (WT_BOOTSTRAP_RUNTIME=native).'
        en = 'Running natively on PowerShell {0} as requested (WT_BOOTSTRAP_RUNTIME=native).'
    }
    'PwshRequired' = @{
        vi = 'Chế độ này yêu cầu PowerShell {0}. Không tìm thấy bản cài đặt tương thích và không cài đặt thêm.'
        en = 'This mode requires PowerShell {0}. No compatible installation was found and nothing was installed.'
    }
    'HandoffDepth' = @{
        vi = 'Đã chuyển runtime {0} lần; dừng chuyển tiếp để tránh vòng lặp và chạy trực tiếp tại đây.'
        en = 'Runtime was handed off {0} time(s); stopping the chain to avoid a loop and running here.'
    }
}

<#
.SYNOPSIS
    Returns one bilingual message, or the English text when Vietnamese is unavailable.
#>
function Get-WtBootstrapMessage {
    param (
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)][object[]]$Argument = @(),
        [Parameter(Mandatory = $false)][switch]$EnglishOnly
    )

    $Entry = $Script:WtBootstrapMessages[$Name]
    if (-not $Entry) { return $Name }

    $English = $Entry.en
    if ($Argument.Count -gt 0) { $English = $English -f $Argument }
    if ($EnglishOnly -or -not $Entry.vi) { return $English }

    $Vietnamese = $Entry.vi
    if ($Argument.Count -gt 0) {
        try { $Vietnamese = $Vietnamese -f $Argument } catch { $Vietnamese = $Entry.vi }
    }
    return ($Vietnamese + [System.Environment]::NewLine + $English)
}

<#
.SYNOPSIS
    Writes a bilingual message to the host, never to the pipeline.
#>
function Write-WtBootstrapMessage {
    param (
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)][object[]]$Argument = @(),
        [Parameter(Mandatory = $false)][switch]$ToError
    )

    $Text = Get-WtBootstrapMessage -Name $Name -Argument $Argument
    if ($ToError) {
        foreach ($Line in @($Text -split "`r?`n")) {
            if ($Line) { $Host.UI.WriteErrorLine($Line) }
        }
        return
    }
    Write-Host $Text
}

# ---- Console encoding -------------------------------------------------------------

<#
.SYNOPSIS
    Switches the console to UTF-8 for the messages and the child interface, remembering the
    previous encoding so it can be restored.
#>
function Enter-WtBootstrapConsole {
    $State = @{ OutputEncoding = $null; Changed = $false }
    try {
        $State.OutputEncoding = [Console]::OutputEncoding
        if ([Console]::OutputEncoding -and [Console]::OutputEncoding.WebName -notmatch 'utf') {
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
            $State.Changed = $true
        }
    } catch {
        # A host without a console (a redirected run) keeps whatever it had.
        $State.Changed = $false
    }
    return $State
}

<#
.SYNOPSIS
    Restores the console encoding captured by Enter-WtBootstrapConsole.
#>
function Restore-WtBootstrapConsole {
    param ([Parameter(Mandatory = $false)][object]$State)

    if (-not $State) { return }
    if ($State.Changed -and $State.OutputEncoding) {
        try {
            [Console]::OutputEncoding = $State.OutputEncoding
        } catch {
            $null = $_
        }
    }
}

# ---- Runtime discovery ------------------------------------------------------------

<#
.SYNOPSIS
    Probes one candidate executable and classifies it.
.DESCRIPTION
    The candidate is executed with a fixed non-interactive command; its file name is never
    trusted. A preview build is reported but never selected.
#>
function Read-WtBootstrapPwshCandidate {
    param ([Parameter(Mandatory = $true)][string]$Path)

    $Result = [pscustomobject]@{
        PSTypeName   = 'WindowsTweaker.BootstrapPwshCandidate'
        Path         = $Path
        Version      = $null
        Edition      = ''
        Architecture = ''
        Preview      = $false
        Compatible   = $false
        Selected     = $false
        Reason       = ''
    }

    $Probe = '"[{0}]|{1}|{2}" -f $PSVersionTable.PSVersion.ToString(), $PSVersionTable.PSEdition, $env:PROCESSOR_ARCHITECTURE'
    $Output = @()
    try {
        $Output = @(& $Path -NoProfile -NonInteractive -Command $Probe 2>$null)
    } catch {
        $Result.Reason = "Could not be started: $($_.Exception.Message)"
        return $Result
    }

    $Line = ''
    foreach ($Item in $Output) {
        if ($Item -and ([string]$Item).Trim()) { $Line = [string]$Item; break }
    }
    if ($Line -notmatch '^\[(?<v>[^\]]+)\]\|(?<e>[^|]*)\|(?<a>.*)$') {
        $Result.Reason = 'Did not report a version.'
        return $Result
    }

    $RawVersion = $Matches['v']
    $IsPreview = ($RawVersion -match '-') -or ($Path -match '(?i)preview')
    $Version = $null
    if (-not [version]::TryParse(($RawVersion -split '-')[0], [ref]$Version)) {
        $Result.Reason = "Reported an unparsable version '$RawVersion'."
        return $Result
    }

    $Result.Version = $Version
    $Result.Edition = $Matches['e']
    $Result.Architecture = $Matches['a']
    $Result.Preview = [bool]$IsPreview

    if ($Result.Preview) {
        $Result.Reason = 'Preview build: never selected automatically.'
        return $Result
    }
    if (-not (Test-WtBootstrapCompatibleVersion -Version $Version)) {
        $Result.Reason = "PowerShell $Version is outside the supported stable range ($($Script:WtBootstrapSupportedVersion)-$($Script:WtBootstrapTestedMaximum))."
        return $Result
    }

    $Result.Compatible = $true
    $Result.Selected = $true
    $Result.Reason = 'Stable, compatible build.'
    return $Result
}

<#
.SYNOPSIS
    Finds installed pwsh executables in PATH and the documented locations.
.DESCRIPTION
    PATH first, then the documented installation directories (Program Files, the Store
    alias, the usual Linux/macOS paths). Symlinks and Store aliases are resolved so one
    installation is probed once. Every candidate is probed by running it.
#>
function Get-WtBootstrapPwshCandidates {
    $RuntimeProfile = Get-WtBootstrapRuntimeProfile
    $Candidates = [System.Collections.Generic.List[string]]::new()

    foreach ($Explicit in @($env:WT_BOOTSTRAP_PWSH)) {
        if ($Explicit) { $Candidates.Add($Explicit) }
    }

    foreach ($Command in @(Get-Command -Name 'pwsh' -CommandType Application -ErrorAction Ignore)) {
        if ($Command -and $Command.Source) { $Candidates.Add([string]$Command.Source) }
    }

    if ($RuntimeProfile.IsWindows) {
        $Roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)
        foreach ($Root in $Roots) {
            if (-not $Root) { continue }
            $Candidates.Add((Join-Path $Root 'PowerShell\7\pwsh.exe'))
            $Candidates.Add((Join-Path $Root 'PowerShell\7-preview\pwsh.exe'))
            $Candidates.Add((Join-Path $Root 'Microsoft\WindowsApps\pwsh.exe'))
        }
    } else {
        foreach ($Location in @(
                '/usr/bin/pwsh', '/usr/local/bin/pwsh', '/opt/microsoft/powershell/7/pwsh',
                '/snap/bin/pwsh', '/opt/homebrew/bin/pwsh', '/usr/local/microsoft/powershell/7/pwsh')) {
            $Candidates.Add($Location)
        }
    }

    $Seen = @{}
    $Results = @()
    foreach ($Candidate in $Candidates) {
        $Full = [string]$Candidate
        if (-not $Full) { continue }
        try { $Full = [System.IO.Path]::GetFullPath($Full) } catch { continue }
        if (-not (Test-Path -LiteralPath $Full -PathType Leaf)) { continue }

        $Identity = $Full
        try {
            $Item = Get-Item -LiteralPath $Full -ErrorAction Ignore
            if ($Item -and $Item.PSObject.Properties['Target'] -and $Item.Target) {
                $Identity = [System.IO.Path]::GetFullPath([string]$Item.Target)
            }
        } catch {
            $null = $_
        }
        if ($Seen.ContainsKey($Identity)) { continue }
        $Seen[$Identity] = $true

        $Results += (Read-WtBootstrapPwshCandidate -Path $Full)
    }

    return @($Results)
}

<#
.SYNOPSIS
    Selects the pwsh to use: highest compatible version, PATH first among equals.
#>
function Select-WtBootstrapPwsh {
    param ([Parameter(Mandatory = $false)][object[]]$Candidate)

    $Candidates = @($Candidate)
    if ($Candidates.Count -eq 0) { $Candidates = @(Get-WtBootstrapPwshCandidates) }

    $Best = $null
    foreach ($Item in $Candidates) {
        if (-not $Item.Compatible) { continue }
        if ($null -eq $Best -or $Item.Version -gt $Best.Version) { $Best = $Item }
    }
    foreach ($Item in $Candidates) {
        if ($Item.Selected -and $Best -and $Item.Path -ne $Best.Path) {
            $Item.Selected = $false
            $Item.Reason = "PowerShell $($Best.Version) was selected."
        }
    }
    return $Best
}

# ---- Installation (winget, with consent) ------------------------------------------

<#
.SYNOPSIS
    Returns the winget command, or $null when it is not installed.
.DESCRIPTION
    Windows IoT LTSC and Server Core images have no App Installer, so the caller must always
    have a manual path; this function never throws.
#>
function Find-WtBootstrapWinget {
    $Command = Get-Command -Name 'winget' -CommandType Application -ErrorAction Ignore | Select-Object -First 1
    if (-not $Command) { return $null }
    return [string]$Command.Source
}

<#
.SYNOPSIS
    Offers to install PowerShell with winget, after explicit consent.
.DESCRIPTION
    Never installs without a 'yes', never elevates by itself (winget may ask, and declining
    its prompt is handled as a failure), never falls back to downloading and running an
    installer. After a successful install the executable is discovered again from the
    documented locations, because PATH in this session was captured before the install.
.OUTPUTS
    The selected candidate after a successful install, or $null.
#>
function Invoke-WtBootstrapInstallOffer {
    param ([Parameter(Mandatory = $false)][switch]$NoInstall)

    $Winget = Find-WtBootstrapWinget
    if (-not $Winget) {
        Write-WtBootstrapMessage -Name 'WingetMissing' -Argument @($Script:WtBootstrapSupportedVersion)
        Write-WtBootstrapMessage -Name 'ManualInstall' -Argument @('https://aka.ms/powershell-release?tag=stable')
        return $null
    }

    if ($NoInstall) {
        Write-WtBootstrapMessage -Name 'ManualInstall' -Argument @('https://aka.ms/powershell-release?tag=stable')
        return $null
    }

    # One question, both languages, default no. A non-interactive host cannot answer, so it
    # is treated as a decline instead of hanging.
    $Prompt = Get-WtBootstrapMessage -Name 'InstallOffer' -Argument @($Script:WtBootstrapSupportedVersion)
    $Answer = ''
    try {
        $Answer = [string](Read-Host -Prompt $Prompt)
    } catch {
        $Answer = ''
    }
    $Answer = $Answer.Trim().ToLowerInvariant()
    if ($Answer -notin 'y', 'yes', 'c', 'co') {
        Write-WtBootstrapMessage -Name 'InstallCancelled'
        Write-WtBootstrapMessage -Name 'ManualInstall' -Argument @('https://aka.ms/powershell-release?tag=stable')
        return $null
    }

    Write-WtBootstrapMessage -Name 'InstallStarting'
    $ExitCode = 1
    try {
        & $Winget install --id Microsoft.PowerShell --exact --source winget --accept-source-agreements --accept-package-agreements --silent
        # winget is a native executable, which sets $LASTEXITCODE; a scripted stand-in does
        # not, so $? decides first and the numeric code is used when it exists.
        if ($?) {
            $ExitCode = 0
        } elseif ($LASTEXITCODE) {
            $ExitCode = [int]$LASTEXITCODE
        }
    } catch {
        $ExitCode = 1
    }

    if ($ExitCode -ne 0) {
        Write-WtBootstrapMessage -Name 'InstallFailed' -Argument @($ExitCode) -ToError
        Write-WtBootstrapMessage -Name 'ManualInstall' -Argument @('https://aka.ms/powershell-release?tag=stable')
        return $null
    }

    # Do not trust PATH: it was captured before the installation.
    $Installed = Select-WtBootstrapPwsh -Candidate @(Get-WtBootstrapPwshCandidates)
    if (-not $Installed) {
        Write-WtBootstrapMessage -Name 'InstallFailed' -Argument @($ExitCode) -ToError
        Write-WtBootstrapMessage -Name 'ManualInstall' -Argument @('https://aka.ms/powershell-release?tag=stable')
        return $null
    }
    return $Installed
}

# ---- HTTP ------------------------------------------------------------------------

<#
.SYNOPSIS
    Hosts a release download may come from or redirect to.
.DESCRIPTION
    github.com serves the release page URL and answers with a 302 to the asset host;
    release-assets.githubusercontent.com is that host today, and the two historical hosts are
    kept so an older redirect chain is not refused. Every hop is checked against this list.
#>
function Get-WtBootstrapAllowedHosts {
    return @(
        'github.com'
        'api.github.com'
        'raw.githubusercontent.com'
        'codeload.github.com'
        'objects.githubusercontent.com'
        'github-releases.githubusercontent.com'
        'release-assets.githubusercontent.com'
    )
}

<#
.SYNOPSIS
    Validates a URL: absolute, HTTPS, allowed host.
#>
function Assert-WtBootstrapUrl {
    param ([Parameter(Mandatory = $true)][string]$Url)

    $Uri = $null
    if (-not [uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$Uri)) {
        throw "NETWORK: Refusing malformed URL: $Url"
    }
    if ($Uri.Scheme -ne 'https') {
        throw "NETWORK: Refusing non-HTTPS URL: $Url"
    }
    if ($Uri.Host -notin (Get-WtBootstrapAllowedHosts)) {
        throw "NETWORK: Host not allowed: $($Uri.Host)"
    }
    return $Uri
}

<#
.SYNOPSIS
    Resolves and validates one redirect hop.
#>
function Resolve-WtBootstrapRedirectTarget {
    param (
        [Parameter(Mandatory = $true)][uri]$Base,
        [Parameter(Mandatory = $false)][string]$Location,
        [Parameter(Mandatory = $true)][string]$SourceUrl
    )

    if (-not $Location) {
        throw "NETWORK: Redirect without Location header from $SourceUrl."
    }
    $Target = $Location
    if ($Location -notmatch '^[A-Za-z][A-Za-z0-9+.\-]*://') {
        $Target = ([uri]::new($Base, $Location)).AbsoluteUri
    }
    $null = Assert-WtBootstrapUrl -Url $Target
    return $Target
}

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

    Every failure names the stage and carries the original exception, so a download problem is
    reported as NETWORK - or as INTEGRITY when the size bound is hit - instead of surfacing as
    an unexplained LAUNCH error. The body stream and the buffer are disposed on every path,
    including the failure path.

    The parameters are explicit (rather than reading the caller's variables) so the same code
    can be driven by a test with a real HttpContent. The content is owned by the caller - it
    belongs to the response, which the caller disposes - so only the body stream and the buffer
    are disposed here.
#>
function Read-WtBootstrapContentBytes {
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
    Downloads a URL with strict HTTPS + allowed-host redirect validation.
.DESCRIPTION
    Redirects are followed manually so every hop is checked. TLS 1.2 is enabled for this
    download only: Windows PowerShell 5.1 on an older Windows build may otherwise negotiate
    TLS 1.0 and fail; the process-wide setting is restored by the caller.
#>
function Get-WtBootstrapContent {
    param (
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $false)][int]$MaxBytes = 0
    )

    $null = Assert-WtBootstrapUrl -Url $Url

    # Loads System.Net.Http on Windows PowerShell 5.1 (it is part of .NET Framework 4.5).
    try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { $null = $_ }

    # A failure anywhere in this block is a download failure: it names the stage it happened at
    # (client, send, redirect, status, body) and carries the original exception, so it is never
    # reported as a generic LAUNCH error.
    $Client = $null
    try {
        $Handler = [System.Net.Http.HttpClientHandler]::new()
        $Handler.AllowAutoRedirect = $false
        $Handler.AutomaticDecompression = [System.Net.DecompressionMethods]::None
        $Client = [System.Net.Http.HttpClient]::new($Handler)
        $Client.Timeout = [timespan]::FromSeconds(30)

        $null = $Client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', $Script:WtBootstrapUserAgent)

        $Redirects = 0
        $Current = $Url
        while ($true) {
            $Uri = Assert-WtBootstrapUrl -Url $Current
            $Request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Uri)
            $Response = $null
            try {
                $Response = $Client.SendAsync($Request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            } catch {
                $Request.Dispose()
                throw "NETWORK: Download of $($Uri.AbsoluteUri) failed while sending the request: $($_.Exception.GetBaseException().Message)"
            }

            $Status = [int]$Response.StatusCode
            if ($Status -in 301, 302, 303, 307, 308) {
                $Location = ''
                if ($Response.Headers.Location) { $Location = $Response.Headers.Location.OriginalString }
                $Response.Dispose()
                $Request.Dispose()
                if ($Redirects -ge $Script:WtBootstrapMaxRedirects) {
                    throw "NETWORK: Too many redirects (limit $($Script:WtBootstrapMaxRedirects)) for $Url."
                }
                $Current = Resolve-WtBootstrapRedirectTarget -Base $Uri -Location $Location -SourceUrl $Current
                $Redirects++
                continue
            }

            try {
                if ($Status -ne 200) {
                    throw "NETWORK: HTTP $Status for $($Uri.AbsoluteUri)."
                }
                return (Read-WtBootstrapContentBytes -Content $Response.Content -MaxBytes $MaxBytes -Source $Uri.AbsoluteUri)
            } finally {
                $Response.Dispose()
                $Request.Dispose()
            }
        }
    } catch {
        $Failure = $_.Exception.Message
        if ($Failure -match '^(RUNTIME|NETWORK|INTEGRITY|PACKAGE|LAUNCH):') { throw }
        throw "NETWORK: Download of $Url failed: $($_.Exception.GetBaseException().Message)"
    } finally {
        if ($Client) { $Client.Dispose() }
    }
}

<#
.SYNOPSIS
    Fetches the release metadata (GitHub API or explicit override URL).
#>
function Get-WtBootstrapRelease {
    $ReleaseUrl = "https://api.github.com/repos/$($Script:WtBootstrapRepository)/releases/latest"
    if ($env:WT_BOOTSTRAP_RELEASE_URL) { $ReleaseUrl = $env:WT_BOOTSTRAP_RELEASE_URL }

    $Bytes = Get-WtBootstrapContent -Url $ReleaseUrl -MaxBytes 2MB
    try {
        $Json = [System.Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json
    } catch {
        throw "PACKAGE: Release metadata from $ReleaseUrl is not valid JSON: $($_.Exception.Message)"
    }
    if (-not $Json.tag_name) { throw 'PACKAGE: Release metadata is missing tag_name.' }
    if (-not $Json.assets) { throw 'PACKAGE: Release metadata has no assets.' }
    return $Json
}

<#
.SYNOPSIS
    Selects the exact asset for the current platform; unambiguous.
#>
function Get-WtBootstrapAsset {
    param ([Parameter(Mandatory = $true)][object]$Release)

    $Key = Get-WtBootstrapPlatformKey
    $Tag = [string]$Release.tag_name
    $Assets = @($Release.assets)
    if ($Assets.Count -eq 0) { throw 'PACKAGE: Release has no assets.' }

    $Candidate = @()
    foreach ($Asset in $Assets) {
        if ($Asset.name -eq "WindowsTweaker-$Key.zip" -or $Asset.name -match "^WindowsTweaker-$([regex]::Escape($Key))-(.+\.zip)$") {
            $Candidate += $Asset
        }
    }
    if ($Candidate.Count -eq 0) {
        $Names = ($Assets | ForEach-Object { $_.name }) -join ', '
        throw "PACKAGE: No asset for platform '$Key' in release $Tag (assets: $Names)."
    }
    if ($Candidate.Count -gt 1) {
        $Versioned = @($Candidate | Where-Object { $_.name -match '-v?[0-9]+\.[0-9]+\.[0-9]+[^/]*\.zip$' })
        if ($Versioned.Count -eq 1) { return $Versioned[0] }
        $Names = ($Candidate | ForEach-Object { $_.name }) -join ', '
        throw "PACKAGE: Ambiguous asset selection for '$Key': $Names."
    }
    $Selected = $Candidate[0]
    if ($Selected.PSObject.Properties['platform'] -and [string]$Selected.platform -ne $Key) {
        throw "PACKAGE: Asset '$($Selected.name)' declares platform '$($Selected.platform)', not '$Key'."
    }
    return $Selected
}

<#
.SYNOPSIS
    Downloads the asset to memory and verifies its size.
#>
function Get-WtBootstrapAssetBytes {
    param ([Parameter(Mandatory = $true)][object]$Asset)

    $Url = [string]$Asset.browser_download_url
    if (-not $Url) { throw 'PACKAGE: Asset has no browser_download_url.' }
    $Size = [long]$Asset.size
    if ($Size -le 0) { throw "PACKAGE: Asset '$($Asset.name)' has no published size; refusing an uncapped download." }
    $Bytes = Get-WtBootstrapContent -Url $Url -MaxBytes ([math]::Max(1, $Size + 1MB))
    if ($Bytes.Length -ne $Size) {
        throw "INTEGRITY: Asset size mismatch: expected $Size, got $($Bytes.Length)."
    }
    return $Bytes
}

<#
.SYNOPSIS
    Parses sha256sum-style text into a file-name -> hash table.
#>
function Read-WtBootstrapChecksums {
    param ([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $Map = @{}
    foreach ($Line in @($Text -split "`r?`n")) {
        if ($Line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
            $Name = [System.IO.Path]::GetFileName($Matches[2].Trim())
            if ($Name) { $Map[$Name.ToLowerInvariant()] = $Matches[1].ToLowerInvariant() }
        }
    }
    return $Map
}

<#
.SYNOPSIS
    Finds the expected SHA-256 for an asset from the same release's checksums asset.
#>
function Get-WtBootstrapExpectedHash {
    param (
        [Parameter(Mandatory = $true)][object]$Release,
        [Parameter(Mandatory = $true)][object]$Asset
    )

    $ChecksumAsset = $null
    foreach ($Item in @($Release.assets)) {
        if ($Item.name -match '(?i)^checksums?\.txt$') { $ChecksumAsset = $Item; break }
    }
    if (-not $ChecksumAsset) { return '' }

    $Bytes = Get-WtBootstrapContent -Url ([string]$ChecksumAsset.browser_download_url) -MaxBytes 1MB
    $Map = Read-WtBootstrapChecksums -Text ([System.Text.Encoding]::UTF8.GetString($Bytes))
    $Name = [System.IO.Path]::GetFileName([string]$Asset.name).ToLowerInvariant()
    if ($Map.ContainsKey($Name)) { return $Map[$Name] }
    return ''
}

<#
.SYNOPSIS
    Verifies the asset's SHA-256 against the same-release checksum.
#>
function Test-WtBootstrapHash {
    param (
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$ExpectedHash
    )

    $Stream = [System.IO.MemoryStream]::new($Bytes)
    try {
        $Hash = (Get-FileHash -InputStream $Stream -Algorithm SHA256).Hash.ToLowerInvariant()
    } finally {
        $Stream.Dispose()
    }
    if ($Hash -ne $ExpectedHash.ToLowerInvariant()) {
        throw "INTEGRITY: SHA-256 mismatch (expected $ExpectedHash, got $Hash)."
    }
}

# ---- Package layout and validation ------------------------------------------------

# Loads the archive assemblies on Windows PowerShell 5.1 and is a no-op on PowerShell 7.
function Initialize-WtBootstrapArchive {
    try { Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop } catch { $null = $_ }
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { $null = $_ }
}

<#
.SYNOPSIS
    The canonical platform table: release key, GOOS/GOARCH and archive-relative worker path.
#>
function Get-WtBootstrapPlatforms {
    return @(
        [pscustomobject]@{ Key = 'win-x64'; Os = 'windows'; Arch = 'amd64'; Exe = 'wt-worker.exe'; WorkerPath = 'worker/bin/windows-amd64/wt-worker.exe' }
        [pscustomobject]@{ Key = 'win-arm64'; Os = 'windows'; Arch = 'arm64'; Exe = 'wt-worker.exe'; WorkerPath = 'worker/bin/windows-arm64/wt-worker.exe' }
        [pscustomobject]@{ Key = 'linux-x64'; Os = 'linux'; Arch = 'amd64'; Exe = 'wt-worker'; WorkerPath = 'worker/bin/linux-amd64/wt-worker' }
        [pscustomobject]@{ Key = 'linux-arm64'; Os = 'linux'; Arch = 'arm64'; Exe = 'wt-worker'; WorkerPath = 'worker/bin/linux-arm64/wt-worker' }
    )
}

<#
.SYNOPSIS
    Returns the canonical record for one release platform key.
#>
function Get-WtBootstrapPlatform {
    param ([Parameter(Mandatory = $true)][string]$PlatformKey)

    $Match = @(Get-WtBootstrapPlatforms | Where-Object { $_.Key -eq $PlatformKey })
    if ($Match.Count -ne 1) {
        $Known = (Get-WtBootstrapPlatforms | ForEach-Object { $_.Key }) -join ', '
        throw "PACKAGE: Unknown release platform key '$PlatformKey' (known: $Known)."
    }
    return $Match[0]
}

<#
.SYNOPSIS
    Returns the archive-relative worker path for a release platform key.
#>
function Get-WtBootstrapWorkerPath {
    param ([Parameter(Mandatory = $true)][string]$PlatformKey)

    return (Get-WtBootstrapPlatform -PlatformKey $PlatformKey).WorkerPath
}

<#
.SYNOPSIS
    Returns the application-owned state directory for this bootstrap.
#>
function Get-WtBootstrapStateDir {
    if ($env:WT_BOOTSTRAP_STATE_DIR) {
        return [System.IO.Path]::GetFullPath($env:WT_BOOTSTRAP_STATE_DIR)
    }
    $RuntimeProfile = Get-WtBootstrapRuntimeProfile
    $Base = $env:LOCALAPPDATA
    if (-not $RuntimeProfile.IsWindows) {
        $Base = $env:XDG_CACHE_HOME
        if (-not $Base) { $Base = Join-Path $HOME '.cache' }
    }
    if (-not $Base) { $Base = $env:TEMP }
    return (Join-Path $Base 'WindowsTweaker-bootstrap')
}

<#
.SYNOPSIS
    Normalizes a full path string to avoid traversal by using a simple canonical join.
#>
function Join-WtBootstrapPath {
    param (
        [Parameter(Mandatory = $true)][string]$Base,
        [Parameter(Mandatory = $true)][string]$Child
    )

    $Norm = $Child -replace '[\\/]', [System.IO.Path]::DirectorySeparatorChar
    $Full = [System.IO.Path]::GetFullPath((Join-Path $Base $Norm))
    $BaseFull = [System.IO.Path]::GetFullPath($Base).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $Full.StartsWith($BaseFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "PACKAGE: Staging path escapes the state directory: $Child"
    }
    return $Full
}

<#
.SYNOPSIS
    Returns the platform key used to select the asset.
#>
function Get-WtBootstrapPlatformKey {
    param (
        [Parameter(Mandatory = $false)][string]$Os = '',
        [Parameter(Mandatory = $false)][string]$Architecture = ''
    )

    $RuntimeProfile = Get-WtBootstrapRuntimeProfile
    if (-not $Os) {
        $Os = 'linux'
        if ($RuntimeProfile.IsWindows) { $Os = 'win' }
    }

    if (-not $Architecture) {
        try {
            $Type = [type]::GetType('System.Runtime.InteropServices.RuntimeInformation, System.Runtime.InteropServices.RuntimeInformation')
            if ($Type) {
                $Property = $Type.GetProperty('OSArchitecture')
                if ($Property) { $Architecture = [string]$Property.GetValue($null) }
            }
        } catch {
            $Architecture = ''
        }
        if (-not $Architecture) {
            $Value = $env:PROCESSOR_ARCHITEW6432
            if (-not $Value) { $Value = $env:PROCESSOR_ARCHITECTURE }
            switch ($Value) {
                'AMD64' { $Architecture = 'X64' }
                'ARM64' { $Architecture = 'Arm64' }
                'x86' { $Architecture = 'X86' }
                default { $Architecture = 'Unknown' }
            }
        }
    }

    # The architecture decides the asset, and it is the architecture of the OS - not "is
    # this a 64-bit operating system". A 32-bit host has no asset and says so.
    switch ($Architecture) {
        'X64' { $Arch = 'x64' }
        'Arm64' { $Arch = 'arm64' }
        default { throw "PACKAGE: Unsupported architecture '$Architecture': no WindowsTweaker release is built for it." }
    }

    $Key = "$Os-$Arch"
    $null = Get-WtBootstrapPlatform -PlatformKey $Key
    return $Key
}

<#
.SYNOPSIS
    Validates the staged release: manifest, platform identity, required files, declared file
    sizes/hashes, and worker protocol.
#>
function Test-WtBootstrapRelease {
    param (
        [Parameter(Mandatory = $true)][string]$Staging,
        [Parameter(Mandatory = $true)][string]$PlatformKey,
        [Parameter(Mandatory = $false)][switch]$SkipIntegrity
    )

    $Platform = Get-WtBootstrapPlatform -PlatformKey $PlatformKey

    $ManifestPath = Join-WtBootstrapPath -Base $Staging -Child 'manifest.json'
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw 'PACKAGE: Release manifest.json is missing.'
    }
    $Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ([int]$Manifest.schemaVersion -ne 1) {
        throw "PACKAGE: Unsupported release manifest schema: $($Manifest.schemaVersion)"
    }
    if (-not $Manifest.version) { throw 'PACKAGE: Release manifest.json declares no version.' }
    if ($Manifest.platform -and [string]$Manifest.platform -ne $PlatformKey) {
        throw "PACKAGE: Release manifest declares platform '$($Manifest.platform)', but this host needs '$PlatformKey'."
    }
    if ($Manifest.entryPoint -and [string]$Manifest.entryPoint -ne 'WindowsTweaker.ps1') {
        throw "PACKAGE: Release manifest declares entry point '$($Manifest.entryPoint)'."
    }
    if ($Manifest.worker) {
        if (-not $Manifest.worker.path) { throw 'PACKAGE: Release manifest declares no worker path.' }
        if ([string]$Manifest.worker.path -ne $Platform.WorkerPath) {
            throw "PACKAGE: Release manifest worker path '$($Manifest.worker.path)' is not the canonical path '$($Platform.WorkerPath)' for '$PlatformKey'."
        }
    }

    $RequiredFiles = @(
        'WindowsTweaker.ps1'
        'src/WindowsTweaker/WindowsTweaker.psd1'
        $Platform.WorkerPath
        'THIRD-PARTY-NOTICES.md'
    )
    foreach ($File in $RequiredFiles) {
        $Target = Join-WtBootstrapPath -Base $Staging -Child $File
        if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) {
            throw "PACKAGE: Required release file missing: $File"
        }
    }

    if ($null -ne $Manifest.workerProtocol -and [int]$Manifest.workerProtocol -ne 1) {
        throw "PACKAGE: Worker protocol mismatch: manifest $($Manifest.workerProtocol), expected 1."
    }

    if (-not $SkipIntegrity) {
        foreach ($Entry in @($Manifest.files)) {
            if (-not $Entry.path) { throw 'PACKAGE: Release manifest lists a file without a path.' }
            $Target = Join-WtBootstrapPath -Base $Staging -Child ([string]$Entry.path)
            if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) {
                throw "PACKAGE: File declared in the release manifest is missing: $($Entry.path)"
            }
            $Item = Get-Item -LiteralPath $Target
            if ($null -ne $Entry.size -and [long]$Entry.size -ne $Item.Length) {
                throw "INTEGRITY: File size mismatch for $($Entry.path): manifest $($Entry.size), staged $($Item.Length)."
            }
            if ($Entry.sha256) {
                $Actual = (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($Actual -ne ([string]$Entry.sha256).ToLowerInvariant()) {
                    throw "INTEGRITY: File hash mismatch for $($Entry.path) (expected $($Entry.sha256), got $Actual)."
                }
            }
        }
    }

    return $Manifest
}

<#
.SYNOPSIS
    Extracts the release archive safely (anti-traversal) into staging.
.DESCRIPTION
    On Linux/macOS the packaged file mode is restored with reflection: the API is .NET 7+,
    and a runtime without it leaves the default mode rather than failing the extraction.
#>
function Expand-WtBootstrapArchive {
    param (
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Staging
    )

    Initialize-WtBootstrapArchive
    $ZipPath = Join-Path $Staging '_download.zip'
    [System.IO.File]::WriteAllBytes($ZipPath, $Bytes)
    try {
        $Archive = [System.IO.Compression.ZipArchive]::new(
            [System.IO.File]::OpenRead($ZipPath),
            [System.IO.Compression.ZipArchiveMode]::Read)
        try {
            $SetMode = $null
            $ModeType = $null
            $RuntimeProfile = Get-WtBootstrapRuntimeProfile
            if (-not $RuntimeProfile.IsWindows) {
                $SetMode = @([System.IO.File].GetMethods() | Where-Object { $_.Name -eq 'SetUnixFileMode' } | Select-Object -First 1)
                $ModeType = [type]::GetType('System.IO.UnixFileMode')
            }

            foreach ($Entry in $Archive.Entries) {
                $Name = $Entry.FullName -replace '\\', '/'
                if ($Name -match '^/' -or $Name -match '(^|/)\.\.(/|$)') {
                    throw "PACKAGE: Archive contains unsafe path: $Name"
                }
                $Target = Join-WtBootstrapPath -Base $Staging -Child $Entry.FullName
                if ($Entry.FullName.EndsWith('/')) { continue }
                $Dir = Split-Path $Target -Parent
                if ($Dir -and -not (Test-Path -LiteralPath $Dir)) {
                    [System.IO.Directory]::CreateDirectory($Dir) | Out-Null
                }
                $Stream = $Entry.Open()
                try {
                    $Out = [System.IO.File]::Create($Target)
                    try { $Stream.CopyTo($Out) } finally { $Out.Dispose() }
                } finally { $Stream.Dispose() }

                # Keep a staged worker executable on Linux, where the archive records the mode.
                if ($SetMode -and $ModeType) {
                    $Mode = ($Entry.ExternalAttributes -shr 16) -band 0xFFF
                    if ($Mode -gt 0) {
                        try {
                            $ModeValue = [enum]::ToObject($ModeType, $Mode)
                            $null = $SetMode.Invoke($null, @($Target, $ModeValue))
                        } catch {
                            $null = $_
                        }
                    }
                }
            }
        } finally {
            $Archive.Dispose()
        }
    } finally {
        Remove-Item -LiteralPath $ZipPath -Force -ErrorAction Ignore
    }
}

<#
.SYNOPSIS
    Writes the completion marker for a staged release that passed validation.
#>
function Set-WtBootstrapStagingComplete {
    param (
        [Parameter(Mandatory = $true)][string]$Staging,
        [Parameter(Mandatory = $true)][string]$PlatformKey,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $Marker = [ordered]@{
        schemaVersion = 1
        platform = $PlatformKey
        version = $Version
        completedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    $Path = Join-WtBootstrapPath -Base $Staging -Child '.complete'
    $Json = $Marker | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($Path, $Json, [System.Text.UTF8Encoding]::new($false))
}

<#
.SYNOPSIS
    Reports whether a staging directory was validated and marked complete.
#>
function Test-WtBootstrapStagingComplete {
    param ([Parameter(Mandatory = $true)][string]$Staging)

    $Path = Join-Path $Staging '.complete'
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $Marker = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        return $false
    }
    return ([int]$Marker.schemaVersion -eq 1 -and [bool]$Marker.platform)
}

<#
.SYNOPSIS
    Finds a validated staged release for this platform in the state directory.
#>
function Find-WtBootstrapCache {
    param (
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][string]$PlatformKey
    )

    if (-not (Test-Path -LiteralPath $State)) { return $null }
    $Dirs = @(Get-ChildItem -LiteralPath $State -Directory -ErrorAction Ignore |
        Where-Object { $_.Name -like 'release-*' } |
        Sort-Object LastWriteTime -Descending)
    foreach ($Dir in $Dirs) {
        if (-not (Test-WtBootstrapStagingComplete -Staging $Dir.FullName)) { continue }
        try {
            $null = Test-WtBootstrapRelease -Staging $Dir.FullName -PlatformKey $PlatformKey -SkipIntegrity
        } catch {
            continue
        }
        return [pscustomobject]@{
            Tag     = $Dir.Name.Substring(8)
            Staging = $Dir.FullName
        }
    }
    return $null
}

<#
.SYNOPSIS
    Prepares a staging directory (version-tagged) with a lock for concurrency.
#>
function Get-WtBootstrapStaging {
    param ([Parameter(Mandatory = $true)][string]$Tag)

    $State = Get-WtBootstrapStateDir
    [System.IO.Directory]::CreateDirectory($State) | Out-Null
    $Staging = Join-Path $State ("release-$Tag")
    [System.IO.Directory]::CreateDirectory($Staging) | Out-Null

    $LockPath = Join-Path $Staging '.lock'
    $Deadline = [datetime]::UtcNow.AddSeconds(60)
    while ($true) {
        try {
            $Stream = [System.IO.File]::Open($LockPath, 'CreateNew', 'Write', 'None')
            $Stream.Dispose()
            break
        } catch {
            if ([datetime]::UtcNow -gt $Deadline) {
                throw "PACKAGE: Another bootstrap is staging $Tag; timed out waiting for the lock."
            }
            Start-Sleep -Milliseconds 200
        }
    }
    return $Staging
}

# ---- Launch and handoff ------------------------------------------------------------

<#
.SYNOPSIS
    Resolves a launch entry point (override for tests/validation).
#>
function Resolve-WtBootstrapEntryPoint {
    param ([Parameter(Mandatory = $true)][string]$Staging)

    if ($env:WT_BOOTSTRAP_ENTRYPOINT) {
        return [System.IO.Path]::GetFullPath($env:WT_BOOTSTRAP_ENTRYPOINT)
    }
    return (Join-Path $Staging 'WindowsTweaker.ps1')
}

<#
.SYNOPSIS
    Quotes an argument for a Windows command line.
.DESCRIPTION
    ProcessStartInfo.ArgumentList does not exist on .NET Framework, so Windows PowerShell 5.1
    has to pass a single argument string. The quoting follows the CommandLineToArgvW rules:
    wrap in double quotes, escape embedded quotes, and double the backslashes in front of a
    quote or of the closing quote, so a path with spaces and a trailing backslash survives.
#>
function ConvertTo-WtBootstrapArgumentString {
    param ([Parameter(Mandatory = $false)][string[]]$Argument = @())

    $Parts = @()
    foreach ($Item in $Argument) {
        if ($null -eq $Item) { continue }
        $Value = [string]$Item
        if ($Value.Length -eq 0) { $Parts += '""'; continue }
        if ($Value -notmatch '[\s"]') { $Parts += $Value; continue }

        $Builder = [System.Text.StringBuilder]::new()
        [void]$Builder.Append('"')
        $Backslashes = 0
        foreach ($Character in $Value.ToCharArray()) {
            if ($Character -eq [char]'\') {
                $Backslashes++
                continue
            }
            if ($Character -eq [char]'"') {
                [void]$Builder.Append('\' * ($Backslashes * 2 + 1))
                [void]$Builder.Append('"')
                $Backslashes = 0
                continue
            }
            if ($Backslashes -gt 0) {
                [void]$Builder.Append('\' * $Backslashes)
                $Backslashes = 0
            }
            [void]$Builder.Append($Character)
        }
        if ($Backslashes -gt 0) { [void]$Builder.Append('\' * ($Backslashes * 2)) }
        [void]$Builder.Append('"')
        $Parts += $Builder.ToString()
    }
    return ($Parts -join ' ')
}

<#
.SYNOPSIS
    Starts the application on one runtime, waits, and returns its exit code.
.DESCRIPTION
    The child inherits this console with no stream redirection, so the terminal interface
    keeps the caller's keyboard; the working directory is preserved; the entry point is
    started with exactly the options the caller asked for (none by default, which opens the
    interface and applies no tweak). Handoff bookkeeping is passed through environment
    variables so a nested bootstrap cannot start a second chain.
#>
function Invoke-WtBootstrapLaunch {
    param (
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$PwshPath = '',
        [Parameter(Mandatory = $true)][string]$EntryPoint,
        [Parameter(Mandatory = $false)][string[]]$Argument = @(),
        [Parameter(Mandatory = $false)][hashtable]$EnvironmentVariable = @{}
    )

    if (-not (Test-Path -LiteralPath $EntryPoint)) {
        throw "LAUNCH: Entry point not found after staging: $EntryPoint"
    }

    $HostExe = $PwshPath
    if (-not $HostExe -or -not (Test-Path -LiteralPath $HostExe -PathType Leaf)) {
        $HostExe = ''
        foreach ($Command in @(Get-Command -Name 'pwsh' -CommandType Application -ErrorAction Ignore)) {
            if ($Command -and $Command.Source) { $HostExe = [string]$Command.Source; break }
        }
        if (-not $HostExe) {
            foreach ($Command in @(Get-Command -Name 'powershell' -CommandType Application -ErrorAction Ignore)) {
                if ($Command -and $Command.Source) { $HostExe = [string]$Command.Source; break }
            }
        }
    }
    if (-not $HostExe) { throw 'LAUNCH: No PowerShell host executable found to start the interface.' }

    $StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $StartInfo.FileName = $HostExe
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $false
    $StartInfo.RedirectStandardInput = $false
    $StartInfo.RedirectStandardOutput = $false
    $StartInfo.RedirectStandardError = $false
    try {
        $StartInfo.WorkingDirectory = (Get-Location).Path
    } catch {
        $StartInfo.WorkingDirectory = [System.IO.Path]::GetTempPath()
    }

    $AllArguments = @('-NoProfile', '-File', $EntryPoint) + @($Argument)
    $StartInfo.Arguments = ConvertTo-WtBootstrapArgumentString -Argument $AllArguments
    foreach ($Key in $EnvironmentVariable.Keys) {
        $StartInfo.EnvironmentVariables[[string]$Key] = [string]$EnvironmentVariable[$Key]
    }

    $Process = [System.Diagnostics.Process]::Start($StartInfo)
    $Process.WaitForExit()
    return $Process.ExitCode
}

<#
.SYNOPSIS
    Returns the launch options the caller asked for, in a form both the native and the
    handed-off run accept.
#>
function Get-WtBootstrapLaunchOptions {
    param (
        [Parameter(Mandatory = $false)][string]$Language,
        [Parameter(Mandatory = $false)][string]$Colour,
        [Parameter(Mandatory = $false)][switch]$Ascii,
        [Parameter(Mandatory = $false)][string]$WorkerBackend,
        [Parameter(Mandatory = $false)][string]$Icons
    )

    $Options = @()
    $ResolvedLanguage = $Language
    if (-not $ResolvedLanguage) {
        $ResolvedLanguage = $env:WT_BOOTSTRAP_LANGUAGE
    }
    if (-not $ResolvedLanguage) {
        $ResolvedLanguage = $env:WT_LANG
    }
    if ($ResolvedLanguage) { $Options += @('-Language', $ResolvedLanguage) }

    $ResolvedColour = $Colour
    if (-not $ResolvedColour) { $ResolvedColour = $env:WT_BOOTSTRAP_COLOUR }
    if ($ResolvedColour) { $Options += @('-Colour', $ResolvedColour) }

    if ($Ascii) { $Options += '-Ascii' }
    if ($WorkerBackend -and $WorkerBackend -ne 'Auto') { $Options += @('-WorkerBackend', $WorkerBackend) }
    if ($Icons -and $Icons -ne 'Auto') { $Options += @('-Icons', $Icons) }

    return $Options
}

# ---- Main flow --------------------------------------------------------------------

<#
.SYNOPSIS
    Stages a validated release and returns its entry point.
.DESCRIPTION
    Cache first, download second. Every step between the download and the completion marker
    throws on failure, and a staging directory without the marker is never launched.
#>
function Get-WtBootstrapStagedEntryPoint {
    param (
        [Parameter(Mandatory = $false)][switch]$AllowOfflinePrompt
    )

    $State = Get-WtBootstrapStateDir
    $PlatformKey = Get-WtBootstrapPlatformKey
    $Cached = Find-WtBootstrapCache -State $State -PlatformKey $PlatformKey

    $Release = $null
    try {
        $Release = Get-WtBootstrapRelease
    } catch {
        $Failure = $_.Exception.Message
        if ($Cached) {
            if ($env:WT_BOOTSTRAP_ENTRYPOINT -or $env:WT_BOOTSTRAP_RELEASE_URL) {
                if ($env:WT_BOOTSTRAP_ALLOW_OFFLINE) {
                    return (Resolve-WtBootstrapEntryPoint -Staging $Cached.Staging)
                }
                throw "$Failure (offline cache not enabled by override)"
            }
            if ($AllowOfflinePrompt) {
                Write-Host $Failure
                Write-Host "A validated cached release exists ($($Cached.Tag)). Launch it offline? [y/N] " -NoNewline
                $Answer = ''
                try { $Answer = [string](Read-Host) } catch { $Answer = '' }
                if ($Answer.Trim().ToLowerInvariant() -in 'y', 'yes') {
                    return (Resolve-WtBootstrapEntryPoint -Staging $Cached.Staging)
                }
            }
            throw $Failure
        }
        throw "$Failure"
    }

    $Tag = [string]$Release.tag_name
    $Asset = Get-WtBootstrapAsset -Release $Release
    if ($Asset.name -notmatch [regex]::Escape("-$PlatformKey")) {
        throw "PACKAGE: Asset '$($Asset.name)' does not match the required platform key '$PlatformKey'."
    }

    if ($Cached -and $Cached.Tag -eq $Tag) {
        return (Resolve-WtBootstrapEntryPoint -Staging $Cached.Staging)
    }

    $Staging = Get-WtBootstrapStaging -Tag $Tag
    try {
        Write-Host "WindowsTweaker $Tag ($PlatformKey) - $($Release.html_url)"
        $Bytes = Get-WtBootstrapAssetBytes -Asset $Asset
        $ExpectedHash = Get-WtBootstrapExpectedHash -Release $Release -Asset $Asset
        if (-not $ExpectedHash) {
            throw 'INTEGRITY: No checksums.txt in the release: refusing to stage unverified content.'
        }
        Test-WtBootstrapHash -Bytes $Bytes -ExpectedHash $ExpectedHash
        Write-Host 'SHA-256 verified against the release checksums (same-source integrity; not independent publisher authentication).'

        Expand-WtBootstrapArchive -Bytes $Bytes -Staging $Staging
        $Manifest = Test-WtBootstrapRelease -Staging $Staging -PlatformKey $PlatformKey
        Set-WtBootstrapStagingComplete -Staging $Staging -PlatformKey $PlatformKey -Version ([string]$Manifest.version)
        Write-Host "Release staged at $Staging"

        return (Resolve-WtBootstrapEntryPoint -Staging $Staging)
    } finally {
        $LockPath = Join-Path $Staging '.lock'
        Remove-Item -LiteralPath $LockPath -Force -ErrorAction Ignore
    }
}

<#
.SYNOPSIS
    Decides which runtime starts the application and starts it.
.DESCRIPTION
    -auto: hand off when the current runtime is Windows PowerShell 5.1 and a compatible
    stable pwsh exists (or is installed with consent); otherwise run natively, with a notice.
    -native: never hand off. -pwsh: hand off or fail with the manual instructions.
    The handoff chain is depth-limited and marked in the environment, so it cannot loop.
#>
function Invoke-WtBootstrapApplication {
    param (
        [Parameter(Mandatory = $true)][string]$EntryPoint,
        [Parameter(Mandatory = $false)][string]$Mode = 'auto',
        [Parameter(Mandatory = $false)][switch]$NoInstall,
        [Parameter(Mandatory = $false)][string[]]$Option = @()
    )

    $RuntimeProfile = Get-WtBootstrapRuntimeProfile
    $Depth = 0
    if ($env:WT_BOOTSTRAP_DEPTH -match '^\d+$') { $Depth = [int]$env:WT_BOOTSTRAP_DEPTH }
    $AlreadyHandedOff = ($env:WT_BOOTSTRAP_HANDOFF -eq '1')

    $Environment = @{
        WT_BOOTSTRAP_HANDOFF = '1'
        WT_BOOTSTRAP_DEPTH = [string]($Depth + 1)
        WT_BOOTSTRAP_PARENT = [string]$PID
    }
    if ($env:WT_BOOTSTRAP_LANGUAGE) { $Environment['WT_BOOTSTRAP_LANGUAGE'] = $env:WT_BOOTSTRAP_LANGUAGE }

    # Native when the caller asked for it, when the runtime is already a supported Core
    # runtime, when a chain is already running, or when the requested mode is unavailable.
    if ($Mode -eq 'native') {
        Write-WtBootstrapMessage -Name 'NativeForced' -Argument @($RuntimeProfile.Version)
        return (Invoke-WtBootstrapLaunch -PwshPath '' -EntryPoint $EntryPoint -Argument $Option -EnvironmentVariable $Environment)
    }
    if ($RuntimeProfile.Tier -eq 'Supported') {
        return (Invoke-WtBootstrapLaunch -PwshPath '' -EntryPoint $EntryPoint -Argument $Option -EnvironmentVariable $Environment)
    }
    if ($AlreadyHandedOff -or $Depth -ge 2) {
        Write-WtBootstrapMessage -Name 'HandoffDepth' -Argument @($Depth)
        return (Invoke-WtBootstrapLaunch -PwshPath '' -EntryPoint $EntryPoint -Argument $Option -EnvironmentVariable $Environment)
    }

    # Windows PowerShell 5.1, an untested Core runtime or a preview: look for a better runtime.
    $Selected = Select-WtBootstrapPwsh -Candidate @(Get-WtBootstrapPwshCandidates)
    if (-not $Selected) {
        $Selected = Invoke-WtBootstrapInstallOffer -NoInstall:$NoInstall
    }

    if (-not $Selected) {
        if ($Mode -eq 'pwsh') {
            Write-WtBootstrapMessage -Name 'PwshRequired' -Argument @($RuntimeProfile.SupportedVersion) -ToError
            Write-WtBootstrapMessage -Name 'ManualInstall' -Argument @('https://aka.ms/powershell-release?tag=stable') -ToError
            return 3
        }
        if ($RuntimeProfile.Tier -eq 'WindowsPowerShell') {
            $Report = Get-WtBootstrapRuntimeReportCommand -EntryPoint $EntryPoint
            Write-WtBootstrapMessage -Name 'NativeWindowsPowerShell' -Argument @($RuntimeProfile.Version, $RuntimeProfile.SupportedVersion, $Report)
        }
        return (Invoke-WtBootstrapLaunch -PwshPath '' -EntryPoint $EntryPoint -Argument $Option -EnvironmentVariable $Environment)
    }

    Write-WtBootstrapMessage -Name 'Handoff' -Argument @($Selected.Version, $Selected.Path)
    return (Invoke-WtBootstrapLaunch -PwshPath $Selected.Path -EntryPoint $EntryPoint -Argument $Option -EnvironmentVariable $Environment)
}

<#
.SYNOPSIS
    The command a Windows PowerShell 5.1 user can run later to get the full runtime.
#>
function Get-WtBootstrapRuntimeReportCommand {
    param ([Parameter(Mandatory = $false)][string]$EntryPoint)

    if (-not $EntryPoint) { $EntryPoint = 'WindowsTweaker.ps1' }
    return ("pwsh -NoProfile -File `"$EntryPoint`" -RuntimeReport")
}

<#
.SYNOPSIS
    Main bootstrap flow. Returns the application exit code (never calls exit).
#>
function Invoke-WtBootstrap {
    param (
        [Parameter(Mandatory = $false)][string]$Language,
        [Parameter(Mandatory = $false)][string]$Colour,
        [Parameter(Mandatory = $false)][switch]$Ascii,
        [Parameter(Mandatory = $false)][string]$WorkerBackend = 'Auto',
        [Parameter(Mandatory = $false)][string]$Icons = 'Auto',
        [Parameter(Mandatory = $false)][ValidateSet('auto', 'native', 'pwsh')][string]$RuntimeMode = 'auto',
        [Parameter(Mandatory = $false)][switch]$NoInstall
    )

    $RuntimeProfile = Get-WtBootstrapRuntimeProfile
    if ($RuntimeProfile.Version -lt $RuntimeProfile.MinimumVersion) {
        Write-WtBootstrapMessage -Name 'UnsupportedRuntime' -Argument @($RuntimeProfile.MinimumVersion, $RuntimeProfile.Version) -ToError
        return 2
    }

    if ($RuntimeMode -eq 'auto' -and $env:WT_BOOTSTRAP_RUNTIME) {
        # An environment value is normalised before it is compared, so WT_BOOTSTRAP_RUNTIME=NATIVE
        # works and a typo cannot reach the ValidateSet.
        $Requested = ([string]$env:WT_BOOTSTRAP_RUNTIME).Trim().ToLowerInvariant()
        if ($Requested -in 'auto', 'native', 'pwsh') { $RuntimeMode = $Requested }
    }
    if ($env:WT_BOOTSTRAP_NO_INSTALL -and $env:WT_BOOTSTRAP_NO_INSTALL -ne '0') { $NoInstall = $true }

    # TLS 1.2 for the download only: Windows PowerShell 5.1 on an older Windows build can
    # otherwise negotiate TLS 1.0 and the request fails. The previous value is restored
    # below, so the caller's session is left as it was.
    $SavedProtocol = [System.Net.ServicePointManager]::SecurityProtocol
    try {
        # Tls12 exists on .NET Framework and on .NET; TLS 1.3 is negotiated by .NET's default
        # SslStream settings on PowerShell 7, where this obsolete switch is a no-op anyway.
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    } catch {
        $null = $_
    }

    try {
        $EntryPoint = Get-WtBootstrapStagedEntryPoint -AllowOfflinePrompt
        $Options = Get-WtBootstrapLaunchOptions -Language $Language -Colour $Colour -Ascii:$Ascii -WorkerBackend $WorkerBackend -Icons $Icons
        return (Invoke-WtBootstrapApplication -EntryPoint $EntryPoint -Mode $RuntimeMode -NoInstall:$NoInstall -Option $Options)
    } finally {
        try { [System.Net.ServicePointManager]::SecurityProtocol = $SavedProtocol } catch { $null = $_ }
    }
}

# Entry: run the bootstrap only when not dot-sourced for tests/authoring.
# No exit(); the code is mirrored into $LASTEXITCODE so the caller's session stays alive, and
# the functions this script defined are removed again so the session is left as it was.
if (-not $env:WT_BOOTSTRAP_TEST_ONLY) {
    $WtBootstrapConsole = Enter-WtBootstrapConsole
    $WtBootstrapExitCode = 0
    try {
        # Bound parameters win; the environment fills what the caller did not pass, which is
        # the only way options can arrive through `irm | iex`.
        $WtBootstrapLanguage = $Language
        if (-not $WtBootstrapLanguage) { $WtBootstrapLanguage = $env:WT_BOOTSTRAP_LANGUAGE }
        $WtBootstrapColour = $Colour
        if (-not $WtBootstrapColour) { $WtBootstrapColour = $env:WT_BOOTSTRAP_COLOUR }
        $WtBootstrapAscii = ($Ascii -or ($env:WT_BOOTSTRAP_ASCII -and $env:WT_BOOTSTRAP_ASCII -ne '0'))
        $WtBootstrapWorker = $WorkerBackend
        if ($WtBootstrapWorker -eq 'Auto' -and $env:WT_BOOTSTRAP_WORKER_BACKEND) { $WtBootstrapWorker = [string]$env:WT_BOOTSTRAP_WORKER_BACKEND }
        $WtBootstrapIcons = $Icons
        $WtBootstrapMode = $RuntimeMode

        $WtBootstrapExitCode = [int](Invoke-WtBootstrap -Language $WtBootstrapLanguage -Colour $WtBootstrapColour -Ascii:$WtBootstrapAscii -WorkerBackend $WtBootstrapWorker -Icons $WtBootstrapIcons -RuntimeMode $WtBootstrapMode -NoInstall:$NoInstall)
    } catch {
        $Message = $_.Exception.Message
        if ($Message -notmatch '^(RUNTIME|NETWORK|INTEGRITY|PACKAGE|LAUNCH):') {
            $Message = "LAUNCH: $Message"
        }
        # Non-terminating on purpose: a caller whose $ErrorActionPreference is Stop would
        # otherwise have the bootstrap terminate their pipeline instead of receiving the code
        # in $LASTEXITCODE.
        Write-Error -Message $Message -ErrorAction Continue
        $WtBootstrapExitCode = 1
    } finally {
        Restore-WtBootstrapConsole -State $WtBootstrapConsole
        foreach ($WtBootstrapFunction in @(Get-ChildItem Function:\ -ErrorAction Ignore |
            Where-Object { $_.Name -like '*WtBootstrap*' })) {
            if ($WtBootstrapFunction.Name -notin $WtBootstrapPreexistingFunctions) {
                Remove-Item -LiteralPath ('function:' + $WtBootstrapFunction.Name) -Force -ErrorAction Ignore
            }
        }
        Remove-Variable -Name WtBootstrapPreexistingFunctions -ErrorAction Ignore
        Remove-Variable -Name WtBootstrapConsole, WtBootstrapLanguage, WtBootstrapColour, WtBootstrapAscii, WtBootstrapWorker, WtBootstrapIcons, WtBootstrapMode -ErrorAction Ignore
    }
    $global:LASTEXITCODE = $WtBootstrapExitCode
}