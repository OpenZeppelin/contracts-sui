"""Helpers for emitting Move source files from codegen scripts."""
from __future__ import annotations

import datetime as _dt
from pathlib import Path


def fmt_u128(n: int) -> str:
    """Format a non-negative integer as a Move-friendly decimal literal with
    underscore separators every 3 digits (right-aligned). The `u128` suffix is
    *not* appended — call sites add it where needed."""
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
    emitted Move file. Generation date is included for human auditing."""
    today = _dt.date.today().isoformat()
    return (
        f"// AUTO-GENERATED — do not hand-edit.\n"
        f"// Source: {source}\n"
        f"// Regenerated: {today}\n"
    )


def write_move(path: Path, content: str) -> None:
    """Write a Move source file, creating parent directories if needed.
    Trailing newline is enforced for POSIX cleanliness."""
    if not content.endswith("\n"):
        content += "\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
