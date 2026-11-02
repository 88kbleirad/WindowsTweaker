# WindowsTweaker - Licensing & Activation workspace (TUI).
#
# The main screen of Windows activation. It answers, in this order: which Windows is installed,
# the *observed* licensing status Windows reports (never an inference), which Windows-only
# activation method is selected and whether that method is permanent or time-limited, whether the
# pinned upstream file is ready, and what the last activation operation reported.
#
# The machine's current licensing state and the last operation's outcome are separate things and
# stay separate on this screen: "nothing has run in this session" is never presented as "Windows
# is not activated".
#
# The observed status comes from one shared, refreshed snapshot (LicensingUiState). The screen
# shows when it was collected and marks it stale when it is older than the freshness bound.
#
# One primary action: A runs the selected method directly. The upstream script is started with the
# one documented switch of that method, so its interactive menu is never shown and no keystroke is
# fed to it. Office, ESU, edition conversion, KMS-host, APPX and reset operations are not reachable
# from here at all. Download provenance, hashes, documentation, updates, removal and the method
# setting live in the second screen (S, Private/Tui/ExternalToolWorkspace.ps1).
#
# Everything this screen collects is read-only. Navigating, refreshing and drawing never download
# and never execute anything; the only two actions that do something are explicit, confirmed, and
# refused outright in dry-run mode.

<#
.SYNOPSIS
    Returns the localised label of one Windows activation method.
#>
function Get-WtActivationMethodText
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][object]$Method)

    switch ([string]$Method.Id)
    {
        'HWID' { return (Get-WtString -Key 'Act.Method.HWID') }
        'TSforge' { return (Get-WtString -Key 'Act.Method.TSforge') }
        'OnlineKMS' { return (Get-WtString -Key 'Act.Method.OnlineKMS') }
        default { return [string]$Method.Id }
    }
}

<#
.SYNOPSIS
    Returns the localised duration model of one method: permanent or time-limited.
.DESCRIPTION
    The model is the short form shown next to the method; the full upstream statement (how long the
    activation lasts and what renews it) is the per-method sentence in the settings screen.
#>
function Get-WtActivationDurationModelText
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][object]$Method)

    if ([string]$Method.DurationModel -eq 'TimeLimited')
    {
        return (Get-WtString -Key 'Act.DurationModel.TimeLimited')
    }

    return (Get-WtString -Key 'Act.DurationModel.Permanent')
}

<#
.SYNOPSIS
    Returns the full upstream duration statement of one method.
#>
function Get-WtActivationDurationText
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][object]$Method)

    switch ([string]$Method.Id)
    {
        'HWID' { return (Get-WtString -Key 'Act.Duration.HWID') }
        'TSforge' { return (Get-WtString -Key 'Act.Duration.TSforge') }
        'OnlineKMS' { return (Get-WtString -Key 'Act.Duration.OnlineKMS') }
        default { return (Get-WtString -Key 'Act.DurationModel.Permanent') }
    }
}

<#
.SYNOPSIS
    Returns the upstream internet requirement of one method.
#>
function Get-WtActivationInternetText
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][object]$Method)

    switch ([string]$Method.Id)
    {
        'HWID' { return (Get-WtString -Key 'Act.Internet.HWID') }
        'TSforge' { return (Get-WtString -Key 'Act.Internet.TSforge') }
        'OnlineKMS' { return (Get-WtString -Key 'Act.Internet.OnlineKMS') }
        default { return (Get-WtString -Key 'Act.Internet.HWID') }
    }
}

<#
.SYNOPSIS
    Returns the localised text of one edition-compatibility status.
#>
function Get-WtActivationCompatibilityText
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][string]$Status)

    switch ($Status)
    {
        'Compatible' { return (Get-WtString -Key 'Act.Compat.Compatible') }
        'NotWindows' { return (Get-WtString -Key 'Act.Compat.NotWindows') }
        'ServerEdition' { return (Get-WtString -Key 'Act.Compat.ServerEdition') }
        'EvaluationEdition' { return (Get-WtString -Key 'Act.Compat.EvaluationEdition') }
        'BuildTooOld' { return (Get-WtString -Key 'Act.Compat.BuildTooOld') }
        'BuildUnknown' { return (Get-WtString -Key 'Act.Compat.BuildUnknown') }
        'EditionUnknown' { return (Get-WtString -Key 'Act.Compat.EditionUnknown') }
        default { return (Get-WtString -Key 'Act.Compat.Unknown') }
    }
}

<#
.SYNOPSIS
    Returns the tool readiness line shown on the main screen.
#>
function Get-WtActivationToolText
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Tool = $State.ActivationTool
    if (-not $Tool)
    {
        return (Get-WtString -Key 'Mas.Status.Unsupported')
    }

    if (-not $Tool.Supported)
    {
        return (Get-WtString -Key 'Mas.Status.Unsupported')
    }

    return (Get-WtString -Key (Get-WtExternalToolStatusKey -Status $Tool.Status))
}

<#
.SYNOPSIS
    Returns the display text of the observed licensing status, including its raw code.
.DESCRIPTION
    Pure: it reads the shared snapshot and produces the line, so every view that calls it
    shows the same status. A stale or unreadable snapshot is reported as such instead of
    being presented as a status.
