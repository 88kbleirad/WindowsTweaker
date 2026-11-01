# Command line and scripted API

Reference for `WindowsTweaker.ps1` and the exported module commands; examples run from the repository root. Launcher and install: [BOOTSTRAP.md](BOOTSTRAP.md). Authoring documents and packs: [CATALOG.md](CATALOG.md), [PACKS.md](PACKS.md).

Every flag and command below is defined by the cited code; the entry point is exercised as a child process by `tests/Cli.Tests.ps1` on Linux. Windows-only mutations were not executed on a Windows host, see [VALIDATION.md](VALIDATION.md). Module paths are relative to `src/WindowsTweaker/`, entry-point citations to `WindowsTweaker.ps1`.

## Invoking the entry point

```powershell
pwsh -File WindowsTweaker.ps1                       # terminal interface (default)
pwsh -File WindowsTweaker.ps1 -Status               # environment snapshot, read-only
```

Without a command switch the script starts the keyboard-driven interface ([KEYBOARD.md](KEYBOARD.md)); every other switch is non-interactive. Without an interactive console (stdin or stdout redirected) the interface refuses to half-start and exits `2`.

Release archives (`WindowsTweaker-<platform>-v<version>.zip`) are unpacked and run from the unpacked root: no launcher is installed and nothing is added to `PATH`. The archive holds `WindowsTweaker.ps1`, `src/WindowsTweaker`, the licence texts, the matching worker binary and the package `manifest.json` that names every file with its SHA-256 ([RELEASE.md](RELEASE.md), [VALIDATION.md](VALIDATION.md) section 11, [tools/New-ReleasePackage.ps1](../tools/New-ReleasePackage.ps1)). PowerShell 7.4-7.6 is the validated runtime, and Windows PowerShell 5.1 starts the same entry point natively (reduced, capability-gated mode) - see [COMPATIBILITY.md](COMPATIBILITY.md).

## Parameters

From the param block (`WindowsTweaker.ps1:263-312`). Dispatch runs in a fixed order (`:472-1145`) and the first match wins: `-List -Status` lists the catalog.

### Inspection (read-only)

| Flag | Type | Effect | Example |
|---|---|---|---|
| `-List` | switch | Catalog with the detected state of every tweak and an enabled/disabled/unknown/unsupported summary | `-List` |
| `-Status` | switch | Environment snapshot, log path, state path, preset names, worker summary | `-Status` |
| `-History` | switch | Change history, newest first (last 50 entries) | `-History` |
| `-Report` | switch | Writes a JSON report (environment + catalog + history) and prints its path | `-Report` |

### Apply and rollback

| Flag | Type | Effect | Example |
|---|---|---|---|
| `-Id` | string | Tweak id to apply (one per run) | `-Id Privacy.AdvertisingId` |
| `-State` | string | Target state; defaults to the tweak's declared default | `-State Disabled` |
| `-Arguments` | hashtable | Parameters for tweaks that declare them | `-Arguments @{ InterfaceIndex = @(7); ServerAddresses = @('1.1.1.1') }` |
| `-IncludeRestorePoint` | switch | Create a System Restore point first (supplementary; needs elevation and System Protection) | `-Id Privacy.AdvertisingId -State Disabled -IncludeRestorePoint` |
| `-RestartAfterApply` | switch | Restart the machine once after the batch, only when every change was applied, verified and fully recorded | `-Preset privacy-hardening -RestartAfterApply` |
| `-WhatIf` | common switch | Dry run: lists every operation that would run, writes nothing, captures no state | `-Id Privacy.AdvertisingId -State Disabled -WhatIf` |
| `-Rollback` | switch | Roll back the newest captured change of `-Id` | `-Id Privacy.AdvertisingId -Rollback` |
| `-HistoryId` | string | Roll back one captured change instead of the newest (id from the `HistoryId` column of `-History`) | `-HistoryId 3f2a1c9e8b7d4a5f9c0e1d2b3a4f5e6d -Rollback` |

A rollback with no captured change reports "No captured state" and exits non-zero rather than pretending to succeed. `Network.DnsOverHttps` and `Maintenance.AdapterPowerSaving` are real tweaks that refuse to run without explicit `-Arguments`.

### Restarting after the batch

`-RestartAfterApply` is opt-in per invocation and is never remembered. It applies to `-Id` and `-Preset` (the two switches that write), and is refused - as a usage error, exit `2`, never silently ignored - with `-WhatIf` and with every read-only switch, and on a platform that cannot restart.

The restart happens only when the whole batch finished cleanly: at least one change applied, nothing failed, cancelled, skipped or unsupported, no worker exception, verification and compensation clean, every journal stage recorded, and nothing else running. A batch of unchanged entries does not restart. A refusal, a cancellation or a failed request never changes what the batch did: the apply outcome and the restart outcome are reported separately, and the manual command is printed.

