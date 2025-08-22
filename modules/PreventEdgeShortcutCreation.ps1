function PreventEdgeShortcutCreation
{
        [CmdletBinding()]
	param
	(
		[Parameter(
                        Mandatory = $false,
		        ParameterSetName = "Channels"
		)]
		[ValidateSet("Stable", "Beta", "Dev", "Canary")]
		[string[]]
		$Channels,

		[Parameter(
		        Mandatory = $false,
		        ParameterSetName = "Disable"
		)]
		[switch]
		$Disable
	)

	if (-not (Get-Package -Name "Microsoft Edge" -ProviderName Programs -ErrorAction Ignore))
	{
		Write-Information -MessageData "" -InformationAction Continue
		Write-Verbose -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -Verbose
		Write-Error -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue

		return
	}

	if (-not (Test-Path -Path HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate))
	{
		New-Item -Path HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate -Force
	}

	foreach ($Channel in $Channels)
	{
		switch ($Channel)
		{
			Stable
			{
				if (Get-Package -Name "Microsoft Edge -ProviderName Programs -ErrorAction Ignore")
				{
					New-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate -Name "CreateDesktopShortcut{56EB18F8-B008-4BCD-B6D2-8C97FE7E9062}" -PropertyType DWord -Value 0 -Force
					Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\EdgeUpdate -Name "CreateDesktopShortcut{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" -Type DWORD -Value 3
				}
			}
			Beta
			{
				if (Get-Package -Name "Microsoft Edge Beta" -ProviderName Programs -ErrorAction Ignore)
				{
					New-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate -Name "CreateDesktopShortcut{2CD8A007-E189-409D-A2C8-9AF4EF3C72AA}" -PropertyType DWord -Value 0 -Force
					Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\EdgeUpdate -Name "CreateDesktopShortcut{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" -Type DWORD -Value 3
				}
			}
			Dev
			{
				if (Get-Package -Name "Microsoft Edge Dev" -ProviderName Programs -ErrorAction Ignore)
				{
					New-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate -Name "CreateDesktopShortcut{0D50BFEC-CD6A-4F9A-964C-C7416E3ACB10}" -PropertyType DWord -Value 0 -Force
					Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\EdgeUpdate -Name "CreateDesktopShortcut{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" -Type DWORD -Value 3
				}
			}
			Canary 
			{
				if (Get-Package -Name "Microsoft Edge Canary" -ProviderName Programs -ErrorAction Ignore)
				{
					New-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate -Name "CreateDesktopShortcut{65C35B14-6C1D-4122-AC46-7148C9D6497}" -PropertyType DWord -Value 0 -Force
					Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\EdgeUpdate -Name "CreateDesktopShortcut{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" -Type DWORD -Value 3
				}
			}
		}
	}

	if ($Disable)
	{
		$Names = @(
	                "CreateDesktopShortcut{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}",
			"CreateDesktopShortcut{2CD8A007-E189-409D-A2C8-9AF4EF3C72AA}",
			"CreateDesktopShortcut{0D50BFEC-CD6A-4F9A-964C-C7416E3ACB10}",
			"CreateDesktopShortcut{65C35B14-6C1D-4122-AC46-7148CC9D6497}"
		)
		Remove-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate -Name $Names -Force -ErrorAction Ignore

	        Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\EdgeUpdate -Name "CreateDesktopShortcut{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" -Type DELETE
		Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\EdgeUpdate -Name "CreateDesktopShortcut{2CD8A007-E189-409D-A2C8-9AF4EF3C72AA}" -Type DELETE
		Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\EdgeUpdate -Name "CreateDesktopShortcut{0D50BFEC-CD6A-4F9A-964C-C7416E3ACB10}" -Type DELETE
		Set-Policy -Scope Computer -Path SOFTWARE\Policies\Microsoft\EdgeUpdate -Name "CreateDesktopShortcut{65C35B14-6C1D-4122-AC46-7148CC9D6497}" -Type DELETE
	}
}
