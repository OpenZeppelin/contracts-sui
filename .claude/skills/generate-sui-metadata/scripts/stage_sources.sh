#!/usr/bin/env bash
# Stage the files needed to generate Sui module metadata into a temporary
# directory, preserving the in-repo layout so the existing extractor scripts
# (which expect local file paths) can run against them.
#
# Accepts EITHER:
#   (1) A contracts-sui PR URL:
#       https://github.com/<owner>/<repo>/pull/<number>
#   (2) A direct GitHub link to a module's Move source:
#       https://github.com/<owner>/<repo>/blob/<ref>/contracts/<pkg>/sources/<name>.move
#
# Usage:
#   stage_sources.sh <source_url> [module_name]
#
# `module_name` only matters when (1) and the PR touches multiple module files.
#
# Side effects:
#   Creates a fresh tempdir (mktemp -d). Writes status lines on stdout in this
#   line-oriented format so the calling skill can parse it deterministically:
#
#     SOURCE_TYPE|pr|blob
#     STAGE_DIR|<absolute path>
#     SOURCE_OWNER|<owner>
#     SOURCE_REPO|<repo>
#     SOURCE_REF|<full commit SHA — for both PR and blob URLs; blob refs
#                  like `main` or a tag are resolved to a commit via `gh api`,
#                  so install.repo_ref downstream is always a reproducible pin>
#     PR_NUMBER|<number, empty when source_type=blob>
#     PR_BASE_REF|<base branch name, empty when source_type=blob>
#     PR_TITLE|<title, empty when source_type=blob>
#     MODULE_FILE|<absolute path to the staged Move source>
#     PACKAGE_ROOT|<absolute path to the staged package root inside the tempdir>
#     TESTS_FILE|<absolute path to the staged tests file, or empty if missing>
#     README_FILE|<absolute path to the staged README, or empty if missing>
#     MOVE_TOML_FILE|<absolute path to the staged Move.toml, or empty if missing>
#     MODULE_NAME|<module file basename without .move>
#     MODULE_DECL_NAME|<actual `module X::Y;` name from the source — use THIS
#                       for `module.name` synthesis and docs lookup; the file
#                       basename and the declaration name often diverge (e.g.
#                       `two_step.move` → `module openzeppelin_access::two_step_transfer;`).>
#     PACKAGE_NAME|<package directory basename, e.g., access>
#     CANDIDATE_MODULES|<comma-separated module names>  (only emitted when ambiguity)
#
# On error: prints an ERR| line to stderr and exits non-zero.
#
# Requires: gh (authenticated), jq, base64.

set -euo pipefail

SOURCE_URL="${1:-}"
MODULE_NAME_FILTER="${2:-}"

if [[ -z "$SOURCE_URL" ]]; then
  echo "ERR|missing required arg: <source_url> (PR URL or blob URL)" >&2
  exit 2
fi

# Detect URL type.
SOURCE_TYPE=""
SOURCE_OWNER=""
SOURCE_REPO=""
PR_NUMBER=""
PR_BASE_REF=""
PR_TITLE=""
TARGET=""        # path within the repo of the Move source
SOURCE_REF=""    # full commit SHA — resolved from PR head or from blob URL ref

if [[ "$SOURCE_URL" =~ ^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)/?$ ]]; then
  SOURCE_TYPE="pr"
  SOURCE_OWNER="${BASH_REMATCH[1]}"
  SOURCE_REPO="${BASH_REMATCH[2]}"
  PR_NUMBER="${BASH_REMATCH[3]}"
