# WindowsTweaker - dashboard configuration (versioned JSON schema, local import/export).
#
# Dashboards are data with a hard allowlist: panel types, metric references, operators,
# aggregations and units. Nothing in a dashboard document is executed. Validation enforces
# size, unknown fields, duplicate ids, unsupported versions and bounded resource requests.

$Script:WtDashboardSchemaVersion = 2
$Script:WtDashboardPanelTypes = @('sparkline', 'stat', 'list', 'table')
$Script:WtDashboardMetrics = @(
    'host.cpu.utilization'
    'host.mem.physical.totalBytes'
    'host.mem.physical.availableBytes'
    'host.mem.physical.usedBytes'
    'host.disk.system.freeBytes'
    'host.disk.system.totalBytes'
    'host.net.link.state'
    'host.net.rxBytes'
    'host.net.txBytes'
    'host.net.links'
    'host.uptime.seconds'
    'ops.verification.failed'
    'ops.interrupted'
    'ops.drift'
)
$Script:WtDashboardAggregations = @('raw', 'avg', 'min', 'max', 'sum', 'last')

function Test-WtDashboardDocument {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ([Parameter(Mandatory = $true)][object]$Document)

    if ($Document -isnot [System.Collections.IDictionary]) {
        $Table = @{}
        foreach ($Prop in $Document.PSObject.Properties) { $Table[$Prop.Name] = $Prop.Value }
        $Document = $Table
    }

    $Errors = [System.Collections.Generic.List[string]]::new()
    $DocSchema = [int]$Document['schemaVersion']
    if ($DocSchema -lt 1 -or $DocSchema -gt $Script:WtDashboardSchemaVersion) {
        $Errors.Add("Unsupported dashboard schema version: $($Document['schemaVersion']).")
    }
    if ([string]::IsNullOrWhiteSpace([string]$Document['dashboardId'])) { $Errors.Add('dashboardId is required.') }

    $Panels = @($Document['panels'])
    if ($Panels.Count -eq 0) { $Errors.Add('A dashboard needs at least one panel.') }
    if ($Panels.Count -gt 12) { $Errors.Add('A dashboard may have at most 12 panels.') }

    $Seen = @{}
    foreach ($Panel in $Panels) {
        if ($Panel -isnot [System.Collections.IDictionary]) {
            $Table = @{}
            foreach ($Prop in $Panel.PSObject.Properties) { $Table[$Prop.Name] = $Prop.Value }
            $Panel = $Table
        }
        $Id = [string]$Panel['id']
        if (-not $Id) { $Errors.Add('a panel is missing an id.'); continue }
        if ($Seen.ContainsKey($Id)) { $Errors.Add("duplicate panel id '$Id'.") }
        $Seen[$Id] = $true

        $Type = [string]$Panel['type']
        if ($Script:WtDashboardPanelTypes -notcontains $Type) { $Errors.Add("panel '$Id' type '$Type' is not allowed.") }

        $Metric = [string]$Panel['metric']
        if ($Metric -and $Script:WtDashboardMetrics -notcontains $Metric) { $Errors.Add("panel '$Id' metric '$Metric' is not on the allowlist.") }

        if ($Panel.Contains('aggregation')) {
            $Agg = [string]$Panel['aggregation']
            if ($Script:WtDashboardAggregations -notcontains $Agg) { $Errors.Add("panel '$Id' aggregation '$Agg' is not allowed.") }
        }

        if ($Panel.Contains('dims')) {
            if ($Panel['dims'] -isnot [System.Collections.IDictionary]) { $Errors.Add("panel '$Id' dims must be an object.") }
            elseif ($Panel['dims'].Count -gt 4) { $Errors.Add("panel '$Id' dims exceeds 4 entries.") }
        }

        if ($Panel.Contains('threshold')) {
            $T = $Panel['threshold']
            if ($T -isnot [double] -and $T -isnot [int] -and $T -isnot [long]) { $Errors.Add("panel '$Id' threshold must be numeric.") }
        }

        if ($Panel.Contains('size')) {
            $Size = [string]$Panel['size']
            if ($Size -notin 'small', 'medium', 'large') { $Errors.Add("panel '$Id' size '$Size' is not allowed (small|medium|large).") }
        }

        $AllowedPanelKeys = 'id', 'type', 'metric', 'unit', 'aggregation', 'dims', 'threshold', 'title', 'size'
        foreach ($Key in $Panel.Keys) {
            if ($AllowedPanelKeys -notcontains $Key) { $Errors.Add("panel '$Id' has unknown field '$Key'.") }
        }
    }

    $Json = ConvertTo-WtJson -InputObject $Document -Depth 12 -Compress
    if ($Json.Length -gt 65536) { $Errors.Add('dashboard document exceeds 64 KiB.') }

    return @{ Valid = ($Errors.Count -eq 0); Errors = @($Errors.ToArray()) }
}

