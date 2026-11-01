# WindowsTweaker - monitoring workspace (TUI).
#
# The workspace is a full-screen mode reached from Overview (or the B key). It uses the
# existing screen grid and dialogs; it never opens listeners and never mutates state. It
# is driven by a single collector runspace whose snapshots feed a bounded metric history.

<#
.SYNOPSIS
    Consumes collector snapshots into the bounded metric history.
.DESCRIPTION
    Registers raw samples and derives counter rates (bytes/s) from monotonic elapsed time.
    Returns the list of registered snapshot summaries.
#>
function Invoke-WtMonitorApplySnapshots
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param
    (
        [Parameter(Mandatory = $true)][object]$Monitor,
        [Parameter(Mandatory = $true)][object[]]$Snapshots
    )

    $Summaries = [System.Collections.Generic.List[object]]::new()
    $RateState = $Monitor.RateState

    foreach ($Snapshot in $Snapshots)
    {
        foreach ($Sample in @($Snapshot.Samples))
        {
            if (-not $Sample) { continue }

            $Result = Add-WtMetricSample -History $Monitor.History -Sample $Sample
            if ($Sample.type -eq 'counter' -and $Result.Accepted)
            {
                $Key = Get-WtMetricSeriesKey -Sample $Sample
                if ($RateState.ContainsKey($Key))
                {
                    $Rate = ConvertTo-WtMetricRate -Previous $RateState[$Key] -Current $Sample -MonotonicMs $Monitor.LastMonoMs
                    if ($Rate)
                    {
                        $RateId = ([string]$Sample.id).Replace('Bytes', 'Rate')
                        $RateSample = New-WtMetricSample -Id $RateId -Type gauge -Unit 'bytes/s' -Quality valid `
                            -Value $Rate.valuePerSecond -Dims ($Sample.dims) -Provider ([string]$Sample.provider) -TsMs ([long]$Sample.tsMs)
                        $null = Add-WtMetricSample -History $Monitor.History -Sample $RateSample
                        $Monitor.RateSeries[$Key] = $RateId
                    }
                }
                $RateState[$Key] = $Sample
            }
        }

        $Summaries.Add(@{
            Kind = $Snapshot.Kind
            Backend = $Snapshot.Backend
            Reason = $Snapshot.Reason
            SampleCount = @($Snapshot.Samples).Count
        })
    }

    return @($Summaries.ToArray())
}

<#
.SYNOPSIS
    Adds event metrics (from the journal) to the history for alert rules.
.DESCRIPTION
    Read-only journal summaries feed the ops.* alert metrics at each slow cycle.
#>
function Add-WtMonitorEventMetrics
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Monitor,
        [Parameter(Mandatory = $false)][long]$NowMs = 0
    )

    if (-not $NowMs) { $NowMs = [int64]([datetime]::UtcNow.ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,[datetimekind]::Utc)).TotalMilliseconds }

    try
    {
        $Drift = @(Get-WtDriftInternal -OnlyDrifted).Count
        $Interrupted = @(Get-WtInterruptedOperationInternal).Count
        $VerifyFailed = @(Get-WtJournalEntryInternal -Outcome 'failed' -Limit 500 -All).Count
    }
    catch
    {
        return
    }

    $null = Add-WtMetricSample -History $Monitor.History -Sample (New-WtMetricSample -Id 'ops.drift' -Type gauge -Unit count -Quality valid -Value ([double]$Drift) -TsMs $NowMs)
    $null = Add-WtMetricSample -History $Monitor.History -Sample (New-WtMetricSample -Id 'ops.interrupted' -Type gauge -Unit count -Quality valid -Value ([double]$Interrupted) -TsMs $NowMs)
    $null = Add-WtMetricSample -History $Monitor.History -Sample (New-WtMetricSample -Id 'ops.verification.failed' -Type gauge -Unit count -Quality valid -Value ([double]$VerifyFailed) -TsMs $NowMs)
}

<#
.SYNOPSIS
    Creates a new monitoring workspace session.
#>
function New-WtMonitorSession
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $false)][string]$Backend = 'Auto',
        [Parameter(Mandatory = $false)][int]$FastSeconds = 0,
        [Parameter(Mandatory = $false)][int]$SlowSeconds = 0
    )

    return @{
        History = New-WtMetricHistory
        RateState = @{}
        RateSeries = @{}
        Collector = $null
        Backend = $Backend
        FastSeconds = $FastSeconds
        SlowSeconds = $SlowSeconds
        LastMonoMs = 0
        LastFastMs = 0
        LastSlowMs = 0
        Adapter = ''
        Disk = ''
        Seconds = 300
        Frozen = $false
        Paused = $false
        DashboardId = 'overview'
        PanelIndex = 0
        Alerts = @()
        AlertState = @{}
        AlertRules = @(Get-WtDefaultAlertRules)
        StartWallMs = 0
        LastError = ''
        ProviderErrors = [System.Collections.Generic.List[string]]::new()
        Persistence = $null
        PromSource = $null
    }
}

<#
.SYNOPSIS
    Starts the collector and the session timers.
#>
function Start-WtMonitorSession
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ([Parameter(Mandatory = $true)][hashtable]$Monitor)

    if ($Monitor.Collector -or $Monitor.Paused) { return $Monitor }

    $Monitor.Collector = Start-WtMonitorCollector -FastSeconds $Monitor.FastSeconds -SlowSeconds $Monitor.SlowSeconds -Backend $Monitor.Backend -Adapter $Monitor.Adapter -Disk $Monitor.Disk
    if (-not $Monitor.Persistence) { $Monitor.Persistence = New-WtMetricPersistenceInternal }
    $Monitor.StartWallMs = [int64]([datetime]::UtcNow.ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,[datetimekind]::Utc)).TotalMilliseconds
    $Monitor.LastFastMs = $Monitor.StartWallMs
    $Monitor.LastSlowMs = $Monitor.StartWallMs
    return $Monitor
}

<#
.SYNOPSIS
    Stops the collector deterministically.
#>
function Stop-WtMonitorSession
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][hashtable]$Monitor)

    if ($Monitor.Collector)
    {
        Stop-WtMonitorCollector -Collector $Monitor.Collector
        $Monitor.Collector = $null
    }

    if ($Monitor.Persistence -and $Monitor.Persistence.Enabled)
    {
        Stop-WtMetricPersistenceInternal -Persistence $Monitor.Persistence
        $Monitor.Persistence.Enabled = $false
    }
}

<#
.SYNOPSIS
    Runs one workspace refresh step: collect available snapshots, evaluate alerts.
.DESCRIPTION
    This is invoked on the frame loop; it never blocks (drains the queue only).
#>
function Update-WtMonitorWorkspace
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][hashtable]$Monitor)

    $Collector = $Monitor.Collector
    if (-not $Collector -or -not $Collector.Running) { return }
    if ($Monitor.Paused) { return }

    $Now = [datetime]::UtcNow
    $NowMs = [int64]($Now.ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,[datetimekind]::Utc)).TotalMilliseconds
    $MonoMs = $Collector.Watch.ElapsedMilliseconds

    # Fast schedule.
    if (($Now - $Collector.LastFast).TotalSeconds -ge $Collector.FastSeconds)
    {
        $Cycle = Invoke-WtMonitorCycle -Backend $Collector.Backend -CpuState $Collector.CpuState -Adapter $Collector.Adapter -NowMs $NowMs -MonotonicMs $MonoMs
        $snapshots = @(@{ Kind='Fast'; Samples=@($Cycle.Samples); Backend=$Cycle.Backend; Reason=$Cycle.Reason })
        $null = Invoke-WtMonitorApplySnapshots -Monitor $Monitor -Snapshots $snapshots
        $Collector.LastFast = $Now
        if ($Cycle.Reason) { $Monitor.ProviderErrors.Add("fast: $($Cycle.Reason)") }
        if ($Monitor.Persistence -and $Monitor.Persistence.Enabled) {
            Add-WtMetricPersistenceBatchInternal -Persistence $Monitor.Persistence -Samples @($Cycle.Samples)
        }
    }

    # Slow schedule.
    if (($Now - $Collector.LastSlow).TotalSeconds -ge $Collector.SlowSeconds)
    {
        $Cycle = Invoke-WtMonitorCycle -Backend $Collector.Backend -Slow -Disk $Collector.Disk -NowMs $NowMs -MonotonicMs $MonoMs
        $snapshots = @(@{ Kind='Slow'; Samples=@($Cycle.Samples); Backend=$Cycle.Backend; Reason=$Cycle.Reason })
        $null = Invoke-WtMonitorApplySnapshots -Monitor $Monitor -Snapshots $snapshots
        Add-WtMonitorEventMetrics -Monitor $Monitor -NowMs $NowMs
        $Collector.LastSlow = $Now
        if ($Cycle.Reason) { $Monitor.ProviderErrors.Add("slow: $($Cycle.Reason)") }
        if ($Monitor.Persistence -and $Monitor.Persistence.Enabled) {
            Add-WtMetricPersistenceBatchInternal -Persistence $Monitor.Persistence -Samples @($Cycle.Samples)
            Write-WtMetricPersistenceBatch -Persistence $Monitor.Persistence
            Update-WtMetricRetentionInternal -Persistence $Monitor.Persistence -NowMs $NowMs
        }
    }

    while ($Monitor.ProviderErrors.Count -gt 16) { $Monitor.ProviderErrors.RemoveAt(0) }

    # Collector staleness metric for alerts.
    $Age = (($Now - $Collector.LastFast).TotalSeconds)
    $null = Add-WtMetricSample -History $Monitor.History -Sample (New-WtMetricSample -Id 'host.collector.ageSeconds' -Type gauge -Unit seconds -Quality valid -Value $Age -TsMs $NowMs)

    # Alert evaluation.
    $Latest = @{}
    foreach ($Rule in $Monitor.AlertRules)
    {
        $Key = [string]$Rule.metric
        $Range = Select-WtMetricRange -History $Monitor.History -Key $Key -Seconds 3600
        if (@($Range.Samples).Count -gt 0)
        {
            $Last = $Range.Samples[@($Range.Samples).Count - 1]
            $Latest[$Key] = $Last
        }
    }
    $Monitor.Alerts = @(Invoke-WtAlertEvaluation -Rules $Monitor.AlertRules -LatestByMetric $Latest -State $Monitor.AlertState -NowMs $NowMs)
    if ($Monitor.Persistence -and $Monitor.Persistence.Enabled) {
        Add-WtAlertTransitionInternal -Persistence $Monitor.Persistence -Alerts $Monitor.Alerts -AlertState $Monitor.AlertState -NowMs $NowMs
    }
}

function Get-WtMonitorLatestValue
{
    [CmdletBinding()]
    [OutputType([object])]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$Monitor,
        [Parameter(Mandatory = $true)][string]$Key
    )

    $Range = Select-WtMetricRange -History $Monitor.History -Key $Key -Seconds 3600
    if (@($Range.Samples).Count -eq 0) { return $null }
    $Last = $Range.Samples[@($Range.Samples).Count - 1]
    if ($Last.quality -ne 'valid') { return $null }
    return $Last
}

<#
.SYNOPSIS
    Returns the panel data for the active dashboard.
#>
function Get-WtMonitorPanels
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param ([Parameter(Mandatory = $true)][hashtable]$Monitor)

    $Dashboard = Read-WtDashboardInternal -Id $Monitor.DashboardId
    if (-not $Dashboard) { return @() }

    $Panels = [System.Collections.Generic.List[object]]::new()

    foreach ($Panel in @($Dashboard.panels))
    {
        $Metric = [string]$Panel.metric
        $Unit = [string]$Panel.unit
        $Dims = $Panel.dims
        $FilteredDims = @{}
        if ($Dims)
        {
            foreach ($Prop in $Dims.PSObject.Properties)
            {
                if ([string]$Prop.Value -eq '{selected}' -and $Monitor.Adapter)
                {
                    $FilteredDims[$Prop.Name] = $Monitor.Adapter
                }
                else
                {
                    $FilteredDims[$Prop.Name] = [string]$Prop.Value
                }
            }
        }

        $Key = $Metric
        if ($FilteredDims.Count -gt 0)
        {
            $Key = Get-WtMetricSeriesKey -Sample (New-WtMetricSample -Id $Metric -Type gauge -Unit $Unit -Quality valid -Value 0 -Dims $FilteredDims -TsMs 1)
        }

        $Sample = Get-WtMonitorLatestValue -Monitor $Monitor -Key $Key
        $Value = $null
        if ($Monitor.PromSource -and $Monitor.PromSource.Enabled -and $Script:WtPromQueryTemplates.ContainsKey($Metric))
        {
            $Remote = Invoke-WtPromQuery -Source $Monitor.PromSource -Template $Script:WtPromQueryTemplates[$Metric] -StepSeconds 60
            if ($Remote.Ok -and $Remote.Series.Count -gt 0 -and $Remote.Series[0].Values.Count -gt 0)
            {
                $Series = $Remote.Series[0]
                $Last = $Series.Values[$Series.Values.Count - 1]
                $Value = [double]$Last.Value
            }
        }
        elseif ($Sample -and $null -ne $Sample.value) { $Value = [double]$Sample.value }

        # Chart series: for rate-converted metrics use the derived series id.
        $ChartKey = $Key
        $Panels.Add([pscustomobject]@{
            PSTypeName = 'WindowsTweaker.MonitorPanel'
            id = [string]$Panel.id
            type = [string]$Panel.type
            title = [string]$Panel.title
            metric = $Metric
            unit = $Unit
            aggregation = [string]$Panel.aggregation
            key = $ChartKey
            dims = $FilteredDims
            value = $Value
            sample = $Sample
        })
    }

    return @($Panels.ToArray())
}

<#
.SYNOPSIS
    Returns the source badge text for a panel (empty when no remote source matches).
#>
function Get-WtMonitorSourceBadge
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$Monitor,
        [Parameter(Mandatory = $true)][string]$Metric
    )

    if ($Monitor.PromSource -and $Monitor.PromSource.Enabled -and $Script:WtPromQueryTemplates.ContainsKey($Metric))
    {
        return ' [prom]'
    }
    return ''
}

<#
.SYNOPSIS
    Renders the monitoring workspace to the screen.
.DESCRIPTION
    Header (host/platform, privilege, language, collector state, active dashboard), a
    dashboard grid, footer shortcuts. Panels are drawn with the existing box painter.
#>
function Add-WtMonitorView
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][hashtable]$Monitor
    )

    $Screen = $State.Screen
    $Width = $Screen.Width
    $Height = $Screen.Height

    $CollectorState = if ($Monitor.Paused) { Get-WtString -Key 'Mon.Pause' }
    elseif ($Monitor.Collector) { Get-WtString -Key 'Mon.Collector.Running' }
    else { Get-WtString -Key 'Mon.Collector.Stopped' }

    if ($Monitor.Frozen) { $CollectorState += ' | ' + (Get-WtString -Key 'Mon.Freeze') }
    if ($Monitor.Persistence -and $Monitor.Persistence.Enabled) { $CollectorState += ' | ' + (Get-WtString -Key 'Mon.Persist.On') }

    $DashboardTitle = (Get-WtString -Key "Mon.Dash.$($Monitor.DashboardId)")

    Set-WtScreenText -Screen $Screen -Row 1 -Column 2 -Text (Get-WtString -Key 'Mon.Title') -Style 'Title'
    Set-WtScreenText -Screen $Screen -Row 2 -Column 2 -Text "$DashboardTitle | $CollectorState | $($State.Environment.OSName) | $(Get-WtLanguage | Out-String)" -Style 'ItemMeta' -MaxWidth ($Width - 4)

    $Panels = Get-WtMonitorPanels -Monitor $Monitor
    $Cols = if ($Width -ge 100) { 2 } else { 1 }
    $Top = 4
    $Bottom = $Height - 2
    $PanelHeight = [math]::Max(6, [int](($Bottom - $Top) / [math]::Max(1, [math]::Ceiling($Panels.Count / $Cols))))

    $ColWidth = [int](($Width - 4) / $Cols)
    $Index = 0
    foreach ($Panel in $Panels)
    {
        $Col = $Index % $Cols
        $Row = $Top + [int]([math]::Floor($Index / $Cols) * ($PanelHeight + 1))
        $Left = 2 + ($Col * ($ColWidth + 2))

        if ($Row -gt $Bottom) { break }

        $BaseTitle = if ($Panel.title) { $Panel.title } else { $Panel.metric }
        $Badge = ''
        if ($Metric) { $Badge = Get-WtMonitorSourceBadge -Monitor $Monitor -Metric $Metric }
        $Title = $BaseTitle + $Badge
        if ($Index -eq $Monitor.PanelIndex) { $Title = '> ' + $Title }

        Add-WtScreenBox -Screen $Screen -Row $Row -Column $Left -Width $ColWidth -Height $PanelHeight -Title $Title

        if ($Panel.type -eq 'sparkline')
        {
            $ChartLines = Get-WtMonitorChartBlock -History $Monitor.History -Key $Panel.key -Seconds $Monitor.Seconds `
                -Unit $Panel.unit -Height ($PanelHeight - 3) -Width ($ColWidth - 4) -Method $Panel.aggregation -Unicode $State.Capability.Unicode
            $LineRow = $Row + 1
            foreach ($Line in $ChartLines)
            {
                if ($LineRow -ge ($Row + $PanelHeight - 1)) { break }
                Set-WtScreenText -Screen $Screen -Row $LineRow -Column ($Left + 2) -Text $Line -Style 'Item' -MaxWidth ($ColWidth - 4)
                $LineRow++
            }
        }
        else
        {
            $ValueText = if ($null -ne $Panel.value) { Format-WtMetricValue -Value $Panel.value -Unit $Panel.unit } else { Get-WtString -Key 'Mon.NoHistory' }
            Set-WtScreenText -Screen $Screen -Row ($Row + 1) -Column ($Left + 2) -Text $ValueText -Style 'Item' -MaxWidth ($ColWidth - 4)
            if ($Panel.sample -and $Panel.sample.quality -ne 'valid')
            {
                $Q = Get-WtString -Key "Mon.Alert.$($Panel.sample.quality)"
                Set-WtScreenText -Screen $Screen -Row ($Row + 2) -Column ($Left + 2) -Text $Q -Style 'Warning' -MaxWidth ($ColWidth - 4)
            }
        }

        $Index++
    }

    $ActiveAlerts = Get-WtActiveAlertCount -Alerts $Monitor.Alerts
    Set-WtScreenText -Screen $Screen -Row ($Height) -Column 2 -Text ((Get-WtString -Key 'Mon.Panel.Alerts') + ': ' + $ActiveAlerts) -Style 'ItemMeta'

    $Footer = "$($Monitor.Seconds)s | " + (Get-WtString -Key 'Mon.Hint') + ' | ' + (Get-WtString -Key 'Mon.Persist.Hint') + ' | ' + (Get-WtString -Key 'Mon.Compare.Hint') + ' | ' + (Get-WtString -Key 'Mon.Edit.Hint') + ' | ' + (Get-WtString -Key 'Mon.Prom.Hint')
    Set-WtScreenText -Screen $Screen -Row ($Height) -Column ($Width - 2 - (Get-WtTextWidth -Text $Footer)) -Text $Footer -Style 'Muted' -MaxWidth ($Width - 4)
}

<#
.SYNOPSIS
    Opens the panel inspector for the selected panel.
#>
function Show-WtMonitorInspector
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][hashtable]$Monitor
    )

    $Panels = @(Get-WtMonitorPanels -Monitor $Monitor)
    if ($Panels.Count -eq 0)
    {
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mon.Inspector.Title') -Lines @((Get-WtString -Key 'Mon.NoHistory'))
        return
    }

    $Panel = $Panels[[math]::Min($Monitor.PanelIndex, $Panels.Count - 1)]
    $Range = Select-WtMetricRange -History $Monitor.History -Key $Panel.key -Seconds $Monitor.Seconds
    $Samples = @($Range.Samples)

    $Lines = @(
        (Get-WtString -Key 'Mon.Inspector.Metric') + ": $($Panel.metric)",
        (Get-WtString -Key 'Mon.Inspector.Unit') + ": $($Panel.unit)",
        (Get-WtString -Key 'Mon.Inspector.Source') + ": $(if ($Panel.sample) { $Panel.sample.provider } else { Get-WtString -Key 'Mon.Provider.None' })",
        (Get-WtString -Key 'Mon.Inspector.LastUpdate') + ": $(if ($Range.AvailableTo) { [DateTimeOffset]::FromUnixTimeMilliseconds($Range.AvailableTo).LocalDateTime.ToString('u') } else { '-' })",
        (Get-WtString -Key 'Mon.Inspector.Interval') + ": $(if ($Samples.Count -gt 1) { [math]::Round((($Samples[$Samples.Count-1].tsMs - $Samples[0].tsMs) / ($Samples.Count - 1) / 1000.0), 1).ToString() + 's' } else { '-' })",
        (Get-WtString -Key 'Mon.Inspector.History') + ": $($Samples.Count) samples ($(([DateTimeOffset]::FromUnixTimeMilliseconds($Range.AvailableFrom).LocalDateTime.ToString('HH:mm:ss'))) → $(([DateTimeOffset]::FromUnixTimeMilliseconds($Range.AvailableTo).LocalDateTime.ToString('HH:mm:ss'))))",
        (Get-WtString -Key 'Mon.Inspector.Dims') + ": $(if ($Panel.dims.Count -gt 0) { ($Panel.dims.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ' } else { Get-WtString -Key 'Common.None' })",
        (Get-WtString -Key 'Mon.Inspector.Method') + ": $($Panel.aggregation)",
        (Get-WtString -Key 'Mon.Inspector.Missing') + ": $(if ($Panel.sample -and $Panel.sample.quality -ne 'valid') { $Panel.sample.note } else { '—' })",
        (Get-WtString -Key 'Mon.Inspector.Errors') + ": $(if ($Monitor.ProviderErrors.Count -gt 0) { $Monitor.ProviderErrors[-1] } else { '—' })"
    )

    # Bounded raw sample table.
    $Raw = @($Samples | Select-Object -Last 12)
    if ($Raw.Count -gt 0)
    {
        $Lines += ''
        $Lines += (Get-WtString -Key 'Mon.Inspector.Raw') + ':'
        foreach ($Sample in $Raw)
        {
            $Time = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Sample.tsMs).LocalDateTime.ToString('HH:mm:ss')
            $Val = if ($null -ne $Sample.value) { Format-WtMetricValue -Value ([double]$Sample.value) -Unit $Panel.unit } else { $Sample.quality }
            $Lines += "  $Time  $Val  [$($Sample.quality)]"
        }
    }
    else
    {
        $Lines += (Get-WtString -Key 'Mon.Inspector.NoData')
    }

    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mon.Inspector.Title') -Lines $Lines -Tone 'Default'
}

