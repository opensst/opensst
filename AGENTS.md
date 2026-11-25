# OpenSST Maintainer Guide

OpenSST is a portable Bash CLI that manages reconnectable remote tmux sessions
over SSH. The project is `opensst`; the installed command is `sst`.

## Project layout

```text
bin/sst                  Runtime implementation; the complete CLI
tests/run.bash           Dependency-light Bash test suite
tests/fixtures/bin/ssh   Fake SSH used by tests; never contacts a host
tests/fixtures/bin/      Fake package tools, downloaders, and sudo for update tests
packaging/build-deb.sh   Builds opensst_<version>_all.deb
packaging/build-rpm.sh   Builds opensst-<version>-1.noarch.rpm
packaging/build-arch.sh  Builds opensst-<version>-1-any.pkg.tar.zst
packaging/release-assets.sh Creates stable aliases and SHA256SUMS
.github/workflows/ci.yml Continuous integration and package smoke tests
.github/workflows/release.yml Manually triggered verified release
docs/specs/               Design specifications
docs/plans/               Implementation plans
Makefile                 Test, check, install, uninstall, package targets
```

## Commands

```sh
make check                              # syntax checks + tests
make install PREFIX=/usr/local          # source install
make uninstall PREFIX=/usr/local        # source uninstall
make package-deb VERSION=0.1.0          # build dist/opensst_0.1.0_all.deb
make package-rpm VERSION=0.1.0          # build dist/opensst-0.1.0-1.noarch.rpm
make package-arch VERSION=0.1.0         # build dist/opensst-0.1.0-1-any.pkg.tar.zst
bash tests/run.bash                     # tests only
```

Tests must run without root, without network access, and without a real remote
host. The fake SSH fixture is the only SSH executable tests may reach.

## Safety invariants

- Never replay `kill` or arbitrary remote commands.
- Only an idempotent `open` may reconnect: only after SSH status 255 and a
  session lasting at least 30 seconds; retries wait 2 seconds; a fast initial
  255 is returned without retry.
- Never weaken project-name validation. Names must match
  `[A-Za-z0-9][A-Za-z0-9_-]*`.
- Never accept positional arguments after the SSH destination, because SSH
  would execute them remotely.
- The operation owns terminal allocation: reject user-supplied `-t`/`-T` so
  `open` always uses a PTY and `list`/`kill` never do.
- Never bypass effective `RemoteCommand` validation. It must resolve to
  `none`; an unresolvable configuration fails closed.
- Keep `kill` targeted with `=<project>` and never support wildcards or batch
  deletion.
- Do not use `eval` for SSH argument handling.
- Keep the runtime independent of Omarchy, Ghostty, Python, Mosh, autossh,
  systemd, and local tmux.
- Keep tests independent of real hosts and of Omarchy shell functions.

## Update safety invariants

- `sst update` is explicit only. No other command checks for updates, and
  nothing updates in the background or without confirmation/`--yes`.
- `SST_VERSION` in `bin/sst` is the single embedded version. It must equal the
  Release workflow input; a mismatch must fail before tests or packaging.
- Detect the installation method by package ownership, never by host
  distribution. Refuse a foreign package owner, multiple owners, an unowned
  `/usr/bin/sst`, and Git-tracked source files.
- Never overwrite a package-owned `/usr/bin/sst` directly. DEB, RPM, and
  pacman updates must go through their package managers.
- Never weaken checksum verification: download `SHA256SUMS` and the asset from
  the same hard-coded `releases/latest/download` base, require exactly one
  matching entry, and verify `sha256sum` before installing or executing.
- Source replacement must be atomic, preserve mode `0755`, keep a backup, and
  restore it if `<target> --version` fails.
- No implicit privilege escalation beyond invoking `sudo` after confirmation
  for a system path. A declined confirmation exits 0 without writing.
- Never claim signatures or publisher authentication. The checksums are
  integrity only; the trust root is the GitHub release channel.
- Updates must never downgrade; a latest release older than the installed
  version exits 0 without changing files.
