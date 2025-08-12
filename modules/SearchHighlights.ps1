function SearchHighlights
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

	Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name EnableDynamicContentInWSB -Force -ErrorAction Ignore
	Set-Policy -Scope Computer -Path "SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name EnableDynamicContentInWSB -Type DELETE

	switch ($PSCmdlet.ParameterSetName)
	{
		"Hide"
		{
			$BingSearchEnabled = ([Microsoft.Win32.Registry]::GetValue("HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Search", "BingSearchEnabled", $null))
			$DisableSearchBoxSuggestions = ([Microsoft.Win32.Registry]::GetValue("HKEY_CURRENT_USER\Software\Policies\Microsoft\Windows\Explorer", "DisableSearchBoxSuggestions", $null))
			if (($BingSearchEnabled -eq 1) -or ($DisableSearchBoxSuggestions -eq 1))
			{
				Write-Information -MessageData "" -InformationAction Continue
				Write-Verbose -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -Verbose
				Write-Error -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue

				return
			}
			else 
			{
				New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings -Name IsDynamicSearchBoxEnabled -PropertyType DWord -Value 0 -Force
			}
		}
		"Show"
		{
			Remove-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Search -Name BingSearchEnabled -Force -ErrorAction Ignore
			Remove-ItemProperty -Path HKCU:\Software\Policies\Microsoft\Windows\Explorer -Name DisableSearchBoxSuggestions -Force -ErrorAction Ignore

			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings -Name IsDynamicSearchBoxEnabled -PropertyType DWord -Value 1 -Force
		}
	}
}