#>
function Get-WtObservedLicensingStatusText
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Ui = Get-WtLicensingUiState -State $State
    $License = $Ui.License

    if (-not $License)
    {
        return (Get-WtString -Key 'Lic.Status.Unreadable')
    }

    $Inventory = $License.Inventory
    if ($Inventory.Unreadable)
    {
        return (Get-WtString -Key 'Lic.Status.Unreadable') + ' - ' + (Get-WtString -Key 'Lic.Status.Raw' -Arguments @('?'))
    }

    $Active = $Inventory.Active
    if (-not $Active)
    {
        return (Get-WtString -Key 'Lic.Status.Unknown') + ' (' + (Get-WtString -Key 'Lic.Status.Raw' -Arguments @('?')) + ')'
    }

    return (Get-WtString -Key "Lic.Status.$($Active.LicenseStatus)") + ' (' + (Get-WtString -Key 'Lic.Status.Raw' -Arguments @($Active.LicenseStatusRaw)) + ')'
}

<#
.SYNOPSIS
    Returns true when the shared licensing snapshot is older than the freshness bound.
.DESCRIPTION
    The bound is deliberately generous - a few minutes - because the observed status is a
    snapshot, not a live value; what matters is that the UI never presents a very old
    snapshot as if it were the current state.
#>
function Test-WtLicensingSnapshotFresh
{
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $false)][int]$MaxAgeSeconds = 300
    )

    $Ui = Get-WtLicensingUiState -State $State
    if (-not $Ui.LicenseCollectionUtc) { return $false }
    return (([datetime]::UtcNow - [datetime]$Ui.LicenseCollectionUtc).TotalSeconds -le $MaxAgeSeconds)
}

<#
.SYNOPSIS
    Returns the display line for the last activation operation.
.DESCRIPTION
    This is the operation outcome, not the machine state. It is kept separate from the
    observed status, and the "nothing run yet" case is explicit.
#>
function Get-WtActivationOutcomeText
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Ui = Get-WtLicensingUiState -State $State

    if (-not $Ui.OperationRanThisSession)
    {
        return (Get-WtString -Key 'Lic.Outcome.None')
    }

    if ($Ui.OperationOutcome)
    {
        return [string]$Ui.OperationOutcome
    }

    return (Get-WtString -Key 'Lic.Outcome.None')
}

<#
.SYNOPSIS
    Returns the collection-time text of the current snapshot (or '-').
