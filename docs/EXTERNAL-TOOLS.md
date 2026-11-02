# Windows activation: Microsoft Activation Scripts (MAS) as a pinned external tool

`Licensing & Activation` (`N`) is now a single-purpose screen: it shows the installed edition, the
activation status Windows reports, the selected activation method with its duration model, the
readiness of the pinned file, and the outcome of the last run. Its one primary action, `A`
(**Activate Windows** / **Kích hoạt Windows**), runs the selected Windows-only activation method of
the pinned upstream script directly, with exactly that method's documented switches, in its own
console - the MAS interactive menu is never shown and no keystroke is fed to it.

WindowsTweaker does not activate anything itself, does not embed, port or modify MAS, and does not
run it as part of a tweak, a preset, a batch, a startup task, a monitoring policy or an automatic
remediation. Everything else that used to live on the licensing screen - download provenance,
hashes, upstream source, documentation, updates, removal, and the documented `slmgr /ato` request -
moved to the secondary screen `S` (Settings & details).

Vietnamese usage instructions: [README.md](../README.md#kích-hoạt-windows-công-cụ-bên-ngoài-microsoft-activation-scripts).

## What was selected upstream

Everything below was read from the upstream repository and its documentation at the pinned commit,
and the artifact was fetched and hashed once during integration (recorded in
[VALIDATION.md](VALIDATION.md) section 22).

| Item | Value |
|---|---|
| Repository | `https://github.com/massgravel/Microsoft-Activation-Scripts` |
| Latest release at integration time | tag `3.12` ("v3.12 8 Years of MAS"), published 2026-07-04 |
| Pinned commit | `40c74d0d7f42146b1dd1ab59b5c7e836d6a56d1f` (the commit tag `3.12` points at) |
| Entry point | `MAS/All-In-One-Version-KL/MAS_AIO.cmd` - the "direct script" the upstream README documents as Method 2 |
| Size | 761,964 bytes |
| Upstream content id | git blob `33513d90d2c8332d10c713a63e5468be4a78cc23` |
| SHA-256 (recorded by this project) | `850f979665fb93999acae93f4790c1ff8ed2041532060b7966a121c2d29a0bfa` |
| License | GNU GPL v3 (`LICENSE` in the repository) |
| Documentation | `https://massgrave.dev/` |
| Elevation | required; MAS checks for it itself and re-launches through UAC |

### Upstream invocation methods, and which one is used

Upstream documents two ways to run it:

1. **PowerShell one-liner** - `irm https://get.activated.win | iex` (and a DoH variant for blocked
   DNS). WindowsTweaker does **not** use this: it downloads a local file first, so the exact bytes
   can be inspected and hashed before anything runs.
2. **Traditional / offline** - download `MAS_AIO.cmd` (or the zip) and run it. This is the method
   implemented here: one file, one pinned commit, one local file on disk, launched through its own
   entry point.

Upstream publishes **no checksum file and no signature** for `MAS_AIO.cmd`; the GitHub release for
`3.12` carries no uploaded assets at all (only generated source archives). That is why the pin is a
commit plus a project-recorded digest rather than an upstream-published one - see the provenance
chain below for what that does and does not prove.

### Unattended invocation: the command-line switches

MAS supports documented unattended invocation. From `https://massgrave.dev/command_line_switches`:

> - You can use the switches below in MAS AIO ... to run in unattended mode.
> - The script will run in unattended mode if any switch is used.
> - All switches are case-insensitive and work in any order, but must be separated with spaces.

In the pinned script itself, the switches are parsed **before any menu is painted** and the script
exits after the requested workflow:

- line 396-403: if the argument list contains a `/`, the script dispatches on it and exits -
  `/HWID` to `:HWIDActivation`, `/Z-` to `:TSforgeActivation`, `/K-` to `:KMSActivation`,
  `/Ohook` to `:OhookActivation` - so no menu choice is ever needed, and the script is not shown
  at all;
- line 675: `/HWID-NoEditionChange` stops HWID from changing the Windows edition;
- line 12081: `/K-NoEditionChange` stops Online KMS from changing the Windows edition.

WindowsTweaker therefore does not automate menu keystrokes, never uses SendKeys, and never patches
upstream code. It passes the documentation switches of exactly one method.

## The methods, and how each one is offered

The method selection lives on the Settings & details screen (`S`). It is a closed table in
`Private/ExternalTool.ps1` (`Get-WtWindowsActivationMethods`); every entry names the upstream line
that implements the switch and the upstream page that documents the duration. The list is
deliberately small: only methods that are Windows-only, that the pinned revision implements, and
that the tool's author demonstrates for the driving editions.

| Method | Switches WindowsTweaker passes | Duration as documented upstream | Internet | Offered when |
|---|---|---|---|---|
| HWID (digital licence) | `/HWID /HWID-NoEditionChange` | permanent (the licence is stored on Microsoft servers and follows the hardware; it cannot be removed locally) | required for the activation request | Windows 10/11 client, non-evaluation, build ≥ 10240 |
| TSforge | `/Z-Windows` | permanent until a Windows reinstall or a major feature upgrade | only for StaticCID, which upstream auto-selects on build 26100+; ZeroCID/KMS4k work offline | any supported Windows/Server build ≥ 7600, non-evaluation |
| Online KMS | `/K-Windows /K-NoEditionChange` | time-limited: 180 days per activation; the renewal task upstream installs makes it lifetime | required | any supported Windows build ≥ 7600, non-evaluation |

Two switches deserve emphasis:

- `/HWID-NoEditionChange` and `/K-NoEditionChange` are always passed with the methods that could
  otherwise change the edition. WindowsTweaker never allows an edition conversion, so it always
  disables upstream's own edition-changing default.
- `/S` (silent) is documented but deliberately **not** passed: it discards the whole console
  output, and a visible upstream report is what makes a failure diagnosable. The child's streams
  are never read or logged either way, so no product key or activation response can reach the log.

The user chooses the method; WindowsTweaker never picks one, and it never substitutes another
method after a failure (no fallback). An evaluation edition gets no method at all: upstream states
such editions cannot be activated beyond their evaluation period, so offering a "permanent" mode to
one would be a false claim. When the build number cannot be read, no method is offered either: an
unknown build is never treated as "new enough".

## The main screen and the settings & details screen

**Main screen (`N`)** shows, read-only:

- the installed edition (generation from the build number, edition label from EditionID, with the
  raw registry name preserved in diagnostics);
- the activation status with the raw status code, and the collection timestamp; stale or
  unreadable snapshots are labelled explicitly;
- the selected method and its duration model, or an explicit "nothing selected yet";
- tool readiness (not downloaded / verified / mismatch / unsupported platform);
- the outcome of the last operation, kept separate from the observed machine status ("nothing run
  in this session" is never the same as "Windows is not activated").

**Settings & details (`S`)** shows the same shared licensing snapshot (status + collection time)
on its own line, then holds the method selection (keys `1`/`2`/`3`), the download provenance and
hashes, the upstream source, the documentation link, update (`U`), removal (`R`), and the
`slmgr /ato` request (`T`) - labelled "Request activation using the installed license (slmgr
/ato) - not the MAS method", with a confirm dialog that says it does not execute the selected
method. Changing the selected method never changes the machine's observed status. The main
screen's `A` is the only handler for the selected MAS method.

## Download, progress and cancellation

The pinned file is the only dependency of the activation action. `A` refuses to run before the
local copy is verified against its pin; when it is missing, `A` asks to download and verify it
first. The transfer runs in its own runspace (`Private/Tui/ExternalToolTask.ps1`): the interface
keeps painting and taking keys, the progress line reports real byte counts (received, total,
percentage only when a total is known), `Esc` cancels the transfer, and a cancelled transfer starts
nothing. Navigation, refresh, drawing and diagnostics never download or execute anything. The
download dialog defaults to **No**.

## Operation lifetime: the launcher is not the operation

MAS re-launches itself in several ways: when it is not elevated it starts a second copy through
UAC; when it detects the Terminal/QuickEdit interaction it restarts through `conhost.exe` or
`cmd.exe`; the elevated child then runs the actual workflow. The process that was started - the
`cmd.exe` wrapper - therefore frequently exits long before the activation is done. Treating that
exit as completion is exactly the bug this revision fixes.

`Wait-WtWindowsActivationCompletion` observes the real lifetime using two signals together:

- the started process object tells whether the launcher exited and what it returned;
- the process table (`Win32_Process`) is expanded to the whole process tree of that launcher -
  seeds accumulate across polls, so a detached grandchild whose parent already left the table is
  still found. Members whose creation time predates the operation (recycled process ids) are
  ignored.

Completion is `Completed` only when the launcher is gone **and** no member of its tree is left.
Anything else is `Unknown` (with the remaining process count) or `Timeout`; the caller then reports
"launched; completion unknown" and never success. When the process table cannot be read at all,
the answer is `Unknown` as well - a detached child cannot be ruled out.

A record (`activation-operation.json` in the tool's directory) is written before the wait and kept
while the outcome is unresolved. It names the root process, the tree members observed so far, the
method and the launch time, and it is the second half of the duplicate guard: `A` refuses to start
a second activation while the record still names a live process. The guard is released as soon as
the tree ends, or when the record is older than the staleness bound and uncheckable. Nothing here
ever falls back to another method, retries, or starts a second instance.

## Observed status: one shared snapshot, refreshed and bounded

The TUI shows the machine's current Windows licensing state and the outcome of the last activation
operation as two separate things. The observed status comes from a single shared snapshot
(`Private/Tui/LicensingUiState.ps1`) that the main screen, the settings screen and the footer all
paint from, so they cannot disagree.

- The active record is selected from the base Windows licensing products (add-ons such as ESU are
  kept apart, and Office has a different ApplicationId); the Licensed record wins ties, and the
  raw status code is always reported. Nothing forces Licensed.
- Every explicit refresh and every post-operation refresh bypasses the inventory cache. After an
  activation whose completion was observed but whose status was not yet activated, a bounded poll
  re-reads the provider a few times at spaced intervals, so a delayed provider update is picked up
  without blocking the keyboard. An older poll result never overwrites a newer refresh.
- The collection timestamp is shown, and stale or unreadable snapshots are labelled explicitly.
- `slmgr /xpr` and `/dlv` are run read-only (through cscript, with a timeout), sanitized, and
  compared with the CIM selection; when they disagree, the discrepancy is shown instead of a
  verdict.
- "Nothing run in this session" is the label of the *last operation* line; it is never presented
  as "Windows is not activated".

## Verification: the licensing record is the only witness

After the operation, the licensing record is re-read (never inferred) and reduced to a snapshot:
status code, product name, channel, grace days, evaluation end date, and whether a partial key is
present - never the key itself. The verdict separates four questions:

- completion was observed (`Completed` / `Unknown` / `Timeout`);
- Windows reports the activated state (status code 1) after the run;
- what validity the record reports (grace days and evaluation end date, copied as-is - nothing is
  derived or invented);
- whether the Software Protection service logged a structured error code (`0x...`), quoted verbatim.

An exit code of 0 is recorded but never treated as evidence. The result dialog shows before/after
status, remaining validity when available, the structured error code when present, and whether
completion could be determined.

## Launch behaviour, console and focus

The child runs in its own console window through `cmd.exe /c "<file>" <method switches>` with the
tool's own directory as the working directory. Its standard streams are never redirected or read,
so no product key or activation response can reach the screen or the log; the log records the
action, the method, the pinned commit, whether the handoff was elevated, the observed completion and
the exit code - nothing else.

- Elevation is an explicit handoff: when the session is not elevated, `Start-Process -Verb RunAs`
  shows Windows' own UAC prompt; refusing it cancels the run and nothing is retried.
- The console is released before the child starts (alternate screen left, cursor shown, colours
  reset). After the child returns, the interface re-enters the alternate buffer, drains keys,
  asks Windows to restore console focus (`SetForegroundWindow`, best-effort) and forces a full
  repaint.

## Safeguards

- Dry-run/WhatIf is enforced at the execution boundary: the interface refuses `A` before its
  confirmation dialog, and the backend (`Start-WtWindowsActivation -WhatIf`) refuses the start
  after building the exact plan. Nothing is spawned, elevated, downloaded or written in dry-run
  mode.
- Activation is not a catalog tweak: it is never in a preset, a batch, a startup task, a
  remediation policy, or the journal. Launching it writes no journal records and creates no
  rollback data; the interface says the journal cannot roll back upstream licensing changes.
- WindowsTweaker does not disable Defender, does not add security exclusions, and never reboots.
- The main screen, the settings screen and the refresh action never download or execute anything.

## Provenance chain

1. **Host policy.** Only HTTPS, only a hard-coded host allow-list
   (`raw.githubusercontent.com`, `api.github.com`, `github.com`, `codeload.github.com`,
   `objects.githubusercontent.com`, `github-releases.githubusercontent.com`,
   `release-assets.githubusercontent.com`). Every redirect hop is validated again; the chain is
   bounded (5 hops) and a hop to another host or to `http://` fails the download.
2. **Immutable target.** The download URL names a commit, never a branch and never a "latest"
   redirect. The only way a different commit is used is the explicit `U` action, which resolves
   `releases/latest` -> tag -> commit and shows that commit before downloading it.
3. **Bounded transfer.** A 4 MiB byte cap enforced while reading (not merely from
   `Content-Length`), a 60 s request timeout, and a whole-read deadline. The body goes to a
   staging file in the tool's own directory.
4. **Upstream content identity.** The staged bytes must match the size *and* the git blob id that
   the upstream repository reports for that path at that commit. Git's blob id is upstream content
   identity, so a changed entry point at the pinned commit is refused, not silently accepted.
5. **Recorded digest.** The bytes must also match the SHA-256 recorded in
   `src/WindowsTweaker/Private/ExternalTool.ps1` when the pin was made. That digest was computed by
   this project; it detects a changed or corrupted artifact, and it is **not** a claim of
   independent authenticity.
6. **Publish, then record.** The verified file is published in one atomic step and the provenance
   record (`<data root>/external-tools/microsoft-activation-scripts/provenance.json`) is written
   last, atomically. That record is the "ready" marker: the interface only calls the copy verified
   when the file still matches the pin it records.

What this does **not** establish: authenticity in the cryptographic sense. There is no signed
manifest to check, and a hash fetched from the same origin as the artifact proves consistency, not
authorship. The trust anchor is HTTPS to GitHub plus the pinned commit. This is stated in the
interface too, next to the digest.

## Separation from tweak operations

- MAS is not a catalog tweak: it does not appear in the catalog, presets, batch apply, pending
  review, monitoring policies or remediation.
- Running it writes **no journal records** and creates no rollback data. WindowsTweaker's registry
  journal cannot undo anything the upstream tool does to Windows licensing, and the interface says
  so before the run.
- Removing the downloaded copy deletes only files this feature created; it does not revert any
  licensing change.
- WindowsTweaker does not delete licensing stores, does not rearm, does not add antivirus
  exclusions, does not bypass Defender detections and does not disable security controls to make
  the tool launch. If the tool is blocked, the block stands.

## License obligations

MAS is **GNU GPL v3**. WindowsTweaker does not include MAS source, does not link against it, and
does not modify it: it downloads the file at runtime, at the user's explicit request, into the
user's own data directory. That is not distribution, so no GPL obligation attaches to this
repository from the download.

If a build or a distribution of WindowsTweaker ever *ships* the downloaded file, that
distribution carries the GPL-3.0 obligations for it: the licence text must accompany it, the
corresponding source must be available under GPL-3.0, no additional restrictions may be imposed,
and the file must not be presented as covered by WindowsTweaker's own terms. The provenance record
records this in its `redistributionNote` field, and
[THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md) repeats it.

## Automated tests and the smoke test

`tests/ExternalTool.Tests.ps1` covers:

- the closed method table: only HWID/TSforge/OnlineKMS are offered, each with the documented
  switch and duration model, and the edition-change-forbidding switches travel with the methods
  that can otherwise change the edition;
- the plan: `cmd /c "<file>" <method switches>` (and nothing else), no method refused, a forged
  method object refused, path/path-char guards unchanged;
- the backend action: method resolution, platform gate, verified-copy gate, the requested-process
  guard, the UAC cancellation, launch failure without retry, and -WhatIf refusal at the execution
  boundary (leaving no operation record);
- the lifetime classification against inert process-table fixtures: a launcher exit while a
  detached grandchild is still in the table is never completion (the reported bug), completion is
  only the empty tree, an unreadable table is "unknown", recycled process ids are ignored;
- the operation record and duplicate guard: a record naming a live process refuses a new
  activation; a record whose tree is gone does not; a determined completion removes the record;
- the main screen: installed edition, status, selected method, tool readiness, outcome, the two
  actions, and that the download/launch strings of the old flow are gone;
- the settings screen: method box with durations and compatibility, actions, both languages, ASCII
  fallback, busy hint, transfer progress;
- download cancellation, second-transfer refusal, and the resolved-update flow;
- dry-run refusal at both layers for download/update/activation/removal;
- licensing evidence: snapshots never carry a full key, the activated state is read from the
  post-run record even when the before-read was unreadable, determination is never claimed when
  completion was not observed, and the structured error code is copied verbatim.

`tools/Test-ExternalToolSmoke.ps1` is the operator-facing smoke test. It creates an **inert child**
(a batch file on Windows, a shell script elsewhere) that writes its argument list to a marker file
and exits with a chosen code, installs it as the "downloaded" copy inside a temporary data root, and
then drives the real paths:

```bash
pwsh -NoProfile -File tools/Test-ExternalToolSmoke.ps1                    # plan, seam, lifetime fixtures, diagnostics, background task
pwsh -NoProfile -File tools/Test-ExternalToolSmoke.ps1 -Elevate -ExpectUacCancelled   # Windows: refuse the prompt
```

It never downloads and never runs MAS. The plan stage asserts the exact method switches and the
absence of every Office/ESU/edition/reset switch; the lifetime stage drives
`Wait-WtWindowsActivationCompletion` against inert process-table fixtures; on Windows the real
launch runs with the observed exit code and the terminal restore; off Windows the platform refusal
and the process seam with the host's own interpreter are exercised instead.

No automated test downloads MAS, executes MAS, activates anything, elevates or reboots. The launch
tests use an inert fixture file inside a temporary data root, and the process seam is mocked.

## Limitations

* A real Windows launch was **not** executed in this environment (no Windows host): the elevation
  handoff, the child console, the observed exit code, the focus handover and the "licensing state
  after the tool" line are covered by tests only through mocks and fixtures, and by the smoke
  tool's inert child through the process seam and the lifetime classifier. See
  [VALIDATION.md](VALIDATION.md) section 22 for the manual procedure.
* Upstream ships no checksum or signature, so the first download cannot be verified against
  an upstream-published value; only the pinned commit, the upstream blob id and the project's own
  recorded digest are available.
* The transfer is bounded but not resumable: a cancelled or failed download starts over from zero
  the next time, and a partial file is never kept.
* Removing the copy does not and cannot undo a licensing change.
* Only one entry point is offered (`MAS_AIO.cmd`); the separate-files version, the OEM folders and
  the upstream command-line switches other than the three methods' are deliberately not exposed.
* When completion cannot be observed, the result is "launched; completion unknown" - the interface
  never pretends otherwise.
