# WindowsTweaker - public device/driver inventory (read-only).

<#
.SYNOPSIS
    Returns the read-only device and driver inventory.
.DESCRIPTION
    Device nodes (with OS-reported state, hardware IDs, bound driver INF, provider, version
    and signature status) and Driver Store packages are returned separately. Non-present
    devices are reported exactly as the OS reports them and are never labelled unused or
    safe to delete, and this API performs no removal.
#>
function Get-WtDeviceInventory
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ()

    $Result = Get-WtDeviceInventoryInternal
    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.DeviceInventory'
        Available  = [bool]$Result.Available
        Reason     = [string]$Result.Reason
        Devices    = @($Result.Devices)
        Packages   = @($Result.Packages)
        StateSummary = [ordered]@{
            Present    = @($Result.Devices | Where-Object { $_.State -eq 'Present' }).Count
            NonPresent = @($Result.Devices | Where-Object { $_.State -eq 'NonPresent' }).Count
            Unknown    = @($Result.Devices | Where-Object { $_.State -eq 'Unknown' }).Count
            Problem    = @($Result.Devices | Where-Object { $_.State -eq 'PresentProblem' }).Count
        }
    }
}
