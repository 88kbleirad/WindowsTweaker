# WindowsTweaker - structured bridge protocol (backend half).
#
# This file is the protocol layer of the WinUI 3 frontend bridge. It is dot-sourced by
# BridgeHost.ps1 (and by the tests); it never imports the module itself and never touches
# the module's internals - the host does that. Everything here is 5.1-safe and has no
# Windows-specific dependency, so the framing and the allowlist are exercised on any
# platform.
#
# Transport: one JSON object per line on stdout, UTF-8, LF-terminated. Diagnostics go to
# stderr. The host's stdout is the protocol channel and carries nothing else
# (Initialize-WtLogging -Console $false, $ProgressPreference etc. are enforced by the
# host). All byte/line bounds that protect the app live here.

$Script:WtBridgeProtocolVersion = 1
$Script:WtBridgeMaxLineBytes = 8MB
$Script:WtBridgeMaxPendingRequests = 8
$Script:WtBridgeWorkerStartupTimeoutMs = 60000
$Script:WtBridgeDefaultTimeoutMs = 60000
$Script:WtBridgeApplyTimeoutMs = 1800000

# ---- framing -------------------------------------------------------------

<#
.SYNOPSIS
    Writes one protocol frame (a single-line JSON object) to stdout.
.DESCRIPTION
    The frame is routed through the host's Console.Out, which is UTF-8 with no BOM by
    construction. A frame that would exceed the byte bound is refused outright and the
    error is reported as its own frame, so a huge result can never corrupt the stream.
#>
function Write-WtBridgeFrame
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Payload)

    try
    {
        $Json = ConvertTo-Json -InputObject $Payload -Depth 12 -Compress
        $Bytes = [System.Text.Encoding]::UTF8.GetByteCount($Json)
        if ($Bytes -gt $Script:WtBridgeMaxLineBytes)
        {
            Write-WtBridgeFrame -Payload ([ordered]@{
                type = 'error'
                id = $null
                code = 'PayloadTooLarge'
                message = "A result frame exceeded the $($Script:WtBridgeMaxLineBytes)-byte bound and was not sent."
            })
            return
        }
        $Host.UI.WriteLine($Json)
    }
    catch
    {
        # The very frame that reports the failure must not throw again.
        try { $Host.UI.WriteLine((ConvertTo-Json -InputObject @{ type = 'error'; id = $null; code = 'FrameFailure'; message = $_.Exception.Message } -Compress)) } catch { $null = $_ }
    }
}

<#
.SYNOPSIS
    Reads one request object from the input reader, enforcing all bounds.
.DESCRIPTION
    The reader is the raw stdin stream. A line longer than the byte bound - which is
    never produced by a well-behaved client - is discarded, the client is warned with an
    error frame, and the loop continues (the protocol never trusts its input).
#>
function Read-WtBridgeRequest
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Reader)

    try
    {
        $Line = $Reader.ReadLine()
    }
    catch
    {
        return $null
    }
    if ($null -eq $Line) { return $null }

    if ($Line.Length -gt $Script:WtBridgeMaxLineBytes)
    {
        Write-WtBridgeFrame -Payload ([ordered]@{
            type = 'error'
            id = $null
            code = 'FrameTooLarge'
            message = "A request line exceeded the $($Script:WtBridgeMaxLineBytes)-byte bound and was discarded."
        })
        return $null
    }

    try
    {
        $Request = ConvertFrom-Json -InputObject $Line
    }
    catch
    {
        Write-WtBridgeFrame -Payload ([ordered]@{
            type = 'error'
            id = $null
            code = 'InvalidRequest'
            message = "A request was not valid JSON and was discarded: $($_.Exception.Message)"
        })
        return $null
    }

    if ($null -eq $Request -or $Request -isnot [psobject])
    {
        Write-WtBridgeFrame -Payload ([ordered]@{
            type = 'error'
            id = $null
            code = 'InvalidRequest'
            message = 'A request was not a JSON object and was discarded.'
        })
        return $null
    }

    return $Request
}

<#
.SYNOPSIS
    Builds a success result frame.
#>
function New-WtBridgeResultFrame
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Data = $null,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Meta = $null
    )

    return [ordered]@{
        type = 'result'
        id = $Id
        ok = $true
        data = $Data
        meta = $Meta
    }
}

<#
.SYNOPSIS
    Builds a failure result frame.
