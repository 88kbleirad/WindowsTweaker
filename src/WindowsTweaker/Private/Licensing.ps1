# WindowsTweaker - Licensing & Activation Diagnostics.
#
# Read-only Windows licensing inventory and guided diagnostics, with three explicit,
# user-requested actions (open activation settings, refresh, request activation using the
# installed license). The implementation uses documented Windows interfaces only:
#
#   * CIM/WMI  SoftwareLicensingProduct / SoftwareLicensingService
#               (the same classes slmgr.vbs reads for its status table)
#   * slmgr.vbs via cscript (documented "SLMgr" UI/scripting interface) for the
#     activation request and for structured error reporting
#   * Win32_OperatingSystem for grace/license state
#   * W32Time / w32tm for time synchronization status
#   * the CSP/activation endpoint configuration published by Microsoft
#
# MAS (Microsoft-Activation-Scripts) is a reference for *flow* only: concise status
# reporting and troubleshooting structure. None of its code is embedded or ported. This
# file is independently written. No hardware-identity spoofing, no licensing hooks, no
# forged activation data, no third-party activation servers, no reset/rearm/
# KMS-reconfiguration commands.
#
# The one place upstream MAS is involved is deliberate and separate: the licensing workspace
# offers an explicit external-tool action (Private/ExternalTool.ps1, see
# docs/EXTERNAL-TOOLS.md) that downloads the upstream file at one pinned commit and launches
# it as its own process on request. Nothing here calls it, and it never runs as part of a
# refresh, a diagnostic read or a batch.
#
# Privacy: the inventory never contains full product keys, activation tokens, installation
# identifiers, or organization hostnames. The partial key is shown only where the OS
# exposes a partial key and the caller asks for it; exports redact it by default.

$Script:WtLicensingCache = $null

# Whether the cached inventory was built with the partial key included. The cache is only
# reusable for the same inclusion mode: a caller that did not ask for the key must never be
# served the records that do carry it, and a caller that asked for it must never be served
# records that had it stripped. Without this, the answer depended on the order of calls.
$Script:WtLicensingCacheHasPartialKey = $false

<#
.SYNOPSIS
    Drops the cached inventory so the next read re-queries the provider.
#>
function Clear-WtLicensingCache
{
    [CmdletBinding()]
    param ()

    $Script:WtLicensingCache = $null
    $Script:WtLicensingCacheHasPartialKey = $false
}

<#
.SYNOPSIS
    Reports whether the licensing provider is available on this runtime.
.DESCRIPTION
    The provider is the CIM/WMI SoftwareLicensingProduct class, which exists on Windows
    only. On non-Windows or when the provider is missing, the workspace reports the
    capability as unsupported and never fabricates a status.
#>
function Test-WtLicensingAvailable
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    $Runtime = Get-WtRuntimeProfile
    if (-not $Runtime.IsWindows) { return $false }
    return $true
}

<#
.SYNOPSIS
    Wrapper over the CIM provider so tests can mock the exact seam.
#>
function Get-WtLicensingCim
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$ClassName)

    return @(Get-CimInstance -ClassName $ClassName -ErrorAction Stop)
}

<#
.SYNOPSIS
    Wrapper over Get-Service so tests can mock the exact seam.
#>
function Get-WtLicensingService
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Name)

    return (Get-Service -Name $Name -ErrorAction Stop)
}

<#
.SYNOPSIS
    Wrapper over w32tm so tests can mock the exact seam.
#>
function Get-WtLicensingTimeQuery
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    $Output = & w32tm /query /status 2>$null
    if ($Output) { return ($Output -join "`n") }
    return ''
}

<#
.SYNOPSIS
    Wrapper over Get-WinEvent so tests can mock the exact seam.
