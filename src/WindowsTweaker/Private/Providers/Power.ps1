# WindowsTweaker - read-only power settings explorer and SRUM application history.
#
# Power settings are read from the documented `powercfg` tool (active plan, per-GUID
# settings with AC/DC values). This module is read-only and never imports power plans or
# changes settings; any later edit must go through the existing preview/restore engine.
#
# SRUM application history (network bytes, CPU cycles where available, disk I/O) is
# optional and depends on a stable, supported source. None exists for PowerShell 7 on
# current Windows releases, so the provider reports itself Unavailable with the reasons,
# and the report is a contract for a future backend: unattributed records, observed time
# ranges, data availability and collection status are separate fields, and missing records
# are never presented as proof of zero activity. Nothing here enables services or clears
# databases.

<#
.SYNOPSIS
    Parses `powercfg /q` text into structured setting rows (pure, testable).
#>
function ConvertFrom-WtPowerCfgText
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param ([Parameter(Mandatory = $true)][string]$Text)

    $Rows = [System.Collections.Generic.List[object]]::new()
    $CurrentGroup = ''
    $CurrentSetting = ''
    $CurrentSettingName = ''
    $CurrentSettingAc = $null
    $CurrentSettingDc = $null
    $CurrentPossible = @()

    foreach ($Line in @($Text -split "`r?`n"))
    {
        $Trimmed = $Line.Trim()
        if (-not $Trimmed) { continue }

        if ($Trimmed -match '^Subgroup GUID:\s*(\{?[0-9A-Fa-f-]+\}?)\s+\((.*)\)\s*$')
        {
            $CurrentGroup = $Matches[2].Trim()
            continue
        }

        if ($Trimmed -match '^Power Setting GUID:\s*(\{?[0-9A-Fa-f-]+\}?)\s+\((.*)\)\s*$')
        {
            # Flush the previous setting.
            if ($CurrentSetting)
            {
                $Rows.Add([pscustomobject]@{
                    Group = $CurrentGroup
                    SettingGuid = $CurrentSetting
                    Name = $CurrentSettingName
                    AcValue = $CurrentSettingAc
                    DcValue = $CurrentSettingDc
                    Possible = @($CurrentPossible)
                    Source = 'powercfg /q'
                })
            }

            $CurrentSetting = $Matches[1].Trim('{', '}')
            $CurrentSettingName = $Matches[2].Trim()
            $CurrentSettingAc = $null
            $CurrentSettingDc = $null
            $CurrentPossible = @()
            continue
        }

        if ($Trimmed -match '^Current AC Power Setting Index:\s*(.+)$')
        {
            $CurrentSettingAc = $Matches[1].Trim()
            continue
        }

        if ($Trimmed -match '^Current DC Power Setting Index:\s*(.+)$')
        {
            $CurrentSettingDc = $Matches[1].Trim()
            continue
        }

        if ($Trimmed -match '^Possible Setting Index Friendly Name:\s*(.+)$')
        {
            $CurrentPossible += $Matches[1].Trim()
            continue
        }
    }

    if ($CurrentSetting)
    {
        $Rows.Add([pscustomobject]@{
            Group = $CurrentGroup
            SettingGuid = $CurrentSetting
            Name = $CurrentSettingName
            AcValue = $CurrentSettingAc
            DcValue = $CurrentSettingDc
            Possible = @($CurrentPossible)
            Source = 'powercfg /q'
        })
    }

    return @($Rows.ToArray())
}

<#
.SYNOPSIS
    Reads the active power plan and its settings (read-only).
.DESCRIPTION
    Uses `powercfg` on Windows. On other platforms (or when powercfg is missing) the
    result reports itself Unavailable; it never guesses a plan.
#>
function Get-WtPowerSettingsInternal
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    if (-not $IsWindows)
    {
        return @{
            Available = $false
            Reason = Get-WtString -Key 'Power.OnlyWindows'
            ActivePlanGuid = ''
            ActivePlanName = ''
            Settings = @()
        }
    }

    $PowerCfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
    if (-not (Test-Path -LiteralPath $PowerCfg))
    {
        return @{
            Available = $false
            Reason = Get-WtString -Key 'Power.NoPowerCfg'
            ActivePlanGuid = ''
            ActivePlanName = ''
            Settings = @()
        }
    }

    $Active = ''
    try
    {
        $Active = (& $PowerCfg /getactivescheme 2>&1 | Out-String)
    }
    catch
    {
        return @{ Available = $false; Reason = $_.Exception.Message; ActivePlanGuid = ''; ActivePlanName = ''; Settings = @() }
    }

    $PlanGuid = ''
    $PlanName = ''
    if ($Active -match '\((\{?[0-9A-Fa-f-]+\}?)\)\s*(.+)?$' -or $Active -match 'GUID:\s*(\{?[0-9A-Fa-f-]+\}?)\s+\((.*)\)')
    {
        $PlanGuid = $Matches[1].Trim('{', '}')
        $PlanName = $Matches[2].Trim()
    }
    elseif ($Active -match '\((\{?[0-9A-Fa-f-]+\}?)\)')
    {
        $PlanGuid = $Matches[1].Trim('{', '}')
    }

    $Settings = @()
    if ($PlanGuid)
    {
        try
        {
            $Query = (& $PowerCfg /q $PlanGuid 2>&1 | Out-String)
            $Settings = @(ConvertFrom-WtPowerCfgText -Text $Query)
        }
        catch
        {
            $Settings = @()
        }
    }

    return @{
        Available = $true
        Reason = ''
        ActivePlanGuid = $PlanGuid
        ActivePlanName = $PlanName
        Settings = $Settings
    }
}

<#
.SYNOPSIS
    Returns the SRUM application-history availability and contract (read-only).
#>
function Get-WtSrumHistoryInternal
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    # No documented, supported public API exposes SRUM to PowerShell 7. The report states
    # that, offers the schema a future backend would fill, and never claims zero activity
    # from missing records.
    return @{
        Available = $false
        Reason = Get-WtString -Key 'Srum.NoProvider'
        CollectionStatus = 'NotCollected'
        ObservedFrom = $null
        ObservedTo = $null
        Records = @()
        Unattributed = 0
        NetworkBytes = 0
        CpuCycles = $null
        DiskIo = $null
        Notes = @(
            'Missing records are not proof of zero activity.',
            'No service is enabled and no database is cleared to populate this view.',
            'Historical counters are not live utilization.'
        )
    }
}
