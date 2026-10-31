# Monitoring workspace, metric contract and optional recording

Local, keyboard-driven observability: dashboards with charts, a panel inspector, local alert
rules, a bounded in-memory history, optional SQLite recording, an optional Prometheus exporter
in the Go worker and an optional remote Prometheus source. Nothing here applies a tweak or
opens a listener unless you ask for it (`Tui/Monitor.ps1:1-5`).

Every key, command and number below was read from the code, and each citation names its file;
a bare `:NN` continues the file named just before it. Paths are repository-relative. No Windows
host was available for this work (`docs/VALIDATION.md:16`), and "Not implemented" at the end
lists what the code does not do.

## Opening it and the keys

`B` opens the workspace (`Tui/Tui.ps1:1614`), as does the Overview → Monitoring row
(`Tui/Tui.ps1:2010`). It replaces the main panes with its own canvas
(`Tui/MonitorWorkspace.ps1:375`); row 2 shows the dashboard, collector state and OS/language
(`:388-397`), the footer the time range and hints (`:453-454`). Dispatch is `:1097-1225` and
letters are lower-cased before matching (`:1130-1132`).

| Key | Effect (code reference) |
|---|---|
| `Left` / `Right` | Previous / next dashboard; the panel selection resets (`:1103-1115`) |
| `Up` / `Down` | Move the panel selection (`:1117-1123`) |
| `Enter` | Panel inspector: metric, unit, provider, last update, interval, samples, window, dims, aggregation, missing-data note, provider errors, raw samples (`:1125-1127`, `:461`) |
| `F` | Toggles `Frozen` (`:1138`) — header label only, see the caveat below (`:392`) |
| `P` | Pause / resume collection; resuming starts a new collector (`:1139-1151`). While paused `Update-WtMonitorWorkspace` returns at `:196` |
| `T` | Time range `300 → 900 → 3600 → 60` s (`:1206-1214`); default 300 s (`:125`) |
| `A` | Alert rules with state, severity, hold, hysteresis; `Enter` toggles acknowledge (`:1152-1154`, `:527`) |
| `E` / `C` | Dashboard editor (`:1179-1181`, `:583`) / interval comparison (`:1175-1177`, `:749`) |
| `O` / `R` | Remote Prometheus source: endpoint prompt and connection test (`:1156-1174`) / toggle SQLite recording (`:1183-1205`) |
| `1`/`2`/`3`/`4` | Fleet / incident / playbook / support bundle — [MULTI-HOST.md](MULTI-HOST.md) (`:1134-1137`) |
| `?` / `Esc` | Shortcut list (`:1216-1224`) / leave; the collector stops in the `finally` block (`:1230-1237`) |

There is **no** refresh control: fast/slow start at 0 (`:153`) and take the defaults 1 s and 10 s
(`Observability/Collector.ps1:21-22`); the collector is in-process and samples on the frame loop
(`Observability/Collector.ps1:428-447`). `Get-WtMonitorDefaults` also reports `QueueCap` 512 and
`ProviderTimeoutMs` 5000 (`Observability/Collector.ps1:21-24`; `src/WindowsTweaker/Public/Observability.ps1:111-130`), but nothing
enforces that timeout; the worker round trip allows 5 s (`Observability/Collector.ps1:334`).

## Dashboards and panels

Built-ins are data, not code (`Observability/Dashboards.ps1:99-135`); imported dashboards come
after them (`:185-201`).

| Id | Panels |
|---|---|
| `overview` | `host.cpu.utilization` (sparkline), `host.mem.physical.usedBytes` (sparkline), `host.disk.system.freeBytes` (stat), `host.uptime.seconds` (stat) |
| `network` | `host.net.rxBytes` / `host.net.txBytes` (sparkline, dims `adapter = {selected}`), `host.net.link.state` (list) |
| `changes` | `ops.events`, `ops.alerts` (list) |

