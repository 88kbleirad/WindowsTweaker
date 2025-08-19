function InputMethod
{
	param
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "English"
		)]
		[switch]
		$English,

		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Default"
		)]
		[switch]
		$Default
	)

	switch ($PSCmdlet.ParameterSetName)
	{
		"English"
		{
			Set-WinDefaultInputMethodOverride -InputTip "0409:00000409"
		}
		"Default"
		{
			Remove-ItemProperty -Path "HKCU:\Control Panel\International\User Profile" -Name InputMethodOverride -Force -ErrorActionIgnore
		}
	}
}