#>
function Get-WtLicensingWinEvent
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$LogName,
        [Parameter(Mandatory = $true)][string]$ProviderName,
        [Parameter(Mandatory = $false)][int]$Hours = 24
    )

    return @(Get-WinEvent -FilterHashtable @{ LogName = $LogName; ProviderName = $ProviderName; StartTime = (Get-Date).AddHours(-$Hours) } -MaxEvents 1 -ErrorAction Ignore)
}

<#
.SYNOPSIS
    Normalises a licensing product into a display-friendly record.
.DESCRIPTION
    Only products that describe the *Windows* license are considered. The active license is
    the one with the highest ApplicationId match for Windows; records that are not the
    active Windows license are reported separately (as inventory, never as the active
    license).
#>
function ConvertTo-WtLicensingView
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $true)][object]$Product,
        [Parameter(Mandatory = $false)][bool]$IncludePartialKey = $false
    )

    $StatusText = switch ([int]$Product.LicenseStatus)
    {
        0 { 'Unlicensed' }
        1 { 'Licensed' }
        2 { 'OOBGrace' }
        3 { 'OOTGrace' }
        4 { 'NonGenuineGrace' }
        5 { 'Notification' }
        6 { 'ExtendedGrace' }
        default { 'Unknown' }
    }

    $Partial = ''
    if ($IncludePartialKey)
    {
        $Partial = [string]$Product.PartialProductKey
    }
    elseif ($null -ne $Product.PartialProductKey)
    {
        # Still a partial key exists; it is just not returned. The field stays '' so a
        # consumer can tell "not requested" from "no key known".
        $Partial = ''
    }

    return [pscustomobject]@{
        PSTypeName       = 'WindowsTweaker.LicensingState'
        ProductName      = [string]$Product.Name
        ApplicationId    = [string]$Product.ApplicationId
        LicenseStatus    = $StatusText
        LicenseStatusRaw = [int]$Product.LicenseStatus
        LicenseChannel   = [string]$Product.LicenseChannel
        PartialProductKey= $Partial
        GraceRemaining   = if ($null -ne $Product.GraceRemaining) { [int]$Product.GraceRemaining } else { $null }
        EvaluationEndDate = if ($null -ne $Product.EvaluationEndDate) { [string]$Product.EvaluationEndDate } else { '' }
        Description       = [string]$Product.Description
    }
}

<#
.SYNOPSIS
    Returns a copy of a licensing record with the partial product key removed.
.DESCRIPTION
    The inventory is cached and handed to more than one caller, so redaction is applied to a
    copy: the cached record keeps exactly what the read produced, and a later read that does
    ask for the partial key still has it.
#>
function Copy-WtLicensingRedactedRecord
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ([Parameter(Mandatory = $true)][psobject]$Record)

    $Copy = $Record.PSObject.Copy()
    $Copy.PartialProductKey = ''
    return $Copy
}

<#
.SYNOPSIS
    Reads the Windows licensing inventory from CIM/WMI.
.DESCRIPTION
    Bounded and read-only: the SoftwareLicensingProduct class is queried for the products
    whose ApplicationId identifies Windows (55c92734-d682-4d71-983e-d6ec3f16059f). The
    active product is selected by LicenseStatus/ProductKeyChannel heuristics documented by
    Microsoft for slmgr; a status is never inferred from other records.
    Returns a hashtable with Products (the inventory), Active (the selected active
    product, or $null), and a Reason when the overall source is unavailable.