Types: `sparkline`, `stat`, `list`, `table` (`Observability/Dashboards.ps1:7`). A `sparkline` draws the
bucketed chart; other types draw a value line plus a quality label for non-`valid` samples,
and a series with no samples reads as "no history" (`Tui/MonitorWorkspace.ps1:407-444`, `:438`).
Counters are charted from a derived per-second series (id `Bytes`→`Rate`, unit `bytes/s`,
`:36-49`).

## Metric data contract

`Observability/Metrics.ps1:1-22` states it, `Test-WtMetricSample` enforces it (`:36-121`); the
Go model is `worker/internal/metric/metric.go:58-84`.

| Field | Rule |
|---|---|
| `id` | stable id `^[a-z0-9][a-z0-9._-]*$` (`Observability/Metrics.ps1:63`) |
| `type` | `gauge` or `counter` (`:27`, `:64`) |
| `unit` | required, SI-ish (`%`, `bytes`, `bytes/s`, `seconds`, `count`, …) (`:65`) |
| `tsMs` | positive UTC epoch milliseconds (`:67`) |
| `quality` | `valid` \| `unavailable` \| `unsupported` \| `stale` \| `error` (`:26`, `:66`) |
| `dims` | at most 8 entries, keys `^[a-z0-9][a-z0-9_-]*$`, values ≤ 128 characters (`:92-113`) |
| `provider` | stable name; defaults to the id's first segment (`:143`) |
| `value` | numeric, **only** on `valid` samples (`:72-75`, `:80-84`) |
| `errorCode` | required for every non-`valid` sample (`:86-88`) |

Missing data is never zero: no value on a non-`valid` sample (`:84`), no gap filling
(`Observability/History.ps1:226-253`). Rates use the monotonic elapsed time between two samples of the same
series when available, otherwise the timestamp delta; a non-positive elapsed time or negative
delta yields nothing, so a rate is never negative (`ConvertTo-WtMetricRate`, `:198-256`).
bytes/s stays distinct from bits/s (unit carried through, `B/s` kept, `Tui/Monitor.ps1:12-35`).
Worker bounds: 64 metrics per snapshot, 8 dimensions, 64 characters per value
(`worker/internal/metric/metric.go:86-92`); codes `E_UNSUPPORTED_PROVIDER`, `E_READ_FAILED`, `E_NO_BASELINE`,
`E_STALE` (`:47-55`). The worker returns raw counters and never computes rates (`:1-17`).

## Bounded history

| Limit (`Observability/History.ps1:18-25`) | Value | At the boundary |
|---|---|---|
| Series | 256 | Refused, counted in `RefusedSeries`, reported `series-limit` (`:71-75`, `:123-130`) |
| Samples per series | 4096 | Oldest dropped (ring), counted in `DroppedSamples` (`:167-169`) |
| Dimension values per series | 16 | Sample refused, counted `dim-cardinality` (`:133-149`) |
| Series per metric id | 16 | Further dimension combinations of one id refused (`:76-85`) |
| Total metric memory | 64 MB (≈128 B/sample) | Sample refused as `memory-limit` (`:151-161`) |
| Subscriptions | 32 | Declared at `:24`, **not enforced anywhere** |

Only observed samples are stored; a range beyond the history is clamped and the available
interval reported via `AvailableFrom`/`AvailableTo`/`Available` (`:183-222`, `:310-330`).

## Optional persistent recording (SQLite)

`R` probes the store (`metric.store.stats`), then reports path plus retention or refuses and
leaves recording off (`Tui/MonitorWorkspace.ps1:1183-1205`; probe `Observability/Persistence.ps1:168-188`).

