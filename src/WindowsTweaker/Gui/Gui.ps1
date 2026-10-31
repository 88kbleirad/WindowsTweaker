# WindowsTweaker - WPF interface.
#
# Presentation lives in Gui\MainWindow.xaml; behaviour lives here and only ever calls
# the public API of the module, so the GUI has exactly the same guarantees as the CLI
# (dry run, state capture, verification, structured logging).
#
# Opening the window performs read-only detection: Get-WtEnvironment,
# Get-WtTweakState and Get-WtHistory. Nothing is written until the user presses
# "Apply selected" or "Roll back selected".

function Get-WtGuiXamlPath
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    return (Join-Path $Script:WtModuleRoot 'Gui/MainWindow.xaml')
}

<#
.SYNOPSIS
    Creates a runspace factory configured for background apply operations.
#>
function Get-WtGuiRunspace
{
    [CmdletBinding()]
    param ()

    $Runspace = [runspacefactory]::CreateRunspace()
    $Runspace.ApartmentState = 'MTA'
    $Runspace.ThreadOptions = 'ReuseThread'
    $Runspace.Open()
    return $Runspace
}

<#
.SYNOPSIS
    Applies a batch of tweaks in a background runspace, pumping the UI dispatcher.
.DESCRIPTION
    Progress lines are pushed through a concurrent queue so the window stays
    responsive and the user sees which item is being processed. Results come back as
    the same InvokeResult objects the CLI produces.
#>
function Invoke-WtGuiBatch
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object[]]$Items,
        [Parameter(Mandatory = $true)][bool]$DryRun,
        [Parameter(Mandatory = $true)][object]$Window,
        [Parameter(Mandatory = $true)][System.Collections.Concurrent.ConcurrentQueue[string]]$Progress,
        [Parameter(Mandatory = $false)][string]$ModulePath
    )

    if (-not $ModulePath)
    {
        $Module = Get-Module -Name WindowsTweaker
        $ModulePath = if ($Module) { $Module.Path } else { Join-Path $Script:WtModuleRoot 'WindowsTweaker.psd1' }
    }

    $Runspace = Get-WtGuiRunspace
    $PowerShell = [powershell]::Create()
    $PowerShell.Runspace = $Runspace

    [void]$PowerShell.AddScript({
        param ($ModulePath, $Items, $DryRun, $ProgressQueue, $StatePath, $LogDirectory)

        if ($StatePath) { $env:WT_STATE_PATH = $StatePath }
        if ($LogDirectory) { $env:WT_LOG_DIRECTORY = $LogDirectory }

        Import-Module -Name $ModulePath -Force
        Initialize-WtLogging -Console $false | Out-Null

        # The interface owns the confirmation flow (dialogs), so providers must not
        # raise their own interactive prompts inside this background runspace.
        $ConfirmPreference = 'None'

        $Results = @()
        foreach ($Item in $Items)
        {
            $ProgressQueue.Enqueue("$($Item.Id) -> $($Item.Target)")
            $Parameters = @{ Id = $Item.Id; State = $Item.Target }
            if ($Item.Arguments) { $Parameters.Arguments = $Item.Arguments }
            if ($DryRun) { $Parameters.WhatIf = $true }
            $Results += Invoke-WtTweak @Parameters
        }

        $ProgressQueue.Enqueue('done')
        return $Results
    })

    [void]$PowerShell.AddParameter('ModulePath', $ModulePath)
    [void]$PowerShell.AddParameter('Items', $Items)
    [void]$PowerShell.AddParameter('DryRun', $DryRun)
    [void]$PowerShell.AddParameter('ProgressQueue', $Progress)
    [void]$PowerShell.AddParameter('StatePath', (Get-WtStatePath))
    [void]$PowerShell.AddParameter('LogDirectory', (Get-WtLogDirectory))

    $Handle = $PowerShell.BeginInvoke()

    while (-not $Handle.IsCompleted)
    {
        # Pump the dispatcher so the window keeps painting while work continues.
        $null = $Window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [action] {})

        $Line = $null
        while ($Progress.TryDequeue([ref]$Line))
        {
            if ($Line -ne 'done')
            {
                $Window.FindName('StatusText').Text = $Line
            }
        }
    }

    try
    {
        $Results = $PowerShell.EndInvoke($Handle)
    }
    finally
    {
        $PowerShell.Dispose()
        $Runspace.Dispose()
    }

    return @($Results)
}

