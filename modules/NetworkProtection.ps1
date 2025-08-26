function NetworkProtection
{
	param
	(
		[Parameter(
		        Mandatory = $true, 
		        ParameterSetName = "Enable"
		)]
		[switch]
		$Enable,

		[Parameter(
		        Mandatory = $true, 
		        ParameterSetName = "Disable"
		)]
		[switch]
		$Disable
	)

	if ((-not $Script:DefenderEnabled) -or $Script:DefenderMpPreferenceBroken)
	{
		Write-Information -MessageData "" -InformationAction Continue
		Write-Verbose -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -Verbose
		Write-Error -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue

		return
	}

	switch ($PSCmdlet.ParameterSetName)
	{
		"Enable"
		{
			Set-MpPreference -EnableNetworkProtection Enabled
		}
		"Disable"
		{
			Set-MpPreference -EnableNetworkProtection Disabled
		}
	}
}
