# Configured, effective and ownership

One Enabled/Disabled flag cannot answer three different questions. The engine answers them
separately, and says how it knows.

```text
Get-WtTweakDimensions -Id Privacy.WindowsTips
Get-WtTweakState -Dimensions
Get-WtPendingRestart
pwsh -File WindowsTweaker.ps1 -CatalogInspect Privacy.WindowsTips -CatalogDimensions
```

## The three dimensions

**Configured** - does the machine hold what the state describes?

| Value | Meaning |
|---|---|
| `Matches` | Every readable target holds the intended value. |
| `Differs` | Something else is configured. |
| `Mixed` | Some targets hold the intended value, some do not (a state that writes several things). |
| `Absent` | No target holds it and detection matches no declared state. |
| `Unreadable` | No target could be read. |
| `Unsupported` | The change cannot run on this system. |

A preview that cannot be built is reported as `Unreadable`, never as `Unsupported`: an inability to
read is not a platform limitation. `Mixed` requires at least one readable match - with no match the
answer is `Absent` or `Differs`, never `Mixed`. Targets that could not be read are counted and
reported, and never allowed to turn "nothing matches" into "some targets match".

**Effective** - what is Windows doing with it?

| Value | Meaning |
|---|---|
| `Active` / `Inactive` | Reported only from evidence (see below). |
| `PendingRestart` | The component reads it when it starts (Explorer, for example): a restart applies it. |
| `PendingSignOut` | Read when a session starts. |
| `PendingReboot` | Read at a Windows restart, and Windows reports a restart pending now. |
| `Unknown` | Configuration is in place, but nothing proves the runtime behaviour. |
| `Unsupported` | The change cannot run here. |

**Ownership** - who put it there, and who can put it back?

| Value | Meaning |
|---|---|
| `Unmanaged` | Pre-existing, or set by something else. |
| `Owned` | Applied by this tool, captured state still available. |
| `Conflicting` | An organization policy governs it, or a recorded target changed outside this tool. |
| `Interrupted` | An operation was started and never reported its last stage; the captured state is available. |

## Evidence, never assumption

A successful write and read-back proves **configuration**. It does not prove behaviour, and it
certainly does not prove a performance change. So an effective state is only reported from evidence,
and every answer carries how it was obtained:

| Evidence | Meaning |
|---|---|
| `Observed` | A probe read the live behaviour, or the definition records an observation made on a real build. |
| `Inferred` | The configuration implies the behaviour through a mapping the definition documents. |
| `Unknown` | Nothing proves it either way - the honest default, and what most definitions report. |

A definition declares this in its own metadata:

```json
"effective": {
  "evidence": "Inferred",              // Observed | Inferred | Unknown
  "boundary": "Explorer",              // None | Explorer | SignOut | Reboot
  "map": { "Enabled": "Active", "Disabled": "Inactive" }
}
```

Without that declaration the effective state is `Unknown`. An imported pack can never report
`Observed`: its own statement is downgraded to `Inferred` and marked as an author claim.

## Restart boundaries

A boundary that has not been crossed outranks any mapping: the component has not read the new value
yet, so the old behaviour - or none - is what is live. Whether the boundary is crossed is decided by
evidence, not by the declaration:

| Evidence | Verdict |
|---|---|
| `no boundary` (`None`) | Crossed: nothing defers this setting. |
| `pre-existing configuration` | Crossed: no apply of this tweak is recorded, so the configuration pre-dates the tool and the component has already read it. |
| `restart marker` | **Not** crossed: Windows reports the restart it still owes. This outranks every timestamp comparison for the Reboot boundary. |
| `last boot time` | Crossed when the boot is after the recorded apply, not crossed before. |
| `File Explorer process` | Crossed when Explorer started after the recorded apply. |
| `interactive logon session` | Crossed when the session started after the recorded apply. |
| unreadable probe | No verdict: the answer is `Unknown`, never "applied" and never "pending". |

A boundary that is provably not crossed reports `PendingReboot`, `PendingSignOut` or
`PendingRestart`; a crossed boundary falls through to the declared mapping (with `Inferred`
evidence) and to `Unknown` when no mapping is declared. After the relevant boundary, re-probe with
`Get-WtTweakDimensions` (or `Get-WtTweakState -Dimensions`) rather than assuming the restart made the
change effective. A change whose boundary cannot be established is never presented as applied.

## Pending-restart evidence

`Get-WtPendingRestart` reads markers and keeps four states apart:

| Marker state | Meaning |
|---|---|
| `NonEmpty` | Present and holds entries: Windows owes work at the next restart. |
| `Empty` | Present but empty - Windows' shape for a marker that has been cleared. |
| `Missing` | Not present. |
| `Unreadable` | The probe could not read it; this is never reported as missing, and an unreadable probe is never evidence that no restart is pending. |

Markers are read-only. Nothing here deletes or clears one, and a pending restart never blocks an
unrelated read-only view.

## Store versions

The journal and settings stores refuse a file whose schema version is newer than this build: it is
not read as if it were current, and a write - including `-Force` - never replaces it, because
overwriting it would destroy records a newer build still needs. A known older version is migrated on
read and the next write persists the current version. Journal timestamps are normalised back to
ISO-8601 UTC on read, so a recorded instant is comparable instead of culture text.

## Where the values come from

`Get-WtTargetState` is the single reader for a target, so the dimensions and the preview cannot
disagree about what is live. It keeps `Absent`, `Zero`, `Empty` and `Value` apart, which is why a
stored `0` is a value, not a missing setting - and why a comparison that only accepted `Value` would
report every zero as a mismatch.
