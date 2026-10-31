# Operation journal, change verification and recovery

This document describes the durable state store as of schema **2**: what is recorded, how it
is written, how an older store is migrated, and what the recovery guarantees actually are.

## Where the data lives

| File | Purpose |
|---|---|
| `state.json` (`Get-WtStatePath`) | The journal: sessions and operations, including the exact pre-change capture the rollback engine replays |
| `state.json.lock` | Cross-process write lock (created with `CreateNew`, removed after the write; older than 60 s is treated as stale and broken with a warning) |
| `settings.json` (`Get-WtSettingsPath`) | Presentation preferences only (icon mode, interface language) |
| `logs/wt-<date>.jsonl` | Structured log records, including the opt-in input trace |
| `diagnostics-<utc>.jsonl` | Bounded diagnostics export, written only when the user asks for it |

`WT_DATA_ROOT`, `WT_STATE_PATH` and `WT_SETTINGS_PATH` override the locations (tests and
portable installs).

## Schema 2

```json
{
  "version": 2,
  "sessions": [
    { "sessionId": "…", "startedUtc": "…", "endedUtc": "…|null",
      "appVersion": "1.0.0", "platform": { "PowerShell": "7.6.9", "OSVersion": "Windows11",
      "OSBuild": "26100", "OSUBR": "1", "OSName": "Windows 11 Pro", "IsWindows": true } }
  ],
  "journal": [
    {
      "operationId": "…", "historyId": "… (same value, legacy alias)",
      "parentOperationId": "…|null", "sessionId": "…", "sequence": 17,
      "origin": "manual|preset|recovery|reapply|legacy",
      "stage": "planned|applied|verified|failed|compensated|restored|completed|abandoned",
      "appVersion": "1.0.0", "platform": { … },
      "tweakId": "Privacy.AdvertisingId", "state": "Disabled", "arguments": { },
      "timestamp": "started UTC", "updatedUtc": "last stage UTC", "dryRun": false,
      "targets": [
        { "identity": "reg:HKCU:\\…\\ENABLED", "label": "HKCU:\\…\\Enabled",
          "class": "Registry", "kind": "RegistrySet",
          "original": { "valueKind": "Absent|Unreadable|Empty|Zero|Value", "value": …, "display": "…", "type": "DWord" },
          "intended": { "kind": "Set|Remove|CreateKey|RemoveKey|Configure", "value": …, "display": "…", "type": "DWord" },
          "captured": true, "verified": true, "baselineOperationId": "…|absent" }
      ],
      "records": [ { "resource": "Registry", "path": "…", "name": "…", "valueExisted": true, "kind": "DWord", "value": 0 } ],
      "outcome": "succeeded|failed|unchanged|dryrun|unsupported|skipped|pending",
      "messages": [ "…" ],
      "verification": { "Attempted": true, "Verified": 1, "Mismatched": 0, "Unverifiable": 0, "Rows": [ … ], "VerifiedUtc": "…" },
      "compensation": { "Attempted": true, "Succeeded": 1, "Failed": 0, "Skipped": 0, "Messages": [ … ], "CompensationUtc": "…" },
      "rolledBack": false, "rolledBackAt": null
    }
  ]
}
```

`historyId` is kept as an alias of `operationId`, and `records`/`state`/`timestamp`/`outcome`
keep their schema-1 names, so every existing caller (`Get-WtHistory`, `Undo-WtTweak`,
`Get-WtReport`, the terminal interface) keeps working unchanged.

## Migration from schema 1

Schema 1 stored `{ "version": 1, "history": [ … ] }` with entries
`{ historyId, tweakId, state, arguments, timestamp, dryRun, outcome, records, rolledBack, rolledBackAt, messages }`.

Reading a schema-1 file is **read-only**: the entries are mapped in memory
(`historyId → operationId`, `sessionId = "legacy"`, `origin = "legacy"`,
`stage = "completed"` — or `"abandoned"` when the outcome was still `pending`,
`targets = []` because schema 1 did not record canonical identities) and
`Read-WtStateStore` reports `Migrated = $true`, `Version = 2`, `FileVersion = 1`.

The file on disk is rewritten in schema 2 on the next write (the first apply, restore or
export that saves the store). Captured `records` are preserved byte for byte, so an old
snapshot stays restorable after the migration — which is the property that matters: a
migrated entry keeps its recovery path even though its per-target identity list is empty.