#>
function New-WtBridgeErrorFrame
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $false)][string]$Message = ''
    )

    return [ordered]@{
        type = 'error'
        id = $Id
        code = $Code
        message = $Message
    }
}

<#
.SYNOPSIS
    Builds a progress event frame (related to one request id).
#>
function New-WtBridgeProgressFrame
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $false)][string]$Phase = '',
        [Parameter(Mandatory = $false)][string]$Text = '',
        [Parameter(Mandatory = $false)][AllowNull()][object]$Item = $null,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Done = $null,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Total = $null
    )

    return [ordered]@{
        type = 'progress'
        id = $Id
        phase = $Phase
        text = $Text
        item = $Item
        done = $Done
        total = $Total
    }
}

<#
.SYNOPSIS
    Builds a notification frame (no request id; e.g. backend lifecycle events).
#>
function New-WtBridgeNoticeFrame
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Data = $null
    )

    return [ordered]@{
        type = 'notice'
        kind = $Kind
        data = $Data
    }
}

<#
.SYNOPSIS
    Normalises an incoming request into a plain hashtable.
.DESCRIPTION
    ConvertFrom-Json returns PSCustomObject on 5.1 and PSCustomObject/ordered hashtables
    on 7; every consumer in the host works on one shape. Unknown keys are dropped, which
    is the allowlist's consumer side: a caller can never smuggle extra parameters into an
    operation through the request envelope.
#>
function ConvertTo-WtBridgeRequestMap
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Request)

    $Map = @{}
    foreach ($Property in $Request.psobject.Properties)
    {
        $Map[$Property.Name] = ConvertTo-WtBridgeValue -Value $Property.Value
    }
    return $Map
}

<#
.SYNOPSIS
    Recursively normalises a JSON-derived value: PSCustomObjects become ordered
    hashtables, arrays get their elements normalised, everything else stays as is.
#>
function ConvertTo-WtBridgeValue
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Array])
    {
        $List = [System.Collections.Generic.List[object]]::new()
        foreach ($Item in $Value)
        {
            $List.Add((ConvertTo-WtBridgeValue -Value $Item))
        }
        return $List.ToArray()
    }
    if ($Value -is [psobject] -and $Value.psobject.Properties.Count -gt 0)
    {
        $Map = [ordered]@{}
        foreach ($Property in $Value.psobject.Properties)
        {
            $Map[$Property.Name] = ConvertTo-WtBridgeValue -Value $Property.Value
        }
        return $Map
    }
    return $Value
}

<#
.SYNOPSIS
    Reads a string parameter from a request map, with a default.
#>
function Get-WtBridgeStringParam
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$Map,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)][string]$Default = ''
    )

    if ($Map.ContainsKey($Name) -and $null -ne $Map[$Name])
    {
        return [string]$Map[$Name]
    }
    return $Default
}

<#
.SYNOPSIS
    Reads a boolean parameter from a request map, with a default.
#>
function Get-WtBridgeBoolParam
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$Map,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)][bool]$Default = $false
    )

    if ($Map.ContainsKey($Name) -and $null -ne $Map[$Name] -and $Map[$Name] -is [bool])
    {
        return [bool]$Map[$Name]
    }
    return $Default
}

<#
.SYNOPSIS
    Reads an integer parameter from a request map, with a default.
#>
function Get-WtBridgeIntParam
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$Map,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)][int]$Default = 0
    )

    if ($Map.ContainsKey($Name) -and $null -ne $Map[$Name])
    {
        try { return [int]$Map[$Name] } catch { return $Default }
    }
    return $Default
}

<#
.SYNOPSIS
    Reads an array parameter from a request map.
#>
function Get-WtBridgeArrayParam
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$Map,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not $Map.ContainsKey($Name) -or $null -eq $Map[$Name]) { return @() }
    return @($Map[$Name])
}

<#
.SYNOPSIS
    Reads a hashtable parameter from a request map (for Arguments).
#>
function Get-WtBridgeHashtableParam
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$Map,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not $Map.ContainsKey($Name) -or $null -eq $Map[$Name]) { return $null }
    return $Map[$Name]
}

# ---- frontend string contract ----------------------------------------------

<#
.SYNOPSIS
    The string keys the native frontend looks up in the served tables.
.DESCRIPTION
    The WinUI interface keeps no translation of its own: it renders whatever the engine's
    string tables say. This list is the frontend's key vocabulary, and it exists for three
    reasons:
      * the loading gate requires every defined string key to be referenced by a literal
        somewhere in src/, and this is where the frontend's keys are referenced;
      * the handshake serves it, so a client can detect a table that is missing a key it
        needs instead of rendering an empty label;
      * a key that nothing references is dead weight, and this list makes that visible.
