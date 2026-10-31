# Multi-host observation, incidents, playbooks and support bundles

Four read-only workflows inside the monitoring workspace. The workspace opens with `B`
from the main interface (`src/WindowsTweaker/Private/Tui/Tui.ps1:1614`) or the
Overview "Monitoring" row (`Tui.ps1:2010`); inside it keys `1`-`4` open the views
(`src/WindowsTweaker/Private/Tui/MonitorWorkspace.ps1:1134-1137`). Full key map:
[KEYBOARD.md](KEYBOARD.md) ("Monitoring workspace (B)").

They are terminal-interface workflows only: the entry point has no flag for them
(`WindowsTweaker.ps1:263-312`) and none of their functions is exported
(`src/WindowsTweaker/WindowsTweaker.psd1:11-105`). Nothing here changes a Windows setting,
authorizes a change on another host, or writes to the journal; the only file a view writes
is the support-bundle archive you name (incident saving exists as a function, see below,
but no key calls it). The local collector, dashboards, alert rules, interval comparison
and the optional Prometheus exporter are owned by [MONITORING.md](MONITORING.md).

## 1. Fleet view (key `1`)

Hosts come only from **explicitly configured** Prometheus data sources
(`src/WindowsTweaker/Private/Observability/Fleet.ps1:1-7`): nothing scans networks,
installs agents, enables remote management or collects credentials. With no source yet the
view asks for an endpoint and registers it (`MonitorWorkspace.ps1:846-852`); the source
gets id `ds<8 hex>` and an alias defaulting to the endpoint (`Fleet.ps1:42-56`) and lives
in session memory only, not persisted (`MonitorWorkspace.ps1:843`). Every entry forces a
refresh (`MonitorWorkspace.ps1:855`).

Discovery uses `label_values(up, instance)` (`Fleet.ps1:70`), taking the `instance` label
of every series, de-duplicated and capped (`Fleet.ps1:83`); per host one
`up{instance="..."}` query plus up to five best-effort node-exporter queries
(`Fleet.ps1:99`, `:131-146`). Each query covers the last 300 s at a 60 s step
(`src/WindowsTweaker/Private/Observability/PromData.ps1:68-71`, called with
`-StepSeconds 60`). Identity is `"<sourceId>|<instance>"` (`Fleet.ps1:186`): the same
hostname on two sources is two rows, never merged (`Fleet.ps1:8-9`; test
`tests/MultiHost.Tests.ps1:23`).

| Condition | Derivation | Where |
|---|---|---|
| `healthy` | source reachable, `up` == 1, sample fresh | `Fleet.ps1:120` |
| `failed-scrape` | source reachable, `up` < 0.5 (does not prove the host is off) | `Fleet.ps1:121` |
| `stale` | last `up` sample older than the staleness window | `Fleet.ps1:125` |
| `missing-target` | instance listed by discovery but no `up` sample | `Fleet.ps1:117` |
| `unreachable-ds` | the source's own query failed (timeout/HTTP error) | `Fleet.ps1:101` |
| `unknown` | declared in the header for "no usable observation" | `Fleet.ps1:17` (no code path produces it) |

Bounds: 8 sources (`Fleet.ps1:22`, throws above that at `:50`), 128 targets per source
(`:23`, `:83`), 120 s staleness (`:24`, `:125`), a 10 s cache that the forced refresh on
entry bypasses (`:26`, `MonitorWorkspace.ps1:855`), and per request a 5 s timeout, 256 KiB
response and 64 series with sanitized labels (`PromData.ps1:29-31`, `:88-92`, `:118`).

An unreachable source yields an error line above the table (`MonitorWorkspace.ps1:877`)
and no host rows, because the host map is rebuilt from scratch each refresh
(`Fleet.ps1:170-171`). Rows are filterable by display name or condition and sortable by
name/condition/freshness (`Fleet.ps1:207-240`); selecting one shows its metrics read-only
(`MonitorWorkspace.ps1:884-896`). Viewing a remote host never authorizes modifying it
(`Fleet.ps1:19`).

