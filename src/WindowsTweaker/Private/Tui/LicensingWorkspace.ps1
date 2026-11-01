# WindowsTweaker - Licensing & Activation Diagnostics workspace (TUI).
#
# A dedicated terminal workspace: status summary, findings, details, explicit actions and
# report export. All collection is read-only; the only action that asks Windows to do
# something is the explicit activation request (documented slmgr /ato) with a purpose
# disclosure before it runs. No full keys, tokens, hostnames or machine identifiers are
# displayed or exported by default.

<#
.SYNOPSIS
    Renders the licensing workspace to the cell grid.
#>
function Add-WtLicensingView
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][hashtable]$License
    )

    $Screen = $State.Screen
    $Width = $Screen.Width
    $Height = $Screen.Height

    Set-WtScreenText -Screen $Screen -Row 1 -Column 2 -Text (Get-WtString -Key 'Lic.Title') -Style 'Title'
    $Collected = if ($License.CollectedUtc) { $License.CollectedUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') } else { '-' }
    Set-WtScreenText -Screen $Screen -Row 2 -Column 2 -Text (Get-WtString -Key 'Lic.Collected' -Arguments @($Collected)) -Style 'ItemMeta' -MaxWidth ($Width - 4)

    $Inventory = $License.Inventory
    $Active = $Inventory.Active
    $Top = 4

    # Status summary box.
    $StatusLine = if ($Inventory.Unreadable)
    {
        (Get-WtString -Key 'Lic.Status.Unreadable') + ' — ' + $Inventory.Reason
    }
    elseif (-not $Active)
    {
        Get-WtString -Key 'Lic.Status.Unknown'
    }
    else
    {
        (Get-WtString -Key "Lic.Status.$($Active.LicenseStatus)") + ' (' + (Get-WtString -Key 'Lic.Status.Raw' -Arguments @($Active.LicenseStatusRaw)) + ')'
    }

    Add-WtScreenBox -Screen $Screen -Row $Top -Column 2 -Width ($Width - 4) -Height 5 -Title (Get-WtString -Key 'Lic.Summary') -BorderStyle 'Border' -TitleStyle 'PanelTitle' -Style 'Dialog'
    $Row = $Top + 1
    Set-WtScreenText -Screen $Screen -Row $Row -Column 4 -Text $StatusLine -Style 'Item' -MaxWidth ($Width - 8)
    $Row++

    if ($Active)
    {
        Set-WtScreenText -Screen $Screen -Row $Row -Column 4 -Text (Get-WtString -Key 'Lic.Product' -Arguments @($Active.ProductName)) -Style 'ItemMeta' -MaxWidth ($Width - 8)
        $Row++
        Set-WtScreenText -Screen $Screen -Row $Row -Column 4 -Text (Get-WtString -Key 'Lic.Channel' -Arguments @($Active.LicenseChannel)) -Style 'ItemMeta' -MaxWidth ($Width - 8)
        $Row++
        if ($Active.PartialProductKey)
        {
            Set-WtScreenText -Screen $Screen -Row $Row -Column 4 -Text (Get-WtString -Key 'Lic.PartialKey' -Arguments @($Active.PartialProductKey)) -Style 'ItemMeta' -MaxWidth ($Width - 8)
            $Row++
        }
        if ($null -ne $Active.GraceRemaining)
        {
            Set-WtScreenText -Screen $Screen -Row $Row -Column 4 -Text (Get-WtString -Key 'Lic.Grace' -Arguments @($Active.GraceRemaining)) -Style 'ItemMeta' -MaxWidth ($Width - 8)
            $Row++
        }
    }

    # Time synchronization finding.
    $Row = $Top + 6
    Set-WtScreenText -Screen $Screen -Row $Row -Column 2 -Text (Get-WtString -Key 'Lic.Time.Title') -Style 'PanelTitle' -MaxWidth ($Width - 4)
    $Row++
    $Time = $License.Time
    $TimeLine = (Get-WtString -Key 'Lic.Time.Now' -Arguments @($Time.LocalNow))
    if ($Time.Synchronized -eq $true) { $TimeLine += ' | ' + (Get-WtString -Key 'Lic.Time.Synced') }
    elseif ($Time.Synchronized -eq $false) { $TimeLine += ' | ' + (Get-WtString -Key 'Lic.Time.NotSynced') }
    Set-WtScreenText -Screen $Screen -Row $Row -Column 4 -Text $TimeLine -Style 'Item' -MaxWidth ($Width - 8)
    $Row++
    Set-WtScreenText -Screen $Screen -Row $Row -Column 4 -Text (Get-WtString -Key 'Lic.Time.Service' -Arguments @($Time.Service, $Time.StartType)) -Style 'ItemMeta' -MaxWidth ($Width - 8)

    # Component availability.
    $Row += 2
    Set-WtScreenText -Screen $Screen -Row $Row -Column 2 -Text (Get-WtString -Key 'Lic.Components.Title') -Style 'PanelTitle' -MaxWidth ($Width - 4)
    $Row++
    $Components = $License.Components
    $CompLine = (Get-WtString -Key 'Lic.Components.Slmgr' -Arguments @($(if ($Components.SlmgrAvailable) { Get-WtString -Key 'Common.Yes' } else { Get-WtString -Key 'Common.No' })))
    $CompLine += ' | ' + (Get-WtString -Key 'Lic.Components.Service' -Arguments @($Components.Service, $Components.ServiceStartType))
    Set-WtScreenText -Screen $Screen -Row $Row -Column 4 -Text $CompLine -Style 'Item' -MaxWidth ($Width - 8)
    $Row++
    if ($Components.LastActivationError)
    {
        Set-WtScreenText -Screen $Screen -Row $Row -Column 4 -Text (Get-WtString -Key 'Lic.Components.LastError' -Arguments @($Components.LastActivationError)) -Style 'Warning' -MaxWidth ($Width - 8)
        $Row++
    }

    # Organization-managed configuration (presence only).
    $Row += 2
    Set-WtScreenText -Screen $Screen -Row $Row -Column 2 -Text (Get-WtString -Key 'Lic.Org.Title') -Style 'PanelTitle' -MaxWidth ($Width - 4)
    $Row++
    $Managed = if ($License.Org.Managed) { Get-WtString -Key 'Lic.Org.Managed' } else { Get-WtString -Key 'Lic.Org.NotManaged' }
    Set-WtScreenText -Screen $Screen -Row $Row -Column 4 -Text $Managed -Style 'Item' -MaxWidth ($Width - 8)

    # Footer with actions.
    $Hint = Get-WtString -Key 'Lic.Hint'
    Set-WtScreenText -Screen $Screen -Row $Height -Column 2 -Text $Hint -Style 'Muted' -MaxWidth ($Width - 4)
}

