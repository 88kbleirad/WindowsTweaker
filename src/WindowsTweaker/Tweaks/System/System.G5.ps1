# WindowsTweaker - System category tweaks, batch G5.
#
# Converted from the legacy modules AdminApprovalMode, LocalSecurityAuthority,
# WindowsManageDefaultPrinter, BSoDStopError, Win32LongPathLimit, Hiberation,
# PowerPlan, StorageSense, ReservedStorage, NumLock and CapsLock. See
# docs/migration-notes/System.G5.md for the per-module outcome and for every value the
# legacy code wrote that is deliberately not ported.
#
# Conventions used here:
#   * DefaultState is the state the tweak exists to provide, or the state Windows ships
#     with when the tweak has no obvious "on" direction. No default state ever lowers
#     protection.
#   * Registry values are written through the providers, so every change captures the
#     exact previous state; the powercfg/DISM tweaks report -Rollback Partial because the
#     previous tool state is not captured by the state store.
#   * Legacy code that only existed to drive LGPO (Set-Policy -> DELETE) is expressed as
#     the equivalent registry removal when the value really can override the new setting,
#     and dropped when it pointed at the very same key the module already wrote.

#region Approval mode and LSA

# The legacy AdminApprovalMode module wrote eight UAC values at once (ConsentPromptBehaviorUser,
# EnableInstallerDetection, ValidateAdminCodeSignatures, EnableSecureUIAPaths, EnableLUA,
# PromptOnSecureDesktop, EnableVirtualization, EnableUIADesktopToggle) and then deleted the
# same names through LGPO, before setting ConsentPromptBehaviorAdmin to 0 ("Never") or 5
# ("Default"). Only the prompt level is a user-visible setting; the rest are either the
# Windows defaults (EnableLUA = 1, PromptOnSecureDesktop = 1) or outright weakenings
# (ValidateAdminCodeSignatures = 0). UAC itself is never disabled here.
New-WtRegistryTweak -Id 'System.UacPromptBehavior' -Category 'System' `
    -Name @{
        en = 'UAC prompt behaviour for administrators'
        vi = 'Mức nhắc nhở UAC cho quản trị viên'
    } `
    -Description @{
        en = 'Sets the User Account Control prompt shown when an administrator approves an elevation (ConsentPromptBehaviorAdmin).'
        vi = 'Đặt mức nhắc nhở của Kiểm soát tài khoản người dùng khi quản trị viên phê duyệt việc nâng quyền (giá trị ConsentPromptBehaviorAdmin).'
    } `
    -Impact @{
        en = 'NeverNotify makes Windows elevate administrators without any prompt, so malware can reach administrator rights silently; that state is therefore never the default. Prompt keeps the Windows default behaviour. UAC itself stays enabled: the legacy move that could turn it off entirely (EnableLUA) is not ported.'
        vi = 'NeverNotify khiến Windows nâng quyền quản trị mà không hỏi gì, nên phần mềm độc hại có thể chiếm quyền quản trị một cách âm thầm; vì vậy trạng thái này không bao giờ là mặc định. Trạng thái Prompt giữ nguyên hành vi mặc định của Windows. Bản thân UAC vẫn được bật: thao tác có thể tắt hẳn UAC (EnableLUA) không được chuyển đổi.'
    } `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'High' -ReducesProtection `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -StateNames @('Prompt', 'NeverNotify') -DefaultState 'Prompt' `
    -Detection @{
        Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        Name = 'ConsentPromptBehaviorAdmin'
        Map  = [ordered]@{
            Prompt      = @(5)
            NeverNotify = @(0)
        }
    } `
    -States @{
        Prompt      = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'ConsentPromptBehaviorAdmin'; Type = 'DWord'; Value = 5 }
        )
        NeverNotify = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'ConsentPromptBehaviorAdmin'; Type = 'DWord'; Value = 0 }
        )
    }

# The legacy LocalSecurityAuthority module wrote Lsa\RunAsPPL and Lsa\RunAsPPLBoot = 2 after
# probing firmware virtualization support. Value 2 means "enabled without a UEFI variable",
# which is the deliberate choice here too: a UEFI-locked configuration cannot be undone from
# the registry, and this catalog promises rollback for everything that is reversible. Value 2
# is only enforced from Windows 11 22H2 (build 22621), hence -MinBuild.
New-WtScriptTweak -Id 'System.LsaProtection' -Category 'System' `
    -Name @{
        en = 'Local Security Authority (LSA) protection'
        vi = 'Bảo vệ Local Security Authority (LSA)'
    } `
    -Description @{
        en = 'Runs LSASS as a protected process light by setting Lsa\RunAsPPL and Lsa\RunAsPPLBoot to 2 (enabled without a UEFI lock) and removes the LSA protection policy value that would override them.'
        vi = 'Chạy LSASS ở dạng protected process light bằng cách đặt Lsa\RunAsPPL và Lsa\RunAsPPLBoot thành 2 (bật nhưng không khóa bằng UEFI) và xóa giá trị policy bảo vệ LSA vốn có thể ghi đè hai giá trị này.'
    } `
    -Impact @{
        en = 'Enabled increases the protection of the credentials LSASS holds and takes effect after a reboot; unsigned or non-Microsoft LSA plug-ins can then fail to load. Disabled removes both values and turns LSA protection off, which lowers the protection of credentials in memory. A setting locked in UEFI firmware cannot be turned off from the registry.'
        vi = 'Bật sẽ tăng mức bảo vệ thông tin đăng nhập do LSASS nắm giữ và có hiệu lực sau khi khởi động lại; các plug-in LSA không được Microsoft ký có thể không tải được. Tắt sẽ xóa cả hai giá trị và tắt bảo vệ LSA, làm giảm mức bảo vệ thông tin đăng nhập trong bộ nhớ. Thiết lập đã bị khóa trong firmware UEFI thì không thể tắt từ registry.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Scope 'Machine' -Privilege 'Admin' -SupportedOS @('Windows11') -MinBuild 22621 `
    -Restart 'Reboot' -Rollback 'Full' -Risk 'High' -ReducesProtection `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'RunAsPPL' }
    ) `
    -Detect {
        param ($Tweak, $Arguments)

        $State = Get-WtRegistryState -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL'
        if (-not $State.Available)
        {
            return @{ State = 'Unsupported'; Reason = 'Registry provider unavailable.' }
        }

        if (-not $State.ValueExists)
        {
            return @{ State = 'Disabled'; Reason = 'RunAsPPL is not present under HKLM\SYSTEM\CurrentControlSet\Control\Lsa.' }
        }

        switch ([string]$State.Value)
        {
            '1' { return @{ State = 'Enabled'; Reason = 'RunAsPPL = 1 (LSA protection with UEFI lock).' } }
            '2' { return @{ State = 'Enabled'; Reason = 'RunAsPPL = 2 (LSA protection without UEFI lock).' } }
            '0' { return @{ State = 'Disabled'; Reason = 'RunAsPPL = 0, so LSA protection is off.' } }
            default { return @{ State = 'Unknown'; Reason = "Unrecognised RunAsPPL value '$($State.Value)'." } }
        }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        $Results = @()

        # The policy value wins over the direct one, so it is removed in both states; the
        # registry provider captures it and rollback restores it.
        $Results += Remove-WtRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'RunAsPPL'

        if ($State -eq 'Enabled')
        {
            $Results += Set-WtRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL' -Value 2 -Kind 'DWord'
            $Results += Set-WtRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPLBoot' -Value 2 -Kind 'DWord'
        }
        else
        {
            $Results += Remove-WtRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL'
            $Results += Remove-WtRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPLBoot'
        }

        return $Results
    }

#endregion Approval mode and LSA

#region Printer, crash screen, paths

New-WtRegistryTweak -Id 'System.DefaultPrinterManagement' -Category 'System' `
    -Name @{
        en = 'Let Windows manage the default printer'
        vi = 'Để Windows quản lý máy in mặc định'
    } `
    -Description @{
        en = 'Controls LegacyDefaultPrinterMode: when Windows manages the default printer it is the last printer that was used; when it does not, the printer you set stays the default.'
        vi = 'Điều khiển giá trị LegacyDefaultPrinterMode: khi Windows quản lý máy in mặc định thì máy in mặc định là máy in được dùng gần nhất; khi tắt, máy in bạn đặt sẽ được giữ làm mặc định.'
    } `
    -Impact @{
        en = 'Enabled keeps the Windows default behaviour (the default printer follows the last printer you used). Disabled stops Windows from switching the default printer, so your own choice is kept until you change it.'
        vi = 'Bật giữ hành vi mặc định của Windows (máy in mặc định thay đổi theo máy in bạn dùng gần nhất). Tắt sẽ ngăn Windows tự đổi máy in mặc định, nên lựa chọn của bạn được giữ cho đến khi bạn tự đổi.'
    } `
    -Scope 'User' -Privilege 'None' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows'
        Name = 'LegacyDefaultPrinterMode'
        Map  = [ordered]@{
            Enabled  = @(0)
            Disabled = @(1)
        }
    } `
    -States @{
        Enabled  = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows'; Name = 'LegacyDefaultPrinterMode'; Type = 'DWord'; Value = 0 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows'; Name = 'LegacyDefaultPrinterMode'; Type = 'DWord'; Value = 1 }
        )
    }

New-WtRegistryTweak -Id 'System.BSoDDisplayParameters' -Category 'System' `
    -Name @{
        en = 'Error parameters on the blue screen'
        vi = 'Tham số lỗi trên màn hình xanh'
    } `
    -Description @{
        en = 'Sets CrashControl\DisplayParameters so that a Stop error screen shows the bug check parameters, not just the stop code.'
        vi = 'Đặt giá trị CrashControl\DisplayParameters để màn hình lỗi dừng hiện các tham số bug check, không chỉ mã dừng.'
    } `
    -Impact @{
        en = 'Enabled shows the four bug check parameters, which helps diagnose a crash but is more technical to read. Disabled shows only the stop code, which is what Windows does out of the box.'
        vi = 'Bật sẽ hiện bốn tham số bug check, giúp chẩn đoán lỗi nhưng mang tính kỹ thuật hơn khi đọc. Tắt chỉ hiện mã dừng, đúng như mặc định của Windows.'
    } `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Detection @{
        Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
        Name = 'DisplayParameters'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled  = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'; Name = 'DisplayParameters'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'; Name = 'DisplayParameters'; Type = 'DWord'; Value = 0 }
        )
    }

# The legacy Win32LongPathLimit parameter names were inverted (its "Disable" wrote
# LongPathsEnabled = 1); the state names here describe the setting itself.
New-WtRegistryTweak -Id 'System.LongPathsEnabled' -Category 'System' `
    -Name @{
        en = 'Win32 long path support'
        vi = 'Hỗ trợ đường dẫn dài của Win32'
    } `
    -Description @{
        en = 'Sets FileSystem\LongPathsEnabled so processes can use paths longer than 260 characters without an application manifest.'
        vi = 'Đặt giá trị FileSystem\LongPathsEnabled để các tiến trình dùng được đường dẫn dài hơn 260 ký tự mà không cần manifest của ứng dụng.'
    } `
    -Impact @{
        en = 'Enabled lifts the 260-character Win32 path limit for every process; some older applications can misbehave with very long paths. Disabled enforces the limit again, which is the Windows default.'
        vi = 'Bật sẽ bỏ giới hạn 260 ký tự của Win32 cho mọi tiến trình; một số ứng dụng cũ có thể xử lý sai với đường dẫn rất dài. Tắt sẽ áp đặt lại giới hạn, đúng như mặc định của Windows.'
    } `
    -Scope 'Machine' -Privilege 'Admin' -MinBuild 14393 -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -CapabilityLoss @(
        @{
            Capability = 'app.integration.longpaths'
            Names      = @{
                en = 'Older applications can misbehave when they receive very long paths'
                vi = 'Các ứng dụng cũ có thể xử lý sai khi nhận đường dẫn rất dài'
            }
            Kind       = 'Conditional'
            Temporary  = $false
            Condition  = @{
                Explanation = @{
                    en = 'Only for applications that do not support long paths (they are not detected here, and absence of evidence is not evidence of absence).'
                    vi = 'Chỉ với ứng dụng không hỗ trợ đường dẫn dài (chúng không được phát hiện ở đây, và không có bằng chứng không đồng nghĩa là không tồn tại).'
                }
            }
            RestoredBy = @{
                en = 'Restore the Windows default (limit enforced) with the same tweak.'
                vi = 'Khôi phục mặc định của Windows (áp đặt giới hạn) bằng chính tinh chỉnh này.'
            }
        }
    ) `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Detection @{
        Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
        Name = 'LongPathsEnabled'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled  = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'; Name = 'LongPathsEnabled'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'; Name = 'LongPathsEnabled'; Type = 'DWord'; Value = 0 }
        )
    }