function Get-WtBuiltinDashboards {
    [CmdletBinding()]
    [OutputType([object[]])]
    param ()

    return @(
        [pscustomobject]@{
            schemaVersion = $Script:WtDashboardSchemaVersion
            dashboardId = 'overview'
            localizedTitle = @{ en = 'Overview'; vi = 'Tổng quan' }
            panels = @(
                @{ id = 'cpu'; type = 'sparkline'; metric = 'host.cpu.utilization'; unit = '%'; aggregation = 'avg' }
                @{ id = 'mem'; type = 'sparkline'; metric = 'host.mem.physical.usedBytes'; unit = 'bytes'; aggregation = 'avg' }
                @{ id = 'disk'; type = 'stat'; metric = 'host.disk.system.freeBytes'; unit = 'bytes' }
                @{ id = 'uptime'; type = 'stat'; metric = 'host.uptime.seconds'; unit = 'seconds' }
            )
        }
        [pscustomobject]@{
            schemaVersion = $Script:WtDashboardSchemaVersion
            dashboardId = 'network'
            localizedTitle = @{ en = 'Network'; vi = 'Mạng' }
            panels = @(
                @{ id = 'rx'; type = 'sparkline'; metric = 'host.net.rxBytes'; unit = 'bytes'; aggregation = 'avg'; dims = @{ adapter = '{selected}' } }
                @{ id = 'tx'; type = 'sparkline'; metric = 'host.net.txBytes'; unit = 'bytes'; aggregation = 'avg'; dims = @{ adapter = '{selected}' } }
                @{ id = 'link'; type = 'list'; metric = 'host.net.link.state' }
            )
        }
        [pscustomobject]@{
            schemaVersion = $Script:WtDashboardSchemaVersion
            dashboardId = 'changes'
            localizedTitle = @{ en = 'Changes'; vi = 'Thay đổi' }
            panels = @(
                @{ id = 'events'; type = 'list'; metric = 'ops.events' }
                @{ id = 'alerts'; type = 'list'; metric = 'ops.alerts' }
            )
        }
    )
}

function Import-WtDashboardInternal {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][switch]$Force
    )

    $Document = ConvertFrom-WtJson -Text (Read-WtTextFile -Path $Path) -Depth 12
    $Validation = Test-WtDashboardDocument -Document $Document
    if (-not $Validation.Valid) { return @{ Ok = $false; Errors = @($Validation.Errors) } }

    $Dir = Join-Path (Get-WtDataRoot) 'dashboards'
    New-WtDirectory -Path $Dir
    $Target = Join-Path $Dir ("$([string]$Document.dashboardId).json")
    if ((Test-Path -LiteralPath $Target) -and -not $Force) {
        return @{ Ok = $false; Errors = @("dashboard '$($Document.dashboardId)' already exists; use -Force") }
    }

    Copy-Item -LiteralPath $Path -Destination $Target -Force
    return @{ Ok = $true; Errors = @(); Target = $Target }
}