<#
.SYNOPSIS
    The monitoring workspace main loop.
#>

<#
.SYNOPSIS
    Shows the local alert rules and current states.
.DESCRIPTION
    Acknowledge and mute are interface flags kept on the monitor session; they never
    resolve an alert and never apply changes.
#>
function Show-WtMonitorAlerts
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][hashtable]$Monitor
    )

    $Items = [System.Collections.Generic.List[object]]::new()
    foreach ($Alert in $Monitor.Alerts)
    {
        $StateText = Get-WtString -Key "Mon.Alert.$($Alert.state)"
        $StateText = $StateText.Replace('Mon.Alert.', '')
        $StateText = Get-WtString -Key "Mon.Alert.$($Alert.state)"
        $Extra = @()
        if ($Alert.ack) { $Extra += Get-WtString -Key 'Mon.Alert.ack' }
        if ($Alert.muted) { $Extra += Get-WtString -Key 'Mon.Alert.muted' }
        if ($Extra.Count -gt 0) { $StateText += ' [' + ($Extra -join ', ') + ']' }

        $Items.Add(@{
            Label = (Get-WtString -Key $Alert.explanationKey)
            Right = "$StateText | $($Alert.severity) | $(Get-WtString -Key 'Mon.Alert.Hold' -Arguments @($Alert.durationSeconds)) | $(Get-WtString -Key 'Mon.Alert.Hysteresis' -Arguments @($Alert.hysteresis))"
            Payload = $Alert
            Filter = "$($Alert.id) $($Alert.metric) $($Alert.state)"
            Disabled = $false
            Checked = $false
        })
    }

    $Lines = @(
        (Get-WtString -Key 'Mon.Alert.Title'),
        (Get-WtString -Key 'Mon.Alert.ShowAck'),
        (Get-WtString -Key 'Mon.Alert.NoMute')
    )

    $Result = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Mon.Alert.Title') -Lines $Lines `
        -Items $Items -Searchable -DetailsHeight 4

    if ($null -eq $Result -or $null -eq $Result.Value) { return }

    # Toggle ack and mute for the selected rule (interface flags only).
    $Alert = $Result.Value
    $RuleState = $Monitor.AlertState[$Alert.id]
    if (-not $RuleState) { return }
    $RuleState.ack = -not $RuleState.ack
}


