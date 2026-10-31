# WindowsTweaker - application preference and shell context-menu tweaks (batch G7).
#
# Derived from Sophia Script for Windows (MIT, (c) 2023 farag2) where noted; every
# setting below was re-expressed as explicit, reversible operations instead of a
# policy transcript (see THIRD-PARTY-NOTICES.md). Deviations from the legacy modules
# are listed in docs/migration-notes/Apps.G7.md - in short:
#   * typos in a registry path, a value name or a CLSID were corrected to the value
#     Windows actually uses (they were confirmed against Microsoft documentation or
#     the vendor registration),
#   * the legacy DISM switch /App-Package is not a valid DISM option and was replaced
#     by /Add-Package for the .cab context menu entry.
#
# The context-menu tweaks below create or delete shell registrations. "Hidden" means
# the entry is removed from the menu, "Shown" means the registration is restored.
# Every state lists the complete set of operations needed to reach it, including the
# machine-wide block value (HKLM), which is written and removed explicitly instead of
# through a policy transcript.

New-WtRegistryTweak -Id 'Apps.DefaultTerminalApp' -Category 'Apps' `
    -Name @{
        en = 'Default terminal application'
        vi = 'Ứng dụng terminal mặc định'
    } `
    -Description @{
        en = 'Chooses which console host opens when a console application starts: Windows Terminal or the legacy Console Host (conhost).'
        vi = 'Chọn chương trình máy chủ console mở khi một ứng dụng console khởi chạy: Windows Terminal hoặc Console Host cũ (conhost).'
    } `
    -Impact @{
        en = 'The choice is stored per user in HKCU\Console\%%Startup. The Windows Terminal option only works while the Windows Terminal package is installed; console windows that are already open keep their current host.'
        vi = 'Lựa chọn được lưu theo từng người dùng trong HKCU\Console\%%Startup. Tùy chọn Windows Terminal chỉ hoạt động khi gói Windows Terminal đã được cài; các cửa sổ console đang mở vẫn giữ máy chủ hiện tại.'
    } `
    -StateNames @('WindowsTerminal', 'ConsoleHost') -DefaultState 'WindowsTerminal' `
    -Scope 'User' -Privilege 'None' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Console\%%Startup'
        Name = 'DelegationConsole'
        Map  = [ordered]@{
            WindowsTerminal = @('{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}')
            ConsoleHost     = @('{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}')
        }
    } `
    -States @{
        WindowsTerminal = @(
            # Both values are the packaged COM server ids Windows Terminal registers
            # for the console delegation; they are stable across Terminal versions.
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Console\%%Startup'; Name = 'DelegationConsole'; Type = 'String'; Value = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Console\%%Startup'; Name = 'DelegationTerminal'; Type = 'String'; Value = '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}' }
        )
        ConsoleHost = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Console\%%Startup'; Name = 'DelegationConsole'; Type = 'String'; Value = '{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Console\%%Startup'; Name = 'DelegationTerminal'; Type = 'String'; Value = '{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}' }
        )
    }

New-WtRegistryTweak -Id 'Apps.UseStoreOpenWith' -Category 'Apps' `
    -Name @{
        en = 'Microsoft Store link in the Open with dialog'
        vi = 'Liên kết Microsoft Store trong hộp thoại Mở bằng'
    } `
    -Description @{
        en = 'Controls the "Look for an app in the Microsoft Store" link that the Open with dialog offers for file types without an installed application.'
        vi = 'Điều khiển liên kết "Tìm ứng dụng trong Microsoft Store" mà hộp thoại Mở bằng hiển thị cho các loại tệp chưa có ứng dụng được cài.'
    } `
    -Impact @{
        en = 'Hiding the link only removes that shortcut; the dialog still lets you pick an installed application. The machine-wide policy value is removed so that the per-user value takes effect.'
        vi = 'Ẩn liên kết chỉ bỏ lối tắt đó; hộp thoại vẫn cho phép chọn ứng dụng đã cài. Giá trị chính sách toàn máy sẽ bị xóa để giá trị theo người dùng có hiệu lực.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Disabled' `
    -Scope 'UserAndMachine' -Privilege 'Admin' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
        Name = 'NoUseStoreOpenWith'
        Map  = [ordered]@{
            Enabled  = @(0)
            Disabled = @(1)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'NoUseStoreOpenWith' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'NoUseStoreOpenWith'; Type = 'DWord'; Value = 0 }
        )
        Disabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'NoUseStoreOpenWith' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'NoUseStoreOpenWith'; Type = 'DWord'; Value = 1 }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'NoUseStoreOpenWith' }
    )

