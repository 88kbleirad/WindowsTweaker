# WindowsTweaker - Appx/UWP package provider.
#
# App removal is irreversible in the "restore my files" sense: this module therefore
#   * never selects packages by default,
#   * reports the exact identity of every package it touches,
#   * refuses to touch packages on the protected list,
#   * reports an explicit irreversible status so callers cannot present it as undoable.

$Script:WtProtectedPackages = @(
    'Microsoft.WindowsStore'
    'Microsoft.StorePurchaseApp'
    'Microsoft.DesktopAppInstaller'
    'Microsoft.WindowsTerminal'
    'Microsoft.SecHealthUI'
    'Microsoft.Windows.SecHealthUI'
    'Microsoft.AAD.BrokerPlugin'
    'Microsoft.AccountsControl'
    'Microsoft.WindowsAppRuntime'
    'Microsoft.VCLibs'
    'Microsoft.UI.Xaml'
    'Microsoft.NET.Native.Framework'
    'Microsoft.NET.Native.Runtime'
    'MicrosoftWindows.Client.CBS'
    'MicrosoftWindows.Client.Core'
    'MicrosoftWindows.Client.FileExp'
    'Microsoft.Windows.ShellExperienceHost'
    'Microsoft.Windows.StartMenuExperienceHost'
    'Microsoft.Windows.Cortana'
    'Microsoft.UI.Xaml.CBS'
    'Microsoft.MicrosoftEdge'
    'Microsoft.WindowsCalculator'
    'Microsoft.Windows.Photos'
    'Microsoft.WindowsNotepad'
)

function Test-WtAppxAvailable
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    if (-not $IsWindows)
    {
        return $false
    }

    return [bool](Get-Command -Name Get-AppxPackage -ErrorAction Ignore)
}

<#
.SYNOPSIS
    Returns the package names that must never be removed by this tool.
#>
function Get-WtProtectedPackage
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ()

    return $Script:WtProtectedPackages
}

function Get-WtAppxPackageRaw
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][string]$Name,
        [Parameter(Mandatory = $false)][switch]$AllUsers
    )

    $Parameters = @{ ErrorAction = 'Ignore' }
    if ($Name)
    {
        $Parameters.Name = $Name
    }
    if ($AllUsers)
    {
        $Parameters.AllUsers = $true
    }

    return @(Get-AppxPackage @Parameters)
}

function Remove-WtAppxPackageRaw
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$PackageFullName,
        [Parameter(Mandatory = $false)][switch]$AllUsers
    )

    $Parameters = @{ Package = $PackageFullName; ErrorAction = 'Stop' }
    if ($AllUsers)
    {
        $Parameters.AllUsers = $true
    }

    Remove-AppxPackage @Parameters
}

<#
.SYNOPSIS
    Lists installed packages as structured objects for explicit selection.
.DESCRIPTION
    Read-only. Includes the fields needed to show the exact scope of a removal
    (name, full identity, version, publisher, current user, framework flag) and a
    Protected flag for packages this tool refuses to remove.
#>
function Get-WtAppxPackageInfo
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][string]$Name,
        [Parameter(Mandatory = $false)][switch]$AllUsers
    )

    if (-not (Test-WtAppxAvailable))
    {
        return @()
    }

    $Packages = Get-WtAppxPackageRaw -Name $Name -AllUsers:$AllUsers

    foreach ($Package in $Packages)
    {
        [pscustomobject]@{
            PSTypeName     = 'WindowsTweaker.AppxPackage'
            Name           = $Package.Name
            PackageFullName = $Package.PackageFullName
            Version        = [string]$Package.Version
            Publisher      = $Package.Publisher
            Architecture   = [string]$Package.Architecture
            InstallLocation = $Package.InstallLocation
            IsFramework    = [bool]$Package.IsFramework
            IsResourcePackage = [bool]$Package.IsResourcePackage
            NonRemovable   = [bool]$Package.NonRemovable
            SignatureKind  = [string]$Package.SignatureKind
            User           = if ($Package.PackageUserInformation) { @($Package.PackageUserInformation.Keys) -join ', ' } else { $null }
            Scope          = if ($AllUsers) { 'AllUsers' } else { 'CurrentUser' }
            Protected      = ($Script:WtProtectedPackages -contains $Package.Name)
        }
    }
}