The countdown (60 s) runs inside this process, so the operating system is asked exactly once, when it expires and only if a console that can deliver a cancellation is attached; `Escape` cancels it. Nothing is force-closed, so unsaved work can delay or prevent the restart. The same rules and the same single adapter are used by the terminal interface's `R` toggle in the review screen.

```powershell
pwsh -File WindowsTweaker.ps1 -Id Privacy.AdvertisingId -State Disabled -RestartAfterApply
pwsh -File WindowsTweaker.ps1 -Preset explorer-usability -RestartAfterApply
pwsh -File WindowsTweaker.ps1 -Id Privacy.AdvertisingId -RestartAfterApply -WhatIf   # refused
```

`Test-WtRestartRequest` answers "may this invocation restart, and why not"; `Invoke-WtBatchRestart` performs the restart for a finished batch (eligibility, countdown, one request) and returns the outcome separately from the batch result.

### Presets

| Flag | Type | Effect | Example |
|---|---|---|---|
| `-Preset` | string | Apply a preset by shipped/user name or by path to a preset JSON | `-Preset privacy-hardening -WhatIf` |
| `-PresetList` | switch | List shipped and user presets with entry counts | `-PresetList` |
| `-PresetExport` | string | Normalise `-Preset` into a preset file at this path | `-Preset privacy-hardening -PresetExport ./my-preset.json` |

`-Preset` applies every entry through `Invoke-WtTweak`, so `-WhatIf` previews the whole preset. `-PresetExport` requires `-Preset` and refuses to overwrite an existing file (the entry point never passes `-Force`).

### Catalog and packs

| Flag | Type | Effect | Example |
|---|---|---|---|
| `-CatalogList` | switch | Declarative status of every definition (source, scope, risk, lifecycle, evidence, support) | `-CatalogList` |
| `-CatalogFilter` | string[], comma-separated or repeated | Restricts `-CatalogList` | `-CatalogList -CatalogFilter definitions,lifecycle:Experimental` |
| `-CatalogInspect` | string | One definition in full: states, detection map, conditions, side effects, evidence | `-CatalogInspect Privacy.WindowsTips` |
| `-CatalogDimensions` | switch | With `-CatalogInspect`: configured/effective/ownership dimensions and pending-restart evidence | `-CatalogInspect Privacy.WindowsTips -CatalogDimensions` |
| `-CatalogValidate` | string | Validate a catalog or pack document and list every problem | `-CatalogValidate ./samples/example-pack.json` |
| `-CatalogPlan` | string[] | Apply order, prerequisites, conflicts and cycles for ids | `-CatalogPlan Privacy.SearchHighlights,Privacy.BingSearch` |
| `-CatalogMigrations` | switch | Recorded id migrations and preset entries that no longer resolve | `-CatalogMigrations` |
| `-PackList` | switch | Installed packs with version, definition count, hash and enabled state | `-PackList` |
| `-PackInspect` | string | One installed pack, its definitions and stored paths | `-PackInspect WindowsTweaker.Sample` |
| `-PackImport` | string | Validate and store a pack document; adds definitions only | `-PackImport ./samples/example-pack.json -WhatIf` |
| `-PackForce` | switch | With `-PackImport`: replace a pack of the same id. With `-PackRemove`: remove despite un-rolled-back changes | `-PackRemove WindowsTweaker.Sample -PackForce` |
| `-PackNoEnable` | switch | Import without registering the pack's definitions | `-PackImport ./samples/example-pack.json -PackNoEnable` |
| `-PackEnable` | string | Register the definitions of an installed pack | `-PackEnable WindowsTweaker.Sample` |
| `-PackDisable` | string | Unregister them; journal entries stay restorable | `-PackDisable WindowsTweaker.Sample` |
| `-PackRemove` | string | Remove an installed pack and unregister its definitions | `-PackRemove WindowsTweaker.Sample` |

`-CatalogFilter` also accepts `powershell`, `builtin`, `pack[:<pack id>]`, and the `scope:`, `risk:`, `lifecycle:`, `evidence:`, `support:`, `category:`, `tag:`, `requires:`, `conflicts:` prefixes; an unrecognised filter is reported, not ignored.

### Sanity scan, recommendations and exclusive choices