#>
function Get-WtLicensingCollectedText
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Ui = Get-WtLicensingUiState -State $State
    if (-not $Ui.LicenseCollectionUtc)
    {
        return (Get-WtString -Key 'Lic.Collected.Never')
    }

    return (Get-WtString -Key 'Lic.Collected' -Arguments @(([datetime]$Ui.LicenseCollectionUtc).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')))
}

<#
.SYNOPSIS
    Renders the main licensing & activation screen.
.DESCRIPTION
    The activation block carries the installed edition, the *observed* activation status with
    its raw code and collection time, the selected method with its duration model, the
    readiness of the pinned file, and the last operation outcome - kept apart from the status.
    When the snapshot is stale or the slmgr comparison disagrees, that is shown explicitly.
    The read-only diagnostics follow when the terminal has rows left, and are dropped first on
    a short window.
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
    $Layout = Get-WtTuiLayout -State $State
    $Bottom = $Screen.Height - $Layout.FooterRows
    $Inner = $Width - 8

    $Ui = Get-WtLicensingUiState -State $State
    Set-WtLicensingUiSnapshot -State $State -License $License -RawStatus $License.Inventory.Active
    $Ui = Get-WtLicensingUiState -State $State

    Set-WtScreenText -Screen $Screen -Row 1 -Column 2 -Text (Get-WtString -Key 'Lic.Title') -Style 'Title' -MaxWidth ($Width - 4)
    $Collected = Get-WtLicensingCollectedText -State $State
    Set-WtScreenText -Screen $Screen -Row 2 -Column 2 -Text $Collected -Style 'ItemMeta' -MaxWidth ($Width - 4)

    $Inventory = $License.Inventory
    $Active = $Inventory.Active
    $Edition = Get-WtWindowsActivationEdition -License $License -Environment $State.Environment
    $Method = Get-WtWindowsActivationMethodSetting

    $Row = 4
    if ($Row + 9 -le $Bottom)
    {
        Add-WtScreenBox -Screen $Screen -Row $Row -Column 2 -Width ($Width - 4) -Height 11 -Title (Get-WtString -Key 'Lic.Section.Activation') `
            -BorderStyle 'Border' -TitleStyle 'PanelTitle' -Style 'Dialog'

        $Line = $Row + 1

        $EditionText = if ($Edition.Name) { $Edition.Name } else { Get-WtString -Key 'Lic.Status.Unknown' }
        Set-WtScreenText -Screen $Screen -Row $Line -Column 4 -Text (Get-WtString -Key 'Lic.Edition' -Arguments @($EditionText)) -Style 'Item' -MaxWidth $Inner
        $Line++

        $StatusText = Get-WtObservedLicensingStatusText -State $State
        if (-not (Test-WtLicensingSnapshotFresh -State $State))
        {
            $StatusText += ' ' + (Get-WtString -Key 'Lic.Status.Stale')
        }
        $StatusStyle = if ($Ui.LicenseRaw -and [int]$Ui.LicenseRaw.LicenseStatusRaw -eq 1) { 'Success' } else { 'Warning' }
        Set-WtScreenText -Screen $Screen -Row $Line -Column 4 -Text (Get-WtString -Key 'Lic.ActStatus' -Arguments @($StatusText)) -Style $StatusStyle -MaxWidth $Inner
        $Line++

        if ($Ui.LicenseCollectionUtc)
        {
            Set-WtScreenText -Screen $Screen -Row $Line -Column 4 -Text (Get-WtString -Key 'Lic.CollectedAt' -Arguments @(([datetime]$Ui.LicenseCollectionUtc).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))) -Style 'ItemMeta' -MaxWidth $Inner
            $Line++
        }

        if ($Active -and $null -ne $Active.GraceRemaining)
        {
            Set-WtScreenText -Screen $Screen -Row $Line -Column 4 -Text (Get-WtString -Key 'Lic.Remaining' -Arguments @($Active.GraceRemaining)) -Style 'ItemMeta' -MaxWidth $Inner
            $Line++
        }

        if ($Active -and $Active.LicenseChannel)
        {
            Set-WtScreenText -Screen $Screen -Row $Line -Column 4 -Text (Get-WtString -Key 'Lic.Channel' -Arguments @($Active.LicenseChannel)) -Style 'ItemMeta' -MaxWidth $Inner
            $Line++
        }

        if ($Method)
        {
            $MethodLine = '{0} - {1}' -f (Get-WtActivationMethodText -Method $Method), (Get-WtActivationDurationModelText -Method $Method)
            Set-WtScreenText -Screen $Screen -Row $Line -Column 4 -Text (Get-WtString -Key 'Lic.SelectedMethod' -Arguments @($MethodLine)) -Style 'Item' -MaxWidth $Inner
        }
        else
        {
            Set-WtScreenText -Screen $Screen -Row $Line -Column 4 -Text (Get-WtString -Key 'Lic.SelectedMethod' -Arguments @((Get-WtString -Key 'Lic.Method.None'))) -Style 'Warning' -MaxWidth $Inner
        }
        $Line++

        Set-WtScreenText -Screen $Screen -Row $Line -Column 4 -Text (Get-WtString -Key 'Lic.ToolStatus' -Arguments @((Get-WtActivationToolText -State $State))) -Style 'Item' -MaxWidth $Inner
        $Line++

        $Outcome = Get-WtActivationOutcomeText -State $State
        Set-WtScreenText -Screen $Screen -Row $Line -Column 4 -Text (Get-WtString -Key 'Lic.Outcome' -Arguments @($Outcome)) -Style 'ItemMeta' -MaxWidth $Inner

        $Row += 11
    }
    else
    {
        # A very short window still shows what the action would do.
        $Line = Get-WtObservedLicensingStatusText -State $State
        Set-WtScreenText -Screen $Screen -Row $Row -Column 2 -Text (Get-WtString -Key 'Lic.ActStatus' -Arguments @($Line)) -Style 'Item' -MaxWidth ($Width - 4)
        $Row++
    }

    # Progress of a background download of the pinned dependency (real byte counts only).
    foreach ($ProgressLine in @(Get-WtExternalToolProgressLines -State $State))
    {
        if ($Row -gt $Bottom) { break }
        Set-WtScreenText -Screen $Screen -Row $Row -Column 2 -Text $ProgressLine -Style 'Pending' -MaxWidth ($Width - 4)
        $Row++
    }

    # The action map of this screen.
    if ($Row -le $Bottom)
    {
        Set-WtScreenText -Screen $Screen -Row $Row -Column 2 -Text (Get-WtString -Key 'Lic.Section.Actions') -Style 'PanelTitle' -MaxWidth ($Width - 4)
        $Row++
    }

    $Actions = @(
        @{ Key = 'A'; IconKey = 'Action.Apply'; Text = (Get-WtString -Key 'Lic.Action.Activate') },
        @{ Key = 'S'; IconKey = 'Action.Select'; Text = (Get-WtString -Key 'Lic.Action.Settings') }
    )
    foreach ($Action in $Actions)
    {
        if ($Row -gt $Bottom) { break }
        Set-WtScreenIconText -Screen $Screen -Row $Row -Column 4 -Width ($Width - 8) -IconKey $Action.IconKey -Text ('{0}  {1}' -f $Action.Key, $Action.Text) -Style 'Item'
        $Row++
    }

    # Read-only diagnostics, kept from the licensing workspace and dropped first on a short window.
    $Row++
    if ($Row + 2 -le $Bottom)
    {
        Set-WtScreenText -Screen $Screen -Row $Row -Column 2 -Text (Get-WtString -Key 'Lic.Time.Title') -Style 'PanelTitle' -MaxWidth ($Width - 4)
        $Row++
        $Time = $License.Time
        $TimeLine = (Get-WtString -Key 'Lic.Time.Now' -Arguments @($Time.LocalNow))
        if ($Time.Synchronized -eq $true) { $TimeLine += ' | ' + (Get-WtString -Key 'Lic.Time.Synced') }
        elseif ($Time.Synchronized -eq $false) { $TimeLine += ' | ' + (Get-WtString -Key 'Lic.Time.NotSynced') }
        Set-WtScreenText -Screen $Screen -Row $Row -Column 4 -Text $TimeLine -Style 'ItemMeta' -MaxWidth $Inner
        $Row++
    }

    if ($Row -le $Bottom)
    {
        Set-WtScreenText -Screen $Screen -Row $Row -Column 4 -Text (Get-WtString -Key 'Lic.Time.Service' -Arguments @($Time.Service, $Time.StartType)) -Style 'ItemMeta' -MaxWidth $Inner
        $Row++
    }

    if ($Row + 1 -le $Bottom)
    {
        Set-WtScreenText -Screen $Screen -Row $Row -Column 2 -Text (Get-WtString -Key 'Lic.Components.Title') -Style 'PanelTitle' -MaxWidth ($Width - 4)
        $Row++
        $Components = $License.Components
        $CompLine = (Get-WtString -Key 'Lic.Components.Slmgr' -Arguments @($(if ($Components.SlmgrAvailable) { Get-WtString -Key 'Common.Yes' } else { Get-WtString -Key 'Common.No' })))
        $CompLine += ' | ' + (Get-WtString -Key 'Lic.Components.Service' -Arguments @($Components.Service, $Components.ServiceStartType))
        if ($Components.ServiceError)
        {
            $CompLine += ' - ' + (Get-WtString -Key 'Lic.Components.ServiceError' -Arguments @([string]$Components.ServiceError))
        }
        Set-WtScreenText -Screen $Screen -Row $Row -Column 4 -Text $CompLine -Style 'ItemMeta' -MaxWidth $Inner
        $Row++
    }

    if ($Row -le $Bottom -and ($License.Components.LastActivationError -or $License.Components.LastActivationErrorReadError))
    {
        $ErrorLine = if ($License.Components.LastActivationError)
        {
            (Get-WtString -Key 'Lic.Components.LastError' -Arguments @([string]$License.Components.LastActivationError))
        }
        else
        {
            (Get-WtString -Key 'Lic.Components.LastErrorReadError' -Arguments @([string]$License.Components.LastActivationErrorReadError))
        }
        Set-WtScreenText -Screen $Screen -Row $Row -Column 4 -Text $ErrorLine -Style 'Warning' -MaxWidth $Inner
        $Row++
    }

    if ($Row + 1 -le $Bottom)
    {
        Set-WtScreenText -Screen $Screen -Row $Row -Column 2 -Text (Get-WtString -Key 'Lic.Org.Title') -Style 'PanelTitle' -MaxWidth ($Width - 4)
        $Row++
        $Managed = if ($License.Org.Managed) { Get-WtString -Key 'Lic.Org.Managed' } else { Get-WtString -Key 'Lic.Org.NotManaged' }
        Set-WtScreenText -Screen $Screen -Row $Row -Column 4 -Text $Managed -Style 'ItemMeta' -MaxWidth $Inner
    }

    # The slmgr comparison is collected in the background. While it is pending, the view
    # says so instead of pretending the comparison exists; a discrepancy is shown, never
    # hidden.
    if ($State.SlmgrGeneration -gt 0 -and -not $License.Slmgr -and $Row -le $Bottom)
    {
        Set-WtScreenText -Screen $Screen -Row $Row -Column 4 -Text (Get-WtString -Key 'Lic.Slmgr.Checking') -Style 'ItemMeta' -MaxWidth $Inner
        $Row++
    }

    if ($License.Slmgr -and $License.Slmgr.Available -and $License.Slmgr.Dlv -and $Active)
    {
        $SlmgrText = [string]$License.Slmgr.Dlv
        $CimStatus = [string]$Active.LicenseStatus
        $Disagrees = $false
        if ($CimStatus -eq 'Licensed' -and $SlmgrText -notmatch '(?i)licensed') { $Disagrees = $true }
        elseif ($CimStatus -ne 'Licensed' -and $SlmgrText -notmatch '(?i)(notification|grace|unlicensed)' -and $SlmgrText -notmatch '(?i)error') { $Disagrees = $false }

        if ($Disagrees -and $Row -le $Bottom)
        {
            Set-WtScreenText -Screen $Screen -Row $Row -Column 4 -Text (Get-WtString -Key 'Lic.SourceConflict') -Style 'Warning' -MaxWidth $Inner
        }
    }

    $Screen.Dirty = $true
}
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
    Requests activation with the installed licence, with a purpose disclosure.
.DESCRIPTION
    The documented slmgr /ato request, kept from the licensing workspace and moved to the settings &
    details screen: it is not the primary action of this feature, and it neither installs a key nor
    changes the edition. The result is re-read from the inventory; "accepted" is never equated with
    "activated".
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
        (Get-WtString -Key 'Lic.Activate.Note'),
        (Get-WtString -Key 'Lic.Activate.NotMas')
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

    # The re-read inventory is the new authoritative snapshot for every view.
    try
    {
        $Fresh = Read-WtLicensingDiagnostics -Refresh
        $State.Licensing = $Fresh
        Set-WtLicensingUiSnapshot -State $State -License $Fresh -RawStatus $Fresh.Inventory.Active
    }
    catch
    {
        # The operation reported its own status; the snapshot refresh failing here is not a
        # second activation attempt. Mark the snapshot stale instead of pretending it is current.
        Set-WtLicensingUiStale -State $State -Reason 'post-operation refresh failed'
    }

    $Outcome = if ($Result.Accepted) { (Get-WtString -Key 'Lic.Activate.Accepted') } else { (Get-WtString -Key 'Lic.Activate.Failed' -Arguments @($Result.ErrorDetail)) }
    Set-WtLicensingUiOperation -State $State -Outcome $Outcome

    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Lic.Activate.Title') -Lines $ReportLines -Tone $(if ($Result.Accepted) { 'Success' } else { 'Warning' })
}

<#
.SYNOPSIS
    Describes what the selected method would do, without doing any of it.
.DESCRIPTION
    Built from the method table, the plan and the local state only: no request is made, nothing is
    downloaded and no process is started. The same refusal exists in the backend (-WhatIf), which is
    what a caller outside the interface gets.
#>
function Show-WtActivationDryRun
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Spec = Get-WtExternalToolSpec
    $Method = Get-WtWindowsActivationMethodSetting
    $Lines = @()

    if (-not $Method)
    {
        $Lines += (Get-WtString -Key 'Act.DryRun.NoMethod')
        $Lines += (Get-WtString -Key 'Act.DryRun.NoRequest')
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.DryRun.Title') -Lines $Lines -Tone 'Warning'
        return
    }

    $Lines += (Get-WtString -Key 'Act.DryRun.Method' -Arguments @((Get-WtActivationMethodText -Method $Method), (Get-WtActivationDurationModelText -Method $Method)))

    $Tool = $State.ActivationTool
    if (-not $Tool -or -not $Tool.Ready)
    {
        $Lines += (Get-WtString -Key 'Act.DryRun.NotReady')
    }
    else
    {
        $Plan = Get-WtExternalToolLaunchPlan -Spec $Spec -ToolPath $Tool.Path -Interpreter '' -Method $Method
        if ($Plan.Ok)
        {
            $Lines += (Get-WtString -Key 'Act.DryRun.Would' -Arguments @([string]$Plan.CommandLine))
            $Lines += (Get-WtString -Key 'Act.DryRun.Elevation' -Arguments @(
                    (Get-WtString -Key $(if ($Plan.Elevated) { 'Act.DryRun.AsAdmin' } else { 'Act.DryRun.WithPrompt' }))))
        }
        else
        {
            $Lines += (Get-WtString -Key 'Act.DryRun.WouldFail' -Arguments @([string]$Plan.Reason))
        }
    }

    $Lines += (Get-WtString -Key 'Act.DryRun.NoRequest')
    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.DryRun.Title') -Lines $Lines -Tone 'Warning'
}

<#
.SYNOPSIS
    Runs the selected method through the backend and reports what the licensing record says after.
.DESCRIPTION
    The console-owning caller releases the terminal, hands the process off (the backend performs the
    explicit elevation handoff and observes the operation's real lifetime), re-acquires the terminal,
    restores the console focus and repaints every row, then re-reads the licensing record.

    The report separates the four questions: was completion observed, did Windows report the activated
    state, what validity does the record report, and was there a structured activation error. An exit
    code is never presented as proof of activation, and no expiration date is derived here.
#>
function Start-WtLicensingActivation
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Method,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Tool = $null
    )

    $Spec = Get-WtExternalToolSpec
    if (-not $Tool) { $Tool = Get-WtExternalToolState -Spec $Spec }

    $Elevated = if ($State.ContainsKey('Environment') -and $State.Environment) { [bool]$State.Environment.IsAdmin } else { $null }

    $Plan = Get-WtExternalToolLaunchPlan -Spec $Spec -ToolPath $Tool.Path -Interpreter '' -Method $Method -Elevated $Elevated

    $ConfirmLines = @(
        (Get-WtString -Key 'Act.Confirm.Method' -Arguments @((Get-WtActivationMethodText -Method $Method), (Get-WtActivationDurationModelText -Method $Method))),
        (Get-WtString -Key 'Act.Confirm.Command' -Arguments @([string]$Plan.CommandLine)),
        (Get-WtString -Key 'Act.Confirm.Admin'),
        (Get-WtString -Key 'Act.Confirm.Changes'),
        (Get-WtString -Key 'Act.Confirm.NoEntitlement'),
        (Get-WtString -Key 'Act.Confirm.NoFallback'),
        (Get-WtString -Key 'Act.Confirm.NotProof'),
        (Get-WtString -Key 'Act.Confirm.Console')
    )

    if (-not (Confirm-WtTui -State $State -Title (Get-WtString -Key 'Act.Confirm.Title') -Lines $ConfirmLines -Tone 'Warning')) { return }

    $Before = Get-WtLicensingSnapshot -License $State.Licensing

    $Suspended = Suspend-WtTuiConsole -State $State
    try
    {
        try
        {
            $Result = Start-WtWindowsActivation -Spec $Spec -Method $Method -Elevated $Elevated
        }
        catch
        {
            # The backend reports failures as results; an exception here is unexpected, and it must
            # not escape with the terminal still suspended.
            $Result = [ordered]@{
                Status               = 'failed'
                Code                 = 'LaunchFailed'
                Reason               = $_.Exception.Message
                Plan                 = $Plan
                Method               = $Method
                Started              = $false
                ExitCode             = $null
                Completion           = 'NotStarted'
                CompletionDetermined = $false
                Remaining            = 0
                RootProcessId        = 0
            }
        }
    }
    finally
    {
        Resume-WtTuiConsole -State $State -Suspended $Suspended
        # The child console owned the foreground; ask for it back. Best effort, and no claim is made
        # about the result.
        $null = Restore-WtConsoleFocus
    }

    # The licensing record is the only witness of activation. It is re-read here, never inferred.
    $After = $null
    $Components = $null
    $License = $null
    try
    {
        $License = Read-WtLicensingDiagnostics -Refresh
        $After = Get-WtLicensingSnapshot -License $License
        $Components = $License.Components
    }
    catch
    {
        $After = $null
        $Components = $null
    }

    if ($License)
    {
        $State.Licensing = $License
        Set-WtLicensingUiSnapshot -State $State -License $License -RawStatus $License.Inventory.Active
        Request-WtLicensingSlmgrCheck -State $State
    }
    $State.ActivationTool = Get-WtExternalToolState -Spec $Spec

    $Verdict = Get-WtWindowsActivationResult -Completion ([string]$Result.Completion) -ExitCode $Result.ExitCode -Before $Before -After $After -Components $Components

    $Lines = @()
    $Lines += (Get-WtString -Key 'Act.Result.Method' -Arguments @((Get-WtActivationMethodText -Method $Method)))
    $Lines += (Get-WtString -Key 'Act.Result.Completion' -Arguments @(
            (Get-WtString -Key $(if ($Verdict.CompletionDetermined) { 'Act.Result.CompletionObserved' } else { 'Act.Result.CompletionUnknown' }))))

    if ($null -ne $Result.ExitCode)
    {
        $Lines += (Get-WtString -Key 'Act.Result.ExitCode' -Arguments @([string]$Result.ExitCode))
    }

    $Lines += ''
    $Lines += (Get-WtString -Key $Verdict.ReasonKey)

    if ($Verdict.Before -and $Verdict.Before.Readable)
    {
        $Lines += (Get-WtString -Key 'Act.Result.Before' -Arguments @([string]$Verdict.Before.Status, [string]$Verdict.Before.StatusRaw))
    }
    if ($Verdict.After -and $Verdict.After.Readable)
    {
        $Lines += (Get-WtString -Key 'Act.Result.After' -Arguments @([string]$Verdict.After.Status, [string]$Verdict.After.StatusRaw))
    }

    if ($null -ne $Verdict.RemainingDays -and [int]$Verdict.RemainingDays -gt 0)
    {
        $Lines += (Get-WtString -Key 'Act.Result.Remaining' -Arguments @([string]$Verdict.RemainingDays))
    }
    if ($Verdict.EvaluationEndDate)
    {
        $Lines += (Get-WtString -Key 'Act.Result.EvaluationEnd' -Arguments @([string]$Verdict.EvaluationEndDate))
    }

    if ($Verdict.ErrorCode)
    {
        $Lines += (Get-WtString -Key 'Act.Result.ErrorCode' -Arguments @([string]$Verdict.ErrorCode))
    }
    elseif ($Verdict.CompletionDetermined -and -not $Verdict.Verified)
    {
        $Lines += (Get-WtString -Key 'Act.Result.ErrorNone')
    }

    if ($Result.Plan -and $Result.Plan.Ok -and $Result.Plan.Switches)
    {
        $Lines += (Get-WtString -Key 'Act.Result.Switches' -Arguments @((@($Result.Plan.Switches) -join ' ')))
    }

    $Tone = 'Warning'
    $Outcome = ''
    if ($Verdict.Verified)
    {
        $Tone = 'Success'
        $Outcome = if ($Verdict.AlreadyActive) { Get-WtString -Key 'Act.Outcome.AlreadyActive' } else { Get-WtString -Key 'Act.Outcome.Activated' }
    }
    elseif (-not $Verdict.CompletionDetermined)
    {
        $Outcome = Get-WtString -Key 'Act.Outcome.NotDetermined'
    }
    elseif (-not $Verdict.After -or -not $Verdict.After.Readable)
    {
        $Outcome = Get-WtString -Key 'Act.Outcome.Unreadable'
    }
    else
    {
        $Outcome = Get-WtString -Key 'Act.Outcome.NotActivated'
    }

    switch ([string]$Result.Code)
    {
        'UacCancelled' { $Outcome = Get-WtString -Key 'Act.Outcome.Cancelled' }
        'LaunchFailed' { $Outcome = Get-WtString -Key 'Act.Outcome.Failed' -Arguments @([string]$Result.Reason) }
        default { }
    }

    # The operation outcome is separate from the machine's observed status. The bounded poll
    # below watches for delayed provider updates without changing what is reported here.
    Set-WtLicensingUiOperation -State $State -Outcome $Outcome
    if ($Verdict.CompletionDetermined -and -not $Verdict.Verified -and -not $Verdict.AlreadyActive)
    {
        $Ui = Get-WtLicensingUiState -State $State
        $Ui.OperationPollRemaining = 4
        $Ui.OperationPollNextUtc = [datetime]::UtcNow.AddSeconds(3)
    }

    Set-WtTuiStatus -State $State -Text $Outcome -Tone $(if ($Verdict.Verified) { 'StatusOk' } elseif ($Verdict.CompletionDetermined) { 'StatusWarn' } else { 'StatusInfo' })
    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Act.Confirm.Title') -Lines $Lines -Tone $Tone
}

<#
.SYNOPSIS
    Runs the primary action: the selected Windows-only activation method, downloading the pinned file
    first when it is missing.
.DESCRIPTION
    Refusals happen before anything is confirmed or started: no method selected, a method this
    edition cannot use, a local copy that does not match its pin, an operation that may still be
    running, and dry-run mode. Nothing falls back to another method.

    When the pinned file is not downloaded yet, this action may fetch it - with visible progress and
    Esc to cancel - and the selected method then runs once the download is verified. Navigating,
    refreshing and drawing never download anything.
#>
function Invoke-WtWindowsActivationAction
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][hashtable]$License
    )

    if (-not (Test-WtExternalToolSupported))
    {
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Lic.Title') -Lines @((Get-WtString -Key 'Mas.Platform.WindowsOnly')) -Tone 'Warning'
        return
    }

    if ($State.DryRun)
    {
        Show-WtActivationDryRun -State $State
        return
    }

    $Spec = Get-WtExternalToolSpec
    $Method = Get-WtWindowsActivationMethodSetting
    if (-not $Method)
    {
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Act.NoMethod.Title') -Lines @((Get-WtString -Key 'Act.NoMethod.Body')) -Tone 'Warning'
        return
    }

    $Edition = Get-WtWindowsActivationEdition -License $License -Environment $State.Environment
    $Compatibility = Test-WtWindowsActivationMethodCompatibility -Method $Method -Edition $Edition
    if (-not $Compatibility.Compatible)
    {
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Act.Incompatible.Title') -Lines @(
            (Get-WtString -Key 'Act.Incompatible.Body' -Arguments @((Get-WtActivationMethodText -Method $Method), (Get-WtActivationCompatibilityText -Status $Compatibility.Status))),
            (Get-WtString -Key 'Act.Incompatible.NoFallback')
        ) -Tone 'Warning'
        return
    }

    $Active = Test-WtWindowsActivationActive
    if ($Active.Active)
    {
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Act.Busy.Title') -Lines @(
            (Get-WtString -Key 'Act.Busy.Body'),
            (Get-WtString -Key 'Act.Busy.Guard')
        ) -Tone 'Warning'
        return
    }

    $Tool = Get-WtExternalToolState -Spec $Spec
    $State.ActivationTool = $Tool

    if ($Tool.Status -eq 'Mismatch')
    {
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Act.Tool.Mismatch.Title') -Lines @(
            (Get-WtString -Key 'Act.Tool.Mismatch.Body'),
            [string]$Tool.Reason
        ) -Tone 'Error'
        return
    }

    if (-not $Tool.Ready)
    {
        $ConfirmLines = @(
            (Get-WtString -Key 'Act.Download.Confirm' -Arguments @([string]$Spec.FileName, [string]$Spec.Bytes, [string]$Spec.DownloadUrl, (Get-WtActivationMethodText -Method $Method))),
            (Get-WtString -Key 'Mas.Download.Verify'),
            (Get-WtString -Key 'Act.Download.ThenActivate'),
            (Get-WtString -Key 'Mas.Download.NoExecute')
        )
        if (-not (Confirm-WtTui -State $State -Title (Get-WtString -Key 'Act.Download.Title') -Lines $ConfirmLines -Tone 'Warning')) { return }

        $Task = Get-WtTuiExternalToolTask -State $State
        $Start = Start-WtExternalToolTask -Task $Task -Spec $Spec -Mode 'download'
        if (-not $Start.Started)
        {
            Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Download.Title') -Lines @((Get-WtString -Key 'Mas.Busy.Download')) -Tone 'Warning'
            return
        }

        # The action continues by itself once the transfer is verified and the frame loop drains it.
        $State.ActivationPending = $true
        Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Mas.Download.Title') -Tone 'StatusInfo'
        $State.Screen.Dirty = $true
        return
    }

    Start-WtLicensingActivation -State $State -Method $Method -Tool $Tool
}

<#
.SYNOPSIS
    Drains the background download of the pinned dependency on the main screen.
.DESCRIPTION
    Called once per frame. While the transfer runs it only keeps the progress line fresh (a real byte
    count from the task's own counters) and stops a task that outlived its deadline. When it finishes
    the outcome is reported, and a download started by the activation action continues with that
    action - after the file was verified, never before. The external-tool view's own state
    ($State.ExternalTool) is deliberately not touched here: the canvas of this screen stays the one
    that is drawn.
#>
function Update-WtActivationDownload
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Task = $State.ExternalToolTask
    if (-not $Task -or -not $Task.Handle) { return }

    $Spec = Get-WtExternalToolSpec

    if (Test-WtExternalToolTaskExpired -Task $Task)
    {
        $Stop = Stop-WtExternalToolTask -Task $Task -Force
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Download.Title') `
            -Lines @((Get-WtString -Key 'Mas.Download.Expired' -Arguments @([string]$Stop.Phase))) -Tone 'Error'
        $null = Complete-WtExternalToolTask -Task $Task
        Close-WtTuiExternalToolTask -State $State
        $State.ActivationPending = $false
        $State.ActivationTool = Get-WtExternalToolState -Spec $Spec
        return
    }

    if (Test-WtExternalToolTaskBusy -Task $Task)
    {
        $Progress = $Task.Progress
        $Snapshot = '{0}|{1}|{2}' -f [string]$Progress.Phase, [long]$Progress.Received, [int]$Progress.Percent
        if ($Snapshot -ne $State.ActivationProgressSnapshot)
        {
            $State.ActivationProgressSnapshot = $Snapshot
            $State.Screen.Dirty = $true
        }
        return
    }

    $Outcome = Complete-WtExternalToolTask -Task $Task
    if (-not $Outcome.Completed) { return }

    $Result = $Outcome.Result
    Close-WtTuiExternalToolTask -State $State
    $State.ActivationTool = Get-WtExternalToolState -Spec $Spec

    if ($Outcome.Error)
    {
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Download.Failed') -Lines @([string]$Outcome.Error) -Tone 'Error'
        $State.ActivationPending = $false
        return
    }

    if ($Outcome.Cancelled -or ($Result -and [string]$Result.Status -eq 'cancelled'))
    {
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Download.Title') -Lines @((Get-WtString -Key 'Mas.Download.Cancelled')) -Tone 'Warning'
        Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Mas.Download.Cancelled') -Tone 'StatusWarn'
        $State.ActivationPending = $false
        return
    }

    if ($Result -and [string]$Result.Status -eq 'succeeded')
    {
        $Tool = $State.ActivationTool
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Download.Title') -Lines @(
            (Get-WtString -Key 'Mas.Download.Done' -Arguments @([string]$Tool.Bytes, [string]$Tool.Sha256)),
            (Get-WtString -Key 'Mas.Status.Verified')
        ) -Tone 'Success'

        if ($State.ActivationPending)
        {
            $State.ActivationPending = $false
            $Method = Get-WtWindowsActivationMethodSetting
            if ($Method)
            {
                Start-WtLicensingActivation -State $State -Method $Method -Tool $Tool
            }
        }
        return
    }

    $Reason = if ($Result -and $Result.Reason) { [string]$Result.Reason } else { Get-WtString -Key 'Mas.Download.Failed' -Arguments @('?') }
    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Download.Failed') -Lines @($Reason) -Tone 'Error'
    Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Mas.Download.Failed' -Arguments @([string]$Result.Code)) -Tone 'StatusError'
    $State.ActivationPending = $false
}

