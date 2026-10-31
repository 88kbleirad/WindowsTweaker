# WindowsTweaker - Security category tweaks, batch G4.
#
# Legacy modules converted here (per-module outcome in docs/migration-notes/Security.G4.md):
#   AppsSmartScreen, DismissSmartScreenFilter, DefenderSandbox, NetworkProtection,
#   SaveZoneInformation, PowerShellModulesLogging, EventViewerCustomView (registry part),
#   WindowsScriptHost. PowerShellScriptsLogging.ps1 is already covered by
#   Security/Security.ps1 (Security.PowerShellScriptBlockLogging) and Logging.ps1 was
#   dropped as a broken duplicate of the framework logging.
#
# Policy for this file (docs/MIGRATION-SPEC.md):
#   * nothing here runs at startup or as a preset; every change is explicit,
#   * every state that weakens a protection is flagged -ReducesProtection, carries
#     -Risk High and says in -Impact what concretely stops being checked,
#   * no tweak disables Microsoft Defender itself.

# From modules/AppsSmartScreen.ps1. The legacy module wrote the machine-wide Explorer
# value; the per-user counterpart already exists as Security.SmartScreenApplications.
New-WtRegistryTweak -Id 'Security.SmartScreenApplicationsMachine' -Category 'Security' `
    -Name @{
        en = 'SmartScreen for applications (machine-wide default)'
        vi = 'SmartScreen cho ứng dụng (giá trị mặc định toàn máy)'
    } `
    -Description @{
        en = 'Sets the machine-wide Explorer SmartScreenEnabled value that decides whether Explorer checks downloaded and unknown applications. It applies to accounts without their own per-user value; the per-user counterpart is Security.SmartScreenApplications.'
        vi = 'Đặt giá trị SmartScreenEnabled toàn máy của Explorer, quyết định việc Explorer kiểm tra ứng dụng tải về và chưa biết. Giá trị này áp dụng cho tài khoản không có giá trị riêng; giá trị theo người dùng là Security.SmartScreenApplications.'
    } `
    -Impact @{
        en = 'Disabling writes Off, so Explorer stops checking downloaded or unknown applications with SmartScreen and no "Windows protected your PC" warning appears before they run. This is a protection-reducing change and is never applied automatically. Enabling writes Warn, which restores the reputation check and its warning.'
        vi = 'Tắt sẽ ghi Off, Explorer ngừng kiểm tra ứng dụng tải về hoặc chưa biết bằng SmartScreen và không còn cảnh báo "Windows protected your PC" trước khi chạy. Đây là thay đổi làm giảm mức bảo vệ và không bao giờ được tự động áp dụng. Bật sẽ ghi Warn, khôi phục việc kiểm tra danh tiếng và cảnh báo.'
    } `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'Explorer' -Rollback 'Full' -Risk 'High' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -ReducesProtection `
    -DefaultState 'Enabled' `
    -Detection @{
        Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'
        Name = 'SmartScreenEnabled'
        Map  = [ordered]@{
            Enabled  = @('Warn', 'Block')
            Disabled = @('Off')
        }
    } `
    -States @{
        Enabled  = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'SmartScreenEnabled'; Type = 'String'; Value = 'Warn' }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'SmartScreenEnabled'; Type = 'String'; Value = 'Off' }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'EnableSmartScreen' }
    )

# From modules/DismissSmartScreenFilter.ps1. The legacy module wrote the suppression
# flag but offered no way back. The tweak is scripted because the protective state is
# the *absence* of the record, which the declarative detector cannot express (it reports
# a missing value as Unknown); -Detect below reads the value directly instead.
New-WtScriptTweak -Id 'Security.DismissSmartScreenFilter' -Category 'Security' `
    -Name @{
        en = 'SmartScreen status warning in Windows Security'
        vi = 'Cảnh báo trạng thái SmartScreen trong Windows Security'
    } `
    -Description @{
        en = 'Controls the Windows Security "App and browser control" record that reports SmartScreen as turned off. The Disabled state writes 0 into AppAndBrowser_EdgeSmartScreenOff so Windows Security stops reporting the condition; the Enabled state removes that record so Windows Security reports the real SmartScreen state again.'
        vi = 'Điều khiển bản ghi "App and browser control" trong Windows Security dùng để báo SmartScreen đang tắt. Trạng thái Disabled ghi 0 vào AppAndBrowser_EdgeSmartScreenOff để Windows Security ngừng báo tình trạng đó; trạng thái Enabled xóa bản ghi để Windows Security báo đúng trạng thái SmartScreen thật.'
    } `
    -Impact @{
        en = 'Dismissing suppresses the Windows Security warning that SmartScreen is off without changing SmartScreen itself, so if the filter really is disabled the user is no longer reminded and can leave it off. This is a protection-reducing change and is never applied automatically. The Enabled state restores Windows Security reporting.'
        vi = 'Việc ẩn cảnh báo sẽ bỏ thông báo SmartScreen đang tắt trong Windows Security mà không thay đổi SmartScreen, nên nếu bộ lọc thực sự bị tắt, người dùng sẽ không còn được nhắc và có thể để nguyên như vậy. Đây là thay đổi làm giảm mức bảo vệ và không bao giờ được tự động áp dụng. Trạng thái Enabled khôi phục việc báo cáo của Windows Security.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Scope 'User' -Privilege 'None' -Restart 'None' -Rollback 'Full' -Risk 'High' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -ReducesProtection `
    -Detect {
        param ($Tweak, $Arguments)

        $Path = 'HKCU:\Software\Microsoft\Windows Security Health\State'
        $Record = Get-WtRegistryState -Path $Path -Name 'AppAndBrowser_EdgeSmartScreenOff'

        if (-not $Record.Available)
        {
            return @{ State = 'Unsupported'; Reason = 'The registry provider is not available on this platform.' }
        }

        if (-not $Record.ValueExists)
        {
            return @{ State = 'Enabled'; Reason = 'No suppression record is present, so Windows Security reports the SmartScreen state itself.' }
        }

        if ([int]$Record.Value -eq 0)
        {
            return @{ State = 'Disabled'; Reason = 'Windows Security is told that SmartScreen is on, which suppresses the warning.' }
        }

        return @{ State = 'Enabled'; Reason = "The suppression record holds '$($Record.Value)', which does not suppress the warning." }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        $Path = 'HKCU:\Software\Microsoft\Windows Security Health\State'

        if ($State -eq 'Enabled')
        {
            # Removing the record lets the Windows Security Health service report the
            # real state instead of the value the legacy module hard-coded.
            return Remove-WtRegistryValue -Path $Path -Name 'AppAndBrowser_EdgeSmartScreenOff'
        }

        return Set-WtRegistryValue -Path $Path -Name 'AppAndBrowser_EdgeSmartScreenOff' -Value 0 -Kind 'DWord'
    }

# From modules/DefenderSandbox.ps1. The legacy module ran "setx.exe /M
# MP_FORCE_USE_SANDBOX <0|1>"; setx /M persists exactly this machine environment
# variable in the registry, so the write goes through the registry provider and keeps
# state capture, verification and rollback.
New-WtRegistryTweak -Id 'Security.DefenderSandbox' -Category 'Security' `
    -Name @{
        en = 'Microsoft Defender sandbox (MP_FORCE_USE_SANDBOX)'
        vi = 'Sandbox của Microsoft Defender (MP_FORCE_USE_SANDBOX)'
    } `
    -Description @{
        en = 'Sets the machine-wide MP_FORCE_USE_SANDBOX environment variable that Microsoft documents for running Defender content scanning in a low-privilege sandbox process (MsMpEngCP.exe). A restart of Windows is required before Defender picks the value up.'
        vi = 'Đặt biến môi trường toàn máy MP_FORCE_USE_SANDBOX theo tài liệu Microsoft để chạy quá trình quét nội dung của Defender trong tiến trình sandbox ít quyền (MsMpEngCP.exe). Cần khởi động lại Windows để Defender nhận giá trị mới.'
    } `
    -Impact @{
        en = 'Disabling (0) makes Defender fall back to in-process content scanning in the privileged MsMpEng.exe process, so a vulnerability in the scanning engine would run with SYSTEM rights - this is a protection-reducing change and is never applied automatically. Enabling (1) restores the sandbox. The value only takes effect after a restart; it does not disable Defender and no other Defender setting is touched.'
        vi = 'Tắt (0) khiến Defender quét nội dung ngay trong tiến trình đặc quyền MsMpEng.exe, nên lỗ hổng trong bộ máy quét có thể chạy với quyền SYSTEM - đây là thay đổi làm giảm mức bảo vệ và không bao giờ được tự động áp dụng. Bật (1) khôi phục sandbox. Giá trị chỉ có hiệu lực sau khi khởi động lại; thao tác này không tắt Defender và không đụng tới cấu hình Defender nào khác.'
    } `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'Reboot' -Rollback 'Full' -Risk 'High' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -ReducesProtection `
    -DefaultState 'Enabled' `
    -States @{
        Enabled  = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'; Name = 'MP_FORCE_USE_SANDBOX'; Type = 'String'; Value = '1' }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'; Name = 'MP_FORCE_USE_SANDBOX'; Type = 'String'; Value = '0' }
        )
    }

