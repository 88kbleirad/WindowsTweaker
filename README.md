# WindowsTweaker

Reviewable, reversible Windows customization, driven from the terminal.

Every change is a **tweak** with metadata (scope, required privileges, supported OS
conditions, impact, restart requirement, rollback support), a **read-only detector** and an
**apply** implementation that captures the previous state before it writes. Changes can be
dry-run, verified, logged per operation and rolled back to the state that actually existed
before - not to a hard-coded default.

## Status

* Target platform: **Windows 10 22H2 / Windows 11** with **PowerShell 7.4 or newer**.
  Windows PowerShell 5.1 is **not** supported and is not claimed: the code base uses
  PowerShell 7-only features (`-Encoding utf8NoBOM`, `-ErrorAction Ignore`,
  `[type]::new()`), and the Windows-only modules are imported explicitly.
* Interfaces: a **keyboard-driven terminal interface** (the default), a scriptable CLI
  and an optional WPF window, all on the same backend.
* Validation status: see [docs/VALIDATION.md](docs/VALIDATION.md). This archive was
  validated statically and with automated tests on Linux (471 tests, including the
  terminal interface driven head-lessly and in a real pty); Windows-only integration
  checks could not be executed and are listed explicitly instead of being claimed.

## Quick start

```powershell
# The terminal interface (the main deliverable): browse, search, select, review, apply.
# Every selection is reviewed before anything is written; see docs/KEYBOARD.md.
pwsh -File WindowsTweaker.ps1

# Read-only: what can this machine do, what is the current state?
pwsh -File WindowsTweaker.ps1 -Status
pwsh -File WindowsTweaker.ps1 -List

# Dry run: shows every operation that would run; writes nothing.
pwsh -File WindowsTweaker.ps1 -Id Privacy.AdvertisingId -State Disabled -WhatIf

# Apply, keeping the previous state for rollback.
pwsh -File WindowsTweaker.ps1 -Id Privacy.AdvertisingId -State Disabled

# Optionally ask for an extra safety net first (supplementary, never implicit).
pwsh -File WindowsTweaker.ps1 -Id Privacy.AdvertisingId -State Disabled -IncludeRestorePoint

# Preview a whole preset, then apply it.
pwsh -File WindowsTweaker.ps1 -PresetList
pwsh -File WindowsTweaker.ps1 -Preset privacy-hardening -WhatIf

# Undo it, restoring exactly what was there before.
pwsh -File WindowsTweaker.ps1 -Id Privacy.AdvertisingId -Rollback

# Optional graphical interface (Windows only).
pwsh -File WindowsTweaker.ps1 -Gui
```

Scripted use:

```powershell
Import-Module ./src/WindowsTweaker/WindowsTweaker.psd1

Get-WtTweak -Category Explorer                        # catalog
Get-WtTweakState -Search 'telemetry'                  # current state, read-only
Invoke-WtTweak -Id Privacy.AdvertisingId -State Disabled -WhatIf
Undo-WtTweak -Id Privacy.AdvertisingId                # newest captured change
Get-WtHistory                                         # audit trail
Get-WtPreset                                          # shipped and user presets
Export-WtPreset -Entries @(@{ id = 'Explorer.FileExtensions'; state = 'Enabled' }) -Path ./my-preset.json
Export-WtReport -Format Json                          # environment + catalog + history
```

Exit codes of the entry point: `0` success/unchanged/dry run, `1` failed or
unsupported, `2` nothing to do (or the terminal interface could not start).

## Terminal interface

The terminal interface is the primary deliverable: it replaces the previous line-based menu
loop, and it migrates the workflows the legacy tool performed in windows.