<#
.SYNOPSIS
    Argument picker for tweaks that need arguments (package removal, DNS).
.DESCRIPTION
    Built in code so it stays independent of the main window's XAML. Nothing is
    preselected: the user must tick the exact packages/adapters, and the dialog
    returns $null when cancelled.
#>
function Show-WtGuiArgumentDialog
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][psobject]$Tweak)

    $Parameters = @($Tweak.Parameters)
    $Title = Get-WtText -Value $Tweak.Name

    $Window = New-Object System.Windows.Window
    $Window.Title = $Title
    $Window.Width = 820
    $Window.Height = 620
    $Window.Background = '#1e1e2e'
    $Window.WindowStartupLocation = 'CenterOwner'

    $Grid = New-Object System.Windows.Controls.Grid
    $Grid.Margin = '12'
    $Grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
    $Grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = '*' }))
    $Grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
    $Grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
    $Window.Content = $Grid

    $Info = New-Object System.Windows.Controls.TextBlock
    $Info.Text = (Get-WtText -Value $Tweak.Impact)
    $Info.TextWrapping = 'Wrap'
    $Info.Foreground = '#a6adc8'
    $Info.Margin = '0,0,0,10'
    [System.Windows.Controls.Grid]::SetRow($Info, 0)
    [void]$Grid.Children.Add($Info)

    $List = New-Object System.Windows.Controls.ListView
    $List.Background = '#181825'
    $List.Foreground = '#cdd6f4'
    $List.SelectionMode = 'Multiple'
    [System.Windows.Controls.Grid]::SetRow($List, 1)
    [void]$Grid.Children.Add($List)

    $Items = @()
    $IsPackagePicker = $Parameters -contains 'PackageFullName'

    if ($IsPackagePicker)
    {
        if (Test-WtAppxAvailable)
        {
            $Items = @(Get-WtAppxPackageInfo | Where-Object { -not $_.IsFramework -and -not $_.IsResourcePackage } |
                Sort-Object -Property Name |
                ForEach-Object {
                    [pscustomobject]@{
                        Display = "$($_.Name) $($_.Version) [$($_.Scope)]$(if ($_.Protected) { ' - protected' })"
                        Value   = $_.PackageFullName
                        Enabled = (-not $_.Protected) -and (-not $_.NonRemovable)
                    }
                })
        }
    }
    elseif ($Parameters -contains 'InterfaceIndex')
    {
        $Items = @(Get-WtNetworkAdapterInternal | ForEach-Object {
            [pscustomobject]@{
                Display = "$($_.Name) (index $($_.InterfaceIndex), $($_.Status))$(if ($_.IsVirtualOrTunnel) { ' - virtual/VPN' })"
                Value   = $_.InterfaceIndex
                Enabled = $true
            }
        })
    }
    else
    {
        [System.Windows.MessageBox]::Show("This tweak requires arguments ($($Parameters -join ', ')) that this dialog does not know how to collect. Use the command line: -Arguments @{ ... }", (Get-WtString -Key 'Gui.Title'), 'OK', 'Information') | Out-Null
        return $null
    }

    $List.ItemsSource = $Items

    $Servers = New-Object System.Windows.Controls.TextBox
    $Servers.Background = '#181825'
    $Servers.Foreground = '#cdd6f4'
    $Servers.Margin = '0,10,0,0'
    $Servers.Visibility = if ($IsPackagePicker) { 'Collapsed' } else { 'Visible' }
    [System.Windows.Controls.Grid]::SetRow($Servers, 2)
    [void]$Grid.Children.Add($Servers)

    $ServersLabel = New-Object System.Windows.Controls.TextBlock
    $ServersLabel.Text = 'DNS servers (comma separated)'
    $ServersLabel.Foreground = '#a6adc8'
    $ServersLabel.Margin = '0,10,0,0'
    $ServersLabel.Visibility = $Servers.Visibility
    [System.Windows.Controls.Grid]::SetRow($ServersLabel, 2)
    [void]$Grid.Children.Add($ServersLabel)
    $Servers.Margin = '0,34,0,0'

    $Buttons = New-Object System.Windows.Controls.StackPanel
    $Buttons.Orientation = 'Horizontal'
    $Buttons.HorizontalAlignment = 'Right'
    $Buttons.Margin = '0,10,0,0'
    [System.Windows.Controls.Grid]::SetRow($Buttons, 3)
    [void]$Grid.Children.Add($Buttons)

    $Ok = New-Object System.Windows.Controls.Button
    $Ok.Content = Get-WtString -Key 'Gui.Apply'
    $Ok.Padding = '14,6'
    $Ok.Margin = '0,0,8,0'
    $Ok.Background = '#313244'
    $Ok.Foreground = '#a6e3a1'
    [void]$Buttons.Children.Add($Ok)

    $Cancel = New-Object System.Windows.Controls.Button
    $Cancel.Content = Get-WtString -Key 'Common.Cancel'
    $Cancel.Padding = '14,6'
    $Cancel.Background = '#313244'
    $Cancel.Foreground = '#cdd6f4'
    [void]$Buttons.Children.Add($Cancel)

    $Result = $null
    $Confirm = {
        $Chosen = @($List.SelectedItems)
        if ($Chosen.Count -eq 0)
        {
            [System.Windows.MessageBox]::Show((Get-WtString -Key 'Gui.NoSelection'), (Get-WtString -Key 'Gui.Title'), 'OK', 'Information') | Out-Null
            return
        }

        if ($IsPackagePicker)
        {
            $script:WtDialogResult = @{ PackageFullName = @($Chosen | ForEach-Object { $_.Value }) }
        }
        else
        {
            $Addresses = @($Servers.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($Addresses.Count -eq 0)
            {
                [System.Windows.MessageBox]::Show('Enter at least one DNS server address.', (Get-WtString -Key 'Gui.Title'), 'OK', 'Information') | Out-Null
                return
            }

            $script:WtDialogResult = @{
                InterfaceIndex  = @($Chosen | ForEach-Object { $_.Value })
                ServerAddresses = $Addresses
                AllowVirtualAdapter = $false
            }
        }

        $Window.Close()
    }

    $Ok.Add_Click($Confirm)
    $Cancel.Add_Click({ $script:WtDialogResult = $null; $Window.Close() })

    $script:WtDialogResult = $null
    [void]$Window.ShowDialog()
    $Result = $script:WtDialogResult

    return $Result
}

