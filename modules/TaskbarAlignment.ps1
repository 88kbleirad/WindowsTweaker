function TaskbarAlignment 
{
	param
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Left"
		)]
		[switch]
		$Left,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Center"
		)]
		[switch]
		$Center
	)

	switch ($PSCmdlet.ParameterSetName)
	{ 
                "Center"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced -Name TaskbarAl -PropertyType DWord -Value 1 -Force
		}
		"Left"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced -Name TaskbarAl -PropertyType DWord -Value 0 -Force
		}
	}
}
