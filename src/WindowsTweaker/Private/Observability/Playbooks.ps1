# WindowsTweaker - declarative diagnostic playbooks.
#
# A playbook is data: stable id + revision, supported platforms, prerequisites, read-only
# checks (allowlisted probes), expected evidence and limitations, branching conditions,
# official documentation references, and completion/inconclusive outcomes. Imported
# playbooks never execute embedded scripts: only probe *kinds* from the allowlist run,
# and every probe is a read-only function in this module.
#
# Diagnosis is separated from remediation: a playbook never proposes a system change;
# anything requiring a change returns to the existing preview/confirmation/journal flow.

$Script:WtPlaybookSchemaVersion = 1
$Script:WtPlaybookProbes = @('metric', 'journal', 'drift', 'device', 'power', 'fleet', 'collector-health')
$Script:WtPlaybookOutcomes = @('complete', 'inconclusive', 'error')

function Get-WtBuiltinPlaybooks {
    [CmdletBinding()]
    param ()
    return @(
        @{
            id = 'network-slow-unstable'
            revision = 1
            title = @{ en = 'Slow or unstable network'; vi = 'Mạng chậm hoặc không ổn định' }
            platforms = @('Windows10', 'Windows11', 'Linux')
            prerequisites = @()
            checks = @(
                @{ id = 'c1'; probe = 'metric'; metric = 'host.net.rxBytes'; note = 'Per-adapter receive counters (rate context).' }
                @{ id = 'c2'; probe = 'metric'; metric = 'host.net.txBytes'; note = 'Per-adapter transmit counters (rate context).' }
                @{ id = 'c3'; probe = 'device'; note = 'Network adapters and link state (read-only).' }
                @{ id = 'c4'; probe = 'power'; note = 'Active power plan (read-only); plans with aggressive power saving can stall NICs on some hardware.' }
            )
            branches = @(
                @{ id = 'b1'; when = 'link-down'; note = 'Adapter link state is down; check cabling/VLAN/switch, not the OS.' }
                @{ id = 'b2'; when = 'counters-flat'; note = 'Counters are unchanged while traffic was expected; possibly an adapter/VM reset, or traffic on another interface.' }
                @{ id = 'b3'; when = 'power-plan'; note = 'A power-saving plan is active; this is context, not a verdict.' }
            )
            references = @(
                @{ title = 'Windows networking troubleshooting (Microsoft Learn)'; url = 'https://learn.microsoft.com/en-us/windows/client-management/troubleshoot-tcpip' }
            )
            limitations = 'Coverage depends on the configured data source; a failed scrape does not prove the host is off.'
            completion = 'Read-only evidence collected; verdicts are contextual, not causal.'
        }
        @{
            id = 'disk-low-space'
            revision = 1
            title = @{ en = 'Low disk space'; vi = 'Dung lượng đĩa thấp' }
            platforms = @('Windows10', 'Windows11', 'Linux')
            prerequisites = @()
            checks = @(
                @{ id = 'c1'; probe = 'metric'; metric = 'host.disk.system.freeBytes'; note = 'System-volume free space.' }
                @{ id = 'c2'; probe = 'metric'; metric = 'host.disk.system.totalBytes'; note = 'System-volume total capacity.' }
                @{ id = 'c3'; probe = 'journal'; note = 'Recent operations (immutable).' }
            )
            branches = @(
                @{ id = 'b1'; when = 'free-low'; note = 'Free space is below the configured threshold; no deletion is proposed by this playbook.' }
            )
            references = @(
                @{ title = 'Disk cleanup guidance (Microsoft Learn)'; url = 'https://learn.microsoft.com/en-us/windows/win32/debug/disk-space' }
            )
            limitations = 'Occupancy is an observation; recovery/quarantine/cleanup remains an explicit, separate engine action.'
            completion = 'Evidence collected; verdict context only.'
        }
        @{
            id = 'high-resource-use'
            revision = 1
            title = @{ en = 'High sustained resource use'; vi = 'Sử dụng tài nguyên cao kéo dài' }
            platforms = @('Windows10', 'Windows11', 'Linux')
            prerequisites = @()
            checks = @(
                @{ id = 'c1'; probe = 'metric'; metric = 'host.cpu.utilization'; note = 'CPU utilization (time-windowed).' }
                @{ id = 'c2'; probe = 'metric'; metric = 'host.mem.physical.usedBytes'; note = 'Physical memory used.' }
                @{ id = 'c3'; probe = 'device'; note = 'Hardware inventory (read-only).' }
                @{ id = 'c4'; probe = 'collector-health'; note = 'Collector freshness: distinguish stale data from a real load.' }
            )
            branches = @(
                @{ id = 'b1'; when = 'cpu-sustained'; note = 'CPU utilization sustained above the configured threshold for the interval.' }
                @{ id = 'b2'; when = 'mem-sustained'; note = 'Physical memory used sustained at a high level.' }
                @{ id = 'b3'; when = 'no-peak'; note = 'No sustained load found; nothing is claimed as the cause.' }
            )
            references = @(
                @{ title = 'Performance counters overview (Microsoft Learn)'; url = 'https://learn.microsoft.com/en-us/windows/win32/perfctrs/performance-counters-portal' }
            )
            limitations = 'CPU/memory utilization is not automatically "bad"; context matters and no universal threshold is claimed.'
            completion = 'Evidence collected; verdicts are contextual.'
        }
        @{
            id = 'tweak-verification-failed'
            revision = 1
            title = @{ en = 'A tweak verification failure'; vi = 'Thất bại xác minh tinh chỉnh' }
            platforms = @('Windows10', 'Windows11')
            prerequisites = @()
            checks = @(
                @{ id = 'c1'; probe = 'journal'; note = 'Verification failures (outcome = failed/review-required).' }
                @{ id = 'c2'; probe = 'drift'; note = 'Drift between intended and live values.' }
                @{ id = 'c3'; probe = 'device'; note = 'Unreadable/missing device inventory rows (context).' }
            )
            branches = @(
                @{ id = 'b1'; when = 'drifted'; note = 'Live value differs from the applied value; re-review, never silent reapply.' }
                @{ id = 'b2'; when = 'managed'; note = 'A policy may override the value; check managed status in the tweak details.' }
            )
            references = @(
                @{ title = 'WindowsTweaker verification & recovery (docs/STATE-JOURNAL.md)'; url = 'https://github.com/' }
            )
            limitations = 'Verification reflects the last apply; it does not prove current behaviour without re-reading.'
            completion = 'Evidence collected; remediation always goes through the review flow.'
        }
        @{
            id = 'recovery-pending-or-failed'
            revision = 1
            title = @{ en = 'Pending or failed recovery operation'; vi = 'Thao tác khôi phục đang chờ hoặc thất bại' }
            platforms = @('Windows10', 'Windows11')
            prerequisites = @()
            checks = @(
                @{ id = 'c1'; probe = 'journal'; note = 'Interrupted operations and failed restores.' }
                @{ id = 'c2'; probe = 'drift'; note = 'Drift that may block a restore.' }
                @{ id = 'c3'; probe = 'collector-health'; note = 'Collector health (context).' }
            )
            branches = @(
                @{ id = 'b1'; when = 'interrupted'; note = 'Interrupted exists with captured records; restore is an explicit action.' }
                @{ id = 'b2'; when = 'missing-records'; note = 'Records missing; recovery is not promised.' }
            )
            references = @(
                @{ title = 'WindowsTweaker recovery (docs/STATE-JOURNAL.md)'; url = 'https://github.com/' }
            )
            limitations = 'Recovery never overwrites an external change without explicit confirmation.'
            completion = 'Evidence collected; recovery remains a separate user-confirmed action.'
        }
    )
}

