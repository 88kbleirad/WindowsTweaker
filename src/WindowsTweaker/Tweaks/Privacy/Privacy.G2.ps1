# WindowsTweaker - Privacy category tweaks, batch G2.
#
# Derived from Sophia Script for Windows (MIT, (c) 2023 farag2); the operations were
# re-expressed as explicit, reversible registry operations instead of LGPO policy
# transcripts (see THIRD-PARTY-NOTICES.md).
#
# Everything here is a suggestion/ad/content or diagnostic-data setting. Where a
# machine-wide policy would override the value the user is being given, the state
# that the policy contradicts removes it, so the requested value is the one that
# takes effect. Nothing in this file reduces protection; the only tweak that lowers
# privacy (Privacy.RecommendTroubleshooting) says so in its impact text.
#
# Three definitions of this batch - Privacy.DismissMSAccount, Privacy.LanguageListAccess
# and Privacy.WindowsTips - are declared in Data/Catalog/builtin.json instead, so the
# same definitions are available to the declarative catalog, the pack format and the
# inspector. They are registered from that document at module load and behave
# identically to the PowerShell definitions that were here before; tests/Catalog.Tests.ps1
# proves the equivalence. Nothing else about this batch changed.
#
# Per-batch conversion record: docs/migration-notes/Privacy.G2.md.

New-WtScriptTweak -Id 'Privacy.SigninInfo' -Category 'Privacy' `
    -Name @{
        en = 'Use my sign-in info to finish setting up after a restart'
        vi = 'Dùng thông tin đăng nhập của tôi để hoàn tất thiết lập sau khi khởi động lại'
    } `
    -Description @{
        en = 'Turns the per-account automatic restart sign-on opt-out (Winlogon\UserARSO\<SID>\OptOut) on or off, and clears the DisableAutomaticRestartSignOn policy that overrides it for every account.'
        vi = 'Bật hoặc tắt tùy chọn từ chối tự động đăng nhập lại (Winlogon\UserARSO\<SID>\OptOut) cho từng tài khoản, đồng thời xóa chính sách DisableAutomaticRestartSignOn vốn ghi đè tùy chọn này cho mọi tài khoản.'
    } `
    -Impact @{
        en = 'Disabling stops Windows from keeping the credentials it uses to sign the last user back in and lock the session after a restart or an update, so that user has to sign in again. It also clears the machine-wide policy that forces the behaviour for every account. Rollback restores both values as they were.'
        vi = 'Tắt sẽ khiến Windows ngừng giữ thông tin đăng nhập để tự đăng nhập lại người dùng cuối và khóa phiên sau khi khởi động lại hoặc cập nhật, nên người dùng đó phải đăng nhập lại. Công cụ cũng xóa chính sách cấp máy buộc hành vi này cho mọi tài khoản. Hoàn tác sẽ khôi phục cả hai giá trị như trước.'
    } `
    -StateNames @('Disabled', 'Enabled') -DefaultState 'Disabled' `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Windows', 'Cmdlet:Get-ItemProperty') `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'DisableAutomaticRestartSignOn' }
    ) `
    -Detect {
        param ($Tweak, $Arguments)

        # The per-account key carries the caller's SID, so this cannot be a declarative
        # operation list. Detection is read-only and never resolves the SID by writing.
        $Sid = Get-WtCurrentUserSid
        if (-not $Sid)
        {
            return @{ State = 'Unsupported'; Reason = 'The current account SID is not available on this system; the per-account ARSO key cannot be read.' }
        }

        $Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\UserARSO\$Sid"
        $State = Get-WtRegistryState -Path $Path -Name 'OptOut'

        if (-not $State.Available)
        {
            return @{ State = 'Unsupported'; Reason = 'Registry provider unavailable.' }
        }

        if (-not $State.ValueExists)
        {
            # No opt-out value means automatic restart sign-on is on, which is the
            # Windows default for this account; that is a documented fact, not a guess.
            return @{ State = 'Enabled'; Reason = "OptOut is not set under $Path, so automatic restart sign-on is on for this account (the Windows default)." }
        }

        switch ([int]$State.Value)
        {
            0 { return @{ State = 'Enabled'; Reason = 'OptOut is 0: automatic restart sign-on is on for this account.' } }
            1 { return @{ State = 'Disabled'; Reason = 'OptOut is 1: this account opts out of automatic restart sign-on.' } }
            default { return @{ State = 'Unknown'; Reason = "Unexpected OptOut value: $($State.Value)" } }
        }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        $Sid = Get-WtCurrentUserSid
        if (-not $Sid)
        {
            return New-WtOperationResult -Status 'unsupported' -Operation 'SigninInfo' -Target $Tweak.Id -Message 'The current account SID is not available on this system; nothing was changed.'
        }

        $Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\UserARSO\$Sid"
        $Policy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        $Results = @()

        if ($State -eq 'Disabled')
        {
            $Results += Set-WtRegistryValue -Path $Path -Name 'OptOut' -Value 1 -Kind 'DWord'
        }
        else
        {
            $Results += Remove-WtRegistryValue -Path $Path -Name 'OptOut'
        }

        # Both states clear the machine-wide policy: with it in place the per-account
        # value would have no effect at all.
        $Results += Remove-WtRegistryValue -Path $Policy -Name 'DisableAutomaticRestartSignOn'

        return @($Results)
    }

New-WtRegistryTweak -Id 'Privacy.WindowsWelcomeExperience' -Category 'Privacy' `
    -Name @{
        en = 'Windows welcome experience after updates'
        vi = 'Trải nghiệm chào mừng Windows sau khi cập nhật'
    } `
    -Description @{
        en = 'Shows or hides the post-update suggestions that highlight what is new in Windows (ContentDeliveryManager SubscribedContent-310093Enabled).'
        vi = 'Hiện hoặc ẩn các gợi ý sau khi cập nhật giới thiệu những điểm mới của Windows (ContentDeliveryManager SubscribedContent-310093Enabled).'
    } `
    -Impact @{
        en = 'Showing the content also removes the machine-wide DisableWindowsConsumerFeatures policy, which would otherwise force this content off for every user.'
        vi = 'Khi bật, công cụ cũng xóa chính sách DisableWindowsConsumerFeatures ở cấp máy, vì chính sách đó sẽ buộc tắt nội dung này cho mọi người dùng.'
    } `
    -Scope 'UserAndMachine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        Name = 'SubscribedContent-310093Enabled'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -DefaultState 'Disabled' `
    -States @{
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-310093Enabled'; Type = 'DWord'; Value = 0 }
        )
        Enabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-310093Enabled'; Type = 'DWord'; Value = 1 }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures' }
    )

