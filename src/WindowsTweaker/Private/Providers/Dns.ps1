# WindowsTweaker - DNS provider.
#
# Design rules enforced here:
#   * every DNS change targets interfaces the caller selected explicitly
#   * VPN / virtual / tunnelling adapters are refused unless the caller opts in
#   * per-adapter server addresses (including "obtain automatically") are captured
#     before the change, so rollback restores the exact previous configuration
#   * registry DoH entries are written per interface GUID with the subkey that
#     belongs to the address being configured (the legacy code created the wrong one)

function Test-WtDnsAvailable
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    if (-not (Get-WtRuntimeProfile).IsWindows)
    {
        return $false
    }

    return [bool](Get-Command -Name Get-DnsClientServerAddress -ErrorAction Ignore)
}

function Get-WtDnsServerAddressRaw
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][int]$InterfaceIndex)

    $Result = Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction Ignore
    if (-not $Result)
    {
        return @()
    }

    return @($Result.ServerAddresses)
}

function Set-WtDnsServerAddressRaw
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][int]$InterfaceIndex,
        [Parameter(Mandatory = $true)][string[]]$ServerAddresses
    )

    Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ServerAddresses $ServerAddresses -ErrorAction Stop
}

function Reset-WtDnsServerAddressRaw
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][int]$InterfaceIndex)

    Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ResetServerAddresses -ErrorAction Stop
}

function Clear-WtDnsResolverCacheRaw
{
    [CmdletBinding()]
    param ()

    if (Get-Command -Name Clear-DnsClientCache -ErrorAction Ignore)
    {
        Clear-DnsClientCache -ErrorAction Ignore
    }
}

<#
.SYNOPSIS
    Lists network adapters with their current DNS configuration (read-only).
.DESCRIPTION
    Used by the DNS workflow so the previous configuration of every adapter is visible
    before a change is selected. The DNS query is only attempted when the DnsClient module
    is available; otherwise DnsServers is empty and DnsAvailable is false.
#>
function Get-WtNetworkAdapterWithDns
{
    [CmdletBinding()]
    param ()

    $Adapters = @(Get-WtNetworkAdapterInternal)
    $DnsAvailable = Test-WtDnsAvailable

    foreach ($Adapter in $Adapters)
    {
        $Addresses = @()
        if ($DnsAvailable)
        {
            $State = Get-WtDnsState -InterfaceIndex $Adapter.InterfaceIndex
            if ($State.Available)
            {
                $Addresses = @($State.ServerAddresses)
            }
        }

        $Adapter | Add-Member -NotePropertyName DnsAvailable -NotePropertyValue ([bool]$DnsAvailable) -Force
        $Adapter | Add-Member -NotePropertyName DnsServers -NotePropertyValue $Addresses -Force
        $Adapter | Add-Member -NotePropertyName DnsAutomatic -NotePropertyValue ([bool]($DnsAvailable -and $Addresses.Count -eq 0)) -Force

        $Adapter
    }
}

<#
.SYNOPSIS
    Read-only DNS configuration of one adapter.
#>
function Get-WtDnsState
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][int]$InterfaceIndex)

    if (-not (Test-WtDnsAvailable))
    {
        return [pscustomobject]@{
            PSTypeName     = 'WindowsTweaker.DnsState'
            InterfaceIndex = $InterfaceIndex
            Available      = $false
            Automatic      = $null
            ServerAddresses = @()
        }
    }

    $Addresses = @(Get-WtDnsServerAddressRaw -InterfaceIndex $InterfaceIndex)

    return [pscustomobject]@{
        PSTypeName      = 'WindowsTweaker.DnsState'
        InterfaceIndex  = $InterfaceIndex
        Available       = $true
        Automatic       = ($Addresses.Count -eq 0)
        ServerAddresses = $Addresses
    }
}

<#
.SYNOPSIS
    Restores the DNS servers of explicitly selected adapters to "obtain automatically".
