# WindowsTweaker - read-only device and driver inventory.
#
# Two different things are kept apart:
#
#   device nodes  - what Windows currently knows about the installed hardware
#                   (Win32_PnPEntity / Win32_PnPSignedDriver records);
#   driver store  - the package folders under the DriverStore (FileRepository), which
#                   are not devices.
#
# Device state is read from the system's own reporting, never inferred from absence:
# a device that is not present is reported as not present, with the OS-provided reason,
# and that is never labelled "unused" or "safe to delete". A query that fails reports
# 'Unreadable' rows with the box, not an empty success. Unknown or incomplete inventory
# never authorizes removal - and this module performs no removal at all.

<#
.SYNOPSIS
    Reports whether a Driver Store directory exists (single seam for tests).
#>
function Test-WtDriverStorePath
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ([Parameter(Mandatory = $true)][string]$Path)

    return [bool](Test-Path -LiteralPath $Path -PathType Container)
}

<#
.SYNOPSIS
    Lists the Driver Store package folders (single seam for tests).
#>
function Get-WtDriverStoreFolders
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param ([Parameter(Mandatory = $true)][string]$Path)

    return @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction Stop | Sort-Object -Property Name)
}

<#
.SYNOPSIS
    Returns the Win32_PnPSignedDriver rows (read-only, single seam).
.DESCRIPTION
    The only place this provider touches the CIM command; tests replace this function, so
    the rest of the inventory can be asserted on any platform.
#>
function Get-WtCimDriverRows
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param ()

    return @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop)
}

<#
.SYNOPSIS
    Enumerates device nodes with their bound driver records (read-only).
.DESCRIPTION
    Uses Win32_PnPSignedDriver when available, which correlates a device node with its
    bound driver package: INF file, provider, version and signature. Devices without a
    driver record are reported with correlation source 'None'; devices the OS reports as
    not present keep their ConfigManagerErrorCode and are never called unused. On a host
    without the CIM provider the result is explicitly unavailable, never empty.
.OUTPUTS
    @{ Available; Reason; Devices; Packages }
#>
function Get-WtDeviceInventoryInternal
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    $Devices = [System.Collections.Generic.List[object]]::new()
    $Packages = [System.Collections.Generic.List[object]]::new()

    $Environment = Get-WtEnvironmentInternal
    if (-not $Environment.IsWindows)
    {
        return @{
            Available = $false
            Reason = Get-WtString -Key 'Dev.OnlyWindows'
            Devices = @()
            Packages = @()
        }
    }

    $Rows = @()
    try
    {
        $Rows = @(Get-WtCimDriverRows)
    }
    catch
    {
        return @{
            Available = $false
            Reason = Get-WtString -Key 'Dev.QueryFailed' -Arguments @($_.Exception.Message)
            Devices = @()
            Packages = @()
        }
    }

    foreach ($Row in $Rows)
    {
        if (-not $Row.DeviceID)
        {
            continue
        }

        # Windows marks a device that is present but not working, or not present at all,
        # with a ConfigManagerErrorCode; the device stays listed with exactly that code.
        $Present = $false
        $State = 'Unknown'
        $ErrorCode = [int]$Row.ConfigManagerErrorCode

        switch ($ErrorCode)
        {
            0
            {
                $Present = $true
                $State = 'Present'
            }
            22
            {
                $State = 'NonPresent'
            }
            24
            {
                $State = 'NonPresent'
            }
            default
            {
                if ($ErrorCode -gt 0)
                {
                    $State = 'PresentProblem'
                }
            }
        }

        if (-not (Test-WtDeviceStatusPresent -Status ([string]$Row.Status)))
        {
            if ($State -eq 'Present') { $State = 'Unknown' }
        }

        # Confidence and source of the device-to-package correlation: this record comes
        # straight from the OS's own binding list, so it is Established when a driver is
        # recorded, and None (no binding recorded) when only hardware is known.
        $HasDriver = [bool]([string]$Row.InfName -or [string]$Row.DriverProviderName -or [string]$Row.DriverVersion)
        $Correlation = if ($HasDriver) { 'Established' } else { 'None' }
        $Confidence = if ($HasDriver) { 'DeviceDriverBinding' } else { 'DeviceOnly' }

        $Devices.Add([pscustomobject]@{
            PSTypeName      = 'WindowsTweaker.Device'
            DeviceId        = [string]$Row.DeviceID
            Name            = [string]$Row.DeviceName
            Class           = [string]$Row.DeviceClass
            State           = $State
            Present         = $Present
            ConfigManagerErrorCode = $ErrorCode
            Status          = [string]$Row.Status
            HardwareIds     = @($Row.HardwareID)
            InfName         = [string]$Row.InfName
            Provider        = [string]$Row.DriverProviderName
            DriverVersion   = [string]$Row.DriverVersion
            DriverDate      = [string]$Row.DriverDate
            IsSigned        = $null
            SignatureStatus = [string]$Row.SignerName
            Confidence      = $Confidence
            CorrelationSource = $Correlation
        })
    }

    # Driver Store packages are enumerated separately: they are folders, not devices, and
    # no device-to-package correlation is invented here.
    $SystemRoot = [string]$env:SystemRoot
    if (-not $SystemRoot) { $SystemRoot = 'C:\Windows' }
    # Join-Path would resolve 'C:' as a drive on non-Windows hosts; build the store path
    # with plain concatenation so the provider stays testable off Windows.
    $StorePath = $SystemRoot.TrimEnd('\', '/') + '\System32\DriverStore\FileRepository'
    if (Test-WtDriverStorePath -Path $StorePath)
    {
        try
        {
            $Folders = @(Get-WtDriverStoreFolders -Path $StorePath)
            foreach ($Folder in $Folders)
            {
                $Packages.Add([pscustomobject]@{
                    PSTypeName = 'WindowsTweaker.DriverStorePackage'
                    Name       = $Folder.Name
                    Path       = $Folder.FullName
                    IsDevice   = $false
                })
            }
        }
        catch
        {
            # The store exists but could not be read; this is reported, never hidden.
            $Packages.Add([pscustomobject]@{
                PSTypeName = 'WindowsTweaker.DriverStorePackage'
                Name       = '(unreadable)'
                Path       = $StorePath
                IsDevice   = $false
                Error      = $_.Exception.Message
            })
        }
    }

    return @{
        Available = $true
        Reason = ''
        Devices = @($Devices.ToArray())
        Packages = @($Packages.ToArray())
    }
}

<#
.SYNOPSIS
    Reports whether a device status string means the device is present (read-only).
#>
function Test-WtDeviceStatusPresent
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ([Parameter(Mandatory = $true)][string]$Status)

    switch ($Status)
    {
        'OK' { return $true }
        'Degraded' { return $true }
        'Pred Fail' { return $true }
        'Starting' { return $true }
        'Stopping' { return $true }
        'Running' { return $true }
        default { return $false }
    }
}
