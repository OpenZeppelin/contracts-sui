#!/usr/bin/env bash
# Deterministic extraction of structural data from a Sui Move source file.
# Emits a JSON-ish report on stdout (line-oriented; the calling skill parses it).
#
# Usage:
#   extract_move_structure.sh <path-to-module.move>
#
# Sections emitted (in order):
#   MODULE=<fully-qualified module name>
#   ENTRY_POINT|<name>|<kind-hint>|<signature-line>
#   ABORTS|<fn_name>|<E1,E2,...>      # from `#### Aborts` doc-comment block
#   EMITS|<fn_name>|<EventName>       # one line per event::emit found in body
#   ERROR|<name>|<code>|<message>     # <code> empty if no #[error(code=N)]
#   TYPE|<name>|<type-params>|<capabilities>|<fields>   # non-event integrator types
#   EVENT|<name>|<fields-comma-separated>
#   DOC_GUIDANCE|<heading>|<text>     # `/// #### <Security|Misuse|Warning|Guidance|...>`
#                                       doc blocks — feed do_not[] / decisions[] synthesis

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <path-to-module.move>" >&2
  exit 1
fi

SRC="$1"
if [ ! -f "$SRC" ]; then
  echo "error: file not found: $SRC" >&2
  exit 1
fi

# --- Module identifier ---
MODULE=$(grep -m1 -E '^module\s+[a-z_0-9]+::[a-z_0-9]+\s*;' "$SRC" \
  | sed -E 's/^module\s+([a-z_0-9]+::[a-z_0-9]+)\s*;.*/\1/')
echo "MODULE=$MODULE"

