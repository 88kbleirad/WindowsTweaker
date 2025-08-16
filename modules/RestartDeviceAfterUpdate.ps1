function RestartDeviceAfterUpdate
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

	Remove-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate -Name ActiveHoursEnd,ActiveHoursStart,SetActiveHours -Force -ErrorAction Ignore
	Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate -Name ActiveHoursEnd -Type DELETE
	Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate -Name ActiveHoursStart -Type DELETE
	Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate -Name SetActiveHours -Type DELETE

	switch ($PSCmdlet.ParameterSetName)
	{
		"Enable"
		{
			New-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings -Name IsExpedited -PropertyType DWord -Value 1 -Force
		}
		"Disable"
		{
			New-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings -Name IsExpedited -PropertyType DWord -Value 0 -Force
		}
	}
}
