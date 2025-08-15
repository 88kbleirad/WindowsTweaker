function WindowsCapabilities
{
	param
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Uninstall"
		)]
		[switch]
		$Uninstall,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Install"
		)]
		[switch]
		$Install
	)

	Add-Type -AssemblyName PresentationCore,PresentationFramework

	$SelectedCapabilities = New-Object -TypeName System.Collections.ArrayList($null)

	[string[]]$CheckedCapabilities = @(
		"App.StepsRecorder*"
	)

	[string[]]$UncheckedCapabilities = @(
		"Browser.InternetExplorer*",
		"Media.WindowsMediaPlayer*"
	)

	[string[]]$ExcludedCapabilities = @(
		"DirectX.Configuration.Database*",
		"Language.*",
		"Microsoft.Windows.Notepad*",
		"OneCoreUAP.OneSync*",
		"Microsoft.Windows.PowerShell.ISE*",
		"Print.Management.Console*",
		"Windows.Client.ShellComponents*"
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
	$XAML.SelectNodes("//*[@*[contain(translate(name(.), 'n', 'N'), 'Name')]]") | ForEach-Object -Process {
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

		$Capability = $Capabilities | Where-Object -FilterScript {$_.DisplayName -eq $CheckBox.Parent.Children[1].Text}

		if ($CheckBox.IsChecked)
		{
			[void]$SelectedCapabilities.Add($Capability)
		}
		else
		{
			[void]$SelectedCapabilities.Remove($Capability)
		}
		

		if ($SelectedCapabilities.Count -gt 0)
		{
			$Button.IsEnabled = $true
		}
		else  
		{
			$Button.IsEnabled = $false
		}
	}

	function UninstallButton
	{
                Write-Information -MessageData "" -InformationAction Continue
		Write-Verbose -Message ([WinAPI.GetStrings]::GetString(12612)) -Verbose

		[void]$Window.Close()

		$SelectedCapabilities | ForEach-Object -Process {Write-Verbose -Message $_.DisplayName -Verbose}
		$SelectedCapabilities | Where-Object -FilterScript {$_.Name -in (Get-WindowsCapability -Online).Name | Remove-WindowsCapability -Online}

		if ([string]$SelectedCapabilities.Name -match "Browser.InternetExplorer")
		{
			Write-Information -MessageData "" -InformationAction Continue
			Write-Warning -Message $Localization.RestartWarning
		}
	}

	function InstallButton
	{
                try {
			Write-Information -MessageData "" -InformationAction Continue
			Write-Verbose -Message ([WinAPI.GetStrings]::GetString(12612)) -Verbose

			[void]$Window.Close()

			$SelectedCapabilities | ForEach-Object -Process {Write-Verbose -Message $_.DisplayName -Verbose}
			$SelectedCapabilities | Where-Object -FilterScript {$_.Name -in ((Get-WindowsCapability -Online).Name)} | Add-WindowsCapability -Online

			if ([string]$SelectedCapabilities.Name -match "Browser.InternetExplorer")
			{
				Write-Information -MessageData "" -InformationAction Continue
				Write-Warning -Message $Localization.RestartWarning
			}
		} 
		catch [System.Runtime.InteropService.COMException]
		{
			
	                Write-Warning -Message ($Localization.NoResponse -f "http://tlu.dl.delivery.mp.microsoft.com/filestreamingservice")
			Write-Error -Message ($Localization.NoResponse -f "http://tlu.dl.delivery.mp.microsoft.com/filestreamingservice") -ErrorAction SilentlyContinue
			Write-Error -Message ($Localization.RestartFunction -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue
		}
	}

	function App-CapabilityControl
	{
                [CmdletBinding()]
		param
		(
			[Parameter(
			        Mandatory = $true,
			        ValueFromPipeline = $true
			)]
			[ValidateNotNull()]
			$Capability
		)

		process
		{
			$CheckBox = New-Object -TypeName System.Windows.Controls.CheckBox
			$CheckBox.Add_Click({Get-CheckBoxClicked -CheckBox $_.Source})
			$CheckBox.ToolTip = $Capability.Description

			$TextBlock = New-Object -TypeName System.Windows.Controls.TextBlock
			$TextBlock.Text = $Capability.DisplayName
			$TextBlock.ToolTip = $Capability.Description

			$StackPanel = New-Object -TypeName System.Windows.Controls.TextBlock
			[void]$StackPanel.Children.Add($CheckBox)
			[void]$StackPanel.Children.Add($TextBlock)
			[void]$PanelContainer.Children.Add($StackPanel)

			if ($UnCheckedCapabilities | Where-Object -FilterScript {$Capability.Name -like $_})
			{
				$CheckBox.IsChecked = $false
				return
			}

			[void]$SelectedCapabilities.Add($Capability)
		}
	}

	switch ($PSCmdlet.ParameterSetName)
	{
		"Install"
		{
			try
			{
				$State = "NotPresent"
				$ButtonContent = $Localization.Install
				$ButtonAdd_Click = {InstallButton}
			}
			catch [System.ComponentModel.Win32Exception]
			{
				Write-Warning -Message ($Localization.NoResponse -f "http://tlu.dl.delivery.mp.microsoft.com/filestreamingservice")
				Write-Error -Message ($Localization.NoResponse -f "http://tlu.dl.delivery.mp.microsoft.com/filestreamingservice") -ErrorAction SilentlyContinue
				Write-Error -Message ($Localization.RestartFunction -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue

				return
			}
		}
		"Uninstall"
		{
			$State = "Installed"
			$ButtonContent = $Localization.Uninstall
			$ButtonAdd_Click = {UninstallButton}
		}
	}

	Write-Information -MessageData "" -InformationAction Continue
	Write-Verbose -Message ([WinAPI.GetStrings]::GetString(12612)) -Verbose

	$OFS = "|"
	$Capabilities = Get-WindowsCapability -Online | Where-Object -FilterScript {
		($_.State -eq $State) -and (($_.Name -match $UncheckedCapabilities) -or ($_.Name -match $CheckCapabilities) -and ($_.Name -notmatch $ExcludedCapabilities)) 
	} | ForEach-Object -Process {Get-WindowsCapability -Name $_.Name -Online}

	if (-not $Capabilities)
	{
		Write-Information -MessageData "" -InformationAction Continue
		Write-Verbose -Message $Localization.NoData -Verbose

		return
	}

	Write-Information -MessageData "" -InformationAction Continue
	Write-Verbose -Message $Localization.DialogBoxOpening -Verbose

	Start-Sleep -Miliseconds 500

	Add-Type -AssemblyName System.Windows.Forms

	Get-Process -Name powershell,WindowsTerminal -ErrorAction Ignore | Where-Object -FilterScript {$_.MainWindowTitle -match "Script for Windows 11"} | ForEach-Object -Process {
		[WinAPI.ForegroundWindow]::ShowWindowAsync($_.MainWindowHandle, 10)
		
		Start-Sleep -Seconds 1

		[WinAPI.ForegroundWindow]::SetForegroundWindow($_.MainWindowHandle)

		Start-Sleep -Seconds 1

		[System.Windows.Forms.SendKeys]::SendWait("{BACKSPACE 1}")
	}

	$Window.Add_Loaded({$Capabilities | Add-CapabilityControl})
	$Button.Content = $ButtonContent
	$Button.Add_Click({& $ButtonAdd_Click})

	$Window.Title = $Localization.OptionFeaturesTitle

	$Window.Add_Loaded({$Window.Activate()})
	$Form.ShowDialog() | Out-Null
}