| Exported command | Parameters | Notes |
|---|---|---|
| `Enable-WtMetricRecording` | `-Persistence`, `-RetentionDays` (default 30, 1..360) | `src/WindowsTweaker/Public/ObservabilityPersistence.ps1:9-38`; throws when the probe fails |
| `Disable-WtMetricRecording` | `-Persistence` | Flushes queued batches, then disables (`:44-58`) |
| `Get-WtMetricRecording` | `-Persistence` | State, path, queue depth, written, dropped, retention, error (`:60-82`) |
| `Get-WtStoredMetricRange` | `-Persistence`, `-Id`, `-FromMs`, `-ToMs`, `-BucketMs` | Read-only bucketed query; throws when recording is off (`:86-127`) |

`-Persistence` is the internal object from `New-WtMetricPersistenceInternal`
(`Observability/Persistence.ps1:26-45`); no exported command returns one, so the tests build it
directly (`tests/Monitor.Tests.ps1:344-345`). Default path `<data root>/metrics/metrics.db`
(`Observability/Persistence.ps1:31-34`), and the data root honours `WT_DATA_ROOT`
(`src/WindowsTweaker/Private/Common.ps1:18-37`). PowerShell never opens the file: the Go worker
is the single writer, reached through `metric.store.write|query|raw|retention|stats|alert`
(`Observability/Persistence.ps1:1-15`; `worker/internal/protocol/protocol.go:42-52`). Queue 64
batches, 2048 rows per batch, retention 30 days, 256 MB cap
(`Observability/Persistence.ps1:17-22`); a full queue drops and counts the batch (`:75-93`).
Retention runs at most hourly and reports what it removes (`:131-166`); only metric rows older
than the cutoff are touched and the store holds no recovery data
(`worker/internal/store/store.go:394-402`, `:5-19`).

Schema v1, batch cap 4096 rows, query cap 10000 buckets; `MaxRetentionDays` 3650 is declared
but never read (`worker/internal/store/store.go:36-44`, `:298-320`). Failures map to stable codes
`E_STORE_OPEN_FAILED`, `E_STORE_MIGRATE_FAILED`, `E_STORE_CORRUPT`, `E_STORE_LOCKED`,
`E_STORE_DISK_FULL`, `E_STORE_READ_ONLY`, `E_STORE_LIMIT_EXCEEDED`, `E_STORE_INVALID_PARAMS`
(`:47-56`, `:188-203`). A corrupt database is never silently replaced: opening fails with a
stable code and the store stays read-only (`worker/internal/store/store.go:14-15`; test `tests/Monitor.Tests.ps1:409`).

## Custom dashboards (E) and import validation

The editor works on a copy and saves explicitly (`Tui/MonitorWorkspace.ps1:583-746`): per panel set
size (`small`/`medium`/`large`), remove, move up/down; then Add (six fixed metrics, type
`sparkline` or `stat`), Save, Duplicate (new id, which becomes active) and Reset (drops the
stored copy so the built-in template applies). `Import-WtDashboard -Path [-Force]` and
`Export-WtDashboard -Id -Path [-Force]` (`src/WindowsTweaker/Public/Observability.ps1:43-105`) validate against a
hard allowlist (`Test-WtDashboardDocument`, `Observability/Dashboards.ps1:26-98`): schema version 1..2,
required `dashboardId`, 1..12 panels, unique ids, type `sparkline|stat|list|table`, metric from
the 14-id allowlist (`:8-23`), aggregation `raw|avg|min|max|sum|last` (`:25`), ≤ 4 dim entries,
numeric threshold, size enum, no unknown fields, 64 KiB bound. An invalid document is refused
before anything is written, an existing id is never overwritten without `-Force` (`:138-159`),
and a stored file that no longer validates is ignored in favour of the built-in
(`:161-183`). Export writes the definition only (`:76-105`).

## Interval comparison (C)

Two pickers (last 1 m / 5 m / 15 m), a metadata confirmation, then one row per supported
metric with coverage `valid/total vs valid/total` and a verdict (`Tui/MonitorWorkspace.ps1:749-818`):
`Improved`, `Regressed`, `Inconclusive` (shift within the pooled spread), `Insufficient`
(< 10 valid samples by default) (`Observability/Comparison.ps1:37-45`, `:76-93`). Direction is
declared per metric, never inferred — lower-is-better CPU and used memory, higher-is-better
free disk, neutral network bytes (`:17-26`). No causation is claimed: intervals link to
sessions/operations for context only (`:11-14`). The optional export writes
`{ baseline, comparison, rows }` (`Tui/MonitorWorkspace.ps1:798-818`).

