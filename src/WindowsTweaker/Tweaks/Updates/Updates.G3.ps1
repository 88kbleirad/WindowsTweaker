# WindowsTweaker - Updates category tweaks (batch G3).
#
# Replaces the legacy modules modules/UpdateMicrosoftProducts.ps1,
# modules/WindowsLatestUpdate.ps1, modules/RestartDeviceAfterUpdate.ps1,
# modules/RestartNotification.ps1 and modules/DeliveryOptimization.ps1 (the
# byte-identical duplicate modules/DelieryOptimization.ps1 defines the same
# function).
#
# Only the behaviour the legacy modules actually wrote is ported: a user preference,
# a restart-notification preference and the Delivery Optimization download mode.
# Nothing here disables Windows Update itself.
#
# As in the legacy modules, every state first deletes the machine policy value that
# would otherwise override the preference (the legacy code expressed this as an LGPO
# "DELETE" line; LGPO is not bundled and must not be downloaded).

New-WtScriptTweak -Id 'Updates.MicrosoftProductUpdates' -Category 'Updates' `
    -Name @{
        en = 'Updates for other Microsoft products'
        vi = 'Cập nhật cho các sản phẩm Microsoft khác'
    } `
    -Description @{
        en = 'Controls the "Receive updates for other Microsoft products" preference in Windows Update, which extends updates to other Microsoft products such as Office.'
        vi = 'Điều khiển tùy chọn "Nhận cập nhật cho các sản phẩm Microsoft khác" trong Windows Update, giúp cập nhật cả các sản phẩm Microsoft khác như Office.'
    } `
    -Impact @{
        en = 'Enabled sets AllowMUUpdateService = 1, so Windows Update also delivers updates for other Microsoft products. Disabled removes the preference, so Windows returns to its default for this value. Security updates for Windows itself are delivered either way.'
        vi = 'Bật sẽ đặt AllowMUUpdateService = 1, Windows Update cũng phân phối cập nhật cho các sản phẩm Microsoft khác. Tắt sẽ xóa tùy chọn, Windows trở về giá trị mặc định. Bản cập nhật bảo mật cho chính Windows vẫn được phân phối trong cả hai trường hợp.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'AllowMUUpdateService' }
    ) `
    -Detect {
        param ($Tweak, $Arguments)

        $State = Get-WtRegistryState -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'AllowMUUpdateService'
        if (-not $State.Available)
        {
            return @{ State = 'Unsupported'; Reason = 'Registry provider is not available on this platform.' }
        }

        if (-not $State.ValueExists)
        {
            return @{ State = 'Disabled'; Reason = 'AllowMUUpdateService is not present (Windows default).' }
        }

        if (Test-WtValueEqual -Left $State.Value -Right 1)
        {
            return @{ State = 'Enabled'; Reason = 'AllowMUUpdateService = 1.' }
        }

        return @{ State = 'Disabled'; Reason = "AllowMUUpdateService = $($State.Value)." }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        $Results = @()

        # An organization policy for this preference would override the user-facing
        # value, so both states delete it first (the legacy LGPO DELETE line).
        $Results += Remove-WtRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name 'AllowMUUpdateService'

        if ($State -eq 'Enabled')
        {
            $Results += Set-WtRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'AllowMUUpdateService' -Value 1 -Kind 'DWord'
        }
        else
        {
            # The legacy Disabled branch removed the value instead of writing 0.
            $Results += Remove-WtRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'AllowMUUpdateService'
        }

        return $Results
    }

