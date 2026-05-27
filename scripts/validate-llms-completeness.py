#!/usr/bin/env python3
"""
Validate that the llms metadata is COMPLETE and consistent with the source tree.

Schema validation (validate-llms-schema.py) checks that each YAML is well-formed;
semantic validation (validate-llms-semantics.py) checks cross-field integrity
within a YAML. This third layer checks the metadata set against the actual Move
source — catching the "added a module, forgot its YAML" (and the reverse) class.

For each package (located by its `<pkg>/llms/index.yaml`):

  1. Every public source module — every `.move` under `<pkg>/sources/` NOT under
     `sources/internal/`, by its DECLARED module name (`module pkg::name;`, NOT the
     file basename, which often diverges e.g. `conversions.move` → `sd29x9_convert`)
     — MUST have:
       a. an entry in the package index `modules[]` whose `name` matches, and
       b. a per-module YAML at the index entry's `path` whose `module.name` matches
          the fully-qualified declared name.
  2. Orphan check (reverse): every per-module YAML under `<pkg>/llms/` MUST
     correspond to a real non-internal source module of the same declared name.
  3. Every index `modules[].path` MUST point at a file that exists on disk.

The repo-root catalog (`llms/index.yaml`, the `packages[]` form) is checked
separately: each listed `index` path must exist, and every package index on disk
must be listed.

Usage:
  scripts/validate-llms-completeness.py            # check every package
  scripts/validate-llms-completeness.py <pkg-dir>  # check one package root

Exit codes: 0 = complete, 1 = gaps found, 2 = usage / dependency error.
"""
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError as e:
    print(f"error: missing dependency ({e.name}). install with: pip install pyyaml", file=sys.stderr)
    sys.exit(2)

REPO_ROOT = Path(__file__).resolve().parent.parent
MODULE_DECL = re.compile(r"^module\s+([a-z_0-9]+::[a-z_0-9]+)\s*;", re.MULTILINE)


def declared_module_name(move_file: Path) -> str | None:
    m = MODULE_DECL.search(move_file.read_text())
    return m.group(1) if m else None


def find_package_indexes() -> list[Path]:
    # Per-package indexes live at <pkg>/llms/index.yaml; the root catalog is
    # llms/index.yaml (directly under the repo root) — exclude it here.
    out = []
    for p in REPO_ROOT.glob("**/llms/index.yaml"):
        if p.parent.parent == REPO_ROOT:
            continue  # root catalog, handled separately
        out.append(p)
    return sorted(out)


def check_package(index_path: Path) -> list[str]:
    pkg_root = index_path.parent.parent           # <pkg>/
    llms_dir = index_path.parent                  # <pkg>/llms/
    sources = pkg_root / "sources"
    failures: list[str] = []
    rel_pkg = pkg_root.relative_to(REPO_ROOT)

    idx = yaml.safe_load(index_path.read_text())
    entries = {e["name"]: e for e in (idx.get("modules") or [])}

    # --- index path existence (3) ---
    for name, e in entries.items():
        if not (llms_dir / e["path"]).is_file():
            failures.append(f"{rel_pkg}: index entry {name!r} path {e['path']!r} does not exist on disk")

    # --- source modules → metadata (1) ---
    source_decls: dict[str, str] = {}  # short name -> fully-qualified
    if sources.is_dir():
        for mv in sorted(sources.rglob("*.move")):
            if "/internal/" in mv.as_posix() + "/":
                continue
            if "internal" in mv.relative_to(sources).parts:
                continue
            fq = declared_module_name(mv)
            if not fq:
                continue
            short = fq.split("::", 1)[1]
            source_decls[short] = fq
            rel_mv = mv.relative_to(REPO_ROOT)
            if short not in entries:
                failures.append(f"{rel_pkg}: source module {fq!r} ({rel_mv}) has no entry in index.yaml modules[]")
                continue
            ypath = llms_dir / entries[short]["path"]
            if ypath.is_file():
                ydoc = yaml.safe_load(ypath.read_text())
                yname = (ydoc.get("module") or {}).get("name")
                if yname != fq:
                    failures.append(
                        f"{rel_pkg}: YAML {entries[short]['path']} module.name={yname!r} "
                        f"does not match source declaration {fq!r} ({rel_mv})"
                    )
            # missing-file case already reported in the index-path loop

    # --- orphan check: YAML without a source module (2) ---
    for y in sorted(llms_dir.rglob("*.yaml")):
        if y.name == "index.yaml":
            continue
        ydoc = yaml.safe_load(y.read_text())
        yname = (ydoc.get("module") or {}).get("name")
        rel_y = y.relative_to(REPO_ROOT)
        if not yname:
            failures.append(f"{rel_pkg}: YAML {rel_y} has no module.name")
            continue
        short = yname.split("::", 1)[1] if "::" in yname else yname
        if short not in source_decls:
            failures.append(f"{rel_pkg}: YAML {rel_y} (module {yname!r}) has no matching non-internal source module")

    return failures


def check_root_catalog() -> list[str]:
    cat = REPO_ROOT / "llms" / "index.yaml"
    if not cat.is_file():
        return []  # optional
    failures: list[str] = []
    doc = yaml.safe_load(cat.read_text())
    listed = {}
    for p in (doc.get("packages") or []):
        listed[p["index"]] = p
        if not (REPO_ROOT / p["index"]).is_file():
            failures.append(f"llms/index.yaml: package {p['name']!r} index {p['index']!r} does not exist")
    # reverse: every on-disk package index must be catalogued
    for idx in find_package_indexes():
        rel = idx.relative_to(REPO_ROOT).as_posix()
        if rel not in listed:
            failures.append(f"llms/index.yaml: on-disk package index {rel} is not listed in the catalog")
    return failures


def main(argv: list[str]) -> int:
    if argv:
        roots = [Path(a).resolve() for a in argv]
        indexes = [r / "llms" / "index.yaml" for r in roots]
        for i in indexes:
            if not i.is_file():
                print(f"error: no llms/index.yaml under {i.parent.parent}", file=sys.stderr)
                return 2
    else:
        indexes = find_package_indexes()

    checked = 0
    all_failures: list[str] = []
    for idx in indexes:
        fs = check_package(idx)
        checked += 1
        rel = idx.relative_to(REPO_ROOT)
        if fs:
            print(f"FAIL  {rel}")
            for f in fs:
                print(f"      {f}")
            all_failures += fs
        else:
            print(f"PASS  {rel}")

    if not argv:
        cat_fs = check_root_catalog()
        if cat_fs:
            print("FAIL  llms/index.yaml (root catalog)")
            for f in cat_fs:
                print(f"      {f}")
            all_failures += cat_fs
        elif (REPO_ROOT / "llms" / "index.yaml").is_file():
            print("PASS  llms/index.yaml (root catalog)")

    print()
    print(f"{checked} package(s) checked" + (f", {len(all_failures)} gap(s)" if all_failures else " — complete"))
    return 1 if all_failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
