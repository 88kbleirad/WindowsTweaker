# Release: packaging, assets and publishing

This document is the exact procedure for producing and publishing a WindowsTweaker release.
Everything in the "Local packaging" section is a repository tool and runs offline. Release
`v1.0.0` is published (tag `v1.0.0`); module version `1.0.1` is packaged locally and **not
published**, and its `dist/` output sits beside the preserved `v1.0.0` files under `dist/v1.0.0/`.
The `v1.0.0` archives were downloaded, SHA-256-verified and staged by the bootstrap during the
launcher fixes ([VALIDATION.md](VALIDATION.md) sections 13, 14 and 15). Adding a release does not
change either bootstrap file, and changing a bootstrap file does not require a new release: neither
file is packaged.

## 1. What a release consists of

| Asset | Produced by | Consumed by |
|---|---|---|
| `WindowsTweaker-win-x64-v<version>.zip` | `tools/New-ReleasePackage.ps1` | the bootstrap, on a Windows x64 host |
| `WindowsTweaker-win-arm64-v<version>.zip` | same | the bootstrap, on a Windows ARM64 host |
| `WindowsTweaker-linux-x64-v<version>.zip` | same | the bootstrap, on a Linux x64 host |
| `WindowsTweaker-linux-arm64-v<version>.zip` | same | the bootstrap, on a Linux ARM64 host |
| `checksums.txt` | same | the bootstrap: the SHA-256 it verifies the download against |
| `manifest.json` | same | release review, and `WT_BOOTSTRAP_RELEASE_URL` for self-hosters |

The bootstrap resolves the asset by name (`WindowsTweaker-<platform key>-v<version>.zip`), reads
the checksum from `checksums.txt` **of the same release**, downloads, verifies, extracts into the
staging directory and validates what it staged. A missing `checksums.txt` is a hard failure: the
bootstrap refuses to stage unverified content.

## 2. Local packaging (offline, no publish)

```bash
pwsh -NoProfile -File tools/New-ReleasePackage.ps1 -Version 1.0.0 -OutDir ./dist
```

* `-Version` must equal `ModuleVersion` in `src/WindowsTweaker/WindowsTweaker.psd1`; the tool
  refuses a mismatch, so the archives always carry the module's real version.
* The tool first builds the Go workers for exactly the selected platforms (`-Platforms <keys>`
  restricts the set; the default is all four). `-SkipWorkerBuild` uses binaries already in
  `worker/bin/<goos>-<goarch>/`. Both paths check that the binary exists and is not empty.
* Fast single-platform run, used by the tests:

  ```bash
  pwsh -NoProfile -File tools/New-ReleasePackage.ps1 -Version 1.0.0 -Platforms linux-x64 -OutDir /tmp/wt-dist
  ```

What it writes inside each archive beyond the module, the licence texts and the entry point:

* the worker binary at the **canonical** path for that platform key (`worker/bin/<goos>-<goarch>/`,
  the same directory the Go build writes to and the client resolves), stored with the executable
  bit so a Linux staging keeps it runnable;
* `manifest.json` - the **internal package manifest**, written before the archive is closed so the
  archive hash published afterwards covers it: `schemaVersion`, `version`, `engineVersion`,
  `platform`, `os`, `arch`, `entryPoint`, `workerProtocol`, the canonical `worker` path with its
  size and SHA-256, and every packaged file with its size and SHA-256. It deliberately contains no
  archive hash; a hash of the archive inside the archive cannot be checked against anything.

What it writes beside the archives: `checksums.txt` (`<sha256>  <name>`) and the **external release
manifest** `manifest.json` - `tag_name`, `version`, `engineVersion`, `workerProtocol`, and per
asset `name`, `platform`, `os`, `arch`, `workerPath`, `version`, `size`, `sha256`,
`browser_download_url`. Neither file is inside an archive, so no archive hash depends on them.

## 3. Validation the tool performs before it prints "Packaged"

For every archive it just wrote:

1. the file's SHA-256 is compared with the line `checksums.txt` carries for it, using
   `Test-WtBootstrapHash` from `bootstrap/implementation.ps1`;
