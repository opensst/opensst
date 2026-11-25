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
- Source installation, native DEB and RPM packages, and a single executable
  Bash script with no runtime configuration file.
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

The package installs `/usr/bin/sst` and depends on `bash` and
`openssh-client`. Remove it with `sudo apt remove opensst`.

### RPM package

Download `opensst-0.1.0-1.noarch.rpm` from the same release page:

```sh
sudo dnf install ./opensst-0.1.0-1.noarch.rpm
sst --help
```

The package installs `/usr/bin/sst` and depends on `bash` and
`openssh-clients`. Remove it with `sudo dnf remove opensst`.

DEB and RPM packages are release assets; this project does not host an apt or
dnf repository. Package artifacts are architecture-independent (`all` /
`noarch`), and SHA256 checksums are published next to them.

## Usage

```text
sst open [ssh options] <host> <project>
sst list [ssh options] <host>
sst kill [ssh options] <host> <project>
sst --help
```

Examples:

```sh
sst open devbox Work
sst open -p 2222 -l duanhongyi devbox Work
sst list devbox
sst kill devbox Work
```

SSH options are passed to `ssh` before the host, for example
`sst open -p 2222 -J jump@example devbox Work`. The host must be the only
positional SSH argument. Additional positional arguments, which SSH would
treat as a remote command, are rejected.

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

## Exit status

- `0`: the remote command succeeded.
- `2`: invalid usage, unsafe project name, ambiguous SSH arguments, an
  unresolvable or unsafe SSH configuration, or `open` without a terminal.
- `127`: local `ssh` is missing or remote `tmux` is missing.
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
```

Tests run the real executable with a fake `ssh` on `PATH`; they never contact
a real remote host. Package builds require `dpkg-deb` or `rpmbuild`, which may
not exist on Arch hosts. CI builds and smoke-tests both packages on Ubuntu and
Fedora.

Maintainer and release rules are in [AGENTS.md](AGENTS.md).

## License

MIT. See [LICENSE](LICENSE).