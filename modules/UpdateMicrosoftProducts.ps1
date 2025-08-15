function UpdateMicrosoftProducts
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

	Remove-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU -Name AllowMUUpdateService -Force -ErrorAction Ignore
	Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU -Name AllowMUUpdateService -Type DELETE

	switch ($PSCmdlet.ParameterSetName)
	{
		"Enable"
		{
			New-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings -Name AllowMUUpdateService -PropertyType DWord -Value 1 -Force
		}
		"Disable"
		{
			Remove-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings -Name AllowMUUpdateService -Force -ErrorAction Ignore
		}
	}
}
