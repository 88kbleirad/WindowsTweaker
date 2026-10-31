# WindowsTweaker - static compatibility gate.
#
# Verifies, without a Windows host, the two properties the project claims:
#
#   1. Every shipped script parses and uses only APIs that exist in Windows PowerShell 5.1.
#      This is checked with PSScriptAnalyzer's own compatibility rules and its Windows
#      PowerShell 5.1 profile (syntax, commands/parameters, .NET types) - the same
#      mechanism the PowerShell team publishes for exactly this purpose.
#   2. Every source file that contains non-ASCII text carries a UTF-8 byte-order mark.
#      Windows PowerShell 5.1 decodes a BOM-less file with the ANSI code page, which
#      corrupts the Vietnamese string tables and every Vietnamese literal; PowerShell 7
#      decodes both. A BOM is therefore required, not optional, for 5.1 support.
#
# What this cannot prove is runtime behaviour: terminal handling, code pages, registry
# access and process launching on a real Windows host. docs/COMPATIBILITY.md states which
# rows rest on this gate and which are unexecuted.
#
# Usage:
#   pwsh -NoProfile -File tools/Test-Compatibility.ps1 [-Detailed]
#
# Exit code 0 when every executed check passed.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][switch]$Detailed
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Path $PSScriptRoot -Parent
$Failures = [System.Collections.Generic.List[string]]::new()

$Profile51 = 'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework'

function Write-Check
{
    param ([string]$Title, [string]$Detail)

    Write-Host ("{0,-46} {1}" -f $Title, $Detail)
}

function Write-Finding
{
    param ([object]$Finding)

    $File = Split-Path -Path $Finding.ScriptName -Leaf
    Write-Host ("  {0} {1}:{2} :: {3}" -f $Finding.Severity, $File, $Finding.Line, $Finding.Message)
}

# ---- 1. The analyzer and the 5.1 profile must be available ----------------------
$Analyzer = Get-Module -ListAvailable PSScriptAnalyzer | Sort-Object -Property Version -Descending | Select-Object -First 1
if (-not $Analyzer)
{
    Write-Host 'PSScriptAnalyzer is required for the compatibility gate (Install-Module PSScriptAnalyzer).'
    exit 2
}

$ProfilePath = Join-Path (Join-Path $Analyzer.ModuleBase 'compatibility_profiles') ($Profile51 + '.json')
if (-not (Test-Path -LiteralPath $ProfilePath))
{
    Write-Host "The Windows PowerShell 5.1 compatibility profile is missing: $ProfilePath"
    exit 2
}

# Shipped code: it runs on the user's machine, so every command, parameter and .NET type it
# uses must exist on Windows PowerShell 5.1.
$Shipped = @(
    (Join-Path $Root 'src'),
    (Join-Path $Root 'bootstrap'),
    (Join-Path $Root 'WindowsTweaker.ps1')
)
# Syntax-only: development tooling and the test suite. They are run with the validated
# PowerShell 7 runtime (Pester 6 needs it), so 7-only cmdlet parameters there are correct;
# but a syntax error in them would still be a defect, so they are parsed against 5.1.
$SyntaxOnly = @(
    (Join-Path $Root 'tests'),
    (Join-Path $Root 'tools')
)

# ---- 2. Windows PowerShell 5.1 syntax ------------------------------------------
$SyntaxSettings = @{
    IncludeRules = @('PSUseCompatibleSyntax')
    Rules        = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') } }
}
$SyntaxFindings = @()
foreach ($Path in @($Shipped + $SyntaxOnly))
{
    $SyntaxFindings += @(Invoke-ScriptAnalyzer -Path $Path -Recurse -Settings $SyntaxSettings -ErrorAction Ignore)
}
Write-Check '5.1 syntax (src, bootstrap, tools, tests)' ("{0} finding(s)" -f $SyntaxFindings.Count)
if ($SyntaxFindings.Count -gt 0)
{
    foreach ($Finding in $SyntaxFindings) { Write-Finding -Finding $Finding }
    $Failures.Add("$($SyntaxFindings.Count) PowerShell 5.1 syntax finding(s)")
}

