# WindowsTweaker - Security category tweaks.
#
# Security policy for this project:
#   * no tweak here is applied at startup or by any preset,
#   * protection-reducing tweaks are flagged with -ReducesProtection and carry
#     -Risk High plus an impact text that states the concrete effect,
#   * enabling protection is the recommended direction and is never hidden.
#
# This file replaces the legacy behaviour where modules/InitialActions.ps1 silently
# ran "Set-MpPreference -EnableControlledFolderAccess Disabled" while initialising.

New-WtScriptTweak -Id 'Security.ControlledFolderAccess' -Category 'Security' `
    -Name @{
        en = 'Controlled folder access (ransomware protection)'
        vi = 'Truy cập thư mục được kiểm soát (chống mã hóa tống tiền)'
    } `
    -Description @{
        en = 'Enable or disable the Defender Controlled Folder Access feature, which blocks unauthorized apps from changing files in protected folders.'
        vi = 'Bật hoặc tắt tính năng Controlled Folder Access của Defender, tính năng chặn ứng dụng không được phép thay đổi tệp trong các thư mục được bảo vệ.'
    } `
    -Impact @{
        en = 'Disabling removes ransomware protection for Documents, Pictures, Desktop and other protected folders. Enabling may block legitimate applications until they are allowed in Windows Security.'
        vi = 'Tắt sẽ mất khả năng chống mã hóa tống tiền cho Documents, Pictures, Desktop và các thư mục được bảo vệ khác. Bật có thể chặn ứng dụng hợp pháp cho tới khi được cho phép trong Windows Security.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'High' `
    -Requires @('Cmdlet:Get-MpPreference') `
    -ReducesProtection `
    -Detect {
        param ($Tweak, $Arguments)

        $Preference = Get-WtMpPreferenceState -Name 'EnableControlledFolderAccess'
        if (-not $Preference.Available)
        {
            return @{ State = 'Unsupported'; Reason = 'Defender preferences are not readable on this system.' }
        }

        switch ([int]$Preference.Value)
        {
            1 { return @{ State = 'Enabled'; Reason = 'Controlled Folder Access is enabled.' } }
            2 { return @{ State = 'Enabled'; Reason = 'Controlled Folder Access is in audit-only mode.' } }
            0 { return @{ State = 'Disabled'; Reason = 'Controlled Folder Access is disabled.' } }
            default { return @{ State = 'Unknown'; Reason = "Unexpected value: $($Preference.Value)" } }
        }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        if ($State -eq 'Enabled')
        {
            return Set-WtMpPreferenceState -Name 'EnableControlledFolderAccess' -Value 1 -Reason 'enable ransomware protection'
        }

        return Set-WtMpPreferenceState -Name 'EnableControlledFolderAccess' -Value 0 -Reason 'protection is being reduced'
    }

New-WtRegistryTweak -Id 'Security.SmartScreenApplications' -Category 'Security' `
    -Name @{
        en = 'SmartScreen for applications (Explorer)'
        vi = 'SmartScreen cho ứng dụng (Explorer)'
    } `
    -Description @{
        en = 'Controls whether Explorer checks downloaded and unknown applications with SmartScreen.'
        vi = 'Điều khiển việc Explorer kiểm tra ứng dụng tải về và chưa biết bằng SmartScreen.'
    } `
    -Impact @{
        en = 'Disabling removes the SmartScreen reputation check for downloaded executables. This is a protection-reducing change.'
        vi = 'Tắt sẽ bỏ kiểm tra danh tiếng SmartScreen cho tệp thực thi tải về. Đây là thay đổi làm giảm mức bảo vệ.'
    } `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'High' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -ReducesProtection `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
        Name = 'SmartScreenEnabled'
        Map  = [ordered]@{
            Enabled  = @('Warn', 'Block')
            Disabled = @('Off')
        }
    } `
    -DefaultState 'Enabled' `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'SmartScreenEnabled'; Type = 'String'; Value = 'Warn' }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'SmartScreenEnabled'; Type = 'String'; Value = 'Off' }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'EnableSmartScreen' }
    )

New-WtRegistryTweak -Id 'Security.PowerShellScriptBlockLogging' -Category 'Security' `
    -Name @{
        en = 'PowerShell script block logging'
        vi = 'Ghi log khối lệnh PowerShell'
    } `
    -Description @{
        en = 'Records PowerShell script block content in the PowerShell operational log.'
        vi = 'Ghi nội dung khối lệnh PowerShell vào log hoạt động của PowerShell.'
    } `
    -Impact @{
        en = 'Security logging is enabled, never disabled, by this tool. Enabling it increases the size of the PowerShell operational log.'
        vi = 'Công cụ này chỉ bật nhật ký bảo mật, không bao giờ tắt. Bật sẽ làm tăng kích thước log hoạt động của PowerShell.'
    } `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Detection @{
        Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging'
        Name = 'EnableScriptBlockLogging'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging'; Name = 'EnableScriptBlockLogging'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging'; Name = 'EnableScriptBlockLogging'; Type = 'DWord'; Value = 0 }
        )
    }