Nothing in the migration needs a manual step. If a store cannot be parsed at all it is
**not** migrated: `Corrupt = $true`, every write refuses ("Refusing to overwrite…"), and the
file is left exactly as it was. Repair means moving that file aside deliberately.

## How a write happens

1. `Add-WtJournalEntry` (stage `planned`) is called **before** the first mutation. If it
   fails, the operation returns `failed` and nothing is changed.
2. The provider writes run; the captured pre-change records are attached to the entry and
   **persisted** (stage `applied`) before verification, so an interruption during
   verification still leaves the recovery data on disk.
3. Verification reads each target back (`Test-WtAppliedTargets`). A mismatch turns the
   outcome into `failed` and is reported, never hidden.
4. On a partial failure with a reversible tweak, compensating restoration is attempted
   (`Invoke-WtCompensation`) and reported separately (stage `compensated` / `failed`).
5. The final stage is written with the outcome, verification and compensation payloads.

Every write takes the lock, writes a temporary file, flushes it to disk and replaces the
target atomically (`File.Replace` on Windows, `Move-Item -Force` elsewhere). Two processes
applying at the same time therefore cannot lose each other's writes.

## What the guarantees are (and are not)

* **Compensation is not atomic rollback.** Windows offers no transaction across registry,
  services, tasks, DNS, Appx and Defender. A partial failure makes the tool *attempt* to put
  the already-changed targets back to their captured values; each target is reported
  individually, failures of the compensation are reported separately, and the captured
  recovery data is always kept so the user can retry deliberately.
* **A restore never overwrites an external change silently.** Before restoring, each target's
  live value is compared with the value the operation applied. A difference means something
  else changed it; the restore returns `review-required` with both values and only proceeds
  with `-Force`.
* **Read-back covers the targets that have a reader**: registry values, registry keys,
  Defender preferences and per-adapter DNS. Service, task, firewall-group and Appx targets
  have no read-back reader in this code base; they are recorded as *unverifiable*, never as
  verified.
* **Drift is information, not an action.** `Get-WtDrift` compares the recorded applied value
  with the live one and classifies each target as `matching`, `changed`, `unreadable` or
  `unsupported`. A build change is shown as context only. Nothing is reapplied
  automatically: `Invoke-WtTweak -Origin reapply` runs the normal reviewed path.
* **Retired tweaks keep their recovery paths.** A tweak declared `-Lifecycle Unsupported` or
  `-Lifecycle Restore-only` refuses to apply (`unsupported`, with the reason) while
  `Undo-WtTweak` still restores any snapshot captured before the retirement.

## Inspecting it

```powershell
Get-WtOperation -Limit 20                  # journal rows, newest first (sequence order)
Get-WtSession                              # sessions with their origins and stages
Close-WtSession                            # marks this run's session as ended
Get-WtInterruptedOperation                 # planned/applied operations that never finished
Get-WtDrift -OnlyDrifted                   # recorded vs live, changed rows only
Get-WtRestorePlan -SessionId <id>          # dependency-aware plan with conflicts
Export-WtHistory -Path ./journal.json      # explicit export (Json or Csv)
Export-WtDiagnostics -Path ./diag.jsonl    # explicit export of the diagnostics buffer
```

A session is opened by the first journal entry a run writes and closed by `Close-WtSession`,
which the interface and the command line call on their way out. Until then the row reads
`endedUtc: null` and `Get-WtSession` reports `Open = $true`, so a run that was interrupted
(the process died, the terminal was closed) stays distinguishable from one that finished.
Closing a run that recorded nothing writes nothing, so a read-only command stays read-only.

In the terminal interface: `V` opens the verification and recovery view (`R` review and
reapply, `U` restore, `E` export the journal, `D` export the diagnostics), and an interrupted
operation is announced on the status line at startup.

## Ordering

Operations are ordered by the monotonic `sequence`, never by timestamp: timestamps tie, move
backwards when the clock is corrected, and say nothing about dependency. A session is
restored newest-first, and when two operations in the plan touch the same (or a containing)
target, the newer one owns the restore and the older one is reported as superseded instead of
being replayed on top of it.