New-WtRegistryTweak -Id 'Apps.AutoPlay' -Category 'Apps' `
    -Name @{
        en = 'AutoPlay for drives and devices'
        vi = 'Tự động phát cho ổ đĩa và thiết bị'
    } `
    -Description @{
        en = 'Turns AutoPlay on or off for drives and removable devices, and clears the legacy autorun policy that would otherwise override the choice.'
        vi = 'Bật hoặc tắt Tự động phát cho ổ đĩa và thiết bị tháo rời, đồng thời xóa chính sách autorun cũ vốn sẽ ghi đè lựa chọn này.'
    } `
    -Impact @{
        en = 'With AutoPlay off, Windows no longer offers a handler when media is inserted; the content is still readable. Per-device AutoPlay settings you made earlier are not changed.'
        vi = 'Khi tắt Tự động phát, Windows không còn gợi ý ứng dụng khi gắn phương tiện; nội dung vẫn đọc được. Các cấu hình Tự động phát theo từng thiết bị bạn đã chọn trước đó không bị thay đổi.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Disabled' `
    -Scope 'UserAndMachine' -Privilege 'Admin' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers'
        Name = 'DisableAutoPlay'
        Map  = [ordered]@{
            Disabled = @(1)
            Enabled  = @(0)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoDriveTypeAutoRun' }
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoDriveTypeAutoRun' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers'; Name = 'DisableAutoPlay'; Type = 'DWord'; Value = 0 }
        )
        Disabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoDriveTypeAutoRun' }
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoDriveTypeAutoRun' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers'; Name = 'DisableAutoPlay'; Type = 'DWord'; Value = 1 }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoDriveTypeAutoRun' }
    )

