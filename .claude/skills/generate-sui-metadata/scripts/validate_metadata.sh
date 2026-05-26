#!/usr/bin/env bash
# Cross-reference validation for a generated metadata YAML.
#
# Usage:
#   validate_metadata.sh <metadata.yaml> <move-source.move> <tests-source.move>
#
# Checks (each emits OK| or WARN| or ERR| lines):
#   - Every examples[].test_function exists in tests file
#   - Every invariants[].fails_with appears in api.errors
#   - Every error name referenced in invariants exists in extracted errors
#   - Every api.entry_points name exists in source as `public fun <name>`
#
# Exits 0 even on warnings — caller decides severity. Exits nonzero only
# on usage errors.

set -euo pipefail

if [ $# -lt 3 ]; then
  echo "usage: $0 <metadata.yaml> <move-source.move> <tests-source.move>" >&2
  exit 2
fi

META="$1"
SRC="$2"
TESTS="$3"

for f in "$META" "$SRC" "$TESTS"; do
  [ -f "$f" ] || { echo "error: file not found: $f" >&2; exit 2; }
done

# --- Build expected sets ---
# Use the same canonical test extractor the skill uses, so we accept any
# `#[test]`-annotated function regardless of naming convention.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DECLARED=$(bash "$SCRIPT_DIR/extract_tests.sh" "$TESTS" 2>/dev/null \
  | awk -F'|' '{print $2}' | sort -u)
ERRORS_DECLARED=$(grep -E '^const E[A-Za-z0-9_]+:' "$SRC" 2>/dev/null | sed -E 's/^const (E[A-Za-z0-9_]+):.*/\1/' | sort -u || true)
FUNS_DECLARED=$(grep -E '^public fun ' "$SRC" 2>/dev/null | sed -E 's/^public fun ([A-Za-z0-9_]+).*/\1/' | sort -u || true)
EVENTS_DECLARED=$(grep -E '^public struct [A-Z][A-Za-z0-9_]*(<[^>]*>)?[[:space:]]+has copy, drop' "$SRC" 2>/dev/null \
  | sed -E 's/^public struct ([A-Z][A-Za-z0-9_]*).*/\1/' | sort -u || true)

# --- Extract references from metadata ---
# Handle v1 inline flow (`{ id: foo, test_function: name, ... }`),
# v1 block (`test_function: name` on its own line),
# AND v2 plural lists (`test_functions: [a, b, c]` or block-list under
# `_audit_grounding.precondition_proofs[*].test_functions:`).
META_TEST_FNS=$(
  {
    # v1 singular `test_function: NAME` anywhere
    grep -oE 'test_function:[[:space:]]*[A-Za-z0-9_]+' "$META" 2>/dev/null \
      | sed -E 's/^test_function:[[:space:]]*//' || true
    # v2 inline plural `test_functions: [a, b, c]`
    grep -oE 'test_functions:[[:space:]]*\[[^]]*\]' "$META" 2>/dev/null \
      | sed -E 's/^test_functions:[[:space:]]*\[//; s/\]$//' \
      | tr ',' '\n' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' || true
    # v2 block-list:  `- test_name` under a previous `test_functions:`
    awk '
      /^[[:space:]]*test_functions:[[:space:]]*$/ { in_list = 1; next }
      in_list && /^[[:space:]]*-[[:space:]]*[A-Za-z0-9_]+[[:space:]]*$/ {
        gsub(/^[[:space:]]*-[[:space:]]*|[[:space:]]+$/, "", $0)
        print
        next
      }
      in_list && /^[[:space:]]*-/ { in_list = 0 }
      /^[^[:space:]-]/ { in_list = 0 }
    ' "$META"
  } | sort -u | grep -v '^$' || true
)
# v1 invariants[].fails_with and v2 preconditions[].fails_with — same shape.
META_FAILS_WITH=$(
  {
    grep -oE 'fails_with:[[:space:]]*[A-Za-z0-9_]+' "$META" 2>/dev/null \
      | sed -E 's/^fails_with:[[:space:]]*//' || true
    grep -oE 'precondition_fails_with:[[:space:]]*[A-Za-z0-9_]+' "$META" 2>/dev/null \
      | sed -E 's/^precondition_fails_with:[[:space:]]*//' || true
  } | sort -u
)
# api.entry_points names: v1 inline `{ name: X, kind: Y }` OR v2 block-list
# `- name: X` followed by `sig:` (entry point) — kind in v2 is replaced by
# role/sig but the `name:` field is still present at the top of each api entry.
META_ENTRY_POINTS=$(
  {
    # v1 inline form
    grep -E '^\s*-\s*\{\s*name:.*kind:' "$META" 2>/dev/null | sed -E 's/^.*name:\s*([A-Za-z0-9_]+).*$/\1/' || true
    # v2 block form: `- name: X` followed shortly by `sig:`
    awk '
      /^[[:space:]]*-[[:space:]]+name:[[:space:]]+[A-Za-z0-9_]+/ {
        cand = $0
        gsub(/^[[:space:]]*-[[:space:]]+name:[[:space:]]+/, "", cand)
        gsub(/[[:space:]].*$/, "", cand)
        pending = cand
        next
      }
      /^[[:space:]]+sig:/ && pending {
        print pending
        pending = ""
      }
    ' "$META"
  } | sort -u
)

