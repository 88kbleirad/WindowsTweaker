# Runs the complete validation suite and prints a report.
#
# Usage:
#   pwsh -NoProfile -File tools/Invoke-Validation.ps1
#
# Exit code 0 when every executed check passed.

[CmdletBinding()]
param ()

$Root = Split-Path -Path $PSScriptRoot -Parent
$Failures = [System.Collections.Generic.List[string]]::new()

function Write-Phase
{
    param ([string]$Title)

    Write-Host ''
    Write-Host ('=' * 78)
    Write-Host $Title
    Write-Host ('=' * 78)
}

Write-Phase '0. Host worker binary (phase 6 drives the compiled worker into SQLite)'

# tests/Monitor.Tests.ps1 starts metric recording through the compiled worker and writes into
# a real SQLite store, and the worker refuses to fall back: without the binary those two tests
# fail instead of skipping, by design - the SQLite path is covered by running it. worker/bin/
# is gitignored build output, so a fresh checkout has no worker at all. Build it for this host
# through the packaging tool's own build path: one builder and one platform table, no second
# copy that can drift.
$WorkerVersion = (Import-PowerShellDataFile -LiteralPath (Join-Path $Root 'src/WindowsTweaker/WindowsTweaker.psd1')).ModuleVersion
$PreviousTestOnly = $env:WT_BOOTSTRAP_TEST_ONLY
$env:WT_BOOTSTRAP_TEST_ONLY = '1'
try
{
    . (Join-Path $Root 'bootstrap/implementation.ps1')
}
finally
{
    if ($null -eq $PreviousTestOnly) { Remove-Item Env:\WT_BOOTSTRAP_TEST_ONLY -ErrorAction Ignore }
    else { $env:WT_BOOTSTRAP_TEST_ONLY = $PreviousTestOnly }
}

$HostWorkerKey = Get-WtBootstrapPlatformKey
$HostWorkerPath = Join-Path $Root ((Get-WtBootstrapPlatform -PlatformKey $HostWorkerKey).WorkerPath)
$HostWorkerRelative = $HostWorkerPath.Substring($Root.Length).TrimStart('\', '/')

if (Get-Command go -ErrorAction Ignore)
{
    # Rebuild whenever Go is available: the tests must exercise a worker built from the Go
    # sources in this tree, never one left behind by an earlier run.
    try
    {
        $WorkerOutput = & (Join-Path $PSScriptRoot 'New-ReleasePackage.ps1') -Version $WorkerVersion -Platforms $HostWorkerKey -WorkersOnly 2>&1
        $WorkerOutput | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { throw "the worker build exited with $LASTEXITCODE" }
        Write-Host ("host worker ({0}): built {1}" -f $HostWorkerKey, $HostWorkerRelative)
    }
    catch
    {
        Write-Host ("host worker build FAILED: {0}" -f $_.Exception.Message)
        $Failures.Add('The host worker binary could not be built, so the SQLite metric tests cannot run')
    }
}
elseif (Test-Path -LiteralPath $HostWorkerPath -PathType Leaf)
{
    Write-Host ("host worker ({0}): reused {1} (no Go toolchain on PATH)" -f $HostWorkerKey, $HostWorkerRelative)
}
else
{
    Write-Host ("host worker: MISSING and no Go toolchain on PATH to build {0}" -f $HostWorkerRelative)
    $Failures.Add('The host worker binary is missing and no Go toolchain is available to build it (docs/WORKER.md)')
}

Write-Phase '1. AST parse of every PowerShell file'

# The unreviewed reference material is excluded from the parse; everything that can be
# loaded at runtime must parse.
$ParseOutput = & (Join-Path $PSScriptRoot 'Parse-All.ps1') 2>&1
$ParseOutput | ForEach-Object { Write-Host $_ }

if ($LASTEXITCODE -ne 0)
{
    $Failures.Add('AST parse reported errors in loadable code')
}

Write-Phase '2. Catalog invariants'

$CatalogOutput = & (Join-Path $PSScriptRoot 'Test-Catalog.ps1') 2>&1
$CatalogOutput | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0)
{
    $Failures.Add('Catalog invariants failed')
}

Write-Phase '3. Insight invariants'

