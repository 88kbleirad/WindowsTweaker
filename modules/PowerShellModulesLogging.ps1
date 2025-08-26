function PowerShellModulesLogging
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
			if (-not (Test-Path -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging\ModuleName))
			{
				New-Item -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging\ModuleNames -Force
			}

			New-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging -Name EnableModuleLogging -PropertyType DWord -Value 1 -Force

			New-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging\ModuleNames -Name * -PropertyType String -Value * -Force

			Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging -Name EnableModuleLogging -Type DWORD -Value 1
			Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging\ModuleNames -Name * -Type SZ -Value *

		}
		"Disable"
		{
			Remove-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging -Name EnableModuleLogging -Force -ErrorAction Ignore
			
			Remove-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging\ModuleNames -Name * -Force -ErrorAction Ignore

			Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging -Name EnableModuleLogging -Type DELETE
		}
	}
}