function Read-WtDashboardInternal {
    [CmdletBinding()]
    [OutputType([object])]
    param ([Parameter(Mandatory = $true)][string]$Id)

    $Dir = Join-Path (Get-WtDataRoot) 'dashboards'
    $Path = Join-Path $Dir "$Id.json"
    if (Test-Path -LiteralPath $Path) {
        try {
            $Document = ConvertFrom-WtJson -Text (Read-WtTextFile -Path $Path) -Depth 12
            $Validation = Test-WtDashboardDocument -Document $Document
            if ($Validation.Valid) { return $Document }
        }
        catch {
            Write-WtLog -Level Warning -Message "Stored dashboard could not be read: $Path ($($_.Exception.Message))" -NoConsole
        }
    }

    foreach ($Builtin in @(Get-WtBuiltinDashboards)) {
        if ($Builtin.dashboardId -eq $Id) { return $Builtin }
    }
    return $null
}

function Get-WtDashboardIdsInternal {
    [CmdletBinding()]
    [OutputType([string[]])]
    param ()

    $Ids = [System.Collections.Generic.List[string]]::new()
    foreach ($Builtin in @(Get-WtBuiltinDashboards)) { $Ids.Add([string]$Builtin.dashboardId) }

    $Dir = Join-Path (Get-WtDataRoot) 'dashboards'
    if (Test-Path -LiteralPath $Dir) {
        foreach ($File in @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File | Sort-Object -Property Name)) {
            $Base = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
            if ($Ids -notcontains $Base) { $Ids.Add($Base) }
        }
    }
    return @($Ids.ToArray())
}

function Save-WtDashboardInternal {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Dashboard)

    $Validation = Test-WtDashboardDocument -Document $Dashboard
    if (-not $Validation.Valid) { return @{ Ok = $false; Errors = @($Validation.Errors) } }

    $Dir = Join-Path (Get-WtDataRoot) 'dashboards'
    New-WtDirectory -Path $Dir
    $Target = Join-Path $Dir ("$([string]$Dashboard.dashboardId).json")
    Write-WtTextFile -Path $Target -Value (ConvertTo-WtJson -InputObject $Dashboard -Depth 12)
    return @{ Ok = $true; Errors = @(); Target = $Target }
}

function Remove-WtDashboardInternal {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Id)

    $Dir = Join-Path (Get-WtDataRoot) 'dashboards'
    $Path = Join-Path $Dir "$Id.json"
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    return @{ Ok = $true; Errors = @() }
}

function Copy-WtDashboardInternal {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][object]$Dashboard,
        [Parameter(Mandatory = $true)][string]$NewId
    )

    $Copy = @{
        schemaVersion = $Script:WtDashboardSchemaVersion
        dashboardId = $NewId
        localizedTitle = @{ en = "$($Dashboard.localizedTitle.en) (copy)"; vi = "$($Dashboard.localizedTitle.vi) (bản sao)" }
        panels = @($Dashboard.panels)
    }
    return (Save-WtDashboardInternal -Dashboard $Copy)
}

# ---------------------------------------------------------------------------
# Versioned monitoring configuration revisions (dashboards, alert rules, playbooks)
# ---------------------------------------------------------------------------
# Revisions are tracked per config kind as append-only snapshot files. Changing a
# threshold NEVER rewrites historical alert decisions; it only appends a new revision.
# Configuration rollback is distinct from restoring Windows settings. The local pack
# security model is retained: configuration cannot bypass provider permissions, execute
# scripts, or authorize remote mutations.

$Script:WtConfigRevisionsDirName = 'config-revisions'

function Get-WtConfigRevisionsDir {
    [CmdletBinding()]
    param ()
    $Dir = Join-Path (Get-WtDataRoot) $Script:WtConfigRevisionsDirName
    if (-not (Test-Path -LiteralPath $Dir)) { New-WtDirectory -Path $Dir }
    return $Dir
}

