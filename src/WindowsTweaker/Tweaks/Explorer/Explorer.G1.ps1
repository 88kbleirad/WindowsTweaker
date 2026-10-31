# WindowsTweaker - Explorer category tweaks (batch G1: general File Explorer options).
#
# Derived from Sophia Script for Windows (MIT, (c) 2023 farag2) modules (see
# THIRD-PARTY-NOTICES.md). The legacy modules contained LGPO policy transcripts
# ("Set-Policy -Type DELETE"); those are re-expressed here as explicit registry
# operations, because LGPO is not bundled and must not be downloaded.
#
# The legacy sources of this batch write to:
#   HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced
#   HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer
#   HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager
#   HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel
#   HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders
#
# See docs/migration-notes/Explorer.G1.md for the per-module outcome table.

New-WtRegistryTweak -Id 'Explorer.CheckBoxes' -Category 'Explorer' `
    -Name @{
        en = 'Item check boxes in File Explorer'
        vi = 'Hộp kiểm cho mục trong File Explorer'
    } `
    -Description @{
        en = 'Adds a check box next to every file and folder so several items can be selected without holding Ctrl.'
        vi = 'Thêm hộp kiểm bên cạnh mỗi tệp và thư mục để chọn được nhiều mục mà không cần giữ Ctrl.'
    } `
    -Impact @{
        en = 'Enabling adds a check box to every File Explorer window; selecting with Ctrl and Shift keeps working as before.'
        vi = 'Bật sẽ thêm hộp kiểm vào mọi cửa sổ File Explorer; cách chọn bằng Ctrl và Shift vẫn hoạt động như trước.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Disabled' `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Name = 'AutoCheckSelect'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'AutoCheckSelect'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'AutoCheckSelect'; Type = 'DWord'; Value = 0 }
        )
    }

New-WtRegistryTweak -Id 'Explorer.ThisPC' -Category 'Explorer' `
    -Name @{
        en = 'This PC icon on the desktop'
        vi = 'Biểu tượng This PC trên màn hình nền'
    } `
    -Description @{
        en = 'Shows or hides the This PC icon on the desktop (Desktop\HideDesktopIcons\NewStartPanel entry for the This PC namespace).'
        vi = 'Hiện hoặc ẩn biểu tượng This PC trên màn hình nền (mục Desktop\HideDesktopIcons\NewStartPanel của không gian tên This PC).'
    } `
    -Impact @{
        en = 'Hiding removes the value, which is the Windows default and leaves no This PC icon on the desktop; the Recycle Bin and other desktop icons are untouched.'
        vi = 'Ẩn sẽ xóa giá trị, đây là mặc định của Windows và không còn biểu tượng This PC trên màn hình nền; Thùng rác và các biểu tượng khác không bị ảnh hưởng.'
    } `
    -StateNames @('Shown', 'Hidden') -DefaultState 'Hidden' `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'
        Name = '{20D04FE0-3AEA-1069-A2D8-08002B30309D}'
        Map  = [ordered]@{
            Shown  = @(0)
            Hidden = @(1)
        }
    } `
    -States @{
        Shown = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'; Name = '{20D04FE0-3AEA-1069-A2D8-08002B30309D}'; Type = 'DWord'; Value = 0 }
        )
        Hidden = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'; Name = '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' }
        )
    }

New-WtRegistryTweak -Id 'Explorer.HiddenItems' -Category 'Explorer' `
    -Name @{
        en = 'Hidden items, folders and drives'
        vi = 'Mục, thư mục và ổ đĩa ẩn'
    } `
    -Description @{
        en = 'Controls whether files, folders and drives with the hidden attribute are listed in File Explorer.'
        vi = 'Điều khiển việc File Explorer có liệt kê các tệp, thư mục và ổ đĩa mang thuộc tính ẩn hay không.'
    } `
    -Impact @{
        en = 'Showing hidden items also shows protected operating system files as ordinary items; the files themselves are neither changed nor deleted.'
        vi = 'Hiện mục ẩn cũng hiện các tệp hệ thống được bảo vệ như mục thường; bản thân các tệp không bị thay đổi hay xóa.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Disabled' `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Name = 'Hidden'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(2)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Hidden'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Hidden'; Type = 'DWord'; Value = 2 }
        )
    }