## Alerts and alert history

Rules are data; the defaults (`Observability/Alerts.ps1:25-77`):

| Rule id | Metric | Condition | Hold | Hysteresis | Severity |
|---|---|---|---|---|---|
| `system-disk-low` | `host.disk.system.freeBytes` | `lt` 5 GB | 30 s | 10 GB | high |
| `collector-stale` | `host.collector.ageSeconds` | `gt` 30 | 15 s | 10 | medium |
| `ops-verification-failed` | `ops.verification.failed` | `gt` 0 | 10 s | 0 | medium |
| `ops-interrupted` | `ops.interrupted` | `gt` 0 | 10 s | 0 | medium |
| `ops-drift` | `ops.drift` | `gt` 0 | 10 s | 0 | low |

Evaluation is pure and read-only (`:91-242`): `normal → pending → firing` after the hold
(`:133-141`, `:154`, `:174`); `firing → resolved` only through hysteresis and only while a
value exists, so missing data never resolves (`:184-215`), and the result carries
`missing = $true` when no valid value exists (`:235`). `unknown` is declared (`:16`) but never
assigned; the active counter skips muted rules (`:246-252`). Alert history is written only
while recording is enabled and only on a state **change** (`Add-WtAlertTransitionInternal`,
`Observability/Persistence.ps1:210-255`) as `metric.store.alert` with `ruleId`, `revision`, `fromState`,
`toState`, `atMs`, `evidence`, `dataSource = "local"`; rows live in the metrics database
(`worker/internal/store/store.go:425-441`), never the journal.

## Optional Prometheus exporter (Go worker)

`worker/internal/exporter/exporter.go`: off by default; loopback by deployment — `Address`
defaults to `127.0.0.1` (`:76-78`) and the server passes only a port
(`worker/internal/server/server.go:788`), so the listener is loopback; the package comment says
a non-loopback interface is refused (`:5-7`), but no code rejects a caller-supplied address.
Port 1024..65535 (`:79-81`), listener opened only by `Start` (`:109`, `:118-121`); read-only
`/metrics`, no management routes (`:11-12`, `:124-130`); a failed probe is never exported as
zero — freshness appears as `wt_collector_freshness_seconds` and
`wt_collector_last_success_timestamp_seconds` (`:13-16`, `:199-209`); samples older than
`StaleAfter` (2 minutes) are removed, not shown as fresh (`:41`, `:139-155`); a scrape never
triggers collection (`:17-18`). The `wt_` prefix is a documented convention (`:39`) used by the
samples; no code enforces a prefix on supplied names. Driver: the official Prometheus Go client
(`:21-22`), Apache-2.0 (`THIRD-PARTY-NOTICES.md`).

| Sample in `artifacts/monitoring/` | Content |
|---|---|
| `prometheus-sample.yml` | `scrape_interval: 15s`, job `windows_tweaker`, `/metrics`, target `127.0.0.1:39090` — an example port; the code has **no default port** |
| `grafana-dashboard.json` | "WindowsTweaker overview", 8 panels (`wt_cpu_utilization_percent`, `wt_mem_physical_used_bytes`, `wt_disk_system_free_bytes`, `rate(wt_net_rx_bytes_total[5m])`, `rate(wt_net_tx_bytes_total[5m])`, `wt_collector_freshness_seconds`, `wt_ops_*_total`, `wt_alerts_active`) |

## Remote Prometheus data source (O)