<#
.SYNOPSIS
    Dashboard editor: add/remove panels, reorder, set size, save/duplicate/reset layouts.
.DESCRIPTION
    Uses the existing modal list dialogs. Invalid imported dashboards are refused before
    overwriting a working layout; built-ins remain recoverable templates.
#>
function Show-WtMonitorDashboardEditor
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][hashtable]$Monitor
    )

    $Dashboard = Read-WtDashboardInternal -Id $Monitor.DashboardId
    if (-not $Dashboard) { return }

    while ($true)
    {
        $Panels = @($Dashboard.panels)
        $Items = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $Panels.Count; $i++)
        {
            $Panel = $Panels[$i]
            $Size = if ($Panel.size) { "[$($Panel.size)]" } else { '' }
            $Items.Add(@{
                Label = "$($i + 1). $($Panel.metric) $Size"
                Right = $Panel.type
                Payload = @{ Action = 'Edit'; Index = $i }
                Filter = "$($Panel.id) $($Panel.metric) $($Panel.type)"
                Disabled = $false
                Checked = $false
            })
        }
        $Items.Add(@{ Label = (Get-WtString -Key 'Mon.Edit.Add'); Payload = @{ Action = 'Add' }; Filter = 'add panel'; Disabled = $false; Checked = $false })
        $Items.Add(@{ Label = (Get-WtString -Key 'Mon.Edit.Save'); Payload = @{ Action = 'Save' }; Filter = 'save'; Disabled = $false; Checked = $false })
        $Items.Add(@{ Label = (Get-WtString -Key 'Mon.Edit.Duplicate'); Payload = @{ Action = 'Duplicate' }; Filter = 'duplicate'; Disabled = $false; Checked = $false })
        $Items.Add(@{ Label = (Get-WtString -Key 'Mon.Edit.Reset'); Payload = @{ Action = 'Reset' }; Filter = 'reset'; Disabled = $false; Checked = $false })

        $Result = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Mon.Edit.Title') -Items $Items -Searchable -EmptyText (Get-WtString -Key 'Tui.NoItems')
        if ($null -eq $Result -or $null -eq $Result.Value) { return }

        switch ($Result.Value.Action)
        {
            'Edit'
            {
                $Index = [int]$Result.Value.Index
                $Action = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Mon.Edit.PanelTitle') -Items @(
                    @{ Label = (Get-WtString -Key 'Mon.Edit.Size'); Payload = 'size'; Filter = 'size'; Disabled = $false; Checked = $false }
                    @{ Label = (Get-WtString -Key 'Mon.Edit.Remove'); Payload = 'remove'; Filter = 'remove'; Disabled = $false; Checked = $false }
                    @{ Label = (Get-WtString -Key 'Mon.Edit.MoveUp'); Payload = 'up'; Filter = 'up'; Disabled = ($Index -eq 0); Checked = $false }
                    @{ Label = (Get-WtString -Key 'Mon.Edit.MoveDown'); Payload = 'down'; Filter = 'down'; Disabled = ($Index -eq $Panels.Count - 1); Checked = $false }
                ) -EmptyText (Get-WtString -Key 'Tui.NoItems')
                if (-not $Action -or -not $Action.Value) { continue }

                switch ($Action.Value)
                {
                    'size'
                    {
                        $Size = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Mon.Edit.Size') -Items @(
                            @{ Label = 'small'; Payload = 'small'; Filter = 'small'; Disabled = $false; Checked = $false }
                            @{ Label = 'medium'; Payload = 'medium'; Filter = 'medium'; Disabled = $false; Checked = $false }
                            @{ Label = 'large'; Payload = 'large'; Filter = 'large'; Disabled = $false; Checked = $false }
                        ) -EmptyText (Get-WtString -Key 'Tui.NoItems')
                        if ($Size -and $Size.Value) { $Panels[$Index].size = [string]$Size.Value }
                    }
                    'remove' { $Panels = @($Panels | Where-Object { [array]::IndexOf($Panels, $_) -ne $Index }) }
                    'up'
                    {
                        if ($Index -gt 0)
                        {
                            $Tmp = $Panels[$Index - 1]
                            $Panels[$Index - 1] = $Panels[$Index]
                            $Panels[$Index] = $Tmp
                        }
                    }
                    'down'
                    {
                        if ($Index -lt $Panels.Count - 1)
                        {
                            $Tmp = $Panels[$Index + 1]
                            $Panels[$Index + 1] = $Panels[$Index]
                            $Panels[$Index] = $Tmp
                        }
                    }
                }

                # In-memory edit; saving is explicit.
                $Dashboard.panels = @($Panels)
            }
            'Add'
            {
                $Metric = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Mon.Edit.AddMetric') -Items @(
                    @{ Label = 'host.cpu.utilization'; Payload = 'host.cpu.utilization'; Filter = 'cpu'; Disabled = $false; Checked = $false }
                    @{ Label = 'host.mem.physical.usedBytes'; Payload = 'host.mem.physical.usedBytes'; Filter = 'mem'; Disabled = $false; Checked = $false }
                    @{ Label = 'host.disk.system.freeBytes'; Payload = 'host.disk.system.freeBytes'; Filter = 'disk'; Disabled = $false; Checked = $false }
                    @{ Label = 'host.net.rxBytes'; Payload = 'host.net.rxBytes'; Filter = 'rx'; Disabled = $false; Checked = $false }
                    @{ Label = 'host.net.txBytes'; Payload = 'host.net.txBytes'; Filter = 'tx'; Disabled = $false; Checked = $false }
                    @{ Label = 'host.uptime.seconds'; Payload = 'host.uptime.seconds'; Filter = 'uptime'; Disabled = $false; Checked = $false }
                ) -EmptyText (Get-WtString -Key 'Tui.NoItems')
                if ($Metric -and $Metric.Value)
                {
                    $Type = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Mon.Edit.AddType') -Items @(
                        @{ Label = 'sparkline'; Payload = 'sparkline'; Filter = 'chart'; Disabled = $false; Checked = $false }
                        @{ Label = 'stat'; Payload = 'stat'; Filter = 'stat'; Disabled = $false; Checked = $false }
                    ) -EmptyText (Get-WtString -Key 'Tui.NoItems')
                    if ($Type -and $Type.Value)
                    {
                        $Panels += @{
                            id = "panel$($Panels.Count + 1)"
                            type = [string]$Type.Value
                            metric = [string]$Metric.Value
                            unit = if ([string]$Metric.Value -like '*Bytes*') { 'bytes' } elseif ([string]$Metric.Value -like '*seconds*') { 'seconds' } else { '%' }
                            aggregation = 'avg'
                        }
                        $Dashboard.panels = @($Panels)
                    }
                }
            }
            'Save'
            {
                $Dashboard.panels = @($Panels)
                $Saved = Save-WtDashboardInternal -Dashboard $Dashboard
                if ($Saved.Ok)
                {
                    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mon.Edit.Title') -Lines @((Get-WtString -Key 'Mon.Edit.Saved') -f $Saved.Target) -Tone 'Success'
                }
                else
                {
                    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mon.Edit.Title') -Lines @($Saved.Errors) -Tone 'Error'
                }
            }
            'Duplicate'
            {
                $Path = Read-WtTuiText -State $State -Title (Get-WtString -Key 'Mon.Edit.Duplicate') -Label (Get-WtString -Key 'Mon.Edit.NewId') -Initial "$($Dashboard.dashboardId)-copy"
                if ($Path)
                {
                    $NewId = ([string]$Path).Trim()
                    $Copy = Copy-WtDashboardInternal -Dashboard $Dashboard -NewId $NewId
                    if ($Copy.Ok)
                    {
                        $Monitor.DashboardId = $NewId
                    }
                    else
                    {
                        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mon.Edit.Title') -Lines @($Copy.Errors) -Tone 'Error'
                    }
                }
            }
            'Reset'
            {
                if (Confirm-WtTui -State $State -Title (Get-WtString -Key 'Mon.Edit.Reset') -Lines @((Get-WtString -Key 'Mon.Edit.ResetConfirm' -Arguments @($Dashboard.dashboardId))) -Tone 'Warning')
                {
                    # Remove the stored copy, if any; the built-in template remains available.
                    Remove-WtDashboardInternal -Id ([string]$Dashboard.dashboardId) | Out-Null
                    $Dashboard = Read-WtDashboardInternal -Id $Monitor.DashboardId
                    if (-not $Dashboard) { return }
                }
            }
        }
    }
}


