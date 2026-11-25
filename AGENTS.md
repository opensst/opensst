# OpenSST Maintainer Guide

OpenSST is a portable Bash CLI that manages reconnectable remote tmux sessions
over SSH. The project is `opensst`; the installed command is `sst`.

## Project layout

```text
bin/sst                  Runtime implementation; the complete CLI
tests/run.bash           Dependency-light Bash test suite
tests/fixtures/bin/ssh   Fake SSH used by tests; never contacts a host
packaging/build-deb.sh   Builds opensst_<version>_all.deb
packaging/build-rpm.sh   Builds opensst-<version>-1.noarch.rpm
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
- Never bypass effective `RemoteCommand` validation. It must resolve to
  `none`; an unresolvable configuration fails closed.
- Keep `kill` targeted with `=<project>` and never support wildcards or batch
  deletion.
- Do not use `eval` for SSH argument handling.
- Keep the runtime independent of Omarchy, Ghostty, Python, Mosh, autossh,
  systemd, and local tmux.
- Keep tests independent of real hosts and of Omarchy shell functions.

## Packaging rules

- Package name: `opensst`.
- Packaged command: `/usr/bin/sst`.
- Source installation: `$(PREFIX)/bin/sst`, default `/usr/local/bin/sst`.
- DEB: `Architecture: all`; dependencies `bash` and `openssh-client`.
- RPM: `BuildArch: noarch`; dependencies `bash` and `openssh-clients`.
- tmux is intentionally not a local package dependency; it belongs on the
  remote host.
- Do not maintain a self-hosted apt/dnf repository in this project. DEB and RPM
  files are GitHub Release assets with `SHA256SUMS`.
- Do not add automatic privilege escalation to Makefile targets.
- Keep DEB and RPM paths aligned at `/usr/bin/sst`.

## Continuous integration

`.github/workflows/ci.yml` runs on pushes and pull requests with read-only
repository permissions. It runs `make check`, builds a DEB and installs it on
Ubuntu, builds an RPM and installs it in a clean Fedora container, verifies
`sst --help`, and uploads package artifacts for inspection.

## Release process

Release versions are stable `MAJOR.MINOR.PATCH` identifiers. Tags are
`v<version>`, for example `v0.1.0`. The initial version is `0.1.0`.

Releases are deliberately manual. Ordinary pushes and pull requests never
create tags or GitHub Releases.

1. Start from a clean, synchronized `main` branch.
2. Choose the exact semantic version. Update the Version History table below
   and any release-related documentation.
3. Run `make check` locally; it must pass with no skips other than explicitly
   reported missing local packaging tools.
4. Commit and push the release-preparation changes with **explicit**
   authorization.
5. Manually run the **Release** workflow (`workflow_dispatch`) with the exact
   version. Never invent, reuse, or move a published version.
6. Wait for validation, test, DEB smoke-test, and RPM smoke-test jobs to pass.
7. Verify the annotated `v<version>` tag, the GitHub Release notes, and the
   uploaded `opensst_<version>_all.deb`,
   `opensst-<version>-1.noarch.rpm`, and `SHA256SUMS` assets.
8. When appropriate, verify installation from the published assets.

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
| 0.1.0 | 2026-11-25 | Initial CLI: open/list/kill, reconnect, source install, DEB/RPM packages, CI and manual release workflow. |

## Documentation rules

Update README.md, this file, and tests when CLI behavior, installation,
packaging, or project structure changes. Keep `/usr/local/bin` (source) and
`/usr/bin/sst` (packages) documented consistently, and keep the command-name
conflict with Serverless SST visible to users.