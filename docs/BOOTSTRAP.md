# Bootstrap: install and launch

Two files make up the bootstrap, and the split is deliberate:

| File | Role | Encoding |
|---|---|---|
| `bootstrap/bootstrap.ps1` | The **published launcher**, and the only documented entry point. It loads the implementation and executes it. | Pure ASCII, **no BOM** |
| `bootstrap/implementation.ps1` | The full installer: release selection, verification, staging, runtime policy, launch. | UTF-8 **with BOM** (Vietnamese messages) |

```powershell
irm "https://raw.githubusercontent.com/88kbleirad/WindowsTweaker/main/bootstrap/bootstrap.ps1" | iex
```

That is the one documented command, and it runs on **Windows PowerShell 5.1 and PowerShell 7**.

## Why the launcher is ASCII-only (the defect this split fixes)

`irm <url> | iex` hands the downloaded body to the parser as a *string*, not as a file. A UTF-8
BOM in that body is decoded into a leading `U+FEFF`, and PowerShell's parser then refuses the
body's own attribute and param block:

```
At line:84 char:1
Unexpected attribute 'CmdletBinding'.
Unexpected token 'param' in expression or statement.
The assignment expression is not valid. ... (one per parameter default below it)
```

Measured in this repository on PowerShell 7.6.9 by decoding the file's bytes the way the
transport does, and reported from Windows PowerShell 5.1 with the same line numbers. The same
text without the leading `U+FEFF` parses with zero errors, and `Get-Content -Raw` (which strips
the BOM) never showed the problem - which is why a file-level parse test did not catch it, and
why `tests/Bootstrap.Tests.ps1` now asserts properties of the *text* the one-liner receives.

One file cannot satisfy both requirements: the body `iex` receives must not start with `U+FEFF`,
and the implementation must keep its BOM because 5.1 decodes a BOM-less file with the ANSI code
page and would corrupt every Vietnamese message in it. So the launcher is pure ASCII - it cannot
produce a `U+FEFF`, and its own messages are therefore English - and it loads the implementation
explicitly:

1. read the implementation as **bytes**: the file beside the launcher for file execution, or the
   pinned `https://raw.githubusercontent.com/88kbleirad/WindowsTweaker/main/bootstrap/implementation.ps1`;
2. decode those bytes as UTF-8 and remove a leading `U+FEFF` if one survived the transport;
3. refuse the text unless it parses and declares `$Script:WtBootstrapLauncherProtocol = 1`;
4. execute it as a script block in a child scope, forwarding every documented option, and mirror
   the code the implementation produced into `$LASTEXITCODE`.

That download refuses redirects (one pinned URL is enough), is capped at 4 MiB, and enables TLS
1.2 for the request only, as every other download in this project does. A failure is reported as
`RUNTIME:`, `NETWORK:`, `INTEGRITY:`, `PACKAGE:` or `LAUNCH:` and mirrored into `$LASTEXITCODE`,
with no unverified fallback.

## Runtimes: what happens on each one

| Current runtime | What the bootstrap does |
|---|---|
| Windows PowerShell 5.1 (the console included with Windows) | Stages and validates the release **on 5.1**, then starts the interface on a compatible stable PowerShell 7 (7.4-7.6) when one is installed. If none is installed it offers the `winget` installation once (consent required) and re-discovers the executable afterwards. Declining, cancelling or a failed installation continues **natively on 5.1** with a bilingual notice. |
| PowerShell 7.4 - 7.6 (stable) | Runs the interface natively in this session; no second process. |
| PowerShell 7.0 - 7.3, 7.7+, 8.x, preview | Runs natively and prints a notice naming the validated range. Preview builds are never selected as a handoff target. |
| older than 5.1 | Refused. `#Requires -Version 5.1` stops a file run, and the launcher checks the runtime before it loads anything and prints an English `RUNTIME:` message naming the floor (an ASCII-only file cannot carry the Vietnamese half); the session stays usable. |

Discovery never trusts a file name: every candidate is executed with
`-NoProfile -NonInteractive -Command` and asked for its version, edition and architecture.
PATH is searched first, then the documented locations (`%ProgramFiles%\PowerShell\7\pwsh.exe`,
the Store alias, `/usr/bin/pwsh`, `/opt/microsoft/powershell/7/pwsh`, snap, Homebrew). A build
whose version string carries a pre-release label - or whose path names `preview` - is reported
and skipped. Versions outside 7.4-<7.7 are reported and skipped.

