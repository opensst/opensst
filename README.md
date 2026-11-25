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
- Source installation, native DEB, RPM, and pacman packages, and a single
  executable Bash script with no runtime configuration file.
- Exact session targeting and explicit rejection of unsafe SSH arguments.
- A test suite that uses a fake SSH executable and never contacts a real host.

## Supported environments

Local requirements:

- Linux with Bash (arrays, `[[ ... ]]`, `SECONDS`).
- An OpenSSH client with `ssh -G` support.

Remote requirements:

- An SSH-accessible account with a POSIX-compatible login shell.
- `tmux` in `PATH` for non-interactive SSH commands.
- tmux support for `new-session -A -D` and exact `=session` targets.

tmux is required on the remote host, not on the machine running `sst`.

## Installation

Choose **one** installation method. Do not install both a source build under
`/usr/local/bin` and a distro package under `/usr/bin`; two copies of `sst`
would make upgrades and command resolution ambiguous.

### From source (installs `/usr/local/bin/sst`)

```sh
git clone https://github.com/opensst/opensst.git
cd opensst
sudo make install
sst --help
```

For a user-level installation instead:

```sh
make install PREFIX="$HOME/.local"
sst --help          # requires ~/.local/bin in PATH
```

Source installs place the executable at `/usr/local/bin/sst` by default.
`PREFIX` and `DESTDIR` are supported. Installing a package instead places it
at `/usr/bin/sst`.

Uninstall a source installation with the matching prefix:

```sh
sudo make uninstall                       # /usr/local/bin/sst
make uninstall PREFIX="$HOME/.local"      # ~/.local/bin/sst
```

### DEB package

Download `opensst_0.1.0_all.deb` from the
[latest release](https://github.com/opensst/opensst/releases), then install it
with your package manager so dependencies are resolved:

```sh
sudo apt install ./opensst_0.1.0_all.deb
sst --help
```

The package installs `/usr/bin/sst` and depends on `bash`, `openssh-client`,
and `curl`. Remove it with `sudo apt remove opensst`.

### RPM package

Download `opensst-0.1.0-1.noarch.rpm` from the same release page:

```sh
sudo dnf install ./opensst-0.1.0-1.noarch.rpm
sst --help
```

The package installs `/usr/bin/sst` and depends on `bash`, `openssh-clients`,
and `curl`. Remove it with `sudo dnf remove opensst`.

### Arch package

Download `opensst.pkg.tar.zst` (or the versioned
`opensst-0.1.0-1-any.pkg.tar.zst`) from the same release page:

```sh
sudo pacman -U ./opensst.pkg.tar.zst
sst --help
```

The package installs `/usr/bin/sst` and declares `bash`, `openssh`, and `curl`
as dependencies. Remove it with `sudo pacman -R opensst`. Updates do not
require archlinuxcn or an AUR helper; `sst update` downloads the current
release package and installs it locally with `pacman -U`.

DEB, RPM, and Arch packages are release assets; this project does not host an
apt, dnf, or pacman repository. Package artifacts are architecture-independent
(`all` / `noarch` / `any`), and SHA256 checksums are published next to them.

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
make package-deb VERSION=0.1.0
make package-rpm VERSION=0.1.0
make package-arch VERSION=0.1.0
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
