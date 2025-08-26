function PowerShellScriptsLogging
{
	param
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Enable"
		)]
		[switch]
		$Enable,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Disable"
		)]
		[switch]
		$Disable
	)

	switch ($PSCmdlet.ParameterSetName)
	{
		"Enable"
		{
			if (-not (Test-Path -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging))
			{
				New-Item -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging -Force
			}

			New-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging -Name EnableScriptBlockLogging -PropertyType DWord -Value 1 -Force

			Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging -Name EnableScriptBlockLogging -Force -ErrorAction Ignore
		}
		"Disable"
		{
			Remove-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging -Name EnableScriptBlockLogging -Force -ErrorAction Ignore

			Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging -Name EnableScriptBlockLogging -Type DELETE
		}
	}
}
