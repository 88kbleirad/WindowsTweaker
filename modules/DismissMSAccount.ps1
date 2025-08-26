function DismissMSAccount 
{
	if ((-not $Script:DefenderEnabled) -or $Script:DefenderMpPreferenceBroken)
	{
		Write-Information -MessageData -InformationAction Continue
		Write-Verbose -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -Verbose
		Write-Error -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue

		return
	}

	New-ItemProperty -Path "HKCU:\Software\Microsoft\Window Security Health\State" -Name AccountProtection_MicrosoftAccount_Disconnected -PropertyType DWord -Value 1 -Force
}