.DESCRIPTION
    The previous per-adapter server list is captured first, so this operation itself
    is reversible with Undo-WtTweak.
#>
function Reset-WtDnsServer
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param
    (
        [Parameter(Mandatory = $true)][int[]]$InterfaceIndex,
        [Parameter(Mandatory = $false)][switch]$AllowVirtualAdapter,
        [Parameter(Mandatory = $false)][switch]$SkipCacheFlush
    )

    $Operation = 'ResetDnsServer'

    if (-not (Test-WtDnsAvailable))
    {
        return New-WtOperationResult -Status 'unsupported' -Operation $Operation -Target ($InterfaceIndex -join ',') -Message 'DnsClient module is not available on this platform.'
    }

    $Adapters = @(Get-WtNetworkAdapterInternal)
    $Results = @()

    foreach ($Index in $InterfaceIndex)
    {
        $Adapter = $Adapters | Where-Object { $_.InterfaceIndex -eq $Index } | Select-Object -First 1

        if (-not $AllowVirtualAdapter -and $Adapter -and $Adapter.IsVirtualOrTunnel)
        {
            $Results += New-WtOperationResult -Status 'skipped' -Operation $Operation -Target $Adapter.Name -Message "Refusing to change DNS on the virtual/VPN adapter '$($Adapter.Name)' (use -AllowVirtualAdapter to override)."
            continue
        }

        $Previous = Get-WtDnsState -InterfaceIndex $Index
        if ($Previous.Automatic)
        {
            $Results += New-WtOperationResult -Status 'unchanged' -Operation $Operation -Target "index $Index" -Message "Interface $Index already obtains DNS automatically."
            continue
        }


        # One confirmation per tweak: Invoke-WtTweak/Undo-WtTweak confirm once, and the
        # providers must not prompt again while that apply/rollback is in progress.
        if ((Get-WtOperationContext).SuppressConfirm) { $ConfirmPreference = 'None' }

        if (-not $PSCmdlet.ShouldProcess("interface $Index", 'restore automatic DNS servers'))
        {
            $Results += New-WtOperationResult -Status (Get-WtShouldProcessStatus) -Operation $Operation -Target "index $Index" -Message "Would reset DNS on interface $Index to automatic."
            continue
        }

        $Context = Get-WtOperationContext
        if ($null -ne $Context.HistoryEntry)
        {
            Add-WtStateRecord -HistoryEntry $Context.HistoryEntry -Record @{
                resource        = 'DnsServer'
                interfaceIndex  = $Index
                interfaceGuid   = if ($Adapter) { $Adapter.InterfaceGuid } else { $null }
                adapterName     = if ($Adapter) { $Adapter.Name } else { $null }
                automatic       = $false
                serverAddresses = @($Previous.ServerAddresses)
            }
        }

        try
        {
            Reset-WtDnsServerAddressRaw -InterfaceIndex $Index
        }
        catch
        {
            $Results += New-WtOperationResult -Status 'failed' -Operation $Operation -Target "index $Index" -Message $_.Exception.Message -ErrorRecord $_
            continue
        }

        $Verify = Get-WtDnsState -InterfaceIndex $Index
        if (-not $Verify.Automatic)
        {
            $Results += New-WtOperationResult -Status 'failed' -Operation $Operation -Target "index $Index" -Message "Verification failed: interface $Index still has explicit DNS servers."
            continue
        }

        $Results += New-WtOperationResult -Status 'succeeded' -Operation $Operation -Target "index $Index" -Message "Interface $Index now obtains DNS servers automatically."
    }

    if (-not $SkipCacheFlush -and -not $WhatIfPreference -and @($Results | Where-Object { $_.Status -eq 'succeeded' }).Count -gt 0)
    {
        Clear-WtDnsResolverCacheRaw
    }

    return $Results
}

<#
.SYNOPSIS
    Sets the DNS servers of explicitly selected adapters.
.PARAMETER InterfaceIndex
    One or more interface indexes (as returned by Get-WtNetworkAdapter).
