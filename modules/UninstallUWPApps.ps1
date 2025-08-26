function UninstallUWPApps 
{
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory = $false)]
		[switch]
		$ForAllUsers
	)

	Add-Type -AssemblyName "$PSScriptRoot\..\Binaries\WinRT.Runtime.dll"
	Add-Type -AssemblyName "$PSScriptRoot\..\Binaries\Microsoft.Windows.SDK.NET.dll"

	Add-Type -AssemblyName PresentationCore,PresentationFramework

	$UncheckedAppxPackages = @(
	        # Dolby Access
		"DolbyLaboratories.DolbyAccess",

		# Windows Media Player
		"Microsoft.ZuneMusic",

		# Screen Sketch
		"Microsoft.ScreenSketch",

		# Photos (and Video Editor)
		"Microsoft.Windows.Photos",
		"Microsoft.Photos.MediaEngineDLC",

		# Calculator
		"Microsoft.WindowsCalculator",

		# Windows Advanced Settings
		"Microsoft.Windows.DevHome",

		# Windows Camera
		"Microsoft.WindowsCamera",

		# Xbox Identity Provider
		"Microsoft.XboxIdentityProvider",

		# Xbox Console Companion
		"Microsoft.XboxApp",

		# Xbox
		"Microsoft.GamingApp",
		"Microsoft.GamingServices",

		# Paint
		"Microsoft.Paint",

		# Xbox TCUI
		"Microsoft.Xbox.TCUI",

		# Xbox Speech To Text Overlay
		"Microsoft.XboxSpeechToTextOverlay",

		# Xbox Game Bar
		"Microsoft.XboxGamingOverlay",

		# Xbox Game Bar Plugin
		"Microsoft.XboxGameOverlay"
	)

	$ExcludedAppxPackages = @(
            	# AMD Radeon Software
		"AdvancedMicroDevicesInc-2.AMDRadeonSoftware",

		# Intel Graphics Control Center
		"AppUp.IntelGraphicsControlPanel",
		"AppUp.IntelGraphicsExperience",

		# ELAN Touchpad
		"ELANMicroelectronicsCorpo.ELANTouchpadforThinkpad",
		"ELANMicroelectronicsCorpo.ELANTrackPointforThinkpa",

		# Microsoft Application Compatibility Enhancements
		"Microsoft.ApplicationCompatibilityEnhancements",

		# AVC Encoder Video Extension
		"Microsoft.AVCEncoderVideoExtension",

		# Microsoft Desktop App Installer
		"Microsoft.DesktopAppInstaller",

		# Store Experience Host
		"Microsoft.StorePurchaseApp",

		# Cross Device Experience Host
		"MicrosoftWindows.CrossDevice",

		# Notepad
		"Microsoft.WindowsNotepad",

		# Microsoft Store
		"Microsoft.WindowsStore",

		# Windows Terminal
		"Microsoft.WindowsTerminal",
		"Microsoft.WindowsTerminalPreview",

		# Web Media Extensions
		"Microsoft.WebMediaExtensions",

		# AV1 Video Extension
		"Microsoft.AV1VideoExtension",

		# Windows Subsystem for Linux
		"MicrosoftCorporationII.WindowsSubsystemForLinux",

		# HEVC Video Extensions from Device Manufacturer
		"Microsoft.HEVCVideoExtension",
		"Microsoft.HEVCVideoExtensions",

		# Raw Image Extension
		"Microsoft.RawImageExtension",

		# HEIF Image Extensions
		"Microsoft.HEIFImageExtension",

		# MPEG-2 Video Extension
		"Microsoft.MPEG2VideoExtension",

		# VP9 Video Extensions
		"Microsoft.VP9VideoExtensions",

		# Webp Image Extensions
		"Microsoft.WebpImageExtension",

		# PowerShell
		"Microsoft.PowerShell",

		# NVIDIA Control Panel
		"NVIDIACorp.NVIDIAControlPanel",

		# Realtek Audio Console
		"RealtekSemiconductorCorp.RealtekAudioControl",

		# Synaptics
		"SynapticsIncorporated.SynapticsControlPanel",
		"SynapticsIncorporated.24916F58D6E7"
	)

	[xml]$XAML = @"
	<Window
		xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
		xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
		Name="Window"
		MinHeight="400" MinWidth="415"
		SizeToContent="Width" WindowStartupLocation="CenterScreen"
		TextOptions.TextFormattingMode="Display" SnapsToDevicePixels="True"
		FontFamily="Candara" FontSize="16" ShowInTaskbar="True"
		Background="#F1F1F1" Foreground="#262626">
		<Window.Resources>
			<Style TargetType="StackPanel">
				<Setter Property="Orientation" Value="Horizontal"/>
				<Setter Property="VerticalAlignment" Value="Top"/>
			</Style>
			<Style TargetType="CheckBox">
				<Setter Property="Margin" Value="10, 13, 10, 10"/>
				<Setter Property="IsChecked" Value="True"/>
			</Style>
			<Style TargetType="TextBlock">
				<Setter Property="Margin" Value="0, 10, 10, 10"/>
			</Style>
			<Style TargetType="Button">
				<Setter Property="Margin" Value="20"/>
				<Setter Property="Padding" Value="10"/>
				<Setter Property="IsEnabled" Value="False"/>
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
			<Grid Grid.Row="0">
				<Grid.ColumnDefinitions>
					<ColumnDefinition Width="*"/>
					<ColumnDefinition Width="*"/>
				</Grid.ColumnDefinitions>
				<StackPanel Name="PanelSelectAll" Grid.Column="0" HorizontalAlignment="Left">
					<CheckBox Name="CheckBoxSelectAll" IsChecked="False"/>
					<TextBlock Name="TextBlockSelectAll" Margin="10,10, 0, 10"/>
				</StackPanel>
				<StackPanel Name="PanelRemoveForAll" Grid.Column="1" HorizontalAlignment="Right">
					<TextBlock Name="TextBlockRemoveForAll" Margin="10,10, 0, 10"/>
					<CheckBox Name="CheckBoxForAllUsers" IsChecked="False"/>
				</StackPanel>
			</Grid>
			<Border>
				<ScrollViewer>
					<StackPanel Name="PanelContainer" Orientation="Vertical"/>
				</ScrollViewer>
			</Border>
			<Button Name="ButtonUninstall" Grid.Row="2"/>
		</Grid>
	</Window>
