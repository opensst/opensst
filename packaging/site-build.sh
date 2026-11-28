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
    if ! command -v dpkg-scanpackages >/dev/null 2>&1 \
      || ! command -v apt-ftparchive >/dev/null 2>&1; then
      printf 'site-build: dpkg-scanpackages/apt-ftparchive not found; install dpkg-dev and apt-utils\n' >&2
      exit 127
    fi
    # Flat apt repository: no pool/ layout and Filename: is relative to this
    # directory (spec non-goal: no dists/ hierarchy for one package). The
    # family subdirectory is rebuilt from scratch, like every family.
    rm -rf "$site/deb"
    mkdir -p "$site/deb"
    cp "$dist/$pkg" "$site/deb/.pkg.tmp"
    mv "$site/deb/.pkg.tmp" "$site/deb/$pkg"
    (
      cd "$site/deb"
      dpkg-scanpackages . >Packages
      gzip -9 -c Packages >Packages.gz
      apt-ftparchive \
        -o APT::FTPArchive::Release::Origin=opensst \
        -o APT::FTPArchive::Release::Label=opensst \
        -o APT::FTPArchive::Release::Suite=stable \
        release . >Release
    )
    ;;
  rpm)
    if ! command -v createrepo_c >/dev/null 2>&1; then
      printf 'site-build: createrepo_c not found; install createrepo-c\n' >&2
      exit 127
    fi
    # gzip repodata is pinned: zstd-compressed metadata is unreadable by
    # older dnf4 clients (support floor). The family subdirectory is
    # rebuilt from scratch, like every family.
    rm -rf "$site/rpm"
    mkdir -p "$site/rpm"
    cp "$dist/$pkg" "$site/rpm/.pkg.tmp"
    mv "$site/rpm/.pkg.tmp" "$site/rpm/$pkg"
    createrepo_c --compress-type=gz "$site/rpm"
    ;;
  arch)
    if ! command -v repo-add >/dev/null 2>&1; then
      printf 'site-build: repo-add not found; install pacman\n' >&2
      exit 127
    fi
    # The family subdirectory is rebuilt from scratch: stale files from an
    # earlier run are removed and other families are never touched.
    rm -rf "$site/arch"
    mkdir -p "$site/arch"
    build=$(mktemp -d)
    trap 'rm -rf "$build"' EXIT
    cp "$dist/$pkg" "$site/arch/.pkg.tmp"
    mv "$site/arch/.pkg.tmp" "$site/arch/$pkg"
    cp "$dist/$pkg" "$build/$pkg"
    # repo-add writes opensst.db.tar.gz plus an opensst.db symlink and
    # files databases; only the materialized opensst.db is published
    # (pacman requests exactly that name and git cannot store the symlink).
    repo-add "$build/opensst.db.tar.gz" "$build/$pkg" >/dev/null
    rm -f "$build/opensst.db"
    mv "$build/opensst.db.tar.gz" "$build/opensst.db"
    cp "$build/opensst.db" "$site/arch/.db.tmp"
    mv "$site/arch/.db.tmp" "$site/arch/opensst.db"
    ;;
esac

# Shared epilogue: every successful family build publishes the site root.
# GitHub Pages would otherwise run Jekyll over the tree; .nojekyll opts out.
printf '' >"$site/.nojekyll"
sed "s/{{VERSION}}/$version/g" "$root/packaging/site-index.html" >"$site/index.html"
