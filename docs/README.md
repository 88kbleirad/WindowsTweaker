# Documentation

Start with the [README](../README.md) (Tiếng Việt) or [README.en.md](../README.en.md) (English) for
what the tool is and how to run it. Each document below is self-contained and states what was
verified on Linux and what was never executed on Windows; [docs/VALIDATION.md](VALIDATION.md) holds
the evidence and the list of unexecuted checks.

## Run, configure and automate

| Document | Content |
|---|---|
| [COMPATIBILITY.md](COMPATIBILITY.md) | Which PowerShell runtimes start the bootstrap, which run the application natively, which features need a newer runtime, and exactly what was executed |
| [BOOTSTRAP.md](BOOTSTRAP.md) | The `irm \| iex` launcher: runtime policy (5.1 native, 7.4-7.6 handoff, installation offer), verification, overrides, security notes, release archives - and the fact that **nothing is hosted today** |
| [CLI.md](CLI.md) | Every entry-point switch, exit codes, the exported module API, environment variables and where state/log/settings live |
| [KEYBOARD.md](KEYBOARD.md) | Every key, dialog, row marker, icon mode and layout, in English and Vietnamese |
| [DEPENDENCIES.md](DEPENDENCIES.md) | PowerShell version, terminal requirements, Windows-only modules per feature, and what happens when one is missing |

## Tweaks, catalogs and packs

| Document | Content |
|---|---|
| [CATALOG.md](CATALOG.md) | Declarative catalog documents: format, strictness rules, capability-loss disclosures, dependencies, evidence, migration registry |
| [PACKS.md](PACKS.md) | Tweak packs: namespace rule, import/enable/disable/remove, storage, recovery after removal |
| [FEATURE-INVENTORY.md](FEATURE-INVENTORY.md) | Every tweak with its category, scope, privileges, risk, restart, rollback, plus the legacy-module mapping |
| [MIGRATION-SPEC.md](MIGRATION-SPEC.md) | The contract for writing a tweak definition (metadata, states, operations, detection) |

## State, recovery and limits

| Document | Content |
|---|---|
| [STATE-JOURNAL.md](STATE-JOURNAL.md) | Journal schema, durability and locking, verification and compensation, drift and interrupted operations, session close |
| [LIMITATIONS.md](LIMITATIONS.md) | The safety model with its exact scope, then every known limitation, partially reversible action and platform gap |

## Diagnostics and recommendations

| Document | Content |
|---|---|
| [SANITY-SCAN.md](SANITY-SCAN.md) | The read-only sanity scan: rules, probe vocabulary, outcomes, sources, reporting, coverage |
| [RECOMMENDATIONS.md](RECOMMENDATIONS.md) | Recommendation policy: kinds, engine floors, objectives, decision explanations, why nothing is applied automatically |
| [STATE-DIMENSIONS.md](STATE-DIMENSIONS.md) | Configured vs effective vs ownership, evidence kinds, restart boundaries, pending-restart markers |

## Observability

| Document | Content |
|---|---|
| [MONITORING.md](MONITORING.md) | Dashboards, metric contract, bounded history, SQLite recording, interval comparison, alerting - and what is wired vs declared |
| [MULTI-HOST.md](MULTI-HOST.md) | Fleet, incident workspace, playbooks, support bundles and versioned monitoring configuration, with an explicit status table |

## Internals and validation

| Document | Content |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Repository layout, load order, layer ownership, how to add and validate a tweak |
| [WORKER.md](WORKER.md) | The optional Go worker: protocol, capabilities, concurrency and memory bounds, build and packaging, licence position |
| [VALIDATION.md](VALIDATION.md) | Exactly which checks were executed (with results), what the Pester suite covers, and which Windows integration checks were **not** run |

## Working notes

`benchmarks/` holds worker measurement output and `migration-notes/` the per-batch records of the
legacy migration (historical; the legacy `modules/` tree itself has been removed).