function Test-WtPlaybookDocument {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Document)

    $Errors = [System.Collections.Generic.List[string]]::new()
    $Id = [string]$Document.id
    if ($Id -notmatch '^[a-z0-9][a-z0-9_-]*$') { $Errors.Add("invalid playbook id '$Id'.") }
    if ([int]$Document.revision -lt 1) { $Errors.Add('revision must be >= 1.') }
    if ([int]$Document.schemaVersion -ne $Script:WtPlaybookSchemaVersion) { $Errors.Add("unsupported schema version: $($Document.schemaVersion).") }
    if (@($Document.checks).Count -eq 0) { $Errors.Add('a playbook needs at least one check.') }

    foreach ($Check in @($Document.checks)) {
        $Probe = [string]$Check.probe
        if ($Script:WtPlaybookProbes -notcontains $Probe) {
            $Errors.Add("check '$( $Check.id)' uses unknown probe '$Probe'.")
        }
        if ($Check.metric -and $Script:WtDashboardMetrics -notcontains [string]$Check.metric) {
            $Errors.Add("check '$( $Check.id)' metric '$($Check.metric)' is not allowlisted.")
        }
    }

    return @{ Valid = ($Errors.Count -eq 0); Errors = @($Errors.ToArray()) }
}

# Runs one allowlisted probe (always read-only).
function Invoke-WtPlaybookProbe {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Probe,
        [Parameter(Mandatory = $false)][string]$Metric = '',
        [Parameter(Mandatory = $false)][object]$Monitor = $null
    )

    switch ($Probe) {
        'metric' {
            if (-not $Monitor) { return @{ Available = $false; Reason = 'no monitor session' } }
            $Sample = Get-WtMonitorLatestValue -Monitor $Monitor -Key $Metric
            if ($Sample -and $Sample.quality -eq 'valid') {
                return @{ Available = $true; Value = [double]$Sample.value; Quality = 'valid' }
            }
            return @{ Available = $false; Reason = "metric $Metric unavailable ($(if ($Sample) { $Sample.quality } else { 'no samples' }))" }
        }
        'journal' {
            try { return @{ Available = $true; Value = @(Get-WtJournalEntryInternal -Limit 50).Count; Reason = 'recent journal entries' } }
            catch { return @{ Available = $false; Reason = $_.Exception.Message } }
        }
        'drift' {
            try { return @{ Available = $true; Value = @(Get-WtDriftInternal -OnlyDrifted).Count; Reason = 'drifted targets' } }
            catch { return @{ Available = $false; Reason = $_.Exception.Message } }
        }
        'device' {
            $Inventory = Get-WtDeviceInventoryInternal
            if ($Inventory.Available) { return @{ Available = $true; Value = @($Inventory.Devices).Count; Reason = 'device rows' } }
            return @{ Available = $false; Reason = $Inventory.Reason }
        }
        'power' {
            $Power = Get-WtPowerSettingsInternal
            if ($Power.Available) { return @{ Available = $true; Value = $Power.ActivePlanName; Reason = 'active plan' } }
            return @{ Available = $false; Reason = $Power.Reason }
        }
        'collector-health' {
            if (-not $Monitor) { return @{ Available = $false; Reason = 'no monitor session' } }
            $NowMs = [int64]([datetime]::UtcNow.ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,[datetimekind]::Utc)).TotalMilliseconds
            $Age = ($NowMs - $Monitor.LastFastMs) / 1000.0
            return @{ Available = $true; Value = $Age; Reason = "collector age ${Age}s" }
        }
        'fleet' {
            return @{ Available = $true; Value = 0; Reason = 'fleet view (see Fleet)' }
        }
        default { return @{ Available = $false; Reason = "unknown probe $Probe" } }
    }
}