New-WtRegistryTweak -Id 'Apps.F1HelpPage' -Category 'Apps' `
    -Name @{
        en = 'F1 Help page'
        vi = 'Trang trợ giúp F1'
    } `
    -Description @{
        en = 'Disables the Windows Help and Support page that the F1 key opens by registering an empty per-user override for the shell help type library.'
        vi = 'Tắt trang Trợ giúp và Hỗ trợ của Windows khi nhấn F1 bằng cách đăng ký một ghi đè rỗng theo người dùng cho thư viện kiểu trợ giúp của shell.'
    } `
    -Impact @{
        en = 'F1 no longer opens Windows Help and Support in applications that use the shell help page. Help that an application implements itself is not affected. Sign out or restart Explorer if the old behaviour persists.'
        vi = 'F1 sẽ không mở Trợ giúp và Hỗ trợ Windows trong các ứng dụng dùng trang trợ giúp của shell. Trợ giúp do ứng dụng tự cung cấp không bị ảnh hưởng. Hãy đăng xuất hoặc khởi động lại Explorer nếu hành vi cũ vẫn còn.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Disabled' `
    -Scope 'User' -Privilege 'None' -Restart 'None' -Rollback 'Partial' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Classes\Typelib\{8cec5860-07a1-11d9-b15e-000d56bfe6ee}\1.0\0\win64'
        Name = '(default)'
        Map  = [ordered]@{
            Disabled = @('')
        }
    } `
    -States @{
        Enabled = @(
            # Removing the override restores the machine-wide type library the shell
            # resolves for the help page.
            @{ Kind = 'RegistryKeyRemove'; Path = 'HKCU:\Software\Classes\Typelib\{8cec5860-07a1-11d9-b15e-000d56bfe6ee}'; Recurse = $true }
        )
        Disabled = @(
            # An empty unnamed value for the win32/win64 platform of that library
            # makes the per-user registration shadow the real one.
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Classes\Typelib\{8cec5860-07a1-11d9-b15e-000d56bfe6ee}\1.0\0\win32'; Name = '(default)'; Type = 'String'; Value = '' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Classes\Typelib\{8cec5860-07a1-11d9-b15e-000d56bfe6ee}\1.0\0\win64'; Name = '(default)'; Type = 'String'; Value = '' }
        )
    }

New-WtRegistryTweak -Id 'Apps.PreventEdgeShortcutCreation' -Category 'Apps' `
    -Name @{
        en = 'Edge desktop shortcut creation'
        vi = 'Tạo lối tắt Edge trên màn hình'
    } `
    -Description @{
        en = 'Uses the Microsoft Edge Update policy to control whether installing Edge creates a desktop shortcut, for the Stable, Beta, Dev and Canary channels.'
        vi = 'Dùng chính sách Microsoft Edge Update để điều khiển việc cài Edge có tạo lối tắt trên màn hình hay không, áp dụng cho các kênh Stable, Beta, Dev và Canary.'
    } `
    -Impact @{
        en = 'The policy only applies to an installation or update that happens after the change and never deletes shortcuts that already exist. It has no effect on a machine where Edge is not installed.'
        vi = 'Chính sách chỉ áp dụng cho lần cài đặt hoặc cập nhật xảy ra sau thay đổi và không bao giờ xóa lối tắt đã có. Không có tác dụng trên máy chưa cài Edge.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Disabled' `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'
        Name = 'CreateDesktopShortcut{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'
        Map  = [ordered]@{
            Disabled = @(0)
            Enabled  = @(1)
        }
    } `
    -States @{
        Enabled = @(
            # Not configured: Edge keeps its default behaviour and creates the
            # shortcut when it installs.
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'; Name = 'CreateDesktopShortcut{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'; Name = 'CreateDesktopShortcut{2CD8A007-E189-409D-A2C8-9AF4EF3C72AA}' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'; Name = 'CreateDesktopShortcut{0D50BFEC-CD6A-4F9A-964C-C7416E3ACB10}' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'; Name = 'CreateDesktopShortcut{65C35B14-6C1D-4122-AC46-7148CC9D6497}' }
        )
        Disabled = @(
            # 0 = do not create the desktop shortcut for that channel.
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'; Name = 'CreateDesktopShortcut{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'; Type = 'DWord'; Value = 0 }
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'; Name = 'CreateDesktopShortcut{2CD8A007-E189-409D-A2C8-9AF4EF3C72AA}'; Type = 'DWord'; Value = 0 }
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'; Name = 'CreateDesktopShortcut{0D50BFEC-CD6A-4F9A-964C-C7416E3ACB10}'; Type = 'DWord'; Value = 0 }
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'; Name = 'CreateDesktopShortcut{65C35B14-6C1D-4122-AC46-7148CC9D6497}'; Type = 'DWord'; Value = 0 }
        )
    }

New-WtRegistryTweak -Id 'Apps.CompressedFolderNewContext' -Category 'Apps' `
    -Name @{
        en = 'Compressed (zipped) folder in the New menu'
        vi = 'Thư mục nén (zip) trong menu Mới'
    } `
    -Description @{
        en = 'Shows or hides the "Compressed (zipped) folder" entry of the Explorer New menu by restoring or deleting its ShellNew registration for the .zip file type.'
        vi = 'Hiện hoặc ẩn mục "Thư mục nén (zip)" trong menu Mới của Explorer bằng cách khôi phục hoặc xóa đăng ký ShellNew của loại tệp .zip.'
    } `
    -Impact @{
        en = 'Hiding removes only the template used by the New menu; zip files can still be created and opened. The registration is machine-wide, so elevation is required. Restart Explorer if the menu does not change immediately.'
        vi = 'Ẩn chỉ xóa mẫu mà menu Mới sử dụng; tệp zip vẫn có thể tạo và mở bình thường. Đăng ký này áp dụng toàn máy nên cần quyền quản trị. Hãy khởi động lại Explorer nếu menu không đổi ngay.'
    } `
    -StateNames @('Shown', 'Hidden') -DefaultState 'Hidden' `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'Explorer' -Rollback 'Partial' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCR:\.zip\CompressedFolder\ShellNew'
        Name = 'ItemName'
        Map  = [ordered]@{
            Shown = @('@%SystemRoot%\System32\zipfldr.dll,-10194')
        }
    } `
    -States @{
        Shown = @(
            # 22-byte empty ZIP end-of-central-directory record, the template the
            # shell copies when a new compressed folder is created.
            @{ Kind = 'RegistrySet'; Path = 'HKCR:\.zip\CompressedFolder\ShellNew'; Name = 'Data'; Type = 'Binary'; Value = [byte[]](80, 75, 5, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) }
            @{ Kind = 'RegistrySet'; Path = 'HKCR:\.zip\CompressedFolder\ShellNew'; Name = 'ItemName'; Type = 'ExpandString'; Value = '@%SystemRoot%\System32\zipfldr.dll,-10194' }
        )
        Hidden = @(
            @{ Kind = 'RegistryKeyRemove'; Path = 'HKCR:\.zip\CompressedFolder\ShellNew'; Recurse = $true }
        )
    }

New-WtRegistryTweak -Id 'Apps.MsiExtractContext' -Category 'Apps' `
    -Name @{
        en = 'Extract context menu for MSI packages'
        vi = 'Menu ngữ cảnh Trích xuất cho gói MSI'
    } `
    -Description @{
        en = 'Adds or removes the Extract command in the context menu of .msi packages, which expands the package into a folder next to it with msiexec.'
        vi = 'Thêm hoặc xóa lệnh Trích xuất trong menu ngữ cảnh của gói .msi, lệnh này dùng msiexec để giải nén gói vào thư mục bên cạnh tệp.'
    } `
    -Impact @{
        en = 'The command needs elevation only when it is started from an elevated shell; it writes the extracted files into a folder named after the package plus " extracted". The registration is machine-wide. Restart Explorer if the entry does not appear.'
        vi = 'Lệnh chỉ cần quyền quản trị khi chạy từ cửa sổ đã nâng quyền; lệnh ghi các tệp đã giải nén vào thư mục cùng tên gói kèm " extracted". Đăng ký này áp dụng toàn máy. Hãy khởi động lại Explorer nếu mục không xuất hiện.'
    } `
    -StateNames @('Shown', 'Hidden') -DefaultState 'Hidden' `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'Explorer' -Rollback 'Partial' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCR:\Msi.Package\shell\Extract\Command'
        Name = '(default)'
        Map  = [ordered]@{
            Shown = @('msiexec.exe /a "%1" /qb TARGETDIR="%1 extracted"')
        }
    } `
    -States @{
        Shown = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCR:\Msi.Package\shell\Extract\Command'; Name = '(default)'; Type = 'String'; Value = 'msiexec.exe /a "%1" /qb TARGETDIR="%1 extracted"' }
            @{ Kind = 'RegistrySet'; Path = 'HKCR:\Msi.Package\shell\Extract'; Name = 'MUIVerb'; Type = 'String'; Value = '@shell32.dll,-37514' }
            @{ Kind = 'RegistrySet'; Path = 'HKCR:\Msi.Package\shell\Extract'; Name = 'Icon'; Type = 'String'; Value = 'shell32.dll,-16817' }
        )
        Hidden = @(
            @{ Kind = 'RegistryKeyRemove'; Path = 'HKCR:\Msi.Package\shell\Extract'; Recurse = $true }
        )
    }

New-WtRegistryTweak -Id 'Apps.EditWithClipchampContext' -Category 'Apps' `
    -Name @{
        en = 'Edit with Clipchamp context menu'
        vi = 'Menu ngữ cảnh Edit with Clipchamp'
    } `
    -Description @{
        en = 'Shows or hides the "Edit with Clipchamp" entry that the Clipchamp app adds to the context menu of image and video files.'
        vi = 'Hiện hoặc ẩn mục "Edit with Clipchamp" mà ứng dụng Clipchamp thêm vào menu ngữ cảnh của tệp ảnh và video.'
    } `
    -Impact @{
        en = 'The entry is hidden through the shell-extension block list; the app stays installed and the entry only exists while it is. Both the per-user and the machine-wide block value are managed, so elevation is required. Restart Explorer if the menu does not change immediately.'
        vi = 'Mục này bị ẩn qua danh sách chặn tiện ích shell; ứng dụng vẫn được cài và mục chỉ tồn tại khi ứng dụng còn cài. Cả giá trị chặn theo người dùng lẫn toàn máy đều được quản lý nên cần quyền quản trị. Hãy khởi động lại Explorer nếu menu không đổi ngay.'
    } `
    -StateNames @('Shown', 'Hidden') -DefaultState 'Hidden' `
    -Scope 'UserAndMachine' -Privilege 'Admin' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
        Name = '{8AB635F8-9A67-4698-AB99-784AD929F3B4}'
        Map  = [ordered]@{
            Hidden = @('')
        }
    } `
    -States @{
        Shown = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'; Name = '{8AB635F8-9A67-4698-AB99-784AD929F3B4}' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'; Name = '{8AB635F8-9A67-4698-AB99-784AD929F3B4}' }
        )
        Hidden = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'; Name = '{8AB635F8-9A67-4698-AB99-784AD929F3B4}' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'; Name = '{8AB635F8-9A67-4698-AB99-784AD929F3B4}'; Type = 'String'; Value = '' }
        )
    }

