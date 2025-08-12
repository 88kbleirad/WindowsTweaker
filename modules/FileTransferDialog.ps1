function FileTransferDialog
{
	param 
	(
		[Parameter(
		        Mandatory = $true, 
		        ParameterSetName = "Detailed"
		)]
		[switch]
		$Detailed,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Compact"
		)]
		[switch]
		$Compact
	)

	if (-not (Test-Path -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager))
	{ 
                New-Item -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager -Force
	}

	switch ($PSCmdlet.ParameterSetName)
	{
		"Detailed"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager -Name EnthusiastMode -PropertyType DWord -Value 1 -Force
		}
		"Compact"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager -Name EnthusiastMode -PropertyType DWord -Value 0 -Force 
		}
	}
}
