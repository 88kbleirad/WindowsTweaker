function AutoPlay
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

	Remove-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer,HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer -Name NoDriveTypeAutoRun -Force -ErrorAction Ignore

	Set-Policy -Scope Computer -Path SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer -Name NoDriveTypeAutoRun -Type DELETE
	Set-Policy -Scope User -Path Software\Microsoft\Windows\CurrentVersion\Policies\Explorer -Name NoDriveTypeAutoRun -Type DELETE

	switch ($PSCmdlet.ParameterSetName)
	{
		"Disable"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers -Name DisableAutoPlay -PropertyType DWord -Value 1 -Force
		}
		"Enable"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers -Name DisableAutoPlay -PropertyType DWord -Value 0 -Force
		}
	}
}
