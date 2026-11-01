# Third-party notices and provenance

## Sophia Script for Windows (upstream source of this repository's first revision)

The initial revision of this project (`modules\*.ps1` and the file now kept at
`reference/original-upstream-reference.txt`) consists of functions extracted from
**Sophia Script for Windows** by farag2:

* Project: https://github.com/farag2/Sophia-Script-for-Windows
* License: MIT, Copyright (c) 2023 farag2
* Full license text: `licenses/Sophia-Script-for-Windows-MIT.txt`

That license and copyright notice are preserved here. Modules and tweak definitions
that keep upstream logic carry an attribution comment naming Sophia Script and its
MIT licence. Compatible with the MIT terms, the code has been substantially
rewritten:

* LGPO policy transcripts replaced with direct, reversible registry operations
  (LGPO is not bundled and is never downloaded);
* inline `Add-Type` C# helpers, `Invoke-Expression`, System32 executable copies and
  download-and-execute paths removed;
* initialization split into a read-only environment probe (`Get-WtEnvironment`) and
  explicit, individually reversible tweaks.

## Components that are NOT bundled

The previous revision expected these files in a `Binaries` directory that does not
exist in this repository (the missing directory was one of the reported defects).
They are **not** shipped here - nothing in this project downloads or ships binaries:

| Component | Owner | Why it is not bundled |
|---|---|---|
| `LGPO.exe` | Microsoft (Security Compliance Toolkit) | Not required: policy values are written directly through the registry provider |
| `WinRT.Runtime.dll` | Microsoft (MIT, Microsoft.Windows.CsWinRT) | Only needed by the legacy WPF/WinRT Appx helpers, which were removed |
| `Microsoft.Windows.SDK.NET.dll` | Microsoft (MIT, Microsoft.Windows.CsWinRT) | Same as above |

Nothing in this repository redistributes third-party *prebuilt* binaries or fonts: no vendor
drop, no downloaded `LGPO.exe`, no Microsoft DLLs. The only third-party code that ships is
the compiled Go worker, whose statically linked modules and their licences are listed under
"Optional Go worker" below. The WPF interface uses fonts and glyphs already present in
Windows (`Segoe UI`, `Segoe Fluent Icons`).

## Microsoft Activation Scripts (MAS) - a downloaded external tool, not bundled

`Licensing & Activation` can download and launch **Microsoft Activation Scripts**, a third-party
Windows/Office activator, as an external tool at the user's explicit request. Details, including
the pinned commit, are in [docs/EXTERNAL-TOOLS.md](docs/EXTERNAL-TOOLS.md).

* Project: https://github.com/massgravel/Microsoft-Activation-Scripts
* Licence: **GNU GPL v3** (the `LICENSE` in that repository)
* Pinned by this repository: tag `3.12`, commit `40c74d0d7f42146b1dd1ab59b5c7e836d6a56d1f`,
  file `MAS/All-In-One-Version-KL/MAS_AIO.cmd`, 761,964 bytes,
  SHA-256 `850f979665fb93999acae93f4790c1ff8ed2041532060b7966a121c2d29a0bfa`
  (that digest was computed by this project; upstream publishes no checksum or signature)

No MAS source is included in this repository: nothing is copied, ported or linked, and no
derivative work is created. The file is fetched over HTTPS from the official repository at that
commit, into the user's own data directory, only when the user asks for it.

**If a distribution ever ships that file**, it distributes a GPL-3.0 work and must meet the GPL-3.0
obligations for it: ship the licence text, make the corresponding source available under GPL-3.0,
impose no additional restrictions, and keep it clearly separate from this project's own terms. The
GPL-3.0 does not apply to WindowsTweaker's own code merely because it can download that file.

## Reference projects consulted for product ideas

The features added after the initial revision were designed with the following projects as
product inspiration only: `windows-11-practical-scripts`, `Windows-Telemetry-OFF`,
`remove-hidden-devices`, `debora`, `darkhub-suite`, `PrivacyPenguin` (documentation only, never
inspected or reused as source), `WinSpectorPro`, `ZapTweaks` and `win-Tweak`. No code from any
of them was imported: the Go worker and every PowerShell module here are original, and no
licence obligation arises from them.