<#
.SYNOPSIS
    Session/interval comparison workflow (C).
.DESCRIPTION
    Select baseline and comparison intervals, review metadata, then compare supported
    metrics and optionally export results.
#>
function Show-WtMonitorComparison
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][hashtable]$Monitor
    )

    $Now = [int64]([datetime]::UtcNow.ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,[datetimekind]::Utc)).TotalMilliseconds

    # Baseline interval picker.
    $Ranges = @(
        @{ Label = 'last 1m'; Payload = @{ From = $Now - 60000; To = $Now }; Filter = '1m'; Disabled = $false; Checked = $false }
        @{ Label = 'last 5m'; Payload = @{ From = $Now - 300000; To = $Now }; Filter = '5m'; Disabled = $false; Checked = $false }
        @{ Label = 'last 15m'; Payload = @{ From = $Now - 900000; To = $Now }; Filter = '15m'; Disabled = $false; Checked = $false }
    )
    $BaselinePick = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Mon.Compare.Baseline') -Items $Ranges -EmptyText (Get-WtString -Key 'Tui.NoItems')
    if (-not $BaselinePick -or -not $BaselinePick.Value) { return }

    $ComparisonPick = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Mon.Compare.Comparison') -Items $Ranges -EmptyText (Get-WtString -Key 'Tui.NoItems')
    if (-not $ComparisonPick -or -not $ComparisonPick.Value) { return }

    $BaselineFrom = [long]$BaselinePick.Value.From
    $BaselineTo = [long]$BaselinePick.Value.To
    $ComparisonFrom = [long]$ComparisonPick.Value.From
    $ComparisonTo = [long]$ComparisonPick.Value.To

    # Metadata review.
    $Env = Get-WtEnvironment
    $MetaLines = @(
        (Get-WtString -Key 'Mon.Compare.Meta.Env') + ": $($Env.OSName) / $($Env.OSVersionKey) build $($Env.OSBuild)",
        (Get-WtString -Key 'Mon.Compare.Meta.Arch') + ": $($Env.Architecture)",
        (Get-WtString -Key 'Mon.Compare.Meta.Baseline') + ": $([DateTimeOffset]::FromUnixTimeMilliseconds($BaselineFrom).LocalDateTime.ToString('u')) → $([DateTimeOffset]::FromUnixTimeMilliseconds($BaselineTo).LocalDateTime.ToString('u'))",
        (Get-WtString -Key 'Mon.Compare.Meta.Comparison') + ": $([DateTimeOffset]::FromUnixTimeMilliseconds($ComparisonFrom).LocalDateTime.ToString('u')) → $([DateTimeOffset]::FromUnixTimeMilliseconds($ComparisonTo).LocalDateTime.ToString('u'))",
        (Get-WtString -Key 'Mon.Compare.Meta.Note')
    )

    if (Confirm-WtTui -State $State -Title (Get-WtString -Key 'Mon.Compare.Title') -Lines $MetaLines -Tone 'Default')
    {
        $Result = Compare-WtMonitorIntervals -Monitor $Monitor -BaselineFromMs $BaselineFrom -BaselineToMs $BaselineTo -ComparisonFromMs $ComparisonFrom -ComparisonToMs $ComparisonTo

        $Lines = @(
            (Get-WtString -Key 'Mon.Compare.Title'),
            $Result.Note
        )
        foreach ($Row in $Result.Rows)
        {
            $Verdict = Get-WtString -Key "Mon.Compare.Verdict.$($Row.Verdict)"
            $Coverage = "$($Row.Baseline.ValidCount)/$($Row.Baseline.SampleCount) vs $($Row.Comparison.ValidCount)/$($Row.Comparison.SampleCount)"
            $Lines += "  $($Row.Metric): $Verdict  [$Coverage]  $($Row.Reason)"
        }

        # Export option.
        $ExportAction = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Mon.Compare.Title') -Items @(
            @{ Label = (Get-WtString -Key 'Mon.Compare.Export'); Payload = 'export'; Filter = 'export'; Disabled = $false; Checked = $false }
            @{ Label = (Get-WtString -Key 'Common.Close'); Payload = 'close'; Filter = 'close'; Disabled = $false; Checked = $false }
        ) -EmptyText (Get-WtString -Key 'Tui.NoItems')

        if ($ExportAction -and $ExportAction.Value -eq 'export')
        {
            $Path = Read-WtTuiText -State $State -Title (Get-WtString -Key 'Mon.Compare.Export') -Label (Get-WtString -Key 'Mon.Compare.ExportPath') -Initial (Join-Path ([System.IO.Path]::GetTempPath()) 'interval-comparison.json')
            if ($Path)
            {
                $Payload = [ordered]@{
                    baseline = @{ fromMs = $BaselineFrom; toMs = $BaselineTo }
                    comparison = @{ fromMs = $ComparisonFrom; toMs = $ComparisonTo }
                    rows = @($Result.Rows)
                }
                Write-WtTextFile -Path $Path -Value (ConvertTo-WtJson -InputObject $Payload -Depth 8)
                Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mon.Compare.Title') -Lines @((Get-WtString -Key 'Mon.Compare.Exported') -f $Path) -Tone 'Success'
            }
        }
        else
        {
            Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mon.Compare.Title') -Lines $Lines -Tone 'Default'
        }
    }
}