New-WtRegistryTweak -Id 'Privacy.SettingsSuggestedContent' -Category 'Privacy' `
    -Name @{
        en = 'Suggested content in the Settings app'
        vi = 'Nội dung được gợi ý trong ứng dụng Cài đặt'
    } `
    -Description @{
        en = 'Shows or hides the suggestion entries the Settings app uses (ContentDeliveryManager SubscribedContent-338393Enabled, SubscribedContent-353694Enabled and SubscribedContent-353696Enabled).'
        vi = 'Hiện hoặc ẩn các mục gợi ý mà ứng dụng Cài đặt sử dụng (ContentDeliveryManager SubscribedContent-338393Enabled, SubscribedContent-353694Enabled và SubscribedContent-353696Enabled).'
    } `
    -Impact @{
        en = 'The three values are always changed together because Windows treats them as one Settings suggestion block. Showing the content also removes the machine-wide DisableWindowsConsumerFeatures policy.'
        vi = 'Ba giá trị luôn được thay đổi cùng nhau vì Windows coi chúng là một khối gợi ý trong Cài đặt. Khi bật, công cụ cũng xóa chính sách DisableWindowsConsumerFeatures ở cấp máy.'
    } `
    -Scope 'UserAndMachine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        Name = 'SubscribedContent-338393Enabled'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -DefaultState 'Disabled' `
    -States @{
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338393Enabled'; Type = 'DWord'; Value = 0 }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353694Enabled'; Type = 'DWord'; Value = 0 }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353696Enabled'; Type = 'DWord'; Value = 0 }
        )
        Enabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338393Enabled'; Type = 'DWord'; Value = 1 }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353694Enabled'; Type = 'DWord'; Value = 1 }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353696Enabled'; Type = 'DWord'; Value = 1 }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures' }
    )

