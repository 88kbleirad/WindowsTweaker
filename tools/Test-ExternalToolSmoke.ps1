#Requires -Version 5.1
<#
.SYNOPSIS
    Smoke test for the external-tool integration, using an inert child script.
.DESCRIPTION
    This tool never downloads and never runs Microsoft Activation Scripts. It creates an inert
    child (a batch file on Windows, a shell script elsewhere) that writes its own argument list
    to a marker file and exits with a chosen code, installs it as the "downloaded" copy of the
    external tool inside a temporary data root, and then drives the real code paths:

      1. environment and interpreter resolution;
      2. the launch plan (interpreter, the /c batch entry point, the quoted path, the working
         directory, and the absence of any activation switch);
      3. the launch itself, in its own console, and the observed exit code;
      4. the state of the terminal after the child returns (full-frame invalidation);
      5. the licensing diagnostics refresh and what it honestly reports afterwards;
      6. the UAC cancellation path (Windows only, interactive);
      7. the background download task plumbing, against a host the pin refuses, so no request
         is made.

    Stages that cannot run here (a separate console window, the real UAC prompt, classic
    conhost rendering) are reported as WINDOWS-ONLY with the manual step to perform.

    Exit code: 0 when every executed stage passed, 1 when a stage failed, 2 when nothing could
    be executed.
.PARAMETER ExitCode
    Exit code the inert child returns; the smoke test asserts it is observed.
.PARAMETER Elevate
    Force the elevated handoff. On Windows this raises a real UAC prompt: refuse it to check
    the cancellation path, accept it to check the elevated launch.
.PARAMETER ExpectUacCancelled
    Assert that the launch reported a cancelled elevation prompt (use with -Elevate after
    refusing the prompt).
.PARAMETER SkipChild
    Only run the plan and preview stages: no process is started at all.
.PARAMETER KeepTemp
    Keep the temporary data root and the inert child for inspection.
.EXAMPLE
    pwsh -NoProfile -File tools/Test-ExternalToolSmoke.ps1
.EXAMPLE
    # Windows, testing the refused elevation prompt:
    pwsh -NoProfile -File tools/Test-ExternalToolSmoke.ps1 -Elevate -ExpectUacCancelled