<#
.SYNOPSIS
    Fleet view: multi-host overview from explicitly configured Prometheus data sources.
#>
function Show-WtMonitorFleet
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][hashtable]$Monitor
    )

    if (-not $Monitor.Fleet) { $Monitor.Fleet = New-WtFleetState }

    # Add a data source (explicit endpoint).
    if ($Monitor.Fleet.Sources.Count -eq 0)
    {
        $Endpoint = Read-WtTuiText -State $State -Title (Get-WtString -Key 'Mon.Fleet.Title') `
            -Label (Get-WtString -Key 'Mon.Fleet.Endpoint') -Initial 'http://127.0.0.1:9090'
        if (-not $Endpoint) { return }
        try { Register-WtFleetSource -Fleet $Monitor.Fleet -Endpoint $Endpoint }
        catch { Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mon.Fleet.Title') -Lines @($_.Exception.Message) -Tone 'Error'; return }
    }

    Update-WtFleet -Fleet $Monitor.Fleet -Force

    $Rows = Get-WtFleetRows -Fleet $Monitor.Fleet
    $Items = @()
    foreach ($Row in $Rows)
    {
        $ConditionText = Get-WtString -Key "Mon.Fleet.Condition.$($Row.Condition)"
        $Fresh = if ($Row.FreshnessMs) { [DateTimeOffset]::FromUnixTimeMilliseconds($Row.FreshnessMs).LocalDateTime.ToString('HH:mm:ss') } else { '-' }
        $Items += @{
            Label = $Row.Display
            Right = "$ConditionText | $Fresh"
            Payload = @{ Action = 'Details'; Row = $Row }
            Filter = "$($Row.Display) $($Row.Condition) $($Row.Instance)"
            Disabled = $false
            Checked = $false
        }
    }

    $Lines = @(
        (Get-WtString -Key 'Mon.Fleet.Title'),
        (Get-WtString -Key 'Mon.Fleet.Limits')
    )
    foreach ($Err in $Monitor.Fleet.Errors) { $Lines += "  ! $Err" }

    $Result = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Mon.Fleet.Title') -Lines $Lines `
        -Items $Items -Searchable -DetailsHeight 4 -EmptyText (Get-WtString -Key 'Mon.Fleet.Empty')

    if ($Result -and $Result.Value -and $Result.Value.Action -eq 'Details')
    {
        $Row = $Result.Value.Row
        $DetailLines = @(
            (Get-WtString -Key 'Mon.Fleet.Host') + ": $($Row.Display)",
            (Get-WtString -Key 'Mon.Fleet.Source') + ": $($Row.SourceAlias)",
            (Get-WtString -Key 'Mon.Fleet.Instance') + ": $($Row.Instance)",
            (Get-WtString -Key 'Mon.Fleet.Condition') + ": $(Get-WtString -Key "Mon.Fleet.Condition.$($Row.Condition)")"
        )
        foreach ($Key in $Row.Metrics.Keys)
        {
            $DetailLines += "  $Key = $($Row.Metrics[$Key])"
        }
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mon.Fleet.Host') -Lines $DetailLines -Tone 'Default'
    }
}