# ---- 3. Windows PowerShell 5.1 commands, parameters and types -------------------
# Shipped code only: development tooling and tests run on PowerShell 7 and may use 7-only
# cmdlet parameters (Invoke-Pester -Output, for example).
$ApiSettings = @{
    IncludeRules = @('PSUseCompatibleCommands', 'PSUseCompatibleTypes')
    Rules        = @{
        PSUseCompatibleCommands = @{ Enable = $true; TargetProfiles = @($Profile51) }
        PSUseCompatibleTypes    = @{ Enable = $true; TargetProfiles = @($Profile51) }
    }
}
$ApiFindings = @()
foreach ($Path in $Shipped)
{
    $ApiFindings += @(Invoke-ScriptAnalyzer -Path $Path -Recurse -Settings $ApiSettings -ErrorAction Ignore)
}
Write-Check '5.1 commands/parameters and .NET types' ("{0} finding(s)" -f $ApiFindings.Count)
if ($ApiFindings.Count -gt 0)
{
    foreach ($Finding in $ApiFindings) { Write-Finding -Finding $Finding }
    $Failures.Add("$($ApiFindings.Count) PowerShell 5.1 API finding(s)")
}

# ---- 4. Encoding: non-ASCII source files carry a UTF-8 BOM ----------------------
$BomNeeded = @()
$BomMissing = @()
$BomUnnecessary = @()
$EncodingRoots = @('src', 'bootstrap', 'tests', 'tools') | ForEach-Object { Join-Path $Root $_ }
$EncodingRoots += Join-Path $Root 'WindowsTweaker.ps1'

foreach ($EncodingRoot in $EncodingRoots)
{
    if (Test-Path -LiteralPath $EncodingRoot -PathType Leaf)
    {
        $Files = @(Get-Item -LiteralPath $EncodingRoot)
    }
    else
    {
        $Files = @(Get-ChildItem -LiteralPath $EncodingRoot -Recurse -File -Include '*.ps1', '*.psd1', '*.psm1')
    }

    foreach ($File in $Files)
    {
        $Bytes = [System.IO.File]::ReadAllBytes($File.FullName)
        $HasBom = ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
        $HasNonAscii = $false
        for ($Index = 0; $Index -lt $Bytes.Length; $Index++)
        {
            if ($Bytes[$Index] -gt 0x7F)
            {
                $HasNonAscii = $true
                break
            }
        }
        if ($HasNonAscii)
        {
            $BomNeeded += $File.FullName
            if (-not $HasBom) { $BomMissing += $File.FullName }
        }
        elseif ($HasBom)
        {
            $BomUnnecessary += $File.FullName
        }
    }
}

