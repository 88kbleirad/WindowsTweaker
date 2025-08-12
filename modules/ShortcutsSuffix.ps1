function ShortcutsSuffix
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

	Remove-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer -Name link -Force -ErrorAction Ignore

	switch ($PSCmdlet.ParameterSetName)
	{
		"Disable"
		{
			if(-not (Test-Path -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\NamingTemplates))
			{
				New-Item -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\NamingTemplates -Force
			}
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\NamingTemplates -Name ShortcutNameTemplate -PropertyType String -Value "%s.lnk" -Force
		}
		"Enable"
		{
			Remove-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\NamingTemplate -Name ShortcutNameTemplate -Force -ErrorAction Ignore
		}
	}
}
