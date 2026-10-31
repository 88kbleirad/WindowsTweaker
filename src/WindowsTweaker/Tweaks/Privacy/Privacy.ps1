# WindowsTweaker - Privacy category tweaks.
#
# Derived from Sophia Script for Windows (MIT, (c) 2023 farag2) where noted; the
# operations below were re-expressed as explicit, reversible registry operations
# instead of LGPO policy transcripts (see THIRD-PARTY-NOTICES.md).

New-WtRegistryTweak -Id 'Privacy.AdvertisingId' -Category 'Privacy' `
    -Name @{
        en = 'Advertising ID'
        vi = 'ID quảng cáo'
    } `
    -Description @{
        en = 'Lets apps use the advertising identifier to show personalized ads based on your app usage.'
        vi = 'Cho phép ứng dụng dùng mã nhận dạng quảng cáo để hiển thị quảng cáo cá nhân hóa dựa trên cách bạn dùng ứng dụng.'
    } `
    -Impact @{
        en = 'Disabling only affects personalized in-app ads; non-personalized ads continue to be shown.'
        vi = 'Tắt chỉ ảnh hưởng đến quảng cáo cá nhân hóa trong ứng dụng; quảng cáo không cá nhân hóa vẫn hiển thị.'
    } `
    -Scope 'User' -Privilege 'None' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Requires @('Cmdlet:Get-ItemProperty') `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'
        Name = 'Enabled'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            # Remove the organization/local policy override first, otherwise the
            # user value below has no effect (this is what the LGPO "DELETE" line did).
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo'; Name = 'DisabledByGroupPolicy' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Type = 'DWord'; Value = 0 }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo'; Name = 'DisabledByGroupPolicy' }
    )

New-WtRegistryTweak -Id 'Privacy.TailoredExperiences' -Category 'Privacy' `
    -Name @{
        en = 'Tailored experiences with diagnostic data'
        vi = 'Trải nghiệm phù hợp với dữ liệu chẩn đoán'
    } `
    -Description @{
        en = 'Lets Microsoft use your diagnostic data to offer personalized tips, ads and recommendations.'
        vi = 'Cho phép Microsoft dùng dữ liệu chẩn đoán của bạn để đưa ra gợi ý, quảng cáo và đề xuất phù hợp.'
    } `
    -Impact @{
        en = 'Disabling removes personalization based on diagnostic data; Windows keeps sending the diagnostic data level you have chosen.'
        vi = 'Tắt sẽ bỏ cá nhân hóa dựa trên dữ liệu chẩn đoán; Windows vẫn gửi dữ liệu chẩn đoán theo mức bạn đã chọn.'
    } `
    -Scope 'User' -Privilege 'None' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'
        Name = 'TailoredExperiencesWithDiagnosticDataEnabled'
        Map  = [ordered]@{
            Enabled  = @(1)
            Disabled = @(0)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableTailoredExperiencesWithDiagnosticData' }
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'; Name = 'TailoredExperiencesWithDiagnosticDataEnabled'; Type = 'DWord'; Value = 1 }
        )
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'; Name = 'TailoredExperiencesWithDiagnosticDataEnabled'; Type = 'DWord'; Value = 0 }
        )
    }

New-WtRegistryTweak -Id 'Privacy.FeedbackFrequency' -Category 'Privacy' `
    -Name @{
        en = 'Windows feedback requests'
        vi = 'Yêu cầu phản hồi của Windows'
    } `
    -Description @{
        en = 'Controls how often Windows asks for feedback (Never, Once a day, Once a week, ...).'
        vi = 'Điều khiển tần suất Windows yêu cầu phản hồi (Không bao giờ, Mỗi ngày, Mỗi tuần, ...).'
    } `
    -Impact @{
        en = 'Never reduces interruption; Windows still collects diagnostic data at the level configured in Privacy settings.'
        vi = 'Không bao giờ sẽ giảm gián đoạn; Windows vẫn thu thập dữ liệu chẩn đoán theo mức cấu hình trong Cài đặt quyền riêng tư.'
    } `
    -Scope 'User' -Privilege 'None' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Detection @{
        Path = 'HKCU:\Software\Microsoft\Siuf\Rules'
        Name = 'NumberOfSIUFInPeriod'
        Map  = [ordered]@{
            Disabled = @(0)
            Enabled  = @(1)
        }
    } `
    -DefaultState 'Disabled' `
    -States @{
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Siuf\Rules'; Name = 'NumberOfSIUFInPeriod'; Type = 'DWord'; Value = 0 }
        )
        Enabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKCU:\Software\Microsoft\Siuf\Rules'; Name = 'NumberOfSIUFInPeriod' }
        )
    }

New-WtRegistryTweak -Id 'Privacy.ErrorReporting' -Category 'Privacy' `
    -Name @{
        en = 'Windows Error Reporting'
        vi = 'Báo cáo lỗi Windows'
    } `
    -Description @{
        en = 'Sends crash and error reports to Microsoft.'
        vi = 'Gửi báo cáo lỗi và sự cố tới Microsoft.'
    } `
    -Impact @{
        en = 'Disabling stops automatic crash report uploads; local crash dumps configured for troubleshooting are unaffected.'
        vi = 'Tắt sẽ ngừng tải báo cáo sự cố tự động; các tệp kết xuất cục bộ phục vụ chẩn đoán không bị ảnh hưởng.'
    } `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -Detection @{
        Path = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'
        Name = 'Disabled'
        Map  = [ordered]@{
            Enabled  = @(0)
            Disabled = @(1)
        }
    } `
    -States @{
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'; Name = 'Disabled'; Type = 'DWord'; Value = 0 }
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting'; Name = 'Disabled' }
        )
        Disabled = @(
            @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting'; Name = 'Disabled' }
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'; Name = 'Disabled'; Type = 'DWord'; Value = 1 }
        )
    }

