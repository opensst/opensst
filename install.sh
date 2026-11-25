#!/usr/bin/env bash
# Install opensst from GitHub Releases.
#
# The script is self-contained so it can be run as:
#   curl -fsSL https://github.com/opensst/opensst/releases/latest/download/install.sh | bash
set -u

SST_RELEASES='https://github.com/opensst/opensst/releases'
VERSION=''
PREFIX='/usr/local'
PREFIX_SET=0
TMPDIR_INSTALL=''
USE_SUDO=0

usage() {
  printf '%s\n' \
    'Usage: install.sh [--version X.Y.Z] [--prefix DIR]' \
    '' \
    'Install opensst from GitHub Releases.' \
    '' \
    'Without --version, the latest release is installed. With --version, that exact' \
    'stable release is installed instead.' \
    '' \
    'The installer detects pacman, apt-get/dpkg, or dnf/yum/rpm and installs the' \
    'matching package. On other systems it installs the raw sst executable. The' \
    'package manager path installs under /usr/bin; the source path installs under' \
    'DIR/bin (default /usr/local/bin).' \
    '' \
    '--prefix DIR only applies to the source fallback.' \
    '' \
    'Examples:' \
    '  curl -fsSL https://github.com/opensst/opensst/releases/latest/download/install.sh | bash' \
    '  curl -fsSL https://github.com/opensst/opensst/releases/latest/download/install.sh | bash -s -- --version 0.2.0'
}

error() {
  printf 'install.sh: %s\n' "$*" >&2
}

usage_error() {
  error "$*"
  printf 'usage: install.sh [--version X.Y.Z] [--prefix DIR]\n' >&2
  exit 2
}

cleanup() {
  if [[ -n $TMPDIR_INSTALL && -d $TMPDIR_INSTALL ]]; then
    rm -rf -- "$TMPDIR_INSTALL"
  fi
}

trap cleanup EXIT INT TERM

