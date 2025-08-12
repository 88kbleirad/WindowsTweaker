function TaskbarSearch 
{
	param
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Hide"
		)]
		[switch]
		$Hide,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "SearchIcon"
		)]
		[switch]
		$SearchIcon,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "SearchIconLabel"
		)]
		[switch]
		$SearchIconLabel,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "SearchBox"
		)]
		[switch]
		$SearchBox
	)

	New-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Search\DisableSearch -Name value -PropertyType DWord -Value 0 -Force
	Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name DisableSearch,SearchOnTaskbarMode -Force -ErrorAction Ignore
	Set-Policy -Scope Computer -Path "SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name DisableSearch -Type DELETE
	Set-Policy -Scope Computer -Path "SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name SearchOnTaskbarMode -Type DELETE

	switch ($PSCmdlet.ParameterSetName)
	{
		"Hide"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Search -Name SearchBoxTaskbarMode -PropertyType DWord -Value 0 -Force
		}
		"SearchIcon"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Search -Name SearchBoxTaskbarMode -PropertyType DWord -Value 1 -Force
		}
		"SearchIconLabel"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Search -Name SearchBoxTaskbarMode -PropertyType DWord -Value 3 -Force
		}
		"SearchBox"
		{
			New-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Search -Name SearchBoxTaskbarMode -PropertyType DWord -Value 2 -Force
		}
	}
}
