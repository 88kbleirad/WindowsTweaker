function EventViewerCustomView
{
	param
	(
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Enable"
		)]
		[switch]
		$Enable,
		 
		[Parameter(
		        Mandatory = $true,
		        ParameterSetName = "Disable"
		)]
		[switch]
		$Disable
	)

	switch ($PSCmdlet.ParameterSetName)
	{
		"Enable"
		{
			auditpol /set /subcategory:"{0CCE922B-69AE-11D9-BED3-505054503030}" /success:enable /failure:enable

			New-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit -Name ProcessCreationIncludeCmdLine_Enabled -PropertyType DWord -Value 1 -Force

			Set-Policy -Scope Computer -Path SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit -Name ProcessCreationIncludeCmdLine_Enabled -Type DWORD -Value 1

			$XML = @"
<ViewerConfig>
	<QueryConfig>
		<QueryParams>
			<UserQuery />
		</QueryParams>
		<QueryNode>
			<Name>$($Localization.EventViewerCustomViewName)</Name>
			<Description>$($Localization.EventViewerCustomViewDescription)</Description>
			<QueryList>
				<Query Id="0" Path="Security">
					<Select Path="Security">*[System[(EventID=4688)]]</Select>
				</Query>
			</QueryList>
		</QueryNode>
	</QueryConfig>
</ViewerConfig>
"@
                        
			if (-not (Test-Path -Path "$env:ProgramData\Microsoft\Event Viewer\Views"))
	                {
                                New-Item -Path "$env:ProgramData\Microsoft\Event Viewer\Views" -ItemType Directory -Force
	                }

	                Set-Content -Path "$env:ProgramData\Microsoft\Event Viewer\Views\ProcessCreation.xml" -Value $XML -Encoding utf8NoBOM -NoNewline -Force
		}
                "Disable"
                {
		        Remove-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrnetVersion\Policies\System\Audit -Name ProcessCreationIncludeCmdLine_Enabled -Force -ErrorAction Ignore

	                Set-Policy -Scope Computer -Path SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit -Name ProcessCreationIncludeCmdLine_Enabled -Type DELETE
	                
	                Remove-Item -Path "$env:ProgramData\Microsoft\Event Viewer\Views\ProcessCreation.xml" -Force -ErrorAction Ignore
		}
	}
}