New-WtRegistryTweak -Id 'Apps.EditWithPaintContext' -Category 'Apps' `
    -Name @{
        en = 'Edit with Paint context menu'
        vi = 'Menu ngữ cảnh Edit with Paint'
    } `
    -Description @{
        en = 'Shows or hides the "Edit with Paint" entry that the Paint app adds to the context menu of image files.'
        vi = 'Hiện hoặc ẩn mục "Edit with Paint" mà ứng dụng Paint thêm vào menu ngữ cảnh của tệp ảnh.'
    } `
    -Impact @{
        en = 'The entry is hidden through the shell-extension block list; the app stays installed and the entry only exists while it is. Both the per-user and the machine-wide block value are managed, so elevation is required. Restart Explorer if the menu does not change immediately.'
        vi = 'Mục này bị ẩn qua danh sách chặn tiện ích shell; ứng dụng vẫn được cài và mục chỉ tồn tại khi ứng dụng còn cài. Cả giá trị chặn theo người dùng lẫn toàn máy đều được quản lý nên cần quyền quản trị. Hãy khởi động lại Explorer nếu menu không đổi ngay.'
    } `
    -StateNames @('Shown', 'Hidden') -DefaultState 'Hidden' `
    -Scope 'UserAndMachine' -Privilege 'Admin' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
        Name = '{2430F218-B743-4FD6-97BF-5C76541B4AE9}'
        Map  = [ordered]@{
            Hidden = @('')
        }
    } `
    -States @{
        Shown = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'; Name = '{2430F218-B743-4FD6-97BF-5C76541B4AE9}' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'; Name = '{2430F218-B743-4FD6-97BF-5C76541B4AE9}' }
        )
        Hidden = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'; Name = '{2430F218-B743-4FD6-97BF-5C76541B4AE9}' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'; Name = '{2430F218-B743-4FD6-97BF-5C76541B4AE9}'; Type = 'String'; Value = '' }
        )
    }

