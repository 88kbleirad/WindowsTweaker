# Declarative catalog

The catalog is the data behind the engine: a JSON document describes *what* a tweak detects and
*writes*, and the existing engine does the rest. Detection, preview, the review fingerprint, the
journal, post-write verification, compensation and rollback are the same code paths a tweak
written in PowerShell uses - there is no second mutation engine, no second journal and no second
recovery store.

| Where | What |
|---|---|
| `src/WindowsTweaker/Data/Catalog/builtin.json` | The shipped catalog. Loaded at module import. |
| `src/WindowsTweaker/Data/Catalog/catalog.schema.json` | Normative JSON Schema for authors. The loader does not use it; a test keeps it in sync with the loader. |
| `src/WindowsTweaker/Data/Catalog/migrations.json` | Stable-ID registry (renames, replacements, retirements). |
| `src/WindowsTweaker/Private/Catalog/Catalog.ps1` | Constants, boundaries and the strict JSON reader. |
| `src/WindowsTweaker/Private/Catalog/CatalogLoader.ps1` | Validation and registration. |
| `src/WindowsTweaker/Private/Catalog/Planner.ps1` | Dependency planning (`requires`, `runAfter`, `conflictsWith`). |
| `src/WindowsTweaker/Private/Catalog/Migrations.ps1` | Alias resolution and migration validation. |
| `src/WindowsTweaker/Data/Presets/` | Presets keep referring to tweak ids; a renamed id still resolves. |

## Capability-loss disclosures (`capabilityLoss`)

A tweak may declare what may stop working after it runs:

```json
"capabilityLoss": [
  { "capability": "power.hibernation",
    "names": { "en": "...", "vi": "..." },
    "kind": "Guaranteed | Conditional | Unknown",
    "temporary": false,
    "condition": { "explanation": { "en": "...", "vi": "..." },
                   "requiresCapabilities": ["Cmdlet:..."] },
    "restoredBy": { "en": "...", "vi": "..." },
    "limitations": { "en": "...", "vi": "..." } }
]
```

Rules: ids are stable, lowercase `a-z0-9._-`; duplicate ids within one definition are
refused; only Conditional impacts carry a condition; a condition's capability tokens are
probed on the machine (unreadable probes keep the impact conditional); packs may add
disclosures but never suppress engine-owned warnings; the review deduplicates by id and
names every causing action.

## What a document is

Documents are **data**. Nothing in a document is evaluated, downloaded or resolved: there are no
expressions, no script blocks, no commands, no remote `$ref`, no URLs that are fetched. Loading a
document registers metadata and nothing else - it never reads or writes Windows.

```json
{
  "schemaVersion": 1,
  "kind": "Catalog",
  "id": "builtin",
  "version": "1.0.0",
  "minEngineVersion": "1.0.0",
  "tweaks": [
    {
      "id": "Privacy.DismissMSAccount",
      "revision": 1,
      "category": "Privacy",
      "names":        { "en": "...", "vi": "..." },
      "descriptions": { "en": "...", "vi": "..." },
      "impacts":      { "en": "...", "vi": "..." },
      "sideEffects":  { "en": "...", "vi": "..." },
      "scope": "User",
      "lifecycle": "Available",
      "risk": "Low",
      "restart": "None",
      "rollback": "Full",
      "irreversible": false,
      "dataDeletion": false,
      "reducesProtection": false,
      "requiresCapabilities": ["Cmdlet:Get-ItemProperty"],
      "detection": { "hive": "HKCU", "key": "Software\\...", "name": "ValueName", "map": { "Dismissed": [1], "Shown": [0] } },
      "states": {
        "Dismissed": [ { "kind": "RegistrySet",    "hive": "HKCU", "key": "Software\\...", "name": "ValueName", "type": "DWord", "value": 1 } ],
        "Shown":     [ { "kind": "RegistryRemove", "hive": "HKCU", "key": "Software\\...", "name": "ValueName" } ]
      },
      "defaultState": "Dismissed",
      "evidence": { "documentation": ["ms-doc"], "windowsIntegration": { "result": "Unverified" } }
    }
  ]
}
```

Full field list, enums and bounds: `catalog.schema.json`. The important parts:

* **`detection`** is the value Windows writes for each state, and it is what review and verification
  read. A value that is *absent* is reported as `Unknown` with the registry path - never guessed.
* **`states`** are complete on their own: every state lists every operation needed to reach it,
  including removing a machine-wide policy value that would otherwise override the setting.
* **`RegistryRemove`** takes no `type` and no `value`. A restore never replays a written value; it
  replays the captured state.
* **Localized text** is required in `en` and `vi`. Internal ids are language-independent.

## Strictness rules

A malformed or hostile document fails loudly and cheaply, before anything is registered:

| Rule | Why |
|---|---|
| Byte size (256 KiB), nesting depth (32), string length (4096), tweaks (256), states (8), operations (16), errors reported (100) | A document that needs more is not a document, it is a dataset. |
| Duplicate JSON property names are an error | A plain conversion keeps the last one, which is exactly how a definition can be smuggled past review. |
| Unknown top-level or per-tweak keys are errors | A typo must not silently do nothing. |
| Unknown `schemaVersion`, `kind`, operation kind, hive, view, registry type, enum value | No defaults are invented for the caller. |
| `privilege` must match `scope` (`User` → `None`, anything else → `Admin`) | A definition cannot declare a machine-wide change as unprivileged. |
| `risk` must be at least `High` when `irreversible`, `dataDeletion` or `reducesProtection` is set | The floor is derived, not declared. |
| Operation targets are canonicalised through the target layer | A catalog definition and a PowerShell definition of the same value cannot describe two different targets. |
| Two operations writing the same target in one state are an error | States must be deterministic. |
| `detection.map` may only name declared states | Detection and states cannot drift apart. |
| Duplicate tweak ids, and ids outside an imported pack's namespace | An imported document cannot redefine a built-in tweak. |

## Mutually exclusive groups

One setting with several alternatives is declared as a tweak whose **states are the alternatives**,
plus the metadata that makes it a group:

```json
"group": {
  "id": "Explorer.StartupLocation",
  "revision": 1,
  "labels": { "en": "...", "vi": "..." },
  "options": [
    { "id": "ThisPC",      "intent": "Configured",     "labels": { "en": "This PC", "vi": "This PC" } },
    { "id": "QuickAccess", "intent": "WindowsDefault", "labels": { "en": "Quick access", "vi": "..." } }
  ]
}
```

Why a tweak and not a set of independent tweaks:

* the engine keys the pending set by tweak id, so **one alternative can be pending at a time** - the
  interface cannot offer two of them as unrelated checkboxes;
* alternatives go through the same preview, journal, verification and recovery as anything else, so
  switching between them is exact and reversible;
* their targets go through the same `Get-WtChangeConflictInternal`, so a group that overlaps another
  group or a pack is reported exactly like any other overlap - a group declaration cannot bypass
  conflict detection.

Validated rules: at least two options, unique option ids, a `group.revision` that is a positive
integer, a `group.id` that is unique in the document, every option has a state of the same name,
the states are exactly the options, every option appears in `detection.map` (an alternative that
cannot be detected can never be reported as the current one), every option's state writes the same
canonical target set (switching must not leave a target behind), `defaultState` is one of them, and
a group may not be irreversible (a group is meant to be switched back and forth).

`intent` separates two different actions: `Configured` writes a value this tool can restore exactly,
`WindowsDefault` asks for the behaviour Windows uses by default. Neither of them is the same as
restoring the captured baseline - that is what `Undo-WtTweak` and the journal do.

