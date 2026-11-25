#!/usr/bin/env bash
set -euo pipefail

version=${1-}
outdir=${2:-dist}

if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'build-arch: version must be MAJOR.MINOR.PATCH\n' >&2
  exit 2
fi

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
embedded=$(sed -n "s/^SST_VERSION='\([0-9.]*\)'$/\1/p" "$root/bin/sst" | head -n1) || embedded=''
if [[ $embedded != "$version" ]]; then
  printf 'build-arch: version %s does not match bin/sst SST_VERSION %s\n' \
    "$version" "${embedded:-unknown}" >&2
  exit 2
fi

if (( EUID == 0 )); then
  printf 'build-arch: run as a non-root user; makepkg refuses to run as root\n' >&2
  exit 2
fi

if ! command -v makepkg >/dev/null 2>&1; then
  printf 'build-arch: makepkg not found; install base-devel (Arch Linux)\n' >&2
  exit 127
fi
if ! command -v bsdtar >/dev/null 2>&1; then
  printf 'build-arch: bsdtar not found; install libarchive (Arch Linux)\n' >&2
  exit 127
fi

mkdir -p "$outdir"
outdir=$(cd -- "$outdir" && pwd)
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT

cat >"$build/PKGBUILD" <<EOF
pkgname=opensst
pkgver=$version
pkgrel=1
pkgdesc='Reconnectable SSH sessions backed by remote tmux'
arch=('any')
url='https://github.com/opensst/opensst'
license=('MIT')
depends=('bash' 'openssh' 'curl')
source=()

package() {
  install -Dm755 '$root/bin/sst' "\$pkgdir/usr/bin/sst"
  install -Dm644 '$root/LICENSE' "\$pkgdir/usr/share/licenses/opensst/LICENSE"
}
EOF

(
  cd "$build"
  BUILDDIR="$build/build" PKGEXT='.pkg.tar.zst' \
    makepkg --noconfirm --nodeps --nocheck >/dev/null
)

pkg="$build/opensst-$version-1-any.pkg.tar.zst"
if [[ ! -f $pkg ]]; then
  printf 'build-arch: makepkg did not produce %s\n' "$pkg" >&2
  exit 1
fi
cp "$pkg" "$outdir/"
