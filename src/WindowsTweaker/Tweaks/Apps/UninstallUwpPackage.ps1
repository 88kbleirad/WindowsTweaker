# WindowsTweaker - application package (UWP/Appx) tweaks.
#
# Contract for package removal, enforced by the provider and by this definition:
#   * nothing is selected by default (DefaultState is Disabled, and Enabled without
#     an explicit package list fails instead of guessing),
#   * the exact package identities and the user scope are shown before applying,
#   * essential packages are protected by Get-WtProtectedPackage,
#   * removal is reported as irreversible and data-deleting.

New-WtScriptTweak -Id 'Apps.UninstallUwpPackage' -Category 'Apps' `
    -Name @{
        en = 'Remove selected Store app packages'
        vi = 'Gỡ các gói ứng dụng Store đã chọn'
    } `
    -Description @{
        en = 'Removes exactly the package identities passed in -Arguments.PackageFullName. Nothing is selected automatically.'
        vi = 'Chỉ gỡ đúng các gói có định danh trong -Arguments.PackageFullName. Không có gói nào được chọn tự động.'
    } `
    -Impact @{
        en = 'Irreversible: package data is deleted and the app must be reinstalled from the Microsoft Store. Essential packages (Store, App Installer, shell components, runtimes) are refused.'
        vi = 'Không thể hoàn tác: dữ liệu của gói bị xóa và ứng dụng phải cài lại từ Microsoft Store. Các gói thiết yếu (Store, App Installer, thành phần shell, runtime) sẽ bị từ chối.'
    } `
    -StateNames @('Enabled', 'Disabled') -DefaultState 'Disabled' `
    -Scope 'User' -Privilege 'Admin' -Restart 'SignOut' -Rollback 'None' -Risk 'High' -Irreversible -DataDeletion `
    -Requires @('Cmdlet:Get-AppxPackage') `
    -Parameters @('PackageFullName', 'AllUsers') `
    -Detect {
        param ($Tweak, $Arguments)

        if (-not (Test-WtAppxAvailable))
        {
            return @{ State = 'Unsupported'; Reason = 'The Appx module is not available on this platform.' }
        }

        $AllUsers = [bool]$Arguments.AllUsers
        $Scope = if ($AllUsers) { 'AllUsers' } else { 'CurrentUser' }
        $Requested = @($Arguments.PackageFullName | Where-Object { $_ })

        $Installed = @(Get-WtAppxPackageInfo -AllUsers:$AllUsers)
        $Instances = @($Installed | Where-Object { -not $_.IsFramework -and -not $_.IsResourcePackage } | ForEach-Object {
            [pscustomobject]@{
                Id        = $_.PackageFullName
                Label     = "$($_.Name) $($_.Version) [$($_.Scope)]"
                State     = 'Installed'
                Protected = $_.Protected
            }
        })

        if ($Requested.Count -eq 0)
        {
            return @{
                State     = 'Disabled'
                Instances = $Instances
                Reason    = "No package was selected. $($Instances.Count) removable package(s) are installed for $Scope."
            }
        }

        $StillPresent = @($Installed | Where-Object { $Requested -contains $_.PackageFullName })

        return @{
            State     = if ($StillPresent.Count -gt 0) { 'Enabled' } else { 'Disabled' }
            Instances = $Instances
            Reason    = if ($StillPresent.Count -gt 0)
            {
                "Selected for removal in $Scope scope: $(($StillPresent | ForEach-Object { $_.Name }) -join ', ')"
            }
            else
            {
                'None of the selected packages are installed.'
            }
        }
    } `
    -Apply {
        param ($Tweak, $State, $Arguments)

        if ($State -ne 'Enabled')
        {
            return New-WtOperationResult -Status 'skipped' -Operation 'RemoveAppxPackage' -Target $Tweak.Id -Message 'No package was selected; nothing was removed.' -Rollback None
        }

        $Requested = @($Arguments.PackageFullName | Where-Object { $_ })
        if ($Requested.Count -eq 0)
        {
            return New-WtOperationResult -Status 'failed' -Operation 'RemoveAppxPackage' -Target $Tweak.Id -Message 'State Enabled requires -Arguments @{ PackageFullName = @(...) }; no package was selected, so nothing was removed.' -Rollback None
        }

        return @(Remove-WtAppxPackage -PackageFullName $Requested -AllUsers:([bool]$Arguments.AllUsers))
    }