## Project licence

This repository contains **no** licence file of its own: the initial archive did not
ship one, and inventing a licence for someone else's project is not something this
work may do. **Unresolved**: the repository owner must choose a licence that is
compatible with the upstream MIT terms above (MIT is the obvious candidate since all
derived code originates from MIT-licensed sources) and add it before distributing
the project.

Until then, note that the MIT notice for the derived portions must remain intact.

## Optional Go worker (`worker/`)

The optional worker is a separate Go module (`wintweaker.dev/worker`). It is **not** standard
library only: `worker/go.mod` declares 22 requirements, `worker/go.sum` pins every one of
them, and the table below lists the modules that are actually linked into the shipped
binaries. `go list -m all` lists them and `go mod verify` verifies them; the source of the
list is `go version -m worker/bin/linux-amd64/wt-worker`, which reports the build's own
dependency list, so a module that is only pulled in by tests is not in it.

| Module | Version | Licence | Licence text |
|---|---|---|---|
| `github.com/beorn7/perks` | v1.0.1 | MIT | `licenses/go-worker/beorn7-perks-MIT.txt` |
| `github.com/cespare/xxhash/v2` | v2.3.0 | MIT | `licenses/go-worker/cespare-xxhash-v2-MIT.txt` |
| `github.com/dustin/go-humanize` | v1.0.1 | MIT | `licenses/go-worker/dustin-go-humanize-MIT.txt` |
| `github.com/google/uuid` | v1.6.0 | BSD-3-Clause | `licenses/go-worker/google-uuid-BSD-3-Clause.txt` |
| `github.com/munnerz/goautoneg` | v0.0.0-20191010083416-a7dc8b61c822 | BSD-3-Clause | `licenses/go-worker/munnerz-goautoneg-BSD-3-Clause.txt` |
| `github.com/prometheus/client_golang` | v1.25.0 | Apache-2.0 | `licenses/go-worker/prometheus-client_golang-Apache-2.0.txt`, `...-NOTICE.txt` |
| `github.com/prometheus/client_model` | v0.6.3 | Apache-2.0 | `licenses/go-worker/prometheus-client_model-Apache-2.0.txt`, `...-NOTICE.txt` |
| `github.com/prometheus/common` | v0.72.0 | Apache-2.0 | `licenses/go-worker/prometheus-common-Apache-2.0.txt`, `...-NOTICE.txt` |
| `github.com/prometheus/procfs` | v0.22.0 | Apache-2.0 | `licenses/go-worker/prometheus-procfs-Apache-2.0.txt`, `...-NOTICE.txt` |
| `github.com/remyoudompheng/bigfft` | v0.0.0-20230129092748-24d4a6f8daec | BSD-3-Clause | `licenses/go-worker/remyoudompheng-bigfft-BSD-3-Clause.txt` |
| `golang.org/x/sys` | v0.48.0 | BSD-3-Clause | `licenses/go-worker/golang-x-sys-BSD-3-Clause.txt` |
| `google.golang.org/protobuf` | v1.36.12 | BSD-3-Clause | `licenses/go-worker/google-protobuf-BSD-3-Clause.txt` |
| `modernc.org/libc` | v1.55.3 | BSD-3-Clause | `licenses/go-worker/modernc-libc-BSD-3-Clause.txt` |
| `modernc.org/mathutil` | v1.6.0 | BSD-3-Clause | `licenses/go-worker/modernc-mathutil-BSD-3-Clause.txt` |
| `modernc.org/memory` | v1.8.0 | BSD-3-Clause | `licenses/go-worker/modernc-memory-BSD-3-Clause.txt` |
| `modernc.org/sqlite` | v1.34.0 | BSD-3-Clause | `licenses/go-worker/modernc-sqlite-BSD-3-Clause.txt` |

The texts under `licenses/go-worker/` are verbatim copies taken from the module cache at the
exact versions above; the Prometheus modules' `NOTICE` files are included as their licence
requires. The Go standard library itself is covered by the Go licence (BSD-3-Clause), and the
toolchain used to build the binaries is named by `go version -m` on each one.

