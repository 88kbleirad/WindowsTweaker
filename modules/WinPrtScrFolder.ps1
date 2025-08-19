function WinPrtScrFolder
{
	param
	(
		[Parameter(
		        Mandatory = $true, 
		        ParameterSetName = "Desktop"
		)]
		[switch]
		$Desktop,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Default"
		)]
		[switch]
		$Default
	)

	switch ($PSCmdlet.ParameterSetName)
	{
		"Desktop"
		{
			$UserEmail = Get-ItemProperty -Path HKCU:\Software\Microsoft\OneDrive\Accounts\Personal -Name UserEmail -ErrorAction Ignore
			if ($UserEmail)
			{
				Write-Information -MessageData "" -InformationAction Continue
				Write-Warning -Message $Localization.OneDriveWarning
				Write-Error -Message $Localization.OneDriveWarning -ErrorAction SilentlyContinue

				Write-Information -MessageData "" -InformationAction Continue
				Write-Verbose -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -Verbose
				Write-Error -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue

				return
			}

			$PresetName = (Get-Variable -Name MyInvocation -Scope Script).Value.PSCommandPath
			$PSCallStack = (Get-PSCallStack).Position.Text
			$OneDriveInstalled = Get-Package -Name "Microsoft OneDrive" -ProviderName Programs -Force -ErrorAction Ignore


	                if ($PresetName -match "Import-TabCompletion.ps1")
			{
				if ($PSCallStack -match "WinPrtScrFolder -Desktop")
				{
					if (($PSCallStack -match "OneDrive -Uninstall") -or (-not $OneDriveInstalled))
					{
						$DesktopFolder = Get-ItemPropertyValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -Name Desktop
						New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -Name "{B7BEDE81-DF94-4682-A7D8-57A52620B86F}" -PropertyType ExpandString -Value $DesktopFolder -Force
					}
					else
					{
						Write-Warning -Message ($Localization.OneDriveWarning -f $MyInvocation.Line.Trim())
						Write-Error -Message ($Localization.OneDriveWarning -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue

						Write-Information -MessageData "" -InformationAction Continue
						Write-Verbose -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -Verbose
						Write-Error -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue
					}
				}
			}
			else
			{
				if (Select-String -Path $PresetName -Pattern "OneDrive -Uninstall" -SimpleMatch)
				{
					$IsOneDriveToUninstall = (Select-String -Path $PresetName -Pattern "OneDrive -Uninstall" -SimpleMatch).Line.StartsWith("#") -eq $false
					if ($IsOneDriveToUninstall -or (-not $OneDriveInstalled) -or ($PSCallStack -match "OneDrive -Uninstall"))
					{
						$DesktopFolder = Get-ItemPropertyValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -Name Desktop
						New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -Name "{B7BEDE81-DF94-4682-A7D8-57A52620B86F}" -PropertyType ExpandString -Value $DesktopFolder -Force
					}
					else
					{
						Write-Warning -Message ($Localization.OneDriveWarning -f $MyInvocation.Line.Trim())
						Write-Error -Message ($Localization.OneDriveWarning -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue

						Write-Information -MessageData "" -InformationAction Continue
						Write-Verbose -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -Verbose
						Write-Error -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue
					}
				}
			}
		}
	        "Default"
		{
			Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -Name "{B7BEDE81-DF94-4682-A7D8-57A52620B86F}" -Force -ErrorAction Ignore
		}
	}
}
