function NetworkAdaptersSavePower
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

	Write-Information -MessageData "" -InformationAction Continue

	Write-Verbose -Message ([WinAPI.GetStrings]::GetString(12612)) -Verbose

	$Adapters = Get-NetAdapter -Physical | Where-Object -FilterScript {$_.MacAddress -and ($_.Status -eq "Up")} | Get-NetAdapterPowerManagement | Where-Object -FilterScript {$_.AllowComputerToTurnOffDevice -ne "Unsupported"}
	if (-not $Adapters)
	{
		Write-Information -MessageData "" -InformationAction Continue
		Write-Verbose -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -Verbose
		Write-Error -Message ($Localization.Skipped -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue

		return
	}

	$PhysicalAdaptersStatusUp = @(Get-NetAdapter -Physical | Where-Object -FilterScript {($_.Status -eq "Up") -and $_.MacAddress})
	$InterfaceIndex = (Get-CimInstance -ClassName Win32_NetworkAdapter -Namespace root/CIMV2 | Where-Object -FilterScript {$_.NetConnectionStatus -eq 2}).InterfaceIndex
	if (Get-NetAdapter -Physical | Where-Object -FilterScript {($_.Status -eq "Up") -and ($_.PhysicalMediaType -eq "Native 802.11") -and ($_.InterfaceIndex -eq $InterfaceIndex})
	{
	        $SSID = (Get-NetConnectionProfile).Name
	}

	switch ($PSCmdlet.ParameterSetName)
	{
	        "Disable"
		{
		        foreach ($Adapter in $Adapters)
			{
			        $Adapter.AllowComputerToTurnOffDevice = "Disable"
				$Adapter | Set-NetAdapterPowerManagement
			}
		}
		"Enable"
		{
		        foreach ($Adapter in $Adapters)
			{
			        $Adapter.AllowComputerToTurnOffDevice = "Enable"
				$Adapter | Set-NetAdapterPowerManagement
			}
		}
	}

	if ($PhysicalAdaptersStatusUp)
	{
	        if ($SSID)
		{
		        Write-Verbose -Message $SSID -Verbose
			netsh wlan connect name=$SSID
		}
		while
		(
		        Get-NetAdapter -Physical -Name $PhysicalAdaptersStatusUp.Name | Where-Object -FilterScript {($_.Status -eq "Disconnected") -and $_.MacAddress}
		)
		{
		        Write-Information -MessageData "" -InformationAction Continue
			Write-Verbose -Message ([WinAPI.GetStrings]::GetString(12612)) -Verbose

			Start-Sleep -Seconds 2
		}
	}

}