```
 ⊞ WindowsTweaker                                              Preset: privacy-hardening    
 Windows11 build 22631 | PowerShell 7.4.2 | administrator | live | EN                       
├──────────────────┬──────────────────────────────────────┬────────────────────────────────┤
┌ Categories ──────┬ Tweaks ──────────────────────────────┬ Details ───────────────────────┐
 ⌂ Overview  [113]│ *  ▪ Advertising...  Disabled   Enabled│▪ Web results and suggestions in 
 ▪ Privacy    [20]│>*  ▪ Web results...  Disabled   Enabled│  the search box                 
 ▭ Explorer   [18]│ *  ▪ Diagnostic ...   Enabled   Enabled│                                 
 ▦ Apps       [21]│    ▪ Microsoft a... Unsuppor...          │Privacy.BingSearch               
 ⊞ System     [14]│    ▪ Windows Err... Unsuppor...          │                                 
 ○ Network     [1]│    ▪ Windows fee... Unsuppor...          │Sets the user policy that keeps  
 ◆ Security   [11]│    ▪ Let website... Unsuppor...          │web suggestions out of the Start 
 ⇩ Updates     [5]│    ▪ Potentially... Unsuppor...          │and File Explorer search boxes   
 ▤ Personal... [9]│    ▪ Recommended... Unsuppor...          │(HKCU\Software\Policies\Microsof 
 ↺ History     [0]│    ▪ Search high... Unsuppor...          │t\Windows\Explorer\DisableSearch 
└──────────────────┴──────────────────────────────────────┴────────────────────────────────┘
├──────────────────┴──────────────────────────────────────┴────────────────────────────────┤
 Up/Down move  Left/Right or Tab panes  Space select  Enter actions  / search  A review  …  
 Ready. Use / to search, Space to select a change, A to review. 3 pending change(s)        
```

* **Panes** - categories, the tweak list and a details pane that states the description,
  the exact planned effect, the scope, the privileges, the current state, the impact level,
  the restart requirement, the rollback fidelity and the dependencies.
* **Layouts** - three panes at 92x18 or larger, two panes from 58x12, and a single pane
  with a category tab strip below that. A resize repaints without losing the cursor, the
  pending set, the filter or the open dialog.
* **Icons** - one semantic icon vocabulary for categories, states and actions, drawn in
  four display modes: `Unicode` (conservative monochrome symbols, the default when the
  output encoding is UTF-8), `NerdFont` (private-use glyphs, opt-in), `ASCII` (readable
  tags such as `[NET]`, `[OK]`, `[WARN]`, `[ERR]` and `[ADMIN]`) and `None`. `Auto` picks
  Unicode or ASCII for the terminal at hand, and no font is ever installed, detected or
  changed. `I` opens an in-terminal preview that draws each mode with the real glyph table,
  the choice is saved to `settings.json` next to the state store, and `-Icons <mode>`
  overrides it for one run. Icons are decoration only: the state, the category and the
  action are always written out as text as well, and the shortcuts never depend on them.
* **Colour** - Catppuccin Mocha with true colour, 256-colour, 16-colour and no-colour
  fallbacks, square panel corners, and an ASCII frame fallback. Row markers (`>`, `*`,
  `!`, `M`, `R`, `D`) keep every state readable without colour or icons, and no Nerd Font
  is required. English and Vietnamese share the same layout.
* **Optional background worker** - a small, read-only, unprivileged Go program
  (`worker/bin/<os>-<arch>/wt-worker[.exe]`) can serve measured background work over a
  versioned JSON Lines protocol on stdin/stdout. It never writes a setting, never runs as
  administrator, and never implements the change engine, journal or rollback - those stay in
  PowerShell. The first capability is directory scanning with size aggregation
  (`Invoke-WtDirectoryScan`), with `Auto` / `Go` / `PowerShell` backend modes (setting or
  `-WorkerBackend`), automatic fallback to the PowerShell implementation with the reason
  reported, and `-Scan <path>` on the command line. See
  [docs/WORKER.md](docs/WORKER.md) for the protocol, the build, and exactly which Windows
  checks were **not** executed.
* **Change verification and recovery** - every pending change is previewed target by target
  (current value, proposed value and type, scope, support status, recovery limits, and whether
  an earlier operation already holds the original baseline), overlapping targets are reported
  as conflicts before anything runs, and the reviewed state is re-read immediately before
  applying: if it moved, the change is refused and has to be reviewed again. The journal
  records schema version, session, operation, parent operation, origin (manual, preset,
  recovery, reapply), stage, canonical targets, captured state and the verified outcome, and
  it is written before the first mutation. Applying and restoring read the supported targets
  back; a partial failure triggers compensating restoration (reported per target, never
  described as atomic Windows rollback) and keeps the recovery data. `V` shows drift
  (matching / changed / unreadable / unsupported) and interrupted operations, with explicit
  reapply and restore actions - nothing is ever reapplied automatically. See
  [docs/STATE-JOURNAL.md](docs/STATE-JOURNAL.md).
