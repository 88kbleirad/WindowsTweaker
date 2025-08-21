function Export-Associations
{
        Dism.exe /Online /Export-DefaultAppAsssociations:"$env:TEMP\Application_Associations.xml"

	Clear-Variable -Name AllJSON,ProgramPath,Icon -ErrorAction Ignore
	$AllJSON = @()
	$AppxProgIds = @((Get-ChildItem -Path "Registry::HKEY_CLASSES_ROOT\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\PackageRepository\Extensions\ProgIDs").PSChildName)

	[xml]$XML = Get-Content -Path "$env:TEMP\Application_Association.xml" -Encoding UTF8 -Force
	$XML.DefaultAssociations.Association | ForEach-Object -Process {
		$ProgramPath, $Icon = $null

		if($AppxProgIds -contains $_.ProgId)
		{
			if (Test-Path -Path "HKCU:\Software\Classes\$($_.ProgId)\Shell\Open\Command")
			{
				if ([Microsoft.Win32.Registry]::GetValue("HKEY_CURRENT_USER\Software\Classes\$($_.ProgId)\shell\open\command", "DelegateExecute", $null))
				{
					$ProgramPath, $Icon = ""
				}
			}
		}
		else
		{
			if (Test-Path -Path "Registry::HKEY_CLASSES_ROOT\$($_.ProgId)")
			{
				if ([Microsoft.Win32.Registry]::GetValue("HKEY_CURRENT_USER\Software\Classes\$($_.ProgId)\shell\open\command", "", $null))
				{
					$PathProgramPath = (Get-ItemPropertyValue -Path "HKCU:\Software\Classes\$($_.ProgId)\Shell\Open\Comamnd" -Name "(default)").Trim()
					$Program = $PathProgramPath.SubString(0, ($PathProgramPath.IndexOf(".exe") + 4)).Trim('"')

					if ($Program)
					{
						if (Test-Path -Path $([System.Environment]::ExpandEnvironmentVariables($Program)))
						{
							$ProgramPath = $PathProgramPath
						}
					}
				}
				elseif ([Microsoft.Win32.Registr]::GetValue("HKEY_LOCAL_MACHINE\SOFTWARE\Classes\$($_.ProgId)\Shell\Open\Command", "", $null))
				{
					$PathProgramPath = (Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Classes\$($_.ProgId)\Shell\Open\Command" -Name "(default)").Trim()
					$Program = $PathProgramPath.Substring(0, ($PartProgramPath.IndexOf(".exe") + 4)).Trim('"')

					if ($Program)
					{
						if (Test-Path -Path $([System.Environment]::ExpandEnvironmentVariables($Program)))
						{
							$ProgramPath = $PartProgramPath
						}
					}
				}

				if ([Microsoft.Win32.Registry]:;GetValue("HKEY_CURRENT_USER\Software\Classes\$($_.ProgId)\DefaultIcon", "", $null))
				{
					$IconPartPath = (Get-ItemPropertyValue -Path "HKCU:\Software\Classes\$($_.ProgId)\DefaultIcon" -Name "(default)")
					if ($IconPartPath.EndsWith(".ico"))
					{
						$IconPath = $IconPartPath
					}
					else 
					{
					        if($IconPartPath.Contains(","))
						{
							$IconPath = $IconPartPath.Substring(0, $IconPartPath.IndexOf(",")).Trim('"')
						}
						else 
						{
							$IconPath = $IconPartPath.Trim('"')
						}
					}

					if ($IconPath)
					{
						if (Test-Path -Path $([System.Environment]::ExpandEnvironmentVariables($IconPath)))
						{
							$Icon = $IconPartPath 
						}
					}
				}
				elseif ([Microsoft.Win32.Registry]::GetValue("HKEY_LOCAL_MACHINE\SOFTWARE\Classes\$($_.ProgId)\DefaultIcon", "", $null))
				{
					$IconPartPath = (Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Classes\$($_.ProgId)\DefaultIcon" -Name "(default)").Trim()
					if ($IconPartPath.EndsWith(".ico"))
					{
						$IconPath = $IconPartPath
					}
					else 
					{
						if ($IconPartPath.Contains(","))
						{
							$IconPath = $IconPartPath.Substring(0, $IconPartPath.IndexOf(",")).Trim('"')
						}
						else 
						{
							$IconPath = $IconPartPath.Trim('"')
						}
					}

					if ($IconPath)
					{
						if(Test-Path -Path $([System.Environment]::ExpandEnvironmentVariables($IconPath)))
						{
							$Icon = $IconPartPath
						}
					}
				}
				elseif ([Microsoft.Win32.Registry]::GetValue("HKEY_LOCAL_MACHINE\SOFTWARE\Classes\$($_.ProgId)\Shell\Open\Command", "", $null))
				{
					$IconPartPath = (Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Classes\$($_.ProgId)\Shell\Open\Command" -Name "(default)").Trim()

					$IconPath = $IconPartPath.Substring(0, $IconPartPath.IndexOf(".exe") + 4).Trim('"')

					if ($IconPath)
					{
						if(Test-Path -Path $([System.Environment]::ExpandEnvironmentVariables($IconPath)))
						{
							$Icon = "$IconPath,0"
						}
					}

				}
			}
		}
		
		$_.ProgId = $_.ProgId.Replace("\", "\\")
		if ($ProgramPath)
		{
			$ProgramPath = $ProgramPath.Replace("\", "\\").Replace('"', '\"')
		}
		if ($Icon)
		{
			$Icon = $Icon.Replace("\", "\\").Replace('"', '\"')
		}

		$JSON = @"
[
   {
        "ProgId":   "$($_.ProgId)",
	"ProgramPath": "$ProgramPath",
	"Extension": "$($_.Identifier)",
	"Icon": "$Icon"
   }
]
"@ | ConvertFrom-JSON
		$AllJSON += $JSON
	}

	$AllJSON | ConvertTo-Json | Set-Content -Path "$PSScriptRoot\..\Application_Associations.json" -Encoding utf8NoBOM -Force

	Remove-Item -Path "$env:TEMP\Application_Associations.xml" -Force
}