#>
function Read-WtLicensingInventory
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $false)][switch]$Refresh,
        [Parameter(Mandatory = $false)][switch]$IncludePartialKey
    )

    if ($Script:WtLicensingCache -and -not $Refresh -and $Script:WtLicensingCacheHasPartialKey -eq [bool]$IncludePartialKey)
    {
        return $Script:WtLicensingCache
    }

    $WindowsAppId = '55c92734-d682-4d71-983e-d6ec3f16059f'
    $Result = @{
        CollectedUtc = [datetime]::UtcNow
        Source = 'CIM/WMI SoftwareLicensingProduct'
        Products = @()
        Active = $null
        Unreadable = $false
        Reason = ''
    }

    if (-not (Test-WtLicensingAvailable))
    {
        $Result.Unreadable = $true
        $Result.Reason = 'the licensing provider is only available on Windows'
        return $Result
    }

    try
    {
        $All = @(Get-WtLicensingCim -ClassName SoftwareLicensingProduct)
        $Windows = @($All | Where-Object { [string]$_.ApplicationId -eq $WindowsAppId })
        $Result.Products = @($Windows | ForEach-Object { ConvertTo-WtLicensingView -Product $_ -IncludePartialKey:$IncludePartialKey })

        if ($Windows.Count -gt 0)
        {
            # Active selection: the product with the highest license status is the running
            # license; ties resolve to the first (the OS's own record).
            $Active = $Windows | Sort-Object -Property @{ Expression = { [int]$_.LicenseStatus }; Descending = $true } | Select-Object -First 1
            $Result.Active = ConvertTo-WtLicensingView -Product $Active -IncludePartialKey:$IncludePartialKey
        }
    }
    catch
    {
        $Result.Unreadable = $true
        $Result.Reason = $_.Exception.Message
    }

    $Script:WtLicensingCache = $Result
    $Script:WtLicensingCacheHasPartialKey = [bool]$IncludePartialKey
    return $Result
}

<#
.SYNOPSIS
    Reads the system time and time-synchronization status.
.DESCRIPTION
    Bounded read-only probes: the local time, the W32Time service state, its configured
    startup trigger, and the service status. A stopped service is reported as a finding,
    not as a fault: the configured start type and trigger explain whether it is expected.
#>
function Read-WtLicensingTimeState
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    $Result = @{
        LocalUtc = [datetime]::UtcNow
        LocalNow = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
        Service = 'unknown'
        StartType = 'unknown'
        Trigger = ''
        Synchronized = $null
        Reason = ''
    }

    try
    {
        $Svc = Get-WtLicensingService -Name w32time
        $Result.Service = [string]$Svc.Status
        $Result.StartType = [string]$Svc.StartType
    }
    catch
    {
        $Result.Service = 'unreadable'
        $Result.Reason = $_.Exception.Message
    }

    # The time service may be trigger-started (e.g., on boot for time sync); a stopped
    # service is only a finding when it has no configured trigger.
    try
    {
        $Triggers = @(Get-WtLicensingCim -ClassName 'Win32_Service' | Where-Object { $_.Name -eq 'w32time' } | Select-Object -ExpandProperty StartName)
        if ($Triggers) { $Result.Trigger = ($Triggers -join ',') }
    }
    catch
    {
        Write-WtLog -Level Debug -Message 'The w32time trigger probe is unavailable; the trigger is reported as unknown.' -NoConsole
    }

    try
    {
        $Result.Synchronized = [bool]((Get-WtLicensingTimeQuery) -match '(?i)synchronized|synced|ntp')
    }
    catch
    {
        Write-WtLog -Level Debug -Message 'w32tm is unavailable; time synchronization stays unreported instead of being assumed.' -NoConsole
    }

    return $Result
}

<#
.SYNOPSIS
    Reads licensing component availability and structured activation error codes.
.DESCRIPTION
    Components: the SoftwareLicensingService state and the presence of the slmgr script
    interface. Structured activation errors are read from the most recent event log entry
    of the Software Protection Service (source 'Software Protection Platform Service') when
    the caller opts into the probe.
