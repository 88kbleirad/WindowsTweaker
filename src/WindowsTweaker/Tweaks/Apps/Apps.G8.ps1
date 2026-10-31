# WindowsTweaker - Apps batch G8: Windows optional features/capabilities, the Start
# menu layout and the OneDrive settings plus the official OneDrive uninstaller.
#
# Derived from Sophia Script for Windows (MIT, (c) 2023 farag2) where noted. The
# legacy WPF pickers, the OneDrive installer download and the recursive deletes that
# the legacy modules performed are deliberately not ported - see
# docs/migration-notes/Apps.G8.md for the per-module outcome and the reasons.
#
# Two contracts hold for the whole batch:
#   * a tweak that acts on named items (features, capabilities) selects nothing on
#     its own: its default state performs no change and applying a real state
#     without an explicit name fails instead of guessing,
#   * every change goes through the providers, so -WhatIf, state capture,
#     verification and per-operation logging keep working.

New-WtScriptTweak -Id 'Apps.WindowsFeature' -Category 'Apps' `
    -Name @{
        en = 'Windows optional features'
        vi = 'Tính năng tùy chọn của Windows'
    } `
    -Description @{
        en = 'Enables or disables exactly the Windows optional features named in -Arguments.FeatureName (e.g. MicrosoftWindowsPowerShellV2, Printing-XPSServices-Features, WorkFolders-Client). No feature is selected automatically.'
        vi = 'Bật hoặc tắt đúng các tính năng tùy chọn của Windows có tên trong -Arguments.FeatureName (ví dụ MicrosoftWindowsPowerShellV2, Printing-XPSServices-Features, WorkFolders-Client). Không tính năng nào được chọn tự động.'
    } `
    -Impact @{
        en = 'Only the named features are changed, through DISM with /NoRestart. Disabling a feature removes its files from this Windows installation and disabling the wrong component (PowerShell 2.0, Media/WMP, .NET 3.5, print components) can break software that depends on it; a restart is usually required before the change takes effect. Rollback re-enables or disables the features with the opposite state instead of restoring a captured snapshot, so the exact pre-existing feature set (including pending states) must be verified by the caller.'
        vi = 'Chỉ các tính năng được nêu tên bị thay đổi, thực hiện qua DISM với /NoRestart. Tắt một tính năng sẽ xóa tệp của nó khỏi bản Windows này và tắt sai thành phần (PowerShell 2.0, Media/WMP, .NET 3.5, thành phần in) có thể làm hỏng phần mềm phụ thuộc vào nó; thường cần khởi động lại để thay đổi có hiệu lực. Hoàn tác chỉ chạy lại trạng thái ngược lại chứ không khôi phục ảnh chụp trước đó, nên người gọi phải tự kiểm tra lại tập tính năng ban đầu (kể cả trạng thái đang chờ).'
    } `
    -StateNames @('None', 'Enabled', 'Disabled') -DefaultState 'None' `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'Reboot' -Rollback 'Partial' -Risk 'Medium' `
    -Requires @('Windows', 'Cmdlet:Get-WindowsOptionalFeature') `
    -Parameters @('FeatureName') `
    -Detect {
        param ($Tweak, $Arguments)

        $Requested = @($Arguments.FeatureName | Where-Object { $_ })
        if ($Requested.Count -eq 0)
        {
            return @{ State = 'None'; Reason = 'No optional feature was selected. Pass -Arguments @{ FeatureName = @(''<FeatureName>'') } to see or change a specific feature.' }
        }

        if (-not (Get-Command -Name Get-WindowsOptionalFeature -ErrorAction Ignore))
        {
            return @{ State = 'Unsupported'; Reason = 'Get-WindowsOptionalFeature is not available on this platform, so no feature can be inspected.' }
        }

        $Instances = @()
        $Unknown = @()
        $Features = @()

        foreach ($Name in $Requested)
        {
            $Feature = $null
            try
            {
                $Feature = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop
            }
            catch
            {
                $Feature = $null
            }

            if (-not $Feature)
            {
                $Unknown += $Name
                continue
            }

            $Features += $Feature
            $Instances += [pscustomobject]@{
                Id    = $Name
                Label = "$Name [$($Feature.State)]"
                State = [string]$Feature.State
            }
        }

        if ($Features.Count -eq 0)
        {
            return @{
                State     = 'Unknown'
                Instances = $Instances
                Reason    = "No Windows optional feature with this name exists on this system: $($Unknown -join ', ')."
            }
        }

        # The raw DISM state is reported per instance; the overall state is only
        # Enabled/Disabled when every inspected feature agrees, otherwise Mixed.
        $Distinct = @($Features | Select-Object -ExpandProperty State -Unique)
        $Overall = if ($Distinct.Count -eq 1 -and $Distinct[0] -in @('Enabled', 'Disabled')) { [string]$Distinct[0] } else { 'Mixed' }

        return @{
            State     = $Overall
            Instances = $Instances
            Reason    = ($Features | ForEach-Object { "$($_.FeatureName): $($_.State)" }) -join '; '
        }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        $Requested = @($Arguments.FeatureName | Where-Object { $_ })

        if ($State -eq 'None')
        {
            return New-WtOperationResult -Status 'skipped' -Operation 'WindowsOptionalFeature' -Target $Tweak.Id -Rollback 'Partial' -Message "$($Requested.Count) feature(s) were named but state None performs no change; pass -State Enabled or -State Disabled."
        }

        if ($Requested.Count -eq 0)
        {
            return New-WtOperationResult -Status 'failed' -Operation 'WindowsOptionalFeature' -Target $Tweak.Id -Rollback 'Partial' -Message "This tweak refuses to run without an explicit feature name: pass -Arguments @{ FeatureName = @('<FeatureName>') }; no feature was changed."
        }

        $Dism = Join-Path -Path $env:SystemRoot -ChildPath 'System32\dism.exe'
        $Results = @()

        foreach ($Name in $Requested)
        {
            $Feature = $null
            try
            {
                $Feature = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop
            }
            catch
            {
                $Feature = $null
            }

            if (-not $Feature)
            {
                $Results += New-WtOperationResult -Status 'failed' -Operation 'WindowsOptionalFeature' -Target $Name -Rollback 'Partial' -Message "Unknown Windows optional feature: $Name. The name is verified with Get-WindowsOptionalFeature before DISM is run, so nothing was changed."
                continue
            }

            if ($Feature.State -eq $State)
            {
                $Results += New-WtOperationResult -Status 'unchanged' -Operation 'WindowsOptionalFeature' -Target $Name -Rollback 'Partial' -Message "Feature $Name is already $State."
                continue
            }

            $DismArguments = if ($State -eq 'Enabled') { @('/Online', '/Enable-Feature', "/FeatureName:$Name", '/All', '/NoRestart') } else { @('/Online', '/Disable-Feature', "/FeatureName:$Name", '/NoRestart') }
            $Results += Invoke-WtProcess -FilePath $Dism -ArgumentList $DismArguments -TimeoutSeconds 3600
        }

        return $Results
    }

