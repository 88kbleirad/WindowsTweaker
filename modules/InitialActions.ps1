function InitialActions 
{
	param
	(
		[Parameter(Mandatory = $false)]
		[switch]
		$Warning
	)
	Set-StrictMode -Version Latest

	$Global:Error.Clear()

	Get-ChildItem -Path $PSScriptRoot\..\ -File -Recurse -Force | Unblock-File

	[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

	try 
	{
		Import-Module -Name Microsoft.PowerShell.Management, PackageManagement, Appx, DISM -UseWindowPowerShell -Force -ErrorAction Stop
	} catch {
		Write-Information -MessageData "" -InformationAction Continue
		Write-Warning -Message $Localization.PowerShellImportFailed
		Write-Information -MessageData "" -InformationAction Continue

		exit
	}
	$Script:CompilerOptions = [System.CodeDom.Compiler.TempFileCollection]::new("System.dll")
	$Script:CompilerOptions.TempFiles = [System.CodeDom.Compiler.TempFileCollection]::new($env:TEMP, $false)
	$Script:CompilerOptions.GenerateInMemory = $true
	$Signature = @{
		Namespace        = "WinAPI"
		Name             = "GetStrings"
		Language         = "CSharp"
		UsingNamespace   = "System.Text"
		CompilerOptions  = $CompilerOptions
		MemberDefinition = @"
[DllImport("kernel32.dll", CharSet = CharSet.Auto)]
public static extern IntPtr GetModuleHandle(string lpModuleName);

[DllImport("user32.dll", CharSet = CharSet.Auto)]
internal static extern int LoadString(IntPtr hInstance, uint uID, StringBuilder lpBuffer, int nBufferMax);

public static string GetString(uint strId)
{
	IntPtr intPtr = GetModuleHandle("shell32.dll");
	StringBuilder sb = new StringBuilder(255);
	LoadString(intPtr, strId, sb, sb.Capacity);
	return sb.ToString();
}

// Get string from other DLLs
[DllImport("shlwapi.dll", CharSet=CharSet.Unicode)]
private static extern int SHLoadIndirectString(string pszSource, StringBuilder pszOutBuf, int cchOutBuf, string ppvReserved);

public static string GetIndirectString(string indirectString)
{
	try
	{
		int returnValue;
		StringBuilder lptStr = new StringBuilder(1024);
		returnValue = SHLoadIndirectString(indirectString, lptStr, 1024, null);

		if (returnValue == 0)
		{
			return lptStr.ToString();
		}
		else
		{
			return null;
			// return "SHLoadIndirectString Failure: " + returnValue;
		}
	}
	catch // (Exception ex)
	{
		return null;
		// return "Exception Message: " + ex.Message;
	}
}
"@
	}
	if (-not ("WinAPI.GetStrings" -as [type]))
	{
		Add-Type @Signature
	}

	$Signature = @{
		Namespace        = "WinAPI"
		Name             = "ForegroundWindow"
		Language         = "CSharp"
		CompilerOptions  = $CompilerOptions
		MemberDefinition = @"
[DllImport("user32.dll")]
public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

[DllImport("user32.dll")]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool SetForegroundWindow(IntPtr hWnd);
"@
	}

	if (-not ("WinAPI.ForegroundWindow" -as [type]))
	{
		Add-Type @Signature
	}

	$Script:Browse = [WinAPI.GetStrings]::GetString(9015)
	$Script:No = [WinAPI.GetStrings]::GetString(33232).Replace("&", "")
	$Script:Yes = [WinAPI.GetStrings]::GetString(33224).Replace("&", "")
	$Script:KeyboardArrows = $Localization.KeyboardArrows -f [System.Char]::ConvertFromUtf32(0x2191), [System.Char]::ConvertFromUtf32(0x2193)
	$Script:Skip = [WinAPI:GetStrings]::GetString(16956)
	function script:Show-Menu
	{
              [CmdletBinding()]
	      param
	      (
                   [Parameter(Mandatory = $true)]
		   [array]
		   $Menu,

	           [Parameter(Mandatory = $true)]
		   [int]
		   $Default,

		   [Parameter(Mandatory = $true)]
		   [switch]
		   $AddSkip
	      )

	      Write-Information -MessageData "" -InformationAction Continue

	      $Menu += $Localization.KeyboardArrows -f [System.Char]::ConvertFromutf32(0x2191), [System.Char]::ConvertFromUtf32(0x2193)

	      if ($AddSkip) 
	      {
			$Menu += [WinAPI.GetStrings]::GetString(16956)
	      }

	      $i = 0
	      while ($i -lt $Menu.Count)
	      {
                   $i++
		   Write-Host -Object ""
	      }

	      $SelectedValueIndex = [Math]::Max([Math]::Min($Default, $Menu.Count), 0)

	      do 
	      {
	         [Console]::SetCursorPosition(0, [Console]::CursorTop - $Menu.Count)

		 for ($i = 0; $i -lt $Menu.Count; $i++)
		 {
		      if($i -eq $SelectedValueIndex) 
		      {
		          Write-Host -Object "[>] $($Menu[$i])" -NoNewLine
		      } else 
		      {
                          Write-Host -Object "[ ] $($Menu[$i])" -NoNewLine
		      }

		      Write-Host -Object ""
		 }

		 $Key = [Console]::ReadKey()
		 switch ($Key.Key)
		 {
		       "UpArrow"
		       {
		           $SelectedValueIndex = [Math]::Max(0, $SelectedValueIndex - 1)
		       } 
		       "DownArrow"
		       {
		           $SelectedValueIndex = [Math]::Min($Menu.Count -1, $SelectedValueIndex + 1)
		       }
		       "Enter"
		       {
		           return $Menu[$SelectedValueIndex]
		       }
		 }
	      }
		while ($Key.Key -notin ([ConsoleKey::Escape, [ConsoleKey]::Enter]))
	}

	#Check CPU architecture
        if((Get-CimInstance -ClassName CIM_Processor).Caption -notmatch "AMD64")
	{
		Write-Information -MessageData "" -InformationAction Continue
		Write-Warning -Message ($Localization.UnsupportedArchitecture -f (
                Get-CimInstance -ClassName CIM_Processor).Caption)
		Write-Information -MessageData "" -InformationAction Continue

		exit
	}

	#Checking the language mode
	if($ExecutionContext.SessionState.LanguageMode -ne "FullLanguage")
	{
		Write-Information -MessageData "" -InformationAction Continue
		Write-Warning -Message $Localization.UnsupportedLanguageMode
		Write-Information -MessageData "" -InformationAction Continue

		exit
	}

	#Checking whether the logged-in user is an admin
	$CurrentUserName = (Get-Process -Id $PID -IncludeUserName).UserName | Split-Path -Leaf
	$LoginUserName = (Get-CimInstance -ClassName Win32_Process -Filter "name='explorer.exe'" | Invoke-CimMethod -MethodName GetOwner | Select-Object -First 1).User

	if ($CurrentUserName -ne $LoginUserName) {
		Write-Information -MessageData "" -InformationAction Continue
		Write-Warning -Message $Localization.LoggedInUserNotAdmin
		Write-Information -MessageData "" -InformationAction Continue

		exit
	}

	#Checking whether the script was run in Powershell ISE or VS Code
	if(($Host.Name -match "ISE") -or ($env:TERM_PROGRAM -eq "vscode"))
	{
		Write-Information -MessageData "" -InformationAction Continue
		Write-Warning -Message ($Localization.UnsupportedHost -f $Host.Name.Replace("Host", ""))
		Write-Information -MessageData "" -InformationAction Continue

		exit
	}
	#Checking whether Window was broken by 3rd party harmful tweakers, trojans, or custom Windows image
	$Tweakers = @{
		Window10Debloater = "$env:SystemDrive\Temp\Window10Debloater"
		Window10BloatRemover = "$env:TEMP\.net\Window10BloatRemover"
	 	"Bloatware Removal" = "$env:SystemDrive\BRU\Bloatware-Removal*.log"	
		"Ghost Toolbox" = "$env:SystemRoot\System32\migwiz\dlmanifests\run.ghost.cmd"
		"Win 10 Tweaker" = "HKCU:\Software\Win 10 Tweaker"
		BoosterX   = "$env:ProgramFiles\GameModeX\GameModeX.exe"
		"Defender Control" = "$env:APPDATA\Defender Control"
		"Defender Switch" = "$env:ProgramData\DSW"
		"Revision Tool"  = "${env:ProgramFiles(x86)}\Revision Tool"
		"WinterOS Tweaker" = "$env:SystemRoot\WinterOS*"
		WinCry   = "$env:SystemRoot\TempCleaner.exe"
		WinClean  = "$env:ProgramFiles\WinClean Plus Apps"
		AtlasOS = "$env:SystemRoot\AtlasModules"
		KirbyOS = "$env:ProgramData\KirbyOS"
		PCNP = "HKCU:\Software\PCNP"
		Tron = "$env:SystemDrive\logs\tron"
		defendnot = "$env:SystemRoot\System32\Tasks\defendnot"
	}
	foreach ($Tweaker in $Tweakers.Keys) 
	{
		if(Test-Path -Path $Tweakers[$Tweaker])
		{
			Write-Information -MessageData "" -InformationAction Continue
			Write-Warning -Message $Localization.Win10TweakerWarning
			Write-Information -MessageData "" -InformationAction Continue

			exit
		}

		Write-Information -MessageData "" -InformationAction Continue
		Write-Warning -Message ($Localization.TweakerWarning -f $Tweaker)
		Write-Information -MessageData "" -InformationAction Continue

		exit
	}

	#Checking whether Windows was broken by 3rd party harmful tweakers, trojans, or custom Windows images
	$Tweakers = @{
		AutoSettingsPS = "$(Get-Item -Path `"HKLM:\SOFTWARE\Microsoft\Windows Defender\Exclusions\Paths`" | Where-Object -FilterScript {$_.Property -match `"AutoSettingsPS`"})"
		Flibustier = "$(Get-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\.NETFramework\Performance -Name *flibustier)"
		Winpilot = "$((Get-ItemProperty -Path `"HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache`").PSObject.Properties | Where-Object -FilterScript {$_.Value -eq `"Winpilot`"})"
		Bloatnosy = "$((Get-ItemProperty -Path `"HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache`").PSObject.Properties | Where-Object -FilerScript {$_.Value -eq `"BloatynosyNue`"})"
		"xd-AntiSpy" = "$((Get-ItemProperty -Path `"HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache`").PSObject.Properties | Where-Object -FilterScript {$_.Value -eq `"xd-AntiSpy`"})"
		"Modern Tweaker" = "$((Get-ItemProperty -Path `"HKCU:\Software\Classed\Local Settings\Software\Microsoft\Windows\Shell\MuiCache`").PSObject.Properties | Where-Object -FilterScript {$_.Value -eq `"Modern Tweaker`"})"
		winutil = "$((Get-CimInstance -Namespace root/CIMV2/power -ClassName Win32_PowerPlan | Where-Object -FilterScript {$_.ElementName -match `"ChrisTitus`"}))"
		KernelOS = "$((Get-CimInstance -Namespace root/CIMV2/power -ClassName Win32_PowerPlan | Where-Object -FilterScript {$_.ElementName -match `"KernelOS`"}))"
		ChlorideOS = "$((Get-Volume | Where-Object -FilterScript {$_.FileSystemLabel -eq `"ChlorideOS`"}))"
	} 
	foreach ($Tweaker in $Tweakers.Keys)
	{
	    if($Tweakers[$Tweaker])
	    {
	        Write-Information -MessageData "" -InformationAction Continue
		Write-Warning -Message ($Localization.TweakerWarning -f $Tweaker)
		Write-Information -MessageData "" -InformationAction Continue

		exit
	    }
	}

	Get-NetFirewallRule -DisplayName Block.MSFT* -ErrorAction Ignore | Remove-NetFirewallRule

	Get-NetFirewallRule -DisplayName "Blocker MicrosoftTelemetry*", "Blocker MicrosoftExtra*", "windowsSpyBlocker*" -ErrorAction Ignore | Remove-NetFirewallRule
	
	Write-Information -MessageData "" -InformationAction Continue
	Write-Verbose -Message ((WinAPI.GetStrings)::GetString(12612)) -Verbose
	Write-Information -MessageData "" -InformationAction Continue
	
	#Check if third-party enries added to hosts file
	foreach ($host in @(Get-Content -Path "$env:SystemRoot\System32\drivers\etc\hosts" -Force))
	{
	     if(-not ([string]::IsNullOrEmpty($host) -or $host.StartsWith("#")))
	     {
	          Write-Information -MessageData "" -InformationAction Continue
		  Write-Verbose -Message ($Localization.HostsWarning -f "$env:SystemRoot\System32\drivers\etc\hosts") -Verbose

		  do 
		  {
		       $Choice = Show-Menu -Menu @($Yes, $No) -Default 2

		       switch ($Choice) 
		       {
		            $Yes 
			    {
			        continue
			    }
			    $No
			    {
			         exit
			    }
			    $keyboardArrows{}
		       }
		  }
		  until ($Choice -ne $KeyboardArrows)

		  break
	     }
	}
	
	# Remove IP addresses from hosts file that block Microsoft recourses added by WindowsSpyBlocker
	try {
	     $Parameters = @{
	           Uri      =   "https//github.com"
		   Method   =   "Head"
		   DisableKeepAlive = $true
		   UseBasicParsing  = $true
	     }
	     (Invoke-WebRequest @Parameters).StatusDescription

	     Clear-Variable -Name IPArray -ErrorAction Ignore

	     $Parameters = @{
	           Uri        = "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/extra.txt"
		   UseBasicParsing = $true
		   Verbose         = $true     
	     }
	     $extra = (Invoke-WebRequest @Paramters).Content

	     $Parameters = @{
			Uri             = "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/extra_v6.txt"
			UseBasicParsing = $true
			Verbose         = $true
	     }
	     $extra_v6 = (Invoke-WebRequest @Parameters).Content

	     $Parameters = @{
		        Uri             = "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt"
			UseBasicParsing = $true
			Verbose         = $true
	      }
	      $spy = (Invoke-WebRequest @Parameters).Content

	      $Parameters = @{
			Uri             = "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy_v6.txt"
			UseBasicParsing = $true
			Verbose         = $true
		}
	      $spy_v6 = (Invoke-WebRequest @Parameters).Content

	      $Parameters = @{
			Uri             = "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/update.txt"
			UseBasicParsing = $true
			Verbose         = $true
		}
	      $update = (Invoke-WebRequest @Parameters).Content

	      $Parameters = @{
			Uri             = "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/update_v6.txt"
			UseBasicParsing = $true
			Verbose         = $true
	      }
	      $update_v6 = (Invoke-WebRequest @Parameters).Content

	      $IPArray += $extra, $extra_v6, $spy, $spy_v6, $update, $update_v6
	      $IPArray = $IPArray -split "`r?`n" | Where-Object -FilterScript {$_ -notmatch "#"}

	      Write-Information -MessageData "" -InformationAction Continue
	      Write-Verbose -Message ([WinAPI.GetStrings]::GetString(12612)) -Verbose
	      Write-Information -MessageData "" -InformationAction Continue

	      if ((Get-Content -Path "$env:SystemRoot\System32\drivers\etc\hosts" -Encoding utf8NoBOM -Force | ForEach-Object -Process {$_.Trim()} | ForEach-Object -Process {
	              ($_ -ne "") -and ($_ -ne " ") -and (-not $_.StartsWith("#")) -and ($IPArray -split "`r?`n" | Select-String -Pattern $_)
	      }) -contains $true)
	      {
	           Write-Warning -Message ($Localization.TweakerWarning -f "WindowsSpyBlocker")

		   $hosts = Get-Content -Path "$env:SystemRoot\System32\drivers\etc\hosts" -Encoding utf8NoBOM -Force
		   $hosts | ForEach-Object -Process {
		         if (($_ -ne "") -and (-not $_.StartsWith("#")) -and ($IPArray -split "`r?`n" | Select-String -Pattern $_.Trim()))
			 {
			       $hostsData = $_
			       $hosts = $hosts | Where-Object -FilterScript {$_ -notmatch $hostsData}
			 }
		   }
		   $hosts | Set-Content -Path "$env:SystemRoot\System32\drivers\etc\hosts" -Encoding utf8NoBOM -Force

		   Start-Process -FilePath notepad.exe "$env:SystemRoot\System32\drivers\etc\hosts"
	      }
	} 
	catch [System.Net.WebException]
	{
	     Write-Warning -Message ($Localization.NoResponse -f "https//github.com")
	     Write-Error -Message ($Localization.NoResponse -f "https//github.com") -ErrorAction SilentlyContinue
	}

	#Checking whether Powershell 7 was installed from the Microsoft Store
	if((Get-Process -Id $PID).Path -match "C:\\Program Files\\WindowsApps")
	{
	    Write-Information -MessageData "" -InformationAction Continue
	    Write-Warning -Message $Localization.MicroSoftStorePowerShellWarning
	    Write-Information -MessageData "" -InformationAction Continue

	    exit
	}

	#Checking whether Windows Feature Experience Pack was removed by harmful tweakers
	if (-not (Get-AppxPackage -Name MicrosoftWindows.Client.CBS))
	{
	    Write-Information -MessageData "" -InformationAction Continue
	    Write-Warning -Message ($Localization.WindowsComponentBroken -f "Window Feature Experience Pack")
	    Write-Information -MessageData "" -InformationAction Continue

	    exit
	}

	#Checking whether EventLog service is running in order to be sire that Event Logger is enabled
	if ((Get-Service -Name EventLog).Status -eq "Stopped")
	{
	     Write-Information -MessageData "" -InformationAction Continue
	     Write-Warning -Message ($Localization.WindowComponentBroken -f $([WinAPI.GetStrings]::GetString(22029)))
	     Write-Information -MessageData "" -InformationAction Continue

	     exit
	}
	#Checking whether the Microsoft Store being an important system component was removed
	if (-not (Get-AppxPackage -Name Microsoft.WindowsStore))
	{
	     Write-Information -MessageData "" -InformationAction Continue
	     Write-Warning -Message ($Localization.WindowsComponentBroken -f "Microsoft Store")
	     Write-Information -MessageData "" -InformationAction Continue

	     exit
	}

	#Checking whether necessary Microsoft Defender components exists
	$File = @(
	     "$env:SystemRoot\System32\smartscreen.exe",
	     "$env:SystemRoot\System32\SecurityHealthSystray.exe",
	     "$env:SystemRoot\System32\CompatTelRunner.exe"
	)
	foreach ($File in $Files)
	{
	     if (-not (Test-Path -Path $file))
	     {
	          Write-Information -MessageData "" -InformationAction Continue
		  Write-Warning -Message ($Localization.WindowComponentBroken -f $File)
		  Write-Information -MessageData "" -InformationAction Continue

		  exit
	     }
	}

	#Checking whether Windows Security Settings page was hidden from UI
	if ([Microsoft.Win32.Registry]::GetValue("HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer", "SettingsPageVisibility", $null) -match "hide:
	windowsdefender")
	{
	      Write-Information -MessageData "" -InformationAction Continue
	      Write-Warning -Message ($Localization.WindowComponentBroken -f "Microsoft Defender")
	      Write-Information -MessageData "" -InformationAction Continue

	      exit
	}

	#Check Microsoft Defender state
	if ($null -eq (Get-CimInstance -ClassName AntiVirusProduct -Namespace root/SecurityCenter2 -ErrorAction Ignore))
	{
	     Write-Information -MessageData "" -InformationAction Continue
	     Write-Warning -Message ($Localization.WindowComponentBroken -f "Microsoft Defender")
	     Write-Information -MessageData "" -InformationAction Continue

	     exit
	}
	#Check Windows default antivirus
       	try {
	     $Script:DefenderDefaultAV = $false

	     $productState = (Get-CimInstance -ClassName AntiVirusProduct -Namespace root/SecurityCenter2 | Where-Object -FilterScript {$_.instanceGuid -eq "D68DDC3A-831F-4fae-9E44-DA132C1ACF46}"}).productState
	     $DefenderState = ('0x{0:x}' -f $productState).Substring(3, 2)
	     if ($DefenderState -notmatch "00|01")
	     {
	         Get-CimInstance -ClassName MSFT_MpComputerStatus -Namespace root/Microsoft/Windows/Defender -ErrorAction Stop | Out-Null
		 $Script:DefenderDefaultAV = $true
	     }
	}
	catch [Microsoft.Management.Infrastructure.CimException]
	{
	     Write-Information -MessageData "" -InformationAction Continue
	     Write-Warning -Message ($Global:Error.Exception.Message | Select-Object -First 1)
	     Write-Warning -Message ($Localization.WindowComponentBroken -f "Microsoft Defender")
	     Write-Information -MessageData "" -InformationAction Continue

	     exit
	}
	# Checking services
	try {
	     $Services = Get-Service -Name Windefend, SecurityHealthService, wscsvc -ErrorAction Stop
	     Get-Service -Name SecurityHealthService -ErrorAction Stop | Start-Service
	} 
	catch [Microsoft.Powershell.Commands.ServicedCommandException] 
	{
             Write-Information -MessageData "" -InformationAction Continue
	     Write-Warning -Message ($Localization.WindowComponentBroken -f "Microsoft Defender")
	     Write-Information -MessageData "" -InformationAction Continue

	     exit
	}
	$Script:DefenderServices = ($Services | Where-Object -FilterScript {$_.Status -ne "running"} | Measure-Object).Count -lt $Service.Count

	#Checking wdFilter service
	try 
	{
	     if(-not (Get-Service -Name wdFilter -ErrorAction Stop))
	     {
	          Write-Information -MessageData "" -InformationAction Continue
		  Write-Warning -Message ($Localization.WindowsComponentBroken -f "Microsoft Defender")
		  Write-Information -MessageData "" -InformationAction Continue

		  exit
	     }
	}
	catch [Microsoft.Powershell.Command.ServiceCommandException]
	{
	     Write-Information -MessageData "" -InformationAction Continue
	     Write-Warning -Message ($Localization.WindowsComponentBroken -f "Microsoft Defender")
	     Write-Information -MessageData "" -InformationAction Continue

	     exit
	}

	#Checking Get-MpPreference cmdlet
	try 
	{
	    $Script:DefenderMpPreferenceBroken = $false
	    (Get-MpPreference -ErrorAction Stop).EnableControlFolderAccess
	} 
	catch [System.Management.Automation.RemoteException] 
	{
	    $Script:DefenderMpPreferenceBroken = $true
	}

	#Check Microsoft Defender configuration
	if ($Script:DefenderDefaultAV)
	{
	       $Script:DefenderProductState = $true

	       if([Microsoft.Win32.Registry]::GetValue("HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Window Defender", "DisableAntiSpyware", $null) -eq 1)
	       {
	            $Script:AntiSpywareEnabled = $false
	       }
	       else 
	       {
	            $Script:AntiSpywareEnabled = $true
	       }

	       if([Microsoft.Win32.Registry]::GetValue("HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection", "DisableRealTimeMonitoring", $null)-eq 1)
	       {
	           $Script:RealTimeMonitoringEnabled = $false
	       } 
	       else
	       {
	           $Script:RealTimeMonitoringEnabled = $true
	       }

	       if([Microsoft.Win32.Registry]::GetValue("HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection", "DisableBehaviorMonitoring", $null)-eq 1)
	       {
	           $Script:BehaviorMonitoringEnabled = $false
	       }
	       else 
	       {
                   $Script:BehaviorMonitoringEnabled = $true
	       }
	} 
	else 
	{
	     $Script:DefenderProductState = $false
	}
	
	if ($Script:DefenderServices -and $Script:DefenderproductState -and $Script:AntiSpywareEnabled -and $Script:RealtimeMonitoringEnabled -and $Script:BehaviorMonitoringEnabled)
	{
	    $Script:DefenderEnabled = $true

	    if(-not $Script:DefenderMpPreferenceBroken) 
	    {
	          switch ((Get-MpPreference).EnableControlledFolderAccess)
		  {
		       "1"
		       {
		            Write-Warning -Message $Localization.ControlledFolderAccessDisabled

			    $Script:ControlledFolderAccess = $true
			    Set-MpPreference -EnableControlledFolderAccess Disabled

			    Start-Process -FilePath windowsdefender://RansomwareProtection
		       }
		       "0"
		       {
		           $Script:ControlledFolderAccess = $false
		       }
		  }
	    }
	}

	#Check for a pending reboot
	$PendingActions = @(
	       #CBS pending
	       "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
	       "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress",
	       "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending",
               #Windows Update pending
	       "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\PostRebootReporting",
	       "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
	)
	if  (($PendingActions | Test-Path) -contains $true)
	{
	      Write-Information -MessageData "" -InformationAction Continue
	      Write-Warning -Message $Localization.RebootPending
	      Write-Information -MessageData "" -InformationAction Continue

	      exit
	}

	#Checking whether all necessary file exist in the script folder
	$Files = @(
	     "$PSScriptRoot\..\Binaries\LGPO.exe",
	     "$PSScriptRoot\..\Binaries\Microsoft.Windows.SDK.NET.dll",
	     "$PSScriptRoot\..\Binaries\WinRT.Runtime.dll"
	)
	if (($Files | Test-Path) -contains $false)
	{
	     Write-Information -MessageData "" -InformationAction Continue
	     Write-Warning -Message ($Localization.Bin -f [IO.Path]::GetFullPath("$PSScriptRoot\..\Binaries"))
	     Write-Information -MessageData "" -InformationAction Continue

	     exit
	}
	$Signature = @{
	       Namespace    = "WinAPI"
	       Name         = "Winbrand"
	       Language     = "CSharp"
	       CompilierOptions = $CompilerOptions
	       MemberDefinition = @"
[DllImport("Winbrand.dll", CharSet = CharSet.Unicode)]
public extern static string BrandingFormatString(string sFormat);
"@
	}
	if (-not ("WinAPI.Winbrand" -as [type]))
	{
	      Add-Type @Signature
	}

	if ([WinAPI.Winbrand]::BrandingFormatString("%WINDOWS_LONG%") -notmatch "Windows 11")
	{
	      Write-Information -MessageData "" -InformationAction Continue

	      #Windows 11 Pro
	      $Windows_Long = [WinAPI.Winbrand]::BrandingFormatString("%WINDOWS_LONG%")
	      $Windows_Long_First_Item = $Windows_Long.split(" ")[0]
	      $Windows_Long_Second_Item = $Windows.Long.split(" ")[1]
	      #Windows 11
	      $Windows_Long = ($Windows_Long_First_Item, $Windows_Long_Second_Item) -join " "

	      #24h2
	      $DisplayVersion = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\Windows nt\CurrentVersion" -Name DisplayVersion

	      Write-Warning -Message ($Localization.UnsupportedOSBuild -f $Windows_Long, $DisplayVersion)
	      Write-Information -MessageData "" -InformationAction Continue

	      #Receive update for other Microsoft products when you update Windows
	      New-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings -Name AllowMUUpdateService -PropertyType DWord -Value 1 -Force

	      #Check for update 
	      Start-Process -FilePath "$env:SystemRoot\System32\UsoClient.exe" -ArgumentList StartInteractiveScan

	      exit
	}
	if ($env:WT_SESSION)
	{
	     $ParentProcessID = (Get-CimInstance -ClassName Win32_Process -Filter ProcessID=$PID).ParentProcessID
	     $WindowTerminalVersion = (Get-Process -Id $ParentProcessID).FileVersion
	     $WindowsTerminalVersion = "{0}.{1}.{2}" -f $WindowsTerminalVersion.Split(".")

	     if ([System.Version]$WindowsTerminalVersion -lt [System.Version]"1.22.0")
	     {
	         Write-Information -MessageData "" -InformationAction Continue
		 Write-Warning -Message $Localization.UnsupportedWindowsTerminal
		 Write-Information -MessageData "" -InformationAction Continue

		 Start-Process -FilePath "ms-windows-store://pdp/?productid=9NODX20HK701"

		 #Check for UWP app updates
		 Get-CimInstance -ClassName MDM_EnterpriseModernAppManagement_AppManagement01 -Namespace root/CIMV2/ndm/dmmap | Invoke-CimMethod -MethodName UpdateScanMethod
		 
		 exit
	     }
	}
	
	#Detect Windows Build version
	switch ((Get-CimInstance -ClassName CIM_OperatingSystem).BuildNumber)
	{
	     {$_ -lt 26100}
	     {
	          Write-Information -MessageData "" -InformationAction Continue
		  Write-Warning -Message ($Localization.UnsupportOSBuild -f [WinAPI.Winbrand]::BrandingFormatString("%WINDOWS_LONG%"))
		  Write-Information -MessageData "" -InformationAction Continue

		  New-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings -Name AllowMUUpdateService -PropertyType DWord -Value 1 -Force

		  #Check for UWP app updates
		  Get-CimInstance -ClassName MDM_EnterpriseModernAppManagement_AppManagement01 -Namespace root/CIMV2/mdm/dmmap | Invoke-CimMethod -MethodName UpdateScanMethod

		  #Check for updates
		  Start-Process -FilePath "$env:SystemRoot\System32\UsoClient.exe" -ArgumentList StartInteractiveScan

		  #Open the "Windows Update" page
		  Start-Process -FilePath "ms-settings:windowsupdate"

		  exit
	     }
	     "26100"
	     {
	          if((Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\Windows nt\CurrentVersion" -Name UBR) -lt $LatestSupportedBuild)
		  {
		       $CurrentBuild = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\Windows nt\CurrentVersion" -Name CurrentBuild
		       $UBR = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\Windows nt\CurrentVersion" -Name UBR

		       Write-Information -MessageData "" -InformationAction Continue
		       Write-Warning -Message ($Localization.UpdateWarning -f $CurrentBuild, $UBR, $LatestSupportedBuild)
		       Write-Information -MessageData "" -InformationAction Continue
			# Receive updates for other Microsoft products when you update Windows
			New-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings -Name AllowMUUpdateService -PropertyType DWord -Value 1 -Force

			# Check for UWP apps updates
			Get-CimInstance -ClassName MDM_EnterpriseModernAppManagement_AppManagement01 -Namespace root/CIMV2/mdm/dmmap | Invoke-CimMethod -MethodName UpdateScanMethod

			# Check for updates
			Start-Process -FilePath "$env:SystemRoot\System32\UsoClient.exe" -ArgumentList StartInteractiveScan

			# Open the "Windows Update" page
			Start-Process -FilePath "ms-settings:windowsupdate"

			exit
		  }
	     }
	}

	#Enable back the SysMain service if it was disable by harmful tweakers
	if ((Get-Service -Name SysMain).Status -eq "Stopped")
	{
	     Get-Service -Name SysMain | Set-Service -StartupType Automatic
	     Get-Service -Name SysMain | Start-Service

	     Start-Process -FilePath "https://www.outsitethebox.ms/19318"
	}

	#Automatically manage paging file size for all drives
	if (-not (Get-CimInstance -ClassName CIM_ComputerSystem).AutomaticManagedPageFile)
	{
	     Get-CimInstance -ClassName CIM_ComputerSystem | Set-CimInstance -Property @{AutomaticManagedPageFile = $true}
	}

	Get-ChildItem -Path "$env:TEMP\LGPO.txt" -Force -ErrorAction Ignore | Remove-Item -Force -ErrorAction Ignore

	#Save all opened folders in order to restore them after File Explorer restrart
	try 
	{
	     $Script:OpeneFolders = {(New-Object -ComObject Shell.Application).Windows() | ForEach-Object -Process {$_.Document.Folder.Self.Path}}.Invoke()
	}
	catch [System.Management.Automation.PropertyNotFoundException]
	{}

	if($Warning)
	{
	     Write-Information -MessageData "" -InformationAction Continue
	     [string]$PresetName = ((Get-PSCallStack).Position | Where-Object -FilterScript {$_.File}).File | Where-Object -FilterScript {$_.EndsWith(".ps1")}
	     Write-Verbose -Message ($Localization.CustomizationWarning -f "`"$PresetName`"") -Verbose

	     do
	     {
	           $Choice = Show-Menu -Menu @($Yes, $No) -Default 2

		   switch ($Choice)
		   {
		        $Yes
			{
			    continue
			}
			$No
			{
			    Invoke-Item -Path $PresetName

			    exit
			}
			$KeyboardArrows {}
		   }
	     }
	     until ($Choice -ne $KeyboardArrows)
	}
}

