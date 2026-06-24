"""Helpers for emitting Move source files from codegen scripts."""
from __future__ import annotations

import difflib
import subprocess
import sys
from pathlib import Path


def fmt_u128(n: int) -> str:
    """Format a non-negative integer as a Move-friendly decimal literal with
    underscore separators every 3 digits (right-aligned). The `u128` suffix is
    *not* appended - call sites add it where needed."""
    if n < 0:
        raise ValueError(f"u128 literal must be non-negative, got {n}")
    if n >= 2**128:
        raise ValueError(f"u128 overflow: {n} >= 2^128")
    return _grouped(str(n))


def fmt_u64(n: int) -> str:
    if n < 0 or n >= 2**64:
        raise ValueError(f"u64 out of range: {n}")
    return _grouped(str(n))


def _grouped(digits: str) -> str:
    """Right-align grouping of decimal digits in chunks of 3.
    Examples: '1' -> '1', '1234' -> '1_234', '6300000000000000000' -> '6_300_000_000_000_000_000'.
    """
    if not digits:
        return "0"
    n = len(digits)
    chunks: list[str] = []
    i = n
    while i > 0:
        chunks.append(digits[max(0, i - 3) : i])
        i -= 3
    return "_".join(reversed(chunks))


def auto_generated_banner(source: str) -> str:
    """A two-line banner identifying the file as auto-generated. Use in every
    emitted Move file.

    Deliberately carries no timestamp: emitted output is a deterministic
    function of its inputs, so regenerating an unchanged fit is a no-op and the
    `--check` drift guard can compare committed output byte-for-byte."""
    return (
        f"// AUTO-GENERATED - do not hand-edit.\n"
        f"// Source: {source}\n"
    )


def rel_or_abs(path: Path, root: Path) -> Path:
    """`path` relative to `root` when possible, else `path` unchanged. Used only
    for human-readable logging - a custom `--output` outside the repo must not
    crash the script after a successful write."""
    try:
        return path.relative_to(root)
    except ValueError:
        return path


def format_move(text: str, path: Path, repo_root: Path) -> str:
    """Format Move source `text` with the repo's prettier + Move plugin, keyed
    by `path`'s `.move` extension.

    The emitters call this so their output is *already* formatter-compliant.
    The committed generated files are checked against the repo-wide Move
    formatter in CI, and formatting here makes the `--check` drift guard exact:
    it compares formatted output against the committed file, instead of raw
    output that a separate `prettier` pass would later reflow (the historical
    source of the coefficients-file drift).

    Raises if prettier is unavailable, so generation fails loudly rather than
    emitting unformatted output that would later trip the formatter gate."""
    prettier = repo_root / "node_modules" / ".bin" / "prettier"
    if not prettier.exists():
        raise RuntimeError(
            f"prettier not found at {prettier}; run `npm ci` at the repo root "
            "(installs @mysten/prettier-plugin-move, the Move formatter)"
        )
    result = subprocess.run(
        [str(prettier), "--stdin-filepath", str(path)],
        input=text,
        capture_output=True,
        text=True,
        cwd=repo_root,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"prettier failed to format {path} (exit {result.returncode}):\n{result.stderr}"
        )
    return result.stdout


def write_move(path: Path, content: str) -> None:
    """Write a Move source file, creating parent directories if needed.
    Trailing newline is enforced for POSIX cleanliness."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(_with_trailing_newline(content), encoding="utf-8")


def check_move(path: Path, content: str) -> bool:
    """Return `True` iff `path` exists and already matches `content` exactly
    (after trailing-newline normalization, matching `write_move`).

    On mismatch, print a unified diff to stderr. This is the drift guard behind
    the emitters' `--check` mode: it asserts the committed Move file is in sync
    with what the generator would produce right now."""
    expected = _with_trailing_newline(content)
    if not path.exists():
        print(f"DRIFT: {path} does not exist", file=sys.stderr)
        return False
    current = path.read_text(encoding="utf-8")
    if current == expected:
        return True
    diff = difflib.unified_diff(
        current.splitlines(keepends=True),
        expected.splitlines(keepends=True),
        fromfile=f"{path} (committed)",
        tofile=f"{path} (freshly generated)",
    )
    print(f"DRIFT: {path} is out of sync with the generator:", file=sys.stderr)
    print("".join(diff), file=sys.stderr)
    return False


def _with_trailing_newline(content: str) -> str:
    return content if content.endswith("\n") else content + "\n"
