# WindowsTweaker - Personalization category tweaks (batch G9).
#
# Replaces the legacy modules modules/WindowsColorMode.ps1, modules/AppColorMode.ps1,
# modules/AeroShaking.ps1, modules/StickyShift.ps1, modules/InputMethod.ps1,
# modules/FirstLogonAnimation.ps1, modules/JPEGWallpapersQuality.ps1,
# modules/PrtScnSnippingTool.ps1 and modules/ControlPanelView.ps1.
# The per-module outcome table is docs/migration-notes/Personalization.G9.md.
#
# Two conversion notes:
#   * AeroShaking.ps1 was broken: both of its parameter sets wrote DisallowShaking = 0,
#     so -Enable and -Disable did the same thing and the feature could never be turned
#     off. This batch restores the documented mapping (0 = the shake gesture is
#     allowed, 1 = it is ignored) instead of copying the bug.
#   * The legacy LGPO "DELETE" lines are expressed as the equivalent RegistryRemove
#     operations, because LGPO is not bundled and must not be downloaded.
#
# Settings whose "default" state means "no registry value at all" (InputMethod,
# JPEGWallpapersQuality) and the multi-value Control Panel view are scripted tweaks:
# they need a read-only detector that can report the absent/unset state, which the
# declarative -Detection map cannot express. They still perform every change through
# the registry provider functions.

New-WtRegistryTweak -Id 'Personalization.WindowsColorMode' -Category 'Personalization' `
    -Name @{
        en = 'Windows mode (light or dark system theme)'
        vi = 'Chế độ Windows (giao diện hệ thống sáng hoặc tối)'
    } `
    -Description @{
        en = 'Sets SystemUsesLightTheme, the light or dark theme the Windows shell applies to the taskbar, Start, the notification centre and system dialogs.'
        vi = 'Đặt SystemUsesLightTheme, giao diện sáng hoặc tối mà Windows áp dụng cho taskbar, Start, trung tâm thông báo và các hộp thoại hệ thống.'
    } `
    -Impact @{
        en = 'Changes only the Windows shell theme; the theme used by apps is the separate "App mode" setting. In the registry Dark = 0 and Light = 1. An Explorer restart or a sign-out may be needed before the taskbar repaints.'
        vi = 'Chỉ thay đổi giao diện của Windows; giao diện dùng cho ứng dụng là cài đặt riêng "Chế độ ứng dụng". Trong registry, Tối = 0 và Sáng = 1. Có thể cần khởi động lại Explorer hoặc đăng nhập lại để taskbar đổi màu.'
    } `
    -StateNames @('Dark', 'Light') -DefaultState 'Light' `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        Name = 'SystemUsesLightTheme'
        Map  = [ordered]@{
            Dark  = @(0)
            Light = @(1)
        }
    } `
    -States @{
        Dark = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'SystemUsesLightTheme'; Type = 'DWord'; Value = 0 }
        )
        Light = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'SystemUsesLightTheme'; Type = 'DWord'; Value = 1 }
        )
    }

New-WtRegistryTweak -Id 'Personalization.AppColorMode' -Category 'Personalization' `
    -Name @{
        en = 'App mode (light or dark app theme)'
        vi = 'Chế độ ứng dụng (giao diện ứng dụng sáng hoặc tối)'
    } `
    -Description @{
        en = 'Sets AppsUseLightTheme, the light or dark theme followed by Windows apps and the Settings app.'
        vi = 'Đặt AppsUseLightTheme, giao diện sáng hoặc tối mà các ứng dụng Windows và ứng dụng Cài đặt sử dụng.'
    } `
    -Impact @{
        en = 'Changes only the app theme; the Windows shell theme is the separate "Windows mode" setting. In the registry Dark = 0 and Light = 1. Apps that ignore the system theme are not affected, and an Explorer restart or a sign-out may be needed.'
        vi = 'Chỉ thay đổi giao diện ứng dụng; giao diện của Windows là cài đặt riêng "Chế độ Windows". Trong registry, Tối = 0 và Sáng = 1. Ứng dụng không tuân theo giao diện hệ thống sẽ không bị ảnh hưởng, và có thể cần khởi động lại Explorer hoặc đăng nhập lại.'
    } `
    -StateNames @('Dark', 'Light') -DefaultState 'Light' `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        Name = 'AppsUseLightTheme'
        Map  = [ordered]@{
            Dark  = @(0)
            Light = @(1)
        }
    } `
    -States @{
        Dark = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'AppsUseLightTheme'; Type = 'DWord'; Value = 0 }
        )
        Light = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'AppsUseLightTheme'; Type = 'DWord'; Value = 1 }
        )
    }