New-WtRegistryTweak -Id 'Privacy.WhatsNewInWindows' -Category 'Privacy' `
    -Name @{
        en = 'Finish setting up your device prompts (SCOOBE)'
        vi = 'Lời nhắc "Hoàn tất thiết lập thiết bị" (SCOOBE)'
    } `
    -Description @{
        en = 'Shows or hides the full-screen "Let''s finish setting up your device" prompts that Windows shows after an update (UserProfileEngagement ScoobeSystemSettingEnabled).'
        vi = 'Hiện hoặc ẩn màn hình toàn phần "Hãy hoàn tất thiết lập thiết bị" mà Windows hiển thị sau khi cập nhật (UserProfileEngagement ScoobeSystemSettingEnabled).'
    } `
    -Impact @{
        en = 'The preference is per user and has no documented machine-wide policy. Disabling stops the prompt; the account, OneDrive and Edge sign-in states are not changed.'
        vi = 'Tùy chọn này theo từng người dùng và không có chính sách cấp máy nào được ghi nhận. Tắt sẽ dừng lời nhắc; trạng thái tài khoản, OneDrive và đăng nhập Edge không thay đổi.'
    } `
    -Scope 'User' -Privilege 'None' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'
        Name = 'ScoobeSystemSettingEnabled'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -DefaultState 'Disabled' `
    -States @{
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'; Name = 'ScoobeSystemSettingEnabled'; Type = 'DWord'; Value = 0 }
        )
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'; Name = 'ScoobeSystemSettingEnabled'; Type = 'DWord'; Value = 1 }
        )
    }

New-WtRegistryTweak -Id 'Privacy.BingSearch' -Category 'Privacy' `
    -Name @{
        en = 'Web results and suggestions in the search box'
        vi = 'Kết quả và gợi ý web trong ô tìm kiếm'
    } `
    -Description @{
        en = 'Sets the user policy that keeps web suggestions out of the Start and File Explorer search boxes (HKCU\Software\Policies\Microsoft\Windows\Explorer\DisableSearchBoxSuggestions).'
        vi = 'Đặt chính sách người dùng để loại gợi ý web khỏi ô tìm kiếm của Start và File Explorer (HKCU\Software\Policies\Microsoft\Windows\Explorer\DisableSearchBoxSuggestions).'
    } `
    -Impact @{
        en = 'Allowing suggestions removes both the user value and any machine-wide DisableSearchBoxSuggestions policy, which would otherwise keep web results off for every user. When suggestions are shown, what you type in the search box can be sent to Microsoft.'
        vi = 'Khi cho phép gợi ý, công cụ xóa cả giá trị người dùng và chính sách DisableSearchBoxSuggestions ở cấp máy, vì chính sách đó sẽ giữ kết quả web ở trạng thái tắt cho mọi người dùng. Khi gợi ý được bật, nội dung bạn nhập vào ô tìm kiếm có thể được gửi tới Microsoft.'
    } `
    -Scope 'UserAndMachine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
        Name = 'DisableSearchBoxSuggestions'
        Map  = [ordered]@{
            Disabled = @(1)
            Enabled  = @(0)
        }
    } `
    -DefaultState 'Disabled' `
    -States @{
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Type = 'DWord'; Value = 1 }
        )
        Enabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions' }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions' }
    )

New-WtRegistryTweak -Id 'Privacy.SearchHighlights' -Category 'Privacy' `
    -Name @{
        en = 'Search highlights'
        vi = 'Điểm nhấn tìm kiếm'
    } `
    -Description @{
        en = 'Shows or hides the search highlights (seasonal content, suggestions and greetings) in the Windows search box (SearchSettings IsDynamicSearchBoxEnabled).'
        vi = 'Hiện hoặc ẩn các điểm nhấn tìm kiếm (nội dung theo mùa, gợi ý và lời chào) trong ô tìm kiếm của Windows (SearchSettings IsDynamicSearchBoxEnabled).'
    } `
    -Impact @{
        en = 'Both states clear the machine-wide EnableDynamicContentInWSB policy, because that policy overrides the user value in either direction. Web results and the "web results" policy are a separate setting and are left alone.'
        vi = 'Cả hai trạng thái đều xóa chính sách EnableDynamicContentInWSB ở cấp máy, vì chính sách đó ghi đè giá trị người dùng theo cả hai hướng. Kết quả web và chính sách "kết quả web" là thiết lập riêng và không bị thay đổi.'
    } `
    -Scope 'UserAndMachine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings'
        Name = 'IsDynamicSearchBoxEnabled'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -DefaultState 'Disabled' `
    -States @{
        Disabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'EnableDynamicContentInWSB' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings'; Name = 'IsDynamicSearchBoxEnabled'; Type = 'DWord'; Value = 0 }
        )
        Enabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'EnableDynamicContentInWSB' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings'; Name = 'IsDynamicSearchBoxEnabled'; Type = 'DWord'; Value = 1 }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'EnableDynamicContentInWSB' }
    )

