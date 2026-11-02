# WindowsTweaker - activation settings & details: Microsoft Activation Scripts (TUI).
#
# The second screen of Windows activation. It holds what the main screen deliberately does not: the
# Windows activation method setting, the download provenance, the pinned hashes, the upstream source,
# the documentation link, the explicit update and the removal of the local copy, plus the documented
# slmgr /ato request that the licensing workspace used to offer directly.
#
# Nothing here downloads, launches or deletes on its own: every action starts with a dialog that
# states what it does, and the backend (Private/ExternalTool.ps1) does the work. This layer never
# starts a process itself - for the download it suspends nothing and drives a background task, and for
# the activation it does not act at all: that is the main screen's single primary action, which runs
# exactly one Windows-only method and never opens the upstream menu.

<#
.SYNOPSIS
    Returns the localised label of one local-copy status.
#>
function Get-WtExternalToolStatusKey
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][string]$Status)

    switch ($Status)
    {
        'Ready' { return 'Mas.Status.Ready' }
        'Mismatch' { return 'Mas.Status.Mismatch' }
        default { return 'Mas.Status.Missing' }
    }
}

<#
.SYNOPSIS
    Returns the icon and tone that describe the local copy.
.OUTPUTS
    A hashtable with IconKey and Tone.
#>
function Get-WtExternalToolStatusLook
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Tool)

    if (-not $Tool.Supported)
    {
        return @{ IconKey = 'Status.Unsupported'; Tone = 'Muted' }
    }

    switch ([string]$Tool.Status)
    {
        'Ready' { return @{ IconKey = 'Status.Succeeded'; Tone = 'Success' } }
        'Mismatch' { return @{ IconKey = 'Status.Warning'; Tone = 'Warning' } }
        default { return @{ IconKey = 'Status.Disabled'; Tone = 'ItemMeta' } }
    }
}

<#
.SYNOPSIS
    Re-reads the local state into the workspace state.
#>
function Update-WtExternalToolState
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Spec = Get-WtExternalToolSpec
    $Tool = Get-WtExternalToolState -Spec $Spec
    $Tool['Spec'] = $Spec
    $State.ExternalTool = $Tool

    return $Tool
}

<#
.SYNOPSIS
    Adds the external-tool canvas: provenance, local status, actions and limits.
.DESCRIPTION
    Rows above the shared footer only, and every section is dropped when the terminal is too
    short for it, so a small window still shows the title, the warning and the actions
    instead of a half-drawn box.