| Flag | Type | Effect | Example |
|---|---|---|---|
| `-SanityScan` | switch | Read-only scan; reports `Clean` only when every required probe answered | `-SanityScan` |
| `-SanityRule` | string[], comma-separated or repeated | Run only these rule ids | `-SanityScan -SanityRule Tcp.LegacyReceiveWindow` |
| `-SanityExport` | string | Write the scan report here; nothing is written without it | `-SanityScan -SanityExport ./scan.md` |
| `-SanityFormat` | `Markdown` (default) or `Json` | Report format for `-SanityExport` | `-SanityScan -SanityExport ./scan.json -SanityFormat Json` |
| `-Recommend` | string: `Balanced`, `Responsiveness`, `Gaming`, `PowerEfficiency`, `Privacy` | Proposal for one objective; nothing is applied | `-Recommend Privacy` |
| `-RecommendManual` | switch | Also list items kept out of automatic selection, with the reason | `-Recommend Privacy -RecommendManual` |
| `-RecommendPreferences` | switch | Also consider preference items (never presented as a performance gain) | `-Recommend Gaming -RecommendPreferences` |
| `-RecommendFinding` | string[] | Sanity rule ids with an observed finding; required for a repair recommendation | `-Recommend Balanced -RecommendFinding Restart.PendingMarkers` |
| `-Choices` | switch | Settings offering alternatives, with the detected alternative and each option's intent | `-Choices` |

See [SANITY-SCAN.md](SANITY-SCAN.md), [RECOMMENDATIONS.md](RECOMMENDATIONS.md), [STATE-DIMENSIONS.md](STATE-DIMENSIONS.md).

### Interface options

| Flag | Type | Effect | Example |
|---|---|---|---|
| *(none)* | - | Terminal interface | `pwsh -File WindowsTweaker.ps1` |
| `-Gui` | switch | Graphical interface instead of the terminal one (Windows only) | `-Gui` |
| `-Language` | `en`, `vi` or a culture name such as `vi-VN` | Interface language for this run | `-Language vi` |
| `-Colour` | `Auto` (default), `TrueColor`, `Ansi256`, `Ansi16`, `Mono` | Palette depth | `-Colour Mono` |
| `-Ascii` | switch | ASCII frame characters instead of box drawing (also forces ASCII icons) | `-Ascii` |
| `-RuntimeReport` | switch | Print the runtime profile, every capability with its reason and the validated range. Read-only, identical on both runtimes | `-RuntimeReport` |
| `-Icons` | `Auto` (default), `Unicode`, `NerdFont`, `ASCII`, `None` | Icon display mode; no font is installed or detected | `-Icons ASCII` |

Language precedence: `-Language`, then the choice saved from the interface, then `WT_LANG`, then the supported UI culture, then English; an unsupported explicit value resolves to English so a typo stays visible. Changing the language never applies a tweak.

### Worker and diagnostics

| Flag | Type | Effect | Example |
|---|---|---|---|
| `-Scan` | string | Aggregate the size of a directory tree (read-only); prints which backend ran | `-Scan 'C:\Users'` |
| `-WorkerBackend` | `Auto` (default), `Go`, `PowerShell` | Background-work backend; `Go` refuses to fall back and reports the capability unavailable | `-WorkerBackend Go -Scan 'C:\Users'` |
| `-InputDiagnostics` | switch | One structured record per key press (text fields masked) in the log file | `-InputDiagnostics` |

Protocol and Windows gaps: [WORKER.md](WORKER.md). `-SanityRule`, `-SanityExport`, `-RecommendManual`, `-RecommendPreferences`, `-RecommendFinding` and `-CatalogDimensions` are refused with exit `2` when their owning command is absent, instead of silently starting the interface; `-SanityFormat` carries a default, so it is not treated this way.

## Exit codes

| Code | Meaning | Evidence |
|---|---|---|
| `0` | Success, unchanged, dry run; every completed read-only command | status mapping `:680-691`; read-only branches `:491`, `:500`, `:512`, `:534`, `:578`, `:614`, `:717`, `:734`, `:779`, `:880`, `:900`, `:931`, `:946`, `:960`, `:973`, `:1107`, `:1133` |
| `1` | Failed or unsupported; failed scan, invalid document, plan errors, pack errors, a sanity scan that is neither `Clean` nor `Findings` | `:561`, `:593`, `:650`, `:804`, `:844`, `:942`, `:951`, `:958`, `:969`, `:1043` |
| `2` | Nothing to do (a status that is neither applied, unchanged nor a dry run), unknown catalog id or pack, empty filter result, usage error, unsupported PowerShell version, or the interface could not start | `:379`, `:386`, `:432`, `:699`, `:727`, `:908`; `Private/Tui/Tui.ps1:2284` for the interface |

The `-Id` mapping (`:680-691`): `succeeded`/`unchanged`/`dryrun` → `0`, `unsupported`/`failed` → `1`, anything else → `2`. An unhandled terminating error, such as an unknown tweak id, leaves through PowerShell's own non-zero code. When the script is dot-sourced or invoked with `&` from a session it does not call `exit`; it returns the code in `$LASTEXITCODE`, so it can never close the caller's shell (`:336-366`).

## Scripted use through the module