New-WtRegistryTweak -Id 'Privacy.StartRecommendedSection' -Category 'Privacy' `
    -Name @{
        en = 'Recommended section on Start'
        vi = 'Mục được đề xuất trên Start'
    } `
    -Description @{
        en = 'Hides or shows the Recommended section of the Start menu for the current user (user policy HideRecommendedSection).'
        vi = 'Ẩn hoặc hiện mục Được đề xuất của menu Start cho người dùng hiện tại (chính sách người dùng HideRecommendedSection).'
    } `
    -Impact @{
        en = 'Both states clear the machine-wide HideRecommendedSection policy and the MDM values (PolicyManager Education IsEducationEnvironment and Start HideRecommendedSection) that would otherwise decide for every user. Windows 11 only; Explorer restarts to apply.'
        vi = 'Cả hai trạng thái đều xóa chính sách HideRecommendedSection ở cấp máy và các giá trị MDM (PolicyManager Education IsEducationEnvironment và Start HideRecommendedSection) vì chúng sẽ quyết định thay cho mọi người dùng. Chỉ dành cho Windows 11; cần khởi động lại Explorer để áp dụng.'
    } `
    -Scope 'UserAndMachine' -Privilege 'Admin' -SupportedOS @('Windows11') -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
        Name = 'HideRecommendedSection'
        Map  = [ordered]@{
            Hidden = @(1)
            Shown  = @(0)
        }
    } `
    -DefaultState 'Hidden' `
    -States @{
        Hidden = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'HideRecommendedSection' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Education'; Name = 'IsEducationEnvironment' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'HideRecommendedSection' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'HideRecommendedSection'; Type = 'DWord'; Value = 1 }
        )
        Shown = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'HideRecommendedSection' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Education'; Name = 'IsEducationEnvironment' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'HideRecommendedSection' }
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'HideRecommendedSection' }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'HideRecommendedSection' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Education'; Name = 'IsEducationEnvironment' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'HideRecommendedSection' }
    )

New-WtRegistryTweak -Id 'Privacy.StartRecommendationsTips' -Category 'Privacy' `
    -Name @{
        en = 'Recommendations for tips, shortcuts and new apps on Start'
        vi = 'Đề xuất mẹo, phím tắt và ứng dụng mới trên Start'
    } `
    -Description @{
        en = 'Shows or hides the recommendation entries of the Recommended section (Explorer\Advanced Start_IrisRecommendations).'
        vi = 'Hiện hoặc ẩn các mục đề xuất của phần Được đề xuất (Explorer\Advanced Start_IrisRecommendations).'
    } `
    -Impact @{
        en = 'Hiding turns only these recommendation entries off; the Recommended section itself remains and can still list recent files and recently added apps.'
        vi = 'Ẩn chỉ tắt các mục đề xuất này; phần Được đề xuất vẫn còn và vẫn có thể liệt kê tệp gần đây và ứng dụng mới thêm.'
    } `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Name = 'Start_IrisRecommendations'
        Map  = [ordered]@{
            Disabled = @(0)
            Enabled  = @(1)
        }
    } `
    -DefaultState 'Disabled' `
    -States @{
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_IrisRecommendations'; Type = 'DWord'; Value = 0 }
        )
        Enabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_IrisRecommendations' }
        )
    }

