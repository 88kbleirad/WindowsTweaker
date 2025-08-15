function WindowsFeatures
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

	$SelectedFeatures = New-Object -TypeName System.Collections.ArrayList($null)

	[string[]]$CheckedFeatures = @(
		"LegacyComponents",

		"MicrosoftWindowsPowerShellV2",
		"MicrosoftWindowsPowerShellV2Root",

		"Printing-XPSServices-Features",

		"Recall",
		"WorkFolders-Client"

	)

	[string[]]$UncheckedFeatures = @(
		"MediaPlayback"
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
	$XAML.SelectNodes("//*[@*[contains(translate(name(.), 'n', 'N'), 'Name')]]")| ForEach-Object -Process {
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

		$Feature = $Features } | Where-Object -FilterScript {$_.DisplayName -eq $CheckBox.Parent.Children[1].Text}

	        if ($CheckBox.IsChecked)
	        {
                        [void]$SelectedFeature.Add($Feature)
	        }
	        else
	        {
                        [void]$SelectedFeature.Remove($Feature)
	        }
	        if ($SelectedFeatures.Count -gt 0)
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

	        $SelectedFeatures | ForEach-Object -Process {Write-Verbose -Message$_.DisplayName -Verbose}
	        $SelectedFeatures | Disable-WindowsOptionalFeature -Online -NoRestart 
        }

        function EnableButton
	{
                Write-Information -MessageData "" -InformationAction Continue
	        Write-Verbose -Message ([WinAPI.GetStrings]::GetString(12612)) -Verbose

	        [void]$Window.Close()

	        $SelectedFeatures | ForEach-Object -Process {Write-Verbose -Message $_.DisplayName -Verbose}
	        $SelectedFeatures | Enable-WindowsOptionalFeature -Online -All -NoRestart
        }

        function Add-FeatureControl
	{
                [CmdletBinding()]
		param 
		(
                        [Parameter(
		                Mandatory = $true,
		                ValueFromPipeline = $true
		         )]
		        [ValidateNotNull()]
		        $Feature
	        )
	         
	        process
	        {
                        $CheckBox = New-Object -TypeName System.Windows.Controls.CheckBox
		        $CheckBox.Add_Click({Get-CheckboxClicked -CheckBox $_.Source})
		        $CheckBox.ToolTip = $Feature.Description

		        $TextBlock = New-Object -TypeName System.Windows.Controls.TextBlock
		        $TextBlock.Text = $Feature.DisplayName
		        $TextBlock.ToolTip = $Feature.Description
		        
		        $StackPanel = New-Object -TypeName System.Windows.Controls.StackPanel
		        [void]$StackPanel.Children.Add($CheckBox)
		        [void]$StackPanel.Children.Add($TextBlock)
		        [void]$PanelContainer.Children.Add($StackPanel)

		        $CheckBox.IsChecked = $true

		        if($UnCheckedFeatures | Where-Object -FilterScript {$Feature.FeatureName -like $_})
		        {
                                $CheckBox.IsChecked = $false
			        return
		        }
		        [void]$SelectedFeatures.Add($Feature)
	        }
        }
        switch ($PSCmdlet.ParameterSetName)
        {
                "Enable"
	        {
                        $State = @("Disabled", "DisablePending")
		        $ButtonContent = $Localization.Enable
		        $ButtonAdd_Click = {EnableButton}
	        }
	        "Disable"
	        {
                        $State = @("Enabled", "EnablePending")
		        $ButtonContent = $Localization.Disable
		        $ButtonAdd_Click = {DisableButton}
	        }
        }

        Write-Information -MessageData "" -InformationAction Continue
        Write-Verbose -Message ([WinAPI.GetStrings]::GetString(12612)) -Verbose

        $OFS = "|"
        $Features = Get-WindowsOptionalFeatures -Online | Where-Object -FilterScript {
	        ($_.State -in $State) -and (($_.FeatureName -match $UncheckedFeatures) -or ($_.FeatureName -match $CheckFeatures))
	} | ForEach-Object -Process {Get-WindowsOptionalFeature -FeatureName $_.FeatureName -Online}

        $OFS = " "
         
        if (-not $Features)
        {
                Write-Information -MessageData "" -InformationAction Continue
	        Write-Verbose -Message $Localization.NoData -Verbose

	        return
        }
          
        Write-Information -MessageData "" -InformationAction Continue
        Write-Verbose -Message $Localization.DialogBoxOpening -Verbose

        Start-Sleep -Milliseconds 500

        Add-Type -AssemblyName System.Windows.Forms
          
        Get-Process -Name powershell,WindowsTerminal -ErrorAction Ignore | Where-Object -FilterScript {$_.MainWindowTitle -match "Script for Windows 11"} | ForEach-Object -Process {
	        [WinAPI.ForegroundWindow]::ShowWindowAsync($_.MainWindowHandle, 10)

	        Start-Sleep -Seconds 1
	        
	        [WinAPI.ForegroundWindow]::SetForegroundWindow($_.MainWindowHandle)

	        Start-Sleep -Seconds 1
	         
	        [System.Windows.Forms.SendKeys]::SendWait("{BACKSPACE 1}")
	}
        
        $Window.Add_Loaded({$Features | Add-FeatureControl})
        $Button.Content = $ButtonContent
        $Button.Add_Click({& $ButtonAdd_Click})

        $Window.Title = $Localization.WindowsFeatureTitle

        $Window.Add_Loaded({$Window.Activate()})

        $Form.ShowDialog() | Out-Null
}