# From modules/NetworkProtection.ps1 ("Set-MpPreference -EnableNetworkProtection").
# The preference is stored by Defender itself, so it goes through the Defender
# provider (state captured, WhatIf aware, verified, rollback restores the previous
# value). Only the two modes the legacy module used are exposed; the audit-only mode
# is reported as Enabled because it still inspects traffic.
New-WtScriptTweak -Id 'Security.NetworkProtection' -Category 'Security' `
    -Name @{
        en = 'Network protection (Defender Exploit Guard)'
        vi = 'Bảo vệ mạng (Defender Exploit Guard)'
    } `
    -Description @{
        en = 'Sets the Microsoft Defender network protection preference. Block mode stops applications from connecting to malicious domains, IP addresses and phishing sites that Defender already knows about.'
        vi = 'Đặt tùy chọn bảo vệ mạng của Microsoft Defender. Chế độ chặn ngăn ứng dụng kết nối tới miền, địa chỉ IP độc hại và trang lừa đảo mà Defender đã biết.'
    } `
    -Impact @{
        en = 'Disabling turns network protection off, so Defender stops inspecting and blocking connections to known malicious domains and addresses - this is a protection-reducing change and is never applied automatically. Enabling turns it on in block mode. Defender itself, its real-time protection and its other features are untouched.'
        vi = 'Tắt sẽ ngừng bảo vệ mạng, Defender không còn kiểm tra và chặn các kết nối tới miền, địa chỉ độc hại đã biết - đây là thay đổi làm giảm mức bảo vệ và không bao giờ được tự động áp dụng. Bật sẽ chạy ở chế độ chặn. Bản thân Defender, bảo vệ thời gian thực và các tính năng khác không bị ảnh hưởng.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'High' `
    -Requires @('Cmdlet:Get-MpPreference') `
    -ReducesProtection `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Windows Defender Exploit Guard\Network Protection'; Name = 'EnableNetworkProtection' }
    ) `
    -Detect {
        param ($Tweak, $Arguments)

        $Preference = Get-WtMpPreferenceState -Name 'EnableNetworkProtection'
        if (-not $Preference.Available)
        {
            return @{ State = 'Unsupported'; Reason = 'The Defender module (Get-MpPreference) is not available on this system.' }
        }

        switch ([int]$Preference.Value)
        {
            1 { return @{ State = 'Enabled'; Reason = 'Network protection is enabled in block mode.' } }
            2 { return @{ State = 'Enabled'; Reason = 'Network protection is enabled in audit mode; network traffic is still inspected.' } }
            0 { return @{ State = 'Disabled'; Reason = 'Network protection is disabled.' } }
            default { return @{ State = 'Unknown'; Reason = "Unexpected EnableNetworkProtection value: $($Preference.Value)" } }
        }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        if ($State -eq 'Enabled')
        {
            return Set-WtMpPreferenceState -Name 'EnableNetworkProtection' -Value 1 -Reason 'enable network protection in block mode'
        }

        return Set-WtMpPreferenceState -Name 'EnableNetworkProtection' -Value 0 -Reason 'protection is being reduced'
    }

# From modules/SaveZoneInformation.ps1. The legacy module always deleted the machine
# policy value first and then wrote (or deleted) the per-user value; the Enabled state
# below writes 0 instead of deleting, which is the same "policy not enforced" outcome
# and keeps detection deterministic. The legacy module's New-Item against
# "CurrnetVersion" was a typo and only ever ran when the key was missing.
New-WtRegistryTweak -Id 'Security.SaveZoneInformation' -Category 'Security' `
    -Name @{
        en = 'Zone information in file attachments (Mark of the Web)'
        vi = 'Thông tin vùng cho tệp đính kèm (Mark of the Web)'
    } `
    -Description @{
        en = 'Controls the "Do not preserve zone information in file attachments" policy. When it is enforced, Windows does not keep the zone identifier on attachments saved from e-mail and downloads, so the files look locally created.'
        vi = 'Điều khiển chính sách "Do not preserve zone information in file attachments". Khi được áp dụng, Windows không giữ mã vùng trên tệp đính kèm lưu từ email và bản tải về, khiến tệp trông như được tạo tại máy.'
    } `
    -Impact @{
        en = 'Disabling stops saving the zone identifier, so attachments open without the Mark-of-the-Web checks (SmartScreen, Protected View and Office macro warnings) that depend on it - this is a protection-reducing change and is never applied automatically. Enabling restores saving the zone information. Only the attachment policy values are changed.'
        vi = 'Tắt sẽ ngừng lưu mã vùng, tệp đính kèm mở ra mà không còn các kiểm tra dựa trên Mark-of-the-Web (SmartScreen, Protected View, cảnh báo macro của Office) - đây là thay đổi làm giảm mức bảo vệ và không bao giờ được tự động áp dụng. Bật sẽ lưu lại thông tin vùng. Chỉ các giá trị chính sách tệp đính kèm bị thay đổi.'
    } `
    -Scope 'UserAndMachine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'High' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -ReducesProtection `
    -DefaultState 'Enabled' `
    -States @{
        Enabled  = @(
            # The machine policy value would otherwise override the per-user value below.
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments'; Name = 'SaveZoneInformation' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments'; Name = 'SaveZoneInformation'; Type = 'DWord'; Value = 0 }
        )
        Disabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments'; Name = 'SaveZoneInformation' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments'; Name = 'SaveZoneInformation'; Type = 'DWord'; Value = 1 }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments'; Name = 'SaveZoneInformation' }
    )

# From modules/PowerShellModulesLogging.ps1. The legacy module created
# "...\ModuleLogging\ModuleNames" (its Test-Path checked the misspelled "...\ModuleName",
# so the guard never worked) and set EnableModuleLogging plus the "*" rule.
New-WtRegistryTweak -Id 'Security.PowerShellModuleLogging' -Category 'Security' `
    -Name @{
        en = 'PowerShell module logging'
        vi = 'Ghi log module PowerShell'
    } `
    -Description @{
        en = 'Turns on PowerShell module logging and records every module in it ("*"), so the PowerShell operational log contains the pipeline details of the commands a module runs.'
        vi = 'Bật ghi log module của PowerShell cho mọi module ("*"), nhờ đó log hoạt động của PowerShell chứa chi tiết pipeline của các lệnh mà module thực thi.'
    } `
    -Impact @{
        en = 'Security logging is only ever enabled by this tool, never disabled silently. Enabling increases the size of the PowerShell operational log and can record command arguments that contain sensitive values; disabling writes 0 and removes the "*" rule.'
        vi = 'Công cụ này chỉ bật nhật ký bảo mật, không bao giờ tự ý tắt. Bật sẽ làm tăng kích thước log hoạt động của PowerShell và có thể ghi lại tham số lệnh chứa giá trị nhạy cảm; tắt sẽ ghi 0 và xóa quy tắc "*".'
    } `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -DefaultState 'Enabled' `
    -States @{
        Enabled  = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging'; Name = 'EnableModuleLogging'; Type = 'DWord'; Value = 1 }
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging\ModuleNames'; Name = '*'; Type = 'String'; Value = '*' }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging'; Name = 'EnableModuleLogging'; Type = 'DWord'; Value = 0 }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging\ModuleNames'; Name = '*' }
        )
    }

