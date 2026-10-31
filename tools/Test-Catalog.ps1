# Validates the tweak catalog invariants without touching the system.
#
# Usage:
#   pwsh -NoProfile -File tools/Test-Catalog.ps1

[CmdletBinding()]
param ()

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Path $PSScriptRoot -Parent
$env:WT_LANG = 'en'

Import-Module (Join-Path $Root 'src/WindowsTweaker/WindowsTweaker.psd1') -Force

$Violations = @()

function Add-Violation
{
    param ([string]$TweakId, [string]$Rule, [string]$Detail)

    $script:Violations += [pscustomobject]@{ TweakId = $TweakId; Rule = $Rule; Detail = $Detail }
}

$Tweaks = @(Get-WtTweak)
$Ids = @($Tweaks | Select-Object -ExpandProperty Id)

Write-Host ("Tweaks in catalog : {0}" -f $Tweaks.Count)

# Duplicate ids cannot happen through Register-WtTweak, but a rename could still
# leave two definitions of the same setting from different files.
$Duplicates = @($Ids | Group-Object | Where-Object { $_.Count -gt 1 })
foreach ($Duplicate in $Duplicates)
{
    Add-Violation -TweakId $Duplicate.Name -Rule 'DuplicateId' -Detail 'defined more than once'
}

foreach ($Tweak in $Tweaks)
{
    if ($Tweak.Id -notmatch '^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z0-9][A-Za-z0-9_-]*)+$')
    {
        Add-Violation -TweakId $Tweak.Id -Rule 'IdFormat' -Detail 'id must look like Category.Setting'
    }

    foreach ($Field in 'Name', 'Description', 'Impact')
    {
        $Value = $Tweak.$Field
        if ($Value -isnot [hashtable] -or -not $Value.Contains('en') -or [string]::IsNullOrWhiteSpace([string]$Value['en']))
        {
            Add-Violation -TweakId $Tweak.Id -Rule 'Localization' -Detail "$Field must be a hashtable with an 'en' value"
        }
    }

    if (-not $Tweak.Detect)
    {
        Add-Violation -TweakId $Tweak.Id -Rule 'NoDetect' -Detail 'tweak has no read-only detector'
    }

    if (-not $Tweak.Apply)
    {
        Add-Violation -TweakId $Tweak.Id -Rule 'NoApply' -Detail 'tweak has no apply implementation'
    }

    if ($Tweak.Rollback -eq 'Full' -and $Tweak.Irreversible)
    {
        Add-Violation -TweakId $Tweak.Id -Rule 'IrreversibleRollback' -Detail 'irreversible tweaks must not claim full rollback'
    }

    if ($Tweak.ReducesProtection -eq $true -and $Tweak.Risk -ne 'High')
    {
        Add-Violation -TweakId $Tweak.Id -Rule 'ProtectionRisk' -Detail 'protection-reducing tweaks must be Risk High'
    }

    if (@($Tweak.StateNames).Count -gt 0 -and $Tweak.DefaultState -and (@($Tweak.StateNames) -notcontains $Tweak.DefaultState))
    {
        Add-Violation -TweakId $Tweak.Id -Rule 'DefaultState' -Detail "default state '$($Tweak.DefaultState)' is not a declared state"
    }

    foreach ($Requirement in @($Tweak.Requires))
    {
        if ($Requirement -notmatch '^(Cmdlet|Module|Admin|Windows|OS|Build):?')
        {
            Add-Violation -TweakId $Tweak.Id -Rule 'RequirementToken' -Detail "unknown requirement token '$Requirement'"
        }
    }

    if ($Tweak.States)
    {
        foreach ($StateName in $Tweak.States.Keys)
        {
            foreach ($Operation in @($Tweak.States[$StateName]))
            {
                if ($Operation.Kind -like 'Registry*' -and $Operation.ContainsKey('Path'))
                {
                    if ($Operation.Path -notmatch '^(HKLM|HKCU|HKCR|HKU|HKCC):\\')
                    {
                        Add-Violation -TweakId $Tweak.Id -Rule 'RegistryPath' -Detail "state '$StateName' uses a non-registry PowerShell path: $($Operation.Path)"
                    }

                    # `HKLM:\Policies\...` is a common mis-mapping of an LGPO relative policy
                    # path: machine policies live under HKLM\SOFTWARE\Policies.
                    if ($Operation.Path -match '^HKLM:\\Policies\\')
                    {
                        Add-Violation -TweakId $Tweak.Id -Rule 'RegistryPathPolicyHive' -Detail "state '$StateName' writes to HKLM:\Policies\... which is not where machine policies live: $($Operation.Path)"
                    }
                }
            }
        }
    }
}

# Two tweaks that detect and write the same registry value are the same setting with
# two ids: applying one would silently contradict the other.
$Targets = @{}
foreach ($Tweak in $Tweaks)
{
    $Detection = $Tweak.Detection
    if (-not $Detection -or -not $Detection.ContainsKey('Path'))
    {
        continue
    }

    $Key = "$(($Detection.Path))|$($Detection.Name)"
    if ($Targets.ContainsKey($Key))
    {
        Add-Violation -TweakId $Tweak.Id -Rule 'DuplicateTarget' -Detail "the same registry value is also handled by $($Targets[$Key]): $Key"
    }
    else
    {
        $Targets[$Key] = $Tweak.Id
    }
}

# Every tweak must survive a detection pass without throwing.
foreach ($State in @(Get-WtTweakState))
{
    if ($State.State -eq 'Unknown' -and -not $State.Details -and $State.Supported)
    {
        Add-Violation -TweakId $State.Id -Rule 'SilentUnknown' -Detail 'detection returned Unknown without an explanation'
    }
}

if ($Violations.Count -gt 0)
{
    $Violations | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
    Write-Host ("Violations : {0}" -f $Violations.Count)
    exit 1
}

Write-Host 'Catalog invariants: OK'
exit 0