<#
.SYNOPSIS
    Bounded async read-only polling after an activation operation.
.DESCRIPTION
    Some provider updates land a few seconds after the operation's write path completes.
    This is called once per frame while a poll window is open: it waits for the next poll
    time (so the interface stays responsive), then performs at most one read-only refresh.
    The poll never changes what the operation reported - it only observes whether the
    provider has caught up. When the poll finds a changed status, the shared snapshot is
    updated and the outcome line is not touched.
#>
function Update-WtLicensingOperationPoll
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Ui = Get-WtLicensingUiState -State $State
    if (-not $Ui.OperationPollNextUtc) { return }

    if ([datetime]::UtcNow -lt [datetime]$Ui.OperationPollNextUtc) { return }

    if ($Ui.OperationPollRemaining -le 0)
    {
        $Ui.OperationPollNextUtc = $null
        return
    }

    $Ui.OperationPollRemaining--
    $Ui.OperationPollNextUtc = [datetime]::UtcNow.AddSeconds(4)

    $License = $null
    try
    {
        $License = Read-WtLicensingDiagnostics -Refresh
    }
    catch
    {
        Set-WtLicensingUiStale -State $State -Reason 'poll refresh failed'
        return
    }

    if ($License)
    {
        # An older background response must never overwrite a newer refresh: only apply the poll
        # when it is at least as new as what the workspace already has.
        $CurrentUtc = if ($State.Licensing -and $State.Licensing.CollectedUtc) { [datetime]$State.Licensing.CollectedUtc } else { [datetime]::MinValue }
        $NewUtc = if ($License.CollectedUtc) { [datetime]$License.CollectedUtc } else { [datetime]::MinValue }

        if ($NewUtc -ge $CurrentUtc)
        {
            $State.Licensing = $License
            Set-WtLicensingUiSnapshot -State $State -License $License -RawStatus $License.Inventory.Active
            Request-WtLicensingSlmgrCheck -State $State
            $State.Screen.Dirty = $true
        }
    }
}

