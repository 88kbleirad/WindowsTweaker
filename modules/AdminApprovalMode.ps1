function AdminApprovalMode
{
	param
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Never"
		)]
		[switch]
		$Never,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Default"
		)]
		[switch]
		$Default
	)

	New-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name ConsentPromptBehaviorUser -PropertyType DWord -Value 3 -Force

	New-ItemProperty -Path  HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name EnableInstallerDetection -PropertyType DWord -Value 1 -Force

	New-ItemProperty -Path  HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name ValidateAdminCodeSignatures -PropertyType DWord -Value 0 -Force

	New-ItemProperty -Path  HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name EnableSecureUIAPaths -PropertyType DWord -Value 1 -Force

	New-ItemProperty -Path  HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name EnableLUA -PropertyType DWord -Value 1 -Force

	New-ItemProperty -Path  HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name PromptOnSecureDesktop -PropertyType DWord -Value 1 -Force

	New-ItemProperty -Path  HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name EnableVirtualization -PropertyType DWord -Value 1 -Force

	New-ItemProperty -Path  HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name EnableUIADesktopToggle -PropertyType DWord -Value 1 -Force

	Set-Policy -Scope Computer -Path SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name FilterAdministratorToken -Type DELETE

	Set-Policy -Scope Computer -Path SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name ConsentPromptBehaviorUser -Type DELETE

	Set-Policy -Scope Computer -Path SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name EnableInstallerDetection -Type DELETE 

	Set-Policy -Scope Computer -Path SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name ValidateAdminCodeSignatures -Type DELETE

	Set-Policy -Scope Computer -Path SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name EnableSecureUIAPaths -Type DELETE

	Set-Policy -Scope Computer -Path SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name EnableLUA -Type DELETE

	Set-Policy -Scope Computer -Path SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name PromptOnSecureDesktop -Type DELETE

	Set-Policy -Scope Computer -Path SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name EnableVirtualization -Type DELETE

	Set-Policy -Scope Computer -Path SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name EnableUIADesktopToggle -Type DELETE

        switch ($PSCmdlet.ParameterSetName)
	{
		"Never"
		{
			New-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name ConsentPromptBehaviorAdmin -PropertyType DWord -Value 0 -Force
		}
		"Default"
		{
			New-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name ConsentPromptBehaviorAdmin -PropertyType DWord -Value 5 -Force
		}
	}
}
