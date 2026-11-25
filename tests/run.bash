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

test_help
test_usage_errors
test_project_names
test_ssh_validation_accepts
test_ssh_validation_rejects

printf '\n%d tests, %d failures\n' "$tests" "$failures"
(( failures == 0 ))