while (( $# > 0 )); do
  case $1 in
    -h|--help)
      usage
      exit 0
      ;;
    --version)
      if (( $# < 2 )); then
        usage_error '--version requires a value'
      fi
      VERSION=$2
      shift 2
      ;;
    --version=*)
      VERSION=${1#*=}
      shift
      ;;
    --prefix)
      if (( $# < 2 )); then
        usage_error '--prefix requires a value'
      fi
      PREFIX=$2
      PREFIX_SET=1
      shift 2
      ;;
    --prefix=*)
      PREFIX=${1#*=}
      PREFIX_SET=1
      shift
      ;;
    *)
      usage_error "unknown option: $1"
      ;;
  esac
done

if [[ -n $VERSION && ! $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  usage_error '--version must be MAJOR.MINOR.PATCH without a v prefix'
fi

if [[ $PREFIX != /* ]]; then
  usage_error '--prefix must be an absolute path'
fi
PREFIX=${PREFIX%/}
if [[ -z $PREFIX ]]; then
  PREFIX='/'
fi

detect_method() {
  if command -v pacman >/dev/null 2>&1; then
    printf 'pacman\n'
  elif command -v apt-get >/dev/null 2>&1; then
    printf 'deb\n'
  elif command -v dpkg >/dev/null 2>&1; then
    printf 'deb\n'
  elif command -v dnf >/dev/null 2>&1; then
    printf 'rpm\n'
  elif command -v yum >/dev/null 2>&1; then
    printf 'rpm\n'
  elif command -v rpm >/dev/null 2>&1; then
    printf 'rpm\n'
  else
    printf 'source\n'
  fi
}

asset_for() {
  local method=$1
  if [[ -n $VERSION ]]; then
    case $method in
      pacman) printf 'opensst-%s-1-any.pkg.tar.zst\n' "$VERSION" ;;
      deb) printf 'opensst_%s_all.deb\n' "$VERSION" ;;
      rpm) printf 'opensst-%s-1.noarch.rpm\n' "$VERSION" ;;
      source) printf 'sst\n' ;;
    esac
  else
    case $method in
      pacman) printf 'opensst.pkg.tar.zst\n' ;;
      deb) printf 'opensst.deb\n' ;;
      rpm) printf 'opensst.rpm\n' ;;
      source) printf 'sst\n' ;;
    esac
  fi
}

base_url() {
  if [[ -n $VERSION ]]; then
    printf '%s/download/v%s\n' "$SST_RELEASES" "$VERSION"
  else
    printf '%s/latest/download\n' "$SST_RELEASES"
  fi
}

require_tools() {
  local method=$1
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    error 'curl or wget is required to download opensst'
    return 127
  fi
  if ! command -v sha256sum >/dev/null 2>&1; then
    error 'sha256sum is required to verify opensst'
    return 127
  fi
  if [[ $method != source ]] && (( EUID != 0 )) &&
    ! command -v sudo >/dev/null 2>&1; then
    error 'sudo is required to install a system package'
    return 127
  fi
  return 0
}

download() {
  local url=$1 dest=$2
  if command -v curl >/dev/null 2>&1; then
    if curl --proto '=https' --proto-redir '=https' --fail --silent --show-error \
      --location --retry 2 --connect-timeout 10 --max-time 120 -o "$dest" "$url"; then
      return 0
    fi
    error "failed to download $url"
    return 1
  fi
  if command -v wget >/dev/null 2>&1; then
    if wget -q --https-only --tries=2 --timeout=120 -O "$dest" "$url"; then
      return 0
    fi
    error "failed to download $url"
    return 1
  fi
  error 'curl or wget is required to download opensst'
  return 127
}

verify_sha256() {
  local file=$1 sums=$2 name=$3 line expected='' digest count=0
  if [[ ! -f $file || ! -f $sums ]]; then
    error 'downloaded asset or checksum file is missing'
    return 1
  fi
  while IFS= read -r line; do
    if [[ $line =~ ^([0-9a-fA-F]{64})[[:space:]]+\*?(.+)$ ]]; then
      if [[ ${BASH_REMATCH[2]} == "$name" ]]; then
        expected=${BASH_REMATCH[1]}
        count=$((count + 1))
      fi
    fi
  done <"$sums"
  if (( count == 0 )); then
    error "SHA256SUMS has no entry for $name"
    return 1
  fi
  if (( count > 1 )); then
    error "SHA256SUMS has multiple entries for $name"
    return 1
  fi
  read -r digest _ < <(sha256sum "$file") || return 1
  if [[ ${digest,,} != "${expected,,}" ]]; then
    error "checksum mismatch for $name"
    return 1
  fi
  return 0
}

priv() {
  if (( USE_SUDO == 1 )); then
    sudo "$@"
  else
    "$@"
  fi
}

dir_is_writable() {
  local dir=$1
  while [[ ! -e $dir ]]; do
    dir=$(dirname -- "$dir")
  done
  [[ -w $dir ]]
}

install_source() {
  local asset=$1
  local bindir target tmpfile backup reported rc
  bindir="$PREFIX/bin"
  target="$bindir/sst"
  tmpfile="$bindir/.sst-new.$$"
  backup=''
  reported=''
  rc=0

  if (( EUID != 0 )) && ! dir_is_writable "$bindir"; then
    USE_SUDO=1
  fi

  if ! priv mkdir -p -- "$bindir"; then
    error "unable to create $bindir"
    return 1
  fi

  if [[ -e $target ]]; then
    backup="$target.sst-backup.$$"
    if ! priv cp -p -- "$target" "$backup"; then
      error "unable to back up $target"
      return 1
    fi
  fi

  if ! priv install -m 755 -- "$asset" "$tmpfile"; then
    error "unable to stage the new executable in $bindir"
    priv rm -f -- "$tmpfile" "$backup" 2>/dev/null || true
    return 1
  fi
  if ! priv mv -f -- "$tmpfile" "$target"; then
    error "unable to replace $target"
    priv rm -f -- "$tmpfile" "$backup" 2>/dev/null || true
    return 1
  fi

  reported=$("$target" --version 2>/dev/null) || reported=''
  if [[ -n $VERSION ]]; then
    [[ $reported == "sst $VERSION" ]] || rc=1
  else
    [[ $reported =~ ^sst\ [0-9]+\.[0-9]+\.[0-9]+$ ]] || rc=1
  fi
  if (( rc != 0 )); then
    if [[ -n $backup ]]; then
      priv mv -f -- "$backup" "$target" 2>/dev/null || true
    else
      priv rm -f -- "$target" 2>/dev/null || true
    fi
    error "the installed sst failed its version check (reported '${reported:-nothing}')"
    return 1
  fi

  if [[ -n $backup ]]; then
    priv rm -f -- "$backup" 2>/dev/null || true
  fi
  printf 'install.sh: installed %s at %s\n' "$reported" "$target"
  return 0
}

apply_package() {
  local method=$1 file=$2
  case $method in
    pacman)
      priv pacman -U --noconfirm "$file"
      ;;
    deb)
      if command -v apt-get >/dev/null 2>&1; then
        priv apt-get install -y "$file"
      else
        priv dpkg -i "$file"
      fi
      ;;
    rpm)
      if command -v dnf >/dev/null 2>&1; then
        priv dnf install -y "$file"
      elif command -v yum >/dev/null 2>&1; then
        priv yum localinstall -y "$file"
      else
        priv rpm -Uvh "$file"
      fi
      ;;
  esac
}

verify_package() {
  local reported=''
  if command -v sst >/dev/null 2>&1; then
    reported=$(sst --version 2>/dev/null) || reported=''
  fi
  if [[ -n $VERSION ]]; then
    [[ $reported == "sst $VERSION" ]]
    return
  fi
  [[ $reported =~ ^sst\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
}

method=$(detect_method)
if [[ $method != source && $PREFIX_SET -eq 1 ]]; then
  usage_error '--prefix only applies to the source fallback'
fi

require_tools "$method" || exit $?

if (( EUID != 0 )) && [[ $method == source ]] &&
  ! dir_is_writable "$PREFIX/bin" && ! command -v sudo >/dev/null 2>&1; then
  error "sudo is required to install under $PREFIX/bin"
  exit 127
fi

if (( EUID != 0 )) && [[ $method != source ]]; then
  USE_SUDO=1
fi

base=$(base_url)
asset=$(asset_for "$method")
TMPDIR_INSTALL=$(mktemp -d) || {
  error 'unable to create a temporary directory'
  exit 1
}

printf 'install.sh: detected %s; installing %s\n' "$method" "$asset"
download "$base/$asset" "$TMPDIR_INSTALL/$asset" || exit $?
download "$base/SHA256SUMS" "$TMPDIR_INSTALL/SHA256SUMS" || exit $?
verify_sha256 "$TMPDIR_INSTALL/$asset" "$TMPDIR_INSTALL/SHA256SUMS" "$asset" || exit $?

if [[ $method == source ]]; then
  install_source "$TMPDIR_INSTALL/$asset" || exit 1
else
  if ! apply_package "$method" "$TMPDIR_INSTALL/$asset"; then
    error "$method failed to install $asset"
    exit 1
  fi
  if ! verify_package; then
    error "the installed sst failed its version check"
    exit 1
  fi
  printf 'install.sh: installed %s\n' "$(sst --version 2>/dev/null)"
fi