## 2. Incident workspace (key `2`)

An incident is one interval; the default is `FromMs = ToMs - 1 h` (`Incidents.ps1:24-27`)
and the view uses the hour ending at session start (`MonitorWorkspace.ps1:912-918`).
`Invoke-WtIncidentCollect` (`Incidents.ps1:73`) re-runs whenever the view opens
(`MonitorWorkspace.ps1:921`) and appends to one unified timeline:

| Collected from | Bound | Where |
|---|---|---|
| Journal operations (`observed`) | 200 newest in window | `Incidents.ps1:84-91` |
| Configuration drift (`observed`) | 100 | `Incidents.ps1:93-100` |
| Interrupted operations (`observed`) | 100 | `Incidents.ps1:102-109` |
| Collector errors (`observed`) | last 20 | `Incidents.ps1:111-117` |
| Alert rules, current `lastRecordedState` (`observed`) | all rules | `Incidents.ps1:119-130` |
| Up-time reset inside the window (`inferred`, flagged uncertain) | 2+ samples &gt; 1 h | `Incidents.ps1:131-144` |

Evidence kinds are a closed vocabulary - `observed`, `inferred`, `note`, `unavailable`
(`Incidents.ps1:50`). Clock uncertainty is a per-event flag (`Incidents.ps1:55`, `:66`);
the up-time event always sets it (`Incidents.ps1:141`) and the view renders flagged rows
with ` ±` (`MonitorWorkspace.ps1:927`). Missing data is not fabricated, and no temporal
proximity is elevated to causation (`Incidents.ps1:13-16`).

Notes are a separate list (`Add-WtIncidentNote`, `Incidents.ps1:148-160`): never merged
into the timeline, never rewriting journal records (test `tests/MultiHost.Tests.ps1:69`).
Collection appends without de-duplication (`Add-WtIncidentEvent`, `Incidents.ps1:46-70`),
so leaving and re-entering the view can add a second copy of an evidence row.

Save/reopen are module-internal, exercised by tests but not reachable from a key:
`Save-WtIncident` writes versioned JSON (`schemaVersion = 1`) to
`<data-root>/incidents/<id>.json` (`Incidents.ps1:163-190`), and `Read-WtIncident`
re-validates the schema before loading (`Incidents.ps1:193-212`). That JSON is also the
export artifact.

## 3. Diagnostic playbooks (key `3`)

A playbook is data (`src/WindowsTweaker/Private/Observability/Playbooks.ps1:1-10`): stable
id, revision, platforms, prerequisites, read-only checks, contextual branches, references,
limitations, completion note. `Test-WtPlaybookDocument` (`Playbooks.ps1:131-153`) enforces
the id shape, `revision >= 1`, `schemaVersion = 1`, at least one check, and - the important
part - that every check uses a probe **kind** from the allowlist with an allowlisted
metric. The format carries no script: only probe **kinds** run, so no document can execute
code (`Playbooks.ps1:1-10`).

| Probe kind | Reads | Where |
|---|---|---|
| `metric` | one allowlisted monitor metric, latest **valid** sample only | `Playbooks.ps1:164-172` |
| `journal` | count of recent journal entries | `Playbooks.ps1:173-176` |
| `drift` | count of drifted targets | `Playbooks.ps1:177-180` |
| `device` | device inventory rows (Windows provider) | `Playbooks.ps1:181-185` |
| `power` | active power plan name (Windows provider) | `Playbooks.ps1:186-190` |
| `collector-health` | age of the last fast collection cycle | `Playbooks.ps1:191-196` |
| `fleet` | placeholder, returns `0` | `Playbooks.ps1:197-199` |

Shipped playbooks (`Get-WtBuiltinPlaybooks`, `Playbooks.ps1:16-129`):