New-WtRegistryTweak -Id 'Apps.EditWithPhotosContext' -Category 'Apps' `
    -Name @{
        en = 'Edit with Photos context menu'
        vi = 'Menu ngữ cảnh Edit with Photos'
    } `
    -Description @{
        en = 'Shows or hides the "Edit with Photos" entry that the Photos app adds to the context menu of image files.'
        vi = 'Hiện hoặc ẩn mục "Edit with Photos" mà ứng dụng Photos thêm vào menu ngữ cảnh của tệp ảnh.'
    } `
    -Impact @{
        en = 'The entry is hidden through the shell-extension block list; the app stays installed and the entry only exists while it is. Both the per-user and the machine-wide block value are managed, so elevation is required. Restart Explorer if the menu does not change immediately.'
        vi = 'Mục này bị ẩn qua danh sách chặn tiện ích shell; ứng dụng vẫn được cài và mục chỉ tồn tại khi ứng dụng còn cài. Cả giá trị chặn theo người dùng lẫn toàn máy đều được quản lý nên cần quyền quản trị. Hãy khởi động lại Explorer nếu menu không đổi ngay.'
    } `
    -StateNames @('Shown', 'Hidden') -DefaultState 'Hidden' `
    -Scope 'UserAndMachine' -Privilege 'Admin' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
        Name = '{BFE0E2A4-C70C-4AD7-AC3D-10D1ECEBB5B4}'
        Map  = [ordered]@{
            Hidden = @('')
        }
    } `
    -States @{
        Shown = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'; Name = '{BFE0E2A4-C70C-4AD7-AC3D-10D1ECEBB5B4}' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'; Name = '{BFE0E2A4-C70C-4AD7-AC3D-10D1ECEBB5B4}' }
        )
        Hidden = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'; Name = '{BFE0E2A4-C70C-4AD7-AC3D-10D1ECEBB5B4}' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'; Name = '{BFE0E2A4-C70C-4AD7-AC3D-10D1ECEBB5B4}'; Type = 'String'; Value = '' }
        )
    }