<#
.SYNOPSIS
    Interactive WPF front end over the same backend as the console.
.PARAMETER Language
    Initial interface language (en, vi); switchable at runtime, no restart needed.
#>
function Start-WtGui
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][object]$Language)

    if (-not (Get-WtRuntimeProfile).IsWindows)
    {
        Write-Warning -Message (Get-WtString -Key 'Error.WindowsOnly' -Arguments @(Get-WtPlatformDescription))
        return
    }

    if (-not ('System.Windows.Window' -as [type]))
    {
        try
        {
            Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        }
        catch
        {
            Write-Warning -Message 'WPF (PresentationFramework) is not available in this PowerShell session.'
            return
        }
    }

    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA')
    {
        Write-Warning -Message 'The graphical interface needs an STA thread. Start WindowsTweaker with "pwsh -STA".'
        return
    }

    Initialize-WtLocalization -Language $Language | Out-Null

    $XamlPath = Get-WtGuiXamlPath
    if (-not (Test-Path -LiteralPath $XamlPath))
    {
        Write-Warning -Message "Interface definition not found: $XamlPath"
        return
    }

    $Reader = [System.Xml.XmlReader]::Create($XamlPath)
    try
    {
        $Window = [System.Windows.Markup.XamlReader]::Load($Reader)
    }
    finally
    {
        $Reader.Close()
    }

    # ---- state used by the window -------------------------------------------------
    $Script:WtGuiStateCache = @()
    $Script:WtGuiPending = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    $Script:WtGuiProgress = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

    # ---- localization -------------------------------------------------------------
    $ApplyLanguage = {
        $Text = {
            param ($Name, $Key)
            $Element = $Window.FindName($Name)
            if ($Element) { $Element.Content = Get-WtString -Key $Key }
        }
        & $Text 'TabTweaks' 'Menu.Catalog'
        & $Text 'TabHistory' 'Menu.History'
        & $Text 'LblSearch' 'Gui.Search'
        & $Text 'LblCategory' 'Gui.Category'
        & $Text 'LblSupported' 'State.Supported'
        & $Text 'BtnRefresh' 'Gui.Refresh'
        & $Text 'BtnAdd' 'Gui.Apply'
        & $Text 'BtnApply' 'Gui.Apply'
        & $Text 'BtnClear' 'Common.Cancel'
        & $Text 'BtnRollback' 'Gui.Rollback'
        & $Text 'ChkDryRun' 'Gui.DryRun'
        & $Text 'LblPending' 'Gui.Pending'
        & $Text 'LblLanguage' 'Cli.Language'
        & $Text 'LblTargetState' 'State.Header'
        & $Text 'ColName' 'State.Header'
        & $Text 'ColState' 'State.Header'
        & $Text 'ColCategory' 'Gui.Category'
        & $Text 'ColPrivilege' 'Gui.Privilege'
        & $Text 'ColRestart' 'Gui.Restart'
        & $Text 'ColRollback' 'Gui.RollbackSupport'
        & $Text 'ColPendingTweak' 'State.Header'
        & $Text 'ColPendingChange' 'Gui.Pending'
        & $Text 'ColHistTime' 'Gui.History'
        & $Text 'ColHistTweak' 'State.Header'
        & $Text 'ColHistState' 'State.Header'
        & $Text 'ColHistOutcome' 'Op.succeeded'
        & $Text 'ColHistRolledBack' 'Gui.Rollback'

        $Window.FindName('HeaderTitle').Text = Get-WtString -Key 'Gui.Title'
        $Window.FindName('HeaderSubtitle').Text = Get-WtString -Key 'Cli.Subtitle'
        $Window.Title = Get-WtString -Key 'Gui.Title'
        $Window.FindName('SearchBox').ToolTip = Get-WtString -Key 'Gui.Search'

        $Environment = Get-WtEnvironment
        $Window.FindName('EnvText').Text = "PS $($Environment.PowerShell) | $($Environment.OSVersionKey) $($Environment.OSBuild) | Admin: $($Environment.IsAdmin)"
        $Window.FindName('RefreshHint').Text = if ($Environment.IsAdmin) { '' } else { Get-WtString -Key 'Cli.NotAdmin' }
    }

    # ---- data ---------------------------------------------------------------------
    $LoadHistory = {
        $History = @(Get-WtHistory -Limit 100 | ForEach-Object {
            [pscustomobject]@{
                Timestamp  = $_.Timestamp
                TweakId    = $_.TweakId
                State      = $_.State
                Outcome    = $_.Outcome
                RolledBack = [bool]$_.RolledBack
                HistoryId  = $_.HistoryId
                Irreversible = [bool]$_.Irreversible
            }
        })
        $Window.FindName('HistoryList').ItemsSource = $History
    }

    $LoadTweaks = {
        $Search = $Window.FindName('SearchBox').Text
        $CategoryElement = $Window.FindName('CategoryList')
        $Category = if ($CategoryElement.SelectedItem) { [string]$CategoryElement.SelectedItem } else { $null }
        if ($Category -eq (Get-WtString -Key 'Common.None')) { $Category = $null }

        $States = @(Get-WtTweakState -Search $Search -Category $Category)
        $Script:WtGuiStateCache = $States

        $Window.FindName('TweakList').ItemsSource = @($States | ForEach-Object {
            [pscustomobject]@{
                Id        = $_.Id
                Name      = $_.Name
                State     = $_.State
                Category  = $_.Category
                Privilege = $_.Privilege
                Restart   = $_.Restart
                Rollback  = $_.Rollback
                Supported = $_.Supported
                Impact    = $_.Impact
                Managed   = $_.Managed
                Irreversible = $_.Irreversible
                DataDeletion = $_.DataDeletion
            }
        })

        $Window.FindName('SupportedSummary').Text = "$(@($States | Where-Object { $_.Supported }).Count) / $($States.Count)"
    }

    $ShowDetails = {
        $Selected = $Window.FindName('TweakList').SelectedItem
        $States = $Script:WtGuiStateCache
        if (-not $Selected) { return }

        $State = $States | Where-Object { $_.Id -eq $Selected.Id } | Select-Object -First 1
        if (-not $State) { return }

        $Window.FindName('DetailsName').Text = "$($State.Name)"
        $Window.FindName('DetailsDescription').Text = $State.Description
        $Window.FindName('DetailsState').Text = "$(Get-WtString -Key 'State.Header'): $($State.State)$(if (-not $State.Supported) { " - $($State.UnsupportedReason)" })"
        $Window.FindName('DetailsImpact').Text = "$(Get-WtString -Key 'State.Impact'): $($State.Impact) | $($State.Risk) | $($State.Scope) | $($State.Privilege)"
        $Window.FindName('DetailsManaged').Text = if ($State.Managed) { Get-WtString -Key 'Error.ManagedByPolicy' -Arguments @(($State.ManagedBy) -join ', ') } else { '' }

        $Combo = $Window.FindName('StateCombo')
        $Combo.ItemsSource = @($State.StateNames)
        if (@($State.StateNames).Count -gt 0) { $Combo.SelectedIndex = 0 }
    }

    $AddPending = {
        $Selected = @($Window.FindName('TweakList').SelectedItems)
        if ($Selected.Count -eq 0)
        {
            Write-Warning -Message (Get-WtString -Key 'Gui.NoSelection')
            return
        }

        $Target = [string]$Window.FindName('StateCombo').SelectedItem

        foreach ($Item in $Selected)
        {
            $State = $Script:WtGuiStateCache | Where-Object { $_.Id -eq $Item.Id } | Select-Object -First 1
            if (-not $State) { continue }

            $Desired = if ($Target) { $Target } elseif ($State.State -eq 'Enabled') { 'Disabled' } else { $State.DefaultState }
            if (@($State.StateNames) -notcontains $Desired) { continue }

            # Parameterized tweaks (package removal, DNS) ask for their exact scope
            # here; cancelling the dialog cancels the change.
            $Arguments = $null
            if (@($State.Tweak.Parameters).Count -gt 0)
            {
                $Arguments = Show-WtGuiArgumentDialog -Tweak $State.Tweak
                if ($null -eq $Arguments) { continue }
            }

            $Script:WtGuiPending.Add([pscustomobject]@{
                Id        = $State.Id
                Target    = $Desired
                Tweak     = $State.Name
                Change    = "$($State.State) -> $Desired"
                Arguments = $Arguments
            })
        }
    }

    $ApplyPending = {
        if ($Script:WtGuiPending.Count -eq 0)
        {
            $Window.FindName('StatusText').Text = Get-WtString -Key 'Gui.NothingPending'
            return
        }

        $Items = @($Script:WtGuiPending | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Target = $_.Target; Arguments = $_.Arguments } })
        $DryRun = [bool]$Window.FindName('ChkDryRun').IsChecked

        $Window.FindName('Progress').IsIndeterminate = $true
        $Window.FindName('StatusText').Text = Get-WtString -Key 'Gui.Busy'

        try
        {
            $Results = @(Invoke-WtGuiBatch -Items $Items -DryRun $DryRun -Window $Window -Progress $Script:WtGuiProgress)

            $Failed = @($Results | Where-Object { $_.Status -eq 'failed' })
            $Summary = ($Results | ForEach-Object { "$($_.TweakId): $($_.Status)" }) -join '; '
            $Window.FindName('StatusText').Text = $Summary

            if ($Failed.Count -gt 0)
            {
                [System.Windows.MessageBox]::Show(
                    (Get-WtString -Key 'Msg.PartialFailure' -Arguments @($Failed.Count)) + [Environment]::NewLine + ($Failed.Messages -join [Environment]::NewLine),
                    (Get-WtString -Key 'Gui.Title'),
                    'OK',
                    'Warning') | Out-Null
            }
        }
        finally
        {
            $Window.FindName('Progress').IsIndeterminate = $false
            $Script:WtGuiPending.Clear()
            & $LoadTweaks
            & $LoadHistory
        }
    }

    $RollbackSelected = {
        $Selected = $Window.FindName('HistoryList').SelectedItem
        if (-not $Selected)
        {
            Write-Warning -Message (Get-WtString -Key 'Gui.NoSelection')
            return
        }

        if (-not $Selected.RolledBack -and -not $Selected.Irreversible)
        {
            # nothing to warn about
        }
        elseif ($Selected.Irreversible)
        {
            $Answer = [System.Windows.MessageBox]::Show(
                (Get-WtString -Key 'Gui.IrreversibleWarning'),
                (Get-WtString -Key 'Gui.Title'),
                'YesNo',
                'Warning')
            if ($Answer -ne 'Yes') { return }
        }

        $Result = Undo-WtTweak -HistoryId $Selected.HistoryId
        $Window.FindName('StatusText').Text = "$($Selected.TweakId): $($Result.Status)"
        if ($Result.Status -eq 'failed')
        {
            [System.Windows.MessageBox]::Show(($Result.Messages -join [Environment]::NewLine), (Get-WtString -Key 'Gui.Title'), 'OK', 'Error') | Out-Null
        }

        & $LoadTweaks
        & $LoadHistory
    }

    # ---- wiring -------------------------------------------------------------------
    $Window.FindName('LanguageCombo').ItemsSource = Get-WtSupportedLanguages
    $Window.FindName('LanguageCombo').SelectedItem = Get-WtLanguage
    $Window.FindName('LanguageCombo').Add_SelectionChanged({
        param ($EventSender, $EventArguments)
        if ($EventSender.SelectedItem)
        {
            Set-WtLanguage -Language $EventSender.SelectedItem | Out-Null
            & $ApplyLanguage
            & $LoadTweaks
            & $LoadHistory
        }
    })

    $Window.FindName('SearchBox').Add_TextChanged({ & $LoadTweaks })
    $Window.FindName('CategoryList').Add_SelectionChanged({ & $LoadTweaks })
    $Window.FindName('TweakList').Add_SelectionChanged({ & $ShowDetails })
    $Window.FindName('BtnRefresh').Add_Click({ & $LoadTweaks })
    $Window.FindName('BtnAdd').Add_Click({ & $AddPending })
    $Window.FindName('BtnClear').Add_Click({ $Script:WtGuiPending.Clear() })
    $Window.FindName('BtnApply').Add_Click({ & $ApplyPending })
    $Window.FindName('BtnRollback').Add_Click({ & $RollbackSelected })
    $Window.FindName('PendingList').ItemsSource = $Script:WtGuiPending

    # Initial load is read-only.
    & $ApplyLanguage
    $Categories = @(Get-WtCategory) + @(Get-WtString -Key 'Common.None')
    $Window.FindName('CategoryList').ItemsSource = $Categories
    & $LoadTweaks
    & $LoadHistory
    $Window.FindName('StatusText').Text = Get-WtString -Key 'Cli.NotAdmin'

    [void]$Window.ShowDialog()

    # Clear GUI-scoped caches when the window closes.
    $Script:WtGuiStateCache = @()
    $Script:WtGuiPending.Clear()
}