#endregion Printer, crash screen, paths

#region Power, storage

# The legacy Hiberation module ran "POWERCFG /HIBERNATE OFF|ON" directly. Detection reads the
# registry value powercfg maintains; the change itself goes through Invoke-WtProcess, which
# checks the exit code. powercfg deletes hiberfil.sys and disables Fast Startup on "off", so
# the change cannot be restored exactly by the state store: -Rollback Partial.
New-WtScriptTweak -Id 'System.Hibernation' -Category 'System' `
    -Name @{
        en = 'Hibernation'
        vi = 'Chế độ ngủ đông (hibernation)'
    } `
    -Description @{
        en = 'Turns hibernation on or off with powercfg /hibernate on|off, which also creates or deletes hiberfil.sys.'
        vi = 'Bật hoặc tắt chế độ ngủ đông bằng powercfg /hibernate on|off, đồng thời tạo hoặc xóa tệp hiberfil.sys.'
    } `
    -Impact @{
        en = 'Turning hibernation off deletes hiberfil.sys (freeing disk space comparable to a large part of the installed RAM), disables Fast Startup and hybrid sleep, and removes the Hibernate power option. Turning it back on recreates the file, but the Fast Startup preference is not restored automatically.'
        vi = 'Tắt ngủ đông sẽ xóa hiberfil.sys (giải phóng dung lượng đĩa xấp xỉ một phần lớn dung lượng RAM), tắt Fast Startup cùng hybrid sleep và làm tùy chọn Hibernate biến mất. Bật lại sẽ tạo lại tệp này, nhưng tùy chọn Fast Startup không được khôi phục tự động.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Partial' -Risk 'Medium' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -CapabilityLoss @(
        @{
            Capability = 'power.hibernation'
            Names      = @{
                en = 'Hibernation, Fast Startup and hybrid sleep stop working'
                vi = 'Ngủ đông, Fast Startup và hybrid sleep ngừng hoạt động'
            }
            Kind       = 'Guaranteed'
            Temporary  = $false
            RestoredBy = @{
                en = 'Re-enable Hibernation with the same tweak (powercfg /hibernate on recreates hiberfil.sys and the Hibernate power option).'
                vi = 'Bật lại chế độ ngủ đông bằng chính tinh chỉnh này (powercfg /hibernate on sẽ tạo lại hiberfil.sys và tùy chọn nguồn Hibernate).'
            }
            Limitations = @{
                en = 'The Fast Startup preference is not restored automatically; this tweak only controls hibernation itself.'
                vi = 'Tùy chọn Fast Startup không được khôi phục tự động; tinh chỉnh này chỉ điều khiển bản thân chế độ ngủ đông.'
            }
        }
    ) `
    -Detect {
        param ($Tweak, $Arguments)

        $State = Get-WtRegistryState -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name 'HibernateEnabled'
        if (-not $State.Available)
        {
            return @{ State = 'Unsupported'; Reason = 'Registry provider unavailable.' }
        }

        if (-not $State.ValueExists)
        {
            return @{ State = 'Unknown'; Reason = 'HibernateEnabled is not present under HKLM\SYSTEM\CurrentControlSet\Control\Power.' }
        }

        switch ([string]$State.Value)
        {
            '1' { return @{ State = 'Enabled'; Reason = 'HibernateEnabled = 1.' } }
            '0' { return @{ State = 'Disabled'; Reason = 'HibernateEnabled = 0.' } }
            default { return @{ State = 'Unknown'; Reason = "Unrecognised HibernateEnabled value '$($State.Value)'." } }
        }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        $PowerCfg = if ($env:SystemRoot) { Join-Path -Path $env:SystemRoot -ChildPath 'System32\powercfg.exe' } else { 'powercfg.exe' }
        $Argument = if ($State -eq 'Enabled') { 'on' } else { 'off' }

        return @(Invoke-WtProcess -FilePath $PowerCfg -ArgumentList @('/hibernate', $Argument))
    }