<#
.SYNOPSIS
    Shows the export preview and (on confirmation) writes the redacted report.
#>
function Export-WtLicensingReport
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][hashtable]$License
    )

    $Payload = Get-WtLicensingExportPayload -License $License
    $PreviewLines = @(
        (Get-WtString -Key 'Lic.Export.Preview'),
        (Get-WtString -Key 'Lic.Export.Redacted'),
        '',
        (Get-WtString -Key 'Lic.Export.Scope'),
        (Get-WtString -Key 'Lic.Export.Source' -Arguments @([string]$Payload.source))
    )

    if (-not (Confirm-WtTui -State $State -Title (Get-WtString -Key 'Lic.Export.Title') -Lines $PreviewLines -Tone 'Warning'))
    {
        return
    }

    $Path = Read-WtTuiText -State $State -Title (Get-WtString -Key 'Lic.Export.Title') `
        -Label (Get-WtString -Key 'Lic.Export.PathLabel') `
        -Initial (Join-Path (Get-WtDataRoot) ("licensing-{0}.json" -f (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')))

    if (-not $Path) { return }

    try
    {
        Write-WtTextFile -Path $Path -Value (ConvertTo-WtJson -InputObject $Payload -Depth 12)
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Lic.Export.Title') `
            -Lines @((Get-WtString -Key 'Lic.Export.Exported' -Arguments @($Path))) -Tone 'Success'
    }
    catch
    {
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Lic.Export.Title') -Lines @($_.Exception.Message) -Tone 'Error'
    }
}

<#
.SYNOPSIS
    Requests activation with a purpose disclosure.
.DESCRIPTION
    The purpose, possible network activity, and permission requirements are shown before
    the documented slmgr /ato command is run. The result is re-read from the inventory;
    "accepted" is never equated with "activated".
#>
function Invoke-WtLicensingAction
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][hashtable]$License
    )

    $Lines = @(
        (Get-WtString -Key 'Lic.Activate.Purpose'),
        (Get-WtString -Key 'Lic.Activate.Network'),
        (Get-WtString -Key 'Lic.Activate.Permissions'),
        (Get-WtString -Key 'Lic.Activate.Note')
    )

    if (-not (Confirm-WtTui -State $State -Title (Get-WtString -Key 'Lic.Activate.Title') -Lines $Lines -Tone 'Warning'))
    {
        return
    }

    $Result = Invoke-WtLicensingActivationRequest

    $ReportLines = @()
    if ($Result.Accepted)
    {
        $ReportLines += (Get-WtString -Key 'Lic.Activate.Accepted')
    }
    else
    {
        $ReportLines += (Get-WtString -Key 'Lic.Activate.Failed' -Arguments @($Result.ErrorDetail))
    }

    if ($Result.StatusAfter -and -not $Result.StatusAfter.Unreadable -and $Result.StatusAfter.Active)
    {
        $After = $Result.StatusAfter.Active
        $ReportLines += (Get-WtString -Key 'Lic.Activate.StatusAfter' -Arguments @((Get-WtString -Key "Lic.Status.$($After.LicenseStatus)"), $After.LicenseStatusRaw))
    }
    else
    {
        $ReportLines += (Get-WtString -Key 'Lic.Activate.StatusUnknown')
    }

    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Lic.Activate.Title') -Lines $ReportLines -Tone $(if ($Result.Accepted) { 'Success' } else { 'Warning' })
}

<#
.SYNOPSIS
    Runs the licensing workspace: bounded loop, explicit actions, responsive keys.
#>
function Show-WtTuiLicensing
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $License = Read-WtLicensingDiagnostics
    $State.Licensing = $License

    $State.Screen.Dirty = $true

    try
    {
        while ($true)
        {
            $Key = Invoke-WtTuiFrame -State $State
            if ($null -eq $Key)
            {
                if ($State.Exit) { break }
                continue
            }

            switch ($Key.Name)
            {
                'Escape' { return }
                'Char'
                {
                    $C = ([string]$Key.Char).ToLowerInvariant()
                    switch ($C)
                    {
                        'r'
                        {
                            $License = Read-WtLicensingDiagnostics -Refresh
                            $State.Licensing = $License
                            Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Lic.Refreshed') -Tone 'StatusOk'
                        }
                        'e' { Export-WtLicensingReport -State $State -License $License }
                        'a' { Invoke-WtLicensingAction -State $State -License $License }
                        '?' { Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Lic.Title') -Lines @((Get-WtString -Key 'Lic.Help')) }
                    }
                }
                default { }
            }
        }
    }
    finally
    {
        $State.Licensing = $null
        $State.Screen.Dirty = $true
    }
}