`O` prompts for an endpoint (initial `http://127.0.0.1:9090`) and tests it with an instant `up`
query; success enables it for the session (`Tui/MonitorWorkspace.ps1:1156-1174`;
`Observability/PromData.ps1:137-155`). Panels with a curated template then read remotely and
carry a `[prom]` badge, so remote values are never mixed silently with local ones
(`Tui/MonitorWorkspace.ps1:318`, `:352-370`, `:418`). Bounds (`Observability/PromData.ps1:1-13`): timeout 5000 ms,
response size 262144 bytes, 64 series, 5-minute default window, per-query step (`:24-42`,
`:69`, `:71`); responses above the byte bound are refused (`:90`); only five templates are
queryable — `host.cpu.utilization`, `host.mem.physical.usedBytes`,
`host.disk.system.freeBytes`, `host.net.rxBytes`, `host.net.txBytes` (`:16-23`) — never an
arbitrary query; labels lose control sequences and newlines (`Clear-WtPromLabel`, `:44-50`).
The endpoint is the only secret input and stays in session state (`:9-10`).

## Status: what is verified, and where

| Area | Verified on Linux by the suite | Still open |
|---|---|---|
| Metric model, history, dashboards, alerts, charts, collection | `tests/Monitor.Tests.ps1` (22 tests, 0 failures, `docs/VALIDATION.md:95`) | — |
| Recording through the real worker/SQLite, retention, corruption | `tests/Monitor.Tests.ps1` ("Persistent metrics recording") | Disk-full and lock codes are classified from SQLite error text but no test exercises them (`worker/internal/store/store.go:188-203`) |
| Comparison verdicts and export payload | `tests/Monitor.Tests.ps1` ("Interval comparison") | — |
| Remote Prometheus source (local stub server) | `tests/Monitor.Tests.ps1` ("Remote Prometheus data source") | — |
| Go exporter internals (loopback, port, staleness) | `worker/internal/exporter/exporter_test.go` | — |
| Windows metric collection | **not exercised anywhere** | The Go worker reports `unsupported`; the PowerShell collector owns Windows via CIM (`worker/internal/metric/metric.go:15-19`, `:110-126`; `Observability/Collector.ps1:11-15`, `:260`) |

[VALIDATION.md](VALIDATION.md) records what was executed and what was not; worker packaging and
the cross-compiled binaries: [WORKER.md](WORKER.md) — the cross-compile proves compilation, not
behaviour.

## Not implemented / not confirmed by the code

* **`F` freeze.** `F` toggles `Monitor.Frozen` and the header label changes, but the frame loop
  never reads the flag (`Tui/MonitorWorkspace.ps1:189-196`, `:392`, `:1138`): panels keep updating
  and collection is unaffected.
* **Mute.** The panel shows a muted flag (`:544`) and the counter honours it
  (`Observability/Alerts.ps1:246-252`), but nothing sets `muted = $true`; `Enter` toggles `ack` only
  (`Tui/MonitorWorkspace.ps1:569-572`).
* **Adapter and disk selection.** The session carries `Adapter`/`Disk` (`:123-124`), passes them
  to the collector (`:153`) and the collector filters by adapter (`Observability/Collector.ps1:205`), but no
  key or dialog assigns them, so `{selected}` has nothing to substitute (`:294-303`).
* **Changes timeline.** The `changes` dashboard declares `ops.events` and `ops.alerts`
  (`Observability/Dashboards.ps1:128-133`); no code produces either id and neither is on the import
  allowlist, so both render as "no history". The journal and verification views stay in the main
  interface ([STATE-JOURNAL.md](STATE-JOURNAL.md)).
* **Prometheus exporter reachability.** The worker wires only `exporter.start`/`stop`/`status`
  (`worker/internal/server/server.go:778-820`), and `Exporter.Set` — the only function that
  populates series — is called from the exporter's own tests only (`worker/internal/exporter/exporter_test.go:26,55,69`):
  a started exporter serves an empty registry, and the `wt_*` names in the Grafana sample come
  from no production code path. No PowerShell command or workspace key starts it.