New-WtRegistryTweak -Id 'Personalization.AeroShaking' -Category 'Personalization' `
    -Name @{
        en = 'Aero Shake (shake a window to minimise the others)'
        vi = 'Aero Shake (lắc cửa sổ để thu nhỏ các cửa sổ khác)'
    } `
    -Description @{
        en = 'Sets DisallowShaking in the Explorer advanced settings, which controls the "shake a window to minimise all other windows" gesture. Both states also delete the NoWindowMinimizingShortcuts policy values, which would otherwise override the setting.'
        vi = 'Đặt DisallowShaking trong cài đặt nâng cao của Explorer, giá trị điều khiển thao tác "lắc cửa sổ để thu nhỏ mọi cửa sổ khác". Cả hai trạng thái đều xóa giá trị chính sách NoWindowMinimizingShortcuts, vì giá trị này sẽ ghi đè cài đặt.'
    } `
    -Impact @{
        en = 'Disabled writes DisallowShaking = 1, so the shake gesture does nothing and a window is not minimised by accident. Enabled writes 0 and restores the gesture. The legacy AeroShaking.ps1 wrote 0 for both of its parameter sets, so its -Disable flag never disabled anything; the mapping documented by Windows is used here instead.'
        vi = 'Trạng thái Tắt ghi DisallowShaking = 1, thao tác lắc cửa sổ không có tác dụng nên cửa sổ không bị thu nhỏ ngoài ý muốn. Trạng thái Bật ghi 0 và khôi phục thao tác này. Module AeroShaking.ps1 cũ ghi 0 cho cả hai bộ tham số, nên cờ -Disable của nó không bao giờ tắt được tính năng; ở đây dùng đúng quy ước của Windows.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Scope 'UserAndMachine' -Privilege 'Admin' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Name = 'DisallowShaking'
        Map  = [ordered]@{
            Enabled  = @(0)
            Disabled = @(1)
        }
    } `
    -States @{
        Enabled = @(
            # The legacy function deleted the policies in both parameter sets so that
            # the change is visible in the UI (the LGPO "DELETE" lines).
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'NoWindowMinimizingShortcuts' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'NoWindowMinimizingShortcuts' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'DisallowShaking'; Type = 'DWord'; Value = 0 }
        )
        Disabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'NoWindowMinimizingShortcuts' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'NoWindowMinimizingShortcuts' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'DisallowShaking'; Type = 'DWord'; Value = 1 }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'NoWindowMinimizingShortcuts' }
    )