New-WtRegistryTweak -Id 'Apps.PrintCommandContext' -Category 'Apps' `
    -Name @{
        en = 'Print command for batch files'
        vi = 'Lệnh In cho tệp batch'
    } `
    -Description @{
        en = 'Shows or hides the Print verb that the context menu of .bat and .cmd files offers, by marking the verb as accessible to programs only.'
        vi = 'Hiện hoặc ẩn lệnh In trong menu ngữ cảnh của tệp .bat và .cmd bằng cách đánh dấu lệnh này chỉ dành cho truy cập theo chương trình.'
    } `
    -Impact @{
        en = 'The Print verb stays registered and remains available to applications; only the context menu entry is hidden. The registration is machine-wide, so elevation is required. Restart Explorer if the menu does not change immediately.'
        vi = 'Lệnh In vẫn được đăng ký và vẫn dùng được từ ứng dụng; chỉ mục trong menu ngữ cảnh bị ẩn. Đăng ký này áp dụng toàn máy nên cần quyền quản trị. Hãy khởi động lại Explorer nếu menu không đổi ngay.'
    } `
    -StateNames @('Shown', 'Hidden') -DefaultState 'Hidden' `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCR:\batfile\shell\print'
        Name = 'ProgrammaticAccessOnly'
        Map  = [ordered]@{
            Hidden = @('')
        }
    } `
    -States @{
        Shown = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKCR:\batfile\shell\print'; Name = 'ProgrammaticAccessOnly' }
            @{ Kind = 'RegistryRemove'; Path = 'HKCR:\cmdfile\shell\print'; Name = 'ProgrammaticAccessOnly' }
        )
        Hidden = @(
            # The presence of the value hides the verb; the data is not used.
            @{ Kind = 'RegistrySet'; Path = 'HKCR:\batfile\shell\print'; Name = 'ProgrammaticAccessOnly'; Type = 'String'; Value = '' }
            @{ Kind = 'RegistrySet'; Path = 'HKCR:\cmdfile\shell\print'; Name = 'ProgrammaticAccessOnly'; Type = 'String'; Value = '' }
        )
    }

New-WtRegistryTweak -Id 'Apps.MultipleInvokeContext' -Category 'Apps' `
    -Name @{
        en = 'Multi-select invoke limit'
        vi = 'Giới hạn khi chọn nhiều tệp'
    } `
    -Description @{
        en = 'Sets how many files Explorer passes to the Open, Print and Edit context menu commands at once (MultipleInvokePromptMinimum): the Windows default of 15 files or a raised limit of 300.'
        vi = 'Đặt số tệp Explorer chuyển cho các lệnh Mở, In và Chỉnh sửa trong menu ngữ cảnh cùng lúc (MultipleInvokePromptMinimum): mặc định 15 tệp của Windows hoặc tăng lên 300.'
    } `
    -Impact @{
        en = 'Raising the limit removes the confirmation Windows shows for a large selection and lets a command act on up to 300 files at once; this is a deliberate convenience trade-off, not a recommendation. The change takes effect after Explorer is restarted or you sign out.'
        vi = 'Tăng giới hạn sẽ bỏ bước xác nhận của Windows khi chọn nhiều tệp và cho phép một lệnh tác động tới 300 tệp cùng lúc; đây là đánh đổi tiện lợi có chủ ý, không phải khuyến nghị. Thay đổi có hiệu lực sau khi khởi động lại Explorer hoặc đăng xuất.'
    } `
    -StateNames @('Raised', 'Default') -DefaultState 'Default' `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
        Name = 'MultipleInvokePromptMinimum'
        Map  = [ordered]@{
            Raised  = @(300)
            Default = @(15)
        }
    } `
    -States @{
        Raised = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'MultipleInvokePromptMinimum'; Type = 'DWord'; Value = 300 }
        )
        Default = @(
            # Removing the value restores the built-in limit of 15 files.
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'MultipleInvokePromptMinimum' }
        )
    }

