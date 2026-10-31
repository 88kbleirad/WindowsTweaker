# Known limitations

Honest list of what this tool does not do, cannot do reliably, or cannot prove in this
environment. Nothing here is hidden behind a success message.

## Safety model and its scope

These are the guarantees the tool makes, and their exact scope; each one names what is
enforced and how, so the limits below can be read against it.

| Guarantee | How it is enforced |
|---|---|
| Importing the module changes nothing | Tweak files only register metadata; a test asserts that no provider mutation runs during import and that no state/log file is created |
| Initialisation is read-only | `Get-WtEnvironment` only reads (version, elevation, OS build, pending reboot, cmdlet availability). All mutating startup logic from the previous revision was removed |
| Selecting a row changes nothing | The interface keeps a pending set; `A` reviews the exact changes and only a confirmation applies them. Every mutation goes through `Invoke-WtTweak`/`Undo-WtTweak` in a worker runspace |
| `-WhatIf` writes nothing | Providers gate every mutation with `ShouldProcess`; a dry run enumerates *which* operations would run and reports them as `dryrun`, and never captures state. The interface's `W` preview uses the same path |
| Rollback restores what was captured, not a default | The previous registry value **and its kind and existence**, service start type/state, scheduled-task state, firewall-rule state, per-adapter DNS list and Defender preference are stored before the change and replayed in reverse. Targets with no read-back reader are recorded as *unverifiable* |
| Irreversible actions are labelled | Package removal, OneDrive uninstall, installer downloads and data deletion are separate tweaks with `-Irreversible`/`-DataDeletion`, `Rollback = None` and an impact text that says what is lost |
| Failures are never reported as success | Every operation returns `succeeded`, `unchanged`, `skipped`, `unsupported`, `dryrun` or `failed`; verification reads the value back, native processes have their exit codes checked, and the result panel repeats every status verbatim |
| Organization policies are visible | Tweaks declare the policy values that govern them; state reports `Managed`/`ManagedBy` and every interface shows it |
| Protection is not reduced | Nothing disables Defender, Controlled Folder Access, SmartScreen, UAC prompts or security logging at startup or as a side effect. Protection-reducing tweaks exist only as explicit, `-Risk High`, `-ReducesProtection`-flagged entries that are never applied automatically, and shipped presets exclude them |
| User data is preserved | Uninstalling software and deleting data are separate tweaks. OneDrive user files are untouched by the OneDrive tweaks, and package removal deletes package data only for the packages you explicitly selected |
| No code execution shortcuts | No `Invoke-Expression`, no download-and-execute, no executables copied into `System32` (the previous `powershell_temp.exe` trick is gone), no inline C# |
| Downloads are verified | `Get-WtVerifiedDownload` requires `https://`, runs only outside a dry run, validates the Authenticode signature against an expected publisher and refuses the file otherwise |

## Validation limits (this archive)

* **Windows execution was not validated.** The archive was developed and validated on
  Linux with PowerShell 7.6.9: static analysis, catalog invariants, the Pester suite
  (471 tests), the entry point, the terminal interface (head-less, in a real pty) and
  dry-run/rollback logic against in-memory provider doubles. Real registry, service, task,
  firewall, DNS, Appx, Defender and DISM behaviour, and the WPF interface, were **not**
  executed. See `VALIDATION.md` for the exact list.
* **The WPF interface could not be rendered or clicked through here.** XAML well-formedness
  is checked; WPF schema validity, layout, icons and dialogs are not.
* **Windows 10 22H2 behaviour is inferred** from the tweaks' own declarations and the
  upstream implementations. Only the declarations were tested, not the OS behaviour.
* **The terminal interface was validated on Linux only.** Key delivery, frame addressing
  and the pty runs were real, but conhost without virtual terminal support, legacy console
  code pages and a Windows console font were not. The fallbacks for those cases are
  implemented and unit-tested; their appearance on Windows is not.

## Terminal interface limits

* **The interface refuses a non-interactive terminal.** If stdin or stdout is redirected
  (a pipe, a scheduled task, an IDE output pane) there is no way to read keys, so it exits
  with code `2` and points at the CLI switches instead of hanging. This is deliberate.
* **A resize is picked up on the next key poll** (up to ~40 ms), not instantly: the input
  loop polls instead of blocking so that a resize and a finished worker are both noticed.
