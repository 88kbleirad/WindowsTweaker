function JPEGWallpapersQuality 
{
	param
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Max"
		)]
		[switch]
		$Max,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Default"
		)]
		[switch]
		$Default
	)

	switch ($PSCmdlet.ParameterSetName)
	{
		"Max"
		{
			New-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name JPEGImportQuality -PropertyType DWord -Value 100 -Force
		}
		"Default"
		{
			Remove-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name JPEGImportQuality -Force -ErrorAction Ignore
		}
	}
}
