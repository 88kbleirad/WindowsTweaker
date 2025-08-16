function PowerPlan
{
	param
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "High"
		)]
		[switch]
		$High,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Balanced"
		)]
		[switch]
		$Balanced
	)

	Remove-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings -Name ActivePowerScheme -Force -ErrorAction Ignore
	Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\Power\PowerSettings -Name ActivePowerScheme -Type DELETE

	switch ($PSCmdlet.ParameterSetName)
	{
		"High"
		{
			POWERCFG /SETACTIVE SCHEME_MIN
		}
		"Balanced"
		{
			POWERCFG /SETACTIVE SCHEME_BALANCED
		}
	}
}
