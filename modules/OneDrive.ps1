function OneDrive
{
	param
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Uninstall"
		)]
		[switch]
		$Uninstall,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Install"
		)]
		[switch]
		$Install,

		[switch]
		$AllUsers
	)

	Remove-ItemProperty -Path HKLM:\Policies\Microsoft\Windows\OneDrive -Name DisableFileSyncNGSC -Force -ErrorAction Ignore
	Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\Windows\OneDrive -Name DisableFileSyncNGSC -Type DELETE

	switch ($PSCmdlet.ParameterSetName)
	{
		"Uninstall"
		{
			[xml]$UninstallString = Get-Package -Name "Microsoft OneDrive" -ProviderName Programs -ErrorAction Ignore | ForEach-Object -Process {$_.SwidTagText}
			[string]$UninstallString = $UninstallString.SoftwareIdentity.Meta.UninstallString

			if(-not $UninstallString)
			{
				Write-Information -MessageData "" -InformationAction Continue
				Write-Verbose -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -Verbose
				Write-Error -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue

				return
			}

			$UserEmail = Get-ItemProperty -Path HKCU:\Software\Microsoft\OneDrive\Accounts\Personal -Name UserEmail -ErrorAction Ignore
			if($UserEmail)
			{
				Write-Information -MessageData "" -InformationAction Continue
				Write-Verbose -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -Verbose
				Write-Error -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue

				return
			}

			Write-Information -MessageData "" -InformationAction Continue 
			Write-Verbose -Message $Localization.OneDriveUninstalling -Verbose
			Stop-Process -Name OneDrive,OneDriveSetup,FileCoAuth -Force
			-ErrorAction Ignore
                                                                      
			[string[]]$OneDriveSetup = ($UninstallString -replace("\*/",",/")).Split(",").Trim()
			Start-Process -FilePath $OneDriveSetup[0] -ArgumentList $OneDriveSetup[1..$OneDriveSetup.Count] -Wait

			if(Test-Path -Path $env:OneDrive)
			{
				if((Get-Children -Path $env:OneDrive -ErrorAction Ignore | Measure-Object).Count -eq 0)
				{
					Remove-Item -Path $env:OneDrive -Recurse -Force -ErrorAction Ignore
				}
				else
				{
					Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList $env:OneDrive
				}
			}

			New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name AutoRestartShell -PropertyType DWord -Value 0 -Force

			Get-Process -Name explorer | Stop-Process -Force

			Write-Information -MessageData "" -InformationAction Continue
			Write-Verbose -Message ([WinAPI.GetStrings]::GetString(12612)) -Verbose

			Start-Sleep -Seconds 3

			New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name AutoRestartShell -PropertyType DWord -Value 1 -Force

			Get-Process -Name UserOOBEBroker -ErrorAction Ignore | Stop-Process -Force 

			Get-ChildItem -Path "$OneDriveFolder\*\FileSyncShell64.dll" -Force | ForEach-Object -Process {
				Start-Process -FilePath "$env:SystemRoot\System32\regsvr32.exe" -ArgumentList "/u /s $FileSyncShell64dll" -Wait
			}

			$OneDriveFolder = (Split-Path -Path (Split-Path -Path $OneDriveSetup[0] -Parent)) -replace '"', ""
			Remove-Item -Path $OneDriveFolder -Force -Recurse -ErrorAction Ignore

			Start-Process -FilePath "$env:SystemRoot\explorer.exe"

			Write-Information -MessageData "" -InformationAction Continue
			Write-Verbose -Message ([WinAPI.GetStrings]::GetString(12612)) -Verbose

			Start-Sleep -Seconds 3 

			Remove-ItemProperty -Path HKCU:\Environment -Name OneDrive,OneDriveConsumer -Force -ErrorAction Ignore
			Unregister-ScheduledTask -TaskName *OneDrive* -Confirm:$false -ErrorAction Ignore
			$Path = @(
				"$env:LOCALAPPDATA\OneDrive",
				"$env:LOCALAPPDATA\Microsoft\OneDrive",
				"$env:LOCALAPPDATA\Microsoft\OneAuth",
				"$env:APPDATA\Microsoft\Windows\Start Menu\Programs\OneDrive.lnk",
				"$env:ProgramData\Microsoft OneDrive",
				"$env:ProgramFiles\Microsoft OneDrive",
				"$env:SystemDrive\OneDriveTemp",
				"HKCU:\Software\Microsoft\OneDrive"
			)
			Remove-Item -Path $Path -Recurse -Force -ErrorAction Ignore
		}
		"Install"
		{
			$OneDrive = Get-Package -Name "Microsoft OneDrive" -ProviderName Programs -Force -ErrorAction Ignore
			if ($OneDrive)
			{
				Write-Information -MessageData "" -InformationAction Continue
				Write-Verbose -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -Verbose
				Write-Error -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue

				return
			}

			if (Test-Path -Path $env:SystemRoot\System32\OneDriveSetup.exe)
			{
				Write-Information -MessageData "" -InformationAction Continue
				Write-Verbose -Message $Localization.OneDriveInstalling -Verbose

				if ($AllUsers)
				{
					Start-Process -FilePath $env:SystemRoot\System32\OneDriveSetup.exe -ArgumentList "/allusers"
				} 
				else 
				{
					Start-Process -FilePath $env:SystemRoot\System32\OneDriveSetup.exe
				}
			} 
			else 
			{
				try 
				{
					Write-Information -MessageData "" -InformationAction Continue
					Write-Verbose -Message $Localization.OneDriveDownloading -Verbose

					$Parameters = @{
						Uri      =  "https://g.live.com/1rewlive5skydrive/OneDriveProductionV2"
						UseBasicParsing = $true
						Verbose         = $true
					}
					$Content = Invoke-RestMethod @Parameters

	                                [xml]$OneDriveXML = $Content -replace "ï»¿", ""

					$OneDriveURL = $OneDriveXML.root.update.amd64binary.url | Select-Object -Index 1 
					$DownloadsFolder = Get-ItemPropertyValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -Name "{374DE290-123F-4565-9164-39C4925E467B}"
					$Parameters = @{
						Uri   =   $OneDriveURL
						OutFile  = "$DownloadsFolder\OneDriveSetup.exe"
						UseBasicParsing = $true
						Verbose = $true
					}
					Invoke-WebRequest @Parameters

					if($AllUsers)
					{
						Start-Process -FilePath "$DownloadsFolder\OneDriveSetup.exe" -ArgumentList "/allusers"
					}
					else 
					{
						Start-Process -FilePath "$DownloadsFolder\OneDriveSetup.exe"
					}

					Start-Sleep -Seconds 3

					Get-Process -Name OneDriveSetup -ErrorAction Ignore | Stop-Process -Force
					Remove-Item -Path "$DownloadsFolder\OneDriveSetup.exe" -Force
				}
				catch [System.Net.WebException]
				{
					Write-Warning -Message ($Localization.NoResponse -f "https://oneclient.sfx.ms")
					Write-Error -Message ($Localization.NoResponse -f "https://oneclient.sfx.ms") -ErrorAction SilentlyContinue
					Write-Error -Message ($Localization.RestartFunction -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue

					return
				}

			}
			Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -Name "{B7BEDE81-DF94-4682-A7D8-57A52620B86F}" -Force -ErrorAction Ignore

			Get-ScheduledTask -TaskName "Onedrive* Update*" | Enable-ScheduledTAsk
			Get-ScheduledTask -TaskName "Onedrive* Update*" | Start-ScheduledTask
		}
	}
}
