function AppsSilentInstalling
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

	Remove-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent -Name DisableWindowsConsumerFeatures -Force -ErrorAction Ignore
	Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\Windows\CloudContent -Name DisableWindowsConsumerFeatures -Type DELETE

	switch ($PSCmdlet.ParameterSetName)
	{
		"Disable"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager -Name SilentInstalledAppsEnabled -PropertyType DWord -Value 0 -Force
		}
		"Enable"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager -Name SilentInstalledAppsEnabled -PropertyType DWord -Value 1 -Force
		}
	}
}
