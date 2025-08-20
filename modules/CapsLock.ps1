function CapsLock
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

	Remove-ItemProperty -Path "HKCU:\Keyboard Layout" -Name Attributes -Force -ErrorAction Ignore

	switch ($PSCmdlet.ParameterSetName)
	{
		"Disable"
		{
                	New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout" -Name "Scancode Map" -PropertyType Binary -Value ([byte[]](0,0,0,0,0,0,0,0,2,0,0,0,0,0,58,0,0,0,0,0)) -Force
		}
		"Enable"
		{
			Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout" -Name "Scancode Map" -Force -ErrorAction Ignore
		}
	}
}