New-WtRegistryTweak -Id 'Privacy.StartAccountNotifications' -Category 'Privacy' `
    -Name @{
        en = 'Microsoft account notifications on Start'
        vi = 'Thông báo tài khoản Microsoft trên Start'
    } `
    -Description @{
        en = 'Shows or hides the Microsoft account notification badges on the Start menu (Explorer\Advanced Start_AccountNotifications).'
        vi = 'Hiện hoặc ẩn huy hiệu thông báo tài khoản Microsoft trên menu Start (Explorer\Advanced Start_AccountNotifications).'
    } `
    -Impact @{
        en = 'Hiding suppresses the badges on Start only; account and sign-in notifications from Windows, OneDrive and Microsoft 365 apps are unchanged.'
        vi = 'Ẩn chỉ loại bỏ huy hiệu trên Start; thông báo tài khoản và đăng nhập từ Windows, OneDrive và ứng dụng Microsoft 365 không thay đổi.'
    } `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Name = 'Start_AccountNotifications'
        Map  = [ordered]@{
            Disabled = @(0)
            Enabled  = @(1)
        }
    } `
    -DefaultState 'Disabled' `
    -States @{
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_AccountNotifications'; Type = 'DWord'; Value = 0 }
        )
        Enabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_AccountNotifications' }
        )
    }

New-WtRegistryTweak -Id 'Privacy.RecommendTroubleshooting' -Category 'Privacy' `
    -Name @{
        en = 'Recommended troubleshooting'
        vi = 'Khắc phục sự cố được đề xuất'
    } `
    -Description @{
        en = 'Chooses how Windows applies Microsoft troubleshooting for known problems (Mitigation UserPreference) and restores what the feature needs: the diagnostic-data limits are cleared, Windows Error Reporting is turned back on, the QueueReporting scheduled task is enabled and the WerSvc service is set to Manual and started.'
        vi = 'Chọn cách Windows áp dụng tính năng khắc phục sự cố của Microsoft cho các vấn đề đã biết (Mitigation UserPreference) và khôi phục những gì tính năng này cần: các giới hạn dữ liệu chẩn đoán được xóa, Windows Error Reporting được bật lại, tác vụ theo lịch QueueReporting được bật và dịch vụ WerSvc được đặt thành Manual rồi khởi động.'
    } `
    -Impact @{
        en = 'This raises the diagnostic data Windows may send to the device maximum and turns Windows Error Reporting back on, so it undoes diagnostic-data and error-reporting restrictions applied earlier (for example by Privacy.DiagnosticDataLevel or Privacy.ErrorReporting). Automatically applies troubleshooting for critical and other problems and then notifies you; Default asks before a troubleshooter runs.'
        vi = 'Thao tác này nâng dữ liệu chẩn đoán mà Windows có thể gửi lên mức tối đa và bật lại Windows Error Reporting, nên nó hoàn tác các hạn chế về dữ liệu chẩn đoán và báo cáo lỗi đã áp dụng trước đó (ví dụ bởi Privacy.DiagnosticDataLevel hoặc Privacy.ErrorReporting). Tự động sẽ chạy khắc phục sự cố cho các vấn đề nghiêm trọng và vấn đề khác rồi thông báo; Mặc định sẽ hỏi trước khi chạy.'
    } `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Medium' `
    -Requires @('Cmdlet:Get-Service', 'Cmdlet:Get-ScheduledTask') `
    -Detection @{
        Path = 'HKLM:\SOFTWARE\Microsoft\WindowsMitigation'
        Name = 'UserPreference'
        Map  = [ordered]@{
            Default       = @(2)
            Automatically = @(3)
        }
    } `
    -DefaultState 'Default' `
    -States @{
        Default = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'; Name = 'MaxTelemetryAllowed' }
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack'; Name = 'ShowedToastAtLevel' }
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Windows Error Reporting'; Name = 'Disabled' }
            @{ Kind = 'ScheduledTask'; Path = '\Microsoft\Windows\Windows Error Reporting\'; Name = 'QueueReporting'; Enabled = $true }
            @{ Kind = 'Service'; Name = 'WerSvc'; StartupType = 'Manual'; Status = 'Running' }
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Microsoft\WindowsMitigation'; Name = 'UserPreference'; Type = 'DWord'; Value = 2 }
        )
        Automatically = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry' }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'; Name = 'MaxTelemetryAllowed' }
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack'; Name = 'ShowedToastAtLevel' }
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Windows Error Reporting'; Name = 'Disabled' }
            @{ Kind = 'ScheduledTask'; Path = '\Microsoft\Windows\Windows Error Reporting\'; Name = 'QueueReporting'; Enabled = $true }
            @{ Kind = 'Service'; Name = 'WerSvc'; StartupType = 'Manual'; Status = 'Running' }
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Microsoft\WindowsMitigation'; Name = 'UserPreference'; Type = 'DWord'; Value = 3 }
        )
    }