* **Language** - English and Vietnamese ship every user-facing string: header, categories,
  details, status line, footer hints, dialog titles/questions/buttons, errors and the
  unsupported-platform notices. `L` (or the Overview -> Language row) switches immediately -
  the whole frame and the detected tweak names are re-rendered, while the search text, the
  pending set, the cursor and the operation history are preserved - and the choice is saved.
  Precedence at startup: `-Language en|vi` (for example
  `pwsh -File WindowsTweaker.ps1 -Language vi`) > the saved choice > `WT_LANG` > the UI
  culture > English. Switching never applies or resets a tweak.
* **Shortcuts** - [docs/KEYBOARD.md](docs/KEYBOARD.md) (English and Vietnamese). The footer
  line shows as many shortcuts as fit and `?` lists all of them; `-InputDiagnostics` logs
  every key press and its dispatch target (masking text fields) when a key seems ignored.
* **Never a window** - confirmations, pickers and errors are panels in the same screen. The
  Store package picker, the Windows feature/capability lists, the DNS adapter workflow and
  the preset import/export path dialogs are all terminal workflows.
* **Responsive** - applying and rolling back run in a worker runspace and report structured
  progress (`Item 3 of 18`, never an invented percentage), per-item results and their
  restart requirements. Cancellation is cooperative: queued items are dropped and the item
  that is already running finishes at its safe boundary, which the interface states
  explicitly. Only one operation runs at a time.
* **Terminal hygiene** - the alternate screen buffer is used (no `Clear-Host` redraw loop),
  and the terminal is restored on a normal exit, on `Ctrl+C` and on an unexpected
  exception.

## Safety model

| Guarantee | How it is enforced |
|---|---|
| Importing the module changes nothing | Tweak files only register metadata; a test asserts that no provider mutation runs during import and that no state/log file is created |
| Initialisation is read-only | `Get-WtEnvironment` only reads (version, elevation, OS build, pending reboot, cmdlet availability). All mutating startup logic from the previous revision was removed |
| Selecting a row changes nothing | The interface keeps a pending set; `A` reviews the exact changes and only a confirmation applies them. Every mutation goes through `Invoke-WtTweak`/`Undo-WtTweak` in a worker runspace |
| `-WhatIf` writes nothing | Providers gate every mutation with `ShouldProcess`; a dry run enumerates *which* operations would run and reports them as `dryrun`, and never captures state. The interface's `W` preview uses the same path |
| Rollback is exact | The previous registry value **and its kind and existence**, service start type/state, scheduled-task state, firewall-rule state, per-adapter DNS list and Defender preference are stored before the change and replayed in reverse |
| Irreversible actions are labelled | Package removal, OneDrive uninstall, installer downloads and data deletion are separate tweaks with `-Irreversible`/`-DataDeletion`, `Rollback = None` and an impact text that says what is lost |
| Failures are never reported as success | Every operation returns `succeeded`, `unchanged`, `skipped`, `unsupported`, `dryrun` or `failed`; verification reads the value back, native processes have their exit codes checked, and the result panel repeats every status verbatim |
| Organization policies are visible | Tweaks declare the policy values that govern them; state reports `Managed`/`ManagedBy` and every interface shows it |
| Protection is not reduced | Nothing disables Defender, Controlled Folder Access, SmartScreen, UAC prompts or security logging at startup or as a side effect. Protection-reducing tweaks exist only as explicit, `-Risk High`, `-ReducesProtection`-flagged entries that are never applied automatically, and shipped presets exclude them |
| User data is preserved | Uninstalling software and deleting data are separate tweaks. OneDrive user files are untouched by the OneDrive tweaks, and package removal deletes package data only for the packages you explicitly selected |
| No code execution shortcuts | No `Invoke-Expression`, no download-and-execute, no executables copied into `System32` (the previous `powershell_temp.exe` trick is gone), no inline C# |
| Downloads are verified | `Get-WtVerifiedDownload` requires `https://`, runs only outside a dry run, validates the Authenticode signature against an expected publisher and refuses the file otherwise |