# The legacy PowerPlan module removed the ActivePowerScheme policy value and ran
# "POWERCFG /SETACTIVE SCHEME_MIN|SCHEME_BALANCED". The policy removal is captured by the
# registry provider; the previously active plan is not captured, so rollback is partial.
New-WtScriptTweak -Id 'System.PowerPlan' -Category 'System' `
    -Name @{
        en = 'Active power plan'
        vi = 'Gói nguồn đang dùng'
    } `
    -Description @{
        en = 'Switches the active power plan with powercfg /setactive and removes the ActivePowerScheme policy value that would otherwise override the choice.'
        vi = 'Chuyển gói nguồn đang dùng bằng powercfg /setactive và xóa giá trị policy ActivePowerScheme vốn có thể ghi đè lựa chọn này.'
    } `
    -Impact @{
        en = 'High performance keeps the processor at higher clocks, which uses more power and produces more heat (and shortens battery life on laptops); Balanced is the Windows default. The previously active plan is not captured, so rollback restores the policy value but not the plan that was active before.'
        vi = 'High performance giữ bộ xử lý ở xung nhịp cao hơn, tốn điện và tỏa nhiệt nhiều hơn (và làm pin laptop nhanh hết hơn); Balanced là mặc định của Windows. Gói nguồn trước đó không được ghi lại, nên khi hoàn tác chỉ khôi phục giá trị policy chứ không khôi phục gói nguồn đã dùng trước đó.'
    } `
    -StateNames @('Balanced', 'HighPerformance') -DefaultState 'Balanced' `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Partial' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings'; Name = 'ActivePowerScheme' }
    ) `
    -Detect {
        param ($Tweak, $Arguments)

        $State = Get-WtRegistryState -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -Name 'ActivePowerScheme'
        if (-not $State.Available)
        {
            return @{ State = 'Unsupported'; Reason = 'Registry provider unavailable.' }
        }

        if (-not $State.ValueExists)
        {
            return @{ State = 'Unknown'; Reason = 'The active power plan is not recorded under HKLM\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes.' }
        }

        $Guid = ([string]$State.Value).Trim().ToLowerInvariant()

        switch ($Guid)
        {
            '381b4222-f694-41f0-9685-ff5bb260df2e' { return @{ State = 'Balanced'; Reason = 'Active plan is Balanced.' } }
            '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' { return @{ State = 'HighPerformance'; Reason = 'Active plan is High performance.' } }
            default { return @{ State = 'Unknown'; Reason = "Active plan '$Guid' is neither Balanced nor High performance." } }
        }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        $PowerCfg = if ($env:SystemRoot) { Join-Path -Path $env:SystemRoot -ChildPath 'System32\powercfg.exe' } else { 'powercfg.exe' }

        $Results = @()
        $Results += Remove-WtRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings' -Name 'ActivePowerScheme'

        $Alias = if ($State -eq 'HighPerformance') { 'SCHEME_MIN' } else { 'SCHEME_BALANCED' }
        $Results += Invoke-WtProcess -FilePath $PowerCfg -ArgumentList @('/setactive', $Alias)

        return $Results
    }