New-WtScriptTweak -Id 'Apps.WindowsCapability' -Category 'Apps' `
    -Name @{
        en = 'Windows capabilities (Features on Demand)'
        vi = 'Khả năng của Windows (Features on Demand)'
    } `
    -Description @{
        en = 'Installs or removes exactly the Windows capabilities named in -Arguments.CapabilityName (e.g. Browser.InternetExplorer~~~~0.0.1.0, Media.WindowsMediaPlayer~~~~0.0.1.0, App.StepsRecorder~~~~0.0.1.0). No capability is selected automatically.'
        vi = 'Cài hoặc gỡ đúng các khả năng của Windows có tên trong -Arguments.CapabilityName (ví dụ Browser.InternetExplorer~~~~0.0.1.0, Media.WindowsMediaPlayer~~~~0.0.1.0, App.StepsRecorder~~~~0.0.1.0). Không khả năng nào được chọn tự động.'
    } `
    -Impact @{
        en = 'Only the named capabilities are changed, through DISM. Installing a capability downloads the payload from Windows Update, so it needs network access; removing one uninstalls it from this Windows installation (Internet Explorer removal in particular is only complete after a restart). Rollback runs the opposite DISM command instead of restoring a captured snapshot.'
        vi = 'Chỉ các khả năng được nêu tên bị thay đổi, thực hiện qua DISM. Cài đặt cần tải gói từ Windows Update nên phải có mạng; gỡ bỏ sẽ xóa khả năng khỏi bản Windows này (đặc biệt Internet Explorer chỉ gỡ xong sau khi khởi động lại). Hoàn tác chạy lệnh DISM ngược lại chứ không khôi phục ảnh chụp trước đó.'
    } `
    -StateNames @('None', 'Enabled', 'Disabled') -DefaultState 'None' `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'Reboot' -Rollback 'Partial' -Risk 'Medium' `
    -Requires @('Windows', 'Cmdlet:Get-WindowsCapability') `
    -Parameters @('CapabilityName') `
    -Detect {
        param ($Tweak, $Arguments)

        $Requested = @($Arguments.CapabilityName | Where-Object { $_ })
        if ($Requested.Count -eq 0)
        {
            return @{ State = 'None'; Reason = 'No capability was selected. Pass -Arguments @{ CapabilityName = @(''<CapabilityName>'') } to see or change a specific capability.' }
        }

        if (-not (Get-Command -Name Get-WindowsCapability -ErrorAction Ignore))
        {
            return @{ State = 'Unsupported'; Reason = 'Get-WindowsCapability is not available on this platform, so no capability can be inspected.' }
        }

        $Instances = @()
        $Unknown = @()
        $Found = @()

        foreach ($Name in $Requested)
        {
            $Capability = $null
            try
            {
                $Capability = Get-WindowsCapability -Online -Name $Name -ErrorAction Stop
            }
            catch
            {
                $Capability = $null
            }

            if (-not $Capability)
            {
                $Unknown += $Name
                continue
            }

            $Found += $Capability
            $Instances += [pscustomobject]@{
                Id    = $Name
                Label = "$Name [$($Capability.State)]"
                State = [string]$Capability.State
            }
        }

        if ($Found.Count -eq 0)
        {
            return @{
                State     = 'Unknown'
                Instances = $Instances
                Reason    = "No Windows capability with this name exists on this system: $($Unknown -join ', '). Use the full capability name, including the version suffix."
            }
        }

        $Distinct = @($Found | Select-Object -ExpandProperty State -Unique)
        $Overall = if ($Distinct.Count -eq 1 -and $Distinct[0] -in @('Installed', 'NotPresent'))
        {
            if ($Distinct[0] -eq 'Installed') { 'Enabled' } else { 'Disabled' }
        }
        else
        {
            'Mixed'
        }

        return @{
            State     = $Overall
            Instances = $Instances
            Reason    = ($Found | ForEach-Object { "$($_.Name): $($_.State)" }) -join '; '
        }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        $Requested = @($Arguments.CapabilityName | Where-Object { $_ })

        if ($State -eq 'None')
        {
            return New-WtOperationResult -Status 'skipped' -Operation 'WindowsCapability' -Target $Tweak.Id -Rollback 'Partial' -Message "$($Requested.Count) capability(ies) were named but state None performs no change; pass -State Enabled or -State Disabled."
        }

        if ($Requested.Count -eq 0)
        {
            return New-WtOperationResult -Status 'failed' -Operation 'WindowsCapability' -Target $Tweak.Id -Rollback 'Partial' -Message "This tweak refuses to run without an explicit capability name: pass -Arguments @{ CapabilityName = @('<CapabilityName>') }; no capability was changed."
        }

        $Dism = Join-Path -Path $env:SystemRoot -ChildPath 'System32\dism.exe'
        $Results = @()

        foreach ($Name in $Requested)
        {
            $Capability = $null
            try
            {
                $Capability = Get-WindowsCapability -Online -Name $Name -ErrorAction Stop
            }
            catch
            {
                $Capability = $null
            }

            if (-not $Capability)
            {
                $Results += New-WtOperationResult -Status 'failed' -Operation 'WindowsCapability' -Target $Name -Rollback 'Partial' -Message "Unknown Windows capability: $Name. The name is verified with Get-WindowsCapability before DISM is run, so nothing was changed."
                continue
            }

            $TargetState = if ($State -eq 'Enabled') { 'Installed' } else { 'NotPresent' }
            if ($Capability.State -eq $TargetState)
            {
                $Results += New-WtOperationResult -Status 'unchanged' -Operation 'WindowsCapability' -Target $Name -Rollback 'Partial' -Message "Capability $Name is already $TargetState."
                continue
            }

            $DismArguments = if ($State -eq 'Enabled') { @('/Online', '/Add-Capability', "/CapabilityName:$Name") } else { @('/Online', '/Remove-Capability', "/CapabilityName:$Name") }
            $Results += Invoke-WtProcess -FilePath $Dism -ArgumentList $DismArguments -TimeoutSeconds 3600
        }

        return $Results
    }