New-WtRegistryTweak -Id 'Personalization.StickyKeys' -Category 'Personalization' `
    -Name @{
        en = 'Sticky Keys shortcut (pressing Shift five times)'
        vi = 'Phím tắt Sticky Keys (nhấn Shift năm lần)'
    } `
    -Description @{
        en = 'Sets the StickyKeys Flags value: 510 leaves the "press Shift five times" shortcut enabled, 506 turns it off.'
        vi = 'Đặt giá trị Flags của StickyKeys: 510 giữ phím tắt "nhấn Shift năm lần", 506 tắt phím tắt này.'
    } `
    -Impact @{
        en = 'Disabled writes Flags = 506, so pressing Shift five times no longer turns Sticky Keys on and its prompt no longer appears. Sticky Keys can still be switched on by hand in Settings > Accessibility > Keyboard. Enabled writes the Windows default 510. A sign-out is required for the change to take effect.'
        vi = 'Trạng thái Tắt ghi Flags = 506, nhấn Shift năm lần không còn bật Sticky Keys và không hiện hộp thoại hỏi nữa. Vẫn có thể bật Sticky Keys thủ công trong Cài đặt > Trợ năng > Bàn phím. Trạng thái Bật ghi giá trị mặc định 510 của Windows. Cần đăng nhập lại để thay đổi có hiệu lực.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Scope 'User' -Privilege 'None' -Restart 'SignOut' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Control Panel\Accessibility\StickyKeys'
        Name = 'Flags'
        Map  = [ordered]@{
            Enabled  = @('510')
            Disabled = @('506')
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Control Panel\Accessibility\StickyKeys'; Name = 'Flags'; Type = 'String'; Value = '510' }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Control Panel\Accessibility\StickyKeys'; Name = 'Flags'; Type = 'String'; Value = '506' }
        )
    }

New-WtScriptTweak -Id 'Personalization.InputMethod' -Category 'Personalization' `
    -Name @{
        en = 'Default input method override'
        vi = 'Ghi đè phương thức nhập mặc định'
    } `
    -Description @{
        en = 'Sets or clears HKCU\Control Panel\International\User Profile\InputMethodOverride - the value the legacy InputMethod module changed through Set-WinDefaultInputMethodOverride.'
        vi = 'Đặt hoặc xóa HKCU\Control Panel\International\User Profile\InputMethodOverride - giá trị mà module InputMethod cũ thay đổi qua lệnh Set-WinDefaultInputMethodOverride.'
    } `
    -Impact @{
        en = 'English pins the English (United States) keyboard (0409:00000409) as the input method for this user; other installed keyboards stay available in the language bar. Default removes the override, so the input method you select yourself is used again. A sign-out is required.'
        vi = 'Trạng thái English ghim bàn phím tiếng Anh (Hoa Kỳ) (0409:00000409) làm phương thức nhập cho người dùng này; các bàn phím khác vẫn có trong thanh ngôn ngữ. Trạng thái Mặc định xóa phần ghi đè, dùng lại phương thức nhập bạn tự chọn. Cần đăng nhập lại.'
    } `
    -StateNames @('English', 'Default') -DefaultState 'Default' `
    -Scope 'User' -Privilege 'None' -Restart 'SignOut' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detect {
        param ($Tweak, $Arguments)

        $Current = Get-WtRegistryState -Path 'HKCU:\Control Panel\International\User Profile' -Name 'InputMethodOverride'
        if (-not $Current.Available)
        {
            return @{ State = 'Unsupported'; Reason = 'Registry provider is not available on this platform.' }
        }

        if (-not $Current.ValueExists)
        {
            return @{ State = 'Default'; Reason = 'InputMethodOverride is not present; the input method selected by the user is used.' }
        }

        if (Test-WtValueEqual -Left $Current.Value -Right '0409:00000409')
        {
            return @{ State = 'English'; Reason = "InputMethodOverride = $($Current.Value) (English (United States))." }
        }

        return @{ State = 'Unknown'; Reason = "Input method override '$($Current.Value)' is not managed by this tweak." }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        $Results = @()

        if ($State -eq 'English')
        {
            $Results += Set-WtRegistryValue -Path 'HKCU:\Control Panel\International\User Profile' -Name 'InputMethodOverride' -Value '0409:00000409' -Kind 'String'
        }
        else
        {
            # The legacy Default branch removed the value instead of writing one.
            $Results += Remove-WtRegistryValue -Path 'HKCU:\Control Panel\International\User Profile' -Name 'InputMethodOverride'
        }

        return $Results
    }