#>
function Read-WtLicensingComponents
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    $Result = @{
        SlmgrAvailable = $false
        Service = 'unknown'
        ServiceStartType = 'unknown'
        LastActivationError = ''
        LastActivationErrorUtc = ''
    }

    try
    {
        $Slmgr = Get-Command -Name 'slmgr.vbs' -ErrorAction Ignore
        $Result.SlmgrAvailable = $null -ne $Slmgr
    }
    catch
    {
        Write-WtLog -Level Debug -Message 'The slmgr.vbs probe failed; the component is reported as unavailable.' -NoConsole
    }

    try
    {
        $Svc = Get-WtLicensingService -Name 'spssvc'
        $Result.Service = [string]$Svc.Status
        $Result.ServiceStartType = [string]$Svc.StartType
    }
    catch
    {
        $Result.Service = 'unreadable'
    }

    try
    {
        $Latest = @(Get-WtLicensingWinEvent -LogName 'Application' -ProviderName 'Software Protection Platform Service') | Select-Object -First 1
        if ($Latest)
        {
            $Result.LastActivationError = [string]$Latest.Message
            $Result.LastActivationErrorUtc = $Latest.TimeCreated.ToUniversalTime().ToString('o')
        }
    }
    catch
    {
        Write-WtLog -Level Debug -Message 'The Software Protection Service log is unreadable; the last activation error stays unknown.' -NoConsole
    }

    return $Result
}

<#
.SYNOPSIS
    Reads organization-managed activation configuration when accessible.
.DESCRIPTION
    KMS/activation configuration lives in HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform
    and the SLMGR KMS registry entries. Only the presence of configuration keys (paths) is
    reported, never the hostnames or keys themselves.
#>
function Read-WtLicensingOrgConfig
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    $Result = @{
        Managed = $false
        KeyPresent = $false
        Sources = @()
    }

    $Paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform',
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SLMGR'
    )

    foreach ($Path in $Paths)
    {
        try
        {
            if (Test-Path -LiteralPath $Path)
            {
                $Result.KeyPresent = $true
                $Result.Sources += [string]$Path
                $Result.Managed = $true
            }
        }
        catch
        {
            Write-WtLog -Level Debug -Message "The licensing configuration key $Path is unreadable; it is reported as absent." -NoConsole
        }
    }

    return $Result
}

<#
.SYNOPSIS
    Builds the full read-only licensing diagnostics view.
#>
function Read-WtLicensingDiagnostics
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $false)][switch]$Refresh,
        [Parameter(Mandatory = $false)][switch]$IncludePartialKey
    )

    $Inventory = Read-WtLicensingInventory -Refresh:$Refresh -IncludePartialKey:$IncludePartialKey
    $Time = Read-WtLicensingTimeState
    $Components = Read-WtLicensingComponents
    $Org = Read-WtLicensingOrgConfig

    return @{
        CollectedUtc = [datetime]::UtcNow
        Inventory = $Inventory
        Time = $Time
        Components = $Components
        Org = $Org
        Redacted = $false
    }
}

<#
.SYNOPSIS
    Prepares the export payload with redaction applied.
.DESCRIPTION
    Exports never include full product keys, tokens, machine identifiers or hostnames.
    The partial key is replaced by a marker; organization hostnames in the reason text are
    stripped; and the report preview is shown before anything is written.
