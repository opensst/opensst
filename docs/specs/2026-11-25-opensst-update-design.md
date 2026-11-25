# OpenSST Update Design

Date: 2026-11-25
Status: Approved 2026-11-25; implementation complete 2026-11-25 (uncommitted)

## Relationship to the base design

This spec extends `docs/specs/2026-11-25-opensst-design.md`. It adds an explicit
self-update command, an Arch package, and the release assets needed to support
those features. It does not change `open`, `list`, `kill`, reconnect behavior,
SSH validation, or remote tmux command construction.

The base design's non-goal "no automatic package-manager updates" remains
true: updates happen only when the user explicitly runs `sst update`. The base
design's "no GPG or Sigstore artifact signing" also remains true. Checksums
provide integrity checking, not publisher authentication.

## Summary

`sst update` detects how the running `sst` was installed, downloads the latest
stable GitHub Release asset for that installation method, verifies its SHA-256
checksum, compares versions, asks for confirmation, and delegates the upgrade
to the owning package manager or performs an atomic source-file replacement.

Supported installation methods are DEB packages, RPM packages, pacman packages
(including packages installed from AUR or archlinuxcn), and source installs.
Arch users do not need archlinuxcn or an AUR helper for updates; Arch is treated
like DEB and RPM: download a release package and install it locally with
`pacman -U`.

## Goals

- Add `sst --version`, reporting the embedded stable version.
- Add explicit `sst update`, `sst update --check`, and `sst update --yes`.
- Detect DEB, RPM, pacman, and source installations without guessing from the
  operating system alone.
- Keep package-manager file ownership intact; never overwrite `/usr/bin/sst`
  directly when a package manager owns it.
- Upgrade Arch through a release-built `opensst.pkg.tar.zst` and `pacman -U`.
- Upgrade source installs atomically, with a backup and post-install sanity
  check.
- Publish stable asset aliases so updates need no GitHub API, JSON parser, `jq`,
  or `gh`.
- Fail closed on unknown installations, checksum mismatches, missing assets,
  and refused downgrades.
- Keep every automated update test offline and independent of a real
  installation.

## Non-goals

- No cryptographic signing, Sigstore, or attestations.
- No background update checks, automatic updates, or update-on-every-command.
- No GitHub API dependency or release-metadata service.
- No self-hosted apt/dnf/pacman repository.
- No AUR packaging or archlinuxcn submission in this scope.
- No update support for Windows, macOS, or non-Linux systems.
- No automatic rollback guarantee for package-manager upgrades.
- No configuration file or update policy file.
- No change to remote SSH behavior or the existing PTY hardening backlog.

## User-facing behavior

```text
sst --version
sst update --check
sst update
sst update --yes
```

- `sst --version` prints exactly `sst <version>` to stdout and exits 0.
- `sst update --check` detects the install method, downloads the latest asset
  and checksum, prints the installed and latest versions, and exits without
  writing files or invoking `sudo`.
- `sst update` performs the same check, prints the planned action, and asks for
  confirmation before applying.
- `sst update --yes` skips confirmation. It is required when stdin or stdout is
  not a terminal.
- `--check` and `--yes` are mutually exclusive.
- Unknown arguments or extra positional arguments exit 2.
- A user who declines confirmation exits 0 without changing anything.
- An up-to-date installation prints an up-to-date message and exits 0.
- A latest release older than the installed version is never installed. The
  command prints a no-downgrade message and exits 0.

## Version contract

The executable contains a single line of the form:

```bash
SST_VERSION='0.1.0'
```

Release versions are stable `MAJOR.MINOR.PATCH` identifiers. The release
workflow's `version` input must equal `SST_VERSION`; a mismatch fails release
validation before tests or packaging run.

Packages are built from the same `bin/sst`, so the packaged command reports the
same version. Versioned package asset names include the version; stable aliases
do not.

