function TaskbarCombine 
{
	param
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Always"
		)]
		[switch]
		$Always,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Full"
		)]
		[switch]
		$Full,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Never"
		)]
		[switch]
		$Never
	)

	Remove-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer,HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer -Name NoTaskGrouping -Force -ErrorAction Ignore
	Set-Policy -Scope Computer -Path SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer -Name NoTaskGrouping -Type DELETE
	Set-Policy -Scope User -Path Software\Microsoft\Windows\CurrentVersion\Policies\Explorer -Name NoTaskGrouping -Type DELETE

	switch ($PSCmdlet.ParameterSetName)
	{
		"Always"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced -Name TaskbarGlomLevel -PropertyType DWord -Value 0 -Force
		}
		"Full"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced -Name TaskbarGlomLevel -PropertyType DWord -Value 1 -Force
		}
		"Never"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced -Name TaskbarGlomLevel -PropertyType DWord -Value 2 -Force
		}
	}
}