function Get-WtConfigRevisionPath {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][int]$Revision
    )
    $Dir = Join-Path (Get-WtConfigRevisionsDir) "$Kind-$Id"
    if (-not (Test-Path -LiteralPath $Dir)) { New-WtDirectory -Path $Dir }
    return (Join-Path $Dir "rev-$Revision.json")
}

function Get-WtConfigRevision {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][ValidateSet('dashboard', 'alertrule', 'playbook')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Id
    )
    $Dir = Join-Path (Get-WtConfigRevisionsDir) "$Kind-$Id"
    if (-not (Test-Path -LiteralPath $Dir)) { return 0 }
    $Files = @(Get-ChildItem -LiteralPath $Dir -Filter 'rev-*.json' -File)
    if ($Files.Count -eq 0) { return 0 }
    $Max = 0
    foreach ($F in $Files) {
        if ($F.BaseName -match '^rev-(\d+)$') { $N = [int]$Matches[1]; if ($N -gt $Max) { $Max = $N } }
    }
    return $Max
}

function Save-WtConfigRevision {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][ValidateSet('dashboard', 'alertrule', 'playbook')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][object]$Document
    )

    $Current = Get-WtConfigRevision -Kind $Kind -Id $Id
    $Json = ConvertTo-WtJson -InputObject $Document -Depth 12 -Compress

    if ($Current -gt 0) {
        $PrevPath = Get-WtConfigRevisionPath -Kind $Kind -Id $Id -Revision $Current
        if (Test-Path -LiteralPath $PrevPath) {
            $PrevJson = (ConvertFrom-WtJson -Text (Read-WtTextFile -Path $PrevPath)).content
            if ($PrevJson -eq $Json) { return $Current }
        }
    }

    $NewRevision = $Current + 1
    $Snapshot = [ordered]@{
        kind = $Kind
        id = $Id
        revision = $NewRevision
        content = $Json
        recordedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-WtTextFile -Path (Get-WtConfigRevisionPath -Kind $Kind -Id $Id -Revision $NewRevision) -Value (ConvertTo-WtJson -InputObject $Snapshot -Depth 12)
    return $NewRevision
}

function Get-WtConfigRevisions {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][ValidateSet('dashboard', 'alertrule', 'playbook')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Id
    )
    $Dir = Join-Path (Get-WtConfigRevisionsDir) "$Kind-$Id"
    if (-not (Test-Path -LiteralPath $Dir)) { return @() }
    $Revisions = @()
    foreach ($F in @(Get-ChildItem -LiteralPath $Dir -Filter 'rev-*.json' -File | Sort-Object Name)) {
        $Revisions += (ConvertFrom-WtJson -Text (Read-WtTextFile -Path $F.FullName))
    }
    return @($Revisions | Sort-Object revision -Descending)
}

function Restore-WtConfigRevision {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][ValidateSet('dashboard', 'alertrule', 'playbook')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][int]$Revision
    )

    $Path = Get-WtConfigRevisionPath -Kind $Kind -Id $Id -Revision $Revision
    if (-not (Test-Path -LiteralPath $Path)) { throw "Revision $Revision not found for $Kind/$Id." }
    $Doc = ConvertFrom-WtJson -Text (Read-WtTextFile -Path $Path)
    $Content = ConvertFrom-WtJson -Text $Doc.content

    switch ($Kind) {
        'dashboard' {
            $Validation = Test-WtDashboardDocument -Document $Content
            if (-not $Validation.Valid) { throw "Revision $Revision is invalid: $($Validation.Errors -join '; ')" }
            $null = Save-WtDashboardInternal -Dashboard $Content
        }
        'playbook' {
            $Validation = Test-WtPlaybookDocument -Document $Content
            if (-not $Validation.Valid) { throw "Revision $Revision is invalid: $($Validation.Errors -join '; ')" }
        }
        default { }
    }

    $null = Save-WtConfigRevision -Kind $Kind -Id $Id -Document $Content
    return [pscustomobject]@{
        Kind = $Kind
        Id = $Id
        Restored = $Revision
        WindowsSettingsChanged = $false
    }
}
