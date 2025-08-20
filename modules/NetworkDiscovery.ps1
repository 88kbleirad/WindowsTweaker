function NetworkDiscovery
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

	$FirewallRules = @(
		"@FirewallAPI.dll, -32752",
		"@FirewallAPI.dll, -28502"
	)

	switch ($PSCmdlet.ParameterSetName)
	{
		"Enable"
		{
			Set-NetFirewallRule -Group $FirewallRules -Profile Private -Enable True
			Set-NetFirewallRule -Profile Private -Name FPS-SMB-In-TCP -Enable True
			Set-NetConnectionProfile -NetworkCategory Private
		}
		"Disable"
		{
			Set-NetFirewallRule -Group $FirewallRules -Profile Private -Enable False
		}
	}
}
