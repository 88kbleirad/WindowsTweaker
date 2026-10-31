# WindowsTweaker - Maintenance batch G6: registry backup, thumbnail cache cleanup,
# restartable apps, .NET Framework CLR selection, .NET runtime installation, network
# discovery and adapter power management.
#
# Derived from Sophia Script for Windows (MIT, (c) 2023 farag2) where noted. The
# WPF pickers, the bundled-binary checks, the download-and-run pipelines, the hosts
# file rewrite and the protection-reducing startup logic of the legacy modules are
# deliberately not ported - see docs/migration-notes/Maintenance.G6.md for the
# per-module outcome and the reasons.
#
# Contracts for the whole batch:
#   * an action that installs something or acts on adapters takes its targets from
#     -Arguments and refuses to guess; nothing is downloaded, executed or changed
#     without an explicit selection,
#   * every change goes through the providers, so -WhatIf, state capture,
#     verification and per-operation logging keep working,
#   * a restore point is never created implicitly (see New-WtRestorePoint and
#     Invoke-WtTweak -IncludeRestorePoint); the legacy modules/CreateRestorePoint.ps1
#     behaviour is documented in the notes instead of being turned into a tweak.

New-WtRegistryTweak -Id 'Maintenance.RestartApps' -Category 'Maintenance' `
    -Name @{
        en = 'Restart apps after sign-in'
        vi = 'Khởi động lại ứng dụng sau khi đăng nhập'
    } `
    -Description @{
        en = 'Lets Windows reopen the apps that it can restart automatically after you sign in or restart the computer.'
        vi = 'Cho phép Windows mở lại các ứng dụng có thể tự khởi động lại sau khi bạn đăng nhập hoặc khởi động lại máy.'
    } `
    -Impact @{
        en = 'Enabled is what the "Restart apps" option in Sign-in options does: apps that register as restartable are relaunched (and saved data is restored) at the next sign-in. Disabled stops that. The value is read at sign-in, so the change only shows at the next sign-in.'
        vi = 'Bật tương ứng với tùy chọn "Khởi động lại ứng dụng" trong Tùy chọn đăng nhập: các ứng dụng đăng ký khởi động lại sẽ được mở lại (và dữ liệu đã lưu được phục hồi) ở lần đăng nhập kế tiếp. Tắt sẽ ngăn điều đó. Giá trị được đọc khi đăng nhập nên thay đổi chỉ thấy ở lần đăng nhập sau.'
    } `
    -Scope 'User' -Privilege 'None' -Restart 'SignOut' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Name = 'RestartApps'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon'; Name = 'RestartApps'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon'; Name = 'RestartApps'; Type = 'DWord'; Value = 0 }
        )
    }

New-WtRegistryTweak -Id 'Maintenance.RegistryBackup' -Category 'Maintenance' `
    -Name @{
        en = 'Periodic registry backup'
        vi = 'Sao lưu registry định kỳ'
    } `
    -Description @{
        en = 'Controls the EnablePeriodicBackup value that decides whether Windows periodically writes a backup of the registry hives into %SystemRoot%\System32\config\RegBack.'
        vi = 'Điều khiển giá trị EnablePeriodicBackup quyết định Windows có định kỳ ghi bản sao lưu các hive registry vào %SystemRoot%\System32\config\RegBack hay không.'
    } `
    -Impact @{
        en = 'Enabled lets the Windows maintenance task write periodic registry backups, which uses additional disk space; the backup is a hive copy for manual recovery only and is not a restore point. Disabled writes 0, which is the Windows default since Windows 10 1803 and stops that backup. Only this one value is changed, and rollback restores the captured value.'
        vi = 'Bật cho phép tác vụ bảo trì của Windows ghi bản sao lưu registry định kỳ, tốn thêm dung lượng đĩa; bản sao lưu chỉ là bản chép hive để phục hồi thủ công, không phải điểm khôi phục hệ thống. Tắt sẽ ghi giá trị 0, đây là mặc định của Windows từ Windows 10 1803 và dừng việc sao lưu đó. Chỉ một giá trị này bị thay đổi và hoàn tác sẽ khôi phục giá trị đã lưu.'
    } `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Medium' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Configuration Manager'
        Name = 'EnablePeriodicBackup'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Configuration Manager'; Name = 'EnablePeriodicBackup'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Configuration Manager'; Name = 'EnablePeriodicBackup'; Type = 'DWord'; Value = 0 }
        )
    }