Handoff mechanics: the explicit executable path, `-NoProfile -File <staged entry point>`, the
caller's working directory, the caller's `-Language`/`-Colour`/`-Ascii`/`-WorkerBackend`/`-Icons`
options, and the inherited console (no stream redirection, no new window) are preserved. The
child receives `WT_BOOTSTRAP_HANDOFF=1`, `WT_BOOTSTRAP_DEPTH` and `WT_BOOTSTRAP_PARENT`; a
bootstrap that sees either marker set runs natively instead of discovering again, and the chain
stops at depth 2, so a relaunch loop is impossible by construction.

Installation is a separate, explicitly confirmed action:

* `winget` present → one question (`[y/N]`, Vietnamese and English) → `winget install --id
  Microsoft.PowerShell --exact --source winget --accept-source-agreements
  --accept-package-agreements --silent`. Microsoft's official source; nothing is downloaded and
  executed by this script, no execution policy is touched, and no elevation is requested by it
  (winget may ask; declining returns to the shell).
* `winget` absent (Windows IoT LTSC, Server Core) → no prompt, only the manual instructions:
  <https://aka.ms/powershell-release?tag=stable> (choose the x64/ARM64 package) or the same winget
  command once App Installer exists.
* After a successful install the executable is discovered again from the documented locations,
  because PATH in the running session was captured before the installation.
* `WT_BOOTSTRAP_NO_INSTALL=1` (or `-NoInstall`) never offers the installation. Cancellation and
  failure return cleanly with the shell intact.

Errors are classified by prefix so a failure is never mistaken for another kind:
`RUNTIME:` (version policy), `NETWORK:` (URL, host, redirect, HTTP), `INTEGRITY:` (size, hash,
declared file hash), `PACKAGE:` (metadata, asset, manifest, layout), `LAUNCH:` (entry point,
host executable).

## Hosting status (read this first)

* The owner and repository in the script are real: `88kbleirad/WindowsTweaker`. The default
  release metadata URL is
  `https://api.github.com/repos/88kbleirad/WindowsTweaker/releases/latest`, so the script no
  longer needs editing before use.
* **Release `v1.0.0` is published** (tag `v1.0.0`, assets `WindowsTweaker-<platform>-v1.0.0.zip`,
  `checksums.txt`, `manifest.json`). During the launcher fix the whole public chain was executed
  on Linux: release metadata resolved, the `linux-x64` archive downloaded, its SHA-256 verified
  against `checksums.txt`, staged, and the interface started - see
  [VALIDATION.md](VALIDATION.md) section 13. A release that is *not* published, or a repository
  with no release at all, still answers `HTTP 404` at the default metadata URL, and the bootstrap
  fails with a classified `NETWORK:`/`PACKAGE:` error instead of falling back to something
  unverified.
* The release archives do **not** contain either bootstrap file: the launcher is fetched from the
  repository's `main` ref, and the implementation is fetched by the launcher from the same ref.
  Changing either file therefore changes no published asset and needs no new release.
* `v1.0.0` is the published release. The fourth fix (the TUI responsiveness work,
  [VALIDATION.md](VALIDATION.md) section 17) ships as module version `1.0.3`, packaged locally and
  **not published**: `dist/` holds `WindowsTweaker-<platform>-v1.0.3.zip`, `checksums.txt` and
  `manifest.json`, and the `v1.0.0` build output is preserved under `dist/v1.0.0/`.
* `deploy/short-url/nginx-win.conf` is a prepared nginx server block for hosting the same script
  on a short URL. Nothing is deployed; its `YOUR_DOMAIN` is a hosting placeholder, not a
  repository value.

## The piped-text flow, in order

Step 0 runs in `bootstrap/bootstrap.ps1`; steps 1-12 run in `bootstrap/implementation.ps1`.

