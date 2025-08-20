function ThumbnailCacheRemoval
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

	switch ($PSCmdlet.ParameterSetName)
	{
		"Disable"
		{
			New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Thumbnail Cache" -Name Autorun -PropertyType DWord -Value 0 -Force

			New-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\VolumeCache\Thumbnail Cache" -Name Autorun -PropertyType DWord -Value 0 -Force
		}
		"Enable"
		{
			New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Thumbnail Cache" -Name Autorun -PropertyType DWord -Value 3 -Force
			New-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Thumbnail Cache" -Name Autorun -PropertyType DWord -Value 3 -Force
		}
	}
}
