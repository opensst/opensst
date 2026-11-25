# OpenSST Design

Date: 2026-11-25
Status: Design approved in conversation; implementation pending

## Summary

OpenSST is a small, self-contained Bash CLI that provides reconnectable SSH sessions backed by remote tmux. The project lives at `~/Sources/opensst`; its installed command is named `sst`.

The project is portable across mainstream Linux user environments and does not depend on Omarchy, Ghostty, Mosh, autossh, Python, systemd, or distribution-specific service machinery.

Releases provide native DEB and RPM packages built by GitHub Actions, alongside source installation through `make install`. GitHub metadata and release assets are structured so the public repository is easy to discover and use.

This design supersedes the abandoned Omarchy-only configuration design.

## Goals

- Provide `open`, `list`, and `kill` operations for named remote tmux sessions.
- Reconnect only a validated, fixed, idempotent `open` operation.
- Preserve the safety rule that arbitrary remote commands and destructive management commands are never replayed.
- Run on mainstream Linux distributions with Bash and a compatible OpenSSH client.
- Require only a POSIX-compatible remote shell and a compatible tmux on the remote host.
- Support source installation under `/usr/local` or a user-selected prefix.
- Build installable DEB and RPM release artifacts without introducing a self-hosted package repository.
- Publish verified releases with an annotated tag, a GitHub Release, generated notes, packages, and checksums.
- Document installation, packaging, release gates, and repository metadata in README.md and AGENTS.md.
- Replace the current Omarchy-specific Bash function after the new implementation passes verification.
- Push the completed initial project to `github.com/opensst/opensst`.

## Non-goals

- No Mosh, Eternal Terminal, autossh, or custom network protocol.
- No local tmux requirement for normal CLI use.
- No automatic remote working-directory selection; a project is a tmux session key, not a filesystem path.
- No shared-session mode, wildcard deletion, bulk deletion, or kill-server operation.
- No Ghostty-specific `+ssh` backend in the initial version.
- No GUI, daemon, background service, plugin system, or runtime configuration file.
- No real remote-server operations in the automated test suite.
- No self-hosted apt/dnf repository, repository signing key, or automatic package-manager updates.
- No GPG or Sigstore artifact signing in the initial release; SHA256 checksums are provided.
- No release-please or semantic-release automation in the initial version.
- No automatic release for every push or merge; releases are deliberately initiated by a maintainer.
- No GitHub Pages site in the initial version.

## Naming

The project directory and GitHub repository are `opensst`; the executable and user-facing command are `sst`.

DEB and RPM package names are `opensst` to match the public project and avoid package-manager name collision with the unrelated Serverless SST `sst-bin` package. The packaged executable path remains `/usr/bin/sst`, so the command name selected by the user is preserved.

A web search found an old, unrelated SourceForge project named OpenSST (Open Simple Secure Transaction). This is not a technical conflict for local development, but the name is not globally unique and should be reconsidered before a substantially broader public launch if necessary.

The `sst` command may conflict with Serverless SST or a pre-existing local function. README.md will state this explicitly. Installation and migration must verify actual command resolution rather than assuming the intended executable is being invoked.

## Supported Environments

Local runtime requirements:

- Mainstream Linux user space.
- Bash with arrays, `[[ ... ]]`, and `SECONDS` support.
- OpenSSH client with `ssh -G` support.
- Standard user-space utilities used by the runtime and installation targets.

Remote requirements:

- An SSH-accessible account.
- A POSIX-compatible command shell for SSH remote commands.
- `tmux` available in `PATH` for non-interactive SSH commands.
- tmux support for `new-session -A -D` and exact `=session-name` targets.

DEB dependencies are `bash` and `openssh-client`; RPM dependencies are `bash` and `openssh-clients`. tmux is intentionally not a local package dependency because it is required on the remote host, not necessarily on the machine running `sst`.

The project will not claim support for every historical, embedded, or deliberately minimal Linux environment. Omarchy and Ghostty are not requirements. The initial version invokes `ssh` directly and therefore does not provide Ghostty-specific `ssh-env` or `ssh-terminfo` integration.

## Project Layout

```text
~/Sources/opensst/
├── .github/
│   └── workflows/
│       ├── ci.yml
│       └── release.yml
├── bin/
│   └── sst
├── docs/
│   └── specs/
│       └── 2026-11-25-opensst-design.md
├── packaging/
│   ├── build-deb.sh
│   └── build-rpm.sh
├── tests/
│   ├── run.bash
│   └── fixtures/
│       └── bin/
│           └── ssh
├── AGENTS.md
├── LICENSE
├── Makefile
├── README.md
└── .gitignore
```