| Step | Function | What it enforces |
|---|---|---|
| 0. Launcher | `Get-WtBootstrapLauncherImplementationText`, `Convert-WtBootstrapLauncherImplementationText`, `Assert-WtBootstrapLauncherImplementationText`, `Invoke-WtBootstrapLauncherImplementation` | Runtime floor (before anything is loaded); implementation bytes from the sibling file or the pinned URL (HTTPS, allowed host, no redirects, 4 MiB cap) read with `ReadAsStreamAsync()` and classified per stage; explicit UTF-8 decode with the leading `U+FEFF` removed; the text must parse and declare launcher protocol 1; the script block is invoked in a child scope with every option forwarded, and its code is mirrored into `$LASTEXITCODE` with nothing emitted. |
| 1. Runtime guard | `Get-WtBootstrapRuntimeProfile`, `Assert-WtBootstrapRuntime` | Reads version/edition/platform without `$IsWindows`; refuses only a runtime below 5.1, with a bilingual message. |
| 2. Platform key | `Get-WtBootstrapPlatformKey` | `win-x64`, `win-arm64`, `linux-x64`, `linux-arm64` from the **OS architecture**; any other architecture throws. |
| 3. Release metadata | `Get-WtBootstrapRelease` | `GET` of `WT_BOOTSTRAP_RELEASE_URL` or the default API URL; body capped at 2 MiB; `tag_name` and `assets` required. The release `manifest.json` published beside the archives is accepted as well, which is what makes self-hosting possible. |
| 4. Asset selection | `Get-WtBootstrapAsset` | Exact name match `WindowsTweaker-<key>-<version>.zip` or `WindowsTweaker-<key>.zip`; zero candidates throws; several candidates resolve only when exactly one is versioned, otherwise it throws; when the asset declares a `platform` (our manifest does) it must equal this host's key. |
| 5. Download | `Get-WtBootstrapAssetBytes`, `Get-WtBootstrapContent`, `Read-WtBootstrapContentBytes` | HTTPS only; every hop checked against the allowed-host list; redirects followed manually (max 10), each hop re-validated; response capped at `asset.size + 1 MiB` and the byte count must equal `asset.size` exactly. The body is read with `HttpContent.ReadAsStreamAsync()` (the synchronous `ReadAsStream()` does not exist on .NET Framework, where 5.1 runs) while the cap is enforced, and any failure names the stage and the original exception: `NETWORK: Download of <url> failed while opening/reading the response body: ...`, `INTEGRITY: ... exceeds the N byte limit`. |
| 6. SHA-256 | `Get-WtBootstrapExpectedHash`, `Test-WtBootstrapHash` | The hash is read from a `checksums.txt`/`checksum.txt` asset **of the same release** (parsed by `Read-WtBootstrapChecksums`) and compared case-insensitively. Without a checksum asset the bootstrap refuses to continue. |
| 7. Staging | `Get-WtBootstrapStaging`, `Expand-WtBootstrapArchive` | Version-tagged directory under the state dir with a `.lock` created `CreateNew`, 60 s deadline. Extraction rejects absolute paths and `..` segments and re-checks every target against the base via `Join-WtBootstrapPath`; on Linux the packaged file modes are restored so the worker stays executable. |
| 8. Release validation | `Test-WtBootstrapRelease` | `manifest.json` present; `schemaVersion` = 1; `version` declared; `platform` (when declared) equals this host's key; `entryPoint` is `WindowsTweaker.ps1`; the declared `worker.path` is the canonical path for that key; required files present; `workerProtocol` = 1; and **every file the manifest declares** is present with the declared size and SHA-256. |
| 9. Completion marker | `Set-WtBootstrapStagingComplete` | `.complete` is written **only after** step 8 passed. `Find-WtBootstrapCache` and `Invoke-WtBootstrap` accept a staged release only when that marker exists and the structure re-validates, so a staging directory left behind by a failed validation is never launched. |
| 10. Runtime choice | `Invoke-WtBootstrapApplication`, `Select-WtBootstrapPwsh`, `Invoke-WtBootstrapInstallOffer` | Handoff, installation offer or native run, exactly as the table above describes; harnessed by `WT_BOOTSTRAP_RUNTIME`, `WT_BOOTSTRAP_NO_INSTALL`, `WT_BOOTSTRAP_PWSH` and the depth guard. |
| 11. Launch | `Resolve-WtBootstrapEntryPoint`, `Invoke-WtBootstrapLaunch`, `ConvertTo-WtBootstrapArgumentString` | Starts the staged entry point with the chosen host, **no arguments beyond the caller's options** (by default none, which opens the interface and applies no tweak), the caller's working directory, and the inherited console. Argument quoting implements the `CommandLineToArgvW` rules because 5.1 has no `ProcessStartInfo.ArgumentList`. Waits and returns the child's exit code. |
| 12. Return | entry block | No `exit()`: the code is mirrored into `$LASTEXITCODE`, the console encoding is restored, the functions the script defined are removed from the caller's scope, and the session stays open - including on the failure path, which writes one non-terminating classified error and leaves `$LASTEXITCODE` at 1. Nothing is returned on the pipeline, so the old visible trailing "1" cannot appear. |