.PARAMETER ServerAddresses
    IPv4/IPv6 addresses to configure, in order.
.PARAMETER AllowVirtualAdapter
    Opt in to configuring VPN/virtual adapters. Default: refused.
#>
function Set-WtDnsServer
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param
    (
        [Parameter(Mandatory = $true)][int[]]$InterfaceIndex,
        [Parameter(Mandatory = $true)][string[]]$ServerAddresses,
        [Parameter(Mandatory = $false)][switch]$AllowVirtualAdapter,
        [Parameter(Mandatory = $false)][switch]$SkipCacheFlush
    )

    $Operation = 'SetDnsServer'

    if (-not (Test-WtDnsAvailable))
    {
        return New-WtOperationResult -Status 'unsupported' -Operation $Operation -Target ($InterfaceIndex -join ',') -Message 'DnsClient module is not available on this platform.'
    }

    if (@($ServerAddresses).Count -eq 0)
    {
        return New-WtOperationResult -Status 'failed' -Operation $Operation -Target ($InterfaceIndex -join ',') -Message 'No DNS server addresses were supplied.'
    }

    foreach ($Address in $ServerAddresses)
    {
        $Parsed = $null
        if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$Parsed))
        {
            return New-WtOperationResult -Status 'failed' -Operation $Operation -Target $Address -Message "Not a valid IP address: $Address"
        }
    }

    $Adapters = @(Get-WtNetworkAdapterInternal)
    $Results = @()

    foreach ($Index in $InterfaceIndex)
    {
        $Adapter = $Adapters | Where-Object { $_.InterfaceIndex -eq $Index } | Select-Object -First 1

        if (-not $AllowVirtualAdapter -and $Adapter -and $Adapter.IsVirtualOrTunnel)
        {
            $Results += New-WtOperationResult -Status 'skipped' -Operation $Operation -Target $Adapter.Name -Message "Refusing to change DNS on the virtual/VPN adapter '$($Adapter.Name)' (use -AllowVirtualAdapter to override)."
            continue
        }

        $Previous = Get-WtDnsState -InterfaceIndex $Index
        if (-not $Previous.Available)
        {
            $Results += New-WtOperationResult -Status 'unsupported' -Operation $Operation -Target "index $Index" -Message 'DNS provider unavailable.'
            continue
        }

        if (-not $Previous.Automatic -and (Test-WtValueEqual -Left $Previous.ServerAddresses -Right $ServerAddresses))
        {
            $Results += New-WtOperationResult -Status 'unchanged' -Operation $Operation -Target "index $Index" -Message "DNS servers already set on interface $Index."
            continue
        }


        # One confirmation per tweak: Invoke-WtTweak/Undo-WtTweak confirm once, and the
        # providers must not prompt again while that apply/rollback is in progress.
        if ((Get-WtOperationContext).SuppressConfirm) { $ConfirmPreference = 'None' }

        if (-not $PSCmdlet.ShouldProcess(("interface $Index" + $(if ($Adapter) { " ($($Adapter.Name))" } else { '' })), "set DNS servers to $($ServerAddresses -join ', ')"))
        {
            $Results += New-WtOperationResult -Status (Get-WtShouldProcessStatus) -Operation $Operation -Target "index $Index" -Message "Would set DNS servers on interface $Index to $($ServerAddresses -join ', ')"
            continue
        }

        $Context = Get-WtOperationContext
        if ($null -ne $Context.HistoryEntry)
        {
            Add-WtStateRecord -HistoryEntry $Context.HistoryEntry -Record @{
                resource         = 'DnsServer'
                interfaceIndex   = $Index
                interfaceGuid    = if ($Adapter) { $Adapter.InterfaceGuid } else { $null }
                adapterName      = if ($Adapter) { $Adapter.Name } else { $null }
                automatic        = $Previous.Automatic
                serverAddresses  = @($Previous.ServerAddresses)
            }
        }

        try
        {
            Set-WtDnsServerAddressRaw -InterfaceIndex $Index -ServerAddresses $ServerAddresses
        }
        catch
        {
            Write-WtLog -Level Error -Message "Failed to set DNS on interface $Index" -Operation $Operation -Status 'failed' -Exception $_.Exception
            $Results += New-WtOperationResult -Status 'failed' -Operation $Operation -Target "index $Index" -Message $_.Exception.Message -ErrorRecord $_
            continue
        }

        $Verify = Get-WtDnsState -InterfaceIndex $Index
        if (-not (Test-WtValueEqual -Left $Verify.ServerAddresses -Right $ServerAddresses))
        {
            $Message = "Verification failed on interface $Index (found: $($Verify.ServerAddresses -join ', '))"
            Write-WtLog -Level Error -Message $Message -Operation $Operation -Status 'failed'
            $Results += New-WtOperationResult -Status 'failed' -Operation $Operation -Target "index $Index" -Message $Message
            continue
        }

        $Results += New-WtOperationResult -Status 'succeeded' -Operation $Operation -Target "index $Index" -Message "DNS servers set on interface $Index to $($ServerAddresses -join ', ')"
    }

    if (-not $SkipCacheFlush -and -not $WhatIfPreference -and @($Results | Where-Object { $_.Status -eq 'succeeded' }).Count -gt 0)
    {
        Clear-WtDnsResolverCacheRaw
    }

    return $Results
}