# The legacy StorageSense module wrote the StoragePolicy values 01 (Storage Sense),
# 04 (temporary files that apps are not using) and 2048 (how often Storage Sense runs, in
# days: 0 means "when Windows decides", 30 means monthly) and removed the
# AllowStorageSenseGlobal policy value.
New-WtRegistryTweak -Id 'System.StorageSense' -Category 'System' `
    -Name @{
        en = 'Storage Sense'
        vi = 'Storage Sense'
    } `
    -Description @{
        en = 'Turns Storage Sense on or off and sets its temporary-file cleanup and run cadence (values 01, 04 and 2048 of the StoragePolicy key).'
        vi = 'Bật hoặc tắt Storage Sense và đặt việc dọn tệp tạm cùng tần suất chạy (các giá trị 01, 04 và 2048 của khóa StoragePolicy).'
    } `
    -Impact @{
        en = 'Enabled lets Windows delete temporary files that applications are not using and runs Storage Sense about once a month. Disabled sets all three values to 0, so nothing is cleaned automatically any more. Nothing outside temporary files is deleted: the recycle bin and Downloads schedules stay off.'
        vi = 'Bật cho phép Windows xóa các tệp tạm mà ứng dụng không dùng và chạy Storage Sense khoảng một tháng một lần. Tắt sẽ đặt cả ba giá trị về 0, không còn tệp nào được dọn tự động. Không có dữ liệu nào ngoài tệp tạm bị xóa: lệnh dọn thùng rác và thư mục Downloads vẫn tắt.'
    } `
    -Scope 'UserAndMachine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Medium' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense'; Name = 'AllowStorageSenseGlobal' }
    ) `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
        Name = '01'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled  = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense'; Name = 'AllowStorageSenseGlobal' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'; Name = '01'; Type = 'DWord'; Value = 1 }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'; Name = '04'; Type = 'DWord'; Value = 1 }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'; Name = '2048'; Type = 'DWord'; Value = 30 }
        )
        Disabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense'; Name = 'AllowStorageSenseGlobal' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'; Name = '01'; Type = 'DWord'; Value = 0 }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'; Name = '04'; Type = 'DWord'; Value = 0 }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'; Name = '2048'; Type = 'DWord'; Value = 0 }
        )
    }

# The legacy ReservedStorage module called the DISM cmdlet Set-WindowsReservedStorageState.
# DISM is used through Invoke-WtProcess (exit code checked) instead of a cmdlet call, and the
# state is read from the registry value DISM maintains. DISM refuses the change while a
# servicing operation holds the reserved space; that refusal is reported as a failure.
New-WtScriptTweak -Id 'System.ReservedStorage' -Category 'System' `
    -Name @{
        en = 'Reserved storage'
        vi = 'Dung lượng dành riêng (reserved storage)'
    } `
    -Description @{
        en = 'Enables or disables the disk space Windows reserves for updates by running dism /Online /Set-ReservedStorageState.'
        vi = 'Bật hoặc tắt dung lượng đĩa mà Windows dành riêng cho cập nhật bằng lệnh dism /Online /Set-ReservedStorageState.'
    } `
    -Impact @{
        en = 'Disabled frees the reserved space (typically several GB) but makes it more likely that a feature update fails because of low disk space; the space is reclaimed after a reboot. Enabled restores the Windows default. The change is refused while reserved storage is in use by a servicing operation, and that refusal is reported.'
        vi = 'Tắt sẽ giải phóng dung lượng dành riêng (thường vài GB) nhưng làm bản cập nhật lớn dễ thất bại vì hết dung lượng; dung lượng được giải phóng sau khi khởi động lại. Bật sẽ trả về mặc định của Windows. Thay đổi sẽ bị từ chối khi dung lượng dành riêng đang được tác vụ servicing sử dụng, và việc từ chối đó được báo cáo rõ ràng.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Scope 'Machine' -Privilege 'Admin' -MinBuild 19041 -Restart 'None' -Rollback 'Partial' -Risk 'Medium' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detect {
        param ($Tweak, $Arguments)

        $State = Get-WtRegistryState -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' -Name 'ShippedWithReserves'
        if (-not $State.Available)
        {
            return @{ State = 'Unsupported'; Reason = 'Registry provider unavailable.' }
        }

        if (-not $State.ValueExists)
        {
            return @{ State = 'Unknown'; Reason = 'ShippedWithReserves is not present under HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager; check the state with dism /Online /Get-ReservedStorageState.' }
        }

        switch ([string]$State.Value)
        {
            '1' { return @{ State = 'Enabled'; Reason = 'ShippedWithReserves = 1.' } }
            '0' { return @{ State = 'Disabled'; Reason = 'ShippedWithReserves = 0.' } }
            default { return @{ State = 'Unknown'; Reason = "Unrecognised ShippedWithReserves value '$($State.Value)'." } }
        }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        $Dism = if ($env:SystemRoot) { Join-Path -Path $env:SystemRoot -ChildPath 'System32\dism.exe' } else { 'dism.exe' }
        $Desired = if ($State -eq 'Enabled') { 'Enabled' } else { 'Disabled' }

        return @(Invoke-WtProcess -FilePath $Dism -ArgumentList @('/Online', '/Set-ReservedStorageState', "/State:$Desired"))
    }

