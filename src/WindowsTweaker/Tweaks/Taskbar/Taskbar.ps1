# WindowsTweaker - Taskbar and Start menu tweaks.
#
# Note on the widgets tweak: the legacy modules/TaskbarWidgets.ps1 copied
# powershell.exe to powershell_temp.exe in System32 and invoked it to work around the
# UCPD driver. That behaviour is removed: writing executables into System32 is not
# something this tool does. The registry values themselves are written directly, and
# the outcome is verified like any other change.

New-WtRegistryTweak -Id 'Taskbar.Widgets' -Category 'Taskbar' `
    -Name @{
        en = 'Widgets button on the taskbar'
        vi = 'Nút Widgets trên taskbar'
    } `
    -Description @{
        en = 'Shows or hides the Widgets (news and interests) button on the taskbar.'
        vi = 'Hiện hoặc ẩn nút Widgets (tin tức và mối quan tâm) trên taskbar.'
    } `
    -Impact @{
        en = 'Hiding the button does not uninstall the Web Experience package; the feed is still available from other entry points.'
        vi = 'Ẩn nút không gỡ gói Web Experience; bảng tin vẫn truy cập được từ các nơi khác.'
    } `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Name = 'TaskbarDa'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; Name = 'AllowNewsAndInterests' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\NewsAndInterests\AllowNewsAndInterests'; Name = 'value' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarDa'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; Name = 'AllowNewsAndInterests' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\NewsAndInterests\AllowNewsAndInterests'; Name = 'value' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarDa'; Type = 'DWord'; Value = 0 }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; Name = 'AllowNewsAndInterests' }
    )

New-WtRegistryTweak -Id 'Taskbar.Alignment' -Category 'Taskbar' `
    -Name @{
        en = 'Taskbar alignment'
        vi = 'Căn chỉnh taskbar'
    } `
    -Description @{
        en = 'Aligns the taskbar icons to the centre (Windows 11 default) or to the left.'
        vi = 'Căn biểu tượng taskbar ra giữa (mặc định Windows 11) hoặc sang trái.'
    } `
    -Impact @{
        en = 'Explorer restarts to apply the change; open File Explorer windows are restored.'
        vi = 'Explorer sẽ khởi động lại để áp dụng; các cửa sổ File Explorer đang mở sẽ được khôi phục.'
    } `
    -StateNames @('Disabled', 'Enabled') -DefaultState 'Disabled' `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Name = 'TaskbarAl'
        Map  = [ordered]@{
            Disabled = @(0)
            Enabled  = @(1)
        }
    } `
    -States @{
        Disabled = @(
            # State 'Disabled' = left aligned
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAl'; Type = 'DWord'; Value = 0 }
        )
        Enabled = @(
            # State 'Enabled' = centred
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAl'; Type = 'DWord'; Value = 1 }
        )
    }

New-WtRegistryTweak -Id 'Taskbar.SearchBox' -Category 'Taskbar' `
    -Name @{
        en = 'Search box on the taskbar'
        vi = 'Hộp tìm kiếm trên taskbar'
    } `
    -Description @{
        en = 'Sets the taskbar search entry to hidden, icon only, search box, or icon with label.'
        vi = 'Đặt mục tìm kiếm trên taskbar thành ẩn, chỉ biểu tượng, hộp tìm kiếm, hoặc biểu tượng kèm nhãn.'
    } `
    -Impact @{
        en = 'Hiding the search entry does not disable Windows Search itself.'
        vi = 'Ẩn mục tìm kiếm không tắt Windows Search.'
    } `
    -StateNames @('Hidden', 'IconOnly', 'SearchBox', 'IconAndLabel') -DefaultState 'SearchBox' `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'
        Name = 'SearchboxTaskbarMode'
        Map  = [ordered]@{
            Hidden       = @(0)
            IconOnly     = @(1)
            SearchBox    = @(2)
            IconAndLabel = @(3)
        }
    } `
    -States @{
        Hidden = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'DisableSearch' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'SearchOnTaskbarMode' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'SearchboxTaskbarMode'; Type = 'DWord'; Value = 0 }
        )
        IconOnly = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'DisableSearch' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'SearchOnTaskbarMode' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'SearchboxTaskbarMode'; Type = 'DWord'; Value = 1 }
        )
        SearchBox = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'DisableSearch' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'SearchOnTaskbarMode' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'SearchboxTaskbarMode'; Type = 'DWord'; Value = 2 }
        )
        IconAndLabel = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'DisableSearch' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'SearchOnTaskbarMode' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'SearchboxTaskbarMode'; Type = 'DWord'; Value = 3 }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'SearchOnTaskbarMode' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'DisableSearch' }
    )

New-WtRegistryTweak -Id 'Taskbar.TaskViewButton' -Category 'Taskbar' `
    -Name @{
        en = 'Task View button'
        vi = 'Nút Task View'
    } `
    -Description @{
        en = 'Shows or hides the Task View button on the taskbar.'
        vi = 'Hiện hoặc ẩn nút Task View trên taskbar.'
    } `
    -Impact @{
        en = 'Task View is still reachable with the keyboard shortcut Win+Tab.'
        vi = 'Vẫn có thể mở Task View bằng tổ hợp Win+Tab.'
    } `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Name = 'ShowTaskViewButton'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            # Clear the policy that would otherwise override the user value.
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'HideTaskViewButton' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'HideTaskViewButton' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowTaskViewButton'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'HideTaskViewButton' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'HideTaskViewButton' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowTaskViewButton'; Type = 'DWord'; Value = 0 }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'HideTaskViewButton' }
        @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'HideTaskViewButton' }
    )
