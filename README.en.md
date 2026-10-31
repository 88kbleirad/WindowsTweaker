# WindowsTweaker

Reviewable, reversible Windows customization, driven from the terminal.

[Tiếng Việt](README.md) | **English**

Every change is a **tweak**: metadata (scope, required privileges, supported OS conditions,
impact, restart requirement, rollback fidelity), a read-only detector, and an apply step that
captures the previous state before it writes. A change can be dry-run, reviewed, applied and
rolled back to the state that actually existed before - not to a hard-coded default.

## What it does

- **Windows customization with preview and per-operation recovery.** 113 tweaks across 10
  categories (privacy, security, Explorer, taskbar, apps, updates, system, network,
  personalization, maintenance). `W` dry-runs the pending selection, `A` reviews it target by
  target, and the journal keeps the captured state so `R` can restore it. Irreversible tweaks
  are labelled as such and never applied automatically.
- **Keyboard-driven terminal interface, plus a scriptable CLI.** Standalone `pwsh` - no
  installation or background service. The same backend also drives an optional WPF window
  (Windows 10/11 only).
- **Diagnostics and configuration drift inspection.** Read-only sanity scan (`S`),
  recommendations for one objective with the reason for every decision (`M`), verification and
  recovery (`V`), capability-loss disclosure for anything a change may stop from working, and a
  per-operation journal with drift between applied and live values.
- **Storage analysis and quarantine.** In-terminal directory explorer with size aggregation
  (PowerShell backend, or the optional Go worker for speed), and a journaled quarantine workflow
  with evidence, same-volume moves and a durable manifest.
- **Local monitoring, with optional Prometheus and Grafana integration.** Keyboard-driven
  dashboards over a bounded in-memory history, declarative alert rules, opt-in SQLite metric
  recording, comparison of two time ranges, and early fleet / incident / playbook / support-bundle
  views. The status of each part is uneven and documented: the Prometheus exporter that ships in
  the worker is not yet fed by the collector, and the fleet/incident/playbook/bundle views are the
  least exercised - see [docs/MONITORING.md](docs/MONITORING.md) and
  [docs/MULTI-HOST.md](docs/MULTI-HOST.md).
- **Declarative catalogs and local packs.** Tweaks can be data (JSON) instead of PowerShell, and a
  local **tweak pack** can add definitions in its own namespace without being able to redefine a
  built-in tweak.

## Status and requirements

| Requirement | Detail |
|---|---|
| Operating system | **Windows 10 22H2 or Windows 11** (the target platform). Every tweak declares `-SupportedOS`/`-MinBuild`; on any other build it reports `unsupported` with the reason instead of guessing |
| PowerShell | **7.4 or newer** - enforced by `#Requires -Version 7.4` and by the module manifest. Windows PowerShell 5.1 is neither supported nor tested |
| Elevation | Only for tweaks that declare `-Privilege Admin`; browsing, previewing and the dry run never need it |
| On Linux | The module loads and the read-only surfaces work (this is where the test suite runs), but every machine-level tweak reports `unsupported`: treat Linux as a place to review and develop, not to apply changes |
| Windows integration checks | **Not executed.** No Windows host was available for validation: real registry, service, scheduled-task, firewall, DNS, Appx, Defender and DISM behaviour, and the WPF interface, were never run. See [docs/VALIDATION.md](docs/VALIDATION.md) |

Things to know before you apply something:

- **Recovery is per operation, not a system snapshot.** Registry values and keys, service start
  type and state, scheduled-task state, firewall-group state, per-adapter DNS lists and Defender
  preferences are captured before a change and restored afterwards. Targets without a read-back
  reader are recorded as *unverifiable*, never as verified. System Restore points are never created
  implicitly; ask for one with `-IncludeRestorePoint`.
- **Some actions cannot be undone.** Package removal, OneDrive uninstall, installer downloads and
  data deletion are separate tweaks marked `-Irreversible`/`-DataDeletion` with `Rollback = None`;
  the shipped presets exclude them.
- **Monitoring measures, it does not promise.** The workspace reports observations with their
  quality and evidence class; no performance gain is claimed or guaranteed.

## Quick start

Run from the repository root; no installed launcher is shipped today.

```powershell
pwsh -File WindowsTweaker.ps1                  # terminal interface: browse, review, apply
pwsh -File WindowsTweaker.ps1 -Language vi     # the same interface in Vietnamese
pwsh -File WindowsTweaker.ps1 -Status          # read-only: what can this machine do?
pwsh -File WindowsTweaker.ps1 -Id Privacy.AdvertisingId -State Disabled -WhatIf
```

The first two commands open the interface. The dry run prints every operation it would perform
and writes nothing; drop `-WhatIf` to apply the change and keep the previous state for rollback.

`irm | iex` installation exists as a script, but it is **not hosted**: the defaults still point at
placeholder repository values, so there is no working public URL today. See
[docs/BOOTSTRAP.md](docs/BOOTSTRAP.md).

## Essential keys

| Key | Action |
|---|---|
| `Up`/`Down`, `PageUp`/`PageDown` | move through the list |
| `Left`/`Right` or `Tab` | move between the panes |
| `Space` | add or remove the current row in the pending set |
| `Enter` | open details and actions (choose the state, collect arguments) |
| `A` | review the pending changes - the only place a selection is applied |
| `W` | dry-run preview of the pending changes (writes nothing) |
| `/` | search; a query starting with `@` filters definitions (`@risk:High`, `@scope:Machine`, ...) |
| `S` / `M` / `C` | sanity scan / recommendations / settings with several alternatives |
| `V` | verification and recovery: drift, interrupted operations, restore, export |
| `B` | monitoring workspace |
| `L` / `I` | switch language / choose the icon mode |
| `?` | the full keyboard reference and the safety rules |
| `Q` (`Ctrl+C`) | quit - pending changes and a running operation are raised explicitly |

Everything, including the monitoring and dialog keys, is in [docs/KEYBOARD.md](docs/KEYBOARD.md).

## Where to go next

| Area | Documents |
|---|---|
| Install, launch, CLI and module API | [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md), [docs/CLI.md](docs/CLI.md), [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) |
| Interface and keys | [docs/KEYBOARD.md](docs/KEYBOARD.md) |
| Catalog, packs and every tweak | [docs/CATALOG.md](docs/CATALOG.md), [docs/PACKS.md](docs/PACKS.md), [docs/FEATURE-INVENTORY.md](docs/FEATURE-INVENTORY.md) |
| Journal, recovery and safety limits | [docs/STATE-JOURNAL.md](docs/STATE-JOURNAL.md), [docs/LIMITATIONS.md](docs/LIMITATIONS.md) |
| Monitoring, exporter and multi-host views | [docs/MONITORING.md](docs/MONITORING.md), [docs/MULTI-HOST.md](docs/MULTI-HOST.md) |
| Architecture, worker and validation | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/WORKER.md](docs/WORKER.md), [docs/VALIDATION.md](docs/VALIDATION.md) |

The complete list is in the [documentation index](docs/README.md). Diagnostic detail lives in
[docs/SANITY-SCAN.md](docs/SANITY-SCAN.md), [docs/RECOMMENDATIONS.md](docs/RECOMMENDATIONS.md) and
[docs/STATE-DIMENSIONS.md](docs/STATE-DIMENSIONS.md).
