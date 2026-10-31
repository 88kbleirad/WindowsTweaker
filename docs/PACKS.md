# Tweak packs

A pack is a local, data-only extension: a JSON document in the *same format* as the built-in
catalog, with one extra rule - every tweak id must live inside the pack's own namespace. A pack can
therefore add settings; it can never redefine, shadow or replace a built-in tweak.

A working example ships with the repository: **`samples/example-pack.json`**. It is deliberately
non-destructive - every value it writes lives under `HKCU\Software\WindowsTweaker\Samples`, a key
no Windows component reads - so it can be imported and applied on any machine to see the whole
workflow (import -> review -> apply -> roll back) without changing how Windows behaves.

## What a pack cannot do

| Guarantee | How it is enforced |
|---|---|
| Run code | The document format has no expression, script, command or URL that is ever evaluated. |
| Touch Windows while loading | Importing only writes two files under the user data root; nothing is detected, registered or applied. |
| Leave its namespace | Every tweak id must start with `<pack id>.`, checked before anything is stored. |
| Lower its privilege or risk floor | Derived from `scope` and from the flags, exactly as for a built-in definition. |
| Claim verification | Anything a pack says about itself is recorded as an author claim; `Support` can only be `AuthorClaimed` or `Unverified`. |
| Break a built-in id | A pack cannot declare an id outside its namespace, so `Privacy.DismissMSAccount` cannot be redefined. |
| Hide a malformed document | Validation is the same strict validation the built-in catalog uses, and it refuses rather than repairs. |

## Workflow

```text
pwsh -File WindowsTweaker.ps1 -PackImport ./samples/example-pack.json -WhatIf    # validate and show
pwsh -File WindowsTweaker.ps1 -PackImport ./samples/example-pack.json           # store and register
pwsh -File WindowsTweaker.ps1 -PackList
pwsh -File WindowsTweaker.ps1 -PackInspect WindowsTweaker.Sample
pwsh -File WindowsTweaker.ps1 -PackDisable WindowsTweaker.Sample
pwsh -File WindowsTweaker.ps1 -PackEnable  WindowsTweaker.Sample
pwsh -File WindowsTweaker.ps1 -PackRemove  WindowsTweaker.Sample
```

The same steps from a script:

```powershell
Import-WtTweakPack -Path ./samples/example-pack.json -Enable   # -WhatIf validates and shows only
Get-WtTweakPack
Get-WtTweakDefinition -Id WindowsTweaker.Sample.ExampleSetting
Disable-WtTweakPack -Id WindowsTweaker.Sample                  # unregisters, keeps the file
Remove-WtTweakPack  -Id WindowsTweaker.Sample -Force           # removes the file as well
```

Import order is: **validate** the document, **show** what it contains (states, targets, risk,
evidence), **confirm** (`ShouldProcess`; `-WhatIf` stops here), **persist** a byte-for-byte copy
plus a record with its SHA-256, import date, source path and enabled flag, then **register** the
definitions through the existing constructor. Nothing about Windows is read or written at any step.

## Where packs live

| Path | Contents |
|---|---|
| `$env:WT_DATA_ROOT` (default: `%LOCALAPPDATA%\WindowsTweaker`, `$XDG_STATE_HOME/WindowsTweaker` elsewhere) | Data root; `WT_PACKS_PATH` overrides the packs directory. |
| `<data root>/packs/<pack id>.json` | The document, copied verbatim so the recorded hash stays true. |
| `<data root>/packs/<pack id>.record.json` | Version, author, source path, import date, SHA-256, tweak ids, enabled flag. |

Packs live outside the module, so upgrading or reinstalling the module does not touch them. A pack
whose stored file is edited or truncated after import is **not** loaded: enabling it re-validates
the stored document and compares its hash with the recorded one, and a mismatch is reported instead
of being registered.

## Removing a pack while its changes are still applied

A restore replays the captured original state, which is stored in the journal and does not need the
definition. So removing a pack never makes a past change unrestorable:

* `Remove-WtTweakPack` **refuses** while changes the pack created have not been rolled back, listing
  them, unless `-Force` is given;
* with `-Force` the pack is removed and those changes remain reversible -
  `Undo-WtTweak -Id <pack tweak id>` still restores the captured values, verified by
  `tests/Catalog.Tests.ps1`.

Disabling is the gentler option: the definitions stop being available for new changes while the
stored document stays on disk.

## Writing a pack

1. Copy `samples/example-pack.json` and change `id` to your namespace, e.g. `Contoso.Hardening`.
2. Give every tweak an id inside it: `Contoso.Hardening.DisableSomething`.
3. Fill in both languages for `names`, `descriptions`, `impacts` and `sideEffects`. State what the
   change does *not* do as well as what it does; the impact text is what a reviewer reads first.
4. Declare `requires`, `runAfter` and `conflictsWith` where they are real. Do not declare a
   prerequisite that the setting does not actually need.
5. Set the flags honestly. `irreversible`, `dataDeletion` and `reducesProtection` raise the derived
   risk floor, and a document that contradicts the floor is refused rather than quietly adjusted.
6. Validate before importing:

   ```text
   pwsh -File WindowsTweaker.ps1 -CatalogValidate ./my-pack.json
   ```

7. Test it on a scratch Windows installation first. A pack author is responsible for what the pack
   writes: the evidence block exists so that claims can be checked, not so that they can be
   implied. `"result": "Unverified"` is a perfectly good value when nothing was observed.

## Relationship to the built-in catalog

Nothing distinguishes a pack definition from a built-in one at apply time: both are registered
through `New-WtRegistryTweak`, so both go through preview, review revalidation, capture,
verification and rollback. The differences are visible and deliberate:

* the id namespace (`<pack id>.`), so a pack cannot take over a built-in id;
* `DefinitionSource` is `Pack`, and the inspector and the interface show the pack it came from;
* evidence is recorded as an author claim, and `Support` for a pack is `AuthorClaimed` or
  `Unverified` - never `ProviderTested` or `WindowsValidated`.
