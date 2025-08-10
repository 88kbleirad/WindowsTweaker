function WindowsTips
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

	Remove-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent -Name DisableSoftLanding -Force -ErrorAction Ignore
	Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\Windows\CloudContent -Name DisableSoftLanding -Type DELETE

	switch ($PSCmdlet.ParameterSetName)
	{
		"Enable"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager -Name SubscribedContent-338389Enabled -PropertyType DWord -Value 1 -Force
		}
		"Disable"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager -Name SubscribedContent-338389Enabled -PropertyType DWord -Value 0 -Force
		}
	}
}


