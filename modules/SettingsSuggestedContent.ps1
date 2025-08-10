function SettingsSuggestedContent
{
	param
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Hide"
		)]
		[switch]
		$Hide,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Show"
		)]
		[switch]
		$Show
	)

	switch ($PSCmdlet.ParameterSetName)
	{
		"Hide"
		{
                        New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager -Name SubscribedContent-338393Enabled -PropertyType DWord -Value 0 -Force
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager -Name SubscribedContent-353694Enabled -PropertyType DWord -Value 0 -Force
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager -Name SubscribedContent-353696Enabled -PropertyType DWord -Value 0 -Force
		}
		"Show"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager -Name SubscribedContent-338393Enabled -PropertyType DWord -Value 1 -Force
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager -Name SubscribedContent-353694Enabled -PropertyType DWord -Value 1 -Force
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager -Name SubscribedContetn-353696Enabled -PropertyType DWord -Value 1 -Force
		}
	}
}