New-WtRegistryTweak -Id 'Personalization.FirstLogonAnimation' -Category 'Personalization' `
    -Name @{
        en = 'First sign-in animation after an upgrade'
        vi = 'Hiệu ứng đăng nhập lần đầu sau khi nâng cấp'
    } `
    -Description @{
        en = 'Sets the Winlogon EnableFirstLogonAnimation value, which controls the "we are getting things ready" animation shown the first time an account signs in after a feature update. Both states also delete the policy value under Policies\System that would otherwise override it.'
        vi = 'Đặt giá trị EnableFirstLogonAnimation trong Winlogon, giá trị điều khiển hiệu ứng "đang chuẩn bị" hiển thị ở lần đăng nhập đầu tiên sau khi cập nhật tính năng. Cả hai trạng thái đều xóa giá trị chính sách trong Policies\System, vì giá trị này sẽ ghi đè cài đặt.'
    } `
    -Impact @{
        en = 'Disabled suppresses the animation after the next feature update, so signing in is quicker and shows no "getting ready" screen; Enabled restores it. The change applies at a later upgrade, not to the current session.'
        vi = 'Trạng thái Tắt bỏ hiệu ứng sau bản cập nhật tính năng kế tiếp, đăng nhập nhanh hơn và không hiện màn hình "đang chuẩn bị"; trạng thái Bật khôi phục lại. Thay đổi có hiệu lực ở lần nâng cấp sau, không ảnh hưởng phiên hiện tại.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Name = 'EnableFirstLogonAnimation'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            # Deleted in both states by the legacy function (LGPO "DELETE" lines) so
            # that the Winlogon value below is not overridden.
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'EnableFirstLogonAnimation' }
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'; Name = 'EnableFirstLogonAnimation'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'EnableFirstLogonAnimation' }
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'; Name = 'EnableFirstLogonAnimation'; Type = 'DWord'; Value = 0 }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'EnableFirstLogonAnimation' }
    )

New-WtScriptTweak -Id 'Personalization.JpegWallpapersQuality' -Category 'Personalization' `
    -Name @{
        en = 'JPEG wallpaper quality factor'
        vi = 'Chất lượng ảnh nền JPEG'
    } `
    -Description @{
        en = 'Sets HKCU\Control Panel\Desktop\JPEGImportQuality, the quality factor Windows uses when it imports and re-encodes a JPEG desktop wallpaper.'
        vi = 'Đặt HKCU\Control Panel\Desktop\JPEGImportQuality, hệ số chất lượng Windows dùng khi nhập và mã hóa lại ảnh nền JPEG.'
    } `
    -Impact @{
        en = 'Max writes 100, so wallpapers keep the highest quality and are stored in a larger file. Default removes the value, so Windows uses its own built-in factor again. Only the desktop wallpaper is affected.'
        vi = 'Trạng thái Tối đa ghi 100, ảnh nền giữ chất lượng cao nhất và có tệp lớn hơn. Trạng thái Mặc định xóa giá trị, Windows dùng lại hệ số mặc định của mình. Chỉ ảnh nền màn hình bị ảnh hưởng.'
    } `
    -StateNames @('Max', 'Default') -DefaultState 'Default' `
    -Scope 'User' -Privilege 'None' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detect {
        param ($Tweak, $Arguments)

        $Current = Get-WtRegistryState -Path 'HKCU:\Control Panel\Desktop' -Name 'JPEGImportQuality'
        if (-not $Current.Available)
        {
            return @{ State = 'Unsupported'; Reason = 'Registry provider is not available on this platform.' }
        }

        if (-not $Current.ValueExists)
        {
            return @{ State = 'Default'; Reason = 'JPEGImportQuality is not present; Windows uses its built-in quality factor.' }
        }

        if (Test-WtValueEqual -Left $Current.Value -Right 100)
        {
            return @{ State = 'Max'; Reason = 'JPEGImportQuality = 100 (maximum).' }
        }

        return @{ State = 'Unknown'; Reason = "JPEG import quality $($Current.Value) is not managed by this tweak." }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        $Results = @()

        if ($State -eq 'Max')
        {
            $Results += Set-WtRegistryValue -Path 'HKCU:\Control Panel\Desktop' -Name 'JPEGImportQuality' -Value 100 -Kind 'DWord'
        }
        else
        {
            # The legacy Default branch removed the value instead of writing one.
            $Results += Remove-WtRegistryValue -Path 'HKCU:\Control Panel\Desktop' -Name 'JPEGImportQuality'
        }

        return $Results
    }