New-WtRegistryTweak -Id 'Explorer.FileExtensions' -Category 'Explorer' `
    -Name @{
        en = 'File name extensions'
        vi = 'Phần mở rộng tên tệp'
    } `
    -Description @{
        en = 'Shows the file name extension (.txt, .exe, ...) of every file in File Explorer.'
        vi = 'Hiện phần mở rộng tên tệp (.txt, .exe, ...) của mọi tệp trong File Explorer.'
    } `
    -Impact @{
        en = 'Showing extensions changes how names are displayed, but the extension also becomes part of the editable name, so a rename that drops it changes the file type.'
        vi = 'Hiện phần mở rộng chỉ thay đổi cách hiển thị tên, nhưng phần mở rộng cũng trở thành một phần của tên có thể sửa, nên đổi tên mà bỏ mất nó sẽ thay đổi loại tệp.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Disabled' `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Name = 'HideFileExt'
        Map  = [ordered]@{
            Enabled  = @(0)
            Disabled = @(1)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'HideFileExt'; Type = 'DWord'; Value = 0 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'HideFileExt'; Type = 'DWord'; Value = 1 }
        )
    }

New-WtRegistryTweak -Id 'Explorer.MergeConflicts' -Category 'Explorer' `
    -Name @{
        en = 'Folder merge conflict dialog'
        vi = 'Hộp thoại xung đột khi gộp thư mục'
    } `
    -Description @{
        en = 'Controls the dialog that asks whether to replace, keep or skip conflicting files when two folders with the same name are combined.'
        vi = 'Điều khiển hộp thoại hỏi thay thế, giữ hay bỏ qua các tệp xung đột khi gộp hai thư mục cùng tên.'
    } `
    -Impact @{
        en = 'With the dialog disabled Windows applies its default choice (replace) without asking, so a folder merge or copy no longer stops for each conflict.'
        vi = 'Khi tắt hộp thoại, Windows tự áp dụng lựa chọn mặc định (thay thế) mà không hỏi, nên thao tác gộp hoặc sao chép thư mục không còn dừng lại ở từng xung đột.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Name = 'HideMergeConflicts'
        Map  = [ordered]@{
            Enabled  = @(0)
            Disabled = @(1)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'HideMergeConflicts'; Type = 'DWord'; Value = 0 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'HideMergeConflicts'; Type = 'DWord'; Value = 1 }
        )
    }

# LaunchTo: 1 = This PC, 2 = Quick access/Home, 3 = Downloads (undocumented value that
# Windows 11 accepts; it is not offered by the Folder Options dialog).

New-WtRegistryTweak -Id 'Explorer.FileExplorerCompactMode' -Category 'Explorer' `
    -Name @{
        en = 'Compact mode for File Explorer'
        vi = 'Chế độ thu gọn cho File Explorer'
    } `
    -Description @{
        en = 'Uses the compact (narrower) row spacing in File Explorer windows.'
        vi = 'Dùng khoảng cách dòng thu gọn (hẹp hơn) trong các cửa sổ File Explorer.'
    } `
    -Impact @{
        en = 'Enabling only changes the row spacing of Explorer lists; nothing is hidden and no file is affected.'
        vi = 'Bật chỉ thay đổi khoảng cách dòng trong danh sách của Explorer; không ẩn gì và không ảnh hưởng tệp nào.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Disabled' `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Name = 'UseCompactMode'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'UseCompactMode'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'UseCompactMode'; Type = 'DWord'; Value = 0 }
        )
    }

New-WtRegistryTweak -Id 'Explorer.OneDriveFileExplorerAd' -Category 'Explorer' `
    -Name @{
        en = 'OneDrive and Office sync notifications in File Explorer'
        vi = 'Thông báo đồng bộ OneDrive và Office trong File Explorer'
    } `
    -Description @{
        en = 'Controls the OneDrive/Office sync provider notifications (the "Get more done with OneDrive" style banners) shown inside File Explorer.'
        vi = 'Điều khiển thông báo của nhà cung cấp đồng bộ OneDrive/Office (dạng băng-rôn "Làm được nhiều hơn với OneDrive") hiển thị trong File Explorer.'
    } `
    -Impact @{
        en = 'Disabling hides only that promotional banner; OneDrive keeps syncing and its status icons and context-menu entries are unaffected.'
        vi = 'Tắt chỉ ẩn băng-rôn quảng cáo đó; OneDrive vẫn đồng bộ, biểu tượng trạng thái và menu ngữ cảnh của nó không bị ảnh hưởng.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Name = 'ShowSyncProviderNotifications'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowSyncProviderNotifications'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowSyncProviderNotifications'; Type = 'DWord'; Value = 0 }
        )
    }