#>
function Add-WtExternalToolView
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Tool
    )

    $Screen = $State.Screen
    $Width = $Screen.Width
    $Layout = Get-WtTuiLayout -State $State
    $Bottom = $Screen.Height - $Layout.FooterRows

    Set-WtScreenText -Screen $Screen -Row 1 -Column 2 -Text (Get-WtString -Key 'Mas.Title') -Style 'Title' -MaxWidth ($Width - 4)

    # The machine's observed licensing status: the same authoritative snapshot the main screen
    # paints, on its own line directly under the title. It is deliberately separate from the tool
    # readiness below - selecting a method or downloading a file never changes this line.
    $Observed = Get-WtObservedLicensingStatusText -State $State
    $ObservedLine = (Get-WtString -Key 'Lic.ActStatus' -Arguments @($Observed))
    if (-not (Test-WtLicensingSnapshotFresh -State $State))
    {
        $ObservedLine += ' ' + (Get-WtString -Key 'Lic.Status.Stale')
    }
    $ObservedLine += ' | ' + (Get-WtLicensingCollectedText -State $State)
    Set-WtScreenText -Screen $Screen -Row 2 -Column 2 -Text $ObservedLine -Style 'Item' -MaxWidth ($Width - 4)

    $Row = 3
    foreach ($Line in (Format-WtWrappedText -Text (Get-WtString -Key 'Mas.Warning.Summary') -Width ($Width - 4)))
    {
        if ($Row -gt $Bottom) { break }
        Set-WtScreenText -Screen $Screen -Row $Row -Column 2 -Text $Line -Style 'Warning' -MaxWidth ($Width - 4)
        $Row++
    }

    $Spec = if ($Tool.Spec) { $Tool.Spec } else { Get-WtExternalToolSpec }

    # Background progress. Painted early, on the interface thread, from the task's own shared
    # counters: the runspace never writes a cell.
    foreach ($Line in @(Get-WtExternalToolProgressLines -State $State))
    {
        if ($Row -gt $Bottom) { break }
        Set-WtScreenText -Screen $Screen -Row $Row -Column 2 -Text $Line -Style 'Pending' -MaxWidth ($Width - 4)
        $Row++
    }

    # The activation method setting: only methods the pinned revision implements, each with the
    # duration model upstream documents (permanent / time-limited) and whether this edition can use it.
    $Edition = Get-WtWindowsActivationEdition -License $State.Licensing -Environment $State.Environment
    $Selected = Get-WtWindowsActivationMethodSetting
    $Methods = @(Get-WtWindowsActivationMethod)

    if ($Row + 7 -le $Bottom)
    {
        Add-WtScreenBox -Screen $Screen -Row $Row -Column 2 -Width ($Width - 4) -Height 7 -Title (Get-WtString -Key 'Mas.Section.Methods') `
            -BorderStyle 'Border' -TitleStyle 'PanelTitle' -Style 'Dialog'
        $MethodInner = $Width - 8
        $Line = $Row + 1

        $Current = if ($Selected) { '{0} - {1}' -f (Get-WtActivationMethodText -Method $Selected), (Get-WtActivationDurationModelText -Method $Selected) } else { Get-WtString -Key 'Mas.Method.None' }
        Set-WtScreenText -Screen $Screen -Row $Line -Column 4 -Text (Get-WtString -Key 'Mas.Method.Current' -Arguments @($Current)) -Style 'Item' -MaxWidth $MethodInner
        $Line++

        $Index = 1
        foreach ($Candidate in $Methods)
        {
            $Compat = Test-WtWindowsActivationMethodCompatibility -Method $Candidate -Edition $Edition
            $Entry = (Get-WtString -Key 'Mas.Method.Entry' -Arguments @([string]$Index, (Get-WtActivationMethodText -Method $Candidate), (Get-WtActivationDurationModelText -Method $Candidate))) + ' - ' + (Get-WtActivationCompatibilityText -Status $Compat.Status)
            $EntryStyle = if ($Compat.Compatible) { 'Item' } else { 'ItemMeta' }
            if ($Selected -and [string]$Selected.Id -eq [string]$Candidate.Id) { $EntryStyle = 'Success' }
            Set-WtScreenText -Screen $Screen -Row $Line -Column 4 -Text $Entry -Style $EntryStyle -MaxWidth $MethodInner
            $Line++
            $Index++
        }

        if ($Selected)
        {
            Set-WtScreenText -Screen $Screen -Row $Line -Column 4 -Text (Get-WtString -Key 'Mas.Method.Duration' -Arguments @((Get-WtActivationDurationText -Method $Selected))) -Style 'ItemMeta' -MaxWidth $MethodInner
            $Line++
        }

        Set-WtScreenText -Screen $Screen -Row $Line -Column 4 -Text (Get-WtString -Key 'Mas.Method.Hint') -Style 'ItemMeta' -MaxWidth $MethodInner

        $Row += 7
    }

    # Actions: the whole keyboard map of this view, with the key that triggers each one.
    if ($Row -le $Bottom)
    {
        Set-WtScreenText -Screen $Screen -Row $Row -Column 2 -Text (Get-WtString -Key 'Mas.Section.Actions') -Style 'PanelTitle' -MaxWidth ($Width - 4)
        $Row++
    }

    $Actions = @(
        @{ Key = 'D'; IconKey = 'Action.Import'; Text = (Get-WtString -Key 'Mas.Action.Download') },
        @{ Key = 'U'; IconKey = 'Action.Refresh'; Text = (Get-WtString -Key 'Mas.Action.Update') },
        @{ Key = 'V'; IconKey = 'Action.Export'; Text = (Get-WtString -Key 'Mas.Action.Docs') },
        @{ Key = 'T'; IconKey = 'Action.Apply'; Text = (Get-WtString -Key 'Mas.Action.RequestActivation') },
        @{ Key = 'R'; IconKey = 'Action.Cancel'; Text = (Get-WtString -Key 'Mas.Action.Remove') }
    )
    foreach ($Action in $Actions)
    {
        if ($Row -gt $Bottom) { break }
        Set-WtScreenIconText -Screen $Screen -Row $Row -Column 4 -Width ($Width - 8) -IconKey $Action.IconKey -Text ('{0}  {1}' -f $Action.Key, $Action.Text) -Style 'Item'
        $Row++
    }

    # Local copy and upstream source: the status a reviewer needs, and what it is pinned to.
    # One box, so a typical window sees the whole story; the details box below absorbs the long
    # notes when there is room.
    if ($Row + 9 -le $Bottom)
    {
        $Look = Get-WtExternalToolStatusLook -Tool $Tool
        $StatusText = Get-WtString -Key 'Mas.StatusLabel' -Arguments @((Get-WtString -Key (Get-WtExternalToolStatusKey -Status $Tool.Status)))
        if (-not $Tool.Supported)
        {
            $StatusText = Get-WtString -Key 'Mas.Status.Unsupported'
        }

        Add-WtScreenBox -Screen $Screen -Row $Row -Column 2 -Width ($Width - 4) -Height 10 -Title (Get-WtString -Key 'Mas.Section.Local') `
            -BorderStyle 'Border' -TitleStyle 'PanelTitle' -Style 'Dialog'

        $Inner = $Width - 8
        $Line = $Row + 1
        Set-WtScreenIconText -Screen $Screen -Row $Line -Column 4 -Width $Inner -IconKey $Look.IconKey -Text $StatusText -Style $Look.Tone
        $Line++

        Set-WtScreenText -Screen $Screen -Row $Line -Column 4 -Text (Get-WtString -Key 'Mas.Sha256' -Arguments @($(if ($Tool.Sha256) { $Tool.Sha256 } else { [string]$Tool.Pin.Sha256 }))) -Style 'ItemMeta' -MaxWidth $Inner
        $Line++

        Set-WtScreenText -Screen $Screen -Row $Line -Column 4 -Text (Get-WtString -Key 'Mas.BlobIn' -Arguments @($(if ($Tool.GitBlobSha1) { $Tool.GitBlobSha1 } else { [string]$Tool.Pin.GitBlobSha1 }))) -Style 'ItemMeta' -MaxWidth $Inner
        $Line++

        $PinLine = Get-WtString -Key 'Mas.PinSource' -Arguments @($(if ([string]$Tool.Pin.PinSource -eq 'user-update') { Get-WtString -Key 'Mas.Pin.User' } else { Get-WtString -Key 'Mas.Pin.Shipped' }))
        if ($Tool.Provenance)
        {
            $PinLine += ' - ' + (Get-WtString -Key 'Mas.Recorded' -Arguments @([string](Get-WtExternalToolJsonProperty -Document $Tool.Provenance -Name 'downloadedUtc')))
        }
        Set-WtScreenText -Screen $Screen -Row $Line -Column 4 -Text $PinLine -Style 'ItemMeta' -MaxWidth $Inner
        $Line++

        Set-WtScreenText -Screen $Screen -Row $Line -Column 4 -Text (Get-WtString -Key 'Mas.Repository' -Arguments @([string]$Spec.RepositoryUrl)) -Style 'Item' -MaxWidth $Inner
        $Line++

        Set-WtScreenText -Screen $Screen -Row $Line -Column 4 -Text (Get-WtString -Key 'Mas.Version' -Arguments @([string]$Tool.Pin.Tag, [string]$Tool.Pin.Commit)) -Style 'Item' -MaxWidth $Inner
        $Line++

        Set-WtScreenText -Screen $Screen -Row $Line -Column 4 -Text (Get-WtString -Key 'Mas.License' -Arguments @([string]$Spec.License)) -Style 'Item' -MaxWidth $Inner
        $Line++

        Set-WtScreenText -Screen $Screen -Row $Line -Column 4 -Text (Get-WtString -Key 'Mas.Documentation' -Arguments @([string]$Spec.DocumentationUrl)) -Style 'Item' -MaxWidth $Inner

        $Row += 10
    }

    # Details: the parts that need more than one line, when the terminal has room.
    $Room = $Bottom - $Row + 1
    if ($Room -ge 5)
    {
        $Height = [math]::Min(11, $Room)
        Add-WtScreenBox -Screen $Screen -Row $Row -Column 2 -Width ($Width - 4) -Height $Height -Title (Get-WtString -Key 'Mas.Section.Details') `
            -BorderStyle 'Border' -TitleStyle 'PanelTitle' -Style 'Dialog'

        $Lines = [System.Collections.Generic.List[string]]::new()
        $Lines.Add((Get-WtString -Key 'Mas.Url' -Arguments @([string]$Tool.Pin.DownloadUrl)))
        if (-not $Tool.Supported)
        {
            $Lines.Add((Get-WtString -Key 'Mas.Platform.WindowsOnly'))
        }
        $Lines.Add((Get-WtString -Key 'Mas.HashNote'))
        $Lines.Add((Get-WtString -Key 'Mas.Help.Offline'))
        if ($Tool.ProvenanceProblem)
        {
            $Lines.Add([string]$Tool.ProvenanceProblem)
        }
        elseif (-not $Tool.Provenance -and $Tool.Installed)
        {
            $Lines.Add((Get-WtString -Key 'Mas.ProvenanceMissing'))
        }

        $Wrapped = [System.Collections.Generic.List[string]]::new()
        foreach ($Line in $Lines)
        {
            foreach ($Part in (Format-WtWrappedText -Text $Line -Width ($Width - 8))) { $Wrapped.Add($Part) }
        }

        $Limit = [math]::Min($Height - 2, $Wrapped.Count)
        for ($Index = 0; $Index -lt $Limit; $Index++)
        {
            Set-WtScreenText -Screen $Screen -Row ($Row + 1 + $Index) -Column 4 -Text $Wrapped[$Index] -Style 'ItemMeta' -MaxWidth ($Width - 8)
        }
    }

    $Screen.Dirty = $true
}

<#
.SYNOPSIS
    Opens the upstream documentation in the default browser.
#>
function Invoke-WtExternalToolDocAction
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Spec = Get-WtExternalToolSpec
    $Result = Open-WtExternalToolDocumentation -Spec $Spec

    $Lines = @()
    if ($Result.Status -eq 'succeeded')
    {
        $Lines += (Get-WtString -Key 'Mas.Docs.Opened' -Arguments @([string]$Spec.DocumentationUrl))
    }
    elseif ($Result.Status -eq 'unsupported')
    {
        $Lines += (Get-WtString -Key 'Mas.Docs.Unsupported')
        $Lines += (Get-WtString -Key 'Mas.Docs.Url' -Arguments @([string]$Spec.DocumentationUrl))
    }
    elseif ([string]$Result.Reason -match 'not allowed|non-HTTPS|malformed')
    {
        $Lines += (Get-WtString -Key 'Mas.Docs.NotAllowed')
        $Lines += (Get-WtString -Key 'Mas.Docs.Url' -Arguments @([string]$Spec.DocumentationUrl))
    }
    else
    {
        $Lines += (Get-WtString -Key 'Mas.Docs.Failed' -Arguments @([string]$Result.Reason))
        $Lines += (Get-WtString -Key 'Mas.Docs.Url' -Arguments @([string]$Spec.DocumentationUrl))
    }

    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Action.Docs') -Lines $Lines -Tone $(if ($Result.Status -eq 'succeeded') { 'Success' } else { 'Warning' })
}

<#
.SYNOPSIS
    Returns the background task of this view, creating it on first use.
#>
function Get-WtTuiExternalToolTask
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    if (-not $State.ExternalToolTask)
    {
        $State.ExternalToolTask = New-WtExternalToolTask
    }

    return $State.ExternalToolTask
}

<#
.SYNOPSIS
    Disposes the background task of this view.
#>
function Close-WtTuiExternalToolTask
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    if ($State.ExternalToolTask)
    {
        Close-WtExternalToolTask -Task $State.ExternalToolTask
        $State.ExternalToolTask = $null
    }
}

<#
.SYNOPSIS
    Reports whether a download is running in this view.
#>
function Test-WtTuiExternalToolBusy
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ([Parameter(Mandatory = $true)][object]$State)

    if (-not $State.ExternalToolTask) { return $false }
    return [bool](Test-WtExternalToolTaskBusy -Task $State.ExternalToolTask)
}

<#
.SYNOPSIS
    Returns the progress lines shown while a background task runs.
.DESCRIPTION
    Read on the interface thread from the task's shared progress table. Byte counts are real,
    and a percentage is shown only while a total is known (the pinned size, or the response's
    own Content-Length): nothing here is estimated or animated.
#>
function Get-WtExternalToolProgressLines
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Lines = [System.Collections.Generic.List[string]]::new()
    $Task = $State.ExternalToolTask
    if (-not $Task -or -not (Test-WtExternalToolTaskBusy -Task $Task))
    {
        return $Lines.ToArray()
    }

    $Progress = $Task.Progress
    $Phase = [string]$Progress.Phase
    $Elapsed = 0
    if ($Progress.StartedUtc -and $Progress.StartedUtc -gt [datetime]::MinValue)
    {
        $Elapsed = [int][math]::Max(0, ([datetime]::UtcNow - $Progress.StartedUtc).TotalSeconds)
    }

    switch ($Phase)
    {
        'downloading'
        {
            if ([long]$Progress.Total -gt 0)
            {
                $Lines.Add((Get-WtString -Key 'Mas.Progress.Downloading' -Arguments @(
                            (Format-WtDiskBytes -Bytes ([long]$Progress.Received)),
                            (Format-WtDiskBytes -Bytes ([long]$Progress.Total)),
                            [math]::Max(0, [int]$Progress.Percent))))
            }
            else
            {
                $Lines.Add((Get-WtString -Key 'Mas.Progress.DownloadingUnknown' -Arguments @((Format-WtDiskBytes -Bytes ([long]$Progress.Received)))))
            }
        }
        'verifying' { $Lines.Add((Get-WtString -Key 'Mas.Progress.Verifying')) }
        'publishing' { $Lines.Add((Get-WtString -Key 'Mas.Progress.Publishing')) }
        default { $Lines.Add((Get-WtString -Key 'Mas.Progress.Resolving')) }
    }

    $Lines.Add((Get-WtString -Key 'Mas.Progress.CancelHint' -Arguments @($Elapsed)))

    return $Lines.ToArray()
}

<#
.SYNOPSIS
    Describes what a dry run would do, without doing any of it.
.DESCRIPTION
    The preview is built from the pin and the filesystem only: no request is made, nothing is
    staged, nothing is started. The same refusal exists in the backend (-WhatIf) for callers
    outside the interface.
#>
function Show-WtExternalToolDryRun
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][ValidateSet('download', 'update', 'launch', 'remove')][string]$Action
    )

    $Spec = Get-WtExternalToolSpec
    $Lines = @()

    switch ($Action)
    {
        'download'
        {
            $Lines += (Get-WtString -Key 'Mas.DryRun.Download' -Arguments @(
                    [string]$Spec.FileName,
                    (Format-WtDiskBytes -Bytes ([long]$Spec.Bytes)),
                    [string]$Spec.DownloadUrl))
            $Lines += (Get-WtString -Key 'Mas.DryRun.Verify')
        }
        'update'
        {
            $Lines += (Get-WtString -Key 'Mas.DryRun.Update' -Arguments @([string]$Spec.Repository))
            $Lines += (Get-WtString -Key 'Mas.DryRun.NoRequest')
        }
        'remove'
        {
            $Would = @(Get-WtExternalToolRemovableFiles -Spec $Spec)
            $Lines += (Get-WtString -Key 'Mas.DryRun.Remove' -Arguments @([string]$Would.Count))
            foreach ($Path in $Would) { $Lines += "  $Path" }
            $Lines += (Get-WtString -Key 'Mas.Remove.Note')
        }
    }

    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.DryRun.Title') -Lines $Lines -Tone 'Warning'
}

<#
.SYNOPSIS
    Starts a pinned download, or resolves the newest release first (both in the background).
.DESCRIPTION
    The action itself returns as soon as the task is running: the view keeps painting and keeps
    taking keys, the progress line is drawn from the task's own counters, and Esc stops it. A
    second D/U while a transfer runs is refused instead of starting another download.
#>
function Invoke-WtExternalToolDownloadAction
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $false)][switch]$Latest
    )

    $Spec = Get-WtExternalToolSpec

    if (-not (Test-WtExternalToolSupported))
    {
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Title') -Lines @((Get-WtString -Key 'Mas.Platform.WindowsOnly')) -Tone 'Warning'
        return
    }

    if (Test-WtTuiExternalToolBusy -State $State)
    {
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Title') -Lines @((Get-WtString -Key 'Mas.Busy.Download')) -Tone 'Warning'
        return
    }

    if ($State.DryRun)
    {
        Show-WtExternalToolDryRun -State $State -Action $(if ($Latest) { 'update' } else { 'download' })
        return
    }

    $Task = Get-WtTuiExternalToolTask -State $State

    if ($Latest)
    {
        # The newest release is resolved first, in the background: the confirmation dialog is
        # shown when the answer is in, so it can name the exact tag, commit and size.
        $Start = Start-WtExternalToolTask -Task $Task -Spec $Spec -Mode 'resolve'
        if (-not $Start.Started)
        {
            Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Update.Title') -Lines @((Get-WtString -Key 'Mas.Busy.Download')) -Tone 'Warning'
            return
        }

        Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Mas.Update.Resolving') -Tone 'StatusInfo'
        $State.Screen.Dirty = $true
        return
    }

    $ConfirmLines = @(
        (Get-WtString -Key 'Mas.Download.Confirm' -Arguments @([string]$Spec.FileName, [string]$Spec.Bytes, [string]$Spec.DownloadUrl)),
        (Get-WtString -Key 'Mas.Download.Verify'),
        (Get-WtString -Key 'Mas.Download.NoExecute')
    )
    if (-not (Confirm-WtTui -State $State -Title (Get-WtString -Key 'Mas.Download.Title') -Lines $ConfirmLines -Tone 'Warning')) { return }

    $Start = Start-WtExternalToolTask -Task $Task -Spec $Spec -Mode 'download'
    if (-not $Start.Started)
    {
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Download.Title') -Lines @((Get-WtString -Key 'Mas.Busy.Download')) -Tone 'Warning'
        return
    }

    Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Mas.Download.Title') -Tone 'StatusInfo'
    $State.Screen.Dirty = $true
}

<#
.SYNOPSIS
    Drains the background task and reports what it produced.
.DESCRIPTION
    Called once per frame by the view. While the task runs it only keeps the progress line
    fresh (and stops a task that outlived its deadline); when the task finishes it reports the
    outcome - an updated pin, a verified download, a cancellation or a failure - re-reads the
    local state, and for an update offers the confirmed release before downloading it.
#>
function Update-WtExternalToolTask
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Task = $State.ExternalToolTask
    if (-not $Task -or -not $Task.Handle) { return }

    if (Test-WtExternalToolTaskExpired -Task $Task)
    {
        # The transport has its own, smaller limits; this is the backstop for a socket that
        # never answers. It is reported, never silently retried.
        $Stop = Stop-WtExternalToolTask -Task $Task -Force
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Download.Title') `
            -Lines @((Get-WtString -Key 'Mas.Download.Expired' -Arguments @([string]$Stop.Phase))) -Tone 'Error'
        $null = Complete-WtExternalToolTask -Task $Task
        $null = Update-WtExternalToolState -State $State
        return
    }

    if (Test-WtExternalToolTaskBusy -Task $Task)
    {
        # Repaint only when something the line shows changed: received bytes, phase or the
        # elapsed second. Painting every frame would burn the terminal for nothing.
        $Progress = $Task.Progress
        $Elapsed = 0
        if ($Progress.StartedUtc -and $Progress.StartedUtc -gt [datetime]::MinValue)
        {
            # A task that was created but never started has no start time; clamping keeps the
            # snapshot (and the elapsed line) meaningful instead of overflowing on the epoch.
            $Elapsed = [int][math]::Min(86400, [math]::Max(0, ([datetime]::UtcNow - $Progress.StartedUtc).TotalSeconds))
        }
        $Snapshot = '{0}|{1}|{2}|{3}' -f [string]$Progress.Phase, [long]$Progress.Received, [int]$Progress.Percent, $Elapsed
        if ($Snapshot -ne $State.ExternalToolProgressSnapshot)
        {
            $State.ExternalToolProgressSnapshot = $Snapshot
            $State.Screen.Dirty = $true
        }
        return
    }

    $Outcome = Complete-WtExternalToolTask -Task $Task
    if (-not $Outcome.Completed) { return }

    $Mode = [string]$Task.Mode
    $Result = $Outcome.Result
    $Spec = Get-WtExternalToolSpec

    if ($Outcome.Error)
    {
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Download.Failed') -Lines @([string]$Outcome.Error) -Tone 'Error'
        $null = Update-WtExternalToolState -State $State
        return
    }

    if ($Mode -eq 'resolve')
    {
        $Release = $Result
        if (-not $Release -or -not $Release.Ok)
        {
            $Reason = if ($Release -and $Release.Cancelled) { Get-WtString -Key 'Mas.Download.Cancelled' } else { [string]$Release.Reason }
            Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Update.Title') -Lines @((Get-WtString -Key 'Mas.Update.NoInfo' -Arguments @($Reason))) -Tone 'Warning'
            return
        }

        $Tool = if ($State.ExternalTool) { $State.ExternalTool } else { Update-WtExternalToolState -State $State }
        if ($Release.UpToDate -and [string]$Tool.Pin.Commit -eq [string]$Release.Commit)
        {
            Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Update.Title') `
                -Lines @((Get-WtString -Key 'Mas.Update.Same' -Arguments @([string]$Release.Tag))) -Tone 'Default'
            return
        }

        $ConfirmLines = @(
            (Get-WtString -Key 'Mas.Update.Confirm' -Arguments @([string]$Release.Tag, [string]$Release.Commit, [string]$Release.Bytes)),
            (Get-WtString -Key 'Mas.Download.Verify'),
            (Get-WtString -Key 'Mas.Download.NoExecute')
        )
        if (-not (Confirm-WtTui -State $State -Title (Get-WtString -Key 'Mas.Update.Title') -Lines $ConfirmLines -Tone 'Warning'))
        {
            Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Mas.Update.Same' -Arguments @([string]$Release.Tag)) -Tone 'StatusInfo'
            return
        }

        $Start = Start-WtExternalToolTask -Task $Task -Spec $Spec -Mode 'download' -Release $Release
        if (-not $Start.Started)
        {
            Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Update.Title') -Lines @((Get-WtString -Key 'Mas.Busy.Download')) -Tone 'Warning'
            return
        }

        Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Mas.Update.Title') -Tone 'StatusInfo'
        $State.Screen.Dirty = $true
        return
    }

    # Download (or update download) finished.
    if ($Outcome.Cancelled -or ($Result -and [string]$Result.Status -eq 'cancelled'))
    {
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Download.Title') -Lines @((Get-WtString -Key 'Mas.Download.Cancelled')) -Tone 'Warning'
        Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Mas.Download.Cancelled') -Tone 'StatusWarn'
        $null = Update-WtExternalToolState -State $State
        return
    }

    if ($Result -and $Result.Status -eq 'dryrun')
    {
        Show-WtExternalToolDryRun -State $State -Action 'download'
        return
    }

    $Tool = Update-WtExternalToolState -State $State

    if ($Result -and $Result.Status -eq 'succeeded')
    {
        $Lines = @()
        if ([string]$Result.Code -eq 'Updated')
        {
            $Lines += (Get-WtString -Key 'Mas.Update.Done' -Arguments @([string]$Tool.Pin.Tag, [string]$Tool.Pin.Commit))
        }
        $Lines += (Get-WtString -Key 'Mas.Download.Done' -Arguments @([string]$Tool.Bytes, [string]$Tool.Sha256))
        $Lines += (Get-WtString -Key 'Mas.Status.Verified')
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key $(if ([string]$Result.Code -eq 'Updated') { 'Mas.Update.Title' } else { 'Mas.Download.Title' })) -Lines $Lines -Tone 'Success'
        Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Mas.Status.Ready') -Tone 'StatusOk'
        return
    }

    $Reason = if ($Result -and $Result.Reason) { [string]$Result.Reason } else { Get-WtString -Key 'Mas.Download.Failed' -Arguments @('?') }
    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Download.Failed') -Lines @($Reason) -Tone 'Error'
    Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Mas.Download.Failed' -Arguments @([string]$Result.Code)) -Tone 'StatusError'
}

