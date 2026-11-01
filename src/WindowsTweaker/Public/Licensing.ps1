# WindowsTweaker - public licensing diagnostics API (read-only, with explicit actions).

<#
.SYNOPSIS
    Returns the read-only Windows licensing diagnostics state.
.DESCRIPTION
    Product name, edition-derived build info, licensing status with the original status
    code, license channel, grace info, partial product key (only when explicitly
    requested), collection timestamp and the data source. The active product record is
    selected from the Windows licensing products; installed-but-inactive records are not
    mistaken for the active license. No full keys, tokens, installation identifiers or
    hostnames are returned.
.PARAMETER IncludePartialKey
    Include the partial product key (XXXXX-XXXXX-...-XXXXX "last five" style). Off by
    default; exports never include it unless the caller passes it through.
.OUTPUTS
    A hashtable with CollectedUtc, Source, Products (inventory), Active (single record),
    Unreadable and Reason.
#>
function Get-WtLicensingDiagnostics
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $false)][switch]$Refresh,
        [Parameter(Mandatory = $false)][switch]$IncludePartialKey
    )

    # The full diagnostics object is the same shape the TUI workspace renders; the public
    # surface only controls the partial-key inclusion.
    $Diagnostics = Read-WtLicensingDiagnostics -Refresh:$Refresh -IncludePartialKey:$IncludePartialKey

    if (-not $IncludePartialKey)
    {
        # The records behind this view are cached and shared, so the key is removed from
        # copies: blanking the records themselves would make a later -IncludePartialKey read
        # answer with the fields this call just redacted.
        $Inventory = $Diagnostics.Inventory.Clone()
        $Inventory.Active = if ($Inventory.Active) { Copy-WtLicensingRedactedRecord -Record $Inventory.Active } else { $null }
        $Inventory.Products = @($Inventory.Products | ForEach-Object { Copy-WtLicensingRedactedRecord -Record $_ })
        $Diagnostics.Inventory = $Inventory
    }

    return $Diagnostics
}

<#
.SYNOPSIS
    Returns time-synchronization and licensing-component diagnostics.
.OUTPUTS
    A hashtable with Time and Components.
#>
function Get-WtLicensingHealth
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    return @{
        Time = Read-WtLicensingTimeState
        Components = Read-WtLicensingComponents
        Org = Read-WtLicensingOrgConfig
    }
}

<#
.SYNOPSIS
    Requests activation using the installed license and the configured mechanism.
.DESCRIPTION
    Documented slmgr /ato. This is an explicit, privileged request; it never installs a
    key, changes edition, configures KMS, resets the licensing store or rearms. The
    returned StateAfter is the re-read inventory status - acceptance is not proof of
    activation.
.OUTPUTS
    A hashtable with Requested, Accepted, ExitCode, ErrorDetail, StatusAfter and Reason.
#>
function Request-WtLicensingActivation
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ([Parameter(Mandatory = $false)][switch]$Refresh)

    return (Invoke-WtLicensingActivationRequest -Refresh:$Refresh)
}

<#
.SYNOPSIS
    Exports the licensing diagnostics as redacted JSON.
.DESCRIPTION
    The report is built read-only, full keys/tokens/identifiers/hostnames are redacted by
    default, and the caller sees the preview before anything is written.
.PARAMETER Path
    Destination .json path.
.PARAMETER IncludePartialKey
    Include the partial product key in the export (off by default).
.OUTPUTS
    [string] the written path, or $null when cancelled.
#>
function Export-WtLicensingDiagnostics
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $false)][string]$Path,
        [Parameter(Mandatory = $false)][switch]$IncludePartialKey,
        [Parameter(Mandatory = $false)][switch]$Refresh
    )

    $Diagnostics = Get-WtLicensingDiagnostics -IncludePartialKey:$IncludePartialKey -Refresh:$Refresh
    $Payload = Get-WtLicensingExportPayload -License $Diagnostics -IncludePartialKey:$IncludePartialKey

    if (-not $Path)
    {
        $Path = Join-Path (Get-WtDataRoot) ("licensing-{0}.json" -f (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))
    }

    Write-WtTextFile -Path $Path -Value (ConvertTo-WtJson -InputObject $Payload -Depth 12)
    return $Path
}
