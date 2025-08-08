function FeedbackFrequency
{
	param 
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Never"
		)]
		[switch]
		$Never,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Automatically"
		)]
		[switch]
		$Automatically
	)

	switch ($PSCmdlet.ParameterSetName)
	{
		"Never"
		{
			if (-not (Test-Path -Path HKCU:\Software\Microsoft\Siuf\Rules))
			{
				New-Item -Path HKCU:\Software\Microsoft\Siuf\Rules -Force
			}
			New-ItemProperty -Path HKCU:\Software\Microsoft\Siuf\Rules -Name NumberOfSIUFInPeriod -PropertyType DWord -Value 0 -Force

			Remove-ItemProperty -Path HKCU:\Software\Microsoft\Siuf\Rules -Name PeriodInNanoSeconds -Force -ErrorAction Ignore
		}
		"Automatically"
		{
			Remove-ItemProperty -Path HKCU:\Software\Microsoft\Siuf\Rules -Name PeriodInNanoSeconds,NumberOfSIUFInPeriod -Force -ErrorAction Ignore
		}
	}
}
