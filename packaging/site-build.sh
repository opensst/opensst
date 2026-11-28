#!/usr/bin/env bash
# Build one family's subdirectory of the gh-pages package-repository site
# from that release's package artifacts. Run once per family per release.
#
# usage: site-build.sh <deb|rpm|arch> <version> <dist-dir> <site-dir>
#
# Exit codes: 0 success, 2 validation error, 127 missing tool.
set -euo pipefail

usage() {
  printf 'usage: site-build.sh <deb|rpm|arch> <version> <dist-dir> <site-dir>\n' >&2
}

if [[ $# -ne 4 ]]; then
  printf 'site-build: expected 4 arguments, got %d\n' "$#" >&2
  usage
  exit 2
fi

family=$1
version=$2
dist=$3
site=$4

case $family in
  deb | rpm | arch) ;;
  *)
    printf 'site-build: unknown family %s (expected deb, rpm, or arch)\n' "$family" >&2
    usage
    exit 2
    ;;
esac

if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'site-build: version must be MAJOR.MINOR.PATCH\n' >&2
  exit 2
fi

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
embedded=$(sed -n "s/^SST_VERSION='\([0-9.]*\)'$/\1/p" "$root/bin/sst" | head -n1) || embedded=''
if [[ $embedded != "$version" ]]; then
  printf 'site-build: version %s does not match bin/sst SST_VERSION %s\n' \
    "$version" "${embedded:-unknown}" >&2
  exit 2
fi

if [[ ! -d $dist ]]; then
  printf 'site-build: dist directory %s does not exist\n' "$dist" >&2
  exit 2
fi
dist=$(cd -- "$dist" && pwd)

case $family in
  deb) pkg="opensst_${version}_all.deb" ;;
  rpm) pkg="opensst-${version}-1.noarch.rpm" ;;
  arch) pkg="opensst-${version}-1-any.pkg.tar.zst" ;;
esac
if [[ ! -f $dist/$pkg ]]; then
  printf 'site-build: missing %s in %s\n' "$pkg" "$dist" >&2
  exit 2
fi

# Probe the raw source asset when it is staged alongside the packages (the
# release pipeline stages it); local test runs may only have the packages.
if [[ -f $dist/sst ]]; then
  reported=$(bash "$dist/sst" --version 2>/dev/null) || reported=''
  if [[ $reported != "sst $version" ]]; then
    printf 'site-build: sst reports %q, expected %q\n' "$reported" "sst $version" >&2
    exit 2
  fi
fi

mkdir -p "$site"
site=$(cd -- "$site" && pwd)

case $family in
  deb)
    printf 'site-build: dpkg-scanpackages/apt-ftparchive not found; install dpkg-dev and apt-utils\n' >&2
    exit 127
    ;;
  rpm)
    printf 'site-build: createrepo_c not found; install createrepo-c\n' >&2
    exit 127
    ;;
  arch)
    printf 'site-build: repo-add not found; install pacman\n' >&2
    exit 127
    ;;
esac