<#
.SYNOPSIS
    Stores the Windows activation method the main action will run.
.DESCRIPTION
    Only ids from the closed method table are accepted, and the write goes through the same settings
    file the rest of the interface uses. Nothing is activated here: the selection is what the main
    screen's primary action then runs, as that specific method and no other.
#>
function Select-WtActivationMethod
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$Id
    )

    $Method = Get-WtWindowsActivationMethod -Id $Id
    if (-not $Method) { return }

    $Title = Get-WtString -Key 'Mas.Section.Methods'

    try
    {
        $null = Set-WtWindowsActivationMethodSetting -Id $Id
    }
    catch
    {
        Show-WtTuiMessage -State $State -Title $Title -Lines @([string]$_.Exception.Message) -Tone 'Error'
        return
    }

    $Text = '{0} - {1}' -f (Get-WtActivationMethodText -Method $Method), (Get-WtActivationDurationModelText -Method $Method)

    # Selecting a method only chooses what the main A action would run. It does not change the
    # machine's licensing status - the observed status line is untouched and stays as it was.
    Show-WtTuiMessage -State $State -Title $Title -Lines @(
        (Get-WtString -Key 'Mas.Method.Selected' -Arguments @($Text)),
        (Get-WtString -Key 'Mas.Method.NoStatusChange'),
        (Get-WtString -Key 'Mas.Method.Duration' -Arguments @((Get-WtActivationDurationText -Method $Method))),
        (Get-WtString -Key 'Mas.Method.Internet' -Arguments @((Get-WtActivationInternetText -Method $Method)))
    ) -Tone 'Success'

    Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Mas.Method.Selected' -Arguments @($Text)) -Tone 'StatusOk'
    $State.Screen.Dirty = $true
}