New-WtRegistryTweak -Id 'Privacy.DiagnosticDataLevel' -Category 'Privacy' `
    -Name @{
        en = 'Diagnostic data level'
        vi = 'Mức dữ liệu chẩn đoán'
    } `
    -Description @{
        en = 'Sets how much optional diagnostic data Windows sends to Microsoft.'
        vi = 'Đặt mức dữ liệu chẩn đoán tùy chọn mà Windows gửi tới Microsoft.'
    } `
    -Impact @{
        en = 'Required only sends the minimum data Windows needs to stay secure and up to date. Reducing the level is not the same as disabling diagnostic data collection entirely.'
        vi = 'Chỉ bắt buộc sẽ gửi dữ liệu tối thiểu để Windows an toàn và cập nhật. Giảm mức này không đồng nghĩa với việc tắt hoàn toàn thu thập dữ liệu chẩn đoán.'
    } `
    -Scope 'Machine' -Privilege 'Admin' -Restart 'None' -Rollback 'Full' -Risk 'Low' `
    -CapabilityLoss @(
        @{
            Capability = 'diagnostics.troubleshooting'
            Names      = @{
                en = 'Windows troubleshooting help may become less detailed'
                vi = 'Hỗ trợ khắc phục sự cố của Windows có thể kém chi tiết hơn'
            }
            Kind       = 'Unknown'
            Temporary  = $false
            RestoredBy = @{
                en = 'Raise the diagnostic data level with the same tweak.'
                vi = 'Nâng mức dữ liệu chẩn đoán bằng chính tinh chỉnh này.'
            }
            Limitations = @{
                en = 'Reducing the level is not the same as disabling diagnostic data collection entirely, and writing a policy does not prove that no telemetry leaves the device.'
                vi = 'Giảm mức không đồng nghĩa với tắt hoàn toàn thu thập dữ liệu chẩn đoán, và ghi chính sách không chứng minh không có dữ liệu từ xa rời khỏi thiết bị.'
            }
        }
    ) `
    -Detection @{
        Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
        Name = 'AllowTelemetry'
        Map  = [ordered]@{
            Disabled   = @(0, 1)
            Enabled    = @(3)
        }
    } `
    -DefaultState 'Disabled' `
    -States @{
        Disabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; Type = 'DWord'; Value = 1 }
        )
        Enabled = @(
            @{ Kind = 'RegistrySet'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; Type = 'DWord'; Value = 3 }
        )
    } `
    -ManagedPolicy @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry' }
    )
