function Install-DotNetRuntimes
{
	[CmdletBinding()]
	param
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Runtimes"
		)]
		[ValidateSet("NET8x64", "NET9x64")]
		[string[]]
		$Runtimes
	)

	$DownloadsFolder = Get-ItemPropertyValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -Name "{374DE290-123F-4565-9164-39C4925E467B}"

	foreach ($Runtime in $Runtimes)
	{
		switch ($Runtime)
		{
		        Net8x64
			{
				try
				{
					$Parameters = @{
						Uri             = "https://builds.dotnet.microsoft.com/dotnet/release-metadata/8.0/releases.json"
						Verbose         = $true
						UseBasicParsing = $true
					}
					$LatestNET8Version = (Invoke-RestMethod @Parameters)."latest-release"
				}
				catch [System.Net.WebException]
				{
                                        Write-Warning -Message ($Localization.NoResponse -f "https://download.visualstudio.microsoft.com")
					Write-Error -Message ($Localization.NoResponse -f "https://download.visualstudio.microsoft.com") -ErrorAction SilentlyContinue
					Write-Error -Message ($Localization.RestartFunction -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue

					return
				}

				if (Test-Path -Path "$env:ProgramData\Package Cache\*\dotnet-runtime-$LatestNET8Version-win-x64.exe")
				{
					$CurrentNET8Version = (Get-Item -Path "$env:ProgramData\Package Cache\*\dotnet-runtime-$LatestNET8Version-win-x64.exe").VersionInfo.FileVersion
					$CurrentNET8Version = "{0}.{1}.{2}" -f $CurrentNET8Version.Split(".")
				}
				else 
				{
					$CurrentNET8Version = "0.0"
				}

				if (([System.Version]$LatestNET8Version -gt [System.Version]$CurrentNET8Version) -or ($CurrentNET8Version -eq "0.0"))
				{
					try 
					{
						
	                                        $Parameters = @{
							Uri             = "https://builds.dotnet.microsoft.com/dotnet/Runtime/$LatestNET8Version/dotnet-runtime-$LatestNET8Version-win-x64.exe"
							OutFile         = "$DownloadsFolder\dotnet-runtime-$LatestNET8Version-win-x64.exe"
							UseBasicParsing = $true
							Verbose         = $true
						}
						Invoke-WebRequest @Parameters
					}
					catch [System.Net.WebException]
					{
						Write-Warning -Message ($Localization.NoResponse -f "https://builds.dotnet.microsoft.com")
						Write-Error -Message ($Localization.NoResponse -f "https://builds.dotnet.microsoft.com") -ErrorAction SilentlyContinue
						Write-Error -Message ($Localization.RestartFunction -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue

						return
					}

					Write-Information -MessageData "" -InformationAction Continue
					Write-Verbose -Message ".NET $LatestNET8Version" -Verbose
					Write-Information -MessageData "" -InformationAction Continue

					Start-Process -FilePath "$DownloadsFolder\dotnet-runtime-$LatestNET8Version-win-x64.exe"-ArgumentList "/install /passive /norestart"-Wait

					$Paths = @(
						"$DownloadsFolder\dotnet-runtime-$LatestNET8Version-win-x64.exe",
						"$env:TEMP\Microsoft_.NET_Runtime*.log"
					)
					Get-ChildItem -Path $Paths -Force -ErrorAction Ignore | Remove-Item -Force -ErrorAction Ignore
				}
				else 
				{
					Write-Information -MessageData "" -InformationAction Continue
					Write-Verbose -Message ($Localization.Skipped -f ("{0} -{1} {2}" -f $MyInvocation.MyCommand.Name, $MyInvocation.BoundParameters.Keys.Trim(), $_)) -Verbose
					Write-Error -Message ($Localization.Skipped -f ("{0} -{1} {2}" -f $MyInvocation.MyCommand.Name, $MyInvocation.BoundParameters.Keys.Trim(), $_)) -ErrorAction SilentlyContinue
				}
			}
			NET9x64
			{
				try
				{
					$Parameters = @{
						Uri     = "https://builds.dotnet.microsoft.com/dotnet/release-metadata/9.0/releases.json"
						Verbose = $true
						UseBasicParsing = $true
					}
					$LatestNET9Version = (Invoke-RestMethod @Parameters)."latest-release"
				}
				catch [System.Net.WebException]
				{
					Write-Warning -Message ($Localization.NoResponse -f "https://download.visualstudio.microsoft.com")
					Write-Error -Message ($Localization.NoResponse -f "https://download.visualstudio.microsoft.com") -ErrorAction SilentlyContinue
					Write-Error -Message ($Localization.RestartFunction -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue

					return
				}


				if (Test-Path -Path "$env:ProgramData\Package Cache\*\dotnet-runtime-$LatestNET9Version-win-x64.exe")
				{
					$CurrentNET9Version = (Get-Item -Path "$env:ProgramData\Package Cache\*\dotnet-runtime-$LatestNET9Version-win-x64.exe").VersionInfo.FileVersion
					$CurrentNET9Version = "{0}.{1}.{2}" -f $CurrnetNET9Version.Split(".")
				}
				else 
				{
					$CurrentNET9Version = "0.0"
				}

				if (([System.Version]$LatestNET9Version -gt [System.Version]$CurrentNET9Version) -or ($CurrentNET9Version -eq "0.0"))
				{
					try
					{
					        $Parameters = @{
							Uri             = "https://builds.dotnet.microsoft.com/dotnet/Runtime/$LatestNET9Version/dotnet-runtime-$LatestNET9Version-win-x64.exe"
							OutFile         = "$DownloadsFolder\dotnet-runtime-$LatestNET9Version-win-x64.exe"
							UseBasicParsing = $true
							Verbose         = $true
						}
						Invoke-WebRequest @Parameters	
					}
					catch [System.Net.WebException]
					{
						Write-Warning -Message ($Localization.NoResponse -f "https://builds.dotnet.microsoft.com")
						Write-Error -Message ($Localization.NoResponse -f "https://builds.dotnet.microsoft.com") -ErrorAction SilentlyContinue
						Write-Error -Message ($Localization.RestartFunction -f $MyInvocation.Line.Trim()) -ErrorAction SilentyContinue

						return
					}

					Write-Information -MessageData "" -InformationAction Continue
					Write-Verbose -Message ".NET $LatestNET9Version" -Verbose
					Write-Information -MessageData "" -InformationAction Continue

					Start-Process -FilePath "$DownloadsFolder\dotnet-runtime-$LatestNET9Version-win-x64.exe" -ArgumentList "/install /passive /norestart" -Wait

                                   	$Paths = @(
						"$DownloadsFolder\dotnet-runtime-$LatestNET9Version-win-x64.exe",
						"$env:TEMP\Microsoft_.NET_Runtime*.log"
					)
					Get-ChildItem -Path $Paths -Force -ErrorAction Ignore | Remove-Item -Force -ErrorAction Ignore
				}
				else 
				{
					Write-Information -MessageData "" -InformationAction Continue
					Write-Verbose -Message ($Localization.Skipped -f ("{0} -{1} {2}" -f $MyInvocation.MyCommand.Name, $MyInvocation.BoundParameters.Keys.Trim(), $_)) -Verbose
					Write-Error -Message ($Localization.Skipped -f ("{0} -{1} {2}" -f $MyInvocation.MyCommand.Name, $MyInvocation.BoundParameters.Keys.Trim(), $_)) -ErrorAction SilentlyContinue
				}
			}
		}
	}
}


