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

Write-Phase '5. Pester test suite'

$Pester = Invoke-Pester -Path (Join-Path $Root 'tests') -Output Detailed -PassThru
Write-Host ("Tests passed: {0} | failed: {1} | skipped: {2}" -f $Pester.PassedCount, $Pester.FailedCount, $Pester.SkippedCount)
if ($Pester.FailedCount -gt 0)
{
    $Failures.Add("Pester reported $($Pester.FailedCount) failing test(s)")
}

Write-Phase '6. Dry-run proof (no state written)'

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