#endregion Power, storage

#region Keyboard

# The legacy NumLock module wrote InitialKeyboardIndicators into the default user profile
# (HKEY_USERS\.DEFAULT), which is the hive the sign-in screen reads.
New-WtRegistryTweak -Id 'System.NumLock' -Category 'System' `
    -Name @{
        en = 'NumLock at the sign-in screen'
        vi = 'NumLock ở màn hình đăng nhập'
    } `
    -Description @{
        en = 'Writes InitialKeyboardIndicators for the default user profile (HKU\.DEFAULT), which is the value the sign-in screen reads.'
        vi = 'Ghi giá trị InitialKeyboardIndicators cho hồ sơ người dùng mặc định (HKU\.DEFAULT), đây là giá trị màn hình đăng nhập đọc.'
    } `
    -Impact @{
        en = 'Enabled turns NumLock on before a session starts (2147483650); Disabled leaves it off (2147483648, the value a new installation carries). It applies to the sign-in screen and to profiles created afterwards, not to the profile of a user who is already signed in.'
        vi = 'Bật sẽ bật NumLock trước khi phiên làm việc bắt đầu (2147483650); tắt sẽ để NumLock tắt (2147483648, giá trị có trên bản cài mới). Thiết lập áp dụng cho màn hình đăng nhập và các hồ sơ tạo sau này, không áp dụng cho hồ sơ của người đang đăng nhập.'
    } `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'SignOut' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Detection @{
        Path = 'HKU:\.DEFAULT\Control Panel\Keyboard'
        Name = 'InitialKeyboardIndicators'
        Map  = [ordered]@{
            Enabled  = @('2147483650')
            Disabled = @('2147483648')
        }
    } `
    -States @{
        Enabled  = @(
            @{ Kind = 'RegistrySet'; Path = 'HKU:\.DEFAULT\Control Panel\Keyboard'; Name = 'InitialKeyboardIndicators'; Type = 'String'; Value = '2147483650' }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKU:\.DEFAULT\Control Panel\Keyboard'; Name = 'InitialKeyboardIndicators'; Type = 'String'; Value = '2147483648' }
        )
    }

# The legacy CapsLock module wrote the machine-wide Scancode Map that maps scancode 0x3A
# (Caps Lock) to nothing, and removed the value again for the normal behaviour. Detection has
# to cope with the value being absent (that is the Windows default and also the "Enabled"
# state), so this tweak is scripted.
New-WtScriptTweak -Id 'System.CapsLock' -Category 'System' `
    -Name @{
        en = 'Caps Lock key'
        vi = 'Phím Caps Lock'
    } `
    -Description @{
        en = 'Detaches the Caps Lock key with a machine-wide Scancode Map entry (scancode 0x3A mapped to nothing), or restores the normal key by removing that value.'
        vi = 'Tách phím Caps Lock bằng một mục Scancode Map toàn máy (mã quét 0x3A ánh xạ vào không), hoặc khôi phục phím bình thường bằng cách xóa giá trị đó.'
    } `
    -Impact @{
        en = 'Disabled makes the Caps Lock key do nothing and needs a reboot. Enabled restores normal uppercase behaviour. A Scancode Map that remaps other keys is never overwritten: detection reports Unknown and leaves that value alone.'
        vi = 'Disabled làm phím Caps Lock không làm gì cả và cần khởi động lại. Enabled khôi phục hành vi chữ hoa bình thường. Mục Scancode Map dùng để ánh xạ các phím khác không bao giờ bị ghi đè: phần phát hiện sẽ báo Unknown và giữ nguyên giá trị đó.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'Reboot' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detect {
        param ($Tweak, $Arguments)

        $State = Get-WtRegistryState -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout' -Name 'Scancode Map'
        if (-not $State.Available)
        {
            return @{ State = 'Unsupported'; Reason = 'Registry provider unavailable.' }
        }

        if (-not $State.ValueExists)
        {
            return @{ State = 'Enabled'; Reason = 'No Scancode Map is present, so every key behaves normally.' }
        }

        $CapsLockDetached = [byte[]](0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 58, 0, 0, 0, 0, 0)
        if (Test-WtValueEqual -Left $State.Value -Right $CapsLockDetached)
        {
            return @{ State = 'Disabled'; Reason = 'The Scancode Map that detaches Caps Lock is present.' }
        }

        $Bytes = @($State.Value)
        $MapsSomething = $false
        foreach ($Byte in $Bytes)
        {
            if ([int]$Byte -ne 0)
            {
                $MapsSomething = $true
                break
            }
        }

        if (-not $MapsSomething)
        {
            return @{ State = 'Enabled'; Reason = 'The Scancode Map is present but empty, so no key is remapped.' }
        }

        return @{ State = 'Unknown'; Reason = "A different Scancode Map is present ($($Bytes.Count) bytes); this tweak only manages the map that detaches Caps Lock." }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        if ($State -eq 'Enabled')
        {
            return @(Remove-WtRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout' -Name 'Scancode Map')
        }

        $CapsLockDetached = [byte[]](0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 58, 0, 0, 0, 0, 0)

        return @(Set-WtRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout' -Name 'Scancode Map' -Value $CapsLockDetached -Kind 'Binary')
    }

#endregion Keyboard
