#!/usr/bin/env bash
set -euo pipefail

version=${1-}
outdir=${2:-dist}

if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'build-rpm: version must be MAJOR.MINOR.PATCH\n' >&2
  exit 2
fi

if ! command -v rpmbuild >/dev/null 2>&1; then
  printf 'build-rpm: rpmbuild not found; install rpm-build\n' >&2
  exit 127
fi

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$outdir"
outdir=$(cd -- "$outdir" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

src="$tmp/opensst-$version"
install -Dm755 "$root/bin/sst" "$src/bin/sst"
install -Dm644 "$root/README.md" "$src/README.md"
install -Dm644 "$root/LICENSE" "$src/LICENSE"

tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
  -czf "$tmp/opensst-$version.tar.gz" -C "$tmp" "opensst-$version"

cat >"$tmp/opensst.spec" <<EOF
Name: opensst
Version: $version
Release: 1
Summary: Reconnectable SSH sessions backed by remote tmux
License: MIT
URL: https://github.com/opensst/opensst
Source0: opensst-%{version}.tar.gz
BuildArch: noarch

Requires: bash
Requires: openssh-clients

%description
OpenSST provides the sst command to open, list, and kill named remote
tmux sessions over SSH. The open command reconnects to a long-lived
session after a dropped connection.

%prep
%setup -q

%install
install -Dm755 bin/sst %{buildroot}%{_bindir}/sst

%files
%{_bindir}/sst
%doc README.md LICENSE
EOF

rpmbuild -bb \
  --define "_topdir $tmp/rpmbuild" \
  --define "_sourcedir $tmp" \
  "$tmp/opensst.spec"

cp "$tmp/rpmbuild/RPMS/noarch/opensst-$version-1.noarch.rpm" "$outdir/"