<#
.SYNOPSIS
    Removes the downloaded file, its staging leftovers and the provenance record.
#>
function Invoke-WtExternalToolRemoveAction
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Spec = Get-WtExternalToolSpec
    $Tool = if ($State.ExternalTool) { $State.ExternalTool } else { Update-WtExternalToolState -State $State }

    if (-not $Tool.Installed -and -not $Tool.Provenance)
    {
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Remove.Title') -Lines @((Get-WtString -Key 'Mas.Remove.Nothing')) -Tone 'Default'
        return
    }

    if ($State.DryRun)
    {
        Show-WtExternalToolDryRun -State $State -Action 'remove'
        return
    }

    $ConfirmLines = @(
        (Get-WtString -Key 'Mas.Remove.Confirm' -Arguments @([string]$Spec.Name)),
        (Get-WtString -Key 'Mas.Remove.Note')
    )
    if (-not (Confirm-WtTui -State $State -Title (Get-WtString -Key 'Mas.Remove.Title') -Lines $ConfirmLines -Tone 'Warning')) { return }

    $Result = Remove-WtExternalToolFiles -Spec $Spec
    $null = Update-WtExternalToolState -State $State

    if ($Result.Status -eq 'succeeded')
    {
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Remove.Title') `
            -Lines @((Get-WtString -Key 'Mas.Remove.Done' -Arguments @([string]@($Result.Removed).Count)), (Get-WtString -Key 'Mas.Remove.Note')) -Tone 'Success'
        return
    }

    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Remove.Title') -Lines @((Get-WtString -Key 'Mas.Remove.Failed' -Arguments @([string]$Result.Reason))) -Tone 'Error'
}

