#!/usr/bin/env python3
"""
Validate llms metadata YAMLs against the published JSON Schemas.

Used by both:
  - CI workflow `.github/workflows/llms-schema-validation.yml` on PRs
  - Maintainers locally before pushing

Schemas:
  schemas/llms-metadata-v1.json       — for per-module YAMLs
  schemas/llms-package-index-v1.json  — for per-package index.yaml files

Usage:
  scripts/validate-llms-schema.py [--all] [PATH ...]

  --all       Validate every YAML under */llms/.
  PATH ...    Validate only the listed files. Non-existent paths are skipped
              (covers the deleted-file case in `git diff --name-only` input).

Exit codes:
  0 — all checked files pass
  1 — at least one file failed validation
  2 — usage error / missing dependencies
"""
import json
import sys
from pathlib import Path

try:
    import yaml
    import jsonschema
except ImportError as e:
    print(f"error: missing dependency ({e.name}). install with: pip install pyyaml jsonschema", file=sys.stderr)
    sys.exit(2)

REPO_ROOT = Path(__file__).resolve().parent.parent
MODULE_SCHEMA_PATH = REPO_ROOT / "schemas" / "llms-metadata-v1.json"
INDEX_SCHEMA_PATH = REPO_ROOT / "schemas" / "llms-package-index-v1.json"


def load_schema(path: Path) -> dict:
    if not path.exists():
        print(f"error: schema not found at {path}", file=sys.stderr)
        sys.exit(2)
    return json.loads(path.read_text())


def schema_for(yaml_path: Path, module_schema: dict, index_schema: dict) -> dict:
    return index_schema if yaml_path.name == "index.yaml" else module_schema


def find_all_yamls() -> list[Path]:
    return sorted(REPO_ROOT.glob("**/llms/**/*.yaml"))


def validate_one(path: Path, schema: dict) -> str | None:
    try:
        doc = yaml.safe_load(path.read_text())
    except yaml.YAMLError as e:
        return f"yaml parse error: {e}"
    try:
        jsonschema.validate(doc, schema)
    except jsonschema.ValidationError as e:
        loc = " / ".join(map(str, e.absolute_path)) or "<root>"
        return f"schema violation at {loc}: {e.message}"
    return None


def main(argv: list[str]) -> int:
    if not argv or argv == ["--all"]:
        targets = find_all_yamls()
    else:
        targets = [REPO_ROOT / p for p in argv]

    module_schema = load_schema(MODULE_SCHEMA_PATH)
    index_schema = load_schema(INDEX_SCHEMA_PATH)

    checked = 0
    failures: list[tuple[Path, str]] = []

    for path in targets:
        if not path.exists():
            continue
        rel = path.relative_to(REPO_ROOT) if path.is_absolute() else path
        schema = schema_for(path, module_schema, index_schema)
        err = validate_one(path, schema)
        checked += 1
        if err is None:
            print(f"PASS  {rel}")
        else:
            print(f"FAIL  {rel}")
            print(f"      {err}")
            failures.append((rel, err))

    print()
    print(f"{checked - len(failures)} / {checked} pass" + (f", {len(failures)} fail" if failures else ""))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