<#
.SYNOPSIS
    Removes the explicitly listed packages.
.PARAMETER PackageFullName
    Exact package identities to remove. Nothing is selected implicitly: an empty
    list removes nothing.
.PARAMETER AllUsers
    Remove for all users (requires elevation) and also remove the provisioned package.
.DESCRIPTION
    Irreversible: user data stored inside the package is deleted. The returned
    results carry Status 'succeeded' together with Rollback 'None'; callers must
    surface that to the user.
#>
function Remove-WtAppxPackage
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param
    (
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$PackageFullName,
        [Parameter(Mandatory = $false)][switch]$AllUsers
    )

    $Operation = 'RemoveAppxPackage'
    $Results = @()

    if (-not (Test-WtAppxAvailable))
    {
        return New-WtOperationResult -Status 'unsupported' -Operation $Operation -Message 'The Appx module is not available on this platform.' -Rollback None
    }

    if (@($PackageFullName).Count -eq 0)
    {
        return New-WtOperationResult -Status 'skipped' -Operation $Operation -Message 'No package was selected; nothing to remove.' -Rollback None
    }

    foreach ($FullName in $PackageFullName)
    {
        $Package = Get-WtAppxPackageRaw -AllUsers:$AllUsers | Where-Object { $_.PackageFullName -eq $FullName } | Select-Object -First 1

        if (-not $Package)
        {
            $Results += New-WtOperationResult -Status 'unchanged' -Operation $Operation -Target $FullName -Message "Package not installed: $FullName" -Rollback None
            continue
        }

        if ($Script:WtProtectedPackages -contains $Package.Name)
        {
            $Results += New-WtOperationResult -Status 'skipped' -Operation $Operation -Target $FullName -Message "Refusing to remove protected package: $($Package.Name)" -Rollback None
            continue
        }

        if ($Package.NonRemovable)
        {
            $Results += New-WtOperationResult -Status 'skipped' -Operation $Operation -Target $FullName -Message "Package is marked non-removable: $($Package.Name)" -Rollback None
            continue
        }

        # No state capture: removal cannot be restored. Say so explicitly.
        $Context = Get-WtOperationContext
        if ($null -ne $Context.HistoryEntry)
        {
            Add-WtStateRecord -HistoryEntry $Context.HistoryEntry -Record @{
                resource    = 'AppxPackage'
                name        = $Package.Name
                fullName    = $Package.PackageFullName
                version     = [string]$Package.Version
                publisher   = $Package.Publisher
                irreversible = $true
            }
        }

        # One confirmation per tweak: Invoke-WtTweak/Undo-WtTweak confirm once, and the
        # providers must not prompt again while that apply/rollback is in progress.
        if ((Get-WtOperationContext).SuppressConfirm) { $ConfirmPreference = 'None' }

        if (-not $PSCmdlet.ShouldProcess("$($Package.Name) ($FullName)", 'remove package (irreversible, deletes package data)'))
        {
            $Results += New-WtOperationResult -Status (Get-WtShouldProcessStatus) -Operation $Operation -Target $FullName -Message "Would remove $($Package.Name)" -Rollback None
            continue
        }

        try
        {
            Remove-WtAppxPackageRaw -PackageFullName $FullName -AllUsers:$AllUsers
        }
        catch
        {
            Write-WtLog -Level Error -Message "Failed to remove $FullName" -Operation $Operation -Status 'failed' -Exception $_.Exception
            $Results += New-WtOperationResult -Status 'failed' -Operation $Operation -Target $FullName -Message $_.Exception.Message -ErrorRecord $_ -Rollback None
            continue
        }

        $StillThere = @(Get-WtAppxPackageRaw -AllUsers:$AllUsers | Where-Object { $_.PackageFullName -eq $FullName }).Count -gt 0
        if ($StillThere)
        {
            $Results += New-WtOperationResult -Status 'failed' -Operation $Operation -Target $FullName -Message "Package still present after removal: $FullName" -Rollback None
            continue
        }

        $Results += New-WtOperationResult -Status 'succeeded' -Operation $Operation -Target $FullName -Message "Removed $($Package.Name) (irreversible)" -Rollback None
    }

    return $Results
}