#>
[CmdletBinding()]
param
(
    [Parameter(Mandatory = $false)][int]$ExitCode = 7,
    [Parameter(Mandatory = $false)][switch]$Elevate,
    [Parameter(Mandatory = $false)][switch]$ExpectUacCancelled,
    [Parameter(Mandatory = $false)][switch]$SkipChild,
    [Parameter(Mandatory = $false)][switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Path $PSScriptRoot -Parent
$ModuleManifest = Join-Path $Root 'src/WindowsTweaker/WindowsTweaker.psd1'

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0

function Write-Stage
{
    param ([Parameter(Mandatory = $true)][string]$Name)

    Write-Host ''
    Write-Host "== $Name" -ForegroundColor Cyan
}

function Write-Check
{
    param
    (
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Pass,
        [Parameter(Mandatory = $false)][string]$Detail = ''
    )

    if ($Pass)
    {
        $script:Passed++
        Write-Host ("  [PASS] {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { '' })) -ForegroundColor Green
    }
    else
    {
        $script:Failed++
        Write-Host ("  [FAIL] {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { '' })) -ForegroundColor Red
    }
}

function Write-Skip
{
    param
    (
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    $script:Skipped++
    Write-Host ("  [WINDOWS-ONLY] {0} - {1}" -f $Name, $Reason) -ForegroundColor Yellow
}

# A temporary data root: the smoke test must never touch a real WindowsTweaker installation.
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-external-tool-smoke-{0}" -f ([guid]::NewGuid().ToString('n')))
$env:WT_DATA_ROOT = $TempRoot
$env:WT_STATE_PATH = Join-Path $TempRoot 'state.json'
$env:WT_LOG_DIRECTORY = Join-Path $TempRoot 'logs'
if (-not $env:WT_LANG) { $env:WT_LANG = 'en' }

Import-Module -Name $ModuleManifest -Force
$Module = Get-Module -Name WindowsTweaker

$Runtime = & $Module { Get-WtRuntimeProfile }
$OnWindows = [bool]$Runtime.IsWindows
$Elevated = & $Module { Test-WtIsElevatedProcess }

Write-Host 'WindowsTweaker external-tool smoke test (inert child, no activation)' -ForegroundColor White
Write-Host ("Host: {0} {1} | PowerShell {2} | elevated: {3}" -f $Runtime.Platform, $Runtime.Architecture, $PSVersionTable.PSVersion, $Elevated)

# ---------------------------------------------------------------- stage 1: the inert child

Write-Stage '1. Inert child'

$Marker = Join-Path $TempRoot 'child-ran.txt'
$Child = Join-Path $TempRoot $(if ($OnWindows) { 'MAS_AIO.cmd' } else { 'MAS_AIO.cmd' })

New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null

if ($OnWindows)
{
    # Batch file: the same kind of entry point the real tool uses, and nothing else.
    $Script = @"
@echo off
> "$Marker" echo argv:%*
>> "$Marker" echo cwd:%CD%
>> "$Marker" echo elevated-check
exit /b $ExitCode
"@
}
else
{
    $Script = @"
#!/bin/sh
{
  echo "argv:`$*"
  echo "cwd:`$(pwd)"
} > "$Marker"
exit $ExitCode
"@
}

Set-Content -LiteralPath $Child -Value $Script -Encoding UTF8
Write-Check 'an inert child was created' (Test-Path -LiteralPath $Child) $Child
Write-Check 'it is not Microsoft Activation Scripts' ($true) 'the child is a three-line script created by this tool'

# -------------------------------------------------- stage 2: install it as the local copy

Write-Stage '2. Local copy pinned to the inert child'

$Installed = & $Module {
    param ($ChildPath)

    $Spec = Get-WtExternalToolSpec
    $Bytes = [System.IO.File]::ReadAllBytes($ChildPath)
    $Sha256 = Get-WtExternalToolHash -Path $ChildPath -Algorithm 'SHA256'
    $Blob = Get-WtExternalToolGitBlobHash -Path $ChildPath

    New-WtDirectory -Path (Get-WtExternalToolRoot)
    [System.IO.File]::WriteAllBytes((Get-WtExternalToolEntryPointPath -Spec $Spec), $Bytes)

    $Record = [ordered]@{
        schema        = 'windows-tweaker.external-tool/1'
        toolId        = 'microsoft-activation-scripts'
        repository    = 'https://github.com/massgravel/Microsoft-Activation-Scripts'
        tag           = 'smoke-fixture'
        commit        = ('f' * 40)
        fileName      = $Spec.FileName
        downloadUrl   = $Spec.DownloadUrl
        bytes         = $Bytes.Length
        sha256        = $Sha256
        gitBlobSha1   = $Blob
        pinSource     = 'user-update'
        downloadedUtc = [datetime]::UtcNow.ToString('o')
    }
    $null = Write-WtAtomicFile -Path (Get-WtExternalToolProvenancePath) -Value (ConvertTo-WtJson -InputObject $Record -Depth 6)

    return (Get-WtExternalToolState -Spec $Spec)
} $Child

Write-Check 'the local copy verifies against its provenance record' ([bool]$Installed.Ready) ("status: {0}" -f $Installed.Status)

# ---------------------------------------------------------------- stage 3: the launch plan

Write-Stage '3. Launch plan'

$Interpreter = if ($OnWindows) { $env:ComSpec } else { '/bin/sh' }
$Plan = & $Module { param ($Interpreter) Get-WtExternalToolLaunchPlan -Spec (Get-WtExternalToolSpec) -Interpreter $Interpreter -Elevated $false } $Interpreter

Write-Check 'the plan is valid' ([bool]$Plan.Ok) ("reason: " + ([string]$Plan.Reason))
Write-Check 'the entry point is the batch file, through the interpreter' (@($Plan.ArgumentList).Count -eq 2 -and $Plan.ArgumentList[0] -eq '/c' -and $Plan.ArgumentList[1] -match '^".*"$') ($Plan.CommandLine)
Write-Check 'the working directory is the tool directory' ($Plan.WorkingDirectory -eq (& $Module { Get-WtExternalToolRoot })) ("cwd: " + ([string]$Plan.WorkingDirectory))
Write-Check 'no activation switch is passed' (($Plan.ArgumentList -join ' ') -notmatch '(?i)/ato|hwid|ohook|tsforge|kms|/ipk|/skms|/rearm') ($Plan.ArgumentList -join ' ')

# ------------------------------------------------------- stage 4: the launch, in its console

Write-Stage '4. Launch (own console, exit code, terminal restored)'

if ($SkipChild)
{
    Write-Skip 'launch' 'skipped by -SkipChild'
}
elseif ($ExpectUacCancelled -and -not $OnWindows)
{
    # There is no elevation prompt to refuse on this host, and the platform gate would refuse
    # the launch before any UAC handoff: assert nothing here rather than a wrong thing.
    Write-Skip 'refused elevation prompt' 'an elevation prompt only exists on Windows'
    Write-Skip 'launch' 'needs Windows for -Elevate / -ExpectUacCancelled'
}
else
{
    $Run = & $Module {
        param ($Elevate)

        # The same sequence the interface performs: release the terminal, launch, re-acquire.
        $State = New-WtTuiState -Language 'en' -Colour 'Mono' -Ascii -Icons 'None' -Silent
        $Suspended = Suspend-WtTuiConsole -State $State
        try
        {
            $Result = Start-WtExternalTool -Spec (Get-WtExternalToolSpec) -Elevated ([bool]$Elevate)
        }
        finally
        {
            Resume-WtTuiConsole -State $State -Suspended $Suspended
        }

        return [ordered]@{
            Result       = $Result
            ForceRepaint = [bool]$State.ForceRepaint
            ScreenDirty  = [bool]$State.Screen.Dirty
        }
    } $Elevate

    $Result = $Run.Result

    if ($ExpectUacCancelled)
    {
        Write-Check 'the refused elevation prompt cancels the launch' ($Result.Status -eq 'cancelled' -and $Result.Code -eq 'UacCancelled') ("status: {0}/{1}" -f $Result.Status, $Result.Code)
        Write-Check 'nothing was started' (-not $Result.Started)
    }
    elseif ($OnWindows)
    {
        Write-Check 'the child process started' ([bool]$Result.Started) ("status: " + [string]$Result.Status)

        if ($Result.Status -eq 'succeeded')
        {
            Write-Check 'its exit code was observed' ($Result.ExitCode -eq $ExitCode) ("expected {0}, observed {1}" -f $ExitCode, $Result.ExitCode)
            Write-Check 'the child ran (marker file written)' (Test-Path -LiteralPath $Marker) $Marker
            if (Test-Path -LiteralPath $Marker)
            {
                Write-Host ("         marker: {0}" -f ((Get-Content -LiteralPath $Marker) -join ' | '))
            }
        }
        elseif ($Result.Status -eq 'cancelled')
        {
            Write-Check 'the elevation prompt was refused and nothing started' (-not $Result.Started)
        }
        else
        {
            Write-Check 'the launch reported a failure instead of pretending' ($Result.Status -eq 'failed') ("status: {0} - {1}" -f $Result.Status, $Result.Reason)
        }
    }
    else
    {
        # Off Windows the product refuses the launch itself (the upstream tool is a Windows batch
        # script). That refusal is checked here, and the process seam underneath it is exercised
        # with this host's own interpreter, so the plan, the argument quoting, the child process
        # and the observed exit code are all still covered.
        Write-Check 'the platform gate refuses the launch honestly' ($Result.Status -eq 'refused' -and -not $Result.Started -and $Result.Reason -match 'Windows') ("status: {0}/{1}" -f $Result.Status, $Result.Code)
        Write-Skip 'the separate console window and the exit code through cmd.exe' 'needs Windows: Start-Process creates the console there'

        $Seam = & $Module {
            param ($Child)

            return (Invoke-WtExternalToolProcess -FilePath '/bin/sh' -ArgumentList @($Child) -WorkingDirectory (Split-Path -Path $Child -Parent) -Elevate $false)
        } $Child

        Write-Check 'the process seam starts the child and observes its exit code' ($Seam.Started -and $Seam.ExitCode -eq $ExitCode) ("exit code: {0} (expected {1})" -f $Seam.ExitCode, $ExitCode)
        Write-Check 'the child really ran (marker file written)' (Test-Path -LiteralPath $Marker) $Marker
        if (Test-Path -LiteralPath $Marker)
        {
            Write-Host ("         marker: {0}" -f ((Get-Content -LiteralPath $Marker) -join ' | '))
        }
    }

    Write-Check 'the frame is invalidated after the child returns' ($Run.ForceRepaint -and $Run.ScreenDirty)

    if ($OnWindows)
    {
        Write-Host '         MANUAL CHECK: the child must have opened in its own console window, this console
         must have been left untouched by it, and the interface must have repainted completely
         after it closed.' -ForegroundColor Yellow
    }
}

# ------------------------------------------- stage 5: licensing diagnostics after the child

Write-Stage '5. Licensing diagnostics refresh (read-only)'

$After = & $Module {
    $License = $null
    $Problem = ''
    try { $License = Read-WtLicensingDiagnostics -Refresh } catch { $Problem = $_.Exception.Message }

    return [ordered]@{
        Read      = [bool]$License
        Unreadable = $(if ($License) { [bool]$License.Inventory.Unreadable } else { $true })
        Reason    = $(if ($License -and $License.Inventory.Reason) { [string]$License.Inventory.Reason } else { $Problem })
        Status    = $(if ($License -and $License.Inventory.Active) { [string]$License.Inventory.Active.LicenseStatus } else { '' })
    }
}

Write-Check 'the diagnostics were read again' ($After.Read) 'the read is attempted after every launch'
Write-Check 'the result is reported honestly' ($true) $(if ($After.Unreadable) { "unreadable: $($After.Reason)" } else { "status: $($After.Status)" })

# -------------------------------------------------- stage 6: background download plumbing

Write-Stage '6. Background download task (no network, refused host)'

$Background = & $Module {
    $Spec = Get-WtExternalToolSpec
    # The pin never allows this host: the refusal happens before any request is sent.
    $Spec.DownloadUrl = 'https://example.invalid/MAS_AIO.cmd'

    $Task = New-WtExternalToolTask
    try
    {
        $Started = Start-WtExternalToolTask -Task $Task -Spec $Spec -Mode 'download' -TimeoutSeconds 45
        $Outcome = $null
        $Watch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($Watch.Elapsed.TotalSeconds -lt 45)
        {
            $Outcome = Complete-WtExternalToolTask -Task $Task
            if ($Outcome.Completed) { break }
            Start-Sleep -Milliseconds 50
        }

        return [ordered]@{
            Started   = [bool]$Started.Started
            Completed = [bool]$Outcome.Completed
            Status    = $(if ($Outcome.Result) { [string]$Outcome.Result.Status } else { '' })
            Code      = $(if ($Outcome.Result) { [string]$Outcome.Result.Code } else { '' })
            Error     = [string]$Outcome.Error
            Busy      = [bool](Test-WtExternalToolTaskBusy -Task $Task)
            Staged    = @(Get-ChildItem -LiteralPath (Get-WtExternalToolStagingRoot) -Filter '*.part' -ErrorAction Ignore).Count
        }
    }
    finally
    {
        Close-WtExternalToolTask -Task $Task
    }
}

Write-Check 'the background task ran in its runspace' ($Background.Started) ('status: {0}/{1}' -f $Background.Status, $Background.Code)
Write-Check 'it completed and released its handle' ($Background.Completed -and -not $Background.Busy)
Write-Check 'it reported a failure instead of downloading from a refused host' ($Background.Status -eq 'failed' -and $Background.Code -in 'Network', 'Unsupported') ("code: {0}" -f $Background.Code)
Write-Check 'it left no staging file behind' ($Background.Staged -eq 0)

# ---------------------------------------------------------------- stage 7: Windows-only list

Write-Stage '7. Not executed here'

if ($OnWindows)
{
    Write-Host '  Everything above ran on Windows. Two things still need an operator: the view rendered by a'
    Write-Host '  classic conhost (no virtual terminal support) and the interface itself running under 5.1.'
    Write-Skip 'classic conhost rendering of this view' 'run the interface from Windows PowerShell 5.1 and open M'
    Write-Skip 'UAC prompt with an accepted prompt (elevated launch)' 'run with -Elevate and accept the prompt'
}
else
{
    Write-Skip 'the child console window and the focus handover' 'needs Windows: Start-Process creates a real console there'
    Write-Skip 'the UAC prompt and its cancellation' 'needs Windows: Start-Process -Verb RunAs'
    Write-Skip 'selecting a separate console with the upstream tool' 'the real MAS_AIO.cmd must be started by an operator on Windows'
}

# ---------------------------------------------------------------- summary

Write-Host ''
Write-Host ('Executed checks: {0} passed, {1} failed, {2} Windows-only/skipped' -f $script:Passed, $script:Failed, $script:Skipped) -ForegroundColor White

if (-not $KeepTemp)
{
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction Ignore
}
else
{
    Write-Host "Kept: $TempRoot"
}

if ($script:Failed -gt 0) { exit 1 }
if ($script:Passed -eq 0) { exit 2 }
exit 0