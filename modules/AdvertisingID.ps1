function AdvertisingID 
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


	Remove-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo -Name DisabledByGroupPolicy -Force -ErrorAction Ignore

	Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\Windows\DataCollection -Name DisabledByGroupPolicy -Type DELETE


	if(-not (Test-Path -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo))
	{
		New-Item -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo -Force
	}

	switch ($PSCmdlet.ParameterSetName)
	{
		"Disable"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo -Name Enabled -PropertyType DWord -Value 0 -Force
		}
		"Enable"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo -Name Enabled -PropertyType DWord -Value 1 -Force
		}
	}
}