# Registered under Apps because that is this batch's category; the setting itself is
# a Windows 11 Start menu layout. modules\StartLayout.ps1 is the only legacy module
# involved: it contains no JSON layout import/export, only these three values.
New-WtRegistryTweak -Id 'Apps.StartLayout' -Category 'Apps' `
    -Name @{
        en = 'Start menu layout'
        vi = 'Bố cục menu Start'
    } `
    -Description @{
        en = 'Chooses the Windows 11 Start menu layout: the default layout, more pins or more recommendations.'
        vi = 'Chọn bố cục menu Start của Windows 11: bố cục mặc định, nhiều ghim hơn hoặc nhiều đề xuất hơn.'
    } `
    -Impact @{
        en = 'Changing the layout resizes the pinned and recommended areas of the Start menu; pinned apps and files are kept. Explorer must be restarted before the new layout is drawn.'
        vi = 'Đổi bố cục sẽ thay đổi kích thước vùng ghim và vùng đề xuất của menu Start; các ứng dụng đã ghim vẫn được giữ. Cần khởi động lại Explorer để bố cục mới được vẽ.'
    } `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -SupportedOS @('Windows11') -MinBuild 22000 `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -StateNames @('Default', 'MorePins', 'MoreRecommendations') -DefaultState 'Default' `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Name = 'Start_Layout'
        Map  = [ordered]@{
            Default             = @(0)
            MorePins            = @(1)
            MoreRecommendations = @(2)
        }
    } `
    -States @{
        Default = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_Layout'; Type = 'DWord'; Value = 0 }
        )
        MorePins = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_Layout'; Type = 'DWord'; Value = 1 }
        )
        MoreRecommendations = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_Layout'; Type = 'DWord'; Value = 2 }
        )
    }

# modules\OneDrive.ps1 removed the DisableFileSyncNGSC policy on every run (its
# `Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\Windows\OneDrive`
# line), i.e. exactly the Enabled state below. The computer-scope LGPO path is
# relative to HKLM\SOFTWARE, so it maps onto the policy store key used here.
New-WtRegistryTweak -Id 'Apps.OneDriveFileSync' -Category 'Apps' `
    -Name @{
        en = 'OneDrive file sync'
        vi = 'Đồng bộ tệp OneDrive'
    } `
    -Description @{
        en = 'Controls the DisableFileSyncNGSC policy that blocks OneDrive file synchronization for this machine.'
        vi = 'Điều khiển chính sách DisableFileSyncNGSC dùng để chặn đồng bộ tệp OneDrive trên máy này.'
    } `
    -Impact @{
        en = 'Disabled writes the group policy value that stops OneDrive from syncing (OneDrive is not started and the sync engine is blocked); files already synced stay where they are. Enabled removes that policy value, which is what the legacy module did on every run. If an organization set this policy, WindowsTweaker reports it as managed before you change it.'
        vi = 'Trạng thái Disabled ghi giá trị chính sách nhóm khiến OneDrive ngừng đồng bộ (OneDrive không chạy và công cụ đồng bộ bị chặn); các tệp đã đồng bộ vẫn nằm nguyên chỗ cũ. Trạng thái Enabled xóa giá trị chính sách đó, đúng như module gốc làm mỗi lần chạy. Nếu tổ chức đã đặt chính sách này, WindowsTweaker sẽ báo là do chính sách quản lý trước khi bạn thay đổi.'
    } `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Medium' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -DefaultState 'Enabled' `
    -Detection @{
        Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'
        Name = 'DisableFileSyncNGSC'
        Map  = [ordered]@{
            Enabled  = @(0)
            Disabled = @(1)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'; Name = 'DisableFileSyncNGSC' }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'; Name = 'DisableFileSyncNGSC'; Type = 'DWord'; Value = 1 }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'; Name = 'DisableFileSyncNGSC' }
    )