`bin/sst` is the complete runtime implementation. It is installed as an executable, not sourced into the user's shell. Tests use a fake SSH executable and do not require Bats or another external test framework.

## Installation Interfaces

The Makefile provides:

- `test`: run the full simulated test suite.
- `check`: run Bash syntax checks and the full test suite.
- `package-deb`: build a DEB into `dist/` using `dpkg-deb`.
- `package-rpm`: build an RPM into `dist/` using `rpmbuild`.
- `install`: install the executable under `PREFIX`, defaulting to `/usr/local`.
- `uninstall`: remove the installed executable from `PREFIX`.

Source installation examples:

```sh
sudo make install                         # /usr/local/bin/sst
make install PREFIX="$HOME/.local"        # ~/.local/bin/sst
```

No target invokes privilege escalation automatically. README.md instructs users to choose either source installation or a package, not both, to avoid `/usr/local/bin/sst` and `/usr/bin/sst` both existing unnoticed.

DEB and RPM packages install `/usr/bin/sst`, README.md, and LICENSE under the distribution-standard documentation directory. Package builds accept the release version as an argument and create architecture-independent packages.

Local Arch systems may not have `dpkg-deb` or `rpmbuild`; the Makefile reports the missing tool clearly. GitHub Actions is the authoritative package build and installation-test environment.

## CLI

```text
sst open [ssh options] <host> <project>
sst list [ssh options] <host>
sst kill [ssh options] <host> <project>
sst --help
```

There is no implicit/default action and no short `connect` alias. `open` is deliberately shorter than `connect` and covers both creation and restoration.

Examples:

```sh
sst open devbox Work
sst open -p 2222 -l duanhongyi devbox Work
sst list devbox
sst kill devbox Work
```

A project name contains only ASCII letters, digits, underscores, and hyphens, and begins with a letter or digit:

```text
[A-Za-z0-9][A-Za-z0-9_-]*
```

This restriction makes the fixed remote command unambiguous and prevents project text from introducing shell syntax.

## SSH Argument Validation

Before any connection, the CLI validates the SSH argument vector itself:

1. Parse OpenSSH flags, including options with separate or attached values.
2. Recognize `--` as the end of options.
3. Require exactly one SSH destination in the supplied arguments.
4. Reject additional positional arguments, which would otherwise be remote commands.
5. Resolve the effective configuration using `ssh -G` with the original SSH argument vector.
6. Reject an effective `RemoteCommand` other than `none`.
7. Fail closed if SSH configuration resolution fails.

The validator must account for the OpenSSH options that consume values, including combined flags and attached values such as `-p2222`. SSH arguments remain in Bash arrays throughout local processing; the implementation does not use `eval`.

Only after validation does the CLI append its own fixed remote command. Reconnect attempts reuse the same validated argument vector and project.

## Remote Operations

All three operations check remote tmux in the same SSH invocation as their operation, avoiding an additional SSH connection. Missing remote tmux produces an actionable error and exit status 127.

### open

```sh
ssh -t [validated arguments] \
  'command -v tmux ...; exec tmux new-session -A -D -s <project>'
```

`open` requires stdin and stdout to be terminals. It creates the named session if absent or attaches to it if present. `-D` detaches other clients attached to that session; this behavior is documented because opening the same project elsewhere can displace an existing client.

After each SSH process exits, the CLI emits terminal-reset escape sequences that disable mouse tracking and focus reporting, leave the alternate screen, and restore the cursor. This prevents a dropped connection from leaving terminal modes armed.

The initial invocation reconnects only when SSH returns 255 and the session lasted at least 30 seconds. A fast initial 255 is returned without retry to avoid authentication and configuration failure loops. Once reconnecting has begun, 255 failures are retried every two seconds so a rebooting or temporarily unreachable server can recover. Any non-255 result ends the loop and is returned. Normal detach or exit does not reconnect.

### list

```sh
ssh -T [validated arguments] \
  'command -v tmux ...; exec tmux list-sessions'
```

`list` does not allocate a PTY, reset terminal modes, or reconnect. It returns the remote command/SSH status unchanged.

### kill

```sh
ssh -T [validated arguments] \
  'command -v tmux ...; exec tmux kill-session -t =<project>'
```

The `=` prefix requires an exact tmux session-name match. `kill` does not allocate a PTY or reconnect. It executes exactly once even if SSH returns 255, because the deletion may already have completed before a transport failure.