The version comparison ignores Debian/RPM epochs and package release suffixes,
including Arch `pkgrel`. Only the three numeric components participate. This is
sufficient because only stable `MAJOR.MINOR.PATCH` releases are accepted.

## Release assets

Each release publishes both versioned assets and stable aliases:

```text
sst
opensst.deb
opensst.rpm
opensst.pkg.tar.zst
SHA256SUMS
opensst_<version>_all.deb
opensst-<version>-1.noarch.rpm
opensst-<version>-1-any.pkg.tar.zst
```

- `sst` is a copy of `bin/sst` for source installations.
- `opensst.deb` is a copy of the versioned DEB.
- `opensst.rpm` is a copy of the versioned RPM.
- `opensst.pkg.tar.zst` is a copy of the versioned Arch package.
- `SHA256SUMS` lists SHA-256 digests for every published asset, including both
  versioned names and stable aliases.
- Downloads use
  `https://github.com/opensst/opensst/releases/latest/download/<asset>`.
- GitHub's `latest` resolves only to non-draft, non-prerelease releases.
- Versioned assets remain published for compatibility with existing
  installation documentation and release links.

## Installation detection

Detection resolves the running executable with `readlink -f`, then queries
package ownership. Package ownership, not the host distribution, selects the
path.

| Method | Detection | Required owner |
|---|---|---|
| DEB | `dpkg-query -S <exe>` | `opensst` |
| RPM | `rpm -qf <exe>` | `opensst` |
| pacman | `pacman -Qqo <exe>` | `opensst` |
| source | No package owns the path, and the path is eligible | none |

Rules:

- If a package manager reports a different owner, the installation is unknown
  and the update is refused. It is not reclassified as source.
- Multiple owners reported by one package manager are unknown and refused.
- If multiple package managers are installed, they are queried in table order.
  The first definitive owner found wins. A definitive owner other than
  `opensst` stops detection.
- Source mode requires a regular resolved file named `sst`.
- Source mode refuses a file tracked by a Git worktree, so development
  checkouts are not modified in place. If `git` is unavailable, that check is
  skipped and the remaining source-path rules still apply.
- Source mode allows a user-writable file in a user-writable directory, or a
  file under `/usr/local` that can be updated with `sudo`.
- A file in `/usr/bin` that no package owns is unknown and refused.
- Other root-owned paths outside `/usr/local` are unknown and refused unless
  the current user can write the file and its directory.
- Detection diagnostics name the resolved path and the reason for refusal.

## Download and verification

- The downloader uses `curl` when available, otherwise `wget`. If neither is
  available, the command exits 127 with an installation hint.
- `curl` runs with HTTPS-only protocols, redirects enabled, certificate
  verification enabled by default, bounded connect and total timeouts, and
  fail-on-HTTP-error.
- `wget` follows HTTPS redirects with bounded retries and timeouts.
- Downloads go to a private `mktemp -d` directory, removed on exit by a trap.
- `SHA256SUMS` and the selected asset are downloaded from the same `latest`
  release URL.
- The checksum parser requires exactly one entry whose filename equals the
  selected stable alias. Missing or duplicate entries fail.
- `sha256sum` must exist. A missing tool exits 127; a mismatch exits 1.
- The asset is never executed before checksum verification.

The latest version is read from the downloaded asset without executing it:

| Method | Version source |
|---|---|
| DEB | `dpkg-deb -f <file> Version` |
| RPM | `rpm -qp --qf '%{VERSION}' <file>` |
| pacman | `pacman -Qip <file>` `Version` field |
| source | `SST_VERSION='...'` line in the downloaded script |

The installed version is read from the owning package database, or from
`SST_VERSION` in the running source file. A package installation whose version
cannot be queried exits 1.

A source file without `SST_VERSION` exits 2 with a reinstall hint.

## Upgrade execution

### DEB

```sh
sudo dpkg -i <downloaded-opensst.deb>
```

The installed version is queried after the command. If it does not equal the
target version, the command exits 1 with package-state guidance. No automatic
rollback is claimed.

