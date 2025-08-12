function UnpinTaskbarShortcuts
{
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory = $true)]
		[ValidateSet("Edge", "Store", "Outlook")]
		[string[]]
		$Shortcuts
	)

	$LocalizedString = [WinAPI.GetStrings]::GetString(5387)

	foreach ($Shortcut in $Shortcuts)
	{
		switch ($Shortcut)
		{
			Edge
			{
				if(Test-Path -Path "$env:AppData\Microsoft\Internet Explorer\Quick Launch\User Pinned\Taskbar\Microsoft Edge.ink")
				{
					$Shell = (New-Object -ComObject Shell.Application).NameSpace("$env:AppData\Microsoft\Internet Explorer\Quick Launch\User Pinned\Taskbar")
					$Shortcut = $Shell.ParseName("Microsoft Edge.ink")

					$Shortcut.Verbs() | Where-Object -FilterScript {$_.Name -eq $LocalizedString} | ForEach-Object -Process {$_.DoIt()}
				}
			}

			Store
			{
				if((New-Object -ComObject Shell.Application).NameSpace("shell:::{4234d49b-0245-4df3-b780-3893943456e1}").Item() | Where-Object -FilterScript {$_.Name -eq "Microsoft Store"})
				{
					((New-Object -ComObject Shell.Application).NameSpace("shell:::{4234d49b-0245-4df3-b780-3893943456e1}").Item() | Where-Object -FilterScript {
						$_.Name -eq "Microsoft Store"
					}).Verb() | Where-Object -FilterScript {$_.Name -eq $LocalizedString} | ForEach-Object -Process {$_.DoIt()}
				}
			}
			Outlook
			{
				if((New-Object -ComObject Shell.Application).NameSpace("shell:::{4234d49b-0245-4df3-b780-3893943456e1}").Item() | Where-Object -FilterScript {$_.Name -match "Outlook"})
				{
					((New-Object -ComObject Shell.Application).NameSpace("shell:::{4234d49b-0245-4df3-b780-3893943456e1}").Item() | Where-Object -FilterScript {
					        $_.Name -match "Outlook"
					}).Verb() | Where-Object -FilterScript {$_.Name -eq $LocalizedString} | ForEach-Object -Process {$_.DoIt()}
				}
			}
		}
	}
}