| id | rev | Checks |
|---|---|---|
| `network-slow-unstable` | 1 | `host.net.rxBytes`, `host.net.txBytes`, device, power |
| `disk-low-space` | 1 | `host.disk.system.freeBytes`, `host.disk.system.totalBytes`, journal |
| `high-resource-use` | 1 | `host.cpu.utilization`, `host.mem.physical.usedBytes`, device, collector-health |
| `tweak-verification-failed` | 1 | journal (failures), drift, device |
| `recovery-pending-or-failed` | 1 | journal (interrupted), drift, collector-health |

`Invoke-WtPlaybook` (`Playbooks.ps1:205`) records one evidence row per check and returns
`complete`, or `inconclusive` whenever any probe is unavailable (`Playbooks.ps1:242`);
branches come back as contextual notes only (`Playbooks.ps1:233-241`). The view confirms
before running and says the run is read-only (`MonitorWorkspace.ps1:993-995`), and a run
performs no mutation (test `tests/MultiHost.Tests.ps1:96`). There is no "fix all": anything
requiring a change returns to the normal preview/confirm/journal flow (`Playbooks.ps1:9-10`).
There is currently no import path for third-party playbooks - the validator exists, no key
or cmdlet feeds it external input.

## 4. Support bundles (key `4`)

Preview, then export (`src/WindowsTweaker/Private/Observability/SupportBundle.ps1:1-10`).
The view builds the option set (journal, alerts, metrics for the last hour, dashboards
`overview`/`network`/`changes`, alert rules, playbooks), shows the exclusion line and the
redaction preview of recent journal text, requires confirmation, then asks for a target
path (default `wt-support-<timestamp>.zip` in the temp directory) and exports
(`MonitorWorkspace.ps1:1024-1059`). An existing path is refused unless `-Force` is given
(`SupportBundle.ps1:176-178`).

| Entry | Content | Where |
|---|---|---|
| `metadata.json` | schema version, time, app/protocol version, OS description, PowerShell version, `isWindows` | `SupportBundle.ps1:81-87` |
| `operations-summary.json` | up to 100 journal rows: tweak id, state, outcome, timestamp, sequence | `SupportBundle.ps1:90-102` |
| `alerts-summary.json` | alert id, state, severity, threshold, value, missing flag | `SupportBundle.ps1:104-118` |
| `metrics-interval.json` | allowlisted local metrics, last 200 samples each (`tsMs`/quality/value) | `SupportBundle.ps1:120-134` |
| `dashboard-<id>.json` | the requested dashboard documents | `SupportBundle.ps1:136-142` |
| `alert-rules.json`, `playbooks.json` | shipped default rules / built-in playbooks | `SupportBundle.ps1:143-148` |
| `fleet-overview.json` | source alias, condition, freshness - only if a caller passes `-Fleet` | `SupportBundle.ps1:150-163` (the view does not) |
| `manifest.json` | schema version, time, per-file name/bytes/SHA-256, omitted count, note | `SupportBundle.ps1:201-208`, written at `:209` |

Default exclusions (declared `SupportBundle.ps1:8-10`, shown in the UI
`src/WindowsTweaker/Data/Strings.en.quarantine.psd1:171`): credentials/tokens, full product
keys, full environment dumps, recovery secrets and executable recovery material, browser
databases, file contents, full command lines, usernames, computer names, serial numbers,
private paths. The entries above are structured summaries, so those categories are never
collected; no free-form text or file body is read.

Redaction: `Clear-WtBundleText` (`SupportBundle.ps1:26-35`) strips ANSI/terminal control
sequences and applies five pattern families - secret assignments, product keys, user
assignments, IPv4 addresses, GUIDs (`SupportBundle.ps1:18-24`).
`Get-WtBundleRedactionPreview` (`SupportBundle.ps1:37-52`) reports which patterns matched
the journal excerpt and the view prints that list before export
(`MonitorWorkspace.ps1:1037-1046`); the helper is currently **not** applied to the
assembled entries, so the preview is advisory in this wiring. The manifest says so:
hashes verify contents, not origin, and redaction is best-effort (`SupportBundle.ps1:207`).

