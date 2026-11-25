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

test_help
test_usage_errors

printf '\n%d tests, %d failures\n' "$tests" "$failures"
(( failures == 0 ))
