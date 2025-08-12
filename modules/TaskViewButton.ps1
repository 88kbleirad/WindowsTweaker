function TaskViewButton 
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

	Remove-ItemProperty -Path HKCU:\Software\Policies\Microsoft\Windows\Explorer,HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer -Name HideTaskViewButton -Force -ErrorAction Ignore
	Set-Policy -Scope User -Path Software\Policies\Microsoft\Windows\Explorer -Name HideTaskViewButton -Type DELETE
	Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\Windows\Explorer -Name HIdeTaskViewButton -Type DELETE

	switch ($PSCmdlet.ParameterSetName)
	{
		"Hide"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced -Name ShowTaskViewButton -PropertyType DWord -Value 0 -Force
		}
		"Show"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced -Name ShowTaskViewButton -PropertyType DWord -Value 1 -Force
		}
	}
}