<#
.SYNOPSIS
    Incident workspace: unified timeline from alerts, metrics, operations, drift.
#>
function Show-WtMonitorIncident
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][hashtable]$Monitor
    )

    $Incident = $Monitor.Incident
    if (-not $Incident)
    {
        $Incident = New-WtIncident -Title 'Local incident'
        $Incident.FromMs = [long]$Monitor.LastFastMs - 3600000
        $Incident.ToMs = [long]$Monitor.LastFastMs
        $Monitor.Incident = $Incident
    }

    Invoke-WtIncidentCollect -Incident $Incident -Monitor $Monitor -AlertState $Monitor.AlertState

    $Items = @()
    foreach ($IncidentEvent in @($Incident.Events | Sort-Object AtMs))
    {
        $Time = [DateTimeOffset]::FromUnixTimeMilliseconds($IncidentEvent.AtMs).LocalDateTime.ToString('HH:mm:ss')
        $Uncertain = if ($IncidentEvent.ClockUncertain) { ' ±' } else { '' }
        $Items += @{
            Label = "$Time$Uncertain [$($IncidentEvent.Kind)] $($IncidentEvent.Type)"
            Right = $IncidentEvent.Source
            Payload = $IncidentEvent
            Filter = "$($IncidentEvent.Source) $($IncidentEvent.Type) $($IncidentEvent.Text)"
            Disabled = $false
            Checked = $false
        }
    }

    $Lines = @(
        (Get-WtString -Key 'Mon.Incident.Title'),
        (Get-WtString -Key 'Mon.Incident.Range') + ": $([DateTimeOffset]::FromUnixTimeMilliseconds($Incident.FromMs).LocalDateTime.ToString('u')) → $([DateTimeOffset]::FromUnixTimeMilliseconds($Incident.ToMs).LocalDateTime.ToString('u'))",
        (Get-WtString -Key 'Mon.Incident.Kinds')
    )
    foreach ($Note in $Incident.Notes) { $Lines += "  [note] $($Note.Text)" }

    $Result = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Mon.Incident.Title') -Lines $Lines `
        -Items $Items -Searchable -DetailsHeight 5 -EmptyText (Get-WtString -Key 'Mon.Incident.Empty')

    if ($Result -and $Result.Value)
    {
        $IncidentEvent = $Result.Value
        $Lines = @(
            (Get-WtString -Key 'Mon.Incident.Event') + ": $($IncidentEvent.Type)",
            (Get-WtString -Key 'Mon.Incident.Source') + ": $($IncidentEvent.Source)",
            (Get-WtString -Key 'Mon.Incident.Kind') + ": $($IncidentEvent.Kind)",
            $IncidentEvent.Text
        )
        if ($IncidentEvent.Payload) { $Lines += (Get-WtString -Key 'Mon.Incident.Payload') + ": " + ($IncidentEvent.Payload | ConvertTo-Json -Compress) }
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mon.Incident.Title') -Lines $Lines -Tone 'Default'
    }
}

