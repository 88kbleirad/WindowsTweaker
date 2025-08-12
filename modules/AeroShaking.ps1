function AeroShaking
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

	Remove-ItemProperty -Path HKCU:\Software\Policies\Microsoft\Windows\Explorer,HKLM:\Software\Policies\Microsoft\Windows\Explorer -Name NoWindowMinimizingShortcuts -Force -ErrorAction Ignore
	Set-Policy -Scope User -Path Software\Policies\Microsoft\Windows\Explorer -Name NoWindowMinimizingShortcuts -Type DELETE
	Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\Windows\Explorer -Name NoWindowMinimizingShortcuts -Type DELETE

	switch ($PSCmdlet.ParameterSetName)
	{
		"Enable"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced -Name DisallowShaking -PropertyType DWord -Value 0 -Force
		}
		"Disable"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced -Name DisallowShaking -PropertyType DWord -Value 0 -Force
		}
	}
}