# The legacy module wrote SnapAssist = 1 for both of its switches (a copy/paste bug);
# upstream Sophia Script sets WindowArrangementActive = 1 unconditionally and
# SnapAssist = 0 for Disable. That is the behaviour restored here.
New-WtRegistryTweak -Id 'Explorer.SnapAssist' -Category 'Explorer' `
    -Name @{
        en = 'Snap Assist'
        vi = 'Hỗ trợ chia cửa sổ (Snap Assist)'
    } `
    -Description @{
        en = 'Controls Snap Assist, which suggests the remaining windows to fill the screen after another window is snapped.'
        vi = 'Điều khiển Snap Assist, tính năng gợi ý các cửa sổ còn lại để lấp phần màn hình trống sau khi một cửa sổ được chia.'
    } `
    -Impact @{
        en = 'Disabling only stops the window suggestions after snapping; snapping windows to the screen edges (Aero Snap) and the window arrangement setting stay enabled.'
        vi = 'Tắt chỉ ngừng việc gợi ý cửa sổ sau khi chia; tính năng kéo cửa sổ vào mép màn hình (Aero Snap) và cài đặt sắp xếp cửa sổ vẫn bật.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Name = 'SnapAssist'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Control Panel\Desktop'; Name = 'WindowArrangementActive'; Type = 'String'; Value = '1' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'SnapAssist'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Control Panel\Desktop'; Name = 'WindowArrangementActive'; Type = 'String'; Value = '1' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'SnapAssist'; Type = 'DWord'; Value = 0 }
        )
    }

New-WtRegistryTweak -Id 'Explorer.FileTransferDialog' -Category 'Explorer' `
    -Name @{
        en = 'File transfer dialog detail level'
        vi = 'Mức chi tiết của hộp thoại truyền tệp'
    } `
    -Description @{
        en = 'Chooses whether copy, move and delete dialogs open in the detailed (EnthusiastMode) or the compact view.'
        vi = 'Chọn hộp thoại sao chép, di chuyển và xóa mở ở dạng chi tiết (EnthusiastMode) hay dạng thu gọn.'
    } `
    -Impact @{
        en = 'Detailed shows the per-file list, transfer speed and graph; Compact shows only the progress bar. Only the dialog layout changes.'
        vi = 'Dạng chi tiết hiện danh sách từng tệp, tốc độ và biểu đồ; dạng thu gọn chỉ hiện thanh tiến trình. Chỉ bố cục hộp thoại thay đổi.'
    } `
    -StateNames @('Detailed', 'Compact') -DefaultState 'Compact' `
    -Scope 'User' -Privilege 'None' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager'
        Name = 'EnthusiastMode'
        Map  = [ordered]@{
            Detailed = @(1)
            Compact  = @(0)
        }
    } `
    -States @{
        Detailed = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager'; Name = 'EnthusiastMode'; Type = 'DWord'; Value = 1 }
        )
        Compact = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager'; Name = 'EnthusiastMode'; Type = 'DWord'; Value = 0 }
        )
    }

# The delete confirmation flag is bit 0x04 of byte 4 of the ShellState binary value.
# The legacy module hard-coded the whole flag byte (51/55), which silently resets the
# other folder-option bits stored in that byte; here the bit is changed in place.
New-WtScriptTweak -Id 'Explorer.RecycleBinDeleteConfirmation' -Category 'Explorer' `
    -Name @{
        en = 'Delete confirmation prompt'
        vi = 'Hỏi xác nhận khi xóa'
    } `
    -Description @{
        en = 'Controls whether Windows asks "Are you sure you want to move this file to the Recycle Bin?" before a delete.'
        vi = 'Điều khiển việc Windows hỏi "Bạn có chắc muốn chuyển tệp này vào Thùng rác?" trước khi xóa.'
    } `
    -Impact @{
        en = 'Disabling removes the safety prompt: files are moved to the Recycle Bin (or deleted permanently with Shift) immediately, so an accidental delete cannot be caught before it happens.'
        vi = 'Tắt sẽ bỏ bước xác nhận an toàn: tệp được chuyển vào Thùng rác (hoặc xóa vĩnh viễn khi giữ Shift) ngay lập tức, nên không còn cơ hội phát hiện thao tác xóa nhầm.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Scope 'UserAndMachine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Medium' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'ConfirmFileDelete' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'ConfirmFileDelete' }
    ) `
    -Detect {
        param ($Tweak, $Arguments)

        $Shell = Get-WtRegistryState -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer' -Name 'ShellState'
        if (-not $Shell.Available)
        {
            return @{ State = 'Unsupported'; Reason = 'The registry provider is not available on this platform.' }
        }

        if (-not $Shell.ValueExists)
        {
            return @{ State = 'Unknown'; Reason = 'ShellState is not present, so the delete confirmation flag cannot be read.' }
        }

        $Bytes = @($Shell.Value)
        if ($Bytes.Count -lt 5)
        {
            return @{ State = 'Unknown'; Reason = "ShellState is only $($Bytes.Count) byte(s) long; the delete confirmation flag (byte 4) is missing." }
        }

        $Flag = if (($Bytes[4] -band 0x04) -ne 0) { 'set' } else { 'clear' }
        $State = if ($Flag -eq 'set') { 'Disabled' } else { 'Enabled' }
        return @{ State = $State; Reason = "ShellState byte 4 = 0x$('{0:X2}' -f $Bytes[4]) (flag $Flag)." }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        $Results = @()

        # The user value only takes effect once the local and organization policies that
        # override it are gone (the legacy module deleted them through LGPO).
        foreach ($Path in @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
                'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
                'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'
                'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
            ))
        {
            $Results += Remove-WtRegistryValue -Path $Path -Name 'ConfirmFileDelete'
        }

        $Shell = Get-WtRegistryState -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer' -Name 'ShellState'
        if (-not $Shell.ValueExists)
        {
            $Results += New-WtOperationResult -Status 'failed' -Operation 'SetRegistry' -Target 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ShellState' -Message 'ShellState is not present, so the delete confirmation flag cannot be changed without inventing the rest of the value.'
            return $Results
        }

        # Work on a copy: the value that came back from the provider must not be
        # modified in place.
        $Raw = $Shell.Value
        if ($null -eq $Raw -or @($Raw).Count -lt 5)
        {
            $Length = if ($null -eq $Raw) { 0 } else { @($Raw).Count }
            $Results += New-WtOperationResult -Status 'failed' -Operation 'SetRegistry' -Target 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ShellState' -Message "ShellState is only $Length byte(s) long; byte 4 cannot be changed."
            return $Results
        }

        $Bytes = [byte[]]::new($Raw.Length)
        [void][Array]::Copy($Raw, $Bytes, $Bytes.Length)

        $Before = $Bytes[4]
        if ($State -eq 'Enabled')
        {
            # Clear bit 0x04: ask before deleting.
            $Bytes[4] = [byte]($Before -band 0xFB)
        }
        else
        {
            # Set bit 0x04: delete without asking.
            $Bytes[4] = [byte]($Before -bor 0x04)
        }

        if ($Bytes[4] -eq $Before)
        {
            $Results += New-WtOperationResult -Status 'unchanged' -Operation 'SetRegistry' -Target 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ShellState' -Message 'The delete confirmation flag is already in the requested state.'
            return $Results
        }

        $Results += Set-WtRegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer' -Name 'ShellState' -Kind 'Binary' -Value $Bytes
        return $Results
    }

# The policy value NoRecentDocsHistory (both "recently used files" and "frequently used
# folders") is removed in every state, exactly as the legacy modules did through LGPO:
# otherwise it silently overrides the user values written below.
New-WtRegistryTweak -Id 'Explorer.QuickAccessRecentFiles' -Category 'Explorer' `
    -Name @{
        en = 'Recently used files in Quick access'
        vi = 'Tệp dùng gần đây trong Truy cập nhanh'
    } `
    -Description @{
        en = 'Shows or hides the "Recent files" list that File Explorer keeps in Quick access / Home.'
        vi = 'Hiện hoặc ẩn danh sách "Tệp gần đây" mà File Explorer giữ trong Truy cập nhanh / Home.'
    } `
    -Impact @{
        en = 'Hiding clears the list from the File Explorer view and stops it from being repopulated; the jump lists and the personal recent-items list used by apps are separate and unaffected.'
        vi = 'Ẩn sẽ bỏ danh sách khỏi giao diện File Explorer và không cho nó được ghi thêm; danh sách nhảy (jump list) và danh sách mục gần đây riêng của ứng dụng vẫn hoạt động bình thường.'
    } `
    -StateNames @('Shown', 'Hidden') -DefaultState 'Shown' `
    -Scope 'UserAndMachine' -Privilege 'Admin' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'NoRecentDocsHistory' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoRecentDocsHistory' }
    ) `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
        Name = 'ShowRecent'
        Map  = [ordered]@{
            Shown  = @(1)
            Hidden = @(0)
        }
    } `
    -States @{
        Shown = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoRecentDocsHistory' }
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoRecentDocsHistory' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'NoRecentDocsHistory' }
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'NoRecentDocsHistory' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'ShowRecent'; Type = 'DWord'; Value = 1 }
        )
        Hidden = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoRecentDocsHistory' }
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoRecentDocsHistory' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'NoRecentDocsHistory' }
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'NoRecentDocsHistory' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'ShowRecent'; Type = 'DWord'; Value = 0 }
        )
    }