# --- Diffs ---
echo "=== test_function references ==="
diff <(echo "$META_TEST_FNS") <(echo "$TESTS_DECLARED") > /tmp/.meta_test_diff || true
# Lines starting with `<` are present in meta but not in tests file → broken refs
if grep -q '^<' /tmp/.meta_test_diff; then
  grep '^< ' /tmp/.meta_test_diff | sed 's/^< /ERR|test_function not in tests file: /'
fi
# Lines starting with `>` are tests not referenced in meta → just informational
miss=$(grep -c '^> ' /tmp/.meta_test_diff || true)
echo "OK|test functions referenced in metadata: $(echo "$META_TEST_FNS" | grep -c .)"
echo "OK|test functions in tests file: $(echo "$TESTS_DECLARED" | grep -c .)"
[ "$miss" -gt 0 ] && echo "WARN|$miss tests exist but are not referenced in _audit_grounding.precondition_proofs[] (v2 schema replaced examples[] with that block — only pin tests that PROVE a specific precondition / do_not, not the full inventory)"

echo "=== fails_with references ==="
while IFS= read -r err; do
  [ -z "$err" ] && continue
  if echo "$ERRORS_DECLARED" | grep -qx "$err"; then
    : # ok
  else
    echo "ERR|fails_with references undefined error: $err"
  fi
done <<< "$META_FAILS_WITH"
echo "OK|distinct fails_with values: $(echo "$META_FAILS_WITH" | grep -c .)"

echo "=== emits references ==="
# Extract event names from api[].emits: [Event1, Event2] entries.
META_EMITS=$(
  { grep -oE 'emits:[[:space:]]*\[[^]]*\]' "$META" 2>/dev/null \
      | sed -E 's/^emits:[[:space:]]*\[//; s/\]$//' \
      | tr ',' '\n' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' || true; } \
    | sort -u | grep -v '^$' || true
)
while IFS= read -r ev; do
  [ -z "$ev" ] && continue
  if echo "$EVENTS_DECLARED" | grep -qx "$ev"; then
    : # ok
  else
    echo "ERR|emits references undeclared event: $ev"
  fi
done <<< "$META_EMITS"
echo "OK|distinct emits values: $(echo "$META_EMITS" | grep -c .)"

echo "=== entry_points existence ==="
while IFS= read -r fn; do
  [ -z "$fn" ] && continue
  if echo "$FUNS_DECLARED" | grep -qx "$fn"; then
    : # ok
  else
    echo "WARN|entry_point declared in metadata but not found as public fun: $fn"
  fi
done <<< "$META_ENTRY_POINTS"
echo "OK|entry_points declared: $(echo "$META_ENTRY_POINTS" | grep -c .)"

echo "=== summary ==="
errs=$(grep -c '^ERR|' /tmp/.meta_test_diff 2>/dev/null || true)
echo "OK|validation complete"
