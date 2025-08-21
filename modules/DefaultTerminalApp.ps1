function DefaultTerminalApp
{
	param
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "WindowsTerminal"
		)]
		[switch]
		$WindowsTerminal,

		[Parameter(
		        Mandatory = $true, 
		        ParameterSetName = "ConsoleHost"
		)]
		[switch]
		$ConsoleHost
	)

	switch ($PSCmdlet.ParameterSetName)
	{
		"WindowsTerminal"
		{
			if (Get-AppxPackage -Name Microsoft.WindowsTerminal)
			{
				$TerminalVersion = (Get-AppxPackage -Name Microsoft.WindowsTerminal).Version
				if ([System.Version]$TerminalVersion -ge [System.Version]"1.11")
				{
					if(-not (Test-Path -Path "HKCU:\Console\%%Startup"))
					{
						New-Item -Path "HKCU:\Console\%%Startup" -Force
					}


				}

				$PackageFullName = (Get-AppxPackage -Name Microsoft.WindowsTerminal).PackageFullName
				Get-ChildItem -Path "HKLM:\SOFTWARE\Classes\PackagedCom\Package\$PackageFullName\Class" | ForEach-Object -Process {
					if ((Get-ItemPropertyValue -Path $_.PSPath -Name ServerId) -eq 0)
					{
						New-ItemProperty -Path "HKCU:\Console\%%Startup" -Name DelegationConsole -PropertyType String -Value $_.PSChildName -Force
					}

					if ((Get-ItemPropertyValue -Path $_.PSPath -Name ServerId) -eq 1)
					{
						New-ItemProperty -Path "HKCU:\Console\%%Startup" -Name DelegationTerminal -Value $_.PSChildName -Force
					}
				}
			}
		}
	}
	"ConsoleHost"
	{
		New-ItemProperty -Path "HKCU:\Console\%%Startup" -Name DelegationConsole -PropertyType String -Value "{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}" -Force
		New-ItemProperty -Path "HKCU:\Console\%%Startup" -Name DelegationTerminal -PropertyType String -Value "{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}" -Force
	}
}