* **Colour and frame fidelity follow the terminal.** Automatic reduction is
  true colour -> 256 -> 16 -> none, and the frame falls back to ASCII when the output
  encoding is not UTF-8; a terminal that misreports its capability needs `-Colour` /
  `-Ascii` to be corrected by hand.
* **Icons never replace text, and no font is detected.** Whether the terminal font has the
  glyphs of the active mode cannot be established without drawing them, so the interface
  draws a preview (`I`) rather than claiming detection, and every icon is accompanied by its
  label. In `NerdFont` mode an unpatched font draws boxes; `Unicode`, `ASCII` and `None` are
  one keystroke away. No font is ever installed and no terminal setting is ever changed.
* **A few Unicode icons are East-Asian-Ambiguous width.** The set avoids Wide and Fullwidth
  characters and keeps every glyph in one cell of the width model, exactly like the
  box-drawing frame the interface already uses; a terminal that renders ambiguous
  characters as double-width (`◆`, `○`, `△`, `■`) will misalign them. `-Icons ASCII` or
  `None` avoids that entirely.
* **The icon column is a budget, not a guarantee.** A pane that cannot hold the icon slot,
  the widest count and a readable label draws no icons (per pane, not globally), so a
  narrow terminal or the 7-cell ASCII tags can leave a pane icon-free.
* **The optional worker has not run on Windows.** Its Windows binaries are cross-compiled and
  `go vet`-checked only. The Windows-specific gaps are listed in `docs/WORKER.md`: allocation
  size, hard-link identity, reparse points, long/UNC paths and process-tree termination.
* **The worker is one capability deep.** Only `scan.directory` is implemented and advertised;
  hashing and network diagnostics are planned, not built, and are never reported as available.
* **Backend results differ in two documented ways.** The PowerShell implementation cannot
  report allocated size or deduplicate hard links (both are stated in the result notes), so a
  cross-backend comparison must compare the fields that both can produce.
* **The benchmark does not control the page cache.** Evicting it needs root, so "cold" means a
  fresh process after a re-created tree, not a guaranteed uncached read, and the numbers are
  labelled accordingly.
* **Compensation is not atomic rollback.** Windows offers no transaction spanning the
  registry, services, tasks, DNS, packages and Defender. After a partial failure the tool
  attempts to put the already-changed targets back, reports each target separately, reports
  compensation failures separately, and always keeps the captured recovery data - it never
  claims the operation was atomic.
* **Read-back verification covers the target kinds that have a reader**: registry values,
  registry keys, Defender preferences and per-adapter DNS. Service, scheduled-task,
  firewall-group and Appx targets are recorded as *unverifiable* and are never reported as
  verified.
* **Drift is a comparison, not a diagnosis.** The recorded Windows build is shown as context
  when it changed; the tool never asserts that a build change caused a drift, and it never
  reapplies a tweak on its own.
* **A corrupt state store stops the tool by design.** It is reported as an error, every write
  refuses to overwrite it, and the file has to be repaired or moved aside deliberately. The
  schema-1 to schema-2 migration happens in memory on read and is persisted by the next write.
* **Cancellation cannot interrupt a native operation that is already in flight.** Queued
  items are dropped immediately; a running DISM call, `Remove-AppxPackage` or service stop
  finishes at its safe boundary, and the interface says so rather than claiming it stopped.
* **Progress is item counts, never a percentage.** Inside one item there is no observable
  progress for those native tools, so the panel shows the active item and the counts of
  items that actually completed.
* **One operation at a time.** Applying and rolling back share a single worker runspace, so
  two conflicting modifications can never interleave; a second request while one runs is
  refused with a message.
* **The worker imports the module in its own runspace**, so a run costs one extra module
  import (~1 s) before the first item. Progress therefore starts with `Item 1 of N` rather
  than instantly.
* **Preset descriptions are single strings**, not localized pairs, so a preset carries its
  description in the language it was authored in (both shipped presets are English).
* **A pending set lives only in the running session.** Exporting it as a preset is the way
  to keep it; quitting discards it after an explicit confirmation.

## Rollback fidelity

