#!/usr/bin/env bash
set -euo pipefail

version=${1-}
dist=${2-}

if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'release-assets: version must be MAJOR.MINOR.PATCH\n' >&2
  exit 2
fi
if [[ -z $dist || ! -d $dist ]]; then
  printf 'release-assets: distribution directory %s does not exist\n' "${dist:-<empty>}" >&2
  exit 2
fi
dist=$(cd -- "$dist" && pwd)

raw="$dist/sst"
deb="$dist/opensst_${version}_all.deb"
rpm="$dist/opensst-${version}-1.noarch.rpm"
arch="$dist/opensst-${version}-1-any.pkg.tar.zst"

for file in "$raw" "$deb" "$rpm" "$arch"; do
  if [[ ! -f $file ]]; then
    printf 'release-assets: missing %s\n' "${file#"$dist"/}" >&2
    exit 1
  fi
done

reported=$(bash "$raw" --version 2>/dev/null) || reported=''
if [[ $reported != "sst $version" ]]; then
  printf 'release-assets: sst reports %q, expected %q\n' "$reported" "sst $version" >&2
  exit 1
fi

cp "$deb" "$dist/opensst.deb"
cp "$rpm" "$dist/opensst.rpm"
cp "$arch" "$dist/opensst.pkg.tar.zst"

(
  cd "$dist"
  LC_ALL=C sha256sum \
    sst \
    opensst.deb \
    opensst.rpm \
    opensst.pkg.tar.zst \
    "opensst_${version}_all.deb" \
    "opensst-${version}-1.noarch.rpm" \
    "opensst-${version}-1-any.pkg.tar.zst" |
    LC_ALL=C sort -k2
) >"$dist/SHA256SUMS"
