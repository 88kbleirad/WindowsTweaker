# WindowsTweaker - Taskbar batch G10.
#
# Converts the legacy modules TaskbarCombine.ps1, TaskbarEndTask.ps1 and
# SecondsInSystemClock.ps1 into declarative registry tweaks.
#
# modules/TaskbarSearch.ps1, modules/TaskViewButton.ps1 and modules/TaskbarAlignment.ps1
# are already covered by Taskbar.ps1 (Taskbar.SearchBox, Taskbar.TaskViewButton,
# Taskbar.Alignment) and are therefore not repeated here.
#
# modules/UnpinTaskbarShortcuts.ps1 is not ported: it unpins shortcuts with a localized
# shell "Unpin from taskbar" verb (obtained through an inline WinAPI Add-Type helper)
# and by removing .lnk files under %APPDATA%\Microsoft\Internet Explorer\Quick
# Launch\User Pinned\Taskbar. Neither is expressible with the providers, and the
# pinned-layout registry area (Explorer\Taskband\Favorites) is an opaque Explorer
# binary blob, not a per-shortcut list. See docs/migration-notes/Taskbar.G10.md.

New-WtRegistryTweak -Id 'Taskbar.CombineButtons' -Category 'Taskbar' `
    -Name @{
        en = 'Combine taskbar buttons'
        vi = 'Gộp các nút trên taskbar'
    } `
    -Description @{
        en = 'Sets whether taskbar buttons are always combined, combined only when the taskbar is full, or never combined (one button per window, with labels).'
        vi = 'Đặt cách gộp các nút trên taskbar: luôn gộp, chỉ gộp khi taskbar đầy, hoặc không bao giờ gộp (mỗi cửa sổ một nút kèm nhãn).'
    } `
    -Impact @{
        en = '"Never" gives every window its own taskbar button and fills the taskbar faster; it does not change how windows are listed in Alt+Tab or Task View. Applying any state clears the NoTaskGrouping policy that would otherwise keep the setting fixed.'
        vi = '"Không bao giờ" khiến mỗi cửa sổ có nút riêng và taskbar đầy nhanh hơn; cách liệt kê cửa sổ trong Alt+Tab hoặc Task View không thay đổi. Mọi trạng thái đều xoá chính sách NoTaskGrouping vốn sẽ ghim cứng thiết lập này.'
    } `
    -StateNames @('Always', 'WhenFull', 'Never') -DefaultState 'Always' `
    -Scope 'UserAndMachine' -Privilege 'Admin' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Name = 'TaskbarGlomLevel'
        Map  = [ordered]@{
            Always   = @(0)
            WhenFull = @(1)
            Never    = @(2)
        }
    } `
    -States @{
        Always = @(
            # The legacy module removed NoTaskGrouping from both the machine and the
            # per-user policy key (its two LGPO DELETE lines target these same keys),
            # because either one overrides TaskbarGlomLevel.
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoTaskGrouping' }
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoTaskGrouping' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarGlomLevel'; Type = 'DWord'; Value = 0 }
        )
        WhenFull = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoTaskGrouping' }
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoTaskGrouping' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarGlomLevel'; Type = 'DWord'; Value = 1 }
        )
        Never = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoTaskGrouping' }
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoTaskGrouping' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarGlomLevel'; Type = 'DWord'; Value = 2 }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoTaskGrouping' }
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoTaskGrouping' }
    )

New-WtRegistryTweak -Id 'Taskbar.EndTask' -Category 'Taskbar' `
    -Name @{
        en = 'End task in the taskbar context menu'
        vi = 'Kết thúc tác vụ trong menu chuột phải taskbar'
    } `
    -Description @{
        en = 'Adds "End task" to the right-click menu of a taskbar button, so an unresponsive app can be closed without opening Task Manager.'
        vi = 'Thêm "End task" vào menu chuột phải của nút trên taskbar để đóng ứng dụng bị treo mà không cần mở Task Manager.'
    } `
    -Impact @{
        en = 'The entry only appears on taskbar buttons. It terminates the process immediately, without the usual save prompt, so unsaved work in that app can be lost.'
        vi = 'Mục này chỉ xuất hiện trên nút ở taskbar. Nó kết thúc tiến trình ngay lập tức, không có hộp thoại lưu, nên dữ liệu chưa lưu của ứng dụng đó có thể mất.'
    } `
    -SupportedOS @('Windows11') -MinBuild 22621 `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'
        Name = 'TaskbarEndTask'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'; Name = 'TaskbarEndTask'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            # The legacy module deleted the value; writing the documented default (0)
            # means the same thing and keeps detection deterministic. Rollback still
            # restores the exact previous state, including "value absent".
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'; Name = 'TaskbarEndTask'; Type = 'DWord'; Value = 0 }
        )
    }

New-WtRegistryTweak -Id 'Taskbar.SecondsInClock' -Category 'Taskbar' `
    -Name @{
        en = 'Seconds in the system clock'
        vi = 'Giây trong đồng hồ hệ thống'
    } `
    -Description @{
        en = 'Shows the seconds in the taskbar clock instead of hours and minutes only.'
        vi = 'Hiển thị cả giây trong đồng hồ trên taskbar thay vì chỉ giờ và phút.'
    } `
    -Impact @{
        en = 'The clock is redrawn every second while it is visible, which keeps Explorer slightly busier. The registry value is honoured on Windows 10 1607+ and on Windows 11 22H2 (build 22621) and later; on earlier Windows 11 builds the value is stored but the clock ignores it.'
        vi = 'Đồng hồ được vẽ lại mỗi giây khi hiển thị, khiến Explorer bận hơn một chút. Giá trị này có hiệu lực trên Windows 10 1607 trở lên và Windows 11 22H2 (build 22621) trở lên; trên các bản Windows 11 sớm hơn, giá trị vẫn được lưu nhưng đồng hồ không hiển thị giây.'
    } `
    -MinBuild 14393 `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Name = 'ShowSecondsInSystemClock'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowSecondsInSystemClock'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowSecondsInSystemClock'; Type = 'DWord'; Value = 0 }
        )
    }
