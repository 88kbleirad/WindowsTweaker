function SnapAssist
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

	New-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name WindowArrangementActive -PropertyType String -Value 1 -Force

	switch ($PSCmdlet.ParameterSetName)
	{
		"Disable"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced -Name SnapAssist -PropertyType  DWord -Value  1 -Force
		}
		"Enable"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced -Name SnapAssist -PropertyType  DWord -Value 1 -Force
		}
	}
}