#>
function Get-WtBridgeGuiStringKeys
{
    [CmdletBinding()]
    param ()

    return @(
        'Gui.Nav.Overview'
        'Gui.Nav.Tweaks'
        'Gui.Nav.Review'
        'Gui.Nav.History'
        'Gui.Nav.Diagnostics'
        'Gui.Nav.Licensing'
        'Gui.Header.Environment'
        'Gui.Header.Backend'
        'Gui.Header.Language'
        'Gui.Header.ReducedMotion'
        'Gui.Details'
        'Gui.Actions'
        'Gui.Status'
        'Gui.Ready'
        'Gui.Starting'
        'Gui.BackendDown'
        'Gui.BackendRestart'
        'Gui.Column.Tweak'
        'Gui.Column.Category'
        'Gui.Column.State'
        'Gui.Tweaks.OnlySupported'
        'Gui.Tweaks.RowCount'
        'Gui.Column.Target'
        'Gui.Column.Risk'
        'Gui.Column.Scope'
        'Gui.Column.Result'
        'Gui.Column.Outcome'
        'Gui.Column.Time'
        'Gui.Column.Message'
        'Gui.Column.Value'
        'Gui.Column.Operation'
        'Gui.Column.Source'
        'Gui.Action.Preview'
        'Gui.Action.AddPending'
        'Gui.Action.RemovePending'
        'Gui.Action.ClearPending'
        'Gui.Action.Apply'
        'Gui.Action.ApplyDryRun'
        'Gui.Action.Restore'
        'Gui.Action.Export'
        'Gui.Action.Copy'
        'Gui.Action.OpenLogs'
        'Gui.Action.Cancel'
        'Gui.Action.Quit'
        'Gui.Action.Refresh'
        'Gui.Action.Inspect'
        'Gui.Review.Title'
        'Gui.Review.Empty'
        'Gui.Review.Confirm'
        'Gui.Review.Dependency'
        'Gui.Review.DryRunNotice'
        'Gui.Review.Revalidation'
        'Gui.Busy.Title'
        'Gui.Busy.Item'
        'Gui.Result.Title'
        'Gui.Result.Verified'
        'Gui.Result.Unverified'
        'Gui.Result.Compensated'
        'Gui.Result.Journal'
        'Gui.Result.Unchanged'
        'Gui.Close.BusyTitle'
        'Gui.Close.BusyBody'
        'Gui.Close.Wait'
        'Gui.Close.Cancel'
        'Gui.Close.Stay'
        'Gui.Overview.Environment'
        'Gui.Overview.Catalog'
        'Gui.Overview.Tweaks'
        'Gui.Overview.Interrupted'
        'Gui.Overview.Drift'
        'Gui.Overview.Pending'
        'Gui.Overview.Packs'
        'Gui.Overview.None'
        'Gui.Diagnostics.Report'
        'Gui.Diagnostics.Scan'
        'Gui.Diagnostics.ScanPath'
        'Gui.Diagnostics.Monitor'
        'Gui.Diagnostics.MonitorRun'
        'Gui.Diagnostics.LogPath'
        'Gui.Diagnostics.StatePath'
        'Gui.Diagnostics.Privacy'
        'Gui.Diagnostics.Devices'
        'Gui.Diagnostics.Power'
        'Gui.Diagnostics.Quarantine'
        'Gui.Diagnostics.SetupPlans'
        'Gui.Diagnostics.Unavailable'
        'Gui.Licensing.Status'
        'Gui.Licensing.Edition'
        'Gui.Licensing.Method'
        'Gui.Licensing.NoMethod'
        'Gui.Licensing.Tool'
        'Gui.Licensing.Activate'
        'Gui.Licensing.Download'
        'Gui.Licensing.Remove'
        'Gui.Licensing.Slmgr'
        'Gui.Licensing.Separate'
        'Gui.Licensing.Duration'
        'Gui.Error.BackendExited'
        'Gui.Error.BackendTimeout'
        'Gui.Error.BackendProtocol'
        'Gui.Error.ProtocolMismatch'
        'Gui.Error.RequiresElevation'
        'Gui.Header.Elevate'
        'Gui.Header.ElevateHint'
        'Gui.Error.BusyMutating'
        'Gui.Error.ElevationDeclined'
        'Gui.Error.ElevationFailed'
        'Gui.Footer.Hint'
        'Gui.Error.NoSelection'
        # Keys the frontend reuses from the terminal vocabulary's base tables.
        'Tui.Header.Admin'
        'Tui.Header.Standard'
        'Gui.Error.EmptySearch'
        'Gui.Error.LoadFailed'
        # Keys the frontend reuses from the terminal interface's vocabulary.
        'Menu.Catalog'
        'Menu.History'
        'Gui.Title'
        'Gui.Search'
        'Gui.Apply'
        'Gui.Rollback'
        'Gui.Refresh'
        'Gui.DryRun'
        'Gui.Pending'
        'Gui.History'
        'Gui.Category'
        'Gui.Privilege'
        'Gui.Restart'
        'Gui.RollbackSupport'
        'Gui.NoSelection'
        'Gui.IrreversibleWarning'
        'Gui.NothingPending'
        'Gui.Busy'
        'Gui.BatchStopped'
        'Common.Cancel'
        'Common.Yes'
        'Common.No'
        'Common.None'
        'State.Header'
        'State.Impact'
        'State.Supported'
        'Tui.Status.Refreshing'
        'Tui.Busy.CancelActive'
        'Tui.Busy.Hint'
        'Tui.Keys.Busy'
        'Cli.NotAdmin'
        'Cli.Subtitle'
    )
}

