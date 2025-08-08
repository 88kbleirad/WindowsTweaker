function script:Set-Policy
{
	[CmdletBinding()]
	param
	(
		[Parameter(
		      Mandatory = $true,
		      Position = 1
		)]
		[string]
		[ValidateSet("Computer", "User")]
		$Scope,

		[Parameter(
		      Mandatory = $true,
		      Position = 2
		)]
		[string]
		$Path,

		[Parameter(
		      Mandatory = $true,
		      Position = 3
		)]
		[string]
		$Name,

		[Parameter(
		      Mandatory = $true,
		      Position = 4
		)]
		[ValidateSet("DWORD", "SZ", "EXSZ", "DELETE")]
		[string]
		$type

		[Parameter(
		      Mandatory = $false,
		      Position = 5
		)]
		$Value
	)
	if (-not (Test-Path -Path "$env:SystemRoot\System32\gpedit.msc"))
	{
		return
	}

	switch ($Type)
	{
		"DELETE"
		{
			$Policy = @"
$Scope
$($Path)
$($Name)
$($Type)`n
"@
		}
		default
		{
			$Policy = @"
$Scope
$($Path)
$($Name)
$($Type):$($Value)`n
"@
		}
	}
	Add-Content -Path "$env:TEMP\LGPO.txt" -value $Policy -Encoding utf8NoBOM -Force
}

function DiagTrackService
{
	param
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Disable"
		)]
		[switch]
		$Disable,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Enable"
		)]
		[switch]
		$Enable
	)

	if(-not ("WinAPI.GetStrings" -as [type]))
	{ 
                $PresetName = Split-Path -Path (((Get-PSCallStack).Position | Where-Object -FilterScript {$_.File}).File | Where-Object -FilterScript {$_.EndsWith(".ps1")}) -Leaf

		Write-Information -MessageData "" -InformationAction Continue
		Write-Verbose -Message ($Localization.IntialActionsCheckFailed -f $PresetName) -Verbose
		Write-Information -MessageData "" -InformationAction Continue

		exit
	}

	switch ($PSCmdlet.ParameterSetName)
	{
		"Disable"
		{
			Get-Service -Name DiagTrack -ErrorAction Ignore | Stop-Service -Force
			Get-Service -Name DiagTrack -ErrorAction Ignore | Stop-Service -StartupType Disabled
			Get-NetFirewallRule -Group DiagTrack -ErrorAction Ignore |
			 Set-NetFirewallRule -Enabled True -Action Block
		}
		"Enable"
		{
			Get-Service -Name DiagTrack -ErrorAction Ignore | Set-Service -StartupType Automatic
			Get-Service -Name DiagTrack -ErrorAction Ignore | Start-Sevice
			Get-NetFirewallRule -Group DiagTrack -ErrorAction Ignore |
			Set-NetFirewallRule -Enabled True -Action Allow
		}
	}
}