# The File Explorer OneDrive notification setting (ShowSyncProviderNotifications) is
# owned by the Explorer category, not by this batch: it is registered once, as
# Explorer.OneDriveFileExplorerAd from modules\OneDriveFileExplorerAd.ps1. It is not
# repeated here, so the catalog keeps one tweak per user-visible setting.

# The autostart command line must contain the absolute path of the OneDrive binary,
# which is profile-specific, so this cannot be a static declarative value. The path is
# resolved and verified before anything is written.
New-WtScriptTweak -Id 'Apps.OneDriveAutostart' -Category 'Apps' `
    -Name @{
        en = 'OneDrive autostart at sign-in'
        vi = 'Tự khởi động OneDrive khi đăng nhập'
    } `
    -Description @{
        en = 'Adds or removes the per-user Run entry that starts OneDrive in the background at sign-in.'
        vi = 'Thêm hoặc xóa mục Run của người dùng để OneDrive tự chạy nền khi đăng nhập.'
    } `
    -Impact @{
        en = 'Disabled removes the Run entry, so OneDrive stops starting with Windows; the app, its settings and every file stay on disk and nothing is deleted. Enabled writes the entry again only after verifying that OneDrive.exe exists in your profile; if it is missing, nothing is written and the failure is reported.'
        vi = 'Trạng thái Disabled xóa mục Run nên OneDrive không còn tự chạy cùng Windows; ứng dụng, cài đặt và mọi tệp vẫn còn nguyên, không có gì bị xóa. Trạng thái Enabled chỉ ghi lại mục đó sau khi kiểm tra OneDrive.exe tồn tại trong hồ sơ của bạn; nếu không có, không ghi gì và báo lỗi rõ ràng.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Disabled' `
    -Scope 'User' -Privilege 'None' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detect {
        param ($Tweak, $Arguments)

        $Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $Entry = Get-WtRegistryState -Path $Path -Name 'OneDrive'
        if (-not $Entry.Available)
        {
            return @{ State = 'Unsupported'; Reason = 'The registry provider is not available on this platform.' }
        }

        $Executable = if ($env:LOCALAPPDATA) { Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft\OneDrive\OneDrive.exe' } else { $null }

        if ($Entry.ValueExists -and -not [string]::IsNullOrWhiteSpace([string]$Entry.Value))
        {
            return @{ State = 'Enabled'; Reason = "OneDrive starts at sign-in with: $($Entry.Value)" }
        }

        if (-not $Executable -or -not (Test-Path -LiteralPath $Executable))
        {
            return @{ State = 'Disabled'; Reason = "No autostart entry is present and $Executable was not found, so there is nothing to start." }
        }

        return @{ State = 'Disabled'; Reason = "No autostart entry is present; OneDrive is installed at $Executable, so state Enabled can recreate the entry." }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        $Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

        if ($State -eq 'Disabled')
        {
            return @(Remove-WtRegistryValue -Path $Path -Name 'OneDrive')
        }

        $Executable = if ($env:LOCALAPPDATA) { Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft\OneDrive\OneDrive.exe' } else { $null }
        if (-not $Executable -or -not (Test-Path -LiteralPath $Executable))
        {
            return New-WtOperationResult -Status 'failed' -Operation 'SetRegistry' -Target "$Path\OneDrive" -Message 'OneDrive.exe was not found in %LOCALAPPDATA%\Microsoft\OneDrive, so the autostart entry was not written (it would point at a missing file).' -ErrorRecord $null
        }

        return @(Set-WtRegistryValue -Path $Path -Name 'OneDrive' -Value ('"{0}" /background' -f $Executable) -Kind 'String')
    }

New-WtScriptTweak -Id 'Apps.OneDriveUninstall' -Category 'Apps' `
    -Name @{
        en = 'Uninstall OneDrive (official uninstaller)'
        vi = 'Gỡ cài đặt OneDrive (trình gỡ chính thức)'
    } `
    -Description @{
        en = 'Runs the OneDriveSetup.exe that is already installed on this machine (or the per-user copy in your profile) with /uninstall. It never downloads an installer and never deletes directories itself.'
        vi = 'Chạy OneDriveSetup.exe đã có sẵn trên máy này (hoặc bản trong hồ sơ người dùng) với tham số /uninstall. Không tải trình cài đặt và không tự xóa thư mục nào.'
    } `
    -Impact @{
        en = 'Irreversible: the OneDrive program, its shell extension and its service integration are removed for this user and reinstalling means running the OneDrive installer again. Your files are preserved: the uninstaller leaves the OneDrive folder and everything in it untouched, and this tweak never deletes files or directories itself. It is refused while a personal account is signed in, because the legacy module refused that case too. Explorer must be restarted for the change to take effect.'
        vi = 'Không thể hoàn tác: chương trình OneDrive, phần mở rộng shell và tích hợp dịch vụ bị gỡ cho người dùng này, muốn dùng lại phải cài OneDrive. Tệp của bạn được giữ nguyên: trình gỡ không xóa thư mục OneDrive và mọi thứ trong đó, và công cụ này không tự xóa tệp hay thư mục nào. Thao tác bị từ chối khi đang đăng nhập tài khoản cá nhân, đúng như module gốc. Cần khởi động lại Explorer để thay đổi có hiệu lực.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Disabled' `
    -Scope 'UserAndMachine' -Privilege 'Admin' -Restart 'Explorer' -Rollback 'None' -Risk 'High' -Irreversible `
    -Requires @('Windows') `
    -Detect {
        param ($Tweak, $Arguments)

        $Executable = if ($env:LOCALAPPDATA) { Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft\OneDrive\OneDrive.exe' } else { $null }
        if (-not $Executable -or -not (Test-Path -LiteralPath $Executable))
        {
            return @{ State = 'Disabled'; Reason = "OneDrive is not installed for this user ($Executable was not found); there is nothing to uninstall." }
        }

        $Candidates = @()
        if ($env:SystemRoot) { $Candidates += (Join-Path -Path $env:SystemRoot -ChildPath 'System32\OneDriveSetup.exe') }
        if ($env:LOCALAPPDATA) { $Candidates += (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft\OneDrive\OneDriveSetup.exe') }
        if ($env:SystemRoot) { $Candidates += (Join-Path -Path $env:SystemRoot -ChildPath 'SysWOW64\OneDriveSetup.exe') }
        # A single string (not a one-element array) is required: the provider
        # parameters bind as [string], which rejects a collection.
        $Uninstaller = $Candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

        if (-not $Uninstaller)
        {
            return @{ State = 'Unsupported'; Reason = 'OneDrive appears to be installed, but no OneDriveSetup.exe was found in %SystemRoot%\System32, %LOCALAPPDATA%\Microsoft\OneDrive or %SystemRoot%\SysWOW64, so the official uninstaller cannot be run.' }
        }

        $Account = Get-WtRegistryState -Path 'HKCU:\Software\Microsoft\OneDrive\Accounts\Personal' -Name 'UserEmail'
        if ($Account.Available -and $Account.ValueExists -and -not [string]::IsNullOrWhiteSpace([string]$Account.Value))
        {
            return @{ State = 'Disabled'; Reason = "OneDrive is signed in with a personal account ($($Account.Value)); the uninstaller is not run for a signed-in account. Sign out of OneDrive first." }
        }

        return @{ State = 'Enabled'; Reason = "OneDrive is installed and not signed in; state Enabled runs '$Uninstaller /uninstall'." }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        if ($State -ne 'Enabled')
        {
            return New-WtOperationResult -Status 'skipped' -Operation 'OneDriveUninstall' -Target $Tweak.Id -Rollback 'None' -Message 'State Disabled performs no change; no uninstaller was run and no file was removed.'
        }

        $Candidates = @()
        if ($env:SystemRoot) { $Candidates += (Join-Path -Path $env:SystemRoot -ChildPath 'System32\OneDriveSetup.exe') }
        if ($env:LOCALAPPDATA) { $Candidates += (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft\OneDrive\OneDriveSetup.exe') }
        if ($env:SystemRoot) { $Candidates += (Join-Path -Path $env:SystemRoot -ChildPath 'SysWOW64\OneDriveSetup.exe') }
        # A single string (not a one-element array) is required: the provider
        # parameters bind as [string], which rejects a collection.
        $Uninstaller = $Candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

        if (-not $Uninstaller)
        {
            return New-WtOperationResult -Status 'failed' -Operation 'OneDriveUninstall' -Target $Tweak.Id -Rollback 'None' -Message 'No OneDriveSetup.exe was found in %SystemRoot%\System32, %LOCALAPPDATA%\Microsoft\OneDrive or %SystemRoot%\SysWOW64; nothing was run.'
        }

        $Account = Get-WtRegistryState -Path 'HKCU:\Software\Microsoft\OneDrive\Accounts\Personal' -Name 'UserEmail'
        if ($Account.Available -and $Account.ValueExists -and -not [string]::IsNullOrWhiteSpace([string]$Account.Value))
        {
            return New-WtOperationResult -Status 'skipped' -Operation 'OneDriveUninstall' -Target $Uninstaller -Rollback 'None' -Message "OneDrive is signed in with a personal account ($($Account.Value)); the uninstaller was not run. Sign out of OneDrive first if you really want to remove it."
        }

        # The official uninstaller does the removal; this tweak only starts it and
        # reports what it said. Its own result is re-labelled as irreversible so the
        # reported rollback fidelity matches the tweak.
        $Result = Invoke-WtProcess -FilePath $Uninstaller -ArgumentList @('/uninstall') -TimeoutSeconds 1800

        return @(
            New-WtOperationResult -Status $Result.Status -Operation 'OneDriveUninstall' -Target $Result.Target -Message $Result.Message -ErrorRecord $Result.Error -Rollback 'None'
        )
    }