## Error Handling

- Invalid CLI usage, unsafe project names, ambiguous SSH arguments, and unsafe/unresolvable SSH configuration return status 2 before connecting.
- `open` without interactive stdin/stdout returns status 2.
- Missing local `ssh` is reported clearly and returns status 127.
- Missing remote tmux returns status 127 with an install/PATH hint.
- Management commands return SSH or remote-command statuses unchanged.
- Unexpected subcommands display concise usage information and return status 2.
- `sst --help` and `sst -h` do not require SSH, tmux, Omarchy, or a terminal.

## Documentation

README.md is the user-facing entry point and includes:

- A searchable first paragraph covering SSH, tmux, reconnect, remote sessions, Linux, Bash, and CLI.
- CI, latest release, MIT license, and Linux badges.
- Purpose and features.
- Local and remote dependencies.
- Source, DEB, and RPM installation, upgrade, and uninstallation instructions.
- CLI examples and project-name rules.
- Reconnect timing and exit behavior.
- `-D` client-detachment semantics.
- Security boundaries and non-goals.
- Command-name conflict and project-name disambiguation notes.
- Test and package-build instructions.

AGENTS.md records project structure, coding conventions, verification commands, packaging rules, release gates, version history, and these invariants:

- Never replay `kill` or arbitrary remote commands.
- Never weaken project-name or SSH destination validation to simplify parsing.
- Never make tests depend on a real remote host.
- Keep runtime independent of Omarchy and Ghostty.
- Keep DEB and RPM installation paths aligned at `/usr/bin/sst`.
- Never publish a release without the complete verification gate.
- Version selection, commits, tags, pushes, GitHub Releases, and repository metadata changes require explicit maintainer authorization.
- Update documentation when CLI behavior, installation, packaging, or project structure changes.

## Versioning

Releases use stable semantic versions in `MAJOR.MINOR.PATCH` form. Git tags use a `v` prefix: version `0.1.0` becomes tag `v0.1.0`.

The initial version is `0.1.0`. Versions are repository release identifiers, not a second runtime version embedded in the script. Package metadata and GitHub Release tags derive from the manually supplied release version.

AGENTS.md contains a Version History table beginning with `0.1.0`. It records release changes but does not replace GitHub-generated release notes.

## GitHub Actions

### Continuous integration

`.github/workflows/ci.yml` runs on pushes and pull requests. It:

- Runs `make check` in a clean Linux environment.
- Runs runtime tests without any Omarchy functions or real remote hosts.
- Builds a DEB, installs it on Ubuntu, and verifies `sst --help`.
- Builds an RPM, installs it in a clean Fedora container, and verifies `sst --help`.
- Uploads package artifacts for inspection on CI runs.

CI jobs use read-only repository permissions except for artifact handling.

### Release workflow

`.github/workflows/release.yml` is manually triggered with `workflow_dispatch` and one required input: a stable version such as `0.1.0`.

The workflow:

1. Fails unless it is running from the `main` branch.
2. Validates `MAJOR.MINOR.PATCH` and rejects an existing `v<version>` tag at a different commit.
3. Runs the complete test suite, including package creation and clean-environment smoke tests.
4. Produces `opensst_<version>_all.deb`, `opensst-<version>-1.noarch.rpm`, and `SHA256SUMS`.
5. Creates an annotated `v<version>` tag only after all builds and smoke tests pass.
6. Creates a GitHub Release titled `v<version>` with GitHub-generated notes and `--verify-tag`.
7. Uploads both packages and SHA256SUMS as Release assets.

The release job has `contents: write`; build and test jobs retain read-only permissions. Only official GitHub Actions are used.

A workflow rerun is idempotent: an existing Release is not modified, an existing tag is reused only when it points to the selected commit, and a tag at a different commit is a hard failure. The workflow never deletes or replaces a published Release.

Ordinary pushes and pull requests never create tags or Releases. Actual tag creation, Release publication, and repository metadata changes require explicit maintainer authorization, matching the governance used by the referenced `omagents/omagents` project.

## AGENTS.md Release Process

AGENTS.md documents a concrete release procedure:

1. Start from a clean, synchronized `main` branch.
2. Confirm the intended semantic version and update Version History and any release-related documentation.
3. Run `make check` locally.
4. Commit and push the release-preparation changes with explicit authorization.
5. Manually run the Release workflow with the exact version; never invent or reuse a version.
6. Wait for test, package, and smoke-test jobs to pass.
7. Verify the annotated tag, Release notes, DEB, RPM, and SHA256SUMS.
8. Verify package installation from the published assets when appropriate.

