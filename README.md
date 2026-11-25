# OpenSST

`sst` is a portable Linux Bash CLI for reconnectable SSH sessions backed by
remote tmux. It opens, lists, and kills named remote tmux sessions and
reconnects an interactive session when a long-lived connection drops.

## Usage

```sh
sst open [ssh options] <host> <project>
sst list [ssh options] <host>
sst kill [ssh options] <host> <project>
sst --help
```

Project names must match `[A-Za-z0-9][A-Za-z0-9_-]*`.

## Install from source

```sh
sudo make install                         # /usr/local/bin/sst
make install PREFIX="$HOME/.local"        # ~/.local/bin/sst
```

## License

MIT. See [LICENSE](LICENSE).