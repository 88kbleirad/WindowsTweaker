# Architecture

How the repository is laid out, how the module loads, and which layer owns which
decision. Everything here is derived from the files as they exist; see
[docs/VALIDATION.md](VALIDATION.md) for what was executed and what was not.

## Repository layout

```
WindowsTweaker.ps1                entry point (terminal interface / CLI / -Gui)
src/WindowsTweaker/
  WindowsTweaker.psd1             module manifest (explicit FunctionsToExport)
  WindowsTweaker.psm1             deterministic loader, explicit exports
  Private/                        helpers, providers, engine, interfaces
    Common, Logging, Localization, Environment, State, Tweak, Rollback, Journal,
    Preview, Quarantine, Diagnostics, Measurements, Targets, Privacy, SetupPlans
    Providers/                    Registry, System (service/task/firewall), Dns, Appx,
                                  Defender, Installers, Dism, Power, AdapterPower, Devices
    Catalog/                      declarative catalog, packs, migrations, planner
    Insight/                      sanity rules, recommendations, scan, state, labels
    Observability/                metrics, collector, dashboards, alerts, fleet,
                                  incidents, playbooks, support bundles, persistence
    Worker/                       optional worker client and its PowerShell fallback
    Tui/                          terminal interface (theme, screen, input, dialogs,
                                  icons, workflows, worker, monitor, main loop)
  Public/                         exported API (catalog, tweaks, presets, reporting,
                                  observability, setup plans, verification, worker)
  Tweaks/<Category>/*.ps1         tweak definitions (metadata + operations)
  Data/Catalog/                   builtin.json, catalog.schema.json, migrations.json
  Data/Insight/rules.json         sanity-rule declarations (read-only probes)
  Data/Presets/*.json             shipped presets
  Data/Privacy/                   privacy metadata
  Data/Strings.<lang>*.psd1       localization (en reference + vi, split by feature)
  Gui/                            optional WPF interface (XAML + Gui.ps1)
tests/                            Pester suite (engine, providers, CLI, GUI, TUI, ...)
tools/                            Parse-All, Test-Catalog, Test-Insight, Test-Compatibility,
                                  Invoke-Validation, New-FeatureInventory, New-ReleasePackage,
                                  Measure-WtWorker
.github/workflows/release.yml     tag-triggered release: package, validate, upload the six assets
docs/                             catalog, packs, worker, state journal, validation,
                                  limitations, dependencies, keyboard, and the notes here
bootstrap/bootstrap.ps1           published launcher: pure ASCII, no BOM, loads the implementation
                                  as bytes, decodes UTF-8, forwards options, mirrors $LASTEXITCODE
bootstrap/implementation.ps1      installer implementation (5.1-parseable, UTF-8 BOM): runtime policy,
                                  discovery, handoff, installation offer, release verification
src/WindowsTweaker/Private/Compatibility.ps1
                                  one runtime layer: profile, capabilities, BOM-less UTF-8,
                                  portable JSON, pwsh discovery, console VT enable/restore
src/WindowsTweaker/Private/Catalog/Json.ps1
                                  portable strict JSON parser (duplicate keys, depth, kinds)
deploy/short-url/                 nginx config for the short download URL (prepared only)
worker/                           optional Go worker: cmd/wt-worker, internal/, go.mod, bin/
samples/example-pack.json         example tweak pack for the catalog/pack switches
licenses/                         verbatim licence texts (upstream MIT, Go worker modules)
artifacts/monitoring/             sample scrape config, Grafana dashboard, sample data
reference/                        upstream reference material (never executed)
THIRD-PARTY-NOTICES.md            third-party attributions
PSScriptAnalyzerSettings.psd1     static-analysis settings
```

## Loading order and layering

`src/WindowsTweaker/WindowsTweaker.psm1` is a loader, not a place for logic.

1. The load order is built from sorted directory listings (`WindowsTweaker.psm1:49-60`):
   `Private/*.ps1`, `Private/Worker`, `Private/Observability`, `Private/Catalog`,
   `Private/Insight`, `Private/Providers`, `Private/Tui`, `Public`, `Tweaks/**`
   (recursive), then `Gui`.
