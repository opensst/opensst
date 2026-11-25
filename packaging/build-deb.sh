#!/usr/bin/env bash
set -euo pipefail

version=${1-}
outdir=${2:-dist}

if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'build-deb: version must be MAJOR.MINOR.PATCH\n' >&2
  exit 2
fi

if ! command -v dpkg-deb >/dev/null 2>&1; then
  printf 'build-deb: dpkg-deb not found; install dpkg (Debian/Ubuntu)\n' >&2
  exit 127
fi

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$outdir"
outdir=$(cd -- "$outdir" && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

install -Dm755 "$root/bin/sst" "$stage/usr/bin/sst"
install -Dm644 "$root/README.md" "$stage/usr/share/doc/opensst/README.md"
install -Dm644 "$root/LICENSE" "$stage/usr/share/doc/opensst/copyright"
install -d "$stage/DEBIAN"

cat >"$stage/DEBIAN/control" <<EOF
Package: opensst
Version: $version
Section: utils
Priority: optional
Architecture: all
Depends: bash, openssh-client
Maintainer: duanhongyi <duanhongyi@doopai.com>
Homepage: https://github.com/opensst/opensst
Description: Reconnectable SSH sessions backed by remote tmux
 OpenSST provides the sst command to open, list, and kill named remote
 tmux sessions over SSH. The open command reconnects to a long-lived
 session after a dropped connection.
EOF

dpkg-deb --root-owner-group --build "$stage" "$outdir/opensst_${version}_all.deb"