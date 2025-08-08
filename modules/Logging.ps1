function Logging
{
	$TranscriptFilename = "Log-$((Get-Date).ToString("dd.MM.yyyy-HH-MM))"
	Start-Transcript -Path $PSScriptRoot\..\$TranscriptFilename.txt -Force
}


