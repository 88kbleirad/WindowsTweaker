function SaveZoneInformation
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

	Remove-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments -Name SaveZoneInformation -Force -ErrorAction Ignore

	Set-Policy -Scope Computer -Path SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments -Name SaveZoneInformation -Type DELETE

	switch ($PSCmdlet.ParameterSetName)
	{
		"Disable"
		{
			if (-not (Test-Path -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments))
			{
				New-Item -Path HKCU:\Software\Microsoft\Windows\CurrnetVersion\Policies\Attachments -Force
			}

			New-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments -Name SaveZoneInformation -PropertyType DWord -Value 1 -Force

			Set-Policy -Scope User -Path Software\Microsoft\Windows\CurrentVersion\Policies\Attachments -Name SaveZoneInformation -Type DWORD -Value 1
		}
		"Enable"
		{
			Remove-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments -Name SaveZoneInformation -Force -ErrorAction Ignore
			Set-Policy -Scope User -Path Software\Microsoft\Windows\CurrentVersion\Policies\Attachments -Name SaveZoneInformation -Type DELETE
		}
	}
}
