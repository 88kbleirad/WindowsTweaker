function NumLock
{
	param
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Enable"
		)]
		[switch]
		$Enable,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Disable"
		)]
		[switch]
		$Disable
	)

	switch ($PSCmdlet.ParameterSetName)
	{
		"Enable"
		{
			New-ItemProperty -Path "Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard" -Name InitialKeyboardIndicators -PropertyType String -Value 2147483650 -Force
		}
		"Disable"
		{
			New-ItemProperty -Path "Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard" -Name InitialKeyboardIndicators -PropertyType String -Value 2147483648 -Force
		}
	}
}


