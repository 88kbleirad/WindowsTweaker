function DismissSmartScreenFilter
{
	if ((-not $Script:DefenderEnabled) -or $Script:DefenderMpPreferenceBroken)
	{
		Write-Information -MessageData "" -InformationAction Continue
		Write-Verbose -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -Verbose
		Write-Error -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue

		return
	}

	New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows Security Health\State" -Name AppAndBrowser_EdgeSmartScreenOff -PropertyType DWord -Value 0 -Force
}