| Situation | Reality |
|---|---|
| Recursive registry-key deletion | The subtree is captured with bounded depth (3) and a key cap (256). If the subtree is larger, the capture is marked truncated, the operation reports partial rollback, and a later rollback fails loudly for that key instead of restoring half of it |
| Registry value kind unknown | On Windows the provider reports the kind; if a value's kind cannot be determined it is inferred from the .NET type and the rollback logs a warning naming the inferred kind |
| Removing an app package, uninstalling OneDrive, importing file associations | **Irreversible.** These are separate tweaks marked `Rollback = None`, `-Irreversible`/`-DataDeletion`, and they state what is lost. There is no "restore my files" path - removed packages must be reinstalled from the Microsoft Store |
| Firewall changes | Rules are changed per *group*. Rule names and membership change between Windows builds; a build that renamed a rule group makes the operation report `unsupported` (no rules found) rather than altering something else |
| Service start type round-trip | `AutoStart`/`Auto` is normalised to `Automatic`; `AutomaticDelayedStart` cannot always be restored exactly through `Set-Service`, in which case the rollback result says so |
| DNS-over-HTTPS registry layout | Written per interface GUID under `Dnscache\InterfaceSpecificParameters`. The `DohFlags` semantics (2 = use the stored template, 5 = resolver default) come from upstream practice, not from a published contract; a build that changes this layout is not detected automatically |
| Emulated/managed state | State is stored per user profile (`%LOCALAPPDATA%`). Tweaks applied from another account, or by another tool, are not in this store and cannot be rolled back here |

## Functional gaps

* **No "disable Windows Update permanently" feature.** The legacy menu promised one and
  never implemented it. Both interfaces are now catalog-driven, and only real, revertible
  update preferences (deferral/notification behaviour, Microsoft Update) are ported.
* **Taskbar shortcut unpinning is not ported.** It requires shell COM verbs and either
  user-data deletion or rewriting an opaque Explorer binary blob; neither can be done
  reversibly through the providers, so it is documented as not ported rather than
  approximated.
* **Controlled Folder Access is never disabled by initialisation.** The legacy startup
  did exactly that; the behaviour was removed and replaced with an explicit
  `Security.ControlledFolderAccess` tweak that enables or disables it only on request.
* **Localization covers English and Vietnamese only.** Missing keys fall back to
  English, then to `[Key]`, and each miss is logged once.
* **Managed-policy detection is presence-based.** A declared policy value existing counts
  as "managed"; the tool does not evaluate policy precedence or Group Policy refresh.
* **Associations import/export** are file-based and depend on the UserChoice hash
  algorithm, which Microsoft changes; importing associations is therefore irreversible
  for the previous values.
* **Nothing is applied automatically.** A preset only fills the pending changes; loading
  one applies nothing, and every change is applied through an explicit
  `Invoke-WtTweak`/`-Id` call after a confirmation. Protection-reducing tweaks are excluded
  from the shipped presets.
* **State store growth** is bounded (the oldest entries are dropped past ~400 records);
  dropped entries can no longer be rolled back.
* **A corrupt state store stops changes instead of being overwritten.** The file is left
  untouched so captured rollback data is not destroyed; repair or move it to continue.

## Declarative catalog, packs and the migration registry

* **Migrated definitions were not run on Windows.** `Privacy.DismissMSAccount`,
  `Privacy.LanguageListAccess` and `Privacy.WindowsTips` are now declared in
  `Data/Catalog/builtin.json`. Their documents were validated structurally, their detection maps and
  operation lists are asserted by `tests/Catalog.Tests.ps1`, and their target identities are compared
  with an equivalent PowerShell definition - but no Windows host was available, so their
  `windowsIntegration.result` is `Unverified` and their `method`/`limitations` say so. Reading them
  back on a real Windows 11 build is the next check, not a completed one.
* **Conditions are recorded, not enforced, except two.** The engine evaluates `supportedOS` and
  `minBuild`. `maxBuild`, `editions`, `architecture` and `hardware` are stored and reported in
  `Get-WtTweakDefinition` and in the details pane as *recorded but not enforced*; they are never
  treated as satisfied, and nothing silently drops a definition because of them.
* **No JSON Schema library is used.** `catalog.schema.json` is the normative description for
  authors, and a test keeps its enums, key lists and bounds equal to the loader's constants. The
  loader itself validates in PowerShell and never resolves a `$ref`, so a document that the schema
  would accept through a reference the loader does not implement is still refused.
* **String tables are split by feature and cannot be merged back.** `Import-PowerShellDataFile`
  refuses a hashtable literal with more than 500 entries, so the interface strings live in
  `Data/Strings.<lang>.psd1` plus `Data/Strings.<lang>.catalog.psd1`, merged at load. Moving keys
  back into one file makes the module fail to import with a "dynamic expression" error - an error
  that does not mention the limit.