Write-Check 'Non-ASCII files with a UTF-8 BOM' ("{0} of {1}" -f ($BomNeeded.Count - $BomMissing.Count), $BomNeeded.Count)
if ($BomMissing.Count -gt 0)
{
    foreach ($Path in $BomMissing) { Write-Host ("  missing BOM: {0}" -f $Path.Substring($Root.Length).TrimStart('\', '/')) }
    $Failures.Add("$($BomMissing.Count) non-ASCII script file(s) without a UTF-8 BOM (Windows PowerShell 5.1 would misdecode them)")
}
if ($Detailed -and $BomUnnecessary.Count -gt 0)
{
    foreach ($Path in $BomUnnecessary) { Write-Host ("  BOM on an ASCII-only file: {0}" -f $Path.Substring($Root.Length).TrimStart('\', '/')) }
}

# ---- 5. Runtime policy invariants ----------------------------------------------
$EntryPoint = Join-Path $Root 'WindowsTweaker.ps1'
$EntryText = [System.IO.File]::ReadAllText($EntryPoint)
if ($EntryText -match '(?m)^#Requires\s+-Version\s+7')
{
    $Failures.Add('WindowsTweaker.ps1 still has a #Requires -Version 7.x parse-time gate')
    Write-Check 'Entry point requirement' '#Requires -Version 7.x found'
}
elseif ($EntryText -match '(?m)^#Requires\s+-Version\s+5\.1')
{
    Write-Check 'Entry point requirement' '#Requires -Version 5.1'
}
else
{
    $Failures.Add('WindowsTweaker.ps1 has no #Requires -Version 5.1 statement')
    Write-Check 'Entry point requirement' 'missing'
}

$Manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $Root 'src/WindowsTweaker/WindowsTweaker.psd1')
if ([version]$Manifest.PowerShellVersion -gt [version]'5.1')
{
    $Failures.Add("The module manifest declares PowerShellVersion $($Manifest.PowerShellVersion); 5.1 could not import it")
}
if (@($Manifest.CompatiblePSEditions) -notcontains 'Desktop' -or @($Manifest.CompatiblePSEditions) -notcontains 'Core')
{
    $Failures.Add('The module manifest does not declare both Desktop and Core compatible editions')
}
Write-Check 'Module manifest floor' ("PowerShellVersion {0}, editions {1}" -f $Manifest.PowerShellVersion, (@($Manifest.CompatiblePSEditions) -join '/'))

$BootstrapPath = Join-Path $Root 'bootstrap/bootstrap.ps1'
$BootstrapText = [System.IO.File]::ReadAllText($BootstrapPath)
if ($BootstrapText -match 'YOUR_GITHUB_OWNER')
{
    $Failures.Add('bootstrap/bootstrap.ps1 still contains the YOUR_GITHUB_OWNER placeholder')
}
if ($BootstrapText -notmatch '88kbleirad/WindowsTweaker')
{
    $Failures.Add('bootstrap/bootstrap.ps1 does not name the real repository')
}
# A comment may explain these variables and Get-Variable may read them (that is how a
# 5.1-safe file reaches them); an actual variable expression is what must not appear. The AST
# distinguishes the two, a regular expression does not.
$BootstrapTokens = $null
$BootstrapErrors = $null
$BootstrapAst = [System.Management.Automation.Language.Parser]::ParseFile($BootstrapPath, [ref]$BootstrapTokens, [ref]$BootstrapErrors)
$AutomaticVariables = @($BootstrapAst.FindAll({
            param($Node)
            $Node -is [System.Management.Automation.Language.VariableExpressionAst] -and
            @('IsWindows', 'IsLinux', 'IsMacOS') -contains $Node.VariablePath.UserPath
        }, $true))
if ($AutomaticVariables.Count -gt 0)
{
    foreach ($Variable in $AutomaticVariables)
    {
        Write-Host ("  bare automatic variable: {0} (line {1})" -f $Variable.Extent.Text, $Variable.Extent.StartLineNumber)
    }
    $Failures.Add('bootstrap/bootstrap.ps1 references $IsWindows/$IsLinux/$IsMacOS directly (absent in 5.1)')
}
if ($BootstrapText -match '-Encoding\s+utf8NoBOM')
{
    $Failures.Add('bootstrap/bootstrap.ps1 uses -Encoding utf8NoBOM, which PowerShell 5.1 rejects')
}
Write-Check 'Bootstrap runtime policy' $(if ($BootstrapText -match 'Get-WtBootstrapRuntimeProfile') { 'runtime profile present' } else { 'runtime profile missing' })
if ($BootstrapText -notmatch 'Get-WtBootstrapRuntimeProfile')
{
    $Failures.Add('bootstrap/bootstrap.ps1 does not probe the runtime through its own profile helper')
}

Write-Host ''
if ($Failures.Count -eq 0)
{
    Write-Host 'COMPATIBILITY GATE PASSED'
    exit 0
}

foreach ($Failure in $Failures)
{
    Write-Host ("FAILED: {0}" -f $Failure)
}
exit 1