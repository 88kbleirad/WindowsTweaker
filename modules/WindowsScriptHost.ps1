function WindowsScriptHost
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
			Get-ScheduledTask -TaskName SoftwareDistribution,Temp, "Window Cleanup", "Window Cleanup Notification" -ErrorAction Ignore | ForEach-Object -Process {
				if($_.State -eq "Ready")
				{
					Write-Information -MessageData "" -InformationAction Continue
					Write-Verbose -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -Verbose
					Write-Error -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue

					break
				}
			}

			if (-not (Test-Path -Path "HKCU:\Software\Microsoft\Windows Script Host\Settings"))
			{
				New-Item -Path "HKCU:\Software\Microsoft\Windows Script Host\Settings" -Name Enabled -PropertyType DWord -Value 0 -Force
			}

			New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows Script Host\Settings" -Name Enabled -PropertyType DWord -Value 0 -Force
		}
		"Enable"
		{
			Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows Script Host\Settings" -Name Enabled -Force -ErrorAction Ignore
		}
	}
}