New-WtRegistryTweak -Id 'Updates.LatestUpdatesAsSoonAsAvailable' -Category 'Updates' `
    -Name @{
        en = 'Get the latest updates as soon as they are available'
        vi = 'Nhận cập nhật mới nhất ngay khi có'
    } `
    -Description @{
        en = 'Controls the Windows Update opt-in that makes the device one of the first to receive new non-security updates.'
        vi = 'Điều khiển tùy chọn của Windows Update giúp thiết bị nằm trong nhóm đầu tiên nhận các bản cập nhật không phải bảo mật.'
    } `
    -Impact @{
        en = 'Enabled opts the device into being among the first to receive new non-security updates. Disabled keeps the device on the normal rollout, so the same updates still arrive, only later. The device keeps receiving security updates in both states.'
        vi = 'Bật sẽ đưa thiết bị vào nhóm nhận sớm các bản cập nhật không phải bảo mật. Tắt sẽ giữ thiết bị ở lịch phát hành thông thường, các bản cập nhật vẫn đến nhưng muộn hơn. Thiết bị vẫn nhận cập nhật bảo mật trong cả hai trạng thái.'
    } `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -DefaultState 'Disabled' `
    -Detection @{
        Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
        Name = 'IsContinuousInnovationOptedIn'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'AllowOptionalContent' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'SetAllowOptionalContent' }
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name = 'IsContinuousInnovationOptedIn'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'AllowOptionalContent' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'SetAllowOptionalContent' }
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name = 'IsContinuousInnovationOptedIn'; Type = 'DWord'; Value = 0 }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'AllowOptionalContent' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'SetAllowOptionalContent' }
    )

New-WtRegistryTweak -Id 'Updates.ExpeditedRestart' -Category 'Updates' `
    -Name @{
        en = 'Restart as soon as possible after an update'
        vi = 'Khởi động lại ngay khi có thể sau khi cập nhật'
    } `
    -Description @{
        en = 'Controls whether the device restarts as soon as possible once an update requires a restart to finish installing.'
        vi = 'Điều khiển việc thiết bị có khởi động lại ngay khi có thể khi một bản cập nhật cần khởi động lại để hoàn tất cài đặt hay không.'
    } `
    -Impact @{
        en = 'Enabled restarts the device as soon as the update needs it, which can interrupt your session. Disabled leaves the decision to you and Windows asks instead. Both states delete the organization active-hours policy values, which would otherwise override this preference. Updates install either way.'
        vi = 'Bật sẽ khởi động lại thiết bị ngay khi bản cập nhật yêu cầu, có thể làm gián đoạn phiên làm việc. Tắt sẽ để bạn tự quyết định, Windows sẽ hỏi trước. Cả hai trạng thái đều xóa các giá trị chính sách giờ hoạt động của tổ chức vì chúng sẽ ghi đè tùy chọn này. Cập nhật vẫn được cài trong cả hai trường hợp.'
    } `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Medium' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -DefaultState 'Disabled' `
    -Detection @{
        Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
        Name = 'IsExpedited'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'SetActiveHours' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'ActiveHoursStart' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'ActiveHoursEnd' }
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name = 'IsExpedited'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'SetActiveHours' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'ActiveHoursStart' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'ActiveHoursEnd' }
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name = 'IsExpedited'; Type = 'DWord'; Value = 0 }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'SetActiveHours' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'ActiveHoursStart' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'ActiveHoursEnd' }
    )

New-WtRegistryTweak -Id 'Updates.RestartNotifications' -Category 'Updates' `
    -Name @{
        en = 'Restart notifications'
        vi = 'Thông báo khởi động lại'
    } `
    -Description @{
        en = 'Controls whether Windows shows a notification when the device needs a restart to finish installing updates.'
        vi = 'Điều khiển việc Windows hiển thị thông báo khi thiết bị cần khởi động lại để hoàn tất cài đặt cập nhật.'
    } `
    -Impact @{
        en = 'Enabled shows the restart notification; Disabled hides it, so a pending restart is easy to miss even though updates are still installed. Both states delete the organization policy value that would otherwise override this preference.'
        vi = 'Bật sẽ hiển thị thông báo khởi động lại; tắt sẽ ẩn thông báo nên bạn dễ bỏ lỡ việc cần khởi động lại dù cập nhật vẫn được cài. Cả hai trạng thái đều xóa giá trị chính sách của tổ chức vốn sẽ ghi đè tùy chọn này.'
    } `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -DefaultState 'Enabled' `
    -Detection @{
        Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
        Name = 'RestartNotificationsAllowed2'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'SetAutoRestartNotificationDisable' }
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name = 'RestartNotificationsAllowed2'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'SetAutoRestartNotificationDisable' }
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name = 'RestartNotificationsAllowed2'; Type = 'DWord'; Value = 0 }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'SetAutoRestartNotificationDisable' }
    )

New-WtRegistryTweak -Id 'Updates.DeliveryOptimization' -Category 'Updates' `
    -Name @{
        en = 'Delivery Optimization download mode'
        vi = 'Chế độ tải xuống của Delivery Optimization'
    } `
    -Description @{
        en = 'Controls how Delivery Optimization obtains Windows updates: only from Microsoft (HTTP), or also from other PCs on the local network.'
        vi = 'Điều khiển cách Delivery Optimization tải cập nhật Windows: chỉ từ Microsoft (HTTP) hay cả từ các máy khác trong mạng nội bộ.'
    } `
    -Impact @{
        en = 'Disabled sets DownloadMode = 0 (HTTP only), so the PC neither shares nor downloads updates from other PCs. Enabled sets DownloadMode = 1 (LAN peering), which can speed downloads up but uploads update data to other PCs on your network. Both states delete the Delivery Optimization policy value that would override this setting.'
        vi = 'Tắt sẽ đặt DownloadMode = 0 (chỉ HTTP), máy không chia sẻ cũng không tải cập nhật từ máy khác. Bật sẽ đặt DownloadMode = 1 (chia sẻ trong mạng nội bộ), có thể tải nhanh hơn nhưng sẽ tải dữ liệu cập nhật lên các máy khác trong mạng. Cả hai trạng thái đều xóa giá trị chính sách Delivery Optimization vốn sẽ ghi đè thiết lập này.'
    } `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -DefaultState 'Disabled' `
    -Detection @{
        Path = 'HKU:\S-1-5-20\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings'
        Name = 'DownloadMode'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; Name = 'DODownloadMode' }
            @{ Kind = 'RegistrySet'; Path = 'HKU:\S-1-5-20\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings'; Name = 'DownloadMode'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; Name = 'DODownloadMode' }
            @{ Kind = 'RegistrySet'; Path = 'HKU:\S-1-5-20\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings'; Name = 'DownloadMode'; Type = 'DWord'; Value = 0 }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; Name = 'DODownloadMode' }
    )
