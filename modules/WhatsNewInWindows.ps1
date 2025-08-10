function WhatsNewInWindows
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

	if (-not (Test-Path -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement))
	{
		New-Item -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement -Force
	}

	switch ($PSCmdlet.ParameterSetName)
	{
		"Disable"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement -Name ScoobeSystemSettingEnabled -PropertyType DWord -Value 0 -Force
		}
		"Enable"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement -Name ScoobeSystemSettingEnabled -PropertyType DWord -Value 1 -Force
		}
	}
}