New-WtRegistryTweak -Id 'Explorer.QuickAccessFrequentFolders' -Category 'Explorer' `
    -Name @{
        en = 'Frequently used folders in Quick access'
        vi = 'Thư mục dùng thường xuyên trong Truy cập nhanh'
    } `
    -Description @{
        en = 'Shows or hides the "Frequent folders" list that File Explorer keeps in Quick access / Home.'
        vi = 'Hiện hoặc ẩn danh sách "Thư mục thường dùng" mà File Explorer giữ trong Truy cập nhanh / Home.'
    } `
    -Impact @{
        en = 'Hiding removes the list from the File Explorer view; pinned Quick access folders and the pinned Start menu tiles are unaffected.'
        vi = 'Ẩn sẽ bỏ danh sách khỏi giao diện File Explorer; các thư mục được ghim trong Truy cập nhanh và ghim trên Start không bị ảnh hưởng.'
    } `
    -StateNames @('Shown', 'Hidden') -DefaultState 'Shown' `
    -Scope 'UserAndMachine' -Privilege 'Admin' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'NoRecentDocsHistory' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoRecentDocsHistory' }
    ) `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
        Name = 'ShowFrequent'
        Map  = [ordered]@{
            Shown  = @(1)
            Hidden = @(0)
        }
    } `
    -States @{
        Shown = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoRecentDocsHistory' }
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoRecentDocsHistory' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'NoRecentDocsHistory' }
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'NoRecentDocsHistory' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'ShowFrequent'; Type = 'DWord'; Value = 1 }
        )
        Hidden = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoRecentDocsHistory' }
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoRecentDocsHistory' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'NoRecentDocsHistory' }
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'NoRecentDocsHistory' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'ShowFrequent'; Type = 'DWord'; Value = 0 }
        )
    }

New-WtRegistryTweak -Id 'Explorer.NavigationPaneExpand' -Category 'Explorer' `
    -Name @{
        en = 'Expand navigation pane to the current folder'
        vi = 'Mở rộng ngăn điều hướng tới thư mục hiện tại'
    } `
    -Description @{
        en = 'Keeps the navigation pane expanded to the folder that is open in File Explorer.'
        vi = 'Giữ ngăn điều hướng luôn mở rộng tới thư mục đang mở trong File Explorer.'
    } `
    -Impact @{
        en = 'With it disabled the navigation pane no longer follows the open folder; the folder tree itself and any manual expansion are unchanged.'
        vi = 'Khi tắt, ngăn điều hướng không còn đi theo thư mục đang mở; cây thư mục và việc mở rộng thủ công không thay đổi.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Name = 'NavPaneExpandToCurrentFolder'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'NavPaneExpandToCurrentFolder'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'NavPaneExpandToCurrentFolder'; Type = 'DWord'; Value = 0 }
        )
    }