<#
.SYNOPSIS
    Requests a background slmgr comparison for the shared licensing snapshot.
.DESCRIPTION
    Child-process probes (cscript /xpr and /dlv) are never run on the UI thread: the
    request goes to the background info collector and the result lands through
    Update-WtInfoCollector on a later frame.
#>
function Request-WtLicensingSlmgrCheck
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    if (-not $State.InfoCollector) { return }

    $State.SlmgrGeneration++
    $null = Send-WtInfoCollectorRequest -Collector $State.InfoCollector -Kind 'slmgr' -Generation $State.SlmgrGeneration
}

<#
.SYNOPSIS
    Runs the licensing & activation workspace: bounded loop, one primary action, the download of the
    pinned dependency in the background, its own key map.
#>
function Show-WtTuiLicensing
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $License = Read-WtLicensingDiagnostics
    $State.Licensing = $License
    $State.ActivationTool = Get-WtExternalToolState -Spec (Get-WtExternalToolSpec)
    Set-WtLicensingUiSnapshot -State $State -License $License -RawStatus $License.Inventory.Active
    Request-WtLicensingSlmgrCheck -State $State

    $State.Screen.Dirty = $true

    try
    {
        while ($true)
        {
            Update-WtActivationDownload -State $State
            Update-WtLicensingOperationPoll -State $State

            $Timeout = if ($State.ContainsKey('FrameTimeoutMs')) { [int]$State.FrameTimeoutMs } else { 40 }
            $Key = Invoke-WtTuiFrame -State $State -TimeoutMs $Timeout
            if ($null -eq $Key)
            {
                if ($State.Exit) { break }
                continue
            }

            $Busy = Test-WtTuiExternalToolBusy -State $State

            if ($Key.Name -eq 'Escape')
            {
                if ($Busy)
                {
                    # Esc cancels the transfer of the pinned dependency; the screen stays open and
                    # reports the outcome, and the activation that was waiting for it does not run.
                    $Stop = Stop-WtExternalToolTask -Task $State.ExternalToolTask
                    Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Mas.Progress.Cancelling' -Arguments @([string]$Stop.Phase)) -Tone 'StatusWarn'
                    $State.Screen.Dirty = $true
                    continue
                }

                return
            }

            if ($Key.Name -ne 'Char') { continue }

            $Character = ([string]$Key.Char).ToLowerInvariant()

            if ($Busy -and $Character -ne '?')
            {
                Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Lic.Title') -Lines @((Get-WtString -Key 'Mas.Busy.Download')) -Tone 'Warning'
                continue
            }

            switch ($Character)
            {
                'r'
                {
                    $License = Read-WtLicensingDiagnostics -Refresh
                    $State.Licensing = $License
                    $State.ActivationTool = Get-WtExternalToolState -Spec (Get-WtExternalToolSpec)
                    Set-WtLicensingUiSnapshot -State $State -License $License -RawStatus $License.Inventory.Active
                    Request-WtLicensingSlmgrCheck -State $State
                    Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Lic.Refreshed') -Tone 'StatusOk'
                }
                'e' { Export-WtLicensingReport -State $State -License $License }
                'a' { Invoke-WtWindowsActivationAction -State $State -License $License }
                's'
                {
                    Show-WtTuiActivationSettings -State $State

                    # The settings screen may have changed the method, the local copy or the
                    # diagnostics: show what is current instead of the copies this loop held.
                    if ($State.Licensing) { $License = $State.Licensing }
                    Set-WtLicensingUiSnapshot -State $State -License $License -RawStatus $License.Inventory.Active
                    $State.ActivationTool = Get-WtExternalToolState -Spec (Get-WtExternalToolSpec)
                    $State.Screen.Dirty = $true
                }
                '?'
                {
                    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Lic.Title') -Lines @(
                        (Get-WtString -Key 'Lic.Help'),
                        (Get-WtString -Key 'Act.Help.Methods'),
                        (Get-WtString -Key 'Act.Help.Evidence')
                    )
                }
                default { }
            }
        }
    }
    finally
    {
        $State.Licensing = $null
        $State.ActivationTool = $null
        $State.ActivationOutcome = ''
        $State.ActivationPending = $false
        $State.ActivationProgressSnapshot = ''
        $State.LicensingUi = $null
        $State.Screen.Dirty = $true
    }
}