A release whose tag is already staged, marked complete and structurally valid is launched
directly, without downloading.

## Canonical platform mapping

One table, `Get-WtBootstrapPlatforms`, used by the bootstrap (what must exist in a staged
release), by `tools/New-ReleasePackage.ps1` (where the worker binary is written) and by the
tests. `worker/bin/<goos>-<goarch>/` is both the archive path and the Go build output
directory, and it is the path the shipped client resolves
(`src/WindowsTweaker/Private/Worker/WorkerClient.ps1`).

| Platform key | GOOS/GOARCH | Worker path inside the archive |
|---|---|---|
| `win-x64` | windows/amd64 | `worker/bin/windows-amd64/wt-worker.exe` |
| `win-arm64` | windows/arm64 | `worker/bin/windows-arm64/wt-worker.exe` |
| `linux-x64` | linux/amd64 | `worker/bin/linux-amd64/wt-worker` |
| `linux-arm64` | linux/arm64 | `worker/bin/linux-arm64/wt-worker` |

An earlier revision of this project mixed two schemes here (the bootstrap expected
`worker/bin/win-x64/wt-worker.exe` while packaging wrote `worker/bin/windows-amd64/wt-worker.exe`),
which made every real archive fail validation. There is now one scheme, and
`Test-WtBootstrapRelease` refuses a manifest that declares anything else.

## Allowed hosts

`Get-WtBootstrapAllowedHosts`: `github.com`, `api.github.com`, `raw.githubusercontent.com`,
`codeload.github.com`, `objects.githubusercontent.com`, `github-releases.githubusercontent.com`
and `release-assets.githubusercontent.com`. The last one is required in practice: a release
asset URL on `github.com` answers `302` to `release-assets.githubusercontent.com`
(verified live - see [VALIDATION.md](VALIDATION.md) section 12). Each redirect hop is checked
against this list, so a redirect can never move the download to another host, and a redirect to
`http://` is refused.

## State directory

`Get-WtBootstrapStateDir`: `WT_BOOTSTRAP_STATE_DIR` if set, else
`%LOCALAPPDATA%\WindowsTweaker-bootstrap` on Windows, else `$XDG_CACHE_HOME/WindowsTweaker-bootstrap`
(or `~/.cache/WindowsTweaker-bootstrap`). Only staging lives here; user settings, metrics, journal
and recovery data are untouched, and the cleanup in the `finally` block removes only the lock file.

## Overrides

| Variable | Effect |
|---|---|
| `WT_BOOTSTRAP_RELEASE_URL` | Release metadata JSON URL instead of the GitHub API default. Must be an allowed host (the list above) over HTTPS. |
| `WT_BOOTSTRAP_STATE_DIR` | Staging/state directory. |
| `WT_BOOTSTRAP_ENTRYPOINT` | Force the entry point script to launch (tests, packaging validation). |
| `WT_BOOTSTRAP_ALLOW_OFFLINE` | Only read when `WT_BOOTSTRAP_ENTRYPOINT` or `WT_BOOTSTRAP_RELEASE_URL` is set: launch the cached release without asking; without it, that branch fails explicitly. |
| `WT_BOOTSTRAP_IMPLEMENTATION_PATH` | Launcher only: run this local implementation file instead of the one beside the launcher or the pinned URL (release engineering and tests). Takes precedence over `WT_BOOTSTRAP_IMPLEMENTATION_URL`. |
| `WT_BOOTSTRAP_IMPLEMENTATION_URL` | Launcher only: implementation URL instead of the pinned `raw.githubusercontent.com` one. HTTPS and an allowed host are still required, and redirects are still refused. |
| `WT_BOOTSTRAP_TEST_ONLY` | Skip the entry block entirely, so the file can be dot-sourced for authoring, tests and `tools/New-ReleasePackage.ps1`. Applies to both files: dot-source `bootstrap/implementation.ps1` for the installer functions, `bootstrap/bootstrap.ps1` for the launcher functions. |
| `WT_BOOTSTRAP_RUNTIME` | `auto` (default), `native`, `pwsh`. `native` never relaunches; `pwsh` requires a compatible runtime and fails (exit 3) with the manual instructions instead of falling back silently. |
| `WT_BOOTSTRAP_NO_INSTALL` | Never offer the `winget` installation; print the manual alternative instead. |
| `WT_BOOTSTRAP_PWSH` | Explicit executable to probe and hand off to (release engineering and tests). |
| `WT_BOOTSTRAP_LANGUAGE` / `WT_BOOTSTRAP_COLOUR` / `WT_BOOTSTRAP_ASCII` / `WT_BOOTSTRAP_WORKER_BACKEND` | Options forwarded to the interface when the bootstrap is invoked through `irm \| iex` (which cannot pass parameters). `WT_LANG` is the language fallback. |
| `WT_BOOTSTRAP_HANDOFF`, `WT_BOOTSTRAP_DEPTH`, `WT_BOOTSTRAP_PARENT` | Internal loop-prevention markers; set by the bootstrap for the child process, never by a user. |

