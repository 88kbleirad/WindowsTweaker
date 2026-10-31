# WindowsTweaker - Privacy category tweaks (batch G3).
#
# Replaces the legacy modules modules/AppsSilentInstalling.ps1 and
# modules/PUAppsDetection.ps1. The legacy LGPO transcript ("Set-Policy ... -Type
# DELETE") is expressed as the equivalent RegistryRemove operation, because LGPO is
# not bundled and must not be downloaded.
#
# modules/AppsLanguageSwitch.ps1 is deliberately NOT ported: its only effect is the
# Windows-only Set-WinLanguageBarOption cmdlet, which has no provider, so porting it
# would bypass state capture, verification and dry run. See
# docs/migration-notes/Privacy.G3.md.

New-WtRegistryTweak -Id 'Privacy.SilentInstalledApps' -Category 'Privacy' `
    -Name @{
        en = 'Silent installation of suggested apps'
        vi = 'Cài đặt ngầm ứng dụng được gợi ý'
    } `
    -Description @{
        en = 'Controls whether Windows installs and updates suggested Microsoft Store apps in the background without asking.'
        vi = 'Điều khiển việc Windows tự cài đặt và cập nhật các ứng dụng Microsoft Store được gợi ý trong nền mà không hỏi bạn.'
    } `
    -Impact @{
        en = 'Enabled lets Windows install promoted Store apps silently. Disabled prevents those installs. Both states delete the machine policy value CloudContent\DisableWindowsConsumerFeatures, which would otherwise override this user setting, so the change needs administrator rights.'
        vi = 'Bật cho phép Windows cài đặt ngầm các ứng dụng Store được quảng bá. Tắt sẽ ngăn các cài đặt đó. Cả hai trạng thái đều xóa giá trị chính sách CloudContent\DisableWindowsConsumerFeatures trên toàn máy vì giá trị này sẽ ghi đè thiết lập người dùng, nên cần quyền quản trị.'
    } `
    -Scope 'UserAndMachine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        Name = 'SilentInstalledAppsEnabled'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -DefaultState 'Disabled' `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SilentInstalledAppsEnabled'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SilentInstalledAppsEnabled'; Type = 'DWord'; Value = 0 }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures' }
    )

New-WtScriptTweak -Id 'Privacy.PuaProtection' -Category 'Privacy' `
    -Name @{
        en = 'Potentially unwanted application (PUA) protection'
        vi = 'Bảo vệ chống ứng dụng không mong muốn (PUA)'
    } `
    -Description @{
        en = 'Sets the Microsoft Defender PUA protection level, which blocks adware, bundled toolbars and other potentially unwanted applications.'
        vi = 'Đặt mức bảo vệ PUA của Microsoft Defender, tính năng chặn phần mềm quảng cáo, thanh công cụ đi kèm và các ứng dụng không mong muốn khác.'
    } `
    -Impact @{
        en = 'Disabling stops Defender from blocking potentially unwanted applications, adware and bundled toolbars; this is a protection-reducing change. Enabling may block legitimate tools that Defender classifies as PUA.'
        vi = 'Tắt sẽ khiến Defender ngừng chặn các ứng dụng không mong muốn, phần mềm quảng cáo và thanh công cụ đi kèm; đây là thay đổi làm giảm mức bảo vệ. Bật có thể chặn các công cụ hợp pháp bị Defender xếp loại là PUA.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'High' `
    -Requires @('Cmdlet:Get-MpPreference') `
    -ReducesProtection `
    -Detect {
        param ($Tweak, $Arguments)

        $Preference = Get-WtMpPreferenceState -Name 'PUAProtection'
        if (-not $Preference.Available)
        {
            return @{ State = 'Unsupported'; Reason = 'Defender preferences are not readable on this system.' }
        }

        switch ([int]$Preference.Value)
        {
            1 { return @{ State = 'Enabled'; Reason = 'PUA protection is enabled.' } }
            2 { return @{ State = 'Enabled'; Reason = 'PUA protection is in audit-only mode.' } }
            0 { return @{ State = 'Disabled'; Reason = 'PUA protection is disabled.' } }
            default { return @{ State = 'Unknown'; Reason = "Unexpected value: $($Preference.Value)" } }
        }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        if ($State -eq 'Enabled')
        {
            return Set-WtMpPreferenceState -Name 'PUAProtection' -Value 1 -Reason 'enable potentially unwanted application protection'
        }

        return Set-WtMpPreferenceState -Name 'PUAProtection' -Value 0 -Reason 'protection is being reduced'
    }
