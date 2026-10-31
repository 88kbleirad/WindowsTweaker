# Parses every PowerShell file in the repository with the PowerShell AST parser and
# fails when any file has a syntax error.
#
# Usage:
#   pwsh -NoProfile -File tools/Parse-All.ps1 [-Path <directory>]

[CmdletBinding()]
param
(
    [Parameter(Mandatory = $false)]
    [string]$Path = (Split-Path -Path $PSScriptRoot -Parent),

    # Directory names to skip. The default keeps the unreviewed reference material out
    # of the report; use -ExcludePath @() to parse absolutely everything.
    [Parameter(Mandatory = $false)]
    [string[]]$ExcludePath = @('reference')
)

$Errors = 0
$SkipPattern = if ($ExcludePath.Count -gt 0)
{
    '[\\/](' + (($ExcludePath | ForEach-Object { [regex]::Escape($_) }) -join '|') + '|\.git)[\\/]'
}
else
{
    '[\\/]\.git[\\/]'
}

$Files = @(Get-ChildItem -Path $Path -Filter '*.ps1' -File -Recurse |
    Where-Object { $_.FullName -notmatch $SkipPattern })
$DataFiles = @(Get-ChildItem -Path $Path -Filter '*.psd1' -File -Recurse |
    Where-Object { $_.FullName -notmatch $SkipPattern })

$Results = @()

foreach ($File in ($Files + $DataFiles))
{
    $ParseErrors = $null
    $Tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($File.FullName, [ref]$Tokens, [ref]$ParseErrors)

    if ($ParseErrors -and $ParseErrors.Count -gt 0)
    {
        $Errors += $ParseErrors.Count
        $Results += [pscustomobject]@{
            File   = $File.FullName.Substring($Path.Length).TrimStart('\', '/')
            Line   = $ParseErrors[0].Extent.StartLineNumber
            Id     = $ParseErrors[0].ErrorId
            Detail = $ParseErrors[0].Message
        }
    }
}

if ($Results.Count -gt 0)
{
    $Results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}

Write-Host ("Files parsed : {0}" -f ($Files.Count + $DataFiles.Count))
Write-Host ("Skipped dirs : {0}" -f $(if ($ExcludePath.Count -gt 0) { $ExcludePath -join ', ' } else { 'none' }))
Write-Host ("Parse errors : {0}" -f $Errors)

if ($Errors -gt 0)
{
    exit 1
}

exit 0
