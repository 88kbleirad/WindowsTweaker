function CABInstallContext
{
	param
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Show"
		)]
		[switch]
		$Show,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Hide"
		)]
		[switch]
		$Hide
	)

	switch ($PSCmdlet.ParameterSetName)
	{
		"Show"
		{
			if ([Microsoft.Win32.Registry]::GetValue("HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.cab\UserChoice", "ProgId", $null) -eq "CABFolder")
			{
				if (-not (Test-Path -Path Registry::HKEY_CLASSES_ROOT\CABFolder\Shell\runas\Command))
				{
				        New-Item -Path Registry::HKEY_CLASSES_ROOT\CABFolde
				}
                            	New-ItemProperty -Path Registry::HKEY_CLASSES_ROOT\CABFolder\Shell\runas\Command -Name "(default)" -PropertyType String -Value "cmd /c DISM.exe /Online /App-Package /PackagePath:`"%1`" /NoRestart & pause" -Force

		                New-ItemProperty -Path Registry::HKEY_CLASSES_ROOT\CABFolder\Shell\runas -Name MUIVerb -PropertyType String -Value "@shell32.dll, -10210" -Force
			        
				New-ItemProperty -Path Registry::HKEY_CLASSES_ROOT\CABFolder\Shell\runas -Name HasLUAShield -PropertyType String -Value "" -Force
			}
			else
			{
				Write-Information -MessageData "" -InformationAction Continue
				Write-Verbose -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -Verbose
				Write-Error -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue

				return
			}
		
		}
		"Hide"
		{
			Remove-Item -Path Registry::HKEY_CLASSES_ROOT\CABFolder\Shell\runas -Recurse -Force -ErrorAction Ignore
		}
	}
}

