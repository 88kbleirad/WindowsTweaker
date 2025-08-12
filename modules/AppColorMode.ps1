function AppColorMode
{
	param 
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Dark"
		)]
		[switch]
		$Dark,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Light"
		)]
		[switch]
		$Light
	)

	switch ($PSCmdlet.ParameterSetName)
	{
		"Dark"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize -Name AppsUseLightTheme -PropertyType DWord -Value 0 -Force
		}
		"Light"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize -Name AppsUseLightTheme -PropertyType DWord -Value 1 -Force
		}
	}
}


