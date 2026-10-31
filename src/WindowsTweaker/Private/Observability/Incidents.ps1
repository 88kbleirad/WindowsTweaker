# WindowsTweaker - incident workspace.
#
# An incident is built around one alert (or a user-selected time interval). It collects
# evidence from local + remote sources into a single timeline:
#   - alert transitions (persisted when recording was enabled),
#   - relevant metrics and quality states (local history + optional stored data),
#   - operation/session events (the journal — immutable),
#   - configuration drift observations,
#   - collector failures,
#   - boot/restart indicators where reliably available (uptime resets).
#
# Evidence kinds are preserved: observed, inferred, note, unavailable. Clock uncertainty
# is reported when timestamps lack a proven source alignment. No temporal proximity is
# ever elevated to causation, and user annotations never rewrite journal records.

$Script:WtIncidentSchemaVersion = 1

function New-WtIncident {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)][string]$Id = '',
        [Parameter(Mandatory = $false)][string]$Title = '',
        [Parameter(Mandatory = $false)][long]$FromMs = 0,
        [Parameter(Mandatory = $false)][long]$ToMs = 0
    )

    if (-not $Id) { $Id = [guid]::NewGuid().ToString('n') }
    if (-not $ToMs) { $ToMs = [int64]([datetime]::UtcNow.ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,[datetimekind]::Utc)).TotalMilliseconds }
    if (-not $FromMs) { $FromMs = $ToMs - 3600000 }

    return @{
        SchemaVersion = $Script:WtIncidentSchemaVersion
        Id = $Id
        Title = $Title
        FromMs = $FromMs
        ToMs = $ToMs
        PinnedPanels = @()       # metric keys pinned to the incident
        Notes = [System.Collections.Generic.List[object]]::new()
        Events = [System.Collections.Generic.List[object]]::new()
        CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

# Adds one timeline event with an explicit evidence kind.
function Add-WtIncidentEvent {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][hashtable]$Incident,
        [Parameter(Mandatory = $true)][string]$Kind,          # observed | inferred | note | unavailable
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Type,          # alert | metric | operation | drift | collector | boot | note
        [Parameter(Mandatory = $true)][long]$AtMs,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $false)][bool]$ClockUncertain = $false,
        [Parameter(Mandatory = $false)][object]$Payload = $null
    )

    $Incident.Events.Add([pscustomobject]@{
        PSTypeName = 'WindowsTweaker.IncidentEvent'
        Kind = $Kind
        Source = $Source
        Type = $Type
        AtMs = $AtMs
        Text = $Text
        ClockUncertain = $ClockUncertain
        Payload = $Payload
    })
    $Incident.UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
}

