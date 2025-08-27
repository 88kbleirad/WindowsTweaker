function UseStoreOpenWith
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

	Remove-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer-Name NoUseStoreOpenWith -Force -ErrorAction Ignore
	Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\Windows\Explorer -Name NoUseStoreOpenWith -Type DELETE

	switch ($PSCmdlet.ParameterSetName)
	{
		"Hide"
		{
			if (-not (Test-Path -Path HKCU:\Software\Policies\Microsoft\Windows\Explorer))
			{
				New-Item -Path HKCU:\Software\Policies\Microsoft\Windows\Explorer -Force
			}

			New-ItemProperty -Path HKCU:\Software\Policies\Microsoft\Windows\Explorer -Name NoUseStoreOpenWith -PropertyType DWord -Value 1 -Force

			Set-Policy -Scope User -Path Software\Policies\Microsoft\Windows\Explorer -Name NoUseStoreOpenWith -Type DWORD -Value 1
		}
		"Show"
		{
			Remove-ItemProperty -Path HKCU:\Software\Policies\Microsoft\Windows\Explorer -Name NoUseStoreOpenWith -Force -ErrorAction Ignore
			Set-Policy -Scope User -Path Software\Policies\Microsoft\Windows\Explorer -Name NoUseStoreOpenWith -Type DELETE
		}
	}
}
