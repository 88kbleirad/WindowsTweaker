# WindowsTweaker - System category tweaks.
#
# Reference implementation of the scripted-tweak pattern: Detect is read-only,
# Apply performs every change through the provider functions (so -WhatIf, state
# capture, verification and per-operation logging are automatic).
#
# This replaces the unparseable legacy modules/DiagTrackService.ps1, which contained
# a missing parameter separator, "Stop-Service -StartupType" (invalid) and the typo
# "Start-Sevice".

New-WtScriptTweak -Id 'System.DiagTrackService' -Category 'System' `
    -Name @{
        en = 'Connected User Experiences and Telemetry service (DiagTrack)'
        vi = 'Dịch vụ Trải nghiệm người dùng được kết nối và Telemetry (DiagTrack)'
    } `
    -Description @{
        en = 'Stops the DiagTrack service, sets it to Disabled and blocks its firewall group.'
        vi = 'Dừng dịch vụ DiagTrack, đặt thành Vô hiệu hóa và chặn nhóm tường lửa của nó.'
    } `
    -Impact @{
        en = 'Stopping DiagTrack reduces telemetry uploads. Some Microsoft diagnostic features that rely on the service stop working; Windows Update and Defender are unaffected.'
        vi = 'Dừng DiagTrack giúp giảm việc gửi telemetry. Một số tính năng chẩn đoán của Microsoft phụ thuộc dịch vụ này sẽ ngừng hoạt động; Windows Update và Defender không bị ảnh hưởng.'
    } `
    -StateNames @('Disabled', 'Enabled') -DefaultState 'Disabled' `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Medium' `
    -Requires @('Cmdlet:Get-Service') `
    -Detect {
        param ($Tweak, $Arguments)

        $Service = Get-WtServiceSnapshot -Name 'DiagTrack'
        if (-not $Service.Available)
        {
            return @{ State = 'Unsupported'; Reason = 'Get-Service is not available on this platform.' }
        }

        if (-not $Service.Exists)
        {
            return @{ State = 'Unsupported'; Reason = 'The DiagTrack service is not present on this system.' }
        }

        if ($Service.StartupType -eq 'Disabled' -or $Service.Status -eq 'Stopped')
        {
            return @{ State = 'Disabled'; Reason = "startup=$($Service.StartupType), state=$($Service.Status)" }
        }

        return @{ State = 'Enabled'; Reason = "startup=$($Service.StartupType), state=$($Service.Status)" }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        $Results = @()

        if ($State -eq 'Disabled')
        {
            # Set the start type first, then stop the service: the order avoids a
            # service that is running with a disabled start type.
            $Results += Set-WtServiceState -Name 'DiagTrack' -StartupType 'Disabled'
            $Results += Set-WtServiceState -Name 'DiagTrack' -Status 'Stopped'
            $Results += Set-WtFirewallGroupState -Group 'DiagTrack' -Enabled 'True' -Action 'Block'
        }
        else
        {
            $Results += Set-WtServiceState -Name 'DiagTrack' -StartupType 'Automatic'
            $Results += Set-WtServiceState -Name 'DiagTrack' -Status 'Running'
            $Results += Set-WtFirewallGroupState -Group 'DiagTrack' -Enabled 'True' -Action 'Allow'
        }

        return $Results
    }

New-WtRegistryTweak -Id 'System.SysMainService' -Category 'System' `
    -Name @{
        en = 'SysMain (Superfetch) service start type'
        vi = 'Kiểu khởi động dịch vụ SysMain (Superfetch)'
    } `
    -Description @{
        en = 'Keeps SysMain at the Windows default (Automatic) or sets it to Manual.'
        vi = 'Giữ SysMain ở mặc định của Windows (Tự động) hoặc đặt thành Thủ công.'
    } `
    -Impact @{
        en = 'SysMain prefetches frequently used applications. Setting it to Manual can slow application start-up on hard disks; it is not a recommendation, only an option.'
        vi = 'SysMain tải trước các ứng dụng thường dùng. Đặt thành Thủ công có thể làm chậm khởi động ứng dụng trên ổ đĩa cứng; đây chỉ là tùy chọn, không phải khuyến nghị.'
    } `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'Reboot' -Rollback 'Full' -Risk 'Medium' `
    -CapabilityLoss @(
        @{
            Capability = 'appstartup.prefetch'
            Names      = @{
                en = 'Application start-up prefetching (SysMain) stops'
                vi = 'Tải trước khi khởi động ứng dụng (SysMain) ngừng hoạt động'
            }
            Kind       = 'Guaranteed'
            Temporary  = $false
            RestoredBy = @{
                en = 'Set SysMain back to Automatic with the same tweak (requires a restart).'
                vi = 'Đặt SysMain trở lại chế độ Tự động bằng chính tinh chỉnh này (cần khởi động lại).'
            }
            Limitations = @{
                en = 'Restoring the service start type does not rebuild the prefetch history that was collected while it was off.'
                vi = 'Khôi phục kiểu khởi động dịch vụ không tạo lại lịch sử tải trước đã thu thập trong lúc nó tắt.'
            }
        }
    ) `
    -Detection @{
        Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\SysMain'
        Name = 'Start'
        Map  = [ordered]@{
            Enabled  = @(2)
            Disabled = @(3)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\SysMain'; Name = 'Start'; Type = 'DWord'; Value = 2 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\SysMain'; Name = 'Start'; Type = 'DWord'; Value = 3 }
        )
    }
