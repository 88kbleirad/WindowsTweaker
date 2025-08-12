function OpenFileExplorerTo
{
	param
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "ThisPC"
		)]
		[switch]
		$ThisPC,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "QuickAccess"
		)]
		[switch]
		$QuickAccess
	)

	switch ($PSCmdlet.ParameterSetName)
	{
		"ThisPC"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced -Name LaunchTo -PropertyType DWord -Value 1 -Force
		}
		"QuickAccess"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced -Name LaunchTo -PropertyType DWord -Value 2 -Force
		}
	}
}