* **Packs are not signed.** A pack records the SHA-256 of the document it imported and refuses to
  enable a stored document that no longer matches, which detects later edits but does not prove
  authorship. Import only packs whose source you trust, and read the document first - it is plain
  JSON and the interface can show every definition before anything is registered.
* **Pack management is a command-line surface.** The terminal interface lists installed packs in
  the Overview details and can filter the catalog by pack (`@pack:`), but importing, enabling,
  disabling and removing are done with the `-Pack*` switches. That is deliberate: importing writes
  files, and the interface has no file picker for it.
* **The migration registry is empty.** No shipped id has ever been renamed, so
  `Data/Catalog/migrations.json` carries no records. The behaviour (alias resolution on lookup,
  retired ids, journal provenance, cycle rejection) is covered by `tests/Catalog.Tests.ps1` with
  temporary registries.

## Sanity scan, recommendations and choice groups

* **No rule has been run on Windows from this archive.** The scan logic, its probe results and its
  outcomes are covered by tests against doubles; the documented claims come from Microsoft pages
  (links in [docs/SANITY-SCAN.md](SANITY-SCAN.md)) and were not re-verified against a live build.
* **There is no power-plan rule.** The device- and AC/DC-dependent mapping could not be verified to
  the standard this rule set requires, so the area is left out instead of filled with folklore.
* **The scan measures nothing.** It reports configuration and the documented relationships behind a
  finding; it never reports a throughput, latency or frame rate.
* **Two rules are manual by design.** MMCSS task values and static TCP window sizes cannot be
  repaired by the engine, because the scan cannot know why they were set, and the boot configuration
  is outside what the preview/journal/recovery engine can capture and restore.
* **Effective states are mostly `Unknown` on purpose.** Configuration is not behaviour: only a
  definition that declares how its behaviour was established can report `Observed`, and no shipped
  definition does, because that would require an observation on a real build.
* **Restart boundaries are inferred from the definition.** Explorer and sign-out boundaries are
  declared per definition; the engine does not watch the component to confirm that it re-read the
  value.
* **Choice-group mappings are inherited.** The group adds exclusivity, intent and validation to an
  existing mapping; `LaunchTo=3` (Downloads) is not documented by Microsoft and the definition says
  so.
* **Pack-provided groups are validated like any other document**, but a pack cannot be prevented from
  describing an alternative that means nothing on a future Windows build. Read the document before
  importing it.

## Unreviewed material

* `reference/original-upstream-reference.txt` is upstream reference material kept for
  review. It is **never executed** and no tweak definition may be copied from it without
  the review described in `MIGRATION-SPEC.md`. It contains unsafe patterns (download and
  execute, recursive user-directory deletion, System32 executable copies, disabling
  Controlled Folder Access at startup) that are explicitly not part of this tool.

## Not covered by these additions

* No power-plan rule: the device- and AC/DC-dependent mapping could not be verified to the
  standard this rule set requires, so the area is left out rather than filled with folklore.
* No measurement of behaviour: the scan and the dimensions report configuration and documented
  relationships. Effective states are `Observed` only when a probe read the live behaviour or a
  Windows-validated observation is recorded for the build; everything else is `Inferred` or
  `Unknown`. No frame rate, latency or throughput is ever claimed.
* The boundary probes that read Windows (last boot time, File Explorer process start, interactive
  logon session) are exercised through fakes in the automated tests; the real reads are
  unexecuted on this Linux host and belong in a disposable Windows VM.
* The repair definition `Mmcss.SystemResponsiveness` writes the documented shipped value and
  declares `WindowsIntegration.result: Unverified`; its mapping is documented, not observed.

## Limitations of the added surface

* **Capability-loss disclosures** are declarations; conditional impacts whose condition
  cannot be probed are labelled conditional, never satisfied. The engine never infers that
  an installed feature is unused.
* **Disk-usage explorer** reports logical sizes (allocated only where the backend knows
  it) and never claims scanned bytes are reclaimable. The PowerShell fallback cannot
  identify hard links or allocation, and special files may be reported as files; the Go
  worker deduplicates hard links and skips links/reparse points by default. A scan is
  cached per visited directory (bounded); stepping into a new directory runs one fresh
  listing.
* **Quarantine** only supports same-volume moves; cross-volume candidates are skipped with
  an explanation, never copied and deleted. Restore refuses silent overwrites; a record
  whose quarantined content is missing stays unresolved for retry. Deletion is explicit
  only; expiry only flags for review.