# Collects local evidence into the incident (read-only; the journal is never modified).
function Invoke-WtIncidentCollect {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][hashtable]$Incident,
        [Parameter(Mandatory = $false)][object]$Monitor = $null,
        [Parameter(Mandatory = $false)][hashtable]$AlertState = $null
    )

    $From = [long]$Incident.FromMs
    $To = [long]$Incident.ToMs

    # 1. Operations from the journal (immutable evidence).
    try {
        foreach ($Entry in @(Get-WtJournalEntryInternal -All | Where-Object { $_.timestamp -and ([long]$_.timestamp -ge $From) -and ([long]$_.timestamp -le $To) } | Select-Object -First 200)) {
            Add-WtIncidentEvent -Incident $Incident -Kind observed -Source 'journal' -Type operation `
                -AtMs ([long]$Entry.timestamp) -Text "$($Entry.tweakId): $($Entry.state) [$($Entry.outcome)]" `
                -Payload @{ operationId = $Entry.operationId; sessionId = $Entry.sessionId; outcome = $Entry.outcome }
        }
    } catch { Write-WtLog -Level Debug -Message ('journal collect failed: {0}' -f $_.Exception.Message) -NoConsole }

    # 2. Drift (observed where recorded).
    try {
        foreach ($Row in @(Get-WtDriftInternal -OnlyDrifted | Where-Object { $_.AppliedUtc -and ([long]$_.AppliedUtc -ge $From) -and ([long]$_.AppliedUtc -le $To) } | Select-Object -First 100)) {
            Add-WtIncidentEvent -Incident $Incident -Kind observed -Source 'drift' -Type drift `
                -AtMs ([long]$Row.AppliedUtc) -Text "$($Row.TweakId) drifted: $($Row.Label) -> $($Row.LiveValue)" `
                -Payload @{ identity = $Row.Identity; status = $Row.Status }
        }
    } catch { Write-WtLog -Level Debug -Message ('journal collect failed: {0}' -f $_.Exception.Message) -NoConsole }

    # 3. Interrupted operations.
    try {
        foreach ($Row in @(Get-WtInterruptedOperationInternal | Where-Object { $_.StartedUtc -and ([long]$_.StartedUtc -ge $From) -and ([long]$_.StartedUtc -le $To) } | Select-Object -First 100)) {
            Add-WtIncidentEvent -Incident $Incident -Kind observed -Source 'journal' -Type operation `
                -AtMs ([long]$Row.StartedUtc) -Text "$($Row.TweakId): interrupted ($($Row.Stage))" `
                -Payload @{ operationId = $Row.OperationId }
        }
    } catch { Write-WtLog -Level Debug -Message ('journal collect failed: {0}' -f $_.Exception.Message) -NoConsole }

    # 4. Collector failures and health (observed when recorded).
    if ($Monitor -and $Monitor.ProviderErrors) {
        foreach ($Err in @($Monitor.ProviderErrors | Select-Object -Last 20)) {
            Add-WtIncidentEvent -Incident $Incident -Kind observed -Source 'collector' -Type collector `
                -AtMs $To -Text $Err
        }
    }

    # 5. Alert transitions (observed where recorded in the store; else from current state).
    if ($AlertState) {
        foreach ($RuleId in $AlertState.Keys) {
            $State = $AlertState[$RuleId]
            if ($State.lastRecordedState) {
                Add-WtIncidentEvent -Incident $Incident -Kind observed -Source 'alerts' -Type alert `
                    -AtMs $To -Text "${RuleId}: $($State.lastRecordedState)" `
                    -Payload @{ ruleId = $RuleId }
            }
        }
    }

    # 6. Boot/restart indicator: uptime series reset within the window (inferred when
    #    observed from local history).
    if ($Monitor) {
        $Uptime = Get-WtMetricSamples -History $Monitor.History -Key 'host.uptime.seconds' -FromMs $From -ToMs $To
        if ($Uptime.Samples.Count -ge 2) {
            $First = [double]$Uptime.Samples[0].value
            $Last = [double]$Uptime.Samples[$Uptime.Samples.Count-1].value
            if ($Last -lt $First -and $First -gt 3600) {
                Add-WtIncidentEvent -Incident $Incident -Kind inferred -Source 'metrics' -Type boot `
                    -AtMs $To -Text 'Uptime reset detected inside the window (possible restart).' `
                    -ClockUncertain $true
            }
        }
    }
}

# Adds a user note (explicitly a note; never touches the journal).
function Add-WtIncidentNote {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][hashtable]$Incident,
        [Parameter(Mandatory = $true)][string]$Text
    )
    $Incident.Notes.Add([pscustomobject]@{
        PSTypeName = 'WindowsTweaker.IncidentNote'
        Text = $Text
        AtUtc = (Get-Date).ToUniversalTime().ToString('o')
    })
    $Incident.UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
}

# Saves an incident to the local data directory (versioned).
function Save-WtIncident {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][hashtable]$Incident,
        [Parameter(Mandatory = $false)][string]$Path = ''
    )

    if (-not $Path) {
        $Dir = Join-Path (Get-WtDataRoot) 'incidents'
        New-WtDirectory -Path $Dir
        $Path = Join-Path $Dir "$($Incident.Id).json"
    }

    $Payload = [ordered]@{
        schemaVersion = $Incident.SchemaVersion
        id = $Incident.Id
        title = $Incident.Title
        fromMs = $Incident.FromMs
        toMs = $Incident.ToMs
        createdUtc = $Incident.CreatedUtc
        updatedUtc = $Incident.UpdatedUtc
        pinnedPanels = @($Incident.PinnedPanels)
        notes = @($Incident.Notes)
        events = @($Incident.Events)
    }
    $Payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
    return $Path
}

# Reopens a saved incident (validated; imported data is historical, never live).
function Read-WtIncident {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Path)

    $Doc = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 10
    if ([int]$Doc.schemaVersion -ne $Script:WtIncidentSchemaVersion) {
        throw "Unsupported incident schema version: $($Doc.schemaVersion)"
    }

    $Incident = New-WtIncident -Id $Doc.id -Title $Doc.title -FromMs ([long]$Doc.fromMs) -ToMs ([long]$Doc.toMs)
    foreach ($StoredEvent in @($Doc.events)) {
        Add-WtIncidentEvent -Incident $Incident -Kind $StoredEvent.kind -Source $StoredEvent.source -Type $StoredEvent.type `
            -AtMs ([long]$StoredEvent.atMs) -Text $StoredEvent.text -ClockUncertain ([bool]$StoredEvent.clockUncertain) -Payload $StoredEvent.payload
    }
    foreach ($Note in @($Doc.notes)) {
        $Incident.Notes.Add($Note)
    }
    $Incident.PinnedPanels = @($Doc.pinnedPanels)
    return $Incident
}