# ---- allowlist -------------------------------------------------------------

# Each entry: Name, Mutating, Privileged, Worker, TimeoutMs.
<#
.SYNOPSIS
    The closed operation table. Every operation the bridge can run is listed here; a
    request whose op is not a key is refused before anything runs. The categories:
      Mutating   - writes to the system or the journal; never runs twice at once;
      Privileged - requires an elevated bridge process (validated again in the host);
      Worker     - runs in the background runspace (long/streaming or mutating);
      TimeoutMs  - the per-operation deadline that cancels it.
#>
function Get-WtBridgeOperations
{
    [CmdletBinding()]
    param ()

    $Ops = @{}
    foreach ($Op in @(
        @{ Name = 'handshake';    Mutating = $false; Privileged = $false; Worker = $false; TimeoutMs = 15000 },
        @{ Name = 'ping';         Mutating = $false; Privileged = $false; Worker = $false; TimeoutMs = 15000 },
        @{ Name = 'strings.get';  Mutating = $false; Privileged = $false; Worker = $false; TimeoutMs = 15000 },
        @{ Name = 'env.status';   Mutating = $false; Privileged = $false; Worker = $false; TimeoutMs = 30000 },
        @{ Name = 'catalog.list'; Mutating = $false; Privileged = $false; Worker = $false; TimeoutMs = 30000 },
        @{ Name = 'catalog.tweaks'; Mutating = $false; Privileged = $false; Worker = $false; TimeoutMs = 60000 },
        @{ Name = 'state.get';    Mutating = $false; Privileged = $false; Worker = $true;  TimeoutMs = 180000 },
        @{ Name = 'state.refresh'; Mutating = $false; Privileged = $false; Worker = $true;  TimeoutMs = 180000 },
        @{ Name = 'preview.get';  Mutating = $false; Privileged = $false; Worker = $true;  TimeoutMs = 120000 },
        @{ Name = 'plan.get';     Mutating = $false; Privileged = $false; Worker = $true;  TimeoutMs = 120000 },
        @{ Name = 'history.list';  Mutating = $false; Privileged = $false; Worker = $true;  TimeoutMs = 60000 },
        @{ Name = 'journal.operation'; Mutating = $false; Privileged = $false; Worker = $true; TimeoutMs = 60000 },
        @{ Name = 'history.interrupted'; Mutating = $false; Privileged = $false; Worker = $true; TimeoutMs = 60000 },
        @{ Name = 'restore.plan'; Mutating = $false; Privileged = $false; Worker = $true;  TimeoutMs = 120000 },
        @{ Name = 'session.list'; Mutating = $false; Privileged = $false; Worker = $true;  TimeoutMs = 60000 },
        @{ Name = 'drift.get';    Mutating = $false; Privileged = $false; Worker = $true;  TimeoutMs = 120000 },
        @{ Name = 'preset.list';  Mutating = $false; Privileged = $false; Worker = $true;  TimeoutMs = 60000 },
        @{ Name = 'preset.load';  Mutating = $false; Privileged = $false; Worker = $true;  TimeoutMs = 60000 },
        @{ Name = 'preset.export'; Mutating = $false; Privileged = $false; Worker = $false; TimeoutMs = 30000 },
        @{ Name = 'diagnostics.report'; Mutating = $false; Privileged = $false; Worker = $true; TimeoutMs = 120000 },
        @{ Name = 'scan.directory'; Mutating = $false; Privileged = $false; Worker = $true;  TimeoutMs = 600000 },
        @{ Name = 'monitor.defaults'; Mutating = $false; Privileged = $false; Worker = $false; TimeoutMs = 30000 },
        @{ Name = 'monitor.cycle'; Mutating = $false; Privileged = $false; Worker = $true;  TimeoutMs = 600000 },
        @{ Name = 'dashboard.list'; Mutating = $false; Privileged = $false; Worker = $false; TimeoutMs = 30000 },
        @{ Name = 'dashboard.get';  Mutating = $false; Privileged = $false; Worker = $false; TimeoutMs = 30000 },
        @{ Name = 'metrics.range';  Mutating = $false; Privileged = $false; Worker = $true;  TimeoutMs = 60000 },
        @{ Name = 'inventory.devices'; Mutating = $false; Privileged = $false; Worker = $true; TimeoutMs = 120000 },
        @{ Name = 'power.settings'; Mutating = $false; Privileged = $false; Worker = $true;  TimeoutMs = 120000 },
        @{ Name = 'privacy.activity'; Mutating = $false; Privileged = $false; Worker = $true;  TimeoutMs = 120000 },
        @{ Name = 'quarantine.summary'; Mutating = $false; Privileged = $false; Worker = $true; TimeoutMs = 60000 },
        @{ Name = 'quarantine.candidates'; Mutating = $false; Privileged = $false; Worker = $true; TimeoutMs = 120000 },
        @{ Name = 'setup.list';    Mutating = $false; Privileged = $false; Worker = $true;  TimeoutMs = 60000 },
        @{ Name = 'setup.preview'; Mutating = $false; Privileged = $false; Worker = $true;  TimeoutMs = 120000 },
        @{ Name = 'licensing.diagnostics'; Mutating = $false; Privileged = $false; Worker = $true; TimeoutMs = 120000 },
        @{ Name = 'exttool.status'; Mutating = $false; Privileged = $false; Worker = $true;  TimeoutMs = 60000 },
        @{ Name = 'exttool.methods'; Mutating = $false; Privileged = $false; Worker = $true;  TimeoutMs = 60000 },
        @{ Name = 'exttool.setmethod'; Mutating = $false; Privileged = $false; Worker = $false; TimeoutMs = 30000 },
        @{ Name = 'exttool.download'; Mutating = $true;  Privileged = $false; Worker = $true;  TimeoutMs = 600000 },
        @{ Name = 'exttool.remove';   Mutating = $true;  Privileged = $false; Worker = $true;  TimeoutMs = 60000 },
        @{ Name = 'exttool.activate'; Mutating = $true;  Privileged = $false; Worker = $true;  TimeoutMs = 1800000 },
        @{ Name = 'slmgr.request';    Mutating = $true;  Privileged = $true;  Worker = $true;  TimeoutMs = 600000 },
        @{ Name = 'apply.batch';  Mutating = $true;  Privileged = $false; Worker = $true;  TimeoutMs = 1800000 },
        @{ Name = 'rollback';     Mutating = $true;  Privileged = $false; Worker = $true;  TimeoutMs = 1800000 },
        @{ Name = 'session.restore'; Mutating = $true;  Privileged = $false; Worker = $true;  TimeoutMs = 1800000 },
        @{ Name = 'restart.test'; Mutating = $false; Privileged = $false; Worker = $false; TimeoutMs = 30000 },
        @{ Name = 'restart.invoke'; Mutating = $true;  Privileged = $true;  Worker = $true;  TimeoutMs = 600000 },
        @{ Name = 'restorepoint.create'; Mutating = $true; Privileged = $true;  Worker = $true;  TimeoutMs = 120000 },
        @{ Name = 'language.set';  Mutating = $false; Privileged = $false; Worker = $false; TimeoutMs = 30000 },
        @{ Name = 'cancel';        Mutating = $false; Privileged = $false; Worker = $false; TimeoutMs = 15000 },
        @{ Name = 'quit';          Mutating = $false; Privileged = $false; Worker = $false; TimeoutMs = 15000 }
    ))
    {
        $Ops[$Op.Name] = $Op
    }

    return $Ops
}
