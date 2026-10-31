# Sanity scan

The scan answers one question: **which configurations on this machine are worth a human look**. It
does not score the machine, does not say a setting is wrong, and never repairs anything.

```text
pwsh -File WindowsTweaker.ps1 -SanityScan
pwsh -File WindowsTweaker.ps1 -SanityScan -SanityRule Tcp.LegacyReceiveWindow -SanityExport ./scan.md
Get-WtSanityScan
Get-WtSanityRule
```

In the terminal interface, `S` opens the scan, `Enter` shows a finding in full and `E` asks for a
path before writing a report.

## Outcomes

| Outcome | Meaning |
|---|---|
| `Clean` | Every required probe of every applicable rule answered, and nothing fired. |
| `Findings` | At least one rule found something to review, and every required probe answered. |
| `Incomplete` | A required probe could not be read, so the picture is partial. **Never reported as Clean.** |
| `Unsupported` | No rule applies to this system, or no rules are loaded. |

The aggregate takes the most cautious answer: findings are still shown when something else could not
be read, and the scan says `Incomplete` rather than pretending the machine is clean.

Three statements the scan never makes:

* a non-default value is not a fault - it is a value that differs from the documented shape, and the
  finding says which documentation says what;
* an absent value is not proof of default behaviour - it is reported as absent;
* an unavailable probe is not evidence of broken hardware or a wrong configuration - it is reported
  as unreadable, and it makes the rule incomplete.

## Rules

Each rule has a stable id, a revision, a documented rationale, a severity, a source URL with the
*specific* claim it supports, a list of known limitations, an honest `effective` answer
(`Observed`, `Inferred`, `Unknown`) and read-only probes. A rule contains no code: the probe kinds
below are the entire vocabulary.

| Rule | Area | Severity | What it reads |
|---|---|---|---|
| `Mmcss.TaskOverrides` | Mmcss | Low | `SystemProfile` and its `Tasks` subkeys |
| `Tcp.LegacyReceiveWindow` | Tcp | Low | static receive-window values under `Tcpip\Parameters` |
| `Boot.TimerDebugOverrides` | Boot | Medium | `useplatformclock` and `tscsyncpolicy` on the current boot entry |
| `Restart.PendingMarkers` | Restart | Low | pending-restart markers |

Probe kinds: `RegistryValue`, `RegistryPair`, `RegistryValuesUnderKey`, `PendingRestart`,
`BcdEntry`. `BcdEntry` is the only probe that starts a process, and it runs exactly
`bcdedit /enum {current}` - read-only, no arguments of the rule's choosing. The executable is
resolved from `%SystemRoot%\System32` first, so a shadowing directory on PATH cannot replace it.

Each finding shows the observed value **and its type** (the registry kind, when a value was
read), the rule's declared Windows conditions (`supportedOS` and `minBuild`, reported as declared
and not enforced beyond the platform key and the minimum build), the effective-behaviour class the
rule claims (`Observed`/`Inferred`/`Unknown`), why the value deserves a look, the documented
claim and source, the next step, and every limitation. A finding also carries the rule's
**remediation link** when one exists: `Mmcss.TaskOverrides` links `Mmcss.SystemResponsiveness` for
its `system-responsiveness` probe. A link is a pointer for a human, never an action - it names a
reviewed definition that goes through the normal preview, review, journal and verification path.
The `Tasks` subkeys stay manual, because their effect depends on the applications that join the task.

### What each rule is based on

* **MMCSS** - [Multimedia Class Scheduler Service](https://learn.microsoft.com/en-us/windows/win32/procthread/multimedia-class-scheduler-service):
  `SystemResponsiveness` is rounded down to a multiple of 10 and values below 10 or above 100 are
  clamped to 20 (100 disables MMCSS); `Priority` is always treated as 2 for tasks whose
  `Scheduling Category` is High; `GPU Priority` is not yet used; `SFIO Priority` is not used; the
  `Clock Rate` guarantee was removed starting with Windows 7.
* **TCP** - [Network Adapter Performance Tuning in Windows Server](https://learn.microsoft.com/en-us/windows-server/networking/technologies/network-subsystem/net-sub-performance-tuning-nics):
  the stack negotiates the receive window through *TCP receive window autotuning level*, whose
  default is `Normal`; before that it used a fixed 65,535-byte window; single-connection throughput
  is the window size divided by the latency. The autotuning level itself is reported by
  `netsh interface tcp show global`, which needs elevation and is deliberately **not** part of the
  scan.
* **Boot** - [BCDEdit /set](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/bcdedit--set):
  `useplatformclock` forces the platform clock as the system performance counter and
  `tscsyncpolicy` controls timestamp-counter synchronisation; both are documented as options that
  "should only be used for debugging". The rule judges only these two: other timer options exist and
  are deliberately not judged, because no verification of their documented status was performed.
* **Restart** - [PendingFileRenameOperations](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-2000-server/cc960241(v=technet.10)):
  Windows records the files to rename or delete at the next restart in that value. The servicing
  markers under Component Based Servicing and Windows Update are read and reported with their state;
  no claim is made here about which component wrote them.

## Reports

A report is written **only** when a path is given (`-SanityExport`, or `E` in the interface), and
the writer refuses to overwrite an existing file unless `-Force` is given - nothing is written when
it refuses, and the refusal is reported instead of a path to a file that does not exist. The report
contains the findings (with the observed type, the conditions, the remediation link and the source
citations), the gaps, and no machine identifiers and no environment dump. The terminal interface
exports the scan that is on screen, not a fresh scan. Nothing else in the scan writes to disk, and
`WroteAnything`/`ExportedTo` on the result describe what actually happened.

## Safety

* No setting is modified, no service is restarted, no cache is flushed, no log is cleared, no tool
  is downloaded, nothing is repaired.
* Restart markers are read and never deleted - they are Windows' own bookkeeping.
* Remediation is a separate, explicit action through the normal path
  (`Invoke-WtTweak` -> preview, review, journal, verification, recovery). There is no "fix all".
  The MMCSS rule links a reviewed repair for its `system-responsiveness` value
  (`Mmcss.SystemResponsiveness`); the `Tasks` subkeys and the TCP and boot rules are manual by
  design - the scan cannot know why those values were set, and the boot configuration is outside
  what the preview/journal/recovery engine can capture and restore.
* Diagnostic capture with side effects (a tracing session, for example) is not part of this scan and
  is not added by it.

## Not covered

* No power-plan rule. The device- and AC/DC-dependent mapping could not be verified to the standard
  this rule set requires - every rule here cites the page that states its claim - so the area is
  left out rather than filled with folklore.
* No performance measurement. The scan reports configuration and the documented relationships it
  rests on; it never reports a frame rate, a latency or a throughput that it did not measure.

## Authoring a rule

Rules live in `src/WindowsTweaker/Data/Insight/rules.json` (override with `WT_RULES_PATH`). Unknown
keys, unknown probe kinds, unknown comparison operators, a missing source, a source without a claim,
a duplicate rule id and an unsupported schema version are all errors: a rule that cannot be trusted
is not silently loaded. A rule that cites no page is refused - an opinion is not a rule. The loader
also requires `revision` (integer, at least 1), a non-negative integer `minBuild` when present,
`supportedOS` limited to `Windows10`/`Windows11` when present, and a boolean `required` on every
probe: a probe that omits `required` can no longer silently stop making the rule incomplete, which
is what keeps the "never report Clean when a required probe failed" guarantee structural.