New-WtRegistryTweak -Id 'Apps.CabInstallContext' -Category 'Apps' `
    -Name @{
        en = 'Install command for CAB files'
        vi = 'Lệnh Cài đặt cho tệp CAB'
    } `
    -Description @{
        en = 'Adds or removes the elevated Install command in the context menu of .cab files, which installs the cabinet as a Windows package with DISM.'
        vi = 'Thêm hoặc xóa lệnh Cài đặt có nâng quyền trong menu ngữ cảnh của tệp .cab, lệnh này cài cabinet dưới dạng gói Windows bằng DISM.'
    } `
    -Impact @{
        en = 'The command runs DISM with elevation on the selected file and does not restart Windows by itself. The entry is only visible while .cab files are associated with the built-in CABFolder type, so it disappears if a third-party archiver owns that association. The registration is machine-wide.'
        vi = 'Lệnh chạy DISM với quyền quản trị trên tệp đã chọn và không tự khởi động lại Windows. Mục này chỉ hiện khi tệp .cab còn liên kết với kiểu CABFolder của Windows, nên sẽ mất nếu trình nén bên thứ ba giữ liên kết đó. Đăng ký này áp dụng toàn máy.'
    } `
    -StateNames @('Shown', 'Hidden') -DefaultState 'Shown' `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'Explorer' -Rollback 'Partial' -Risk 'Medium' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCR:\CABFolder\Shell\runas\Command'
        Name = '(default)'
        Map  = [ordered]@{
            Shown = @('cmd /c DISM.exe /Online /Add-Package /PackagePath:"%1" /NoRestart & pause')
        }
    } `
    -States @{
        Shown = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCR:\CABFolder\Shell\runas\Command'; Name = '(default)'; Type = 'String'; Value = 'cmd /c DISM.exe /Online /Add-Package /PackagePath:"%1" /NoRestart & pause' }
            @{ Kind = 'RegistrySet'; Path = 'HKCR:\CABFolder\Shell\runas'; Name = 'MUIVerb'; Type = 'String'; Value = '@shell32.dll,-10210' }
            @{ Kind = 'RegistrySet'; Path = 'HKCR:\CABFolder\Shell\runas'; Name = 'HasLUAShield'; Type = 'String'; Value = '' }
        )
        Hidden = @(
            @{ Kind = 'RegistryKeyRemove'; Path = 'HKCR:\CABFolder\Shell\runas'; Recurse = $true }
        )
    }

