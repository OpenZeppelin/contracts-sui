#!/usr/bin/env bash
# Stage the MDX guide for a Sui module from a docs PR into a tempdir.
#
# Usage:
#   stage_docs_pr.sh <docs_pr_url> <module_name> [stage_dir]
#
# If <stage_dir> is given, the MDX is staged inside it under
# docs/modules/<filename>.mdx; otherwise a fresh tempdir is created.
#
# Output (stdout, line-oriented):
#   DOCS_STAGE_DIR|<absolute path>
#   DOCS_MDX_FILE|<absolute path to the MDX, or empty if no matching file found>
#   DOCS_PR_OWNER|<owner>
#   DOCS_PR_REPO|<repo>
#   DOCS_PR_NUMBER|<number>
#   DOCS_HEAD_SHA|<sha>
#
# On error: prints ERR| to stderr, exits non-zero.

set -euo pipefail

DOCS_URL="${1:-}"
MODULE_NAME="${2:-}"
STAGE_DIR="${3:-}"

if [[ -z "$DOCS_URL" || -z "$MODULE_NAME" ]]; then
  echo "ERR|usage: stage_docs_pr.sh <docs_pr_url> <module_name> [stage_dir]" >&2
  exit 2
fi

if [[ ! "$DOCS_URL" =~ ^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)/?$ ]]; then
  echo "ERR|not a GitHub PR URL: $DOCS_URL" >&2
  exit 2
fi

OWNER="${BASH_REMATCH[1]}"
REPO="${BASH_REMATCH[2]}"
NUMBER="${BASH_REMATCH[3]}"

PR_JSON="$(gh pr view "$DOCS_URL" --json files,headRefOid 2>/dev/null)" || {
  echo "ERR|gh pr view failed for $DOCS_URL — is gh authenticated and do you have access?" >&2
  exit 3
}

HEAD_SHA="$(jq -r '.headRefOid' <<<"$PR_JSON")"

if [[ -z "$STAGE_DIR" ]]; then
  STAGE_DIR="$(mktemp -d -t sui-meta-docs-XXXXXX)"
fi

# Find the MDX whose basename matches the module name. Tolerate hyphenated
# variants (e.g., access_control vs access-control).
MOD_KEY_UNDER="$MODULE_NAME"
MOD_KEY_HYPHEN="${MODULE_NAME//_/-}"

MATCHED_PATH=""
while IFS= read -r path; do
  bn_lower="$(basename "$path" | tr '[:upper:]' '[:lower:]')"
  if [[ "$bn_lower" == "${MOD_KEY_UNDER,,}.mdx" \
     || "$bn_lower" == "${MOD_KEY_HYPHEN,,}.mdx" ]]; then
    MATCHED_PATH="$path"
    break
  fi
done < <(jq -r '.files[].path' <<<"$PR_JSON" | grep -E '\.mdx$' || true)

DOCS_MDX_FILE=""
if [[ -n "$MATCHED_PATH" ]]; then
  TARGET_DIR="$STAGE_DIR/$(dirname "$MATCHED_PATH")"
  mkdir -p "$TARGET_DIR"
  TARGET_FILE="$STAGE_DIR/$MATCHED_PATH"
  if gh api "repos/$OWNER/$REPO/contents/$MATCHED_PATH?ref=$HEAD_SHA" 2>/dev/null \
       | jq -r 'if .content then .content else empty end' \
       | base64 -d > "$TARGET_FILE" 2>/dev/null \
     && [[ -s "$TARGET_FILE" ]]; then
    DOCS_MDX_FILE="$TARGET_FILE"
  fi
fi

echo "DOCS_STAGE_DIR|$STAGE_DIR"
echo "DOCS_MDX_FILE|$DOCS_MDX_FILE"
echo "DOCS_PR_OWNER|$OWNER"
echo "DOCS_PR_REPO|$REPO"
echo "DOCS_PR_NUMBER|$NUMBER"
echo "DOCS_HEAD_SHA|$HEAD_SHA"
