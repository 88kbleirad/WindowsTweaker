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


}