# The optional feature is serviced by DISM, which is not a registry, service or task
# change, so the framework cannot capture it: rollback is Partial and a manual
# "apply the other state" (or the Windows Features item) is the way back. The feature
# state is read before anything runs, so an already satisfied state reports "unchanged"
# instead of starting an unnecessary DISM run, and -WhatIf never starts DISM at all.
New-WtScriptTweak -Id 'Apps.WindowsSandbox' -Category 'Apps' `
    -Name @{
        en = 'Windows Sandbox'
        vi = 'Windows Sandbox'
    } `
    -Description @{
        en = 'Enables or disables the Windows Sandbox optional feature (Containers-DisposableClientVM) with DISM.'
        vi = 'Bật hoặc tắt tính năng tùy chọn Windows Sandbox (Containers-DisposableClientVM) bằng DISM.'
    } `
    -Impact @{
        en = 'Changing this feature requires a restart of Windows before it takes effect, and the DISM operation only runs with elevation. Windows Sandbox also needs a CPU with hardware virtualization (Intel VT-x or AMD-V) and is only available on Windows 10/11 Pro, Enterprise and Education. The feature change itself is not captured by the rollback store: roll back by applying the opposite state.'
        vi = 'Thay đổi tính năng này cần khởi động lại Windows mới có hiệu lực và thao tác DISM chỉ chạy khi có quyền quản trị. Windows Sandbox còn cần CPU hỗ trợ ảo hóa phần cứng (Intel VT-x hoặc AMD-V) và chỉ có trên Windows 10/11 Pro, Enterprise và Education. Bản thân thay đổi tính năng không được lưu để hoàn tác tự động: hãy hoàn tác bằng cách áp dụng trạng thái ngược lại.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Disabled' `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'Reboot' -Rollback 'Partial' -Risk 'Medium' `
    -SupportedOS @('Windows10', 'Windows11') -MinBuild 18362 `
    -Requires @('Cmdlet:Get-WindowsOptionalFeature') `
    -CapabilityLoss @(
        @{
            Capability = 'app.integration.sandbox'
            Names      = @{
                en = 'Windows Sandbox becomes unavailable (disabled) or appears (enabled)'
                vi = 'Windows Sandbox trở nên không khả dụng (tắt) hoặc xuất hiện (bật)'
            }
            Kind       = 'Guaranteed'
            Temporary  = $false
            RestoredBy = @{
                en = 'Apply the opposite state with the same tweak; the feature change itself is not captured by the rollback store, so this is the recovery path.'
                vi = 'Áp dụng trạng thái ngược lại bằng chính tinh chỉnh này; bản thân thay đổi tính năng không được lưu trong kho hoàn tác, nên đây là đường khôi phục.'
            }
            Limitations = @{
                en = 'A restart is required after the change, and Windows Sandbox additionally needs hardware virtualization and a supported edition; enabling it does not guarantee it can run.'
                vi = 'Cần khởi động lại sau khi thay đổi, và Windows Sandbox còn cần ảo hóa phần cứng cùng phiên bản Windows được hỗ trợ; bật không đảm bảo nó chạy được.'
            }
        }
    ) `
    -Detect {
        param ($Tweak, $Arguments)

        if (-not [bool]$IsWindows)
        {
            return @{ State = 'Unsupported'; Reason = 'The Windows Sandbox optional feature can only be managed on Windows.' }
        }

        if (-not (Get-Command -Name Get-WindowsOptionalFeature -ErrorAction Ignore))
        {
            return @{ State = 'Unsupported'; Reason = 'Get-WindowsOptionalFeature (DISM module) is not available in this session.' }
        }

        try
        {
            $Feature = Get-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM' -ErrorAction Stop
        }
        catch
        {
            return @{ State = 'Unsupported'; Reason = "The optional feature state could not be read (elevation and the DISM module are required): $($_.Exception.Message)" }
        }

        if ($null -eq $Feature)
        {
            return @{ State = 'Unsupported'; Reason = 'The Containers-DisposableClientVM feature is not present on this system (Windows Sandbox needs Windows 10/11 Pro, Enterprise or Education).' }
        }

        if ($Feature.State -eq 'Enabled')
        {
            return @{ State = 'Enabled'; Reason = "Feature state: $($Feature.State)" }
        }

        return @{ State = 'Disabled'; Reason = "Feature state: $($Feature.State)" }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        $Operation = 'WindowsOptionalFeature'
        $FeatureName = 'Containers-DisposableClientVM'

        if (-not [bool]$IsWindows)
        {
            return New-WtOperationResult -Status 'unsupported' -Operation $Operation -Target $FeatureName -Message 'The Windows Sandbox optional feature can only be changed on Windows.'
        }

        # Read-only pre-check: a state that is already satisfied must not trigger a
        # DISM run (and a dry run never reaches DISM at all).
        $CurrentState = $null
        if (Get-Command -Name Get-WindowsOptionalFeature -ErrorAction Ignore)
        {
            try
            {
                $Feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction Stop
                if ($Feature)
                {
                    $CurrentState = [string]$Feature.State
                }
            }
            catch
            {
                $CurrentState = $null
            }
        }

        if ($CurrentState -eq $State)
        {
            return New-WtOperationResult -Status 'unchanged' -Operation $Operation -Target $FeatureName -Message "Windows Sandbox is already $State; DISM was not started."
        }

        $SystemRoot = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
        $Dism = Join-Path -Path $SystemRoot -ChildPath 'System32\dism.exe'

        if ($State -eq 'Enabled')
        {
            return @(Invoke-WtProcess -FilePath $Dism -ArgumentList @('/Online', '/Enable-Feature', "/FeatureName:$FeatureName", '/All', '/NoRestart') -TimeoutSeconds 1800)
        }

        return @(Invoke-WtProcess -FilePath $Dism -ArgumentList @('/Online', '/Disable-Feature', "/FeatureName:$FeatureName", '/NoRestart') -TimeoutSeconds 1800)
    }