# --- Entry points + per-function aborts ---
# Multi-state awk pass:
#   - Track when we are inside a `/// #### Aborts` block; collect E-codes.
#   - On `public fun`, emit ENTRY_POINT line and ABORTS line (if any collected).
#   - Skip `#[test_only]`-annotated functions.
awk '
  function clean_sig(s,    out) {
    gsub(/[[:space:]]+/, " ", s)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
    return s
  }

  # Track entry into an Aborts doc-comment block.
  /^\/\/\/[[:space:]]*####[[:space:]]*Aborts/ { in_aborts = 1; next }
  # Any other ####-section ends Aborts.
  /^\/\/\/[[:space:]]*####/ { in_aborts = 0; next }
  # Plain `///` line: if in Aborts, harvest E-codes from `- \`EXxx\`` form.
  /^\/\/\// {
    if (in_aborts) {
      line = $0
      while (match(line, /`E[A-Za-z0-9_]+`/)) {
        code = substr(line, RSTART + 1, RLENGTH - 2)
        if (length(aborts) > 0) aborts = aborts "," code
        else aborts = code
        line = substr(line, RSTART + RLENGTH)
      }
    }
    next
  }
  # `#[test_only]`: mark the next public fun to be skipped.
  /^#\[test_only\]/ { skip_next_pub = 1; in_aborts = 0; next }

  # `public fun ...` OR `public macro fun ...`: gather signature, emit ENTRY_POINT.
  /^public (macro )?fun / {
    if (skip_next_pub) {
      skip_next_pub = 0
      in_aborts = 0
      aborts = ""
      next
    }

    is_macro = ($0 ~ /^public macro fun /)

    sig = $0
    while (sig !~ /[{;]/ && (getline next_line) > 0) {
      sig = sig " " next_line
    }
    sub(/[{;].*$/, "", sig)

    name = sig
    sub(/^public (macro )?fun /, "", name)
    sub(/[<(].*$/, "", name)

    # Kind classification — schema-compliant values only (read | write | macro | init).
    # `kind` is optional per schema; extractor emits a best-guess hint, sub-agents may
    # refine or omit at synthesis time.
    if (is_macro) kind = "macro"
    else if (name == "new" && sig ~ /<[[:space:]]*RootRole[[:space:]]*:[[:space:]]*drop/) kind = "init"
    else if (name ~ /^(begin_|accept_|cancel_)/)    kind = "write"   # scheduled lifecycle ops mutate state
    else if (sig ~ /:[[:space:]]*Auth</)            kind = "write"   # mints proof, conceptually a write
    else if (sig ~ /&mut /)                         kind = "write"   # any &mut argument => write
    else                                            kind = "read"    # default

    print "ENTRY_POINT|" name "|" kind "|" clean_sig(sig)
    if (length(aborts) > 0) print "ABORTS|" name "|" aborts

    aborts = ""
    in_aborts = 0
    current_fn = name
  }

  # event::emit inside any function body — attribute to the most recent
  # `public fun` seen. Private helpers that emit events get attributed to
  # the public caller above them, which is fine for integrator-facing docs.
  /event::emit\(/ && current_fn != "" {
    line = $0
    if (match(line, /event::emit\([[:space:]]*[A-Za-z_][A-Za-z0-9_]*/)) {
      ev = substr(line, RSTART, RLENGTH)
      sub(/^event::emit\([[:space:]]*/, "", ev)
      print "EMITS|" current_fn "|" ev
    }
  }

  # Reset state on any other non-doc-comment line.
  !/^\/\/\// && !/^#\[/ && !/^public fun / {
    in_aborts = 0
    aborts = ""
    skip_next_pub = 0
  }
' "$SRC"

# --- Error codes (Move convention: #[error(code = N)] const EXxx: vector<u8> = "..."; ) ---
# Also tolerates plain `#[error]` (no code) — emits empty code column.
awk '
  /^#\[error(\(|\])/ {
    in_error = 1
    current_code = ""
    if (match($0, /code[[:space:]]*=[[:space:]]*[0-9]+/)) {
      code_str = substr($0, RSTART, RLENGTH)
      gsub(/[^0-9]/, "", code_str)
      current_code = code_str
    }
    next
  }
  in_error && /^const E[A-Za-z0-9_]+:/ {
    match($0, /const E[A-Za-z0-9_]+/)
    name = substr($0, RSTART + 6, RLENGTH - 6)
    text = $0
    while (text !~ /"[[:space:]]*;/ && (getline next_line) > 0) {
      text = text " " next_line
    }
    sub(/^[^"]*"/, "", text)
    sub(/"[[:space:]]*;.*$/, "", text)
    gsub(/\|/, " ", text)
    print "ERROR|" name "|" current_code "|" text
    in_error = 0
    current_code = ""
  }
' "$SRC"

# --- Types (integrator-facing structs: those carrying `key` or `store`). ---
# Events (copy + drop only, no key/store) are emitted separately below.
# Format: TYPE|<name>|<type-params-or-empty>|<capability-list-comma>|<field-list-comma>
awk '
  /^public struct [A-Z][A-Za-z0-9_]*(<[^>]*>)?(\([^)]*\))?[[:space:]]+has[[:space:]]+[a-z, ]+/ {
    head = $0
    # Extract name
    match(head, /^public struct [A-Z][A-Za-z0-9_]*/)
    name = substr(head, RSTART + 14, RLENGTH - 14)

    # Extract type parameters between < and > immediately after name
    type_params = ""
    rest = substr(head, RSTART + RLENGTH)
    if (match(rest, /^<[^>]*>/)) {
      type_params = substr(rest, RSTART + 1, RLENGTH - 2)
      rest = substr(rest, RSTART + RLENGTH)
    }
    # Skip tuple-struct positional fields `(...)` between name and `has`
    if (match(rest, /^\([^)]*\)/)) {
      rest = substr(rest, RSTART + RLENGTH)
    }

    # Extract capabilities after `has`
    if (match(rest, /has[[:space:]]+[a-z, ]+/)) {
      caps = substr(rest, RSTART + 4, RLENGTH - 4)
      gsub(/[[:space:]]/, "", caps)
    } else {
      caps = ""
    }

    # Skip event-shaped structs: capabilities are exactly `copy,drop` (no key/store).
    if (caps == "copy,drop" || caps == "drop,copy") next

    # Gather field names if struct body starts on this line or next lines.
    fields = ""
    if (head ~ /\{[[:space:]]*\}/) {
      # empty struct
    } else if (head ~ /\{[[:space:]]*$/) {
      while ((getline next_line) > 0) {
        if (next_line ~ /^[[:space:]]*\}/) break
        f = next_line
        gsub(/^[[:space:]]+/, "", f)
        gsub(/[[:space:]]*:.*$/, "", f)
        gsub(/,[[:space:]]*$/, "", f)
        if (length(f) > 0 && f !~ /^\/\//) {
          fields = fields (length(fields) > 0 ? "," : "") f
        }
      }
    }

    print "TYPE|" name "|" type_params "|" caps "|" fields
  }
' "$SRC"

# --- Events (structs with `has copy, drop` — also matches `<phantom T>` parameterized). ---
awk '
  /^public struct [A-Z][A-Za-z0-9_]*(<[^>]*>)?[[:space:]]+has copy, drop/ {
    match($0, /public struct [A-Z][A-Za-z0-9_]*/)
    name = substr($0, RSTART + 14, RLENGTH - 14)
    if ($0 ~ /\{[[:space:]]*\}/) {
      print "EVENT|" name "|"
      next
    }
    if ($0 ~ /\{[[:space:]]*$/) {
      fields = ""
      while ((getline next_line) > 0) {
        if (next_line ~ /^\}/) break
        field_name = next_line
        gsub(/^[[:space:]]+/, "", field_name)
        gsub(/:.*$/, "", field_name)
        if (length(field_name) > 0 && field_name !~ /^\/\//) {
          fields = fields (length(fields) > 0 ? "," : "") field_name
        }
      }
      print "EVENT|" name "|" fields
    }
  }
' "$SRC"

# --- Doc-comment guidance blocks (#### Security / Misuse / Warning / Guidance / ...) ---
# These narrative `///` blocks carry the consumer-side anti-patterns and integration
# constraints that drive do_not[] / decisions[] synthesis. Mechanical per-function
# sections (Parameters / Returns / Aborts) are NOT emitted — they are already covered
# by ENTRY_POINT / ABORTS. Both module-level and function-level guidance blocks surface.
awk '
  function is_guidance(h) { return (h ~ /[Ss]ecurity|[Mm]isuse|[Dd]anger|[Cc]aution|[Ww]arning|[Gg]uidance|[Ii]nvariant|[Tt]radeoff/) }
  /^[[:space:]]*\/\/\/[[:space:]]*####[[:space:]]/ {
    if (heading != "" && is_guidance(heading)) print "DOC_GUIDANCE|" heading "|" body
    line = $0
    sub(/^[[:space:]]*\/\/\/[[:space:]]*####[[:space:]]*/, "", line)
    heading = line
    body = ""
    next
  }
  heading != "" {
    if ($0 ~ /^[[:space:]]*\/\/\//) {
      line = $0
      sub(/^[[:space:]]*\/\/\/[[:space:]]?/, "", line)
      gsub(/\|/, " ", line)
      if (line != "") body = (body == "" ? line : body " " line)
    } else {
      if (is_guidance(heading)) print "DOC_GUIDANCE|" heading "|" body
      heading = ""
      body = ""
    }
  }
  END { if (heading != "" && is_guidance(heading)) print "DOC_GUIDANCE|" heading "|" body }
' "$SRC"
