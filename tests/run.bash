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

  run_capture "$SST" -h
  assert_eq "$STATUS" 0 "sst -h exits 0"
  assert_contains "$OUTPUT" "sst open" "-h prints the same usage"
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
}

test_ssh_validation_rejects() {
  run_sourced _sst_validate_ssh
  assert_eq "$STATUS" 1 "missing destination is rejected"

  run_sourced _sst_validate_ssh devbox extra
  assert_eq "$STATUS" 1 "positional remote command is rejected"

  run_sourced _sst_validate_ssh devbox -p
  assert_eq "$STATUS" 1 "missing option value is rejected"

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
}

test_packages() {
  if command -v dpkg-deb >/dev/null 2>&1; then
    local debdir="$TMP/deb"
    rm -rf "$debdir"
    mkdir -p "$debdir"
    "$ROOT/packaging/build-deb.sh" 0.1.0 "$debdir" >"$TMP/stdout" 2>"$TMP/stderr"
    STATUS=$?
    assert_eq "$STATUS" 0 "deb build succeeds"
    local deb="$debdir/opensst_0.1.0_all.deb"
    assert_file "$deb" "deb build creates the expected filename"
    assert_eq "$(dpkg-deb -f "$deb" Package)" opensst "deb package is named opensst"
    assert_eq "$(dpkg-deb -f "$deb" Version)" 0.1.0 "deb version matches"
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
    "$ROOT/packaging/build-rpm.sh" 0.1.0 "$rpmdir" >"$TMP/stdout" 2>"$TMP/stderr"
    STATUS=$?
    assert_eq "$STATUS" 0 "rpm build succeeds"
    local rpm_file="$rpmdir/opensst-0.1.0-1.noarch.rpm"
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

test_help
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
test_source_install
test_package_version_validation
test_packages

printf '\n%d tests, %d failures\n' "$tests" "$failures"
(( failures == 0 ))