# From modules/EventViewerCustomView.ps1, registry part only: the value that makes
# security event 4688 carry the full command line. The module's other two actions
# (auditpol process-creation auditing and the process-creation.xml Event Viewer view)
# are not ported - see docs/migration-notes/Security.G4.md.
New-WtRegistryTweak -Id 'Security.ProcessCreationCommandLine' -Category 'Security' `
    -Name @{
        en = 'Include the command line in process creation events (4688)'
        vi = 'Ghi cả dòng lệnh vào sự kiện tạo tiến trình (4688)'
    } `
    -Description @{
        en = 'Sets ProcessCreationIncludeCmdLine_Enabled so that process creation events record the full command line of the process that was started.'
        vi = 'Đặt ProcessCreationIncludeCmdLine_Enabled để sự kiện tạo tiến trình ghi lại toàn bộ dòng lệnh của tiến trình được khởi chạy.'
    } `
    -Impact @{
        en = 'Event 4688 then contains the command line as well as the process name. Windows only writes event 4688 at all when process creation auditing is enabled (auditpol, or Advanced Audit Policy), which this tool does not change; the custom Event Viewer view the legacy module installed is not created either.'
        vi = 'Sự kiện 4688 sau đó chứa cả dòng lệnh lẫn tên tiến trình. Windows chỉ ghi sự kiện 4688 khi bật kiểm tra việc tạo tiến trình (auditpol hoặc Advanced Audit Policy) - điều mà công cụ này không thay đổi; view tùy chỉnh trong Event Viewer mà module cũ tạo cũng không được tạo.'
    } `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -DefaultState 'Enabled' `
    -States @{
        Enabled  = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit'; Name = 'ProcessCreationIncludeCmdLine_Enabled'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit'; Name = 'ProcessCreationIncludeCmdLine_Enabled'; Type = 'DWord'; Value = 0 }
        )
    }

# From modules/WindowsScriptHost.ps1. The legacy "Disable" branch wrote Enabled=0 and
# first looked at four scheduled tasks, but only printed a warning (the break left the
# pipeline and execution continued into the write), so that guard is not reproduced.
# The legacy "Enable" branch deleted the value; writing 1 is the same "allowed"
# outcome and keeps detection deterministic.
New-WtRegistryTweak -Id 'Security.WindowsScriptHost' -Category 'Security' `
    -Name @{
        en = 'Windows Script Host'
        vi = 'Windows Script Host'
    } `
    -Description @{
        en = 'Blocks (Disabled) or allows (Enabled) the Windows Script Host for the current user, which is what runs .vbs, .vbe, .js, .jse, .wsf and .wsh script files.'
        vi = 'Chặn (Disabled) hoặc cho phép (Enabled) Windows Script Host cho người dùng hiện tại, đây là thành phần chạy các tệp script .vbs, .vbe, .js, .jse, .wsf và .wsh.'
    } `
    -Impact @{
        en = 'Blocking stops scripts from running through Windows Script Host, which also removes a well-known malware execution path, but any legitimate logon script, installer or automation that uses .vbs/.js files stops working. Allowing restores the Windows default. The machine-wide value and cscript/wscript for other users are not changed.'
        vi = 'Chặn sẽ ngừng chạy script qua Windows Script Host, đồng thời loại bỏ một đường thực thi mã độc phổ biến, nhưng mọi script đăng nhập, trình cài đặt hay tự động hóa hợp lệ dùng tệp .vbs/.js sẽ ngừng hoạt động. Cho phép sẽ trở về mặc định của Windows. Giá trị toàn máy và cscript/wscript của người dùng khác không bị thay đổi.'
    } `
    -Scope 'User' -Privilege 'None' -Restart 'None' -Rollback 'Full' -Risk 'Medium' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -CapabilityLoss @(
        @{
            Capability = 'app.integration.scripting'
            Names      = @{
                en = 'Legitimate scripts (.vbs, .js, .wsf, ...) stop running'
                vi = 'Script hợp lệ (.vbs, .js, .wsf, ...) ngừng chạy'
            }
            Kind       = 'Conditional'
            Temporary  = $false
            Condition  = @{
                Explanation = @{
                    en = 'Applies when your logon scripts, installers or automation rely on Windows Script Host; those are not detected here, and the machine-wide setting and other users are not changed.'
                    vi = 'Áp dụng khi script đăng nhập, trình cài đặt hoặc tự động hóa của bạn dùng Windows Script Host; chúng không được phát hiện ở đây, và cài đặt toàn máy cùng người dùng khác không bị thay đổi.'
                }
            }
            RestoredBy = @{
                en = 'Set Windows Script Host back to Enabled with the same tweak (the Windows default).'
                vi = 'Đặt Windows Script Host trở lại Enabled bằng chính tinh chỉnh này (mặc định của Windows).'
            }
            Limitations = @{
                en = 'Rollback restores only this user settings value; scripts blocked by a machine-wide policy need that policy changed separately.'
                vi = 'Hoàn tác chỉ khôi phục giá trị cài đặt của người dùng này; script bị chặn bởi chính sách toàn máy cần thay đổi chính sách đó riêng.'
            }
        }
    ) `
    -DefaultState 'Disabled' `
    -States @{
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows Script Host\Settings'; Name = 'Enabled'; Type = 'DWord'; Value = 0 }
        )
        Enabled  = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows Script Host\Settings'; Name = 'Enabled'; Type = 'DWord'; Value = 1 }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows Script Host\Settings'; Name = 'Enabled' }
    )