## Architecture

```
WindowsTweaker.ps1                  entry point (terminal interface / CLI / -Gui)
src/WindowsTweaker/
  WindowsTweaker.psm1               deterministic loader, explicit exports
  Private/                          helpers, providers, tweak model, rollback engine
    Common, Logging, Localization, Environment, State, Tweak, Rollback
    Providers/                      Registry, System (service/task/firewall), Dns, Appx,
                                    Defender, Installers, Dism, Operations
    Tui/                            terminal interface
      Theme, Screen, Input          palette, cell grid and renderers, key vocabulary
      Dialogs                       in-screen message/confirm/text/list dialogs
      Worker                        cancellable runspace worker with structured events
      Workflows                     pickers, pending review, apply/preview/rollback, presets
      Tui                           state, layout, key dispatch, main loop, terminal setup
  Public/                           exported API (catalog, tweaks, presets, reporting)
  Tweaks/<Category>/*.ps1           tweak definitions (metadata + operations)
  Data/Strings.<lang>.psd1          localization (en reference + vi)
  Data/Presets/*.json               shipped presets
  Gui/MainWindow.xaml, Gui.ps1      optional WPF interface (styling separated from logic)
tests/                              Pester suite (engine, providers, CLI, GUI, TUI)
tools/                              Parse-All, Test-Catalog, Test-Insight, Invoke-Validation,
                                    New-FeatureInventory, New-ReleasePackage, Measure-WtWorker
docs/                               catalog, packs, worker, state journal, validation,
                                    limitations, dependencies, keyboard, migration notes
bootstrap/bootstrap.ps1             installer launcher run as text (irm | iex)
deploy/short-url/                   nginx config for the short download URL (prepared only)
worker/                             optional Go worker: cmd/, internal/, go.mod, bin/
samples/example-pack.json           example tweak pack for -CatalogValidate / -PackImport
licenses/                           verbatim licence texts (upstream MIT, Go worker modules)
artifacts/monitoring/               sample scrape config and Grafana dashboard JSON
reference/                          upstream reference material (never executed)
```

Loading order is explicit (helpers, providers, terminal interface, public API, tweaks, GUI)
and every file is parsed before it is dot-sourced: a syntax error aborts the import instead
of silently dropping definitions - the failure mode that produced the original
"undefined function" bugs.

Presentation, state detection, planning, execution and rollback are separate:

| Concern | Where | Read-only |
|---|---|---|
| Presentation | `Private/Tui/*`, `Private/Gui.ps1`, the CLI switch block in the entry point | yes |
| State detection | `Get-WtTweakState` (per-tweak `-Detect`, always read-only) | yes |
| Planning | the pending set in the interface, and `-WhatIf` in the backend | yes |
| Execution | `Invoke-WtTweak` / `Undo-WtTweak` through the providers, in a worker runspace | no |
| Rollback | the state store and `Invoke-WtRollback` | no |

## Defining a tweak

Declarative (registry):

```powershell
New-WtRegistryTweak -Id 'Explorer.FileExtensions' -Category 'Explorer' `
    -Name @{ en = 'File name extensions'; vi = 'Phần mở rộng tên tệp' } `
    -Description @{ en = '...'; vi = '...' } -Impact @{ en = '...'; vi = '...' } `
    -Scope 'User' -Privilege 'None' -Restart 'Explorer' -Rollback 'Full' -Risk 'Low' `
    -Detection @{ Path = 'HKCU:\...\Advanced'; Name = 'HideFileExt'; Map = [ordered]@{ Enabled = @(0); Disabled = @(1) } } `
    -States @{
        Enabled  = @(@{ Kind = 'RegistrySet'; Path = 'HKCU:\...\Advanced'; Name = 'HideFileExt'; Type = 'DWord'; Value = 0 })
        Disabled = @(@{ Kind = 'RegistrySet'; Path = 'HKCU:\...\Advanced'; Name = 'HideFileExt'; Type = 'DWord'; Value = 1 })
    }
