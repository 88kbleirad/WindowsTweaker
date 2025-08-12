function TailoredExperiences
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

	Remove-ItemProperty -Path HKCU:\Software\Policies\Microsoft\Windows\CloudContent -Name DisableTailoredExperiencesWithDiagnosticData -Force -ErrorAction
	Ignore
	Set-Policy -Scope User -Path Software\Policies\Microsoft\Windows\CloudContent -Name DisableTailoredExperiencesWithDiagnosticData -Type DELETE
       
	switch ($PSCmdlet.ParameterSetName)
	{
		"Disable"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy -Name TailoredExperiencesWithDiagnosticDataEnabled -PropertyType DWord -Value 0 -Force
		}
		"Enable"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy -Name TailoredExperiencesWithDiagnosticDataEnabled -PropertyType DWord -Value 1 -Force
		}
	}

}