<#
.SYNOPSIS
    Builds the Dnscache registry path used for per-interface DoH settings.
#>
function Get-WtDohRegistryPath
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][string]$InterfaceGuid,
        [Parameter(Mandatory = $true)][string]$ServerAddress
    )

    return "HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters\$InterfaceGuid\DohInterfaceSettings\Doh\$ServerAddress"
}

<#
.SYNOPSIS
    Configures DNS-over-HTTPS for one adapter/address pair.
.DESCRIPTION
    DohFlags semantics follow the Dnscache interface settings layout:
      2 - use the DoH template stored in DohTemplate
      5 - use the resolver's default template (no DohTemplate value needed)
    The subkey is created for the address being configured, and every value is
    written through the registry provider so it is captured and reversible.
.PARAMETER DohTemplate
    DoH template URL, e.g. https://dns.example/dns-query. Required for DohFlags 2.
#>
function Set-WtDohSetting
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$InterfaceGuid,
        [Parameter(Mandatory = $true)][string]$ServerAddress,
        [Parameter(Mandatory = $false)][ValidateSet(2, 5)][int]$DohFlags = 2,
        [Parameter(Mandatory = $false)][string]$DohTemplate
    )

    $Operation = 'SetDohSetting'
    $Target = "$InterfaceGuid/$ServerAddress"

    if (-not (Test-WtRegistryAvailable))
    {
        return New-WtOperationResult -Status 'unsupported' -Operation $Operation -Target $Target -Message 'Registry provider is not available on this platform.'
    }

    if ($DohFlags -eq 2 -and [string]::IsNullOrWhiteSpace($DohTemplate))
    {
        return New-WtOperationResult -Status 'failed' -Operation $Operation -Target $Target -Message 'DohFlags 2 requires an explicit -DohTemplate URL.'
    }

    if ($DohTemplate -and ($DohTemplate -notmatch '^https://'))
    {
        return New-WtOperationResult -Status 'failed' -Operation $Operation -Target $Target -Message "DoH template must be an https:// URL: $DohTemplate"
    }

    $Path = Get-WtDohRegistryPath -InterfaceGuid $InterfaceGuid -ServerAddress $ServerAddress

    $Results = @()
    $Results += Set-WtRegistryValue -Path $Path -Name 'DohFlags' -Kind QWord -Value ([int64]$DohFlags)

    if ($DohFlags -eq 2)
    {
        $Results += Set-WtRegistryValue -Path $Path -Name 'DohTemplate' -Kind String -Value $DohTemplate
    }

    return $Results
}