<#
.SYNOPSIS
    Playbook runner: pick a playbook, run read-only checks, show evidence/limitations.
#>
function Show-WtMonitorPlaybook
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][hashtable]$Monitor
    )

    $Playbooks = Get-WtBuiltinPlaybooks
    $Items = @()
    foreach ($Pb in $Playbooks)
    {
        $Items += @{
            Label = (Get-WtText -Value $Pb.title)
            Right = "rev $($Pb.revision)"
            Payload = $Pb
            Filter = "$($Pb.id) $(Get-WtText -Value $Pb.title)"
            Disabled = $false
            Checked = $false
        }
    }

    $Pick = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Mon.Playbook.Title') -Items $Items -Searchable -EmptyText (Get-WtString -Key 'Tui.NoItems')
    if (-not $Pick -or -not $Pick.Value) { return }

    $Pb = $Pick.Value
    if (Confirm-WtTui -State $State -Title (Get-WtString -Key 'Mon.Playbook.Title') `
            -Lines @((Get-WtString -Key 'Mon.Playbook.RunConfirm' -Arguments @((Get-WtText -Value $Pb.title))), (Get-WtString -Key 'Mon.Playbook.ReadOnly')) -Tone 'Default')
    {
        $Result = Invoke-WtPlaybook -Id $Pb.id -Monitor $Monitor
        $Lines = @(
            (Get-WtString -Key 'Mon.Playbook.Title') + ": $(Get-WtText -Value $Result.Title) (rev $($Result.Revision))",
            (Get-WtString -Key 'Mon.Playbook.Outcome') + ": $($Result.Outcome)"
        )
        foreach ($E in $Result.Evidence)
        {
            $Avail = if ($E.Available) { 'ok' } else { 'missing' }
            $Lines += "  [$avail] $($E.Probe) $($E.Metric): $($E.Reason)"
        }
        foreach ($B in $Result.Branches) { $Lines += "  branch $($B.When): $($B.Note)" }
        $Lines += (Get-WtString -Key 'Mon.Playbook.Limitations') + ": $($Result.Limitations)"
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mon.Playbook.Title') -Lines $Lines -Tone 'Default'
    }
}

<#
.SYNOPSIS
    Support bundle preview-and-export workflow.
#>
function Show-WtMonitorBundle
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][hashtable]$Monitor
    )

    $Options = @{
        includeJournal = $true
        includeAlerts = $true
        includeMetrics = $true
        interval = @{ fromMs = [long]$Monitor.LastFastMs - 3600000; toMs = [long]$Monitor.LastFastMs }
        dashboards = @('overview', 'network', 'changes')
        rules = $true
        playbooks = $true
    }

    $JournalText = (Get-WtJournalEntryInternal -Limit 20 | ConvertTo-Json -Compress)
    if (-not $JournalText) { $JournalText = '{}' }
    $RedactionPreview = Get-WtBundleRedactionPreview -Text $JournalText
    $Lines = @(
        (Get-WtString -Key 'Mon.Bundle.Title'),
        (Get-WtString -Key 'Mon.Bundle.Exclusions'),
        (Get-WtString -Key 'Mon.Bundle.Redaction')
    )
    foreach ($S in $RedactionPreview)
    {
        $Lines += "  - $($S.Pattern) → sample: $($S.Sample)"
    }

    if (Confirm-WtTui -State $State -Title (Get-WtString -Key 'Mon.Bundle.Title') -Lines $Lines -Tone 'Warning')
    {
        $Path = Read-WtTuiText -State $State -Title (Get-WtString -Key 'Mon.Bundle.Title') `
            -Label (Get-WtString -Key 'Mon.Bundle.PathLabel') `
            -Initial (Join-Path ([System.IO.Path]::GetTempPath()) ("wt-support-{0}.zip" -f (Get-Date).ToString('yyyyMMdd-HHmmss')))
        if ($Path)
        {
            try
            {
                $Bundle = Export-WtSupportBundle -Options $Options -Path $Path -Monitor $Monitor
                Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mon.Bundle.Title') `
                    -Lines @((Get-WtString -Key 'Mon.Bundle.Exported' -Arguments @($Bundle.Bundle, $Bundle.Entries, $Bundle.TotalBytes))) -Tone 'Success'
            }
            catch
            {
                Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mon.Bundle.Title') -Lines @($_.Exception.Message) -Tone 'Error'
            }
        }
    }
}

