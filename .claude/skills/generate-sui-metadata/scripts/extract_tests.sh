#!/usr/bin/env bash
# Deterministic extraction of test function names + their expected-failure
# abort codes from a Sui Move tests file.
#
# Usage:
#   extract_tests.sh <path-to-tests.move>
#
# Emits one line per test:
#   TEST|<test_function_name>|<expected_abort_code_or_empty>
#
# Convention:
#   #[expected_failure(abort_code = <CODE>)]
#   fun test_xxx() { ... }
# is captured as TEST|test_xxx|<CODE>
# A bare `#[test]` test (no expected_failure) emits TEST|test_xxx|

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <path-to-tests.move>" >&2
  exit 1
fi

SRC="$1"
if [ ! -f "$SRC" ]; then
  echo "error: file not found: $SRC" >&2
  exit 1
fi

awk '
  # Track whether we are in a test annotation chain. Any `#[test]` (with
  # or without companions) marks the next `fun` as a test. The fn name is
  # NOT required to start with `test_` — Move teams use varied naming.
  /#\[[[:space:]]*test[[:space:]]*\]/ { in_test = 1; next }
  /#\[[[:space:]]*test[[:space:]]*,/   { in_test = 1 }
  /expected_failure[[:space:]]*\([[:space:]]*abort_code[[:space:]]*=/ {
    abort = $0
    sub(/^.*abort_code[[:space:]]*=[[:space:]]*/, "", abort)
    sub(/[[:space:]]*\)[[:space:]]*\].*$/, "", abort)
    sub(/[[:space:]]*\)[[:space:]]*,.*$/, "", abort)
    sub(/,.*$/, "", abort)
    sub(/^.*::/, "", abort)
    pending_abort = abort
    in_test = 1
    next
  }
  # Match any function declaration that is currently in a test chain.
  # Allow optional indentation and a `public ` prefix (some teams write
  # `public fun test_*`).
  in_test && /^[[:space:]]*(public[[:space:]]+)?fun[[:space:]]+[A-Za-z_]/ {
    name = $0
    sub(/^[[:space:]]*(public[[:space:]]+)?fun[[:space:]]+/, "", name)
    sub(/[(<].*$/, "", name)
    print "TEST|" name "|" pending_abort
    pending_abort = ""
    in_test = 0
  }
  # Reset both flags on a blank line.
  /^[[:space:]]*$/ { pending_abort = ""; in_test = 0 }
' "$SRC"
