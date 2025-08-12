function ControlPanelView
{
	param
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Category"
		)]
		[switch]
		$Category,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "LargeIcons"
		)]
		[switch]
		$LargeIcons,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "SmallIcons"
		)]
		[switch]
		$SmallIcons
	)

	Remove-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer -Name ForceClassicControlPanel -Force -ErrorAction Ignore
	Set-Policy -Scope User -Path Software\Microsoft\Windows\CurrentVersion\Policies\Explorer -Name ForceClassisControlPanel -Type DELETE

	if(-not (Test-Path -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel))
	{
		New-Item -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel -Force
	}

	switch ($PSCmdlet.ParameterSetName)
	{
		"Category"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel -Name AllItemsIconView -PropertyType DWord -Value 0 -Force
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel -Name StartupPage -PropertyType DWord -Value 0 -Force
		}
		"LargeIcons"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel -Name AllItemsIconView -PropertyType DWord -Value 0 -Force
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel -Name StartupPage -PropertyType DWord -Value 1 -Force
		}
		"SmallIcons"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel -Name AllItemsIconView -PropertyType DWord -Value 1 -Force
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel -Name StartupPage -PropertyType DWord -Value 1 -Force
		}
	}
}
