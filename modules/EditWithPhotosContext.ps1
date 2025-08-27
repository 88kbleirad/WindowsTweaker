function EditWithPhotosContext
{
	param 
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Hide"
		)]
		[switch]
		$Hide,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Show"
		)]
		[switch]
		$Show
	)

	if (-not (Get-AppxPackage -Name Microsoft.Windows.Photos))
	{
		Write-Information -MessageData "" -InformationAction Continue
		Write-Verbose -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -Verbose
		Write-Error -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue

		return
	}

	Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked" -Name "{BFE0E2A4-C70C-4AD7-AC3D-10D1ECEBB584}" -Force -ErrorAction Ignore

	switch ($PSCmdlet.ParameterSetName)
	{
		"Hide"
		{
			if(-not (Test-Path -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked"))
			{
				New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked" -Force
			}
			New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked" -Name "{BFE0E2A4-C70C-4AD7-AC3D-10D1ECEBB5B4}" -PropertyType String -Value "" -Force
		}
		"Show"
		{
			Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked" -Name "{BFE0E2A4-C70C-4AD7-AC3D-10D1ECEBB5B4}" -Force -ErrorAction Ignore
		}
	}
}