### RPM

```sh
sudo rpm -Uvh <downloaded-opensst.rpm>
```

Post-install version verification follows the same rule as DEB.

### pacman

```sh
sudo pacman -U --noconfirm <downloaded-opensst.pkg.tar.zst>
```

Post-install version verification follows the same rule as DEB.

### Source, user-writable

1. Copy the running file to a backup in the same directory.
2. Install the downloaded file as a same-directory temporary file with mode
   `0755`.
3. Atomically rename the temporary file over the target.
4. Run `<target> --version`.
5. On success, remove the backup. On failure, restore the backup and exit 1.

### Source, `/usr/local`

1. Create a backup and a same-directory temporary file with `sudo`.
2. Install the temporary file with mode `0755` and `sudo`.
3. Atomically replace the target with `sudo mv`.
4. Run `<target> --version` as the invoking user.
5. On success, remove the backup with `sudo`. On failure, restore the backup
   and exit 1.

### Privileges

- If the current user is root, package managers and source replacement run
  directly.
- If the current user is not root and the method requires root, the command
  invokes `sudo`.
- If `sudo` is required but absent, the command exits 127.
- `sudo` prompts are left to `sudo`; this command does not manage passwords.
- Package-manager commands are fixed; downloaded paths are quoted and come from
  the private temporary directory.

## Failure semantics

- Network, HTTP, missing asset, missing checksum entry, checksum mismatch,
  version-query failure, install failure, and source sanity-check failure exit
  1. A source failure restores the old file. A package-manager failure reports
  the failing command and tells the user to inspect package state.
- Usage errors, unknown install methods, unsupported source paths, and
  non-interactive update without `--yes` exit 2.
- Missing downloader, `sha256sum`, `sudo`, `dpkg-deb`, `rpm`, or `pacman` when
  required exits 127.
- User cancellation and no-downgrade are not failures; both exit 0.

## Security and trust model

- The update channel is HTTPS to the hard-coded public GitHub Release URL.
- SHA-256 checksums detect corruption and incomplete downloads. Because the
  checksum file and assets come from the same release, they do not authenticate
  the publisher.
- The maintainer explicitly accepts this model: compromise of the GitHub
  release channel is equivalent to compromise of the update channel.
- README.md must state this trust boundary and must not describe checksums as
  signatures or as protection against a compromised release account.
- Updates require explicit invocation. No command checks for updates in the
  background or updates itself without a confirmation or `--yes`.
- Downloaded source files are parsed as text before replacement and are only
  executed after installation and a checksum check.

## Packaging and CI

- `packaging/build-deb.sh` and `packaging/build-rpm.sh` verify that their
  version argument equals the embedded `SST_VERSION` before building.
- Add `packaging/build-arch.sh`, which builds
  `opensst-<version>-1-any.pkg.tar.zst` with `makepkg` in a temporary directory,
  refuses to run as root, verifies the version argument against `SST_VERSION`,
  installs the executable at `/usr/bin/sst`, installs the license at
  `/usr/share/licenses/opensst/LICENSE`, and writes the package to the
  requested output directory.
- Add `make package-arch`.
- Add `packaging/release-assets.sh <version> <dist-dir>`, which requires the raw
  `sst` and all three versioned packages, creates stable aliases, verifies the
  raw script reports the expected version, and writes `SHA256SUMS` in stable
  sorted order.
- DEB metadata adds `curl` to `Depends`; RPM metadata adds `curl` to
  `Requires`; the Arch package declares `curl` as a dependency. The runtime
  still accepts `wget` as a fallback for source installs, but packages
  guarantee at least one downloader.
- CI adds an Arch package job: build in `archlinux:latest` as a non-root
  builder, install the package with `pacman -U --noconfirm`, and smoke-test
  `sst --help` and `sst --version`.
