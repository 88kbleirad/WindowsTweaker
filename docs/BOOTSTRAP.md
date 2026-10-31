# Bootstrap: install and launch

`bootstrap/bootstrap.ps1` is the installer launcher. It is a single script meant to be executed
as **text** (`irm <url> | iex`), so it uses no `$PSScriptRoot`, no `$PSCommandPath` and no
caller working directory, and it never calls `exit()`. Everything below is read from that file;
line numbers refer to it.

## Hosting status (read this first)

* `deploy/short-url/` contains one file, `nginx-win.conf` - a prepared nginx server block. **Nothing
  is deployed.** There is no CI workflow in this repository (no `.github/`) that publishes it.
* The script's own usage header and its default metadata URL contain placeholders, not real hosts:
  `https://YOUR_DOMAIN/win` and
  `https://raw.githubusercontent.com/YOUR_GITHUB_OWNER/WindowsTweaker/main/bootstrap/bootstrap.ps1`
  (lines 4-5), and the default release metadata URL is
  `https://api.github.com/repos/YOUR_GITHUB_OWNER/WindowsTweaker/releases/latest` (lines 165-166).
* **There is no working public URL today.** `irm | iex` works only after someone hosts the script
  and the release assets (or points `WT_BOOTSTRAP_RELEASE_URL` at their own metadata) with the
  placeholders filled in. Otherwise, run from a checkout: `pwsh -NoProfile -File ./WindowsTweaker.ps1`
  from the repository root (the entry point requires PowerShell 7.4); see `docs/CLI.md` for the
  command line.

The nginx file states what the `/win` route must serve: `bootstrap/bootstrap.ps1` as plain text
(`text/plain; charset=utf-8`), no HTML wrapper, no auth page, no redirect; DNS is out of scope for
the repository.

## The piped-text flow, in order

| Step | Function (line) | What it enforces |
|---|---|---|
| 1. Runtime guard | `Assert-WtBootstrapRuntime` (427) | PowerShell ≥ 7.4, otherwise a message telling the user to run `pwsh` (431). A wrong runtime cannot select a right release. |
| 2. Platform key | `Get-WtBootstrapPlatformKey` (71) | `win-x64`, `win-arm64`, `linux-x64`, `linux-arm64` from the **OS architecture**; any other architecture throws (85). |
| 3. Release metadata | `Get-WtBootstrapRelease` (164) | `GET` of `WT_BOOTSTRAP_RELEASE_URL` or the default URL above; body capped at 2 MiB (168); `tag_name` required (170). |
| 4. Asset selection | `Get-WtBootstrapAsset` (178) | Exact name match `WindowsTweaker-<key>-<version>.zip` or `WindowsTweaker-<key>.zip` (188-191); zero candidates throws (193); several candidates resolve only when exactly one is versioned, otherwise it throws (195-199). |
| 5. Download | `Get-WtBootstrapAssetBytes` (208), `Get-WtBootstrapContent` (95) | HTTPS only (106); host must be in the allow-list (100-104, 115); redirects are followed manually, max 10, each hop re-checked (118-127); response capped at `asset.size + 1 MiB`, and the byte count must equal `asset.size` exactly (217). |
| 6. SHA-256 | `Get-WtBootstrapExpectedHash` (227), `Test-WtBootstrapHash` (250) | Hash is read from a `checksums.txt`/`checksum.txt` asset **of the same release** (232-239) and compared case-insensitively (255-257). If no checksum asset exists, the bootstrap refuses to continue (501-503). |
| 7. Staging | `Get-WtBootstrapStaging` (345), `Expand-WtBootstrapArchive` (265) | Version-tagged directory under the state dir with a `.lock` created `CreateNew`, 60 s deadline (355-370). Extraction rejects absolute paths and `..` segments (279-280) and re-checks every target against the base via `Join-WtBootstrapPath` (52). |
| 8. Release validation | `Test-WtBootstrapRelease` (304) | `manifest.json` present, `schemaVersion` must be 1 (317), required files present (321-326): `WindowsTweaker.ps1`, `src/WindowsTweaker/WindowsTweaker.psd1`, `worker/bin/<key>/wt-worker[.exe]`, `THIRD-PARTY-NOTICES.md`; `workerProtocol` must be 1 when declared (335). |
| 9. Launch | `Resolve-WtBootstrapEntryPoint` (376), `Invoke-WtBootstrapLaunch` (389) | Starts `pwsh -NoProfile -File <entry point>` as a child process (399-411), waits, and returns its exit code (412). |
| 10. Return | entry block (522-532) | No `exit()`: the exit code is mirrored into `$LASTEXITCODE` so the caller's session survives (including the failure path, which writes an error and returns 1). |

A release whose tag is already staged with a valid `manifest.json` + `WindowsTweaker.ps1` is
launched directly, without downloading (491-493).

## State directory