```

Scripted (services, tasks, DNS, packages, installers) uses `New-WtScriptTweak` with a
read-only `-Detect` and an `-Apply` that calls the provider functions. A parameterized tweak
declares `-Parameters` (for example `Apps.WindowsFeature` declares `FeatureName`); the
interface collects them through its pickers and refuses to run without them. Both
constructors are documented in [docs/MIGRATION-SPEC.md](docs/MIGRATION-SPEC.md); the
operation kinds and the provider list are there too.

## Declarative catalog and packs

A tweak can also be data. `src/WindowsTweaker/Data/Catalog/builtin.json` declares tweaks in JSON
(same detection maps and operation lists, both languages, separated evidence), and a local
**Tweak Pack** uses the same format with one extra rule: every id must live inside the pack's own
namespace, so an imported pack can never redefine a built-in tweak.

```text
pwsh -File WindowsTweaker.ps1 -CatalogList -CatalogFilter definitions,lifecycle:Experimental
pwsh -File WindowsTweaker.ps1 -CatalogInspect Privacy.WindowsTips
pwsh -File WindowsTweaker.ps1 -CatalogValidate ./samples/example-pack.json
pwsh -File WindowsTweaker.ps1 -CatalogPlan Privacy.SearchHighlights,Privacy.BingSearch
pwsh -File WindowsTweaker.ps1 -PackImport ./samples/example-pack.json -WhatIf
```

Documents are data only: nothing in them is evaluated, downloaded or resolved, and loading one
never reads or writes Windows. Definitions are registered through the existing constructor, so
preview, review, journal, verification and rollback are unchanged. Prerequisites (`requires`),
ordering (`runAfter`) and refusals (`conflictsWith`) are planned before anything runs, and a
prerequisite that is already satisfied is excluded from the apply set rather than rewritten.
Renaming or retiring an id keeps it working through the migration registry, and journal entries
keep the id they were written with.

See [docs/CATALOG.md](docs/CATALOG.md) and [docs/PACKS.md](docs/PACKS.md).

## Review before you change: scan, recommendations, dimensions

Three read-only surfaces, none of which applies anything:

```text
pwsh -File WindowsTweaker.ps1 -SanityScan                     # what is worth a human look
pwsh -File WindowsTweaker.ps1 -Recommend Privacy -RecommendManual
pwsh -File WindowsTweaker.ps1 -Choices                        # one setting, several alternatives
pwsh -File WindowsTweaker.ps1 -CatalogInspect Privacy.WindowsTips -CatalogDimensions
```

* **Sanity scan** - a small rule set with sources: MMCSS task values (documented rounding,
  clamping, ignored and removed semantics), static TCP receive-window values, debug-only boot timer
  options, and pending-restart markers. A finding is not a fault: it carries the documented claim,
  the expectation that claim implies, and what the claim does not cover. It reports `Clean` only
  when every required probe answered; an unreadable probe makes it `Incomplete`.
* **Recommendations** - one objective at a time (Balanced, Responsiveness, Gaming, PowerEfficiency,
  Privacy), with an explanation for every item considered. Eligibility is decided by the engine, not
  by the document: nothing that reduces protection, cannot be restored exactly or carries high risk
  is ever selected automatically, and an imported pack can only ever be offered.
* **Configured, effective and ownership** - three separate answers, kept apart everywhere. A
  successful write and read-back proves configuration, not behaviour, so an effective state is only
  reported from evidence (`Observed`, `Inferred`, or the honest `Unknown`).
* **Exclusive choices** - a setting with several alternatives is one tweak with several states, so
  only one alternative can be pending; switching replaces it, recomputes dependencies and conflicts,
  and invalidates the earlier review. Restoring the captured baseline is a different action from
  asking for Windows' own default, and the interface labels them differently.

In the terminal interface: `S` scan, `M` recommendations, `C` choices.

## Documentation

| Document | Content |
|---|---|
| [docs/SANITY-SCAN.md](docs/SANITY-SCAN.md) | The read-only sanity scan: rules, probe vocabulary, outcomes, sources with the claim each supports, reporting, what is not covered |
| [docs/RECOMMENDATIONS.md](docs/RECOMMENDATIONS.md) | Recommendation policy: kinds, engine floors, the five objectives, the explanation for every decision, why nothing is applied automatically |
| [docs/STATE-DIMENSIONS.md](docs/STATE-DIMENSIONS.md) | Configured vs effective vs ownership, evidence kinds, restart boundaries and the four pending-restart marker states |
| [docs/CATALOG.md](docs/CATALOG.md) | Declarative catalog: document format, strictness rules, dependencies, conditions, evidence, migration registry, authoring steps |
| [docs/PACKS.md](docs/PACKS.md) | Tweak packs: format, namespace rule, import/enable/disable/remove workflow, storage, recovery after removal, authoring steps |
| [docs/KEYBOARD.md](docs/KEYBOARD.md) | Every key, dialog, row marker and layout, in English and Vietnamese |
| [docs/WORKER.md](docs/WORKER.md) | The optional Go worker: protocol specification, capability contract, concurrency and memory bounds, PowerShell integration, build and packaging, licence position, benchmark method, and the Windows checks that were not executed |
| [docs/STATE-JOURNAL.md](docs/STATE-JOURNAL.md) | The operation journal: schema 2 fields, migration from schema 1, durability and locking, verification and compensation guarantees, inspection commands |
| [docs/FEATURE-INVENTORY.md](docs/FEATURE-INVENTORY.md) | Interfaces, presets and every tweak: id, category, scope, privileges, risk, restart, rollback, plus the legacy-module mapping |
| [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) | PowerShell version, terminal requirements, Windows-only modules per feature, what happens when a dependency is missing |
| [docs/LIMITATIONS.md](docs/LIMITATIONS.md) | Known limitations, partially reversible actions, platform gaps |
| [docs/VALIDATION.md](docs/VALIDATION.md) | Exactly which checks were executed, with results, and which could not be run |
| [docs/MIGRATION-SPEC.md](docs/MIGRATION-SPEC.md) | Internal contract used to convert the legacy tree |
| [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) | Upstream provenance (Sophia Script for Windows, MIT) and unresolved licensing |

Vietnamese documentation: [README.vi.md](README.vi.md).

## Tests

```bash
pwsh -NoProfile -File tools/Parse-All.ps1        # AST parse every script
pwsh -NoProfile -File tools/Test-Catalog.ps1     # catalog invariants
pwsh -NoProfile -Command "Invoke-Pester -Path tests"
pwsh -NoProfile -File tools/Invoke-Validation.ps1  # all of the above + analyzer + dry-run proof
```

The suite runs on any platform: platform seams (registry, service, task, firewall,
DNS, Appx, Defender) are replaced by in-memory doubles, so state capture, dry-run
behaviour, verification, rollback, logging, dependency handling and the UWP/DNS
selection rules are tested without touching a real system. The terminal interface has its
own suite that drives it head-lessly (an injected key source and an injected terminal
size), so focus, filtering, selection preservation, resize handling, dialogs, presets and
the worker's cancellation contract are covered. Windows-only integration checks are listed
in `docs/VALIDATION.md`.

## Licence

The upstream code this project derives from is MIT (see `THIRD-PARTY-NOTICES.md`).
This repository ships **no licence of its own** - the initial archive did not contain
one, and choosing a licence for the project is the owner's decision. Treat
`THIRD-PARTY-NOTICES.md` as the unresolved item it is.

## Added surface (this work)

* **Capability-loss disclosure** (`Get-WtCapabilityLoss`) - catalog definitions may declare
  what may stop working (stable capability ids, localized descriptions, guaranteed /
  conditional / unknown kinds, temporary vs persistent, restoration path and limits).
  The review aggregates the disclosure across the pending selection (deduplicated by
  capability id, with every causing action named) and shows it in the details pane, the
  preset preview, the review and the final confirmation. Packs may add disclosures but can
  never suppress engine-owned warnings.
* **Disk usage explorer** - an in-terminal directory explorer (`Overview -> Disk usage
  explorer`): explicit root selection, one-level browsing with subtree aggregates and
  sorting by size / file count / name, bounded listing cache, readonly scan, and TXT/JSON
  export. It is backed by a new worker capability `scan.children`
  (`Get-WtDirectoryChildren`) with a PowerShell fallback; links and reparse points are
  listed but never followed, and reports state logical size and never claim the bytes are
  reclaimable.
* **Journaled quarantine** - `Overview -> Quarantine`: read-only candidate scan with
  evidence (install/uninstall records, portable executables, running processes/services,
  recent activity, vendor names, user-data hints), reviewed selection, same-volume moves
  only, recovery intent persisted before any move, source revalidation, durable manifest in
  the state store, restore with no silent overwrite, unresolved-record retry, explicit
  delete, and expiry that only flags for review. Moved bytes are reported separately from
  freed bytes.
* **Device and driver inventory** - `Get-WtDeviceInventory` (read-only): device nodes with
  OS-reported state, hardware IDs, bound driver INF/provider/version/signature, correlation
  confidence, plus a separate Driver Store package list. Non-present is never called
  unused, and incomplete inventory never authorizes removal.
* **Checkpointed setup workflows** - `Get-WtSetupPlan`, `New-WtSetupPlan`,
  `Import-WtSetupPlan` (import applies nothing), `Get-WtSetupPlanPreview`, `Start-WtSetupPlan`,
  `Resume-WtSetupPlan`, `Remove-WtSetupPlanResume`: versioned plans whose steps are catalog
  tweak ids/states only, dependent-step stop on failure, no automatic retry of uncertain
  results, bounded reboot/retry counts, and identity-bound resume registrations that refuse
  tampering.
* **Privacy profile and activity views** - `Get-WtPrivacySummary` reports per-tweak
  preference/policy-shaped metadata (Settings editability, editions/builds, diagnostics
  consequence) as data; `Get-WtPrivacyActivity` lists camera / microphone / location /
  screen-capture views that report themselves Unavailable on this build rather than
  fabricating logs.
* **Power settings explorer and SRUM contract** - `Get-WtPowerSettings` (read-only,
  `powercfg`) reports the active plan and AC/DC setting values; `Get-WtSrumHistory` states
  the SRUM availability contract without enabling services or claiming zero activity from
  missing records.
* **Explorer "Copy path" command** - `Explorer.CopyPathCommand` (current-user context-menu
  verb, engine-reviewed, exactly restored on rollback; quoted `%W` placeholder, no global
  hooks).

The new tests live in `tests/CapabilityLoss.Tests.ps1`, `tests/Quarantine.Tests.ps1`,
`tests/Devices.Tests.ps1`, `tests/SetupPlans.Tests.ps1` and
`tests/PrivacyPowerTools.Tests.ps1`; the Go worker gained `scan.children` and its own tests.


## Attribution

The added surfaces were designed with the listed reference projects as product inspiration
only: `windows-11-practical-scripts`, `Windows-Telemetry-OFF`, `remove-hidden-devices`,
`debora`, `darkhub-suite`, `PrivacyPenguin` (documentation only, never inspected or reused
as source), `WinSpectorPro`, `ZapTweaks` and `win-Tweak`. No code from these projects was
imported; the worker and every PowerShell module here are original, and the third-party
notice file is unchanged.


## Monitoring workspace (local observability)

`B` (or the Overview -> Monitoring row) opens a keyboard-driven monitoring mode: Overview,
Network and Changes dashboards with time-series charts, time-range/refresh controls, adapter
and disk selection, a panel inspector, local alert rules, and a changes timeline that links
to the existing journal/verification views. `F` freezes the display (collection continues),
`P` pauses collection, `T` cycles the time range, `Enter` inspects the selected panel.

Data contract (metric.snapshot): typed gauges/counters with units, UTC timestamps, bounded
dimensions, provider, quality (valid/unavailable/unsupported/stale/error) and stable error
codes. Missing data is never replaced by zero; counter rates use monotonic elapsed time and
never go negative after a reset; bytes/s stays distinct from bits/s. History is bounded
in-memory (256 series x 4096 samples, dimension cardinality limits, gaps preserved).

The Go worker gained `metric.snapshot` (Linux reads /proc and /sys; Windows providers report
unsupported and the PowerShell CIM providers own Windows collection). Dashboards are
versioned JSON documents validated against an allowlist (no embedded code); import/export is
local only. Alerts are declarative rules with holds, hysteresis, missing-data semantics and
explicit acknowledge/mute; they never alter the system.

Measured on this host (CachyOS, PowerShell 7.6.9, amd64): 20 fast cycles = 592 ms
(29.6 ms/cycle, 420 samples) with the PowerShell backend; 968 ms (48.4 ms/cycle) with the
Go worker-backed Auto mode, worker ~7.1 MB resident. These are conditions, not guarantees.

### Optional deeper observability (this iteration)

- **Persistent metrics** (`R` in the workspace, or `Enable-WtMetricRecording`): the Go
  worker is the single SQLite writer (modernc.org/sqlite, pure-Go, BSD-3-Clause). Schema
  v1 with explicit migrations, transactional batched writes, bounded queue with
  drop-and-count backpressure, configurable retention (reported before deletion, never
  touches recovery records), bounded range queries, and explicit corruption/lock/disk-full
  handling — a damaged database is never silently replaced.
- **Custom dashboards** (`E` in the workspace): add/remove supported panels, reorder,
  set size, save named layouts, duplicate, reset to the built-in template, and local
  import/export with strict validation (allowlisted metrics/aggregations, no embedded
  execution). Stored layouts never overwrite a working one on invalid import.
- **Interval comparison** (`C`): baseline vs comparison interval workflow with coverage,
  sample counts, units, aggregation, median/quartiles, direction-aware verdicts
  (improved/regressed/inconclusive/insufficient) and optional JSON export. No causation is
  ever claimed from operation proximity.
- **Optional Prometheus exporter**: disabled by default, loopback-only, validated port,
  read-only /metrics using the official Prometheus Go client (Apache-2.0). Bounded
  allowlisted metrics with a wt_ prefix; no PIDs, paths, tokens, session IDs or operation
  IDs in labels; failed probes are never exported as zero; stale series are removed instead
  of shown as fresh. Sample scrape config and Grafana dashboard JSON live in
  `artifacts/monitoring/`.
- **Remote Prometheus data source** (`O`): endpoint config + connection test, curated
  query templates (no arbitrary query editing), bounded responses/timouts, sanitized
  untrusted labels, and a `[prom]` source badge so remote series are never mixed silently
  with local ones.
- **Alert history**: persisted transitions (pending/firing/resolved/normal) with rule
  id/revision, timestamps, evidence and data-source identity; recorded only on state
  changes (no per-refresh duplicates, no external notifications).


### Multi-host observation, incidents, playbooks and support bundles

- **Fleet (`1`)** — read-only multi-host overview from explicitly configured Prometheus
  data sources (target discovery via `label_values(up, instance)`; stable identity =
  data source + instance; conditions healthy/failed-scrape/stale/missing-target/
  unreachable-ds/unknown; bound sources/targets/query ranges).
- **Incident workspace (`2`)** — unified timeline for an alert or interval: alert
  transitions, relevant metrics/quality, journal operations, drift, collector errors,
  boot/uptime-reset indicators. Evidence kinds (observed/inferred/note/unavailable) and
  clock uncertainty are preserved; notes never rewrite journal records; investigation can
  be saved/reopened and exported.
- **Diagnostic playbooks (`3`)** — versioned, declarative, read-only playbooks for
  network instability, low disk, high resource use, verification failure, and pending/
  failed recovery. Allowlisted probes only; no embedded scripts; no Fix All; remediation
  returns to the existing reviewed engine.
- **Support bundles (`4`)** — explicit preview-and-export of sanitized local support
  packages (manifest with hashes; default exclusions for credentials, keys, usernames,
  computer names, serials, private paths, full command lines, file contents, recovery
  secrets; identifier-redaction preview; bounded size/entries; traversal-safe import as
  historical, untrusted evidence).
- **Versioned monitoring configuration** — append-only revisions for dashboards/alert
  rules/playbooks with diff-before-activation, explicit activation, revert, compatibility
  validation, and evidence attribution to the revision that produced it.