<#
.SYNOPSIS
    Runs the activation settings & details view: bounded loop, background transfers, its own key map.
.DESCRIPTION
    The workspace owns the keyboard while it is open, so this loop reads frames directly. Each
    frame first drains the background task (progress and completion) and then reads one key,
    which is what keeps the interface responsive while a download runs.

    While a transfer is in flight: Esc asks it to stop (the view stays open and reports the
    outcome), the other keys are refused with a message instead of starting a second transfer,
    and `?` still works. Esc when nothing is running leaves the view. `1`, `2` and `3` select the
    activation method the main screen's primary action runs; nothing is started from here.
#>
function Show-WtTuiActivationSettings
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $null = Update-WtExternalToolState -State $State
    $null = Get-WtTuiExternalToolTask -State $State
    $State.Screen.Dirty = $true

    try
    {
        while ($true)
        {
            Update-WtExternalToolTask -State $State

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
                Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Title') -Lines @((Get-WtString -Key 'Mas.Busy.Download')) -Tone 'Warning'
                continue
            }

            switch ($Character)
            {
                '1' { Select-WtActivationMethod -State $State -Id 'HWID' }
                '2' { Select-WtActivationMethod -State $State -Id 'TSforge' }
                '3' { Select-WtActivationMethod -State $State -Id 'OnlineKMS' }
                'v' { Invoke-WtExternalToolDocAction -State $State }
                'd' { Invoke-WtExternalToolDownloadAction -State $State }
                'u' { Invoke-WtExternalToolDownloadAction -State $State -Latest }
                'r' { Invoke-WtExternalToolRemoveAction -State $State }
                't'
                {
                    # The documented slmgr /ato request, kept from the licensing workspace: it is a
                    # licensing action, not one of the upstream activation methods, so it lives here
                    # rather than next to the single primary action of the main screen.
                    $License = $State.Licensing
                    if (-not $License) { $License = Read-WtLicensingDiagnostics }
                    $State.Licensing = $License
                    Invoke-WtLicensingAction -State $State -License $License
                }
                '?'
                {
                    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mas.Title') -Lines @(
                        (Get-WtString -Key 'Mas.Help.Source'),
                        (Get-WtString -Key 'Mas.Help.Local'),
                        (Get-WtString -Key 'Mas.Help.Actions'),
                        (Get-WtString -Key 'Mas.Help.Methods'),
                        (Get-WtString -Key 'Mas.Help.Safety'),
                        (Get-WtString -Key 'Mas.Help.Offline')
                    )
                }
                default { }
            }
        }
    }
    finally
    {
        Close-WtTuiExternalToolTask -State $State
        $State.ExternalTool = $null
        $State.ExternalToolProgressSnapshot = ''
        $State.Screen.Dirty = $true
    }
}