2. the bytes are extracted with `Expand-WtBootstrapArchive` (traversal-safe);
3. `Test-WtBootstrapRelease` checks the internal manifest: schema, platform identity, entry point,
   `workerProtocol`, the canonical worker path for the platform, the required files
   (`WindowsTweaker.ps1`, `src/WindowsTweaker/WindowsTweaker.psd1`, the platform worker,
   `THIRD-PARTY-NOTICES.md`), and the size **and** SHA-256 of every file the manifest declares;
4. the internal manifest is asserted to carry no archive hash, and to declare exactly the archive's
   entries (minus itself);
5. on a host that is the archive's own platform, the shipped client is imported from the staged
   directory and asked for its worker: the resolved path must be the manifest's path, the
   handshake must succeed and the protocol must be the packaged one.

A failure throws; the tool never reports a package it could not verify, and the release workflow
publishes only after this step and the test suite succeeded.

## 4. Publishing (needs authorization)

Either push a tag whose name is `v<version>` matching `ModuleVersion`, which runs
`.github/workflows/release.yml`, or run that workflow manually with the version as input. The
workflow builds the workers, packages, runs `tests/Bootstrap.Tests.ps1` and
`tests/ReleasePackage.Tests.ps1`, and then uploads the six files with:

```bash
gh release create "v$VERSION" \
  "dist/WindowsTweaker-win-x64-v$VERSION.zip" \
  "dist/WindowsTweaker-win-arm64-v$VERSION.zip" \
  "dist/WindowsTweaker-linux-x64-v$VERSION.zip" \
  "dist/WindowsTweaker-linux-arm64-v$VERSION.zip" \
  dist/checksums.txt \
  dist/manifest.json \
  --title "WindowsTweaker v$VERSION" --generate-notes --verify-tag
```

Manual equivalent: run the packaging command from section 2, then upload **exactly** those six
files to the release - not a re-zipped copy, not a subset. Renaming an archive breaks asset
selection; omitting `checksums.txt` breaks verification; both are hard failures at the user's end.

After publishing, verify as a user would (a real download is the only proof):

```powershell
$State = Join-Path $env:TEMP 'wt-bootstrap-check'
$env:WT_BOOTSTRAP_STATE_DIR = $State
irm "https://raw.githubusercontent.com/88kbleirad/WindowsTweaker/main/bootstrap/bootstrap.ps1" | iex
```

The bootstrap prints the resolved tag, the platform key, that the SHA-256 matched, and the staging
path, then opens the interface. Check the staged `manifest.json` under `$State/release-<tag>/`
against `dist/manifest.json` before trusting the run.

## 5. What has been validated here, and what has not

| Claim | Status |
|---|---|
| Workers build for all four platforms, archives are produced and validated | **Executed** on Linux: four archives, 143 file hashes each, worker handshake on the host platform (`docs/VALIDATION.md` section 11) |
| Checksum -> extraction -> manifest validation -> worker-path resolution on a real archive | **Executed**: `tests/ReleasePackage.Tests.ps1` |
| GitHub's real asset redirect (`github.com` -> `release-assets.githubusercontent.com`) and the allowed-host list | **Executed** against a public release of another project (`WT_BOOTSTRAP_LIVE_TEST=1`) |
| Staging into the cache, cache lookup, launch of the staged entry point and exit-code propagation | **Executed** with the generated archive on Linux |
| Packaging module version `1.0.1` after the streaming fix | **Executed**: four archives rebuilt with `tools/New-ReleasePackage.ps1 -Version 1.0.1`, each validated (146 file hashes, worker handshake), `version`/`engineVersion` `1.0.1` in both manifests and `ModuleVersion` `1.0.1` inside each archive. Not published, and the `v1.0.0` tag and release were not touched. |
| A real end-to-end run of the published command on Linux: release resolution, asset download, SHA-256 check, staging, launch into the terminal interface | **Executed** for the published `v1.0.0` during the launcher fix - `bootstrap/bootstrap.ps1` resolved `releases/latest`, downloaded `WindowsTweaker-linux-x64-v1.0.0.zip`, verified its hash against `checksums.txt`, staged it and started the interface (`docs/VALIDATION.md` section 13) |
| The same end-to-end run on a Windows host (Windows PowerShell 5.1 and PowerShell 7) in a real console | **NOT executed** - no Windows host was available. Both 5.1 failures (the BOM parse failure and the synchronous `ReadAsStream` call) were reported from the field and reproduced on PowerShell 7.6.9 with the identical error text (`docs/VALIDATION.md` sections 13, 14 and 15). |
