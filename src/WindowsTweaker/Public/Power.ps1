# WindowsTweaker - public power settings explorer and SRUM history (read-only).

<#
.SYNOPSIS
    Returns the active power plan identity and its settings with AC/DC values.
.DESCRIPTION
    Read-only, from `powercfg`. On a host where powercfg is unavailable the result reports
    Unavailable. No OEM plan is replaced and no plan is imported; any future edit must use
    the existing preview and original-state restoration mechanism.
#>
function Get-WtPowerSettings
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ()

    $Result = Get-WtPowerSettingsInternal
    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.PowerSettings'
        Available  = [bool]$Result.Available
        Reason     = [string]$Result.Reason
        ActivePlanGuid = [string]$Result.ActivePlanGuid
        ActivePlanName = [string]$Result.ActivePlanName
        Settings   = @($Result.Settings)
    }
}

<#
.SYNOPSIS
    Returns the SRUM application history availability and contract (read-only).
.DESCRIPTION
    Reports itself Unavailable on this build because no documented, supported public API
    exists for PowerShell 7. The shape still states the data availability, observed range,
    unattributed records and counter types; missing records are never presented as proof of
    zero activity.
#>
function Get-WtSrumHistory
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ()

    $Result = Get-WtSrumHistoryInternal
    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.SrumHistory'
        Available  = [bool]$Result.Available
        Reason     = [string]$Result.Reason
        CollectionStatus = [string]$Result.CollectionStatus
        ObservedFrom = $Result.ObservedFrom
        ObservedTo = $Result.ObservedTo
        Records = @($Result.Records)
        Unattributed = [int]$Result.Unattributed
        NetworkBytes = [long]$Result.NetworkBytes
        CpuCycles = $Result.CpuCycles
        DiskIo = $Result.DiskIo
        Notes = @($Result.Notes)
    }
}