elif [[ "$SOURCE_URL" =~ ^https://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+\.move)$ ]]; then
  SOURCE_TYPE="blob"
  SOURCE_OWNER="${BASH_REMATCH[1]}"
  SOURCE_REPO="${BASH_REMATCH[2]}"
  RAW_REF="${BASH_REMATCH[3]}"
  TARGET="${BASH_REMATCH[4]}"
  # Require the path to contain a `/sources/` segment so we can locate the
  # package root deterministically. Otherwise reject. Note: contracts-sui
  # has packages at both `contracts/<pkg>/` (access, etc.) and `<pkg>/`
  # (math/, etc.), so we do not require a `contracts/` prefix.
  if [[ ! "$TARGET" =~ ^.+/sources/.+\.move$ ]]; then
    echo "ERR|blob URL does not point to a .move under a sources/ directory: $TARGET" >&2
    exit 4
  fi
  # Resolve the URL's ref to a full commit SHA so `install.repo_ref` in the
  # downstream YAML is always a reproducible pin — not a moving branch like
  # `main`. `gh api commits/<ref>` resolves branches, tags, and short SHAs.
  if [[ "$RAW_REF" =~ ^[0-9a-f]{40}$ ]]; then
    SOURCE_REF="$RAW_REF"
  else
    SOURCE_REF="$(gh api "repos/$SOURCE_OWNER/$SOURCE_REPO/commits/$RAW_REF" --jq '.sha' 2>/dev/null || true)"
    if [[ -z "$SOURCE_REF" ]]; then
      echo "ERR|could not resolve blob ref '$RAW_REF' to a commit SHA in $SOURCE_OWNER/$SOURCE_REPO (is the ref valid? is gh authenticated?)" >&2
      exit 3
    fi
  fi
else
  echo "ERR|not a recognized GitHub URL (expected PR URL or blob URL to .move file): $SOURCE_URL" >&2
  exit 2
fi

# --- PR path: resolve to head SHA + the target module file via the PR's file list ---
if [[ "$SOURCE_TYPE" == "pr" ]]; then
  PR_JSON="$(gh pr view "$SOURCE_URL" \
    --json files,headRefOid,baseRefName,title \
    2>/dev/null)" || {
    echo "ERR|gh pr view failed for $SOURCE_URL — is gh authenticated and do you have access?" >&2
    exit 3
  }

  SOURCE_REF="$(jq -r '.headRefOid' <<<"$PR_JSON")"
  PR_BASE_REF="$(jq -r '.baseRefName' <<<"$PR_JSON")"
  PR_TITLE="$(jq -r '.title' <<<"$PR_JSON")"

  mapfile -t CANDIDATES < <(
    jq -r '.files[].path' <<<"$PR_JSON" \
      | grep -E '^contracts/[^/]+/sources/.+\.move$' \
      || true
  )

  if [[ "${#CANDIDATES[@]}" -eq 0 ]]; then
    echo "ERR|PR $SOURCE_URL does not touch any contracts/<pkg>/sources/<name>.move file" >&2
    exit 4
  fi

  if [[ -n "$MODULE_NAME_FILTER" ]]; then
    for c in "${CANDIDATES[@]}"; do
      [[ "$(basename "$c" .move)" == "$MODULE_NAME_FILTER" ]] && TARGET="$c" && break
    done
    if [[ -z "$TARGET" ]]; then
      NAMES=""
      for c in "${CANDIDATES[@]}"; do NAMES+="$(basename "$c" .move),"; done
      NAMES="${NAMES%,}"
      echo "ERR|module_name '$MODULE_NAME_FILTER' not found among PR candidates: $NAMES" >&2
      exit 5
    fi
  elif [[ "${#CANDIDATES[@]}" -eq 1 ]]; then
    TARGET="${CANDIDATES[0]}"
  else
    NAMES=""
    for c in "${CANDIDATES[@]}"; do NAMES+="$(basename "$c" .move),"; done
    NAMES="${NAMES%,}"
    echo "ERR|PR touches multiple module files; pass module_name to disambiguate: $NAMES" >&2
    echo "CANDIDATE_MODULES|$NAMES" >&2
    exit 5
  fi
fi

# --- Both paths converge here. Stage files at SOURCE_REF ---
MODULE_FILE_BASENAME="$(basename "$TARGET" .move)"
# Walk up to the parent of the first 'sources/' segment so this works for both
# flat (sources/foo.move) and nested (sources/subdir/foo.move) layouts.
PACKAGE_DIR_IN_REPO="${TARGET%%/sources/*}"               # contracts/<pkg>
PACKAGE_NAME="$(basename "$PACKAGE_DIR_IN_REPO")"

# Stage files under /tmp/ by default. macOS's `$TMPDIR` (`/var/folders/.../T/`) is
# unreachable for downstream tools running in sandboxed environments (e.g., Claude
# Code agents that can only Read paths in the allowlist), so we bypass `$TMPDIR`
# entirely. Override with `SUI_META_STAGE_ROOT=<dir>` if /tmp is unsuitable.
STAGE_ROOT="${SUI_META_STAGE_ROOT:-/tmp}"
STAGE_DIR="$(mktemp -d "${STAGE_ROOT}/sui-meta.XXXXXX")"
mkdir -p "$STAGE_DIR/$PACKAGE_DIR_IN_REPO/sources"
mkdir -p "$STAGE_DIR/$PACKAGE_DIR_IN_REPO/tests"

fetch_at_ref() {
  local path="$1"
  local ref="$2"
  gh api "repos/$SOURCE_OWNER/$SOURCE_REPO/contents/$path?ref=$ref" 2>/dev/null \
    | jq -r 'if .content then .content else empty end' \
    | base64 -d 2>/dev/null
}

# 1) Module source (required) — at SOURCE_REF.
MODULE_STAGED="$STAGE_DIR/$TARGET"
mkdir -p "$(dirname "$MODULE_STAGED")"
if ! fetch_at_ref "$TARGET" "$SOURCE_REF" > "$MODULE_STAGED" || [[ ! -s "$MODULE_STAGED" ]]; then
  echo "ERR|could not fetch module source at $TARGET@$SOURCE_REF" >&2
  rm -rf "$STAGE_DIR"
  exit 6
fi

# Helper: try fetching a sibling file at SOURCE_REF first; for PR, also try PR_BASE_REF.
stage_optional() {
  local path_in_repo="$1"
  local staged="$STAGE_DIR/$path_in_repo"
  mkdir -p "$(dirname "$staged")"
  if fetch_at_ref "$path_in_repo" "$SOURCE_REF" > "$staged" 2>/dev/null && [[ -s "$staged" ]]; then
    echo "$staged"
    return 0
  fi
  if [[ -n "$PR_BASE_REF" ]] && fetch_at_ref "$path_in_repo" "$PR_BASE_REF" > "$staged" 2>/dev/null && [[ -s "$staged" ]]; then
    echo "$staged"
    return 0
  fi
  rm -f "$staged"
  echo ""
}

TESTS_STAGED=$(stage_optional "$PACKAGE_DIR_IN_REPO/tests/${MODULE_FILE_BASENAME}_tests.move")
README_STAGED=$(stage_optional "$PACKAGE_DIR_IN_REPO/README.md")
MOVE_TOML_STAGED=$(stage_optional "$PACKAGE_DIR_IN_REPO/Move.toml")

# --- Extract the actual module declaration name from the staged source. ---
# File basename and `module X::Y;` name frequently diverge (e.g. file
# `two_step.move` declares `module openzeppelin_access::two_step_transfer;`).
# Downstream synthesis must use MODULE_DECL_NAME for `module.name`, docs
# lookup, and any cross-module references; MODULE_NAME stays as the file
# basename for legacy callers.
MODULE_DECL_NAME=$(grep -m1 -E '^module\s+[a-z_0-9]+::[a-z_0-9]+\s*[;{]' "$MODULE_STAGED" \
  | sed -E 's/^module\s+[a-z_0-9]+::([a-z_0-9]+)\s*[;{].*/\1/')

# Canonical in-repo destination for the generated metadata YAML. Mirrors the
# source layout: <pkg>/sources/<subdir>/<file>.move → <pkg>/llms/<subdir>/<module-decl>.yaml.
# The basename is the MODULE DECLARATION name (not the file basename), so
# `two_step.move` declaring `two_step_transfer` lands at .../llms/.../two_step_transfer.yaml.
# This is repo-root-relative; the canonical run context is inside the contracts-sui
# checkout, so writing here drops the YAML in its final committed location.
SOURCE_SUBPATH="${TARGET#*/sources/}"                     # ownership_transfer/two_step.move  (or  access_control.move)
SOURCE_SUBDIR="$(dirname "$SOURCE_SUBPATH")"              # ownership_transfer  (or  .)
DECL_NAME_FOR_PATH="${MODULE_DECL_NAME:-$MODULE_FILE_BASENAME}"
if [ "$SOURCE_SUBDIR" = "." ]; then
  METADATA_PATH_IN_REPO="$PACKAGE_DIR_IN_REPO/llms/${DECL_NAME_FOR_PATH}.yaml"
else
  METADATA_PATH_IN_REPO="$PACKAGE_DIR_IN_REPO/llms/$SOURCE_SUBDIR/${DECL_NAME_FOR_PATH}.yaml"
fi

echo "SOURCE_TYPE|$SOURCE_TYPE"
echo "STAGE_DIR|$STAGE_DIR"
echo "SOURCE_OWNER|$SOURCE_OWNER"
echo "SOURCE_REPO|$SOURCE_REPO"
echo "SOURCE_REF|$SOURCE_REF"
echo "PR_NUMBER|$PR_NUMBER"
echo "PR_BASE_REF|$PR_BASE_REF"
echo "PR_TITLE|$PR_TITLE"
echo "MODULE_FILE|$MODULE_STAGED"
echo "PACKAGE_ROOT|$STAGE_DIR/$PACKAGE_DIR_IN_REPO"
echo "TESTS_FILE|${TESTS_STAGED:-}"
echo "README_FILE|${README_STAGED:-}"
echo "MOVE_TOML_FILE|${MOVE_TOML_STAGED:-}"
echo "MODULE_NAME|$MODULE_FILE_BASENAME"
echo "MODULE_DECL_NAME|${MODULE_DECL_NAME:-$MODULE_FILE_BASENAME}"
echo "PACKAGE_NAME|$PACKAGE_NAME"
echo "METADATA_PATH_IN_REPO|$METADATA_PATH_IN_REPO"
