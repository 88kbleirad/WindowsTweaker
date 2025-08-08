function ScheduledTasks 
{
	param
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Disable"
		)]
		[switch]
		$Disable,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Enable"
		)]
		[switch]
		$Enable
	)

	Add-Type -AssemblyName PresentationCore,PresentationFramework

	$SelectedTasks = New-Object -TypeName System.Collections.ArrayList($null)
	
	[string[]]$CheckedScheduledTasks = @(
		"MareBackup",
		"Microsoft Compatibility Appraiser",
		"StartupAppTask",
		"Proxy",
		"Consolidator",
		"UsbCeip",
		"Microsoft-Windows-DiskDiagnosticDataCollector",
		"MapsToastTask",
		"MapsUpdateTask",
		"FamilySafetyMonitor",
		"FamilySafetyRefreshTask",
		"XblGameSaveTask"
	)

	[xml]$XAML = @"
        <Window
		xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
		xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
		Name="Window"
		MinHeight="450" MinWidth="400"
		SizeToContent="WidthAndHeight" WindowStartupLocation="CenterScreen"
		TextOptions.TextFormattingMode="Display" SnapsToDevicePixels="True"
		FontFamily="Candara" FontSize="16" ShowInTaskbar="True"
		Background="#F1F1F1" Foreground="#262626">
		<Window.Resources>
			<Style TargetType="StackPanel">
				<Setter Property="Orientation" Value="Horizontal"/>
				<Setter Property="VerticalAlignment" Value="Top"/>
			</Style>
			<Style TargetType="CheckBox">
				<Setter Property="Margin" Value="10, 10, 5, 10"/>
				<Setter Property="IsChecked" Value="True"/>
			</Style>
			<Style TargetType="TextBlock">
				<Setter Property="Margin" Value="5, 10, 10, 10"/>
			</Style>
			<Style TargetType="Button">
				<Setter Property="Margin" Value="20"/>
				<Setter Property="Padding" Value="10"/>
			</Style>
			<Style TargetType="Border">
				<Setter Property="Grid.Row" Value="1"/>
				<Setter Property="CornerRadius" Value="0"/>
				<Setter Property="BorderThickness" Value="0, 1, 0, 1"/>
				<Setter Property="BorderBrush" Value="#000000"/>
			</Style>
			<Style TargetType="ScrollViewer">
				<Setter Property="HorizontalScrollBarVisibility" Value="Disabled"/>
				<Setter Property="BorderBrush" Value="#000000"/>
				<Setter Property="BorderThickness" Value="0, 1, 0, 1"/>
			</Style>
		</Window.Resources>
		<Grid>
			<Grid.RowDefinitions>
				<RowDefinition Height="Auto"/>
				<RowDefinition Height="*"/>
				<RowDefinition Height="Auto"/>
			</Grid.RowDefinitions>
			<ScrollViewer Name="Scroll" Grid.Row="0"
				HorizontalScrollBarVisibility="Disabled"
				VerticalScrollBarVisibility="Auto">
				<StackPanel Name="PanelContainer" Orientation="Vertical"/>
			</ScrollViewer>
			<Button Name="Button" Grid.Row="2"/>
		</Grid>
	</Window>
