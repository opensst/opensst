# OpenSST — reconnectable SSH sessions with remote tmux

[![CI](https://github.com/opensst/opensst/actions/workflows/ci.yml/badge.svg)](https://github.com/opensst/opensst/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/opensst/opensst)](https://github.com/opensst/opensst/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Linux](https://img.shields.io/badge/platform-Linux-lightgrey.svg)](#supported-environments)

`sst` is a portable Linux Bash CLI for **reconnectable SSH sessions backed by
remote tmux**. It opens, lists, and kills named remote tmux sessions and
reconnects an interactive session when a long-lived SSH connection drops.
It works with any mainstream Linux distribution and a standard OpenSSH client;
it does not depend on Omarchy, Ghostty, Python, Mosh, autossh, or systemd.

## Features

- `open`, `list`, and `kill` for named remote tmux sessions.
- Automatic reconnect after a dropped interactive session.
- Explicit `sst update`, which detects the installation method and upgrades
  through the matching package manager.
- A self-contained `install.sh` that installs the matching DEB, RPM, or pacman
  release package and falls back to the raw executable; `sst` itself is a
  single Bash script with no runtime configuration file.
- Exact session targeting and explicit rejection of unsafe SSH arguments.
- A test suite that uses a fake SSH executable and never contacts a real host.

## Supported environments

Local requirements:

- Linux with Bash (arrays, `[[ ... ]]`, `SECONDS`).
- An OpenSSH client with `ssh -G` support.
- For installation and updates: `curl` or `wget`, `sha256sum`, and `sudo` for
  system paths.

Remote requirements:

- An SSH-accessible account with a POSIX-compatible login shell.
- `tmux` in `PATH` for non-interactive SSH commands.
- tmux support for `new-session -A -D` and exact `=session` targets.

tmux is required on the remote host, not on the machine running `sst`.

## Installation

Install the latest release:

```sh
curl -fsSL https://github.com/opensst/opensst/releases/latest/download/install.sh | bash
```

The installer detects the available package manager and installs the matching
release package:

| System | Package manager | Installed at |
|---|---|---|
| Arch | `pacman -U` | `/usr/bin/sst` |
| Debian, Ubuntu | `apt-get install` (or `dpkg -i`) | `/usr/bin/sst` |
| Fedora, RHEL | `dnf install`, `yum localinstall`, or `rpm -Uvh` | `/usr/bin/sst` |
| other Linux | raw `sst` executable | `/usr/local/bin/sst` |

The installer downloads only from GitHub Releases over HTTPS, verifies the
chosen asset against `SHA256SUMS`, and uses `sudo` only for the install step.
Package-managed files are upgraded through their package manager, never
overwritten directly.

To install a specific stable version:

```sh
curl -fsSL https://github.com/opensst/opensst/releases/latest/download/install.sh | bash -s -- --version 0.2.1
```

Use only one installation method. Do not mix a package install under
`/usr/bin` with a source fallback under `/usr/local/bin`; check which executable
your shell resolves with `type -a sst`.

Uninstall with the command matching the detected installation:

```sh
sudo apt remove opensst           # DEB
sudo dnf remove opensst           # RPM
sudo pacman -R opensst            # Arch
sudo rm -f /usr/local/bin/sst     # source fallback
```

The installer follows the same trust boundary as `sst update`: the Release
channel is trusted over HTTPS, and `SHA256SUMS` detects corruption but is not a
signature.

Installing is separate from upgrading: `install.sh` never modifies your
package-manager configuration, but you can opt in to repository-based upgrades
afterwards — see [Upgrades via your system package
manager](#upgrades-via-your-system-package-manager).

## Upgrades via your system package manager

Every release also publishes a static package-repository site at
<https://opensst.github.io/opensst> (served from this repository's `gh-pages`
branch). Adding it to your package manager gets you `opensst` upgrades through
your normal system upgrades. The site always serves the latest release, and
its package files are byte-identical to that release's GitHub assets.

**apt** (Debian, Ubuntu) — create `/etc/apt/sources.list.d/opensst.list`:

```ini
deb [trusted=yes] https://opensst.github.io/opensst/deb ./
```

**dnf** (Fedora, RHEL) — create `/etc/yum.repos.d/opensst.repo`:

```ini
[opensst]
baseurl=https://opensst.github.io/opensst/rpm
gpgcheck=0
```

**pacman** (Arch) — append to `/etc/pacman.conf`:

```ini
[opensst]
Server = https://opensst.github.io/opensst/arch
SigLevel = Never
```

Then upgrade as usual: `sudo apt update && sudo apt upgrade`,
`sudo dnf upgrade`, or `sudo pacman -Syu`.

These repositories are not signed. The per-repository settings above
(`[trusted=yes]`, `gpgcheck=0`, `SigLevel = Never`) opt in for this repository
only. Transport is HTTPS, the trust root is this GitHub repository, and the
package bytes are byte-identical to the release assets, so you can verify them
against the `SHA256SUMS` published on the release page — the same trust
boundary as `install.sh` and `sst update`; checksums are not signatures.
Support floor: apt ≥ 1.5, dnf4, pacman ≥ 6.

On Arch, installing from the repository also stops `opensst` from being a
foreign package, so AUR helpers no longer report it as "not in AUR" during
system updates.

The repository complements `sst update` instead of replacing it: both channels
install the same bytes from the same release, so use whichever is more
convenient (`sst update` is a no-op when you are already current, and source
installs under `/usr/local/bin` are only covered by `sst update`). Only the
latest release is served; older versions remain downloadable from the GitHub
release pages (`pacman -U`, `dpkg -i`, `dnf install <url>`).

## Usage

```text
sst open [ssh options] <host> <project>
sst list [ssh options] <host>
sst kill [ssh options] <host> <project>
sst update [--check|--yes]
sst --help
sst --version
```

Examples:

```sh
sst open devbox Work
sst open -p 2222 -l duanhongyi devbox Work
sst list devbox
sst kill devbox Work
sst update --check
sst update
```

SSH options are passed to `ssh` before the host, for example
`sst open -p 2222 -J jump@example devbox Work`. The host must be the only
positional SSH argument. Additional positional arguments, which SSH would
treat as a remote command, are rejected. The operation owns terminal
allocation, so -t/-T are rejected: `open` uses a PTY and `list`/`kill` run
without one.

### Project names

A project is a remote tmux session key, not a filesystem path. Names must
match:

```text
[A-Za-z0-9][A-Za-z0-9_-]*
```

Only ASCII letters, digits, underscores, and hyphens are allowed, and the
first character must be a letter or digit. Invalid names fail before any
network connection.

### What each command does

- `open` runs `tmux new-session -A -D -s <project>` over an SSH PTY. It creates
  the session if needed or attaches to the existing one.
- `list` runs `tmux list-sessions` once and returns its output.
- `kill` runs `tmux kill-session -t =<project>`. The `=` prefix requires an
  exact session-name match; there is no wildcard or bulk deletion.

All three commands check for remote `tmux` in the same SSH invocation and
return status 127 with an installation hint when tmux is missing.

### Reconnect behavior

`open` reconnects only after a connection that lasted at least 30 seconds and
ended with SSH status 255. It then retries the identical SSH command and
project every 2 seconds until a non-255 result. A fast initial 255 is returned
without retrying because it usually indicates an authentication, host, or
configuration failure. Normal detach and exit do not reconnect.

`list` and `kill` never retry, including on status 255, because a transport
failure does not prove the remote operation did not run.

### `-D` client detachment

`open` uses `new-session -A -D`. The `-D` flag detaches other clients already
attached to the same session. Opening the same project from another terminal
will therefore displace the earlier client. Use different project names for
concurrent attachments.

### Remote terminal compatibility

`open` allocates a PTY, so SSH passes the local `TERM` to the remote host.
tmux needs a terminfo entry for that value and otherwise fails with
`missing or unsuitable terminal: ...` (common with Ghostty, kitty, or
Alacritty). Before starting tmux, `open` probes the entry with the remote
`infocmp`. If it is missing, `open` uses the first available entry from
`xterm-256color`, `xterm`, `screen`, and `vt100`, and reports the change:

```text
sst: remote terminal xterm-ghostty is unsupported; using xterm-256color
```

A fallback is applied only after the replacement entry probes successfully.
If the remote host has no `infocmp`, or none of the fallback entries exist,
`TERM` is left unchanged and tmux reports its usual error. `list` and `kill`
allocate no PTY and are unaffected. Inside tmux, `TERM` is still set by tmux
itself.

A fallback keeps the session usable but can reduce terminal capabilities. To
keep all local terminal features, install the matching terminfo entry on the
remote host instead, for example for Ghostty:

```sh
infocmp -x xterm-ghostty | ssh <host> -- tic -x -
```

## Updating

`sst --version` prints the embedded version. `sst update` checks the latest
stable GitHub Release, verifies the asset checksum, prints the installed and
latest versions, and asks before changing anything.

```sh
sst update --check   # report only; no writes and no sudo
sst update           # ask, then upgrade through the matching method
sst update --yes     # skip confirmation for scripts
```

Detection uses package ownership, not the operating system:

| Installed from | Detected by | Upgrade command |
|---|---|---|
| DEB | `dpkg-query -S /usr/bin/sst` | `sudo dpkg -i opensst.deb` |
| RPM | `rpm -qf --qf '%{NAME}' /usr/bin/sst` | `sudo rpm -Uvh opensst.rpm` |
| pacman | `pacman -Qqo /usr/bin/sst` | `sudo pacman -U --noconfirm opensst.pkg.tar.zst` |
| source | no package owns the file | atomic replacement, with `sudo` under `/usr/local` |

The owning package must be named `opensst`. An executable owned by a different
package, owned by multiple packages, or unowned under `/usr/bin/sst` is refused
instead of being reclassified as a source installation.

Source installs are replaced atomically and keep executable mode `0755`. If the
new file fails `sst --version`, the previous file is restored. Package-managed
files are never overwritten directly, so package ownership stays intact.

Updates require explicit invocation; no other command checks for updates.
`--check` and `--yes` are mutually exclusive. Without `--yes`, an update needs
a terminal and exits 2 instead of blocking in scripts. An installation that is
already current exits 0, and a latest release older than the installed version
is never installed (no downgrade).

Runtime requirements for updates are `curl or wget`, `sha256sum`, the owning
package manager, and `sudo` for system installs.

**Trust boundary:** assets come from the hard-coded
`https://github.com/opensst/opensst/releases/latest/download/` channel over
HTTPS. `SHA256SUMS` detects corruption and incomplete downloads.
The checksums are not signatures and do not authenticate the publisher. A
compromise of the GitHub release channel is a compromise of the update channel.

## Exit status

- `0`: the command succeeded; for updates, also up to date, applied, declined,
  or no downgrade performed.
- `1`: an update failed because of a network, download, checksum, version
  query, install, or post-install check error.
- `2`: invalid usage, unsafe project name, ambiguous SSH arguments, an
  unresolvable or unsafe SSH configuration, `open` without a terminal, an
  unknown installation method, an unsupported source path, or `sst update`
  without a terminal and without `--yes`.
- `127`: a required local tool is missing: `ssh`, remote `tmux`, update
  downloader (`curl` or `wget`), `sha256sum`, `sudo`, or the owning package
  manager.
- `255`: an SSH connection failure that did not qualify for reconnect; other
  SSH and remote-command statuses are returned unchanged.

## Security boundaries

- Only a fixed remote command derived from a validated project name is sent.
- The SSH destination and options are validated before connecting, and
  positional remote commands are rejected.
- The effective `RemoteCommand` from SSH configuration must be `none`;
  validation fails closed if `ssh -G` cannot resolve the configuration.
- `kill` uses an exact tmux target and never accepts wildcards.
- The implementation uses Bash arrays and never `eval`.
- Updates verify SHA-256 checksums before executing or installing anything and
  never overwrite package-owned files directly.

## Name conflicts

Serverless SST also publishes a command named `sst` (the AUR package is
`sst-bin`), and a pre-existing shell function or alias can shadow this
executable. Check what your shell resolves:

```sh
type -a sst
```

If an old function wins, remove it once in the current shell with
`unset -f sst; hash -r`, then start a new shell. This project's package is
named `opensst` even though the installed command is `sst`.

## Development

```sh
make check                 # Bash syntax checks plus the full test suite
make package-deb VERSION=0.2.1
make package-rpm VERSION=0.2.1
make package-arch VERSION=0.2.1
```

Tests run the real executable with a fake `ssh` on `PATH`; they never contact
a real remote host. Update tests use fake downloaders, package tools, and
`sudo`, so they never touch GitHub, a real package database, or an installed
system. Package builds require `dpkg-deb`, `rpmbuild`, or `makepkg`, which may
not all exist on one host. CI builds and smoke-tests DEB, RPM, and Arch
packages on Ubuntu, Fedora, and Arch containers.

Maintainer and release rules are in [AGENTS.md](AGENTS.md).

## License

MIT. See [LICENSE](LICENSE).
