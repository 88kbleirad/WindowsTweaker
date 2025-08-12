function TaskbarWidgets 
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

	if(-not (Get-AppxPackage -Name MicrosoftWindows.Client.WebExperience))
	{
		Write-Information -MessageData "" InformationAction Continue
		Write-Verbose -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -Verbose
		Write-Error -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -ErrorAction SilentyContinue

		return
	}

	Remove-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\PolicyManager\default\NewsAndInterests\AllowNewsAndInterests -Name value -Force -ErrorAction Ignore
	Remove-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Dsh -Name AllowNewsAndInterests -Force -ErrorAction Ignore
	Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\Dsh -Name AllowNewsAndInterests -Type DELETE

	Copy-Item -Path "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Destination "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell_temp.exe" -Force

	switch ($PSCmdlet.ParameterSetName)
	{
		"Hide"
		{
			& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell_temp.exe" -Command {New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced -Name TaskbarDa -PropertyType DWord -Value 0 -Force}
		}
		"Show"
		{
                        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell_temp.exe" -Command {New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced -Name TaskbarDa -PropertyType DWord -Value 1 -Force}

		}
	}
	Remove-Item -Path "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell_temp.exe" -Force
}