"@
	$Form = [Windows.Markup.XamlReader]::Load((New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList $XAML))
	$XAML.SelectNodes("//*[@*[contains(translate(name(.), 'n', 'N'), 'Name')]]") | ForEach-Object -Process {
		Set-Variable -Name ($_.Name) -Value $Form.FindName($_.Name)
	}


	$Window.Title               = $Localization.UWPAppsTitle
	$ButtonUnistall.Content     = $Localization.Uninstall
	$TextBlockRemoveForAll.Text = $Localization.UninstallUWPForAll

	$TextBlockSelectAll.Text    = [WinAPI.GetStrings]::GetString(31276)

	$ButtonUninstall.Add_Click({ButtonUninstallClick})
	$CheckBoxForAllUsers.Add_Click({CheckBoxForAllUsersClick})
	$CheckBoxSelectAll.Add_Click({CheckBoxSelectAllClick})

	function Get-AppxBundle
	{
                [CmdletBinding()]
		param
		(
			[string[]]
			$Exclude,

			[switch]
			$AllUsers
		)

		Write-Information -MessageData "" -InformationAction Continue
		Write-Verbose -Message ([WinAPI.GetStrings]::GetString(12612)) -Verbose

		$AppxPackages = @(Get-AppxPackage -PackageTypeFilter Bundle -AllUsers:$AllUsers | Where-Object -FilterScript {$_.Name -notin $ExcludedAppxPackages})

		$Packages = @(
			"Microsoft.OutlookForWindows",
			"MSTeams",
			"Microsoft.Edge.GameAssist"
		)

		foreach ($Package in $Packages)
		{
			if (Get-AppxPackage -Name $Package -AllUsers:$AllUsers)
			{
				$AppxPackages += Get-AppxPackage -Name $Package -AllUsers:$AllUsers
			}
		}

		$PackageIds = [Windows.Management.Deployment.PackageManager]::new().FindPackage() | Select-Object -Property DisplayName -ExpandProperty Id | Select-Object -Property Name,DisplayName
		foreach ($AppxPackage in $AppxPackages)
		{
			$PackageId = $PackageIds | Where-Object -FilterScript {$_.Name -eq $AppxPackage.Name}

			if (-not $PackageId)
			{
				continue
			}

			[PSCustomObject]@{
				Name              = $AppxPackage.Name
				PackageFullName   = $AppxPackage.PackageFullName
				DisplayName       = $PackageId.DisplayName | Select-Object -First 1
			}

		}
	}

	function Add-Control
	{
                [CmdletBinding()]
		param
		(
			[Parameter(
			        Mandatory = $true,
			        ValueFromPipeline = $true
			)]
			[ValidateNotNull()]
			[PSCustomObject[]]
			$Packages
		)

		process 
		{
			foreach ($Package in $Packages)
			{
				$CheckBox = New-Object -TypeName System.Windows.Controls.Checkbox
				$CheckBox.Tag = $Package.PackageFullName

				$TextBlock = New-Object -TypeName System.Windows.Controls.TextBlock

				if ($Package.DisplayName)
				{
                                        $TextBlock.Text = $Package.DisplayName
				}
				else
				{
					$TextBlock.Text = $Package.Name
				}

				$StackPanel = New-Object -TypeName System.Windows.Controls.StackPanel
				$StackPanel.Children.Add($CheckBox) | Out-Null
				$StackPanel.Children.Add($TextBlock) | Out-Null

				$PanelContainer.Children.Add($StackPanel) | Out-Null

				if ($UncheckedAppxPackages.Contains($Package.Name))
				{
					$CheckBox.IsChecked = $false
				}
				else
				{
					$CheckBox.IsChecked = $true
					$PackageToRemove.Add($Package.PackageFullName)
				}

				$CheckBox.Add_Click ({CheckBoxClick})

			}
		}
	}

	function CheckBoxForAllUsersClick
	{
                $PanelContainer.Children.RemoveRange(0, $PanelContainer.Childrem.Count)
		$PackagesToRemove.Clear()
		$AppXPackage = Get-AppxBundle -Exclude $ExcludedAppxPackages -AllUsers:$CheckBoxForAllUsers.IsChecked
		$AppxPackages | Add-Control

		ButtonUnistallSetIsEnabled
	}

	function ButtonUninstallClick
	{
		Write-Information -MessageData "" -InformationAction Continue
		Write-Verbose -Message ([WinAPI.GetStrings]::GetString(12612)) -Verbose

		$Window.Close() | Out-Null


	        if ($PackagesToRemove -match "MSTeams")
		{
			Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList "/x {A7AB73A3-CB10-4AA5-9D38-6AEFFBDE4C91} /qn" -Wait
		}

		$PackageToRemove | Remove-AppxPackage -AllUsers:$CheckBoxForAllUsers.IsChecked -Verbose
	}

	function CheckBoxClick
	{
                $CheckBox = $_.Source

		if ($CheckBox.IsChecked)
		{
			$PackageToRemove.Add($CheckBox.Tag) | Out-Null
		}
		else
		{
			$PackageToRemove.Remove($CheckBox.Tag)
		}

		ButtonUninstallSetIsEnabled
	}

	function CheckBoxSelectAllClick
	{
		$CheckBox = $_.Source

		if ($CheckBox.IsChecked)
		{
			$PackagesToRemove.Clear()

			foreach ($Item in $PanelContainer.Children.Children)
			{
				if ($Item -is [System.Windows.Controls.CheckBox])
				{
					$Item.IsChecked = $true
					$PackagesToRemove.Add($Item.Tag)
				}
			}
		} 
		else 
		{
			$PackageToRemove.Clear()

			foreach ($Item in $PanelContainer.Children.Children)
			{
				if ($Item -is [System.Windows.Controls.Checkbox])
				{
					$Item.IsChecked = $false
				}
			}
		}

		ButtonUninstallSetIsEnabled
	}

	function ButtonUninstallSetIsEnabled
	{
                if ($PackagesToRemove.Count -gt 0)
		{
			$ButtonUninstall.IsEnabled = $true
		}
		else 
		{
			$ButtonUninstall.IsEnabled = $false
		}
	}

	if ($ForAllUsers)
	{
		$CheckBoxForAllUsers.IsChecked = $true
	}

	$PackagesToRemove = [Collections.Generic.List[string]]:new()
	$AppxPackages = Get-AppxBundle -Exclude $ExcludedAppxPackage -AllUsers:$ForAllUsers
	$AppXPackages | Add-Control

	if ($AppxPackages.Count -eq 0)
	{
		Write-Information -MessageData "" -InformationAction Continue
		Write-Verbose -Message $Localization.NoData -Verbose
	}
	else
	{
		Write-Information -MessageData "" -InformationAction Continue
		Write-Verbose -Message $Localization.DialogBoxOpening -Verbose

		Start-Sleep -Milliseconds 500

		Add-Type -AssemblyName System.Windows.Forms

		Get-Process -Name powershell,WindowTerminal -ErrorAction Ignore
		| Where-Object -FilterScript {$_.MainWindowTitle -match "Script for Windows 11"} | ForEach-Object -Process {
			[WinAPI.ForegroundWindow]::ShowWindowAsync($_.MainWindowHandle, 10)

			Start-Sleep -Seconds 1

			[WinAPI.ForegroundWindow]::SetForegroundWindow($_.MainWindowHandle)

			Start-Sleep -Seconds 1

			[System.Windows.Forms.SendKeys]::SendWait("{BACKSPACE 1}")
		}

		if ($PackageToRemove.Count -gt 0)
		{
			$ButtonUninstall.IsEnable = $true
		}

		$Window.Add_Loaded({$Window.Activate()})
		$Form.ShowDialog() | Out-Null
	}



}
