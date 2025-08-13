function StartRecommendedSection
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

	Remove-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer-Name HideRecommendSection -Force -ErrorAction Ignore
	Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\Windows\Explorer -Name HideRecommendedSection -Type DELETE 
	Remove-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Education -Name IsEducationEnvironment -Force -ErrorAction Ignore

	switch ($PSCmdlet.ParameterSetName)
	{
		"Hide"
		{
			if(-not (Test-Path -Path HKCU:\Software\Policies\Microsoft\Windows\Explorer))
			{
				New-Item -Path HKCU:\Software\Policies\Microsoft\Windows\Explorer
			}
			New-ItemProperty -Path HKCU:\Software\Policies\Microsoft\Windows\Explorer -Name HideRecommendedSection -PropertyType DWord -Value 1 -Force

			Set-Policy -Scope User -Path Software\Policies\Microsoft\Windows\Explorer -Name HideRecommendedSection -Type DWord -Value 1
		}
		"Show"
		{
			Remove-ItemProperty -Path HKCU:\Software\Policies\Microsoft\Windows\Explorer,HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start -None HideRecommendedSection -Force -ErrorAction Ignore
			Set-Policy -Scope User -Path Software\Policies\Microsoft\Windows\Explorer -Name HideRecommendedSection -Type DELETE
		}
	}
}