* **Device inventory** depends on CIM (`Win32_PnPSignedDriver`) on Windows; on other hosts
  it reports itself unavailable. Non-present devices keep the OS-reported error code and
  are never labelled unused. Driver Store packages are listed separately with no invented
  device-to-package correlation.
* **Setup plans** apply only existing catalog tweak ids/states. Resume registrations are
  identity-bound (plan hash, user, app version, execution path) and tampering is refused.
  Steps whose outcome is uncertain are never retried automatically; reboot counts are
  bounded.
* **Privacy activity views** (camera, microphone, location, screen capture) and **SRUM
  history** report themselves Unavailable on this build because no documented, supported
  public API exists for PowerShell 7; no fabricated log or counter is produced, and no
  service is enabled and no database is cleared to populate them.
* **Power settings explorer** reads `powercfg` only and never imports or replaces plans;
  it reports the active plan identity and AC/DC values read-only.


## Monitoring workspace limitations

* Windows collection is powered by PowerShell CIM providers (CPU/memory/disk/uptime and
  network counters); the Go worker reports unsupported there by design. None of that has
  been executed on a real Windows host in this archive — it must be validated in a
  disposable Windows VM.
* GPU, temperature, SMART and similar sensors are never reported: no reliable provider
  exists here, and no kernel driver is installed.
* History and alerts are in-memory and bounded by default. SQLite metric recording is opt-in and
  disabled until you enable it (see [MONITORING.md](MONITORING.md)). The worker contains a
  Prometheus exporter, but it is **not yet wired end to end**: nothing in the interface or the
  module feeds it, so a started exporter serves an empty registry - do not treat the sample
  Grafana dashboard in `artifacts/monitoring/` as a working pipeline.
* Counter rates are computed by the collector from monotonic elapsed time; wall-clock
  changes do not corrupt ordering, and no rate crosses a reset.
* The overhead measurement (29.6 ms/cycle PowerShell, 48.4 ms/cycle Auto with the Go
  worker on this host) is a condition snapshot, not a guarantee.


## Observability iteration limitations

* SQLite persistence is worker-owned; the database is created only after the first write
  cycle (the stats probe opens it). A corrupt/locked/full database yields stable codes;
  the store becomes read-only and queries fail rather than fabricating data.
* The Grafana dashboard and scrape config are installation-independent artifacts; they have
  not been imported into a live Grafana/Prometheus in this environment. Verify them in a
  disposable VM with real Prometheus/Grafana before relying on them.
* Alert-history transitions are stored but not surfaced as a list UI beyond the current
  alert view; external notifications remain deferred by design.
* Remote Prometheus integration uses curated query templates only; arbitrary query editing
  is intentionally not offered.
* OpenMetrics/format details follow the official Prometheus client defaults; no
  non-loopback exposure or authentication is implemented yet.


## Multi-host / incident / playbook / support-bundle limitations

* Fleet view depends on explicitly configured Prometheus data sources. Target discovery
  uses only `label_values(up, instance)` and per-instance `up`; anything the source does
  not expose is simply absent. A failed scrape never proves a host is off.
* The incident timeline merges local journal/drift/collector evidence with alert state.
  Remote journal events are never fabricated from aggregate counters. Clock alignment
  across sources is best-effort; timestamp uncertainty is flagged, not hidden.
* Playbooks are read-only and run only allowlisted probes. No Fix All exists; any change
  must go through the existing review/journal/recovery flow.
* Support bundles use best-effort redaction; hashes verify contents, not origin. Bundle
  import treats everything as historical, untrusted, offline evidence.
* Configuration revisions are append-only snapshots; reverting a configuration never
  changes Windows settings and never rewrites historical alert decisions.
* Windows-specific collection and real multi-host Prometheus checks (including a live
  Grafana import) require a disposable Windows VM and were not executed here.


## Measured worker overhead (conditions on this host)

- Fleet refresh with an unreachable data source: ~116 ms per forced refresh (failure
  path; caches 10 s). A healthy source adds one bounded query per target.
- A read-only playbook execution (network symptom, 4 probes, no monitor data): ~172 ms.
- Monitor rendering without new views: unchanged from prior iteration (~30-50 ms per
  drawn frame; first update amortized).
- Support-bundle export of a small sanitized set: < 50 ms; import of a 4-entry zip
  < 20 ms.

These are condition snapshots, not guarantees; tune via cache/interval settings.