The current alternative is reported as detected, with the honest answers kept apart: `CurrentState`
(` the option id, or `Unknown`/`Unsupported`), `CurrentDetail` (`Matched`, `Mixed`, `Custom`,
`Absent`, `Unreadable`, `Unsupported`) and, when a pending set is handed to
`Get-WtChoiceGroup -Pending <map>`, `PendingState` and per-option `Pending`. An absent value is
not a custom value, and no option is guessed as "current" when the value does not match one.

```text
pwsh -File WindowsTweaker.ps1 -Choices
Get-WtChoiceGroup
Get-WtChoiceGroup -Pending $State.Pending
```

The shipped group is `Explorer.StartupLocation` (`Explorer.OpenFileExplorerTo`): This PC, Quick
access (Windows default) and Downloads, all writing the documented `LaunchTo` value (1, 2, 3).

## Recommendation and effective-state metadata

`recommendation` and `effective` are declared per definition and are described in
[docs/RECOMMENDATIONS.md](RECOMMENDATIONS.md) and [docs/STATE-DIMENSIONS.md](STATE-DIMENSIONS.md).
Both are requests or declarations that the engine judges; neither can grant trust to an imported
pack.

## Dependencies

```json
"requires":      ["Privacy.SomethingElse"],
"runAfter":      ["Privacy.OrderingOnly"],
"conflictsWith": ["Privacy.TheOpposite"]
```

* `requires` is a **prerequisite**: it must reach its state first. `Get-WtDependencyPlan` adds it to
  the plan; a prerequisite already in its default state is *excluded from the apply set* and is
  never rewritten; a prerequisite whose state cannot be read stays in the plan and is reported as
  unreadable, because "cannot read" is not "already done".
* `runAfter` is ordering only, and only when both are in the plan.
* `conflictsWith` is a refusal: both in one plan is an error, reported once per pair.
* Cycles are reported with the cycle path; unknown ids are reported, never dropped.

```powershell
Get-WtDependencyPlan -Id Privacy.SearchHighlights, Privacy.BingSearch
```

## Conditions

Only two conditions are enforced, because only two can be evaluated honestly: `supportedOS` and
`minBuild` (through the existing prerequisite check). `maxBuild`, `editions`, `architecture` and
`hardware` are **recorded and reported as not enforced** - they are never silently treated as
satisfied, and a reviewer sees them in `Get-WtTweakDefinition` under `Conditions`.

## Evidence

Evidence is separated, because one "verified" flag would be a lie by aggregation:

| Block | Means |
|---|---|
| `documentation[]` | `https://` references with a `supports` sentence each. They are never fetched. |
| `structural` | The loader validated the document. Always true for a loaded definition. |
| `providerTests` | The provider tests exercised the detection and the operations. |
| `windowsIntegration` | What somebody actually observed on a real build: build, edition, architecture, date, method, limitations, result. |
| `AuthorClaimed` | Set for imported packs. A pack can never authorize trust here. |

`Get-WtTweakDefinitionView` reports the resulting `Support` per tweak: `Structural`,
`ProviderTested`, `WindowsValidated` (only when the evidence records a real build),
`AuthorClaimed` or `Unverified` - and `Unsupported` for a definition that can no longer be applied.

### Schema and loader stay in step

The catalog schema (`catalog.schema.json`) is the normative description for authors, and it now
describes `recommendation`, `effective` and `group` exactly as the loader accepts them.
`tests/Catalog.Tests.ps1` asserts the schema's key lists and enums against the loader constants in
both directions, so the schema cannot be narrower than the engine or invent a key the loader
refuses.

### A repair that follows a finding

`Mmcss.SystemResponsiveness` is the definition that pairs a sanity finding with a repair: it writes
the documented shipped value (20) of `SystemResponsiveness`, declares `recommendation.kind: Repair`
with `requiresFinding: Mmcss.TaskOverrides/system-responsiveness`, and is offered only while that
finding is present. It goes through the same preview, journal, verification and recovery path as
every other definition, and it claims no performance effect.

## Lifecycle

`Available` runs; `Experimental` runs and is announced; `Deprecated`, `Unsupported` and
`Restore-only` are refused for applying but remain **restorable** from captured state.

## Stable ids and migrations

A tweak id is a contract: it appears in presets, in reports and in the journal. When a definition
is renamed, replaced or retired, the old id keeps working:

```json
{ "from": "Privacy.OldId", "to": "Privacy.NewId", "kind": "rename", "since": "1.1.0", "reason": "..." }
{ "from": "Privacy.Gone",  "kind": "deprecate", "reason": "merged into Privacy.NewId" }
```

The registry is validated at load: unique `from`, well-formed ids, a target that exists, no
self-migration, no cycles, and a hard hop limit. Resolution happens **on lookup only**: journal
entries, presets and reports keep the id they were written with, and `Undo-WtTweak -Id <new id>`
still finds an entry stored under the old one. `Get-WtTweakMigration -Problems` lists preset
entries that no longer resolve.

## Command line

```text
pwsh -File WindowsTweaker.ps1 -CatalogList -CatalogFilter definitions,lifecycle:Experimental
pwsh -File WindowsTweaker.ps1 -CatalogInspect Privacy.WindowsTips
pwsh -File WindowsTweaker.ps1 -CatalogValidate ./my-catalog.json
pwsh -File WindowsTweaker.ps1 -CatalogPlan Privacy.SearchHighlights,Privacy.BingSearch
pwsh -File WindowsTweaker.ps1 -CatalogMigrations
```

Filters: `definitions`, `powershell`, `builtin`, `pack[:<pack id>]`, `scope:<name>`,
`risk:<name>`, `lifecycle:<name>`, `evidence:<status>`, `support:<status>`, `category:<name>`,
`tag:<name>`, `requires:<id>`, `conflicts:<id>`. An unrecognised filter is reported rather than
ignored. In the terminal interface the same expressions are typed into the search box prefixed
with `@`, for example `@pack:`, `@risk:High` or `@lifecycle:Experimental`.

## Adding a built-in definition

1. Write the definition with the fields above; keep the English and Vietnamese texts complete.
2. Run `pwsh -File WindowsTweaker.ps1 -CatalogValidate <path>` - it must report no problems.
3. Run the validation suite: `pwsh -NoProfile -File tools/Invoke-Validation.ps1`.
4. Record what was actually verified: `docs/FEATURE-INVENTORY.md` is generated from the catalog
   (`tools/New-FeatureInventory.ps1`), so keep the definition and the inventory in step.
5. Never claim Windows validation that did not happen. `"result": "Unverified"` with a `method`
   and `limitations` sentence is the honest answer, and it is what every migrated definition
   currently says.
