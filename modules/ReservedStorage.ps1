function ReservedStorage 
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

	switch ($PSCmdlet.ParameterSetName)
	{
		"Disable"
		{
			try 
			{
				Set-WindowsReservedStorageState -State Disabled
			}
			catch [System.Runtime.InteropServices.COMException]
			{
				Write-Warning -Message ($Localization.ReservedStorageIsInUse -f $MyInvocation.Line.Trim())
				Write-Error -Message ($Localization.ReversedStorageIsInUse -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue
			}
		}
		"Enable"
		{
			Set-WindowsReservedStorageState -State Enabled
		}
	}
}
