function Import-Associations
{
	Add-Type -AssemblyName System.Windows.Forms
	$OpenFileDialog = New-Object -TypeName System.Windows.Forms.OpenFileDialog
	$OpenFileDialog.Filter = "*.json|*.json|{0} (*.*)|*.*" -f $Localization.AllFilesFilter
	$OpenFileDialog.InitialDirectory = $PSScriptRoot
	$OpenFileDialog.MultiSelect = $false

	$Focus = New-Object -TypeName System.Windows.Forms.Form -Property @{TopMost = $true}
	$OpenFileDialog.ShowDialog($Focus)

	if ($OpenFileDialog.FileName)
	{
		$AppxProgIds = @((Get-ChildItem -Path "Registry::HKEY_CLASSES_ROOT\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\PackageRepository\Extensions\ProgIDs").PSChildName)

		try 
		{
			$JSON = Get-Content -Path $OpenFileDialog.FileName -Encoding UTF8 -Force | ConvertFrom-JSON
		}
		catch [System.Exception]
		{
			Write-Warning -Message ($Localization.RestartFunction -f $MyInvocation.Line.Trim())
			Write-Error -Message ($Localization.RestartFunction -f $MyInvocation.Line.Trim()) -ErrorAction SilentlyContinue

			return
		}

                $JSON | ForEach-Object -Process {
			if ($AppxProgIds -contains $_.ProgId)
			{
				Write-Information -MessageData "" -InformationAction Continue
				Write-Verbose -Message ([string]($_.ProgId, "|", $_.Extension)) -Verbose

				Set-Association -ProgramPath $_.ProgId -Extension $_.Extension
			}
			else 
			{
				Write-Information -MessageData "" -InformationAction Continue
				Write-Verbose -Message ([string]($_.ProgramPath, "|", $_.Extension, "|", $_.Icon)) -Verbose

				Set-Association -ProgramPath $_.ProgramPath -Extension $_.Extension -Icon $_.Icon
			}
		}
	}
}