Self-hosting: point `WT_BOOTSTRAP_RELEASE_URL` at the release's own `manifest.json`. Its
`assets[].browser_download_url` values must be allowed hosts, and the archives must be reachable
at those URLs with the sizes and hashes the manifest states.

## Security properties it states about itself

* A hash taken from the same release is **integrity relative to that source**, not independent
  publisher authentication. The same sentence is printed on success.
* No unverified fallback: if verification cannot complete, the bootstrap fails explicitly, and a
  staging directory that failed validation carries no completion marker, so it can never be
  launched as if it were valid.
* No elevation is requested to download or start the interface. Installing PowerShell is a
  separate, explicitly confirmed `winget` action; declining it returns to the shell.
* The console output encoding and the process-wide TLS setting are saved and restored on every
  path (success, failure, cancellation), so the caller's session is left as it was.
* If the network fails and a verified cache exists, the offline launch is offered only after
  explicit confirmation (interactive `[y/N]`); a silent substitution never happens.
* The lock is per staged tag, so two concurrent bootstraps do not interleave.

## Release archives

Produced by `tools/New-ReleasePackage.ps1`; the full contract, the validation it performs and the
publishing steps are in [RELEASE.md](RELEASE.md). Each archive holds `WindowsTweaker.ps1`,
`PSScriptAnalyzerSettings.psd1`, `THIRD-PARTY-NOTICES.md`, the module tree under
`src/WindowsTweaker/`, `licenses/**` verbatim, the matching Go worker binary, and the internal
`manifest.json`. `checksums.txt` and the external release `manifest.json` are written beside the
archives and are not part of any archive.

## Executed vs not executed

Executed here (Linux host, PowerShell 7.6.9): the launcher executed from downloaded text
(`irm ... | iex` against a local HTTP fixture, and `iex` of the file text) with session survival,
code mirroring and function cleanup; the launcher's explicit decode with and without a leading
`U+FEFF`, the protocol refusal, the option forwarding and the refuse-non-HTTPS policy; file
execution of the launcher reaching the implementation beside it; the implementation's
piped-text execution path; **the download path's body reader over a real `HttpContent` and over a
real HTTP socket, including the size bound** (section 15); the platform mapping; the 7.4 runtime
guard; exact asset selection, ambiguity refusal and platform-declaration mismatch; refusal of
non-HTTPS and non-allow-listed URLs; redirect-hop validation including the real GitHub asset host;
checksum parsing; traversal-safe extraction; manifest validation (schema, platform, entry point,
protocol, canonical worker path, per-file size and hash); the no-bypass cache rule; the launch step
with no arguments and exit-code propagation; a full rehearsal of the verification chain on a real
generated archive; and the real published release (`v1.0.0`) downloaded from GitHub,
SHA-256-verified, staged and launched into the terminal interface. `tests/Bootstrap.Tests.ps1`
holds these, and `tests/ReleasePackage.Tests.ps1` drives the real archive. Evidence:
[VALIDATION.md](VALIDATION.md) sections 3, 11, 12, 13, 14 and 15.

**Not executed anywhere**: `irm | iex` on a Windows host, the download helpers on Windows
PowerShell 5.1 (no 5.1 host and no Windows host was available; the two 5.1 failures were reported
from the field and are reproduced here on PowerShell 7.6.9 with the identical error text and line
numbers), the Windows branch of the state directory, and the interactive offline confirmation. The
failure mode of the *published* `main` ref is reproduced in section 13 of
[VALIDATION.md](VALIDATION.md); the fixed public command can only be verified against `main` after
this change is merged, and the opt-in live tests (`WT_BOOTSTRAP_LIVE_TEST=1`) do exactly that -
including the streaming test that runs the whole downloader on whichever runtime executes it.
