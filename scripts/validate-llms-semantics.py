#!/usr/bin/env python3
"""
Validate cross-field referential integrity of llms metadata YAMLs.

This is the semantic layer above the JSON Schema validation: it checks that
references between fields within a single module YAML stay consistent
(e.g., every error name cited in api[].aborts actually exists in errors,
every precondition cited in audit grounding actually exists, etc.).

Six checks per module YAML:
  1. api[].aborts                                              ⊆ errors.keys()
  2. preconditions[].fails_with                                ⊆ errors.keys()
  3. preconditions[E].affects                                  = {api.name where E in api.aborts}
  4. _audit_grounding.precondition_proofs[].precondition_fails_with
                                                               ⊆ preconditions[].fails_with
  5. _audit_grounding.do_not_demonstrations[].do_not_id        ⊆ do_not[].id
  6. _audit_grounding.do_not_detection[].do_not_id             ⊆ do_not[].id

Check #3 is strict set equality (catches both omissions and invented entries).
The other five are subset checks.

index.yaml files are skipped — they have no api/errors/preconditions to check.

Usage:
  scripts/validate-llms-semantics.py [--all] [PATH ...]

  --all       Validate every module YAML under */llms/ (excluding index.yaml).
  PATH ...    Validate only the listed files. Non-existent paths are skipped
              (covers deleted-file case in `git diff --name-only` input).
              index.yaml paths are silently skipped.

Exit codes:
  0 — all checked files pass
  1 — at least one file failed validation
  2 — usage error / missing dependencies
"""
import sys
from pathlib import Path

try:
    import yaml
except ImportError as e:
    print(f"error: missing dependency ({e.name}). install with: pip install pyyaml", file=sys.stderr)
    sys.exit(2)

REPO_ROOT = Path(__file__).resolve().parent.parent


def find_all_module_yamls() -> list[Path]:
    return sorted(p for p in REPO_ROOT.glob("**/llms/**/*.yaml") if p.name != "index.yaml")


def check_aborts_in_errors(doc: dict) -> list[str]:
    """1. Every error name in api[].aborts must exist in errors.keys()."""
    errors = set((doc.get("errors") or {}).keys())
    failures = []
    for api in doc.get("api") or []:
        name = api.get("name", "<unnamed>")
        for err in api.get("aborts") or []:
            if err not in errors:
                failures.append(f"api[{name}].aborts cites {err!r} but errors has no such key")
    return failures


def check_precondition_fails_with_in_errors(doc: dict) -> list[str]:
    """2. Every preconditions[].fails_with must exist in errors.keys()."""
    errors = set((doc.get("errors") or {}).keys())
    failures = []
    for i, pre in enumerate(doc.get("preconditions") or []):
        err = pre.get("fails_with")
        if err is not None and err not in errors:
            failures.append(f"preconditions[{i}].fails_with={err!r} but errors has no such key")
    return failures


def check_affects_exhaustive(doc: dict) -> list[str]:
    """3. preconditions[E].affects must equal {api.name where E in api.aborts}.

    Strict equality — catches both omissions (api aborts with E but missing
    from affects) and invented entries (affects names an api that doesn't
    actually abort with E).
    """
    apis_by_error: dict[str, set[str]] = {}
    for api in doc.get("api") or []:
        name = api.get("name")
        if not name:
            continue
        for err in api.get("aborts") or []:
            apis_by_error.setdefault(err, set()).add(name)

    failures = []
    for i, pre in enumerate(doc.get("preconditions") or []):
        err = pre.get("fails_with")
        if err is None:
            continue
        declared = set(pre.get("affects") or [])
        actual = apis_by_error.get(err, set())
        missing = actual - declared
        extra = declared - actual
        if missing or extra:
            parts = []
            if missing:
                parts.append(f"missing {sorted(missing)}")
            if extra:
                parts.append(f"unexpected {sorted(extra)}")
            failures.append(
                f"preconditions[{i}] (fails_with={err}).affects mismatch — {'; '.join(parts)}"
            )
    return failures


def check_precondition_proofs_reference_real_preconditions(doc: dict) -> list[str]:
    """4. _audit_grounding.precondition_proofs[].precondition_fails_with must exist in preconditions[].fails_with."""
    declared = {
        pre.get("fails_with") for pre in (doc.get("preconditions") or []) if pre.get("fails_with")
    }
    failures = []
    proofs = (doc.get("_audit_grounding") or {}).get("precondition_proofs") or []
    for i, proof in enumerate(proofs):
        err = proof.get("precondition_fails_with")
        if err is not None and err not in declared:
            failures.append(
                f"_audit_grounding.precondition_proofs[{i}].precondition_fails_with={err!r} "
                f"is not declared in any preconditions[].fails_with"
            )
    return failures


def check_do_not_id_references(doc: dict, field: str) -> list[str]:
    """5+6. _audit_grounding.<field>[].do_not_id must exist in do_not[].id."""
    declared = {d.get("id") for d in (doc.get("do_not") or []) if d.get("id")}
    failures = []
    entries = (doc.get("_audit_grounding") or {}).get(field) or []
    for i, entry in enumerate(entries):
        ref = entry.get("do_not_id")
        if ref is not None and ref not in declared:
            failures.append(
                f"_audit_grounding.{field}[{i}].do_not_id={ref!r} "
                f"is not declared in any do_not[].id"
            )
    return failures


CHECKS = [
    ("api.aborts ⊆ errors", check_aborts_in_errors),
    ("preconditions.fails_with ⊆ errors", check_precondition_fails_with_in_errors),
    ("preconditions.affects = unia(api with that abort)", check_affects_exhaustive),
    ("audit_grounding.precondition_proofs ⊆ preconditions.fails_with", check_precondition_proofs_reference_real_preconditions),
    ("audit_grounding.do_not_demonstrations ⊆ do_not.id",
     lambda d: check_do_not_id_references(d, "do_not_demonstrations")),
    ("audit_grounding.do_not_detection ⊆ do_not.id",
     lambda d: check_do_not_id_references(d, "do_not_detection")),
]


def validate_one(path: Path) -> list[str]:
    try:
        doc = yaml.safe_load(path.read_text())
    except yaml.YAMLError as e:
        return [f"yaml parse error: {e}"]
    if not isinstance(doc, dict):
        return [f"root is not a mapping (got {type(doc).__name__})"]

    failures = []
    for label, fn in CHECKS:
        for f in fn(doc):
            failures.append(f"[{label}] {f}")
    return failures


def main(argv: list[str]) -> int:
    if not argv or argv == ["--all"]:
        targets = find_all_module_yamls()
    else:
        targets = [REPO_ROOT / p for p in argv]

    checked = 0
    total_failures = 0

    for path in targets:
        if not path.exists():
            continue
        if path.name == "index.yaml":
            continue
        rel = path.relative_to(REPO_ROOT) if path.is_absolute() else path
        failures = validate_one(path)
        checked += 1
        if not failures:
            print(f"PASS  {rel}")
        else:
            print(f"FAIL  {rel}")
            for f in failures:
                print(f"      {f}")
            total_failures += 1

    print()
    print(f"{checked - total_failures} / {checked} pass" + (f", {total_failures} fail" if total_failures else ""))
    return 1 if total_failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
