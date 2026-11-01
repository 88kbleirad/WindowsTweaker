# External tool: Microsoft Activation Scripts (MAS)

`Licensing & Activation` offers one integration point with a third-party tool: **Microsoft
Activation Scripts (external tool)**, reachable with `M` from the licensing workspace (or the
Overview row `Licensing & Activation Diagnostics`).

It is an intentionally separate feature. WindowsTweaker does not activate anything itself, does
not embed, port or modify MAS, and does not run it as part of a tweak, a preset, a batch, a startup
task, a monitoring policy or an automatic remediation. The user downloads the upstream file at one
pinned commit and launches it as its own process, inside its own console, on request.

Vietnamese usage instructions: [README.md](../README.md#microsoft-activation-scripts-công-cụ-bên-ngoài).

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
| Elevation | required; the script checks for it itself and re-launches through UAC |

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

### Activation methods are not all time-limited

The tool's menu contains several methods, and their durations differ. From the upstream
documentation at the pinned commit:

| Method | Product | Duration as documented upstream | Internet needed |
|---|---|---|---|
| HWID (digital licence) | Windows 10/11 | described as permanent | yes |
| Ohook | Office | described as permanent | no |
| TSforge | Windows / ESU / Office | described as permanent | only for the StaticCID method (build 26100 and above) |
| Online KMS | Windows / Office | 180 days, lifetime with the renewal task | yes |

The workspace therefore never says "this activates Windows permanently": it says the duration
depends on the method chosen inside the upstream menu, and that activation is not licence
entitlement.

## The actions, and what each one does

| Key | Action | What it does |
|---|---|---|
| `V` | View upstream documentation | opens `https://massgrave.dev/` in the default browser through the backend (Windows only; the URL is shown otherwise) |
| `D` | Download the pinned version | starts one **background** transfer of the pinned file; the interface stays responsive, the progress line reports real byte counts, `Esc` cancels it, and a second press while it runs is refused |
| `U` | Check for a newer upstream release | resolves the newest upstream release to an immutable commit, shows its tag/commit/size, and only downloads it after an explicit confirmation |
| `L` | Launch the downloaded tool | starts the verified file in its own console, with an explicit elevation handoff |
| `R` | Remove the downloaded files | deletes the local copy, any staging leftover and the provenance record |
| `?` | Help | the full disclosure in one dialog |
| `Esc` | Back | returns to the licensing diagnostics |

Nothing is downloaded, launched or deleted while the interface navigates, refreshes, starts, or
reads diagnostics. Each action begins with a dialog, and every confirmation defaults to **No**.

### Background transfer, progress and cancellation

* The download runs in its own runspace (`Private/Tui/ExternalToolTask.ps1`). **Only the interface
  thread writes to the terminal**: the runspace mutates two shared tables (progress and
  cancellation) and enqueues structured events, and the view paints from them. A source-level test
  asserts the task file cannot paint, prompt or touch the console.
* The progress line reports what is known: received and total bytes (the total is the pinned size,
  or the response's own `Content-Length`) and a percentage only while a total exists. There is no
  spinner-invented percentage, and no animation.
* `Esc` asks the running transfer to stop. The reader observes the flag once per 64 KiB chunk,
  unwinds through the download's own failure path, and the staging file is removed - a cancelled
  download publishes nothing and leaves an installed copy untouched. If a stop is not observed
  before the task deadline, the pipeline is aborted (`Stop()`), which is the last resort.
* The task carries a deadline of its own (90 s) on top of the transport's limits, so a socket that
  never answers cannot hold the view.
* A second `D`/`U` while a transfer runs is refused with a message: one task at a time, by
  construction (`Start-WtExternalToolTask` refuses a second start, and the view refuses too).
* While a transfer runs the footer hint names the one meaningful key (`Esc`) instead of the normal
  action list.

### Dry run (`D`/`W` toggle) and `-WhatIf`

A dry run refuses this whole feature, at two layers:

* **The interface** previews instead of acting. Pressing `D`, `U`, `L` or `R` in dry-run mode
  shows exactly what would happen - the file, its size and URL for a download; the command line and
  the elevation expectation for a launch; the file list for a removal - and starts, fetches and
  deletes nothing. A launch is refused **before** its confirmation dialog, so confirming is not
  possible while the mode is on.
* **The backend** refuses the same operations when a caller passes `-WhatIf`:
  `Invoke-WtExternalToolDownload -WhatIf` returns a `dryrun` result with the plan and never touches
  the network or the disk, `Start-WtExternalTool -WhatIf` returns a refusal with the exact command
  line, and `Remove-WtExternalToolFiles -WhatIf` lists the files it would delete. The interface
  never passes `-WhatIf` on its own thread (that would print a `What if:` line over the frame); a
  background runspace may, because its host output is not the terminal.

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

## Launch behaviour

* The entry point is the documented one: the batch file itself, through the command interpreter
  (`cmd.exe /c "<file>"`), with its own directory as the working directory and **no switches**.
  Nothing preselects an activation method, no activation command is composed, and no keystroke is
  fed to the tool: the upstream menu keeps every choice.
* It runs in **its own console** (`Start-Process` without `-NoNewWindow`). Its standard streams are
  never redirected or read, so no product key or activation response can reach the screen or the
  log. The log records the action, the pinned commit, whether the handoff was elevated, and the
  exit code - nothing else.
* **Elevation is an explicit handoff.** When the session is not elevated, the launch goes through
  `Start-Process -Verb RunAs`, so Windows shows its own UAC prompt. Refusing it cancels the launch
  (nothing is started, nothing is retried, no second instance is created).
* **The console is released first.** The workspace leaves the alternate screen buffer, shows the
  cursor and resets colour before the child starts. On return it re-enters the alternate buffer,
  drains keys that were typed while the child had focus, marks the frame dirty and forces a full
  repaint - a diff against the unknown terminal content would be wrong.
* **The result is not overclaimed.** After return, the licensing diagnostics are re-read and the
  dialog says whether that read succeeded. The process exit code is reported as an exit code, and
  the dialog states explicitly that it is not proof of activation.
* Nothing reboots, nothing retries on its own, and a second launch is refused while one is in
  progress (the workspace blocks, and the backend refuses a nested launch).

## Separation from tweak operations

* MAS is not a catalog tweak: it does not appear in the catalog, presets, batch apply, pending
  review, monitoring policies or remediation.
* Launching it writes **no journal records** and creates no rollback data. WindowsTweaker's registry
  journal cannot undo anything the upstream tool does to Windows or Office licensing, and the
  interface says so before the launch.
* Removing the downloaded copy deletes only files this feature created; it does not revert any
  licensing change.
* WindowsTweaker does not delete licensing stores, does not rearm, does not add antivirus
  exclusions, does not bypass Defender detections and does not disable security controls to make
  the tool launch. If the tool is blocked, the block stands.
* The dry-run switch is not consulted: this is not a tweak. The action is explicit, and its
  confirmation is the gate (the same model the licensing workspace already uses for
  `slmgr /ato`).

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

`tests/ExternalTool.Tests.ps1` (64 tests: 61 inert, 3 opt-in header-only live checks):

* pinned URL selection, host allow-list, redirect validation (relative hop, foreign host, `http://`
  hop, missing `Location`, hop limit), the size bound enforced while reading;
* the verification chain end to end with a fixture: size + git blob id + SHA-256, publish only after
  verification, the provenance record contents, a digest mismatch refused, a failed re-download
  leaving the previous copy intact, a staging directory left empty;
* provenance state: missing copy, corrupt record (untrusted, falls back to the shipped pin), a
  user-update pin, and a copy that no longer matches its pin;
* removal touching only this feature's files;
* the launch plan (interpreter, `/c`, quoted path, working directory, no switches, path outside the
  directory refused, another file name refused, `%` in the path refused), the elevation flag, a UAC
  refusal mapped to a cancellation, a launch failure reported without a retry, a copy that is not
  verified refused, and a nested launch refused while one is in progress;
* the interface: the review screen contents, the workspace hints replacing the main-screen hints,
  both languages, the ASCII frame/icon fallback, the licensing entry row, and that viewing the
  workspace, opening the download dialog and declining it download and start nothing;
* the console handoff: suspend -> launch -> resume ordering, resume on an unexpected backend
  failure, and the full-frame invalidation;
* background execution: progress reporting and cooperative cancellation in the reader, a cancelled
  transfer classified as cancelled with the staging file removed, the real runspace task delivering
  the backend's result and releasing its handle, a second start refused while one runs, a stop
  reporting what it targets, and a source-level assertion that the task never writes to the terminal;
* dry-run refusal at both layers (download, launch, removal), including that the launch preview
  names the exact command line and that nothing is fetched, started or deleted;
* the interface: a background transfer started only after confirmation, a second download refused
  while one runs, `Esc` asking a running transfer to stop without leaving the view, the real byte
  counts and percentages painted for a running transfer, the busy hint, completion/cancellation
  reporting, and the resolved-release flow that downloads only the confirmed commit;
* three opt-in live tests (`WT_EXTERNAL_TOOL_LIVE_TEST=1`) that read **response headers only**:
  the pinned URL still serves the pinned size, a redirect stays on allowed hosts, and the hop limit
  is enforced.

`tools/Test-ExternalToolSmoke.ps1` is the operator-facing smoke test. It creates an **inert child**
(a batch file on Windows, a shell script elsewhere) that writes its argument list to a marker file
and exits with a chosen code, installs it as the "downloaded" copy inside a temporary data root, and
then drives the real paths:

```bash
pwsh -NoProfile -File tools/Test-ExternalToolSmoke.ps1                    # plan, seam, restore, diagnostics, background task
pwsh -NoProfile -File tools/Test-ExternalToolSmoke.ps1 -Elevate -ExpectUacCancelled   # Windows: refuse the prompt
```

It never downloads and never runs MAS. On Windows it exercises the real launch (its own console
window, the observed exit code, the terminal restored); off Windows it asserts the platform refusal
instead and drives the process seam with the host's own interpreter, so the plan, the quoting, the
child process, the exit code, the terminal release/re-acquire and the licensing re-read are all
still executed.

No automated test downloads MAS, executes MAS, activates anything, elevates or reboots. The launch
tests use an inert fixture file inside a temporary data root, and the process seam is mocked.

## Limitations

* A real Windows launch was **not** executed in this environment (no Windows host): the elevation
  handoff, the child console, the returned exit code and the "licensing state after the tool" line
  are covered by tests only through mocks, and by the smoke tool's inert child through the process
  seam. See [VALIDATION.md](VALIDATION.md) section 22 for the manual procedure.
* Upstream ships no checksum or signature, so the first download cannot be verified against
  an upstream-published value; only the pinned commit, the upstream blob id and the project's own
  recorded digest are available.
* The transfer is bounded but not resumable: a cancelled or failed download starts over from zero
  the next time, and a partial file is never kept.
* Removing the copy does not and cannot undo a licensing change.
* Only one entry point is offered (`MAS_AIO.cmd`); the separate-files version, the OEM folders and
  the upstream command-line switches are deliberately not exposed.