`Get-WtBootstrapStateDir` (40): `WT_BOOTSTRAP_STATE_DIR` if set, else
`%LOCALAPPDATA%\WindowsTweaker-bootstrap` on Windows, else `$XDG_CACHE_HOME/WindowsTweaker-bootstrap`
(or `~/.cache/WindowsTweaker-bootstrap`). Only staging lives here; user settings, metrics, journal and
recovery data are untouched, and the cleanup in the `finally` block removes only the lock file
(513-515).

## Overrides

| Variable | Effect |
|---|---|
| `WT_BOOTSTRAP_RELEASE_URL` | Release metadata JSON URL instead of the GitHub API default (165). |
| `WT_BOOTSTRAP_STATE_DIR` | Staging/state directory (41-42). |
| `WT_BOOTSTRAP_ENTRYPOINT` | Force the entry point script to launch (378-380). |
| `WT_BOOTSTRAP_ALLOW_OFFLINE` | Only read when `WT_BOOTSTRAP_ENTRYPOINT` or `WT_BOOTSTRAP_RELEASE_URL` is set: launch the cached release without asking (465-470); without it, that branch fails explicitly (470). |
| `WT_BOOTSTRAP_TEST_ONLY` | Skip the entry block entirely, so the script can be dot-sourced for authoring and tests (522). |

Note for self-hosting: the metadata URL goes through the same `Get-WtBootstrapContent`, so its host
must be one of the six allow-listed hosts (100-104) - a private host is refused unless the list is
changed in the script.

## Security properties it states about itself

From the header (lines 21-29) and the code:

* A hash taken from the same release is **integrity relative to that source**, not independent
  publisher authentication. The same sentence is printed on success (505).
* No unverified fallback: if verification cannot complete, the bootstrap fails explicitly.
* No elevation is requested to download or start the interface.
* If the network fails and a valid cache exists, the offline launch is offered only after explicit
  confirmation (interactive `[y/N]`, 472-478); a silent substitution never happens.
* The lock is per staged tag, so two concurrent bootstraps do not interleave (355-370).

## Release archives

Produced by `tools/New-ReleasePackage.ps1 -Version <v> -OutDir <dir>` (the optional
`-WorkerProtocol` defaults to 1). Before packaging it runs `tools/Parse-All.ps1` and **refuses to
package a tree that does not parse**, imports the module and refuses if the module version differs
from `-Version`, and refuses a platform whose worker binary is missing (`worker/bin/<os>-<arch>/`).

Each `WindowsTweaker-<platform>-v<version>.zip` contains: `WindowsTweaker.ps1`,
`PSScriptAnalyzerSettings.psd1`, `THIRD-PARTY-NOTICES.md`, a root `LICENSE` **only if that file
exists** (this repository has none), the module tree under `src/WindowsTweaker/` (excluding `Data/`
and `GUI/` except their `.json`/`.psd1`/`.ps1`/`.xaml` files), `licenses/**` verbatim, and the
matching Go worker binary. `checksums.txt` (ASCII, two spaces, name) and `manifest.json`
(`schemaVersion` 1: version, engineVersion, workerProtocol, createdUtc, per-asset name/platform/os/
arch/version/bytes/sha256, plus a note repeating the same-source-integrity caveat) are written
beside the archives.

Every archive is then re-opened and checked: required entries (entry point, notices, module
manifest, the platform worker binary, and the two `licenses/go-worker/` notices for the statically
linked modules) and no entry containing `..` or an absolute path. Publishing is not part of the
tool. Executed evidence and archive contents: `docs/VALIDATION.md` section 11.

## Executed vs not executed

`tests/Bootstrap.Tests.ps1` (12 tests, Pester; table in `docs/VALIDATION.md` section 3) runs on
Linux and covers, at function level: text execution with no script-path variables and no `exit()`;
platform-key mapping including ARM64 and the 32-bit refusal; the 7.4 runtime guard; exact asset
selection and ambiguity refusal; refusal of non-HTTPS and non-allow-listed hosts; the empty result
when no checksums exist; hash mismatch; traversal-safe extraction; spaces/Unicode paths; the
manifest/key-file requirement; and that no app state or settings file is written. The text-execution
tests point `WT_BOOTSTRAP_RELEASE_URL` at a non-HTTPS URL, so no network request is ever made.

**Never executed anywhere**, because the flow needs a real GitHub release and a Windows host:

* A real HTTPS fetch of release metadata, the redirected asset download, and the sizes/hashes of
  actual published archives - the only network path exercised is an immediate refusal.
* The success path of checksum lookup (a hash found and matched against a real archive), and the
  successful extraction and validation of a real release.
* Launching the entry point as a child process and propagating its exit code; the tests set
  `WT_BOOTSTRAP_ENTRYPOINT` to a non-existent path and fail before launch.
* The interactive offline-cache confirmation and the `WT_BOOTSTRAP_ALLOW_OFFLINE` branch; the lock
  timeout; the manifest `schemaVersion`/`workerProtocol` success comparisons.
* Every Windows branch: the `%LOCALAPPDATA%` default, `wt-worker.exe`, and the whole `irm | iex`
  invocation on a Windows host with PowerShell 7.4+.

Running the interface from a checkout instead is documented in `docs/CLI.md`; worker protocol
details are in `docs/WORKER.md`.
