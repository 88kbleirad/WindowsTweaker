function ErrorReporting
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

	Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting", "HKCU:\Software\Policies\Microsoft\Windows\Windows Error Reporting" -Name Disable -Force -ErrorAction Ignore

	Set-Policy -Scope Computer -Path "SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" -Name Disabled -Type DELETE

	Set-Policy -Scope User -Path "Software\Policies\Microsoft\Windows\Windows Error Reporting" -Name Disabled -Type DELETE

	switch ($PSCmdlet.ParameterSetName)
	{
		"Disable"
		{
			Get-ScheduledTask -TaskName QueueReporting -ErrorAction Ignore | Disable-ScheduledTask
			New-ItemProperty -Path "HKCU:Software\Microsoft\Windows\Windows Error Reporting" -Name Disabled -PropertyType DWord -Value 1 -Force
			Get-Service -Name WerSvc | Stop-Service -Force
			Get-Service -Name WerSvc | Set-Service -StartupType Disable d
		}
		"Enable"
		{
                	Get-ScheduledTask -TaskName QueueReporting -ErrorAction Ignore | Enable-ScheduledTask
			Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\Windows Error Reporting" -Name Disabled -Force -ErrorAction Ignore

			Get-Service -Name WerSvc | Set-Service -StartupType Manual
			Get-Service -Name WerSvc | Start-Service
		}
	}
}