New-WtRegistryTweak -Id 'Maintenance.ThumbnailCacheCleanup' -Category 'Maintenance' `
    -Name @{
        en = 'Thumbnail cache in Disk Cleanup'
        vi = 'Bộ nhớ đệm hình thu nhỏ trong Dọn đĩa'
    } `
    -Description @{
        en = 'Sets the Autorun value of the "Thumbnail Cache" handler in the Disk Cleanup / Storage Sense volume-cache list, for both the 64-bit and the WOW6432Node key.'
        vi = 'Đặt giá trị Autorun của trình xử lý "Thumbnail Cache" trong danh sách bộ nhớ đệm ổ đĩa của Dọn đĩa / Storage Sense, cho cả khóa 64-bit và WOW6432Node.'
    } `
    -Impact @{
        en = 'Enabled marks the thumbnail cache handler for automatic cleanup, so Disk Cleanup or Storage Sense may delete the cached thumbnails; Explorer rebuilds them, which makes the first view of a folder slower. Disabled keeps the handler out of the automatic cleanup. The tweak itself deletes no files, and both registry values are captured so rollback restores them.'
        vi = 'Bật sẽ đánh dấu trình xử lý bộ nhớ đệm hình thu nhỏ cho việc dọn tự động, nên Dọn đĩa hoặc Storage Sense có thể xóa các hình thu nhỏ đã lưu; Explorer sẽ tạo lại chúng và lần đầu mở thư mục sẽ chậm hơn. Tắt giữ trình xử lý này ngoài việc dọn tự động. Bản thân tinh chỉnh không xóa tệp nào và cả hai giá trị registry đều được lưu để hoàn tác.'
    } `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Medium' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -CapabilityLoss @(
        @{
            Capability = 'explorer.thumbnails'
            Names      = @{
                en = 'Cached file thumbnails are deleted by Disk Cleanup or Storage Sense'
                vi = 'Hình thu nhỏ của tệp đã lưu trữ bị Dọn đĩa hoặc Storage Sense xóa'
            }
            Kind       = 'Guaranteed'
            Temporary  = $true
            RestoredBy = @{
                en = 'Explorer rebuilds the thumbnails on the next folder view; the first view after cleanup is slower.'
                vi = 'Explorer tạo lại hình thu nhỏ ở lần mở thư mục kế tiếp; lần xem đầu tiên sau khi dọn sẽ chậm hơn.'
            }
            Limitations = @{
                en = 'Rollback restores the registry values, not the deleted cache files; rebuilding is done by Explorer itself.'
                vi = 'Hoàn tác chỉ khôi phục giá trị registry, không khôi phục các tệp bộ nhớ đệm đã xóa; việc tạo lại do chính Explorer đảm nhiệm.'
            }
        }
    ) `
    -Detection @{
        Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Thumbnail Cache'
        Name = 'Autorun'
        Map  = [ordered]@{
            Enabled  = @(3)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Thumbnail Cache'; Name = 'Autorun'; Type = 'DWord'; Value = 3 }
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Thumbnail Cache'; Name = 'Autorun'; Type = 'DWord'; Value = 3 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Thumbnail Cache'; Name = 'Autorun'; Type = 'DWord'; Value = 0 }
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Thumbnail Cache'; Name = 'Autorun'; Type = 'DWord'; Value = 0 }
        )
    }

New-WtRegistryTweak -Id 'Maintenance.OnlyUseLatestClr' -Category 'Maintenance' `
    -Name @{
        en = 'Only use the latest installed .NET Framework CLR'
        vi = 'Chỉ dùng CLR .NET Framework mới nhất đã cài'
    } `
    -Description @{
        en = 'Sets OnlyUseLatestCLR in the 64-bit and the 32-bit .NET Framework key, which forces every .NET Framework application on this computer to load the newest CLR that is installed.'
        vi = 'Đặt OnlyUseLatestCLR trong khóa .NET Framework 64-bit và 32-bit, buộc mọi ứng dụng .NET Framework trên máy này nạp CLR mới nhất đã cài.'
    } `
    -Impact @{
        en = 'Enabled is a machine-wide, per-application-unavoidable redirection: applications built for an older CLR are loaded on the newest one and can fail or behave differently, and the legacy module removed the value again on disable. Disabled writes 0 in both keys, which is the documented default. Rollback restores the captured values.'
        vi = 'Bật là chuyển hướng toàn máy, không thể loại trừ theo từng ứng dụng: các ứng dụng viết cho CLR cũ sẽ chạy trên CLR mới nhất và có thể lỗi hoặc hoạt động khác đi. Tắt sẽ ghi 0 vào cả hai khóa, đây là giá trị mặc định được tài liệu hóa. Hoàn tác sẽ khôi phục giá trị đã lưu.'
    } `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'High' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKLM:\SOFTWARE\Microsoft\.NETFramework'
        Name = 'OnlyUseLatestCLR'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Microsoft\.NETFramework'; Name = 'OnlyUseLatestCLR'; Type = 'DWord'; Value = 1 }
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework'; Name = 'OnlyUseLatestCLR'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Microsoft\.NETFramework'; Name = 'OnlyUseLatestCLR'; Type = 'DWord'; Value = 0 }
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework'; Name = 'OnlyUseLatestCLR'; Type = 'DWord'; Value = 0 }
        )
    }

New-WtScriptTweak -Id 'Maintenance.InstallDotNetRuntime' -Category 'Maintenance' `
    -Name @{
        en = 'Install a .NET runtime from an explicit official URL'
        vi = 'Cài .NET runtime từ một URL chính thức được chỉ định'
    } `
    -Description @{
        en = 'Downloads the installer named in -Arguments.Uri over https, verifies that it carries a valid Authenticode signature from Microsoft Corporation, and only then runs it with /install /passive /norestart. Nothing is selected, downloaded or executed without that argument.'
        vi = 'Tải bộ cài được chỉ định trong -Arguments.Uri qua https, kiểm tra chữ ký Authenticode hợp lệ của Microsoft Corporation, chỉ sau đó mới chạy với /install /passive /norestart. Không có gì được chọn, tải hay chạy nếu thiếu tham số đó.'
    } `
    -Impact @{
        en = 'Irreversible: installing a runtime writes files and registry entries and cannot be undone here (Rollback None). A wrong or malicious URL cannot lead to execution, because an unsigned or foreign-signed binary is refused before it is run. The installer is left in the destination path (%TEMP% unless -Arguments.DestinationPath is given) for you to delete; the legacy automatic lookup of the newest release and its post-install cleanup are not ported.'
        vi = 'Không thể hoàn tác: cài runtime sẽ ghi tệp và khóa registry và không thể hoàn tác ở đây (Rollback None). URL sai hay độc hại cũng không thể dẫn tới việc chạy mã, vì tệp không có chữ ký hoặc do nhà phát hành khác sẽ bị từ chối trước khi chạy. Bộ cài được giữ lại ở thư mục đích (%TEMP% nếu không truyền -Arguments.DestinationPath) để bạn tự xóa; việc tự tra phiên bản mới nhất và dọn dẹp sau khi cài của bản cũ không được chuyển đổi.'
    } `
    -StateNames @('None', 'Enabled') -DefaultState 'None' `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'None' -Risk 'High' -Irreversible `
    -Requires @('Windows', 'Cmdlet:Get-AuthenticodeSignature') `
    -Parameters @('Uri', 'DestinationPath') `
    -Detect {
        param ($Tweak, $Arguments)

        $Uri = if ($Arguments) { [string]$Arguments.Uri } else { '' }

        if (-not $Uri)
        {
            return @{
                State  = 'None'
                Reason = 'No installer was selected. Pass -Arguments @{ Uri = ''https://.../dotnet-runtime-<version>-win-x64.exe'' } to see the exact download and install plan.'
            }
        }

        if ($Uri -notmatch '^https://')
        {
            return @{ State = 'Unknown'; Reason = "Only an https:// download is accepted; '$Uri' is not one." }
        }

        $FileName = [System.IO.Path]::GetFileName(([uri]$Uri).AbsolutePath)
        if ([string]::IsNullOrWhiteSpace($FileName) -or $FileName -notlike '*.exe')
        {
            return @{ State = 'Unknown'; Reason = "The installer URL must end in a .exe file name; '$Uri' does not." }
        }

        $Destination = if ($Arguments.DestinationPath) { [string]$Arguments.DestinationPath } else { Join-Path ([System.IO.Path]::GetTempPath()) $FileName }

        return @{
            State     = 'Enabled'
            Instances = @([pscustomobject]@{ Id = $Uri; Label = "$FileName from $(([uri]$Uri).Host)"; State = 'NotDetected' })
            Reason    = "Would download '$FileName' from $(([uri]$Uri).Host) to '$Destination', verify that it is signed by Microsoft Corporation, then run it with /install /passive /norestart. The runtime versions already installed are not detected here."
        }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        $Uri = if ($Arguments) { [string]$Arguments.Uri } else { '' }

        if ($State -ne 'Enabled')
        {
            return New-WtOperationResult -Status 'skipped' -Operation 'InstallDotNetRuntime' -Target $Tweak.Id -Rollback None -Message 'State None performs no change; nothing was downloaded or executed. Pass -State Enabled with -Arguments @{ Uri = ... } to install a runtime.'
        }

        if (-not $Uri)
        {
            return New-WtOperationResult -Status 'failed' -Operation 'InstallDotNetRuntime' -Target $Tweak.Id -Rollback None -Message 'State Enabled requires -Arguments @{ Uri = ''<official https URL of the .NET runtime installer>'' }; no installer was selected, so nothing was downloaded or executed.'
        }

        if ($Uri -notmatch '^https://')
        {
            return New-WtOperationResult -Status 'failed' -Operation 'InstallDotNetRuntime' -Target $Uri -Rollback None -Message "Only an https:// download is accepted; '$Uri' was not downloaded or executed."
        }

        $FileName = [System.IO.Path]::GetFileName(([uri]$Uri).AbsolutePath)
        if ([string]::IsNullOrWhiteSpace($FileName))
        {
            return New-WtOperationResult -Status 'failed' -Operation 'InstallDotNetRuntime' -Target $Uri -Rollback None -Message "The installer URL has no file name: '$Uri'."
        }

        $Destination = if ($Arguments.DestinationPath) { [string]$Arguments.DestinationPath } else { Join-Path ([System.IO.Path]::GetTempPath()) $FileName }

        $Download = Get-WtVerifiedDownload -Uri $Uri -ExpectedPublisher 'Microsoft Corporation' -DestinationPath $Destination
        if ($Download.Status -ne 'succeeded')
        {
            # dry run, failure or an unverifiable signature: never execute the file.
            return $Download
        }

        $Results = @($Download)
        $Results += Invoke-WtProcess -FilePath $Destination -ArgumentList @('/install', '/passive', '/norestart') -TimeoutSeconds 1800
        return $Results
    }

New-WtScriptTweak -Id 'Maintenance.NetworkDiscovery' -Category 'Maintenance' `
    -Name @{
        en = 'Network discovery and file sharing (Private profile)'
        vi = 'Khám phá mạng và chia sẻ tệp (hồ sơ Riêng tư)'
    } `
    -Description @{
        en = 'Enables or disables the built-in "Network Discovery" and "File and Printer Sharing" firewall rule groups and assigns those rules to the Private profile, which is what the legacy module did.'
        vi = 'Bật hoặc tắt các nhóm quy tắc tường lửa "Network Discovery" và "File and Printer Sharing" có sẵn và gán các quy tắc đó cho hồ sơ Riêng tư, đúng như mô-đun cũ đã làm.'
    } `
    -Impact @{
        en = 'Enabled makes this computer discoverable and able to share files on private (home/work) networks and assigns those rule groups to the Private profile, so the rules no longer apply to the Domain and Public profiles. The legacy step that also forced the active network into the Private category (Set-NetConnectionProfile) is not ported, so Windows may still treat a network as Public and block discovery. Rollback restores the captured Enabled, Action and Profile of every rule in the groups.'
        vi = 'Bật sẽ khiến máy này có thể được phát hiện và chia sẻ tệp trên mạng riêng (nhà/cơ quan) và gán các nhóm quy tắc đó cho hồ sơ Riêng tư, nên chúng không còn áp dụng cho hồ sơ Miền và Công cộng. Bước cũ buộc mạng đang dùng sang loại Riêng tư (Set-NetConnectionProfile) không được chuyển đổi, nên Windows có thể vẫn coi mạng là Công cộng và chặn việc phát hiện. Hoàn tác sẽ khôi phục Enabled, Action và Profile đã lưu của từng quy tắc trong nhóm.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Disabled' `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Medium' `
    -Requires @('Cmdlet:Get-NetFirewallRule') `
    -Detect {
        param ($Tweak, $Arguments)

        $Groups = @(
            @{ Group = '@FirewallAPI.dll,-32752'; Label = 'Network Discovery' }
            @{ Group = '@FirewallAPI.dll,-28502'; Label = 'File and Printer Sharing' }
        )

        if (-not (Test-WtFirewallAvailable))
        {
            return @{ State = 'Unsupported'; Reason = 'The NetSecurity module is not available on this platform.' }
        }

        $Instances = @()
        $GroupStates = @()

        foreach ($Entry in $Groups)
        {
            $Snapshot = Get-WtFirewallGroupSnapshot -Group $Entry.Group
            if (-not $Snapshot.Available)
            {
                return @{ State = 'Unsupported'; Reason = 'The NetSecurity module is not available on this platform.' }
            }

            $Rules = @($Snapshot.Rules)
            if ($Rules.Count -eq 0)
            {
                return @{ State = 'Unsupported'; Reason = "No firewall rule belongs to the '$($Entry.Label)' group on this system." }
            }

            $EnabledCount = @($Rules | Where-Object { $_.Enabled -eq 'True' }).Count
            $InstanceState = if ($EnabledCount -eq $Rules.Count) { 'Enabled' } elseif ($EnabledCount -eq 0) { 'Disabled' } else { 'Mixed' }

            $GroupStates += $InstanceState
            $Instances += [pscustomobject]@{
                Id    = $Entry.Group
                Label = "$($Entry.Label) ($($Rules.Count) rule(s))"
                State = $InstanceState
            }
        }

        $Distinct = @($GroupStates | Select-Object -Unique)

        return @{
            State     = if ($Distinct.Count -eq 1) { $Distinct[0] } else { 'Mixed' }
            Instances = $Instances
            Reason    = ($Instances | ForEach-Object { "$($_.Label): $($_.State)" }) -join '; '
        }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        $Groups = @('@FirewallAPI.dll,-32752', '@FirewallAPI.dll,-28502')
        $Enabled = if ($State -eq 'Enabled') { 'True' } else { 'False' }

        $Results = @()
        foreach ($Group in $Groups)
        {
            $Results += Set-WtFirewallGroupState -Group $Group -Enabled $Enabled -Profile 'Private'
        }

        return $Results
    }

New-WtScriptTweak -Id 'Maintenance.AdapterPowerSaving' -Category 'Maintenance' `
    -Name @{
        en = 'Network adapter power saving ("Allow the computer to turn off this device")'
        vi = 'Tiết kiệm điện của card mạng ("Cho phép máy tính tắt thiết bị này")'
    } `
    -Description @{
        en = 'Sets the "Allow the computer to turn off this device to save power" power-management property for exactly the adapters named in -Arguments.InterfaceIndex.'
        vi = 'Đặt thuộc tính quản lý nguồn "Cho phép máy tính tắt thiết bị này để tiết kiệm điện" cho đúng các card mạng được nêu trong -Arguments.InterfaceIndex.'
    } `
    -Impact @{
        en = 'Disabled stops Windows from powering the selected adapter down, which fixes adapters that lose the connection when the computer sleeps; it costs some battery life. Enabled is the Windows default and lets Windows turn the adapter off. Applying either state goes through Set-NetAdapterPowerManagement, which restarts the selected adapter, so the network connection is interrupted briefly; the previous per-adapter value is captured and rollback restores it.'
        vi = 'Tắt sẽ ngăn Windows tắt card mạng đã chọn để tiết kiệm điện, giúp khắc phục tình trạng mất kết nối khi máy ngủ; đổi lại sẽ tốn pin hơn. Bật là mặc định của Windows và cho phép Windows tắt card mạng. Cả hai trạng thái đều đi qua Set-NetAdapterPowerManagement, lệnh này khởi động lại card mạng đã chọn nên kết nối mạng bị ngắt trong giây lát; giá trị trước đó của từng card được lưu và hoàn tác sẽ khôi phục.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Scope 'PerAdapter' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Medium' `
    -Requires @('Windows', 'Cmdlet:Get-NetAdapterPowerManagement') `
    -Parameters @('InterfaceIndex') `
    -Detect {
        param ($Tweak, $Arguments)

        if (-not (Test-WtAdapterPowerAvailable))
        {
            return @{ State = 'Unsupported'; Reason = 'The NetAdapter module is not available on this platform.' }
        }

        $Adapters = @(Get-WtNetworkAdapterInternal | Where-Object { $_.IsPhysical -and -not $_.IsVirtualOrTunnel -and $_.Status -eq 'Up' })
        if ($Adapters.Count -eq 0)
        {
            return @{ State = 'Unsupported'; Reason = 'No connected physical network adapter was reported.' }
        }

        $Selected = if ($Arguments -and $Arguments.InterfaceIndex)
        {
            @($Adapters | Where-Object { $Arguments.InterfaceIndex -contains $_.InterfaceIndex })
        }
        else
        {
            $Adapters
        }

        if ($Selected.Count -eq 0)
        {
            return @{ State = 'Unsupported'; Reason = 'None of the requested interface indexes is a connected physical adapter.' }
        }

        $Instances = @()
        foreach ($Adapter in $Selected)
        {
            $Snapshot = Get-WtAdapterPowerSnapshot -InterfaceIndex $Adapter.InterfaceIndex
            $InstanceState = if ($Snapshot.AllowComputerToTurnOffDevice -eq 'Enabled') { 'Enabled' }
                elseif ($Snapshot.AllowComputerToTurnOffDevice -eq 'Disabled') { 'Disabled' }
                else { 'Unsupported' }

            $Instances += [pscustomobject]@{
                Id    = $Adapter.InterfaceIndex
                Label = $Adapter.Name
                State = $InstanceState
            }
        }

        $Distinct = @($Instances | Select-Object -ExpandProperty State -Unique)

        return @{
            State     = if ($Distinct.Count -eq 1 -and $Distinct[0] -in @('Enabled', 'Disabled')) { $Distinct[0] } else { 'Mixed' }
            Instances = $Instances
            Reason    = ($Instances | ForEach-Object { "$($_.Label): $($_.State)" }) -join '; '
        }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        if (-not $Arguments -or -not $Arguments.InterfaceIndex)
        {
            return New-WtOperationResult -Status 'failed' -Operation 'SetAdapterPower' -Target $Tweak.Id -Message 'This tweak requires -Arguments @{ InterfaceIndex = @(...) } so that only explicitly selected adapters are changed.'
        }

        $Value = if ($State -eq 'Disabled') { 'Disabled' } else { 'Enabled' }

        $Results = @()
        foreach ($Index in $Arguments.InterfaceIndex)
        {
            $Results += Set-WtAdapterPowerState -InterfaceIndex ([int]$Index) -AllowComputerToTurnOffDevice $Value
        }

        return $Results
    }