```powershell
Import-Module ./src/WindowsTweaker/WindowsTweaker.psd1

Get-WtTweak -Category Explorer                 # catalog (also -Id, -Search)
Get-WtTweakState -Search 'telemetry'           # current state, read-only
Invoke-WtTweak -Id Privacy.AdvertisingId -State Disabled -WhatIf
Undo-WtTweak -Id Privacy.AdvertisingId         # newest captured change, or -HistoryId
Get-WtHistory                                  # audit trail (-TweakId, -Limit, -Raw)
Get-WtPreset                                   # shipped and user presets (optionally -Name)
Export-WtPreset -Entries @(@{ id = 'Explorer.FileExtensions'; state = 'Enabled' }) -Path ./my-preset.json
Export-WtReport -Format Json                   # environment + catalog + history; returns the path
Close-WtSession                                # marks this run's session as ended
```

Every name above is exported by [`src/WindowsTweaker/WindowsTweaker.psd1`](../src/WindowsTweaker/WindowsTweaker.psd1) (`FunctionsToExport`) and by the explicit list in [`WindowsTweaker.psm1`](../src/WindowsTweaker/WindowsTweaker.psm1) (`Export-ModuleMember`). `Invoke-WtTweak` and `Undo-WtTweak` support `-WhatIf`; `Invoke-WtTweak` also takes `-Arguments`, `-IncludeRestorePoint` and `-Origin`, and `Undo-WtTweak` refuses to overwrite a value something else changed unless `-Force` is given. `Export-WtPreset` requires `-Entries` and `-Path` and throws instead of overwriting without `-Force`. `Close-WtSession` returns `$false` when the run recorded nothing, so a read-only run stays read-only; importing the module changes nothing and creates no state or log file.

## Environment variables

All optional; each overrides a default otherwise derived from the data root. The bootstrap script reads its own `WT_BOOTSTRAP_*` variables, documented in [BOOTSTRAP.md](BOOTSTRAP.md).

| Variable | Effect | Read at |
|---|---|---|
| `WT_DATA_ROOT` | Root for state, logs, settings, packs and plans | `Private/Common.ps1:24` |
| `WT_STATE_PATH` | State store file (default `<data root>/state.json`) | `Private/Common.ps1:47` |
| `WT_SETTINGS_PATH` | Interface settings file (language, icon mode) | `Private/Common.ps1:70` |
| `WT_LOG_DIRECTORY` | Log directory (default `<data root>/logs`) | `Private/Common.ps1:84` |
| `WT_LANG` | Language fallback after the saved choice (`en`/`vi`) | `Private/Localization.ps1:170` |
| `WT_PACKS_PATH` | Directory of imported pack documents | `Private/Catalog/Packs.ps1:34` |
| `WT_MIGRATIONS_PATH` | Id migration registry file | `Private/Catalog/Migrations.ps1:41` |
| `WT_RULES_PATH` | Sanity rule registry (default `Data/Insight/rules.json`) | `Private/Insight/Rules.ps1:44` |
| `WT_QUARANTINE_DIR` | Quarantine storage (default `<state dir>/quarantine`) | `Private/Quarantine.ps1:39` |
| `WT_SETUP_PLANS_DIR` | Setup plan storage (default `<state dir>/plans`) | `Private/SetupPlans.ps1:38` |
| `WT_SETUP_USER_ID` | Identity bound into a resume registration | `Private/SetupPlans.ps1:507` |
| `WT_WORKER_PATH` | Explicit worker binary; the worker is never resolved through `PATH` | `Private/Worker/WorkerClient.ps1:38` |
| `WT_TUI_INPUT_TRACE` | `1`/`true`/`yes` enables the key-press trace, as `-InputDiagnostics` does | `Private/Tui/Tui.ps1:2277` |

## State, log and settings locations

| Path | Default | Reported by |
|---|---|---|
| Data root | `%LOCALAPPDATA%\WindowsTweaker` on Windows; `$XDG_STATE_HOME` or `~/.local/state/WindowsTweaker` elsewhere; created only when something is written | `Get-WtDataRoot` |
| State store | `<data root>/state.json` | `Get-WtStatePath`, also printed by `-Status` |
| Log file | `<data root>/logs/wt-<yyyyMMdd>.jsonl` | `Get-WtLogPath`, also printed by `-Status` |
| Settings | `<data root>/settings.json` | `Get-WtSettingsPath` |

## Where to go next

- Pack and catalog document authoring: [CATALOG.md](CATALOG.md), [PACKS.md](PACKS.md).
- Journal, state capture and recovery: [STATE-JOURNAL.md](STATE-JOURNAL.md).
- What is verified, where, and what was never executed on Windows: [VALIDATION.md](VALIDATION.md), [LIMITATIONS.md](LIMITATIONS.md).