Bounds: at most 64 entries, 8 MiB total, 1 MiB per entry (longer content is truncated with
a `...[TRUNCATED]` marker); sections that do not fit are counted in `omittedSections`
(`SupportBundle.ps1:12-15`, `:68-77`, `:164`). `Import-WtSupportBundle`
(`SupportBundle.ps1:234-290`) treats a bundle as historical, untrusted, offline evidence:
entry names are normalized and absolute or `..` paths rejected, entry count and size
re-checked, nothing executed, every entry flagged `Historical = $true` (`:248-265`,
`:286-288`). Traversal rejection is covered by `tests/MultiHost.Tests.ps1:142`.

## Versioned monitoring configuration

Append-only snapshot files per kind, under
`<data-root>/config-revisions/<kind>-<id>/rev-<n>.json`
(`src/WindowsTweaker/Private/Observability/Dashboards.ps1:246-252`, `:254-271`); valid
kinds are `dashboard`, `alertrule`, `playbook` (`Dashboards.ps1:277`).
`Save-WtConfigRevision` appends the next revision and skips the write when the serialized
content equals the current revision (`Dashboards.ps1:291-320`). Changing a threshold never
rewrites historical alert decisions, it appends a revision (`Dashboards.ps1:246-248`).
Reverting is distinct from restoring Windows settings: `Restore-WtConfigRevision`
(`Dashboards.ps1:337-370`) re-validates the stored document before activating it -
`Test-WtDashboardDocument` (`:351-354`), `Test-WtPlaybookDocument` (`:356-359`) - and
returns `WindowsSettingsChanged = $false` (`:368`).

Current wiring, stated plainly: the revision store is an internal API with tests
(`tests/MultiHost.Tests.ps1:180`) but no workspace key and no exported cmdlet. Saving a
dashboard from the editor goes through `Save-WtDashboardInternal` to
`dashboards/<id>.json` (`Dashboards.ps1:203-215`) and does **not** append a revision; no
diff helper exists (snapshots hold the full document, so a diff can be computed by
comparing two revisions); the `alertrule` kind has no validator in the restore switch
(`Dashboards.ps1:360`). Alert-transition records carry a `revision` field currently sent
as the constant `1` (`src/WindowsTweaker/Private/Observability/Persistence.ps1:238`).

## Status

| Surface | Verified on Linux (Pester, `tests/MultiHost.Tests.ps1`) | Windows-only / not executed |
|---|---|---|
| Fleet identity, conditions, bounds | yes - identity key, no cross-source merge, `failed-scrape` vs availability (lines 23, 40) | target discovery (`label_values`) and per-host `up` queries were never run against a real Prometheus server ([LIMITATIONS.md](LIMITATIONS.md)) |
| Incident timeline, evidence kinds, clock uncertainty, notes, save/reopen | yes (lines 54, 69, 80) | remote journal events do not exist by design; cross-source clock alignment is best-effort |
| Playbook validation, read-only run | yes - validator rejects unknown probes and non-allowlisted metrics (line 108); a run writes no state (line 96) | `device`/`power` probes return unavailable off Windows (`src/WindowsTweaker/Private/Providers/Devices.ps1:80-88`, `Power.ps1:116-124`), forcing `inconclusive` |
| Support bundle export/import, redaction helper, traversal rejection | yes (lines 130, 142) | none specific |
| Config revisions (dashboard kind) | yes - append-only, no duplicate revision, revert without Windows changes (line 180) | `alertrule`/`playbook` kinds and any activation UI are not exercised; no UI path exists |
| Views `1`-`4` end-to-end | not exercised: the suite calls the functions above directly, not the key dispatch (`MonitorWorkspace.ps1:1134-1137`) | real multi-host runs and a live Grafana import need a disposable Windows VM |

Related: [KEYBOARD.md](KEYBOARD.md) (key map), [MONITORING.md](MONITORING.md) (collector,
dashboards, alerts, exporter), [LIMITATIONS.md](LIMITATIONS.md), [VALIDATION.md](VALIDATION.md),
[STATE-JOURNAL.md](STATE-JOURNAL.md) (journal, drift, data root).