function Show-WtTuiMonitor
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Monitor = New-WtMonitorSession
    $Monitor = Start-WtMonitorSession -Monitor $Monitor

    $State.Monitor = $Monitor

    $State.Screen.Dirty = $true

    try
    {
        while ($true)
        {
            Update-WtMonitorWorkspace -Monitor $Monitor

            $Key = Invoke-WtTuiFrame -State $State
            if ($null -eq $Key)
            {
                if ($State.Exit)
                {
                    break
                }
                continue
            }

            $Batch = 0
            $Escaped = $false
            while ($Key -and $Batch -lt 16 -and -not $State.Exit -and -not $Escaped)
            {
                switch ($Key.Name)
                {
                'Escape'
                {
                    $Escaped = $true
                }
                'Left'
                {
                    $Dashboards = Get-WtDashboardIdsInternal
                    $Index = [array]::IndexOf($Dashboards, $Monitor.DashboardId)
                    $Monitor.DashboardId = $Dashboards[($Index + $Dashboards.Count - 1) % $Dashboards.Count]
                    $Monitor.PanelIndex = 0
                }
                'Right'
                {
                    $Dashboards = Get-WtDashboardIdsInternal
                    $Index = [array]::IndexOf($Dashboards, $Monitor.DashboardId)
                    $Monitor.DashboardId = $Dashboards[($Index + 1) % $Dashboards.Count]
                    $Monitor.PanelIndex = 0
                }
                'Up'
                {
                    if ($Monitor.PanelIndex -gt 0) { $Monitor.PanelIndex-- }
                }
                'Down'
                {
                    $Monitor.PanelIndex++
                }
                'Enter'
                {
                    Show-WtMonitorInspector -State $State -Monitor $Monitor
                }
                'Char'
                {
                    $Character = ([string]$Key.Char).ToLowerInvariant()
                    switch ($Character)
                    {
                        '1' { Show-WtMonitorFleet -State $State -Monitor $Monitor }
                        '2' { Show-WtMonitorIncident -State $State -Monitor $Monitor }
                        '3' { Show-WtMonitorPlaybook -State $State -Monitor $Monitor }
                        '4' { Show-WtMonitorBundle -State $State -Monitor $Monitor }
                        'f' { $Monitor.Frozen = -not $Monitor.Frozen }
                        'p'
                        {
                            $Monitor.Paused = -not $Monitor.Paused
                            if ($Monitor.Paused)
                            {
                                Stop-WtMonitorSession -Monitor $Monitor
                            }
                            else
                            {
                                $Monitor = Start-WtMonitorSession -Monitor $Monitor
                                $State.Monitor = $Monitor
                            }
                        }
                        'a'
                        {
                            Show-WtMonitorAlerts -State $State -Monitor $Monitor
                        }
                        'o'
                        {
                            $Path = Read-WtTuiText -State $State -Title (Get-WtString -Key 'Mon.Prom.Title') -Label (Get-WtString -Key 'Mon.Prom.Endpoint') -Initial 'http://127.0.0.1:9090'
                            if ($Path)
                            {
                                $Source = New-WtPromDataSource -Endpoint $Path
                                $Conn = Test-WtPromConnection -Source $Source
                                if ($Conn.Ok)
                                {
                                    $Source.Enabled = $true
                                    $Monitor.PromSource = $Source
                                    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mon.Prom.Title') -Lines @((Get-WtString -Key 'Mon.Prom.Connected')) -Tone 'Success'
                                }
                                else
                                {
                                    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mon.Prom.Title') -Lines @((Get-WtString -Key 'Mon.Prom.Failed') -f $Conn.Reason) -Tone 'Error'
                                }
                            }
                        }
                        'c'
                        {
                            Show-WtMonitorComparison -State $State -Monitor $Monitor
                        }
                        'e'
                        {
                            Show-WtMonitorDashboardEditor -State $State -Monitor $Monitor
                        }
                        'r'
                        {
                            $Monitor.Persistence.Enabled = -not $Monitor.Persistence.Enabled
                            if ($Monitor.Persistence.Enabled)
                            {
                                $Probe = Test-WtMetricPersistenceInternal -Persistence $Monitor.Persistence
                                if (-not $Probe.Ok)
                                {
                                    $Monitor.Persistence.Enabled = $false
                                    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mon.Persist.Title') -Lines @($Probe.Reason) -Tone 'Error'
                                }
                                else
                                {
                                    Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mon.Persist.Title') -Lines @(
                                        (Get-WtString -Key 'Mon.Persist.Enabled' -Arguments @($Monitor.Persistence.Path)),
                                        (Get-WtString -Key 'Mon.Persist.Retention' -Arguments @($Monitor.Persistence.Limits.RetentionDays))) -Tone 'Success'
                                }
                            }
                            else
                            {
                                Stop-WtMetricPersistenceInternal -Persistence $Monitor.Persistence
                            }
                        }
                        't'
                        {
                            switch ($Monitor.Seconds)
                            {
                                60 { $Monitor.Seconds = 300 }
                                300 { $Monitor.Seconds = 900 }
                                900 { $Monitor.Seconds = 3600 }
                                default { $Monitor.Seconds = 60 }
                            }
                        }
                        '?' { Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Mon.Title') -Lines @(
                                (Get-WtString -Key 'Mon.Hint'),
                                (Get-WtString -Key 'Mon.Persist.Hint'),
                                (Get-WtString -Key 'Mon.Compare.Hint'),
                                (Get-WtString -Key 'Mon.Edit.Hint'),
                                (Get-WtString -Key 'Mon.Prom.Hint'),
                                (Get-WtString -Key 'Mon.Fleet.Hint'),
                                (Get-WtString -Key 'Mon.Incident.Hint'),
                                (Get-WtString -Key 'Mon.Playbook.Hint'),
                                (Get-WtString -Key 'Mon.Bundle.Hint'),
                                'F freeze/resume | P pause collection | T time range | Enter inspect | Esc close') }
                    }
                }
            }

            if ($Key.Name -eq 'Escape') { $Escaped = $true }

                $Batch++
                if ($State.Overlay -or $State.Operation -or $State.Exit) { break }
                $Key = Read-WtConsoleKey -TimeoutMs 0
            }

            if ($Escaped -or $State.Exit) { break }
        }
    }
    finally
    {
        Stop-WtMonitorSession -Monitor $Monitor
        $State.Monitor = $null
        $State.Screen.Dirty = $true
    }
}
