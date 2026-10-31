# Bootstrap: install and launch

`bootstrap/bootstrap.ps1` is the installer launcher. It is a single script meant to be executed
as **text** (`irm <url> | iex`), so it uses no `$PSScriptRoot`, no `$PSCommandPath` and no
caller working directory, it never calls `exit()`, it leaves no functions behind in the
caller's session, and the only session state it writes is `$LASTEXITCODE`.

```powershell
irm "https://raw.githubusercontent.com/88kbleirad/WindowsTweaker/main/bootstrap/bootstrap.ps1" | iex
```

This is the one documented command, and it runs on **Windows PowerShell 5.1 and PowerShell 7**.
The file is 5.1-parseable and carries a UTF-8 BOM so 5.1 decodes its Vietnamese messages
correctly; below 5.1 it refuses with a bilingual explanation instead of selecting a wrong release.

## Runtimes: what happens on each one

| Current runtime | What the bootstrap does |
|---|---|
| Windows PowerShell 5.1 (the console included with Windows) | Stages and validates the release **on 5.1**, then starts the interface on a compatible stable PowerShell 7 (7.4-7.6) when one is installed. If none is installed it offers the `winget` installation once (consent required) and re-discovers the executable afterwards. Declining, cancelling or a failed installation continues **natively on 5.1** with a bilingual notice. |
| PowerShell 7.4 - 7.6 (stable) | Runs the interface natively in this session; no second process. |
| PowerShell 7.0 - 7.3, 7.7+, 8.x, preview | Runs natively and prints a notice naming the validated range. Preview builds are never selected as a handoff target. |
| older than 5.1 | Refused (`#Requires -Version 5.1` and an explicit bilingual message); the session stays usable. |

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
* **No release is published yet.** Until one is, that default URL answers `HTTP 404` and the
  bootstrap fails with `Could not resolve release metadata: HTTP 404 ...` - it never falls back
  to something unverified. Publish the assets described in [RELEASE.md](RELEASE.md) and the
  command above starts working.
* `deploy/short-url/nginx-win.conf` is a prepared nginx server block for hosting the same script
  on a short URL. Nothing is deployed; its `YOUR_DOMAIN` is a hosting placeholder, not a
  repository value.

## The piped-text flow, in order

| Step | Function | What it enforces |
|---|---|---|
| 1. Runtime guard | `Get-WtBootstrapRuntimeProfile`, `Assert-WtBootstrapRuntime` | Reads version/edition/platform without `$IsWindows`; refuses only a runtime below 5.1, with a bilingual message. |
| 2. Platform key | `Get-WtBootstrapPlatformKey` | `win-x64`, `win-arm64`, `linux-x64`, `linux-arm64` from the **OS architecture**; any other architecture throws. |
| 3. Release metadata | `Get-WtBootstrapRelease` | `GET` of `WT_BOOTSTRAP_RELEASE_URL` or the default API URL; body capped at 2 MiB; `tag_name` and `assets` required. The release `manifest.json` published beside the archives is accepted as well, which is what makes self-hosting possible. |
| 4. Asset selection | `Get-WtBootstrapAsset` | Exact name match `WindowsTweaker-<key>-<version>.zip` or `WindowsTweaker-<key>.zip`; zero candidates throws; several candidates resolve only when exactly one is versioned, otherwise it throws; when the asset declares a `platform` (our manifest does) it must equal this host's key. |
| 5. Download | `Get-WtBootstrapAssetBytes`, `Get-WtBootstrapContent` | HTTPS only; every hop checked against the allowed-host list; redirects followed manually (max 10), each hop re-validated; response capped at `asset.size + 1 MiB` and the byte count must equal `asset.size` exactly. |
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
| `WT_BOOTSTRAP_TEST_ONLY` | Skip the entry block entirely, so the script can be dot-sourced for authoring, tests and `tools/New-ReleasePackage.ps1`. |
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

Executed here (Linux host, PowerShell 7.6.9): the piped-text execution path including
session-survival and function cleanup; the platform mapping; the 7.4 runtime guard; exact asset
selection, ambiguity refusal and platform-declaration mismatch; refusal of non-HTTPS and
non-allow-listed URLs; redirect-hop validation including the real GitHub asset host; checksum
parsing; traversal-safe extraction; manifest validation (schema, platform, entry point, protocol,
canonical worker path, per-file size and hash); the no-bypass cache rule; the launch step with no
arguments and exit-code propagation; and a full rehearsal of the verification chain on a real
generated archive (checksum, extraction, validation, staging marker, cache lookup, launch).
`tests/Bootstrap.Tests.ps1` holds these, and `tests/ReleasePackage.Tests.ps1` drives the real
archive. Evidence: [VALIDATION.md](VALIDATION.md) sections 3, 11 and 12.

**Not executed anywhere**: downloading a WindowsTweaker release from GitHub (none is published),
`irm | iex` on a Windows host, the Windows branch of the state directory, and the interactive
offline confirmation - the opt-in live tests exercise the transport against a public release of
another project instead. Until a release is published and a user downloads and launches it, no
claim is made that the public command works end to end.