# Runs a playbook: executes allowlisted checks, gathers evidence, returns outcome.
function Invoke-WtPlaybook {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $false)][object]$Monitor = $null,
        [Parameter(Mandatory = $false)][hashtable]$Thresholds = @{}
    )

    $Playbook = @(Get-WtBuiltinPlaybooks | Where-Object { $_.id -eq $Id }) | Select-Object -First 1
    if (-not $Playbook) { throw "Playbook '$Id' not found." }

    $Evidence = [System.Collections.Generic.List[object]]::new()
    $Inconclusive = $false
    foreach ($Check in @($Playbook.checks)) {
        $Probe = Invoke-WtPlaybookProbe -Probe $Check.probe -Metric $Check.metric -Monitor $Monitor
        $Evidence.Add([pscustomobject]@{
            CheckId = [string]$Check.id
            Probe = [string]$Check.probe
            Metric = [string]$Check.metric
            Available = [bool]$Probe.Available
            Value = $Probe.Value
            Reason = [string]$Probe.Reason
            Note = [string]$Check.note
        })
        if (-not $Probe.Available) { $Inconclusive = $true }
    }

    # Branch matching is heuristic and explicitly contextual (never causal).
    $Branches = @()
    foreach ($Branch in @($Playbook.branches)) {
        $Branches += [pscustomobject]@{
            Id = [string]$Branch.id
            When = [string]$Branch.when
            Note = [string]$Branch.note
        }
    }

    $Outcome = if ($Inconclusive) { 'inconclusive' } else { 'complete' }
    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.PlaybookResult'
        Id = $Id
        Revision = [int]$Playbook.revision
        Title = $Playbook.title
        Outcome = $Outcome
        Evidence = @($Evidence.ToArray())
        Branches = $Branches
        References = @($Playbook.references)
        Limitations = [string]$Playbook.limitations
        Completion = [string]$Playbook.completion
    }
}
