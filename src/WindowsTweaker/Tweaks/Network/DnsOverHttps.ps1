# WindowsTweaker - Network category tweaks.
#
# DNS changes only ever target adapters the caller selected explicitly. VPN and
# virtual adapters are reported and skipped unless -Arguments.AllowVirtualAdapter is
# set, and the previous per-adapter configuration is captured before the change, so
# rollback restores the exact previous server list (or "obtain automatically").

New-WtScriptTweak -Id 'Network.DnsOverHttps' -Category 'Network' `
    -Name @{
        en = 'DNS over HTTPS (DoH) servers'
        vi = 'Máy chủ DNS qua HTTPS (DoH)'
    } `
    -Description @{
        en = 'Configures explicit DNS servers, and their DoH template, on the adapters you select.'
        vi = 'Cấu hình máy chủ DNS cụ thể, cùng mẫu DoH, trên các adapter bạn chọn.'
    } `
    -Impact @{
        en = 'Only the selected adapters are changed. Applying it requires -Arguments with InterfaceIndex and ServerAddresses; disabling restores each selected adapter to "obtain DNS server address automatically" unless a previous value was captured.'
        vi = 'Chỉ các adapter được chọn bị thay đổi. Cần truyền -Arguments gồm InterfaceIndex và ServerAddresses; khi tắt, mỗi adapter được chọn sẽ trở về "tự động lấy địa chỉ máy chủ DNS" trừ khi đã lưu trước giá trị cũ.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Medium' `
    -Requires @('Cmdlet:Get-DnsClientServerAddress') `
    -Parameters @('InterfaceIndex', 'ServerAddresses', 'DohTemplate', 'DohFlags', 'AllowVirtualAdapter') `
    -Detect {
        param ($Tweak, $Arguments)

        if (-not (Test-WtDnsAvailable))
        {
            return @{ State = 'Unsupported'; Reason = 'The DnsClient module is not available on this platform.' }
        }

        $Adapters = @(Get-WtNetworkAdapterInternal)
        if ($Adapters.Count -eq 0)
        {
            return @{ State = 'Unsupported'; Reason = 'No network adapters were reported.' }
        }

        $Selected = if ($Arguments -and $Arguments.InterfaceIndex)
        {
            @($Adapters | Where-Object { $Arguments.InterfaceIndex -contains $_.InterfaceIndex })
        }
        else
        {
            @($Adapters | Where-Object { -not $_.IsVirtualOrTunnel })
        }

        $Instances = @()
        foreach ($Adapter in $Selected)
        {
            $Dns = Get-WtDnsState -InterfaceIndex $Adapter.InterfaceIndex
            $Addresses = @($Dns.ServerAddresses)

            $InstanceState = if ($Dns.Automatic) { 'Disabled' } elseif ($Addresses.Count -gt 0) { 'Enabled' } else { 'Unknown' }

            $Instances += [pscustomobject]@{
                Id    = $Adapter.InterfaceIndex
                Label = $Adapter.Name
                State = $InstanceState
                Addresses = $Addresses
            }
        }

        $Distinct = @($Instances | Select-Object -ExpandProperty State -Unique)

        return @{
            State     = if ($Distinct.Count -eq 1) { $Distinct[0] } else { 'Mixed' }
            Instances = $Instances
            Reason    = ($Instances | ForEach-Object { "$($_.Label): $($_.State)" }) -join '; '
        }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        if (-not $Arguments -or -not $Arguments.InterfaceIndex)
        {
            return New-WtOperationResult -Status 'failed' -Operation 'SetDnsServer' -Target $Tweak.Id -Message 'This tweak requires -Arguments @{ InterfaceIndex = @(...) } so that only explicitly selected adapters are changed.'
        }

        if ($State -eq 'Enabled')
        {
            if (-not $Arguments.ServerAddresses)
            {
                return New-WtOperationResult -Status 'failed' -Operation 'SetDnsServer' -Target $Tweak.Id -Message 'State Enabled requires -Arguments.ServerAddresses.'
            }

            $Results = @(Set-WtDnsServer -InterfaceIndex $Arguments.InterfaceIndex -ServerAddresses $Arguments.ServerAddresses -AllowVirtualAdapter:([bool]$Arguments.AllowVirtualAdapter))

            # DoH templates are stored per interface GUID and address; configure them
            # only for adapters that actually got the new servers.
            if ($Arguments.DohTemplate -or $Arguments.DohFlags)
            {
                $Adapters = @(Get-WtNetworkAdapterInternal)
                foreach ($Index in $Arguments.InterfaceIndex)
                {
                    $Adapter = $Adapters | Where-Object { $_.InterfaceIndex -eq $Index } | Select-Object -First 1
                    if (-not $Adapter -or -not $Adapter.InterfaceGuid)
                    {
                        continue
                    }

                    foreach ($Address in $Arguments.ServerAddresses)
                    {
                        $DohParameters = @{
                            InterfaceGuid = $Adapter.InterfaceGuid
                            ServerAddress = $Address
                        }
                        if ($Arguments.DohTemplate) { $DohParameters.DohTemplate = $Arguments.DohTemplate }
                        if ($Arguments.DohFlags) { $DohParameters.DohFlags = [int]$Arguments.DohFlags }

                        $Results += Set-WtDohSetting @DohParameters
                    }
                }
            }

            return $Results
        }

        # Disabled: reset the selected adapters to automatic DNS. The previous
        # per-adapter list is captured, so this is reversible too.
        return @(Reset-WtDnsServer -InterfaceIndex $Arguments.InterfaceIndex -AllowVirtualAdapter:([bool]$Arguments.AllowVirtualAdapter))
    }