2. **Every file is parsed before any file is dot-sourced** (`WindowsTweaker.psm1:65-76`):
   first `Assert-WtScriptParses` over the whole list, then the dot-source loop. A syntax
   error therefore aborts the import loudly instead of dropping that file's definitions.
3. Files are dot-sourced in module scope (`WindowsTweaker.psm1:71-76`), so the functions
   they define live in the module, not inside a helper function's scope.
4. After the definitions exist, `Initialize-WtCatalog` registers declarative tweaks, then
   registered packs, then migrations, then sanity rules (`WindowsTweaker.psm1:83-145`).
   Registration is metadata only; nothing is detected or mutated here.
5. The public surface is an explicit list, handed to `Export-ModuleMember`
   (`WindowsTweaker.psm1:147-268`, `270-272`). Everything not listed stays private.

Why the order matters: PowerShell reports a parse error as a non-terminating error and
still loads the module, minus that file's definitions. Parsing everything up front turns
the silent "undefined function" failure mode into a hard import failure - the behaviour
`Assert-WtScriptParses` documents (`WindowsTweaker.psm1:33-47`) and that
`tests/Loading.Tests.ps1` asserts ("fails loudly when a module file has a syntax error").

## Layers: who owns what

| Layer | Location | Responsibility | Read-only |
|---|---|---|---|
| Providers | `Private/Providers/*` | touch one Windows surface (registry, service, task, firewall, DNS, Appx, Defender, DISM, installers, power); every mutation goes through a `ShouldProcess`-gated function | no (detectors are) |
| Tweak definitions | `Tweaks/<Category>/*.ps1`, `Data/Catalog/builtin.json` | declare metadata, a read-only detector and the per-state operations; no ad-hoc system access | yes |
| Engine | `Private/Tweak.ps1`, `Private/Rollback.ps1`, `Private/Journal.ps1`, `Private/State.ps1`, `Private/Catalog/*` | capture previous state, execute, verify by reading back, journal, roll back | no |
| Interfaces | `Private/Tui/*`, `Gui/`, the CLI switch block in `WindowsTweaker.ps1` | present, review, confirm; never write directly | yes |

A change flows one way: interface -> engine -> provider. A new tweak belongs at the
**tweak-definition** layer (or as a catalog document); it never reaches a provider
directly. The metadata contract, the operation kinds and the provider list are in
[docs/MIGRATION-SPEC.md](MIGRATION-SPEC.md); the catalog and packs are in
[docs/CATALOG.md](CATALOG.md) and [docs/PACKS.md](PACKS.md).

## Adding and validating a tweak

Write the definition under `Tweaks/<Category>/` (or add a namespaced pack / catalog
document), then check it with the repository tools - one line each, no numbers copied
here (results are recorded in [docs/VALIDATION.md](VALIDATION.md)):

* `tools/Parse-All.ps1` - PowerShell AST-parses every script and fails on a syntax error.
* `tools/Test-Catalog.ps1` - checks catalog invariants (duplicate ids, conflicting writers,
  detection pass) without touching the system.
* `tools/Test-Insight.ps1` - checks the invariants that span documents (rules, exclusive
  groups, recommendation links).
* `tools/Invoke-Validation.ps1` - runs the complete validation suite and prints a report.

## The Go worker

The optional worker lives in `worker/` (`cmd/wt-worker`, `internal/{protocol,server,scan,
metric,store,exporter}`) and is reached through `Private/Worker/*` plus the exported
`*-WtWorker*` commands. It is a bounded, protocol-driven helper: it **never** owns the
change engine, the state journal or rollback - it serves scans, metrics and the
single-writer metrics store. Build, protocol, capabilities and the Windows gaps are in
[docs/WORKER.md](WORKER.md).

## Import-time purity

Importing the module must not mutate anything: tweak files only register metadata, and no
detection, preview or write runs at import time. `tests/Loading.Tests.ps1:31-77` enforces
this - it asserts that an import creates no data directory and no `state.json`, and that a
full detection pass invokes no provider mutation.