- The release workflow adds a `package-arch` job with the same container build
  and smoke test. The release job depends on DEB, RPM, and Arch package jobs,
  copies `bin/sst` to `dist/sst`, runs `packaging/release-assets.sh`, and
  uploads every artifact including `SHA256SUMS`.
- The release workflow validates `SST_VERSION` against the workflow input
  before tests.
- Release creation remains manual `workflow_dispatch`; ordinary pushes never
  tag or release.
- Existing tag and Release idempotency rules are unchanged.

## Documentation

README.md adds:

- `sst --version`, `sst update`, `--check`, and `--yes`.
- The installation-method table and the local package commands.
- Arch installation from the release `.pkg.tar.zst` with `pacman -U`.
- Source, DEB, RPM, and Arch uninstall commands.
- Runtime requirements: Bash, a downloader (`curl` or `wget`), `sha256sum`,
  the owning package manager, and `sudo` for system installs.
- The explicit trust boundary: checksums are integrity checks, not signatures.
- Update exit statuses and the no-downgrade rule.

AGENTS.md adds:

- Update safety invariants: explicit invocation only, checksum verification,
  package-ownership preservation, no direct writes to package-owned
  `/usr/bin/sst`, source atomic replacement, and no signature claims.
- The Arch package and stable release-asset rules.
- Release steps: bump `SST_VERSION`, keep it equal to the workflow input, build
  and smoke-test the Arch package, and verify all stable aliases.

The usage text adds `sst update` and `sst --version`.

## Testing

All update tests are offline. Fake `curl`, fake package tools, fake `sudo`,
temporary directories, and local fixture files are used. No test contacts
GitHub, a real package database, or a real remote host.

Coverage must include:

- `sst --version` output and help documentation.
- Detection of DEB, RPM, pacman, source, foreign package owner, unowned
  `/usr/bin`, tracked Git file, and unwritable unsupported path.
- `--check` performs no writes and no `sudo`.
- `--yes` skips confirmation; non-interactive update without `--yes` exits 2.
- Confirmation accepted and declined.
- Up-to-date, update available, and newer-installed no-downgrade paths.
- Checksum success, checksum mismatch, missing checksum entry, missing asset,
  download failure, and missing downloader.
- Version parsing for DEB, RPM, pacman, and source assets.
- Source replacement success, executable mode, post-install failure restoring
  the old file, and `/usr/local` sudo path.
- Exact DEB, RPM, and pacman upgrade commands.
- Release asset alias creation, checksum generation, version consistency, and
  static workflow checks for the Arch job and `SST_VERSION` validation.
- Arch package build when `makepkg` is available and the test is not running as
  root; explicit skip otherwise.

## Exit statuses

| Status | Meaning |
|---|---|
| 0 | Check completed, up to date, update applied, user declined, or no downgrade performed |
| 1 | Network, download, checksum, version query, install, or sanity-check failure |
| 2 | Usage error, unknown installation, unsupported source path, or missing terminal without `--yes` |
| 127 | Required local tool is missing |

## Acceptance criteria

- `make check` passes locally with the new update tests; only explicitly
  reported missing packaging tools may skip.
- `sst --version` reports the embedded version.
- `sst update --check` detects all four installation methods and never writes.
- `sst update` successfully upgrades a user-owned source install in a temporary
  directory with a fake release.
- Package-manager installs invoke the correct fixed command and preserve
  package ownership.
- Checksum and version failures leave the old installation intact.
- The release workflow and CI generate, install, and smoke-test the Arch
  package.
- README.md and AGENTS.md match the implemented behavior.
- No test contacts a real network host or performs a real package installation.

## Out of scope

- Signing keys, signatures, Sigstore, and attestations.
- AUR `PKGBUILD` publication and archlinuxcn submission.
- Automatic update checks or automatic updates.
- Hosted package repositories and package-manager repository configuration.
- Update rollback for package-manager-managed files.
- Windows and macOS support.
- PTY hardening for `-n`, `-f`, `-N`, `-W`, and `StdinNull`; this remains a
  separate follow-up to the base CLI.