New-WtRegistryTweak -Id 'Explorer.FoldersLaunchSeparateProcess' -Category 'Explorer' `
    -Name @{
        en = 'Open each folder in a separate process'
        vi = 'Mở mỗi thư mục trong một tiến trình riêng'
    } `
    -Description @{
        en = 'Runs every File Explorer window in its own explorer.exe process instead of one shared process.'
        vi = 'Chạy mỗi cửa sổ File Explorer trong tiến trình explorer.exe riêng thay vì dùng chung một tiến trình.'
    } `
    -Impact @{
        en = 'Enabling isolates windows so one hung folder cannot freeze the others, at the cost of more memory; it takes effect for windows opened after the change.'
        vi = 'Bật sẽ tách biệt các cửa sổ nên một thư mục bị treo không làm đơ các cửa sổ khác, đổi lại tốn nhiều bộ nhớ hơn; có hiệu lực với các cửa sổ mở sau khi thay đổi.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Disabled' `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Name = 'SeparateProcess'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'SeparateProcess'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'SeparateProcess'; Type = 'DWord'; Value = 0 }
        )
    }

# ShortcutNameTemplate "%s.lnk" makes new shortcuts use "<name>.lnk" instead of
# "<name> - Shortcut". The legacy "-Enable" branch pointed at the misspelled key
# "NamingTemplate" (singular), so it never removed the value; the correct key is used
# here.
New-WtRegistryTweak -Id 'Explorer.ShortcutsSuffix' -Category 'Explorer' `
    -Name @{
        en = 'Shortcut name suffix (" - Shortcut")'
        vi = 'Hậu tố tên lối tắt (" - Shortcut")'
    } `
    -Description @{
        en = 'Controls whether newly created shortcuts are named "<name> - Shortcut" (Windows default) or "<name>.lnk".'
        vi = 'Điều khiển việc lối tắt mới được đặt tên "<tên> - Shortcut" (mặc định Windows) hay "<tên>.lnk".'
    } `
    -Impact @{
        en = 'Disabling the suffix only changes the default name of shortcuts created afterwards; existing shortcuts keep their current names.'
        vi = 'Tắt hậu tố chỉ thay đổi tên mặc định của các lối tắt tạo về sau; lối tắt hiện có giữ nguyên tên.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Scope 'User' -Privilege 'None' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\NamingTemplates'
        Name = 'ShortcutNameTemplate'
        Map  = [ordered]@{
            Disabled = @('%s.lnk')
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'link' }
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\NamingTemplates'; Name = 'ShortcutNameTemplate' }
        )
        Disabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'link' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\NamingTemplates'; Name = 'ShortcutNameTemplate'; Type = 'String'; Value = '%s.lnk' }
        )
    }

# {B7BEDE81-DF94-4682-A7D8-57A52620B86F} is the Screenshots known folder. The legacy
# module copied whatever the Desktop user shell folder contained (and refused to run
# when OneDrive was signed in); the standard "%USERPROFILE%\Desktop" expansion of that
# folder is written here so the state is fixed and detectable.
New-WtRegistryTweak -Id 'Explorer.WinPrtScrFolder' -Category 'Explorer' `
    -Name @{
        en = 'Win+PrtScr screenshot folder'
        vi = 'Thư mục ảnh chụp Win+PrtScr'
    } `
    -Description @{
        en = 'Chooses where Win+PrtScr screenshots are saved: the Desktop folder or the default Pictures\Screenshots folder.'
        vi = 'Chọn nơi lưu ảnh chụp bằng Win+PrtScr: thư mục Desktop hoặc thư mục mặc định Pictures\Screenshots.'
    } `
    -Impact @{
        en = 'Desktop redirects only the Win+PrtScr screenshots to %USERPROFILE%\Desktop; Snipping Tool, the Print Screen key setting and existing screenshots are unaffected. A OneDrive-managed Desktop is not detected, so check that the path exists before applying.'
        vi = 'Desktop chỉ chuyển ảnh chụp Win+PrtScr tới %USERPROFILE%\Desktop; Snipping Tool, cài đặt phím Print Screen và ảnh đã chụp không bị ảnh hưởng. Thư mục Desktop do OneDrive quản lý không được phát hiện, nên hãy kiểm tra đường dẫn tồn tại trước khi áp dụng.'
    } `
    -StateNames @('Desktop', 'Default') -DefaultState 'Default' `
    -Scope 'User' -Privilege 'None' -Restart 'SignOut' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        Name = '{B7BEDE81-DF94-4682-A7D8-57A52620B86F}'
        Map  = [ordered]@{
            Desktop = @('%USERPROFILE%\Desktop')
        }
    } `
    -States @{
        Desktop = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'; Name = '{B7BEDE81-DF94-4682-A7D8-57A52620B86F}'; Type = 'ExpandString'; Value = '%USERPROFILE%\Desktop' }
        )
        Default = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'; Name = '{B7BEDE81-DF94-4682-A7D8-57A52620B86F}' }
        )
    }

# Current-user Explorer "Copy path" command. The verb is registered for the current user
# only (HKCU\Software\Classes), uses the application-owned verb name
# WindowsTweakerCopyPath, and its command line is the documented %W placeholder quoted
# with single quotes: %W is the full path Explorer supplies, and single quotes avoid any
# shell-level argument re-splitting of paths containing spaces. The registry operations
# are regular provider operations, so capture, verification and exact rollback are the
# same as for every other tweak. This is not a global hook, not an AutoHotkey script and
# not a startup entry.
New-WtScriptTweak -Id 'Explorer.CopyPathCommand' -Category 'Explorer' `
    -Name @{
        en = 'Explorer "Copy path" context-menu command (current user)'
        vi = 'Lệnh "Copy path" trong menu ngữ cảnh Explorer (người dùng hiện tại)'
    } `
    -Description @{
        en = 'Adds or removes a current-user Explorer context-menu item that copies the absolute path of the selected file or folder to the clipboard.'
        vi = 'Thêm hoặc gỡ mục menu ngữ cảnh Explorer của người dùng hiện tại để sao chép đường dẫn tuyệt đối của tệp hoặc thư mục đã chọn vào bảng tạm.'
    } `
    -Impact @{
        en = 'Enabled registers the verb "WindowsTweakerCopyPath" under HKCU\Software\Classes\Directory\shell and \*\shell. Disabled removes exactly those values; the captured previous state is restored verbatim on rollback. The command uses cmd.exe with the documented %W placeholder; paths with spaces are handled by single-quoting the placeholder. Nothing is installed globally and no startup entry is created.'
        vi = 'Bật đăng ký động từ "WindowsTweakerCopyPath" dưới HKCU\Software\Classes\Directory\shell và \*\shell. Tắt gỡ đúng các giá trị đó; trạng thái trước đó đã lưu được khôi phục nguyên vẹn khi hoàn tác. Lệnh dùng cmd.exe với trình giữ chỗ %W đã được ghi nhận; đường dẫn có khoảng trắng được xử lý bằng cách đặt %W trong dấu nháy đơn. Không cài đặt gì toàn cục và không tạo mục khởi động.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Disabled' `
    -Scope 'User' -Privilege 'None' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detect {
        param ($Tweak, $Arguments)

        $VerbPath = 'HKCU:\Software\Classes\Directory\shell\WindowsTweakerCopyPath\command'
        $TagPath = 'HKCU:\Software\Classes\*\shell\WindowsTweakerCopyPath\command'
        $Present = Test-Path -LiteralPath $VerbPath -and (Test-Path -LiteralPath $TagPath)
        if ($Present)
        {
            return @{ State = 'Enabled'; Reason = 'Both context-menu registrations are present.' }
        }
        return @{ State = 'Disabled'; Reason = 'No WindowsTweakerCopyPath registration is present.' }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        $Verb = 'HKCU:\Software\Classes\Directory\shell\WindowsTweakerCopyPath'
        $TagVerb = 'HKCU:\Software\Classes\*\shell\WindowsTweakerCopyPath'
        $Command = 'cmd.exe /d /c echo %W|clip'

        if ($State -eq 'Disabled')
        {
            $Results = @(
                (Remove-WtRegistryKey -Path $Verb -Recurse:$true)
                (Remove-WtRegistryKey -Path $TagVerb -Recurse:$true)
            )
            return $Results
        }

        $Results = @(
            (New-WtRegistryKey -Path $Verb)
            (Set-WtRegistryValue -Path $Verb -Name '(default)' -Value (Get-WtString -Key 'Tweaks.Explorer.CopyPath.Caption') -Kind 'String')
            (Set-WtRegistryValue -Path "$Verb\command" -Name '(default)' -Value $Command -Kind 'String')
            (New-WtRegistryKey -Path $TagVerb)
            (Set-WtRegistryValue -Path $TagVerb -Name '(default)' -Value (Get-WtString -Key 'Tweaks.Explorer.CopyPath.Caption') -Kind 'String')
            (Set-WtRegistryValue -Path "$TagVerb\command" -Name '(default)' -Value $Command -Kind 'String')
        )
        return $Results
    }