- All update tests stay offline: fake `curl`/`wget`, fake package tools, fake
  `sudo`, and temporary directories only.

## Packaging rules

- Package name: `opensst`.
- Packaged command: `/usr/bin/sst` for DEB, RPM, and pacman.
- Source installation: `$(PREFIX)/bin/sst`, default `/usr/local/bin/sst`.
- DEB: `Architecture: all`; dependencies `bash`, `openssh-client`, `curl`.
- RPM: `BuildArch: noarch`; dependencies `bash`, `openssh-clients`, `curl`.
- pacman: `arch=('any')`; dependencies `bash`, `openssh`, `curl`.
- tmux is intentionally not a local package dependency; it belongs on the
  remote host.
- Do not maintain a self-hosted apt/dnf/pacman repository in this project.
  Packages are GitHub Release assets with `SHA256SUMS`.
- Do not add automatic privilege escalation to Makefile targets.
- Keep DEB, RPM, and pacman paths aligned at `/usr/bin/sst`.
- Every release publishes stable aliases (`sst`, `opensst.deb`, `opensst.rpm`,
  `opensst.pkg.tar.zst`, `SHA256SUMS`) next to the versioned assets. Stable
  aliases are the update contract; do not rename them.
- Release versions must be stable `MAJOR.MINOR.PATCH`; package builders reject
  an argument that differs from `SST_VERSION`.

## Continuous integration

`.github/workflows/ci.yml` runs on pushes and pull requests with read-only
repository permissions. It runs `make check`, builds a DEB and installs it on
Ubuntu, builds an RPM and installs it in a clean Fedora container, builds an
Arch package in an `archlinux:latest` container as a non-root user and installs
it with `pacman -U`, verifies `sst --help` and `sst --version`, and uploads
package artifacts for inspection.

## Release process

Release versions are stable `MAJOR.MINOR.PATCH` identifiers. Tags are
`v<version>`, for example `v0.1.0`. The initial version is `0.1.0`.

Releases are deliberately manual. Ordinary pushes and pull requests never
create tags or GitHub Releases.

1. Start from a clean, synchronized `main` branch.
2. Choose the exact semantic version. Bump `SST_VERSION` in `bin/sst` and keep
   it equal to the version passed to the Release workflow. Update the Version
   History table below, version-specific README examples, and version
   expectations in `tests/run.bash`.
3. Run `make check` locally; it must pass with no skips other than explicitly
   reported missing local packaging tools. Build and smoke-test the Arch
   package locally when `makepkg` is available.
4. Commit and push the release-preparation changes with **explicit**
   authorization.
5. Manually run the **Release** workflow (`workflow_dispatch`) with the exact
   version. Never invent, reuse, or move a published version.
6. Wait for validation, test, DEB smoke-test, RPM smoke-test, and Arch
   smoke-test jobs to pass.
7. Verify the annotated `v<version>` tag, the GitHub Release notes, and the
   uploaded `sst`, `opensst.deb`, `opensst.rpm`, `opensst.pkg.tar.zst`,
   versioned package assets, and `SHA256SUMS`. Verify the stable aliases match
   the versioned files and that `sst --version` reports the release version.
8. When appropriate, verify installation and a real `sst update` from the
   published assets.

The workflow is idempotent: an existing tag is reused only when it points to
the selected commit, and an existing Release is left unchanged. A tag at a
different commit is a hard failure. Never delete or replace a published
Release to bypass a failure; investigate and release a new patch version.
Versioning, commits, tags, pushes, package publication, GitHub Release
creation, and repository metadata changes each require explicit maintainer
authorization.

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 0.1.0 | 2026-11-25 | Initial CLI: open/list/kill, reconnect, explicit `sst update` for source/DEB/RPM/pacman installs, source install, DEB/RPM/Arch packages, CI and manual release workflow. |

## Documentation rules

Update README.md, this file, and tests when CLI behavior, installation,
packaging, or project structure changes. Keep `/usr/local/bin` (source) and
`/usr/bin/sst` (packages) documented consistently, and keep the command-name
conflict with Serverless SST visible to users.