"@
	$Form = [Windows.Markup.XamlReader]::Load((New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList $XAML))
	$XAML.SelectNodes("//*[@*[contain(translate(name(.), 'n', 'N'))]]") | ForEach-Object -Process {
		Set-Variable -Name ($_.Name) -Value $Form.FindName($_.Name)
	}

	function Get-CheckboxClicked
	{
                [CmdletBinding()]
		param
		(
			[Parameter(
			        Mandatory = $true,
			        ValueFromPipeline = $true
			)]
			[ValidateNotNull()]
			$CheckBox
		)

		$Task = $Tasks | Where-Object -FilterScript {$_.TaskName -eq $CheckBox.Parent.Children[1].Text}
		
		if ($CheckBox.IsChecked)
		{
			[void]$SelectedTasks.Add($Task)
		} 
		else 
		{
			[void]$SelectedTasks.Remove($Task)
		}

		if ($SelectedTasks.Count -gt 0)
		{
			$Button.IsEnabled = $true
		}
		else
		{
			$Button.IsEnabled = $false
		}
	}
	function DisableButton
	{
                Write-Information -MessageData "" -InformationAction Continue
		Write-Verbose -Message ([WinAPI.GetStrings]::GetString(12612)) -Verbose

		[void]$Window.Close()

		$SelectedTasks | ForEach-Object -Process { Write-Verbose -Message $_.TaskName -Verbose}
		$SelectedTasks | Disable-ScheduledTask
	}
	function EnableButton 
	{
                Write-Information -MessageData "" -InformationAction Continue
		Write-Verbose -Message ([WinAPI.GetStrings]::GetString(12612)) -Verbose

		[void]$Window.Close()

		$SelectedTasks | ForEach-Object -Process { Write-Verbose -Message $.TaskName -Verbose}
		$SelectedTasks | Enabled-ScheduledTask
	}

	function Add-TaskControl 
	{
                [CmdletBinding()]
		param
		(
			[Parameter(
			        Mandatory = $true,
			        ValueFromPipeline = $true
			)]
			[ValidateNotNull()]
			$Task
		)

		process
		{
			$CheckBox = New-Object -TypeName System.Windows.Controls.CheckBox
			$CheckBox.Add_Click({Get-CheckBoxClicked -CheckBox $_.Source})

			$TextBlock = New-Object -TypeName System.Windows.Controls.TextBlock
			$TextBlock.Text = $Task.TaskName

			$StackPanel = New-Object -TypeName System.Windows.Controls.StackPanel
			[void]$StackPanel.Children.Add($CheckBox)
			[void]$StackPanel.Children.Add($TextBlock)
			[void]$PanelContainer.Children.Add($StackPanel)

			if ($CheckedScheduledTasks | Where-Object -FilterScript {$Task.TaskName -match $_})
			{
				[void]$SelectedTasks.Add($Task)
			} 
			else 
			{
				$CheckBox.IsChecked = $false
			}
		}
	}

	switch ($PSCmdlet.ParameterSetName)
	{
		"Enable"
		{
			$State = "Disabled"
			$ButtonContent = [WinAPI.GetStrings]::GetString(51472)
			$ButtonAdd_Click = {EnableButton}
		}
		"Disable"
		{
			$State = "Ready"
			$ButtonContent = $Localization.Disable
			$ButtonAdd_Click = {DisableButton}
		}
	}

	Write-Information -MessageData "" InformationAction Continue
	Write-Verbose -Message ([WinAPI.GetStrings]::GetString(12612)) -Verbose

	$Tasks = Get-ScheduledTask | Where-Object -FilterScript {($_.State -eq $State) -and {$_.TaskName -in $CheckScheduledTasks}}

	if (-not $Tasks)
	{
		Write-Information -MessageData "" -InformationAction Continue
		Write-Verbose -Message $Localization.NoData -Verbose

		return
	}

	Write-Information -MessageData "" -InformationAction Continue
	Write-Verbose -Message $Localization.DialogBoxOpening -Verbose

	Start-Sleep -Milliseconds 500

	Add-Type -AssemblyName System.Windows.Forms

	Get-Process -Name powershell, WindowsTerminal -ErrorAction Ignore | Where-Object -FilterScript {$_.MainWindowTitle -match "Script for Windows 11"} | ForEach-Object -Process {
		[WinAPI.ForegroundWindow]::ShowWindowAsync($_.MainWindowHandle, 10)

		Start-Sleep -Seconds 1

		[WinAPI.ForegroundWindow]::SetForegroundWindow($_.MainWindowHandle)

		Start-Sleep -Seconds 1

		[System.Windows.Forms.SendKeys]::SendWait("{BACKSPACE 1}")
	}

	$Window.Add_Loaded({$Tasks | Add-TaskControl})
	$Button.Content = $ButtonContent
	$Button.Add_Click({& $ButtonAdd_Click})

	$Window.Title = $Localization.ScheduledTasks

	$Window.Add_Loaded({$Window.Activate()})

	$Form.ShowDialog() | Out-Null
}