# The rules, the groups and the recommendation links span two documents. The loader refuses a
# malformed document; this refuses a pair that disagree.
$InsightOutput = & (Join-Path $PSScriptRoot 'Test-Insight.ps1') 2>&1
$InsightOutput | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0)
{
    $Failures.Add('Insight invariants failed')
}

Write-Phase '4. PSScriptAnalyzer'

$Settings = Join-Path $Root 'PSScriptAnalyzerSettings.psd1'
$AnalyzerFindings = @(Invoke-ScriptAnalyzer -Path (Join-Path $Root 'src') -Recurse -Settings $Settings) +
    @(Invoke-ScriptAnalyzer -Path (Join-Path $Root 'tests') -Recurse -Settings $Settings) +
    @(Invoke-ScriptAnalyzer -Path (Join-Path $Root 'tools') -Recurse -Settings $Settings) +
    @(Invoke-ScriptAnalyzer -Path (Join-Path $Root 'bootstrap') -Recurse -Settings $Settings) +
    @(Invoke-ScriptAnalyzer -Path (Join-Path $Root 'WindowsTweaker.ps1') -Settings $Settings)

if ($AnalyzerFindings.Count -eq 0)
{
    Write-Host 'PSScriptAnalyzer: no findings (Error/Warning) with PSScriptAnalyzerSettings.psd1'
}
else
{
    $AnalyzerFindings | ForEach-Object { Write-Host ('{0} {1}:{2} :: {3}' -f $_.Severity, (Split-Path $_.ScriptName -Leaf), $_.Line, $_.Message) }
    $Failures.Add("PSScriptAnalyzer reported $($AnalyzerFindings.Count) finding(s)")
}

Write-Phase '5. Windows PowerShell 5.1 compatibility gate'

# Static proof of the two properties this project claims for 5.1: the shipped code only uses
# APIs that exist there (PSScriptAnalyzer's 5.1 syntax/command/type rules), and every
# non-ASCII source file carries the UTF-8 BOM that 5.1 needs to decode it. Runtime behaviour
# on a real 5.1 host is not provable here; docs/COMPATIBILITY.md lists those rows.
$CompatibilityOutput = & (Join-Path $PSScriptRoot 'Test-Compatibility.ps1') 2>&1
$CompatibilityOutput | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0)
{
    $Failures.Add('The Windows PowerShell 5.1 compatibility gate failed')
}

Write-Phase '6. Pester test suite'

$Pester = Invoke-Pester -Path (Join-Path $Root 'tests') -Output Detailed -PassThru
Write-Host ("Tests passed: {0} | failed: {1} | skipped: {2}" -f $Pester.PassedCount, $Pester.FailedCount, $Pester.SkippedCount)
if ($Pester.FailedCount -gt 0)
{
    $Failures.Add("Pester reported $($Pester.FailedCount) failing test(s)")
}

Write-Phase '7. Dry-run proof (no state written)'

$Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-validate-{0}" -f ([guid]::NewGuid().ToString('n')))
$env:WT_DATA_ROOT = $Sandbox
$env:WT_STATE_PATH = Join-Path $Sandbox 'state.json'
$env:WT_LOG_DIRECTORY = Join-Path $Sandbox 'logs'

Import-Module (Join-Path $Root 'src/WindowsTweaker/WindowsTweaker.psd1') -Force
$DryRunResult = Invoke-WtTweak -Id 'Privacy.AdvertisingId' -State Disabled -WhatIf
Write-Host ("WhatIf status      : {0}" -f $DryRunResult.Status)
Write-Host ("WhatIf captured    : {0}" -f $DryRunResult.CapturedState)
Write-Host ("State file created : {0}" -f (Test-Path -LiteralPath $env:WT_STATE_PATH))

if ($DryRunResult.CapturedState -or (Test-Path -LiteralPath $env:WT_STATE_PATH))
{
    $Failures.Add('A dry run wrote state')
}

Remove-Item -LiteralPath $Sandbox -Recurse -Force -ErrorAction Ignore
Remove-Item Env:\WT_DATA_ROOT, Env:\WT_STATE_PATH, Env:\WT_LOG_DIRECTORY -ErrorAction Ignore

Write-Phase 'Summary'

if ($Failures.Count -eq 0)
{
    Write-Host 'ALL EXECUTED CHECKS PASSED'
    exit 0
}

foreach ($Failure in $Failures)
{
    Write-Host ("FAILED: {0}" -f $Failure)
}
exit 1