New-WtRegistryTweak -Id 'Personalization.PrtScnSnippingTool' -Category 'Personalization' `
    -Name @{
        en = 'Print Screen key opens screen snipping'
        vi = 'Phím Print Screen mở công cụ cắt màn hình'
    } `
    -Description @{
        en = 'Sets PrintScreenKeyForSnippingEnabled: 1 makes the Print Screen key open screen snipping, 0 keeps the classic behaviour of copying the screen to the clipboard.'
        vi = 'Đặt PrintScreenKeyForSnippingEnabled: 1 để phím Print Screen mở công cụ cắt màn hình, 0 để giữ hành vi cổ điển là sao chép màn hình vào clipboard.'
    } `
    -Impact @{
        en = 'Enabled (1) is the Windows 11 22H2 and later default. Disabled (0) restores the classic Print Screen behaviour; an installed screenshot app can still take the key over. A sign-out may be required before the key behaves differently.'
        vi = 'Trạng thái Bật (1) là mặc định từ Windows 11 22H2. Trạng thái Tắt (0) khôi phục hành vi Print Screen cổ điển; ứng dụng chụp ảnh đã cài vẫn có thể chiếm phím này. Có thể cần đăng nhập lại để phím hoạt động khác đi.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Scope 'User' -Privilege 'None' -Restart 'SignOut' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Control Panel\Keyboard'
        Name = 'PrintScreenKeyForSnippingEnabled'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Control Panel\Keyboard'; Name = 'PrintScreenKeyForSnippingEnabled'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Control Panel\Keyboard'; Name = 'PrintScreenKeyForSnippingEnabled'; Type = 'DWord'; Value = 0 }
        )
    }

New-WtScriptTweak -Id 'Personalization.ControlPanelView' -Category 'Personalization' `
    -Name @{
        en = 'Control Panel start page and icon size'
        vi = 'Trang bắt đầu và cỡ biểu tượng của Control Panel'
    } `
    -Description @{
        en = 'Sets StartupPage and AllItemsIconView under Explorer\ControlPanel, and deletes the ForceClassicControlPanel policy value that would otherwise pin the classic all-items view.'
        vi = 'Đặt StartupPage và AllItemsIconView trong Explorer\ControlPanel, đồng thời xóa giá trị chính sách ForceClassicControlPanel, vì giá trị này sẽ ghim chế độ xem tất cả các mục cổ điển.'
    } `
    -Impact @{
        en = 'Category opens Control Panel on the category page; LargeIcons and SmallIcons open the all-items page with large or small icons. In the registry StartupPage 0 = categories and 1 = all items, AllItemsIconView 0 = large icons and 1 = small icons. An organization policy can still force the classic view, which the catalog reports.'
        vi = 'Trạng thái Danh mục mở Control Panel ở trang danh mục; Biểu tượng lớn và Biểu tượng nhỏ mở trang tất cả các mục với biểu tượng lớn hoặc nhỏ. Trong registry, StartupPage 0 = danh mục và 1 = tất cả các mục, AllItemsIconView 0 = biểu tượng lớn và 1 = biểu tượng nhỏ. Chính sách của tổ chức vẫn có thể buộc chế độ xem cổ điển, danh mục sẽ báo điều đó.'
    } `
    -StateNames @('Category', 'LargeIcons', 'SmallIcons') -DefaultState 'Category' `
    -Scope 'User' -Privilege 'None' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detect {
        param ($Tweak, $Arguments)

        $Startup = Get-WtRegistryState -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel' -Name 'StartupPage'
        $IconView = Get-WtRegistryState -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel' -Name 'AllItemsIconView'

        if (-not $Startup.Available -or -not $IconView.Available)
        {
            return @{ State = 'Unsupported'; Reason = 'Registry provider is not available on this platform.' }
        }

        if (-not $Startup.ValueExists)
        {
            return @{ State = 'Category'; Reason = 'StartupPage is not present; Windows opens Control Panel in the category view by default.' }
        }

        if (Test-WtValueEqual -Left $Startup.Value -Right 0)
        {
            return @{ State = 'Category'; Reason = 'StartupPage = 0 (category view).' }
        }

        if (Test-WtValueEqual -Left $Startup.Value -Right 1)
        {
            # The start page alone cannot tell the two icon views apart, so the icon
            # view value decides; when it is absent Windows uses large icons.
            if (-not $IconView.ValueExists)
            {
                return @{ State = 'LargeIcons'; Reason = 'StartupPage = 1 and AllItemsIconView is not present; Windows shows large icons by default.' }
            }

            if (Test-WtValueEqual -Left $IconView.Value -Right 1)
            {
                return @{ State = 'SmallIcons'; Reason = 'StartupPage = 1, AllItemsIconView = 1.' }
            }

            if (Test-WtValueEqual -Left $IconView.Value -Right 0)
            {
                return @{ State = 'LargeIcons'; Reason = 'StartupPage = 1, AllItemsIconView = 0.' }
            }

            return @{ State = 'Unknown'; Reason = "AllItemsIconView value '$($IconView.Value)' is not managed by this tweak." }
        }

        return @{ State = 'Unknown'; Reason = "StartupPage value '$($Startup.Value)' is not managed by this tweak." }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        $Results = @()

        # The legacy function deleted this policy in every parameter set so that the
        # selected view becomes visible (the LGPO "DELETE" line).
        $Results += Remove-WtRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name 'ForceClassicControlPanel'

        switch ($State)
        {
            'Category'
            {
                $Results += Set-WtRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel' -Name 'AllItemsIconView' -Value 0 -Kind 'DWord'
                $Results += Set-WtRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel' -Name 'StartupPage' -Value 0 -Kind 'DWord'
            }
            'LargeIcons'
            {
                $Results += Set-WtRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel' -Name 'AllItemsIconView' -Value 0 -Kind 'DWord'
                $Results += Set-WtRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel' -Name 'StartupPage' -Value 1 -Kind 'DWord'
            }
            'SmallIcons'
            {
                $Results += Set-WtRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel' -Name 'AllItemsIconView' -Value 1 -Kind 'DWord'
                $Results += Set-WtRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel' -Name 'StartupPage' -Value 1 -Kind 'DWord'
            }
            default
            {
                $Results += New-WtOperationResult -Status 'failed' -Operation 'SetControlPanelView' -Target $Tweak.Id -Message "Unsupported state '$State'."
            }
        }

        return $Results
    } `
    -ManagedPolicy @(
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'ForceClassicControlPanel' }
    )
