function WindowsSandbox
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

	$EditionID = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").EditionID
	if (($EditionID -notmatch "Professional") -and ($EditionID -notmatch "Enterprise") -and ($EditionID -notmatch "Education"))
	{
		Write-Information -MessageData "" -InformationAction Continue
		Write-Verbose -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -Verbose
		Write-Error -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue

		return
	}

	switch ($PSCmdlet.ParameterSetName)
	{
		"Disable"
		{
			if ((Get-CimInstance -ClassName CIM_Processor).VirtualizationFirmwareEnabled)
			{
				Disable-WindowsOptionalFeature -FeatureName Containers-DisposableClientVM -Online -NoRestart
			}
			else 
			{
				try 
				{
					if ((Get-CimInstance -ClassName CIM_ComputerSystem).HypervisorPresent)
					{
						Disable-WindowsOptionalFeature -FeatureName Container-DisposableClientVM
			                        -Online -NoRestart
					}
				}
				catch [System.Exception]
				{
					Write-Error -Message $Localization.EnableHardwareVT -ErrorAction SilentlyContinue
					Write-Error -Message ($Localization.RestartFunction -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue
				}
			}
		}
		"Enable"
		{
			if ((Get-CimInstance -ClassName CIM_Processor).VirtualizationFirmwareEnabled)
			{
				Enable-WindowsOptionalFeature -FeatureName Containers-DisposableClientVM -All -Online -NoRestart
			}
			else 
			{
                                try 
				{
					if ((Get-CimInstance -ClassName CIM_ComputerSystem).HypervisorPresent)
					{
						Enable-WindowsOptionalFeature -FeatureName Containers-DisposableClientVM -All -Online -NoRestart
					}
				}
				catch [System.Exception]
				{
					Write-Error -Message $Localization.EnableHardwareVT -ErrorAction SilentlyContinue
					Write-Error -Message ($Localization.RestartFunction -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue
				}
			}
		}
	}
}