The document also states that versioning, Git mutations, tagging, pushing, package publication, and GitHub Release creation each require explicit authorization, and that a failed release must be investigated rather than bypassed by moving an existing tag.

## GitHub Repository Metadata

After the initial push, the repository About section is configured with:

```text
Reconnectable SSH sessions with remote tmux — open, list, and kill
named Linux sessions from a portable Bash CLI.
```

Repository topics:

```text
ssh tmux openssh ssh-client terminal remote-development
persistent-sessions session-manager linux bash cli developer-tools
```

README keywords, badges, description, topics, MIT license recognition, and published releases are the discoverability mechanisms. No search-ranking outcome is guaranteed.

Repository settings unrelated to description and topics are not changed without explicit authorization.

## Tests and Verification

The test harness runs the actual `bin/sst` executable with a controlled `PATH` and a programmable fake `ssh`. Pseudo-terminal tests use the Linux `script` utility where needed.

Tests cover:

- Help and invalid usage.
- Missing local SSH and required dependency errors.
- Separate and attached SSH option values, combined flags, and `--`.
- Missing or multiple destinations and positional remote-command rejection.
- Effective `RemoteCommand` rejection, explicit `none` acceptance, and `ssh -G` failure.
- Project-name validation before connection.
- Exact open/list/kill command construction and PTY selection.
- Missing remote tmux for all operations.
- No retry for list or kill, including kill returning 255.
- No retry for a fast initial open failure.
- Reconnect after a qualifying open failure using identical SSH arguments and project.
- Termination of reconnect on a non-255 result.
- Operation in a clean Bash environment without Omarchy functions.
- Bash syntax checks and installation into temporary system and user prefixes.
- DEB and RPM metadata, file layout, and clean installation smoke tests in CI.

Final local migration verification also checks `.bashrc` syntax, installed command resolution, and `sst --help`. It does not contact a real server.

## Git and Initial Publication

The GitHub repository `opensst/opensst` is public and initially empty. The current account has repository admin permission.

The local machine cannot currently use GitHub SSH port 22 because the connection is reset, while HTTPS access works. The implementation therefore uses the HTTPS remote URL and a repository-local Git credential helper backed by the authenticated GitHub CLI. Global Git configuration is not changed.

Initial publication:

1. Initialize the local repository with `main` as the default branch.
2. Add the HTTPS remote for `opensst/opensst`.
3. Run all local verification before the initial commit.
4. Commit the complete project.
5. Push `main` with explicit authorization.
6. Configure the repository description and topics.
7. Verify GitHub Actions results and package smoke tests.
8. Do not create a release tag or Release during initial publication unless separately authorized.

## Migration and Cleanup

Only after the standalone project passes its tests:

1. Install it with `make install PREFIX="$HOME/.local"`, after checking for an existing destination that could be overwritten.
2. Back up `~/.bashrc` and remove only the old `~/.config/bash/sst.bash` source line.
3. Remove the old Omarchy-dependent `~/.config/bash/sst.bash` file so the two implementations cannot drift.
4. Verify a fresh interactive Bash resolves `sst` to the installed executable rather than a function.
5. Remove the obsolete `~/Nextcloud/Config/omarchy/docs/specs/2026-11-25-sst-config-design.md` created during the abandoned design, and remove only its empty parent directories. Existing Nextcloud archives and AGENTS.md remain untouched.
6. Leave the unrelated empty `~/Nextcloud/Config/sst` directory untouched.

Existing shells may retain the old function until the user runs `unset -f sst` and `hash -r`; new shells must work without those commands.

## Acceptance Criteria

- The project exists at `~/Sources/opensst` with the documented files.
- `make check` passes without real network access.
- The CLI passes its tests in an environment with no Omarchy functions.
- Source, DEB, and RPM installation paths and metadata are documented and tested.
- User-level source installation succeeds without modifying files outside the chosen prefix, except for explicitly approved migration and cleanup.
- A fresh shell resolves `sst` to `~/.local/bin/sst`, and `sst --help` succeeds.
- The initial commit is pushed to `opensst/opensst` over HTTPS.
- Repository description and topics match this specification.
- CI passes, including DEB and RPM package smoke tests.
- The Release workflow exists and is manual-only; no tag or GitHub Release is created without separate authorization.
- No package-owned Omarchy file is modified.