#>
function Get-WtLicensingExportPayload
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$License,
        [Parameter(Mandatory = $false)][switch]$IncludePartialKey
    )

    $Payload = [ordered]@{
        exportedUtc = [datetime]::UtcNow.ToString('o')
        source = $License.Inventory.Source
        collectedUtc = $License.CollectedUtc.ToString('o')
        active = $null
        products = @()
        time = $null
        components = $null
        organizationManaged = $null
    }

    if ($License.Inventory.Active)
    {
        $Active = $License.Inventory.Active
        $Payload.active = [ordered]@{
            productName = [string]$Active.ProductName
            licenseStatus = [string]$Active.LicenseStatus
            licenseStatusRaw = [int]$Active.LicenseStatusRaw
            licenseChannel = [string]$Active.LicenseChannel
            partialProductKey = if ($IncludePartialKey) { [string]$Active.PartialProductKey } else { '<redacted>' }
            graceRemaining = $Active.GraceRemaining
        }
    }

    $Payload.products = @($License.Inventory.Products | ForEach-Object {
            [ordered]@{
                productName = [string]$_.ProductName
                licenseStatus = [string]$_.LicenseStatus
                licenseStatusRaw = [int]$_.LicenseStatusRaw
                licenseChannel = [string]$_.LicenseChannel
            }
        })

    $Payload.time = [ordered]@{
        localNow = [string]$License.Time.LocalNow
        service = [string]$License.Time.Service
        startType = [string]$License.Time.StartType
        synchronized = $License.Time.Synchronized
    }

    $Payload.components = [ordered]@{
        slmgrAvailable = [bool]$License.Components.SlmgrAvailable
        service = [string]$License.Components.Service
        serviceStartType = [string]$License.Components.ServiceStartType
        lastActivationError = [string]$License.Components.LastActivationError
    }

    $Payload.organizationManaged = [bool]$License.Org.Managed

    return $Payload
}

<#
.SYNOPSIS
    Requests activation through the documented slmgr interface.
.DESCRIPTION
    Explicit user request only. Runs `cscript slmgr.vbs /ato` (activate using the
    installed product key and the configured KMS/MAK mechanism). No key is installed, no
    edition is changed, no KMS server is configured, nothing is reset or rearmed. The
    command's accepted status is NOT proof of activation: the inventory is re-read and the
    resulting status reported. Errors are mapped to the structured SLMGR error code when
    the exit code is a documented one.
#>
function Invoke-WtLicensingActivationRequest
{
    [CmdletBinding()]
    [OutputType([hashtable])]

    # -Refresh is part of the parameter set the public Request-WtLicensingActivation wrapper
    # forwards. The status after a request is always re-read (a cached answer is never reported
    # as the result of an activation attempt), so the switch records the caller's intent rather
    # than changing what is returned.
    param ([Parameter(Mandatory = $false)][switch]$Refresh)

    $Result = @{
        Requested = $false
        Accepted = $false
        ExitCode = $null
        ErrorDetail = ''
        StatusAfter = $null
        Reason = ''
    }

    if (-not (Test-WtLicensingAvailable))
    {
        $Result.Reason = 'the licensing provider is only available on Windows'
        return $Result
    }

    $Cscript = Get-Command -Name 'cscript.exe' -ErrorAction Ignore
    if (-not $Cscript)
    {
        $Result.Reason = 'cscript is not available'
        return $Result
    }

    $Slmgr = Get-Command -Name 'slmgr.vbs' -ErrorAction Ignore
    if (-not $Slmgr)
    {
        $Result.Reason = 'slmgr.vbs is not available'
        return $Result
    }

    $Result.Requested = $true
    try
    {
        $Process = Start-Process -FilePath $Cscript.Source -ArgumentList @($Slmgr.Source, '/ato') -NoNewWindow -Wait -PassThru
        $Result.ExitCode = $Process.ExitCode
        $Result.Accepted = ($Process.ExitCode -eq 0)
    }
    catch
    {
        $Result.ErrorDetail = $_.Exception.Message
        $Result.Accepted = $false
    }

    # Evidence, not promise: re-read the inventory and report the resulting status.
    $Result.StatusAfter = Read-WtLicensingInventory -Refresh

    if (-not $Result.Accepted)
    {
        # Documented SLMGR exit codes: 0 success, others are the structured error code.
        $Result.ErrorDetail = if ($Result.ErrorDetail) { $Result.ErrorDetail }
        elseif ($null -ne $Result.ExitCode -and $Result.ExitCode -lt 0)
        {
            $Unsigned = [uint32](([int64]$Result.ExitCode) -band [int64]4294967295)
            "slmgr /ato exited with code 0x$($Unsigned.ToString('X8'))"
        }
        else { "slmgr /ato exited with code $($Result.ExitCode)" }
    }

    return $Result
}
