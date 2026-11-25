#!/usr/bin/env bash
set -u

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SST="$ROOT/bin/sst"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

tests=0
failures=0
STATUS=0
OUTPUT=
ERROR=

pass() {
  tests=$((tests + 1))
  printf 'ok %d - %s\n' "$tests" "$1"
}

fail() {
  tests=$((tests + 1))
  failures=$((failures + 1))
  printf 'not ok %d - %s\n' "$tests" "$1" >&2
}

assert_eq() {
  local actual=$1 expected=$2 label=$3
  if [[ $actual == "$expected" ]]; then
    pass "$label"
  else
    fail "$label (expected '$expected', got '$actual')"
  fi
}

assert_ne() {
  local actual=$1 unexpected=$2 label=$3
  if [[ $actual != "$unexpected" ]]; then
    pass "$label"
  else
    fail "$label (unexpected '$actual')"
  fi
}

assert_contains() {
  local haystack=$1 needle=$2 label=$3
  if [[ $haystack == *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label (missing '$needle')"
  fi
}

assert_not_contains() {
  local haystack=$1 needle=$2 label=$3
  if [[ $haystack != *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label (unexpected '$needle')"
  fi
}

assert_file_contains() {
  local file=$1 needle=$2 label=$3
  if [[ -f $file ]] && grep -Fq -- "$needle" "$file"; then
    pass "$label"
  else
    fail "$label (missing '$needle' in $file)"
  fi
}

assert_file() {
  if [[ -f $1 ]]; then
    pass "$2"
  else
    fail "$2 (missing $1)"
  fi
}

assert_file_order() {
  local file=$1 first=$2 second=$3 label=$4 first_line second_line
  first_line=$(grep -nF -- "$first" "$file" | head -n1 | cut -d: -f1)
  second_line=$(grep -nF -- "$second" "$file" | head -n1 | cut -d: -f1)
  if [[ -n $first_line && -n $second_line ]] && (( first_line < second_line )); then
    pass "$label"
  else
    fail "$label (expected '$first' before '$second' in $file)"
  fi
}

assert_executable() {
  if [[ -x $1 ]]; then
    pass "$2"
  else
    fail "$2 (not executable: $1)"
  fi
}

assert_absent() {
  if [[ ! -e $1 ]]; then
    pass "$2"
  else
    fail "$2 (still present: $1)"
  fi
}

run_capture() {
  : >"$TMP/stdout"
  : >"$TMP/stderr"
  "$@" >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  OUTPUT=$(<"$TMP/stdout")
  ERROR=$(<"$TMP/stderr")
}

test_help() {
  run_capture "$SST" --help
  assert_eq "$STATUS" 0 "sst --help exits 0"
  assert_contains "$OUTPUT" "sst open" "help documents open"
  assert_contains "$OUTPUT" "sst list" "help documents list"
  assert_contains "$OUTPUT" "sst kill" "help documents kill"
  assert_contains "$OUTPUT" "-t and -T are rejected" "help documents sst-owned terminal allocation"
  assert_contains "$OUTPUT" "sst update" "help documents update"
  assert_contains "$OUTPUT" "--check" "help documents update --check"

  run_capture "$SST" -h
  assert_eq "$STATUS" 0 "sst -h exits 0"
  assert_contains "$OUTPUT" "sst open" "-h prints the same usage"
}

test_version() {
  run_capture "$SST" --version
  assert_eq "$STATUS" 0 "sst --version exits 0"
  assert_eq "$OUTPUT" "sst 0.2.1" "sst --version prints the embedded version"

  run_capture "$SST" --help
  assert_contains "$OUTPUT" "sst --version" "help documents --version"
}

test_version_helpers() {
  run_sourced _sst_normalize_version '1:0.1.0-2'
  assert_eq "$STATUS" 0 "epoch and package release are normalized"
  assert_eq "$OUTPUT" "0.1.0" "normalized version keeps three components"

  run_sourced _sst_normalize_version '0.1.1-1'
  assert_eq "$OUTPUT" "0.1.1" "arch pkgrel is normalized away"

  run_sourced _sst_normalize_version '0.1.0-rc1'
  assert_eq "$STATUS" 1 "prerelease versions are rejected"

  run_sourced _sst_normalize_version '0.1'
  assert_eq "$STATUS" 1 "short versions are rejected"

  run_sourced _sst_version_cmp 0.1.0 0.1.1
  assert_eq "$OUTPUT" lt "older version compares lt"

  run_sourced _sst_version_cmp 0.1.0 0.1.0
  assert_eq "$OUTPUT" eq "equal versions compare eq"

  run_sourced _sst_version_cmp 0.2.1 0.1.9
  assert_eq "$OUTPUT" gt "newer version compares gt"

  for pair in 'deb opensst.deb' 'rpm opensst.rpm' 'pacman opensst.pkg.tar.zst' 'source sst'; do
    set -- $pair
    run_sourced _sst_asset_for_method "$1"
    assert_eq "$OUTPUT" "$2" "asset for $1"
  done

  run_sourced _sst_asset_for_method unknown
  assert_eq "$STATUS" 1 "unknown update method has no asset"
}

# Report the detection failure reason for assertions; library detection itself
# only sets _SST_DETECT_ERROR.
detect_error_text() {
  if _sst_detect_install "$1"; then
    printf 'ok\n'
  else
    printf '%s\n' "$_SST_DETECT_ERROR"
  fi
}

test_update_detection() {
  local exe="$TMP/detect/sst"
  mkdir -p "$(dirname "$exe")"
  cp "$SST" "$exe"
  chmod +x "$exe"

  run_sourced _sst_self_path "$exe"
  assert_eq "$STATUS" 0 "self path resolves"
  assert_eq "$OUTPUT" "$exe" "self path is absolute"

  run_sourced _sst_detect_install "$exe"
  assert_eq "$STATUS" 0 "writable untracked source install is detected"
  assert_eq "$OUTPUT" source "source method is reported"

  FAKE_DPKG_OWNER=opensst run_sourced _sst_detect_install "$exe"
  assert_eq "$OUTPUT" deb "DEB owner is detected"

  FAKE_RPM_OWNER=opensst run_sourced _sst_detect_install "$exe"
  assert_eq "$OUTPUT" rpm "RPM owner is detected"

  : >"$TMP/rpm-detect.log"
  FAKE_RPM_LOG="$TMP/rpm-detect.log" FAKE_RPM_OWNER=opensst \
    run_sourced _sst_detect_install "$exe"
  assert_file_contains "$TMP/rpm-detect.log" "-qf --qf %{NAME}" \
    "RPM ownership query asks for the package name"

  FAKE_PACMAN_OWNER=opensst run_sourced _sst_detect_install "$exe"
  assert_eq "$OUTPUT" pacman "pacman owner is detected"

  FAKE_DPKG_OWNER=otherpkg run_sourced detect_error_text "$exe"
  assert_contains "$OUTPUT" "otherpkg" "foreign package owner is named in the refusal"
  assert_contains "$OUTPUT" "$exe" "foreign package refusal names the path"

  FAKE_DPKG_MULTI=1 run_sourced detect_error_text "$exe"
  assert_contains "$OUTPUT" "multiple" "multiple package owners are refused"
  assert_contains "$OUTPUT" "$exe" "multiple-owner refusal names the path"

  run_sourced detect_error_text /usr/bin/sst
  assert_contains "$OUTPUT" "/usr/bin/sst" "unowned /usr/bin path is refused"

  if command -v git >/dev/null 2>&1; then
    local repo="$TMP/tracked-repo"
    mkdir -p "$repo"
    git -C "$repo" init -q
    cp "$SST" "$repo/sst"
    chmod +x "$repo/sst"
    git -C "$repo" add sst
    run_sourced detect_error_text "$repo/sst"
    assert_contains "$OUTPUT" "Git" "Git-tracked source file is refused"
  else
    printf '# skip Git-tracked source test: git is unavailable\n'
  fi
}

test_update_version_readers() {
  local exe="$TMP/readers/sst" file="$TMP/readers/asset"
  mkdir -p "$(dirname "$exe")"
  cp "$SST" "$exe"
  printf 'x\n' >"$file"

  FAKE_DPKG_INSTALLED_VERSION=0.1.0 run_sourced _sst_installed_version deb "$exe"
  assert_eq "$OUTPUT" 0.1.0 "DEB installed version"
  FAKE_DPKG_ASSET_VERSION=0.1.1 run_sourced _sst_asset_version deb "$file"
  assert_eq "$OUTPUT" 0.1.1 "DEB asset version"

  FAKE_RPM_INSTALLED_VERSION=0.1.0 run_sourced _sst_installed_version rpm "$exe"
  assert_eq "$OUTPUT" 0.1.0 "RPM installed version"
  FAKE_RPM_ASSET_VERSION=0.1.1 run_sourced _sst_asset_version rpm "$file"
  assert_eq "$OUTPUT" 0.1.1 "RPM asset version"

  FAKE_PACMAN_INSTALLED_VERSION=0.1.0-1 run_sourced _sst_installed_version pacman "$exe"
  assert_eq "$OUTPUT" 0.1.0-1 "pacman installed version"
  FAKE_PACMAN_ASSET_VERSION=0.1.1-1 run_sourced _sst_asset_version pacman "$file"
  assert_eq "$OUTPUT" 0.1.1-1 "pacman asset version"

  run_sourced _sst_installed_version source "$exe"
  assert_eq "$OUTPUT" 0.2.1 "source installed version"

  printf "SST_VERSION='0.1.1'\n" >"$file"
  run_sourced _sst_asset_version source "$file"
  assert_eq "$OUTPUT" 0.1.1 "source asset version"

  printf '#!/bin/bash\n' >"$file"
  run_sourced _sst_asset_version source "$file"
  assert_eq "$STATUS" 1 "source asset without version is rejected"

  (
    PATH=/nonexistent
    # shellcheck disable=SC1090
    source "$SST"
    _sst_asset_version deb "$file"
  ) >/dev/null 2>&1
  STATUS=$?
  assert_eq "$STATUS" 127 "missing dpkg-deb returns 127"
}

test_update_download() {
  local dir="$TMP/download" asset="$TMP/download/sst" sums="$TMP/download/SHA256SUMS"
  mkdir -p "$dir"
  printf "SST_VERSION='0.1.1'\n" >"$asset"
  (cd "$dir" && sha256sum sst >SHA256SUMS)

  FAKE_CURL_DIR="$dir" run_sourced _sst_download https://example.invalid/sst "$TMP/fetched"
  assert_eq "$STATUS" 0 "curl download succeeds"

  FAKE_CURL_FAIL_ASSET=sst run_sourced _sst_download https://example.invalid/sst "$TMP/failed"
  assert_eq "$STATUS" 1 "download failure is reported"

  run_sourced _sst_verify_sha256 "$asset" "$sums" sst
  assert_eq "$STATUS" 0 "matching checksum is accepted"

  printf 'x\n' >"$asset"
  run_sourced _sst_verify_sha256 "$asset" "$sums" sst
  assert_eq "$STATUS" 1 "mismatched checksum is rejected"

  run_sourced _sst_verify_sha256 "$asset" "$sums" missing
  assert_eq "$STATUS" 1 "missing checksum entry is rejected"

  printf 'deadbeef  sst\n' >"$sums"
  run_sourced _sst_verify_sha256 "$asset" "$sums" sst
  assert_eq "$STATUS" 1 "malformed checksum is rejected"

  printf '%s  sst\n%s  sst\n' "$(sha256sum "$asset" | cut -d' ' -f1)" \
    "$(sha256sum "$asset" | cut -d' ' -f1)" >"$sums"
  run_sourced _sst_verify_sha256 "$asset" "$sums" sst
  assert_eq "$STATUS" 1 "duplicate checksum entries are rejected"

  (
    PATH=/nonexistent
    # shellcheck disable=SC1090
    source "$SST"
    _sst_download https://example.invalid/sst "$TMP/none"
  ) >/dev/null 2>&1
  STATUS=$?
  assert_eq "$STATUS" 127 "missing downloader returns 127"

  (
    PATH=/nonexistent
    # shellcheck disable=SC1090
    source "$SST"
    _sst_verify_sha256 "$asset" "$sums" sst
  ) >/dev/null 2>&1
  STATUS=$?
  assert_eq "$STATUS" 127 "missing sha256sum returns 127"

  local only="$TMP/wget-only"
  mkdir -p "$only"
  cp "$FAKEBIN/wget" "$only/wget"
  ln -s "$(command -v cp)" "$only/cp"
  (
    PATH="$only"
    # shellcheck disable=SC1090
    source "$SST"
    FAKE_WGET_DIR="$dir" _sst_download https://example.invalid/sst "$TMP/wget-fetched"
  )
  STATUS=$?
  assert_eq "$STATUS" 0 "wget fallback succeeds when curl is absent"
  assert_file "$TMP/wget-fetched" "wget fallback writes the destination"
}

run_update() {
  local self="$TMP/update-self/sst"
  mkdir -p "$(dirname "$self")"
  sed "s/^SST_VERSION=.*/SST_VERSION='0.1.0'/" "$SST" >"$self"
  chmod +x "$self"
  : >"$TMP/stdout"
  : >"$TMP/stderr"
  env PATH="$FAKEBIN:$PATH" \
    FAKE_SSH_LOG="${FAKE_SSH_LOG-}" \
    FAKE_SSH_G_LOG="${FAKE_SSH_G_LOG-}" \
    FAKE_CURL_DIR="${FAKE_CURL_DIR-}" \
    FAKE_CURL_FAIL_ASSET="${FAKE_CURL_FAIL_ASSET-}" \
    FAKE_CURL_LOG="${FAKE_CURL_LOG-}" \
    FAKE_WGET_DIR="${FAKE_WGET_DIR-}" \
    FAKE_WGET_FAIL_ASSET="${FAKE_WGET_FAIL_ASSET-}" \
    FAKE_DPKG_OWNER="${FAKE_DPKG_OWNER-}" \
    FAKE_DPKG_MULTI="${FAKE_DPKG_MULTI-}" \
    FAKE_DPKG_INSTALLED_VERSION="${FAKE_DPKG_INSTALLED_VERSION-}" \
    FAKE_DPKG_ASSET_VERSION="${FAKE_DPKG_ASSET_VERSION-}" \
    FAKE_RPM_OWNER="${FAKE_RPM_OWNER-}" \
    FAKE_RPM_INSTALLED_VERSION="${FAKE_RPM_INSTALLED_VERSION-}" \
    FAKE_RPM_ASSET_VERSION="${FAKE_RPM_ASSET_VERSION-}" \
    FAKE_PACMAN_OWNER="${FAKE_PACMAN_OWNER-}" \
    FAKE_PACMAN_INSTALLED_VERSION="${FAKE_PACMAN_INSTALLED_VERSION-}" \
    FAKE_PACMAN_ASSET_VERSION="${FAKE_PACMAN_ASSET_VERSION-}" \
    FAKE_PKG_STATE="${FAKE_PKG_STATE-}" \
    FAKE_PKG_ASSET_VERSION="${FAKE_PKG_ASSET_VERSION-}" \
    FAKE_PKG_FAIL="${FAKE_PKG_FAIL-}" \
    FAKE_SUDO_LOG="$TMP/sudo.log" \
    FAKE_SUDO_FAIL="${FAKE_SUDO_FAIL-}" \
    "$self" "$@" >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  OUTPUT=$(<"$TMP/stdout")
  ERROR=$(<"$TMP/stderr")
}

run_update_tty() {
  local input=$1
  shift
  local self="$TMP/update-self/sst"
  mkdir -p "$(dirname "$self")"
  sed "s/^SST_VERSION=.*/SST_VERSION='0.1.0'/" "$SST" >"$self"
  chmod +x "$self"
  : >"$TMP/stdout"
  : >"$TMP/stderr"
  local cmd
  cmd=$(printf 'PATH=%q FAKE_CURL_DIR=%q FAKE_DPKG_OWNER=%q FAKE_RPM_OWNER=%q FAKE_PACMAN_OWNER=%q %q' \
    "$FAKEBIN:$PATH" "${FAKE_CURL_DIR-}" "${FAKE_DPKG_OWNER-}" \
    "${FAKE_RPM_OWNER-}" "${FAKE_PACMAN_OWNER-}" "$self")
  local arg
  for arg in "$@"; do
    cmd+=$(printf ' %q' "$arg")
  done
  printf '%s\n' "$input" | script -qec "$cmd" /dev/null >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  OUTPUT=$(<"$TMP/stdout")
  ERROR=$(<"$TMP/stderr")
}

INSTALL="$ROOT/install.sh"

make_installer_path() {
  local dir=$1 manager=${2-} tool
  rm -rf "$dir"
  mkdir -p "$dir"
  for tool in bash mktemp rm cp mv mkdir dirname basename cat grep sed tr sha256sum install; do
    ln -s "$(command -v "$tool")" "$dir/$tool"
  done
  ln -s "$FAKEBIN/curl" "$dir/curl"
  ln -s "$FAKEBIN/wget" "$dir/wget"
  ln -s "$FAKEBIN/sudo" "$dir/sudo"
  if [[ -n $manager ]]; then
    ln -s "$FAKEBIN/$manager" "$dir/$manager"
  fi
  cat >"$dir/sst" <<'EOF'
#!/bin/bash
printf 'sst %s\n' "${FAKE_INSTALLED_VERSION:-0.2.1}"
EOF
  chmod +x "$dir/sst"
}

installer_release() {
  local dir=$1 version=$2
  rm -rf "$dir"
  mkdir -p "$dir"
  printf 'deb\n' >"$dir/opensst.deb"
  printf 'rpm\n' >"$dir/opensst.rpm"
  printf 'arch\n' >"$dir/opensst.pkg.tar.zst"
  printf 'deb\n' >"$dir/opensst_${version}_all.deb"
  printf 'rpm\n' >"$dir/opensst-${version}-1.noarch.rpm"
  printf 'arch\n' >"$dir/opensst-${version}-1-any.pkg.tar.zst"
  cat >"$dir/sst" <<EOF
#!/bin/bash
printf 'sst %s\\n' "$version"
EOF
  chmod +x "$dir/sst"
  (
    cd "$dir" &&
      sha256sum \
        sst \
        opensst.deb \
        opensst.rpm \
        opensst.pkg.tar.zst \
        "opensst_${version}_all.deb" \
        "opensst-${version}-1.noarch.rpm" \
        "opensst-${version}-1-any.pkg.tar.zst" >SHA256SUMS
  )
}

reset_install_logs() {
  : >"$TMP/install-curl.log"
  : >"$TMP/install-wget.log"
  : >"$TMP/install-sudo.log"
}

run_installer() {
  local pathdir=$1
  shift
  : >"$TMP/stdout"
  : >"$TMP/stderr"
  reset_install_logs
  env PATH="$pathdir" \
    FAKE_CURL_DIR="${FAKE_CURL_DIR-}" \
    FAKE_CURL_FAIL_ASSET="${FAKE_CURL_FAIL_ASSET-}" \
    FAKE_CURL_LOG="$TMP/install-curl.log" \
    FAKE_WGET_DIR="${FAKE_WGET_DIR-}" \
    FAKE_WGET_FAIL_ASSET="${FAKE_WGET_FAIL_ASSET-}" \
    FAKE_WGET_LOG="$TMP/install-wget.log" \
    FAKE_PKG_FAIL="${FAKE_PKG_FAIL-}" \
    FAKE_SUDO_LOG="$TMP/install-sudo.log" \
    FAKE_SUDO_FAIL="${FAKE_SUDO_FAIL-}" \
    FAKE_INSTALLED_VERSION="${FAKE_INSTALLED_VERSION-0.2.1}" \
    /bin/bash "$INSTALL" "$@" >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  OUTPUT=$(<"$TMP/stdout")
  ERROR=$(<"$TMP/stderr")
}

test_install_script() {
  local base="$TMP/installer"
  local rel_latest="$base/release-latest" rel_pinned="$base/release-v0.2.1"
  local rel_bad="$base/release-bad" rel_invalid="$base/release-invalid"
  local p_pacman="$base/path-pacman" p_apt="$base/path-apt"
  local p_dpkg="$base/path-dpkg" p_dnf="$base/path-dnf" p_yum="$base/path-yum"
  local p_rpm="$base/path-rpm" p_none="$base/path-none" p_priority="$base/path-priority"
  local prefix="$base/prefix" empty="$base/empty-path"

  rm -rf "$base"
  mkdir -p "$base" "$empty"
  installer_release "$rel_latest" 0.2.1
  installer_release "$rel_pinned" 0.2.1
  installer_release "$rel_bad" 0.2.1
  printf 'corrupt\n' >"$rel_bad/opensst.deb"
  installer_release "$rel_invalid" 0.2.1
  cat >"$rel_invalid/sst" <<'EOF'
#!/bin/bash
printf 'not-a-version\n'
EOF
  chmod +x "$rel_invalid/sst"

  assert_executable "$INSTALL" "install.sh is executable"

  run_installer "$empty" --help
  assert_eq "$STATUS" 0 "install.sh --help exits 0"
  assert_contains "$OUTPUT" "--version" "installer help documents --version"
  assert_contains "$OUTPUT" "--prefix" "installer help documents --prefix"

  run_installer "$empty" --bogus
  assert_eq "$STATUS" 2 "installer rejects an unknown option"
  assert_contains "$ERROR" "usage" "installer usage error is written to stderr"

  run_installer "$empty" --version 0.2
  assert_eq "$STATUS" 2 "installer rejects a non-semver version"

  make_installer_path "$p_pacman" pacman
  make_installer_path "$p_apt" apt-get
  make_installer_path "$p_dpkg" dpkg
  make_installer_path "$p_dnf" dnf
  make_installer_path "$p_yum" yum
  make_installer_path "$p_rpm" rpm
  make_installer_path "$p_none"
  make_installer_path "$p_priority" pacman
  ln -s "$FAKEBIN/apt-get" "$p_priority/apt-get"

  FAKE_CURL_DIR="$rel_latest" run_installer "$p_pacman"
  assert_eq "$STATUS" 0 "Arch install succeeds"
  assert_file_contains "$TMP/install-curl.log" \
    "releases/latest/download/opensst.pkg.tar.zst" "Arch uses the stable alias"
  assert_file_contains "$TMP/install-sudo.log" "pacman -U --noconfirm" \
    "Arch installs with pacman -U"
  assert_contains "$OUTPUT" "0.2.1" "Arch install reports the installed version"

  FAKE_CURL_DIR="$rel_pinned" run_installer "$p_pacman" --version 0.2.1
  assert_eq "$STATUS" 0 "pinned Arch install succeeds"
  assert_file_contains "$TMP/install-curl.log" \
    "releases/download/v0.2.1/opensst-0.2.1-1-any.pkg.tar.zst" \
    "pinned Arch uses the versioned asset"

  FAKE_CURL_DIR="$rel_pinned" run_installer "$p_pacman" --version=0.2.1
  assert_eq "$STATUS" 0 "installer accepts --version=VERSION"

  FAKE_CURL_DIR="$rel_latest" run_installer "$p_apt"
  assert_eq "$STATUS" 0 "DEB install succeeds"
  assert_file_contains "$TMP/install-curl.log" \
    "releases/latest/download/opensst.deb" "DEB uses the stable alias"
  assert_file_contains "$TMP/install-sudo.log" "apt-get install -y" \
    "DEB installs with apt-get"

  FAKE_CURL_DIR="$rel_latest" run_installer "$p_dpkg"
  assert_eq "$STATUS" 0 "DEB install succeeds without apt-get"
  assert_file_contains "$TMP/install-sudo.log" "dpkg -i" \
    "DEB falls back to dpkg -i"

  FAKE_CURL_DIR="$rel_latest" run_installer "$p_dnf"
  assert_eq "$STATUS" 0 "RPM install with dnf succeeds"
  assert_file_contains "$TMP/install-sudo.log" "dnf install -y" \
    "RPM uses dnf when available"

  FAKE_CURL_DIR="$rel_latest" run_installer "$p_yum"
  assert_eq "$STATUS" 0 "RPM install with yum succeeds"
  assert_file_contains "$TMP/install-sudo.log" "yum localinstall -y" \
    "RPM uses yum localinstall when available"

  FAKE_CURL_DIR="$rel_latest" run_installer "$p_rpm"
  assert_eq "$STATUS" 0 "RPM install with rpm succeeds"
  assert_file_contains "$TMP/install-sudo.log" "rpm -Uvh" \
    "RPM falls back to rpm -Uvh"

  FAKE_CURL_DIR="$rel_latest" run_installer "$p_priority"
  assert_eq "$STATUS" 0 "detection prefers pacman over apt-get"
  assert_file_contains "$TMP/install-sudo.log" "pacman -U" \
    "pacman is selected when both tools exist"

  rm -rf "$prefix"
  FAKE_CURL_DIR="$rel_latest" FAKE_INSTALLED_VERSION=0.2.1 \
    run_installer "$p_none" --prefix "$prefix"
  assert_eq "$STATUS" 0 "source fallback succeeds"
  assert_executable "$prefix/bin/sst" "source fallback installs an executable"
  run_capture "$prefix/bin/sst" --version
  assert_eq "$OUTPUT" "sst 0.2.1" "source fallback installs the requested version"
  assert_eq "$(wc -l <"$TMP/install-sudo.log")" 0 \
    "a writable prefix does not use sudo"

  mkdir -p "$prefix/bin"
  printf '#!/bin/bash\nprintf "sst 0.1.0\\n"\n' >"$prefix/bin/sst"
  chmod +x "$prefix/bin/sst"
  FAKE_CURL_DIR="$rel_pinned" run_installer "$p_none" --version 0.1.0 --prefix "$prefix"
  assert_eq "$STATUS" 1 "pinned source version mismatch fails"
  assert_eq "$("$prefix/bin/sst" --version)" "sst 0.1.0" \
    "a failed source install restores the previous file"

  FAKE_CURL_DIR="$rel_bad" run_installer "$p_apt"
  assert_eq "$STATUS" 1 "checksum mismatch fails"
  assert_contains "$ERROR" "checksum" "checksum mismatch is explained"
  assert_eq "$(wc -l <"$TMP/install-sudo.log")" 0 \
    "checksum failure installs nothing"

  FAKE_CURL_DIR="$rel_invalid" run_installer "$p_none" --prefix "$base/invalid-prefix"
  assert_eq "$STATUS" 1 "invalid post-install version fails"
  assert_absent "$base/invalid-prefix/bin/sst" \
    "failed post-install check removes the new file"

  make_installer_path "$p_none" pacman
  rm -f "$p_none/curl" "$p_none/wget"
  run_installer "$p_none"
  assert_eq "$STATUS" 127 "missing downloader exits 127"
  assert_contains "$ERROR" "curl or wget" "missing downloader is explained"

  make_installer_path "$p_none" pacman
  rm -f "$p_none/sha256sum"
  run_installer "$p_none"
  assert_eq "$STATUS" 127 "missing sha256sum exits 127"

  make_installer_path "$p_none"
  rm -f "$p_none/curl"
  FAKE_WGET_DIR="$rel_latest" run_installer "$p_none" --prefix "$base/wget-prefix"
  assert_eq "$STATUS" 0 "wget fallback works when curl is absent"
  assert_file_contains "$TMP/install-wget.log" \
    "releases/latest/download/sst" "wget fallback uses the same URL"

  if (( EUID != 0 )); then
    make_installer_path "$p_none" pacman
    rm -f "$p_none/sudo"
    FAKE_CURL_DIR="$rel_latest" run_installer "$p_none"
    assert_eq "$STATUS" 127 "missing sudo exits 127 for a system package install"

    make_installer_path "$p_none"
    rm -f "$p_none/sudo"
    mkdir -p "$base/readonly"
    chmod 555 "$base/readonly"
    run_installer "$p_none" --prefix "$base/readonly"
    assert_eq "$STATUS" 127 "missing sudo exits 127 for a non-writable prefix"
    chmod 755 "$base/readonly"
  fi

  make_installer_path "$p_none" pacman
  FAKE_CURL_DIR="$rel_latest" FAKE_PKG_FAIL=1 run_installer "$p_none"
  assert_eq "$STATUS" 1 "package install failure exits 1"
  assert_contains "$ERROR" "pacman" "package install failure names the manager"

  FAKE_CURL_DIR="$rel_latest" run_installer "$p_none" --prefix "$base/unused"
  assert_eq "$STATUS" 2 "--prefix with a package manager is rejected"
}

test_update_check() {
  local dir="$TMP/release-check" self="$TMP/update-self/sst"
  mkdir -p "$dir"
  printf "#!/bin/bash\nSST_VERSION='0.1.1'\nprintf 'sst 0.1.1\\n'\n" >"$dir/sst"
  (cd "$dir" && sha256sum sst >SHA256SUMS)

  FAKE_CURL_DIR="$dir" run_update update --check
  assert_eq "$STATUS" 0 "source update check exits 0"
  assert_contains "$OUTPUT" "installed 0.1.0" "check reports installed version"
  assert_contains "$OUTPUT" "latest 0.1.1" "check reports latest version"
  assert_contains "$OUTPUT" "update available" "check reports availability"
  assert_eq "$(grep -c "SST_VERSION='0.1.0'" "$self")" 1 \
    "check does not modify the source file"

  printf "#!/bin/bash\nSST_VERSION='0.1.0'\nprintf 'sst 0.1.0\\n'\n" >"$dir/sst"
  (cd "$dir" && sha256sum sst >SHA256SUMS)
  FAKE_CURL_DIR="$dir" run_update update --check
  assert_contains "$OUTPUT" "up to date" "equal versions are up to date"

  printf "#!/bin/bash\nSST_VERSION='0.0.9'\nprintf 'sst 0.0.9\\n'\n" >"$dir/sst"
  (cd "$dir" && sha256sum sst >SHA256SUMS)
  FAKE_CURL_DIR="$dir" run_update update --check
  assert_eq "$STATUS" 0 "newer installed version is not a failure"
  assert_contains "$OUTPUT" "no downgrade" "newer installed version refuses downgrade"

  printf "#!/bin/bash\nSST_VERSION='0.1.1'\nprintf 'sst 0.1.1\\n'\n" >"$dir/sst"
  (cd "$dir" && sha256sum sst >SHA256SUMS)
  printf 'corrupt\n' >"$dir/sst"
  FAKE_CURL_DIR="$dir" run_update update --check
  assert_eq "$STATUS" 1 "checksum mismatch fails"
  assert_contains "$ERROR" "checksum" "checksum failure is explained"

  local nover="$TMP/no-version/sst"
  mkdir -p "$(dirname "$nover")"
  sed '/^SST_VERSION=/d' "$SST" >"$nover"
  chmod +x "$nover"
  env PATH="$FAKEBIN:$PATH" FAKE_CURL_DIR="$dir" "$nover" update --check \
    >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  assert_eq "$STATUS" 2 "source without SST_VERSION exits 2"
  assert_contains "$(cat "$TMP/stderr")" "reinstall" \
    "source without SST_VERSION suggests reinstalling"
}

test_update_source() {
  local dir="$TMP/release-source" target="$TMP/update-self/sst"
  mkdir -p "$dir"
  printf "#!/bin/bash\nSST_VERSION='0.1.1'\nprintf 'sst 0.1.1\\n'\n" >"$dir/sst"
  (cd "$dir" && sha256sum sst >SHA256SUMS)

  FAKE_CURL_DIR="$dir" run_update update --yes
  assert_eq "$STATUS" 0 "source update succeeds"
  assert_contains "$(cat "$target")" "SST_VERSION='0.1.1'" "source file is replaced"
  assert_eq "$(stat -c %a "$target")" 755 "source file keeps executable mode"

  printf "#!/bin/bash\nSST_VERSION='0.1.1'\nexit 1\n" >"$dir/sst"
  (cd "$dir" && sha256sum sst >SHA256SUMS)
  FAKE_CURL_DIR="$dir" run_update update --yes
  assert_eq "$STATUS" 1 "broken replacement fails sanity check"
  assert_contains "$(cat "$target")" "SST_VERSION='0.1.0'" \
    "old source file is restored"
  assert_contains "$(cat "$target")" "_sst_main" \
    "restored file is the full CLI, not the broken asset"

  local sudo_target="$TMP/sudo-source/sst" sudo_asset="$TMP/sudo-asset"
  mkdir -p "$(dirname "$sudo_target")"
  cp "$SST" "$sudo_target"
  chmod +x "$sudo_target"
  printf "#!/bin/bash\nSST_VERSION='0.1.1'\nprintf 'sst 0.1.1\\n'\n" >"$sudo_asset"
  : >"$TMP/sudo.log"
  FAKE_SUDO_LOG="$TMP/sudo.log" run_sourced \
    _sst_apply_source "$sudo_asset" "$sudo_target" sudo
  assert_eq "$STATUS" 0 "sudo source apply succeeds"
  assert_file_contains "$TMP/sudo.log" "install" "sudo source apply uses sudo install"
  assert_contains "$(cat "$sudo_target")" "SST_VERSION='0.1.1'" \
    "sudo source target is replaced"

  if (( EUID != 0 )); then
    (
      PATH=/nonexistent
      # shellcheck disable=SC1090
      source "$SST"
      _sst_apply_source "$sudo_asset" "$sudo_target" sudo
    ) >/dev/null 2>&1
    STATUS=$?
    assert_eq "$STATUS" 127 "source apply without sudo returns 127"
  else
    printf '# skip source sudo-missing test: running as root\n'
  fi
}

test_update_interaction() {
  local dir="$TMP/release-interaction" self="$TMP/update-self/sst"
  mkdir -p "$dir"
  printf "#!/bin/bash\nSST_VERSION='0.1.1'\nprintf 'sst 0.1.1\\n'\n" >"$dir/sst"
  (cd "$dir" && sha256sum sst >SHA256SUMS)

  : >"$TMP/sudo.log"
  rm -f "$TMP/sudo.log"
  FAKE_CURL_DIR="$dir" run_update update
  assert_eq "$STATUS" 2 "non-interactive update without --yes exits 2"
  assert_absent "$TMP/sudo.log" "non-interactive refusal runs no privileged command"

  FAKE_CURL_DIR="$dir" run_update update --check --yes
  assert_eq "$STATUS" 2 "--check with --yes exits 2"

  local before
  before=$(sha256sum "$self" | cut -d' ' -f1)
  FAKE_CURL_DIR="$dir" run_update_tty n update
  assert_eq "$STATUS" 0 "declining confirmation exits 0"
  assert_eq "$(sha256sum "$self" | cut -d' ' -f1)" "$before" \
    "declining confirmation leaves the file unchanged"

  FAKE_CURL_DIR="$dir" run_update_tty y update
  assert_eq "$STATUS" 0 "accepting confirmation applies the update"
  assert_contains "$(cat "$self")" "SST_VERSION='0.1.1'" \
    "accepted confirmation replaces the source file"
}

test_update_packages() {
  local dir="$TMP/release-packages" state="$TMP/pkg-state"
  mkdir -p "$dir"
  printf 'dummy\n' >"$dir/opensst.deb"
  printf 'dummy\n' >"$dir/opensst.rpm"
  printf 'dummy\n' >"$dir/opensst.pkg.tar.zst"
  (cd "$dir" && sha256sum opensst.deb opensst.rpm opensst.pkg.tar.zst >SHA256SUMS)

  : >"$TMP/sudo.log"
  printf '0.1.0\n' >"$state"

  FAKE_CURL_DIR="$dir" FAKE_DPKG_OWNER=opensst FAKE_PKG_STATE="$state" \
    FAKE_PKG_ASSET_VERSION=0.1.1 FAKE_DPKG_ASSET_VERSION=0.1.1 \
    run_update update --yes
  assert_eq "$STATUS" 0 "DEB update succeeds"
  assert_file_contains "$TMP/sudo.log" "dpkg -i" "DEB uses dpkg -i"
  assert_eq "$(grep -c 'dpkg -i' "$TMP/sudo.log")" 1 "DEB installs once"

  printf '0.1.0\n' >"$state"
  FAKE_CURL_DIR="$dir" FAKE_RPM_OWNER=opensst FAKE_PKG_STATE="$state" \
    FAKE_PKG_ASSET_VERSION=0.1.1 FAKE_RPM_ASSET_VERSION=0.1.1 \
    run_update update --yes
  assert_eq "$STATUS" 0 "RPM update succeeds"
  assert_file_contains "$TMP/sudo.log" "rpm -Uvh" "RPM uses rpm -Uvh"

  printf '0.1.0\n' >"$state"
  FAKE_CURL_DIR="$dir" FAKE_PACMAN_OWNER=opensst FAKE_PKG_STATE="$state" \
    FAKE_PKG_ASSET_VERSION=0.1.1-1 FAKE_PACMAN_ASSET_VERSION=0.1.1-1 \
    run_update update --yes
  assert_eq "$STATUS" 0 "pacman update succeeds"
  assert_file_contains "$TMP/sudo.log" "pacman -U --noconfirm" "pacman uses pacman -U"

  printf '0.1.0\n' >"$state"
  FAKE_CURL_DIR="$dir" FAKE_DPKG_OWNER=opensst FAKE_PKG_STATE="$state" \
    FAKE_PKG_ASSET_VERSION=0.1.1 FAKE_DPKG_ASSET_VERSION=0.1.1 FAKE_PKG_FAIL=1 \
    run_update update --yes
  assert_eq "$STATUS" 1 "package install failure is reported"
  assert_eq "$(cat "$state")" 0.1.0 "failed install does not change state"

  printf '0.1.0\n' >"$state"
  FAKE_CURL_DIR="$dir" FAKE_DPKG_OWNER=opensst FAKE_PKG_STATE="$state" \
    FAKE_PKG_ASSET_VERSION=0.1.0 FAKE_DPKG_ASSET_VERSION=0.1.1 \
    run_update update --yes
  assert_eq "$STATUS" 1 "post-install version mismatch fails"

  if (( EUID != 0 )); then
    (
      PATH=/nonexistent
      # shellcheck disable=SC1090
      source "$SST"
      _sst_run_privileged true
    ) >/dev/null 2>&1
    STATUS=$?
    assert_eq "$STATUS" 127 "missing sudo returns 127"
  else
    printf '# skip missing sudo test: running as root\n'
  fi
}

test_usage_errors() {
  run_capture "$SST"
  assert_eq "$STATUS" 2 "sst with no arguments exits 2"
  assert_contains "$ERROR" "sst open" "no-argument usage is written to stderr"

  run_capture "$SST" unknown
  assert_eq "$STATUS" 2 "unknown subcommand exits 2"
  assert_contains "$ERROR" "sst kill" "unknown-subcommand usage is written to stderr"
}

FAKEBIN="$ROOT/tests/fixtures/bin"
GLOG="$TMP/ssh-g.log"
CLOG="$TMP/ssh-connection.log"

run_sourced() {
  local func=$1
  shift
  : >"$TMP/stdout"
  : >"$TMP/stderr"
  : >"$GLOG"
  (
    PATH="$FAKEBIN:$PATH"
    export FAKE_SSH_G_LOG="$GLOG"
    if [[ -n ${TEST_LOCALE-} ]]; then
      export LC_ALL="$TEST_LOCALE"
    fi
    # shellcheck disable=SC1090
    source "$SST"
    "$func" "$@"
  ) >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  OUTPUT=$(<"$TMP/stdout")
  ERROR=$(<"$TMP/stderr")
}

test_project_names() {
  local name rc
  for name in Work project-x api_2 Work-tab1 A; do
    run_sourced _sst_valid_project "$name"
    assert_eq "$STATUS" 0 "project name '$name' is accepted"
  done
  for name in '' -bad .hidden 'Work;id' 'Work space' 'Work/other'; do
    run_sourced _sst_valid_project "$name"
    assert_eq "$STATUS" 1 "project name '$name' is rejected"
  done
  for name in 'Wörk' 'ｗｏｒｋ'; do
    TEST_LOCALE=en_US.UTF-8 run_sourced _sst_valid_project "$name"
    assert_eq "$STATUS" 1 "project name '$name' is rejected under a UTF-8 locale"
  done
  TEST_LOCALE=en_US.UTF-8 run_sourced _sst_valid_project Work
  assert_eq "$STATUS" 0 "ASCII project names stay valid under a UTF-8 locale"
}

test_ssh_validation_accepts() {
  run_sourced _sst_validate_ssh -p 2222 devbox
  assert_eq "$STATUS" 0 "separate -p value is accepted"
  assert_file_contains "$GLOG" "-p 2222 devbox" "ssh -G probe keeps separate -p value"

  run_sourced _sst_validate_ssh -p2222 devbox
  assert_eq "$STATUS" 0 "attached -p value is accepted"

  run_sourced _sst_validate_ssh -Jjump@example devbox
  assert_eq "$STATUS" 0 "attached -J value is accepted"

  run_sourced _sst_validate_ssh -J jump@example devbox
  assert_eq "$STATUS" 0 "separate -J value is accepted"

  run_sourced _sst_validate_ssh -oRemoteCommand=none devbox
  assert_eq "$STATUS" 0 "attached RemoteCommand=none is accepted"

  run_sourced _sst_validate_ssh -- devbox
  assert_eq "$STATUS" 0 "-- terminates options and leaves one destination"

  run_sourced _sst_validate_ssh -4p2222 devbox
  assert_eq "$STATUS" 0 "clustered flags with an attached value are accepted"

  run_sourced _sst_validate_ssh devbox
  assert_eq "$STATUS" 0 "default SSH configuration is accepted"
  assert_file_contains "$GLOG" "devbox true" \
    "ssh -G probe includes a command so sessiontype-specific RemoteCommand is evaluated"
}

test_ssh_validation_rejects() {
  run_sourced _sst_validate_ssh
  assert_eq "$STATUS" 1 "missing destination is rejected"

  run_sourced _sst_validate_ssh devbox extra
  assert_eq "$STATUS" 1 "positional remote command is rejected"

  run_sourced _sst_validate_ssh devbox -p
  assert_eq "$STATUS" 1 "missing option value is rejected"

  local flag
  for flag in -t -T -4t; do
    run_sourced _sst_validate_ssh "$flag" devbox
    assert_eq "$STATUS" 1 "user $flag is rejected because sst owns terminal allocation"
  done

  (
    PATH="$FAKEBIN:$PATH"
    export FAKE_SSH_G_LOG="$GLOG" FAKE_SSH_G_REMOTE_COMMAND='printf bad'
    # shellcheck disable=SC1090
    source "$SST"
    _sst_validate_ssh -o RemoteCommand='printf bad' devbox
  ) >/dev/null 2>&1
  STATUS=$?
  assert_eq "$STATUS" 1 "unsafe effective RemoteCommand is rejected"

  run_sourced _sst_validate_ssh devbox
  assert_eq "$STATUS" 0 "default RemoteCommand none is accepted"

  (
    PATH="$FAKEBIN:$PATH"
    export FAKE_SSH_G_LOG="$GLOG" FAKE_SSH_G_FAIL=1
    # shellcheck disable=SC1090
    source "$SST"
    _sst_validate_ssh devbox
  ) >/dev/null 2>&1
  STATUS=$?
  assert_eq "$STATUS" 1 "ssh -G failure is rejected"
}

run_sst_env() {
  local exit_code=$1 exec_remote=$2
  shift 2
  : >"$TMP/stdout"
  : >"$TMP/stderr"
  : >"$CLOG"
  : >"$GLOG"
  PATH="$FAKEBIN:$PATH" \
    FAKE_SSH_LOG="$CLOG" \
    FAKE_SSH_G_LOG="$GLOG" \
    FAKE_SSH_EXIT="$exit_code" \
    FAKE_SSH_EXEC_REMOTE="$exec_remote" \
    "$SST" "$@" >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  OUTPUT=$(<"$TMP/stdout")
  ERROR=$(<"$TMP/stderr")
}

run_sst() {
  run_sst_env 0 0 "$@"
}

connection_count() {
  if [[ -f $CLOG ]]; then
    wc -l <"$CLOG" | tr -d ' '
  else
    printf '0'
  fi
}

test_list_and_kill() {
  run_sst list -p 2222 devbox
  assert_eq "$STATUS" 0 "list succeeds"
  assert_file_contains "$CLOG" "-T -p 2222 devbox" "list uses ssh -T before host"
  assert_file_contains "$CLOG" "list-sessions" "list runs tmux list-sessions"
  assert_eq "$(connection_count)" 1 "list makes exactly one connection"

  run_sst kill -p 2222 devbox Work
  assert_eq "$STATUS" 0 "kill succeeds"
  assert_file_contains "$CLOG" "-T -p 2222 devbox" "kill uses ssh -T before host"
  assert_file_contains "$CLOG" "kill-session -t =Work" "kill targets the exact session name"
  assert_eq "$(connection_count)" 1 "kill makes exactly one connection"

  run_sst kill devbox 'Work;id'
  assert_eq "$STATUS" 2 "kill rejects an unsafe project name"
  assert_eq "$(connection_count)" 0 "rejected kill connects to nothing"

  run_sst kill devbox
  assert_eq "$STATUS" 2 "kill requires a distinct host and project"

  run_sst list
  assert_eq "$STATUS" 2 "list requires a host"

  run_sst list devbox extra
  assert_eq "$STATUS" 2 "list rejects a positional remote command"

  run_sst list -t devbox
  assert_eq "$STATUS" 2 "list rejects a user-requested PTY"
  assert_contains "$ERROR" "controls terminal allocation" "list explains the -t rejection"
  assert_eq "$(connection_count)" 0 "rejected list connects to nothing"

  run_sst kill -T devbox Work
  assert_eq "$STATUS" 2 "kill rejects a user-requested PTY"
  assert_eq "$(connection_count)" 0 "rejected kill connects to nothing"
}

test_management_never_retries() {
  run_sst_env 255 0 list devbox
  assert_eq "$STATUS" 255 "list returns ssh status 255 unchanged"
  assert_eq "$(connection_count)" 1 "list does not retry on 255"

  run_sst_env 255 0 kill devbox Work
  assert_eq "$STATUS" 255 "kill returns ssh status 255 unchanged"
  assert_eq "$(connection_count)" 1 "kill does not retry on 255"

  assert_eq "$OUTPUT" "" "management commands emit no terminal reset on stdout"
}

test_missing_remote_tmux() {
  run_sst_env 0 1 list devbox
  assert_eq "$STATUS" 127 "list returns 127 when remote tmux is missing"
  assert_contains "$ERROR" "install tmux" "list explains how to fix missing tmux"

  run_sst_env 0 1 kill devbox Work
  assert_eq "$STATUS" 127 "kill returns 127 when remote tmux is missing"
  assert_contains "$ERROR" "install tmux" "kill explains how to fix missing tmux"
}

test_missing_local_ssh() {
  : >"$TMP/stdout"
  : >"$TMP/stderr"
  env -i PATH=/nonexistent HOME="$TMP" /bin/bash "$SST" list devbox \
    >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  OUTPUT=$(<"$TMP/stdout")
  ERROR=$(<"$TMP/stderr")
  assert_eq "$STATUS" 127 "missing local ssh returns 127"
  assert_contains "$ERROR" "ssh" "missing local ssh is reported"
}

run_sst_tty() {
  local exit_code=$1 exec_remote=$2
  shift 2
  : >"$TMP/stdout"
  : >"$TMP/stderr"
  : >"$CLOG"
  : >"$GLOG"
  local cmd
  cmd=$(printf 'PATH=%q FAKE_SSH_LOG=%q FAKE_SSH_G_LOG=%q FAKE_SSH_EXIT=%q FAKE_SSH_EXEC_REMOTE=%q %q' \
    "$FAKEBIN:$PATH" "$CLOG" "$GLOG" "$exit_code" "$exec_remote" "$SST")
  local arg
  for arg in "$@"; do
    cmd+=$(printf ' %q' "$arg")
  done
  script -qec "$cmd" /dev/null >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  OUTPUT=$(<"$TMP/stdout")
  ERROR=$(<"$TMP/stderr")
}

test_open_requires_tty() {
  run_sst open devbox Work
  assert_eq "$STATUS" 2 "open without a terminal exits 2"
  assert_eq "$(connection_count)" 0 "open without a terminal connects to nothing"
}

test_open_operation() {
  if ! command -v script >/dev/null 2>&1; then
    printf '# skip open PTY tests: script(1) is unavailable\n'
    return
  fi

  run_sst_tty 0 0 open -p 2222 devbox Work
  assert_eq "$STATUS" 0 "open succeeds"
  assert_file_contains "$CLOG" "-t -p 2222 devbox" "open uses ssh -t before host"
  assert_file_contains "$CLOG" "new-session -A -D -s Work" "open creates or attaches the named session"
  assert_eq "$(connection_count)" 1 "open makes exactly one connection"
  assert_contains "$OUTPUT" "?1049l" "open disarms terminal modes on exit"

  run_sst_tty 0 0 open devbox 'Work;id'
  assert_eq "$STATUS" 2 "open rejects an unsafe project name"
  assert_eq "$(connection_count)" 0 "rejected open connects to nothing"

  run_sst_tty 0 0 open -T devbox Work
  assert_eq "$STATUS" 2 "open rejects a user-requested no-PTY option"
  assert_contains "$OUTPUT" "controls terminal allocation" "open explains the -T rejection"
  assert_eq "$(connection_count)" 0 "rejected open connects to nothing"

  run_sst_tty 0 1 open devbox Work
  assert_eq "$STATUS" 127 "open returns 127 when remote tmux is missing"
  assert_contains "$OUTPUT" "install tmux" "open explains how to fix missing tmux"

  run_sst_tty 255 0 open devbox Work
  assert_eq "$STATUS" 255 "a fast initial failure returns 255 without retrying"
  assert_eq "$(connection_count)" 1 "a fast initial failure makes one attempt"
}

test_open_reconnects() {
  local calls="$TMP/reconnect-calls" disarms="$TMP/disarms"
  : >"$calls"
  : >"$disarms"
  (
    # shellcheck disable=SC1090
    source "$SST"
    _sst_ssh() {
      local n
      n=$(wc -l <"$calls")
      printf '%s\n' "$*" >>"$calls"
      if (( n == 0 )); then
        SECONDS=$((SECONDS + 31))
        return 255
      fi
      return 0
    }
    _sst_disarm() { printf 'disarm\n' >>"$disarms"; }
    sleep() { :; }
    _sst_open_session -p 2222 devbox Work
  ) >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  ERROR=$(<"$TMP/stderr")

  assert_eq "$STATUS" 0 "a qualifying failure reconnects and returns success"
  assert_eq "$(connection_count_calls "$calls")" 2 "reconnect retries once"
  assert_eq "$(wc -l <"$disarms" | tr -d ' ')" 2 "terminal is disarmed after each attempt"
  assert_contains "$ERROR" "reconnect" "reconnect is announced on stderr"
  assert_ne "$(sed -n 1p "$calls")" "" "reconnect attempts are recorded"
  assert_eq "$(sed -n 1p "$calls")" "$(sed -n 2p "$calls")" \
    "reconnect reuses identical SSH arguments and project"

  : >"$calls"
  : >"$disarms"
  (
    # shellcheck disable=SC1090
    source "$SST"
    _sst_ssh() {
      local n
      n=$(wc -l <"$calls")
      printf '%s\n' "$*" >>"$calls"
      if (( n == 0 )); then
        SECONDS=$((SECONDS + 31))
        return 255
      fi
      return 1
    }
    _sst_disarm() { printf 'disarm\n' >>"$disarms"; }
    sleep() { :; }
    _sst_open_session devbox Work
  ) >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  assert_eq "$STATUS" 1 "a non-255 retry result ends reconnection"
  assert_eq "$(connection_count_calls "$calls")" 2 "non-255 ends reconnection after one retry"
}

# Execute the generated `open` remote command locally with a fake tmux and a
# fake infocmp. $1 is the TERM to simulate, $2 lists the terminfo entries the
# remote supports, $3 may be "without-infocmp", and $4 selects the shell.
run_remote_open() {
  local term=$1 supported=$2 mode=${3-} shell=${4-sh}
  local bindir="$TMP/remote-open-bin" log="$TMP/remote-open-tmux.log"
  : >"$TMP/stdout"
  : >"$TMP/stderr"
  : >"$log"
  (
    # shellcheck disable=SC1090
    source "$SST"
    remote=$(_sst_remote_command open Work)
    rm -rf "$bindir"
    mkdir -p "$bindir"
    cat >"$bindir/tmux" <<'EOF'
#!/bin/bash
printf 'TERM=%s\nargs=%s\n' "${TERM-}" "$*" >>"$FAKE_TMUX_LOG"
EOF
    chmod +x "$bindir/tmux"
    if [[ $mode != without-infocmp ]]; then
      cat >"$bindir/infocmp" <<'EOF'
#!/bin/bash
case " ${FAKE_INFOCMP_SUPPORTED-} " in
  *" $1 "*) exit 0 ;;
esac
exit 1
EOF
      chmod +x "$bindir/infocmp"
    fi
    # Only the fake tools are on PATH, so a missing fake infocmp really means
    # no infocmp, regardless of what the host has installed.
    shell=$(command -v "$shell")
    PATH="$bindir" TERM="$term" \
      FAKE_INFOCMP_SUPPORTED="$supported" FAKE_TMUX_LOG="$log" \
      "$shell" -c "$remote"
  ) >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  OUTPUT=$(<"$TMP/stdout")
  ERROR=$(<"$TMP/stderr")
}

test_open_term_fallback() {
  local log="$TMP/remote-open-tmux.log"

  run_remote_open xterm-ghostty 'xterm-ghostty xterm-256color'
  assert_eq "$STATUS" 0 "open succeeds when the remote supports TERM"
  assert_file_contains "$log" "TERM=xterm-ghostty" \
    "a supported TERM is preserved"
  assert_file_contains "$log" "args=new-session -A -D -s Work" \
    "open still creates or attaches the named session"
  assert_not_contains "$ERROR" "unsupported" \
    "a supported TERM produces no fallback notice"

  run_remote_open xterm-ghostty 'xterm-256color xterm'
  assert_eq "$STATUS" 0 "open succeeds with an unsupported TERM"
  assert_file_contains "$log" "TERM=xterm-256color" \
    "an unsupported TERM falls back to xterm-256color"
  assert_contains "$ERROR" "xterm-ghostty" "the notice names the original TERM"
  assert_contains "$ERROR" "using xterm-256color" "the notice names the fallback"

  run_remote_open xterm-ghostty 'vt100'
  assert_file_contains "$log" "TERM=vt100" \
    "the fallback chain reaches the last usable candidate"

  run_remote_open xterm-ghostty ''
  assert_file_contains "$log" "TERM=xterm-ghostty" \
    "with no usable candidate the original TERM is preserved"
  assert_not_contains "$ERROR" "using" \
    "no fallback is announced when none was applied"

  run_remote_open xterm-ghostty 'xterm-256color' without-infocmp
  assert_file_contains "$log" "TERM=xterm-ghostty" \
    "without infocmp the original TERM is preserved"
  assert_not_contains "$ERROR" "using" \
    "without infocmp no fallback is announced"

  if command -v dash >/dev/null 2>&1; then
    run_remote_open xterm-ghostty 'xterm-256color' '' dash
    assert_eq "$STATUS" 0 "the remote command runs under POSIX dash"
    assert_file_contains "$log" "TERM=xterm-256color" \
      "the fallback also works under dash"
  else
    printf '# skip dash test: dash is unavailable\n'
  fi

  run_sourced _sst_remote_command list
  assert_not_contains "$OUTPUT" "infocmp" "list does not probe remote terminfo"
  run_sourced _sst_remote_command kill Work
  assert_not_contains "$OUTPUT" "infocmp" "kill does not probe remote terminfo"
}

test_source_install() {
  local user="$TMP/user" root="$TMP/root" nosudo="$TMP/nosudo"
  rm -rf "$user" "$root" "$nosudo"
  mkdir -p "$nosudo"
  printf '#!/bin/sh\nexit 99\n' >"$nosudo/sudo"
  chmod +x "$nosudo/sudo"

  PATH="$nosudo:$PATH" make -s -C "$ROOT" install PREFIX="$user" \
    >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  assert_eq "$STATUS" 0 "make install into a user prefix succeeds without sudo"
  assert_executable "$user/bin/sst" "make install installs an executable"

  run_capture "$user/bin/sst" --help
  assert_eq "$STATUS" 0 "the installed command runs"
  assert_contains "$OUTPUT" "sst open" "the installed command prints usage"

  make -s -C "$ROOT" install PREFIX=/usr/local DESTDIR="$root" \
    >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  assert_eq "$STATUS" 0 "make install honors DESTDIR"
  assert_executable "$root/usr/local/bin/sst" "DESTDIR install uses /usr/local/bin"

  make -s -C "$ROOT" uninstall PREFIX=/usr/local DESTDIR="$root" \
    >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  assert_eq "$STATUS" 0 "make uninstall succeeds"
  assert_absent "$root/usr/local/bin/sst" "make uninstall removes the executable"

  make -s -C "$ROOT" uninstall PREFIX="$user" \
    >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  assert_eq "$STATUS" 0 "make uninstall works with a user prefix"
  assert_absent "$user/bin/sst" "user-prefix uninstall removes the executable"
}

test_package_version_validation() {
  "$ROOT/packaging/build-deb.sh" 1.0 "$TMP" >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  assert_eq "$STATUS" 2 "deb build rejects a non-semver version"

  "$ROOT/packaging/build-rpm.sh" v1.0.0 "$TMP" >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  assert_eq "$STATUS" 2 "rpm build rejects a version with a tag prefix"

  "$ROOT/packaging/build-deb.sh" 9.9.9 "$TMP" >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  assert_eq "$STATUS" 2 "deb build rejects a version that differs from SST_VERSION"

  "$ROOT/packaging/build-rpm.sh" 9.9.9 "$TMP" >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  assert_eq "$STATUS" 2 "rpm build rejects a version that differs from SST_VERSION"

  "$ROOT/packaging/build-arch.sh" 9.9.9 "$TMP" >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  assert_eq "$STATUS" 2 "arch build rejects a version that differs from SST_VERSION"

  assert_file_contains "$ROOT/packaging/build-deb.sh" "Depends: bash, openssh-client, curl" \
    "deb metadata depends on curl"
  assert_file_contains "$ROOT/packaging/build-rpm.sh" "Requires: curl" \
    "rpm metadata requires curl"
}

test_arch_package() {
  if ! command -v makepkg >/dev/null 2>&1 || ! command -v bsdtar >/dev/null 2>&1 \
    || (( EUID == 0 )); then
    printf '# skip arch package test: makepkg/bsdtar is unavailable or running as root\n'
    return
  fi
  local out="$TMP/arch"
  mkdir -p "$out"
  "$ROOT/packaging/build-arch.sh" 0.2.1 "$out" >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  assert_eq "$STATUS" 0 "arch package build succeeds"
  local pkg="$out/opensst-0.2.1-1-any.pkg.tar.zst"
  assert_file "$pkg" "arch package has the expected filename"
  assert_contains "$(bsdtar -xOf "$pkg" .PKGINFO)" "pkgname = opensst" \
    "arch PKGINFO names opensst"
  assert_contains "$(bsdtar -xOf "$pkg" .PKGINFO)" "pkgver = 0.2.1-1" \
    "arch PKGINFO records version"
  assert_contains "$(bsdtar -tf "$pkg")" "usr/bin/sst" \
    "arch package installs /usr/bin/sst"
}

test_release_assets() {
  local dist="$TMP/release-assets"
  mkdir -p "$dist"
  cp "$SST" "$dist/sst"
  chmod +x "$dist/sst"
  cp "$INSTALL" "$dist/install.sh"
  chmod +x "$dist/install.sh"
  printf 'deb\n' >"$dist/opensst_0.2.1_all.deb"
  printf 'rpm\n' >"$dist/opensst-0.2.1-1.noarch.rpm"
  printf 'arch\n' >"$dist/opensst-0.2.1-1-any.pkg.tar.zst"

  "$ROOT/packaging/release-assets.sh" 0.2.1 "$dist" >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  assert_eq "$STATUS" 0 "release assets script succeeds"
  local file
  for file in opensst.deb opensst.rpm opensst.pkg.tar.zst SHA256SUMS; do
    assert_file "$dist/$file" "release assets creates $file"
  done
  assert_file "$dist/install.sh" "release assets keeps install.sh"
  assert_file_contains "$dist/SHA256SUMS" "opensst.deb" \
    "checksums include stable DEB alias"
  assert_file_contains "$dist/SHA256SUMS" "opensst.pkg.tar.zst" \
    "checksums include stable Arch alias"
  assert_file_contains "$dist/SHA256SUMS" "  sst" \
    "checksums include the raw source asset"
  assert_file_contains "$dist/SHA256SUMS" "  install.sh" \
    "checksums include install.sh"
  assert_file_contains "$dist/SHA256SUMS" "opensst_0.2.1_all.deb" \
    "checksums include the versioned DEB"

  rm -f "$dist/install.sh"
  "$ROOT/packaging/release-assets.sh" 0.2.1 "$dist" >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  assert_eq "$STATUS" 1 "release assets refuses a missing install.sh"
  cp "$INSTALL" "$dist/install.sh"
  chmod +x "$dist/install.sh"

  printf "#!/bin/bash\nSST_VERSION='9.9.9'\n" >"$dist/sst"
  chmod +x "$dist/sst"
  "$ROOT/packaging/release-assets.sh" 0.2.1 "$dist" >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  assert_eq "$STATUS" 1 "release assets refuses a raw script with the wrong version"

  rm -f "$dist/opensst.rpm"
  "$ROOT/packaging/release-assets.sh" 0.2.1 "$dist" >"$TMP/stdout" 2>"$TMP/stderr"
  STATUS=$?
  assert_eq "$STATUS" 1 "release assets refuses a missing versioned package"
}

test_packages() {
  if command -v dpkg-deb >/dev/null 2>&1; then
    local debdir="$TMP/deb"
    rm -rf "$debdir"
    mkdir -p "$debdir"
    "$ROOT/packaging/build-deb.sh" 0.2.1 "$debdir" >"$TMP/stdout" 2>"$TMP/stderr"
    STATUS=$?
    assert_eq "$STATUS" 0 "deb build succeeds"
    local deb="$debdir/opensst_0.2.1_all.deb"
    assert_file "$deb" "deb build creates the expected filename"
    assert_eq "$(dpkg-deb -f "$deb" Package)" opensst "deb package is named opensst"
    assert_eq "$(dpkg-deb -f "$deb" Version)" 0.2.1 "deb version matches"
    assert_eq "$(dpkg-deb -f "$deb" Architecture)" all "deb is architecture-independent"
    assert_contains "$(dpkg-deb -f "$deb" Depends)" "openssh-client" "deb depends on the OpenSSH client"
    if dpkg-deb -c "$deb" | grep -Fq './usr/bin/sst'; then
      pass "deb installs /usr/bin/sst"
    else
      fail "deb installs /usr/bin/sst"
    fi
  else
    printf '# skip deb package test: dpkg-deb is unavailable\n'
  fi

  if command -v rpmbuild >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1; then
    local rpmdir="$TMP/rpm"
    rm -rf "$rpmdir"
    mkdir -p "$rpmdir"
    "$ROOT/packaging/build-rpm.sh" 0.2.1 "$rpmdir" >"$TMP/stdout" 2>"$TMP/stderr"
    STATUS=$?
    assert_eq "$STATUS" 0 "rpm build succeeds"
    local rpm_file="$rpmdir/opensst-0.2.1-1.noarch.rpm"
    assert_file "$rpm_file" "rpm build creates the expected filename"
    assert_eq "$(rpm -qp --qf '%{NAME}' "$rpm_file")" opensst "rpm package is named opensst"
    assert_eq "$(rpm -qp --qf '%{ARCH}' "$rpm_file")" noarch "rpm is architecture-independent"
    if rpm -qlp "$rpm_file" | grep -Fq '/usr/bin/sst'; then
      pass "rpm installs /usr/bin/sst"
    else
      fail "rpm installs /usr/bin/sst"
    fi
  else
    printf '# skip rpm package test: rpmbuild is unavailable\n'
  fi
}

connection_count_calls() {
  if [[ -f $1 ]]; then
    wc -l <"$1" | tr -d ' '
  else
    printf '0'
  fi
}

test_release_workflow() {
  local release="$ROOT/.github/workflows/release.yml"

  assert_file_contains "$release" "workflow_dispatch" "release is manual only"
  assert_file_contains "$release" 'git config user.name' "release configures a Git committer name"
  assert_file_contains "$release" 'git config user.email' "release configures a Git committer email"
  assert_file_order "$release" 'git config user.email' 'git tag -a' \
    "release configures Git identity before creating the annotated tag"
  assert_file_contains "$release" 'git cat-file -t' "release requires the existing tag to be annotated"
  assert_file_contains "$release" '--verify-tag' "release verifies the tag before publishing"
  assert_file_contains "$release" 'SHA256SUMS' "release publishes checksums"
  assert_file_contains "$release" "SST_VERSION" "release validates the embedded version"
  assert_file_contains "$release" "package-arch" "release builds an Arch package"
  assert_file_contains "$release" "archlinux:latest" "Arch build uses an Arch container"
  assert_file_contains "$release" "release-assets.sh" "release creates stable asset aliases"
  assert_file_contains "$release" "opensst.pkg.tar.zst" "release publishes the stable Arch alias"
  assert_file_contains "$release" "cp install.sh dist/install.sh" \
    "release stages install.sh"
  assert_file_contains "$release" "dist/install.sh" "release publishes install.sh"
}

test_ci_workflow() {
  local ci="$ROOT/.github/workflows/ci.yml"
  assert_file_contains "$ci" "SST_VERSION" "CI reads the embedded version"
  assert_file_contains "$ci" "package-arch" "CI builds an Arch package"
  assert_file_contains "$ci" "archlinux:latest" "CI uses an Arch container"
  assert_file_contains "$ci" "pacman -U" "CI smoke-tests the Arch package"
  assert_file_contains "$ROOT/Makefile" "bash -n install.sh" \
    "make check syntax-checks install.sh"
}

test_help
test_version
test_version_helpers
test_update_detection
test_update_version_readers
test_update_download
test_update_check
test_update_source
test_update_interaction
test_update_packages
test_install_script
test_usage_errors
test_project_names
test_ssh_validation_accepts
test_ssh_validation_rejects
test_list_and_kill
test_management_never_retries
test_missing_remote_tmux
test_missing_local_ssh
test_open_requires_tty
test_open_operation
test_open_reconnects
test_open_term_fallback
test_source_install
test_package_version_validation
test_packages
test_arch_package
test_release_assets
test_release_workflow
test_ci_workflow

test_documentation() {
  local readme="$ROOT/README.md" agents="$ROOT/AGENTS.md" license="$ROOT/LICENSE"
  local needle
  for needle in \
    'sst open [ssh options] <host> <project>' \
    'sst list [ssh options] <host>' \
    'sst kill [ssh options] <host> <project>' \
    '/usr/local/bin' \
    '/usr/bin/sst' \
    'releases/latest/download/install.sh' \
    'bash -s -- --version 0.2.1' \
    '30 seconds' \
    '2 seconds' \
    'Serverless SST' \
    'new-session -A -D' \
    '-t/-T are rejected' \
    'sst update' \
    'sst update --check' \
    'opensst.pkg.tar.zst' \
    'pacman -U' \
    'curl or wget' \
    'missing or unsuitable terminal' \
    'checksums are not signatures'; do
    assert_file_contains "$readme" "$needle" "README documents '$needle'"
  done

  for needle in 'Release' 'Version History' 'explicit' 'workflow_dispatch' \
    'make check' '0.2.1' 'install.sh' 'sst update' 'SST_VERSION' 'pacman' \
    'stable aliases'; do
    assert_file_contains "$agents" "$needle" "AGENTS documents '$needle'"
  done

  for needle in 'MIT License' '2026' 'duanhongyi'; do
    assert_file_contains "$license" "$needle" "LICENSE contains '$needle'"
  done
}

test_documentation

printf '\n%d tests, %d failures\n' "$tests" "$failures"
(( failures == 0 ))
