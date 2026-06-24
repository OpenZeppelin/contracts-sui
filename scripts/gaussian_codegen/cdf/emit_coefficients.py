"""Read derive.py output, quantize each coefficient to (u128 magnitude, bool sign)
at WAD scale, and emit `cdf_coefficients.move`.

Coefficient layout in the emitted module:
- `NUM_MAGS: vector<u128>` and `NUM_NEGS: vector<bool>` (parallel arrays).
- `DEN_MAGS: vector<u128>` and `DEN_NEGS: vector<bool>` (parallel arrays).
- Both vectors are in **ascending power order** (index 0 = constant term).

The emitted accessors return the whole `vector<u128>` / `vector<bool>` constants
(`cdf_num_mags()`, `cdf_num_negs()`, `cdf_den_mags()`, `cdf_den_negs()`) so the
on-chain Horner loop binds them to a local once and indexes locally, plus
`max_z_raw()` exposing the central-domain saturation bound at the `10^9` scale.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
from typing import Sequence

from mpmath import mp, mpf

from gaussian_codegen.shared import constants
from gaussian_codegen.shared.move_emit import (
    auto_generated_banner,
    check_move,
    fmt_u128,
    format_move,
    rel_or_abs,
    write_move,
)

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]

WAD = constants.WAD
MAX_Z_RAW = constants.MAX_Z_RAW

DERIVE_OUTPUT_PATH = pathlib.Path(__file__).parent / ".derive_output.json"
COEFF_OUTPUT_PATH = (
    REPO_ROOT / "math" / "fixed_point" / "sources" / "internal" / "cdf_coefficients.move"
)


def quantize(c_str: str) -> tuple[int, bool]:
    """Quantize a high-precision coefficient string at unit scale to a
    `(u128 magnitude, bool is_negative)` pair at WAD scale, half-up rounding.

    The u128 range is enforced downstream by `fmt_u128` when the literal is
    rendered, so it is not re-checked here."""
    mp.dps = constants.DPS
    c = mpf(c_str)
    is_neg = c < 0
    mag_real = (-c if is_neg else c) * mpf(WAD)
    mag = int(mag_real + mpf("0.5"))
    if mag == 0:
        is_neg = False  # canonicalize zero
    return mag, bool(is_neg)


def render_vector(name: str, ty: str, items: Sequence[str], indent: str = "    ") -> str:
    body = f",\n{indent}".join(items)
    return f"const {name}: vector<{ty}> = vector[\n{indent}{body},\n];"


def emit_module(num: list[tuple[int, bool]], den: list[tuple[int, bool]]) -> str:
    banner = auto_generated_banner(
        "scripts/gaussian_codegen/cdf/derive.py + scripts/gaussian_codegen/cdf/emit_coefficients.py"
    )

    num_mag_items = [fmt_u128(m) for m, _ in num]
    num_neg_items = ["true" if n else "false" for _, n in num]
    den_mag_items = [fmt_u128(m) for m, _ in den]
    den_neg_items = ["true" if n else "false" for _, n in den]

    return f"""{banner}
/// Numerator and denominator coefficients for the AAA-rational standard-normal
/// CDF approximation on the central domain `[0, 6.3]`. All values are
/// sign-magnitude pairs at WAD (`10^18`) scale, indexed in ascending power
/// order (index 0 is the constant term).
///
/// Accessors return the underlying `vector<u128>` / `vector<bool>` constants so
/// callers can bind them to a local once per CDF evaluation and index locally
/// inside the Horner loop - avoiding a fresh constant load on every iteration.
///
/// See `cdf` for the consumer API. This module is regenerated from the AAA fit
/// in `scripts/gaussian_codegen/cdf/`; do not hand-edit.
module openzeppelin_fp_math::cdf_coefficients;

// === Constants ===

{render_vector("NUM_MAGS", "u128", num_mag_items)}

{render_vector("NUM_NEGS", "bool", num_neg_items)}

{render_vector("DEN_MAGS", "u128", den_mag_items)}

{render_vector("DEN_NEGS", "bool", den_neg_items)}

/// Saturation threshold |z| at the raw `10^9` scale: inputs with |z| ≥ this
/// saturate to the endpoint (0 for negative z, 10^9 for positive z) instead of
/// consulting the rational. Single source of truth for the central-domain
/// bound, consumed by `cdf::cdf_nonneg_raw`.
const MAX_Z_RAW: u128 = {fmt_u128(MAX_Z_RAW)};

// === Package Functions ===

/// Numerator magnitudes (ascending power order).
public(package) fun cdf_num_mags(): vector<u128> {{ NUM_MAGS }}

/// Numerator sign flags (ascending power order); index `i` paired with `cdf_num_mags()[i]`.
public(package) fun cdf_num_negs(): vector<bool> {{ NUM_NEGS }}

/// Denominator magnitudes (ascending power order).
public(package) fun cdf_den_mags(): vector<u128> {{ DEN_MAGS }}

/// Denominator sign flags (ascending power order); index `i` paired with `cdf_den_mags()[i]`.
public(package) fun cdf_den_negs(): vector<bool> {{ DEN_NEGS }}

/// Saturation threshold |z| at the raw `10^9` scale (`6_300_000_000`).
public(package) fun max_z_raw(): u128 {{ MAX_Z_RAW }}
"""


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Emit cdf_coefficients.move.")
    parser.add_argument("--input", type=pathlib.Path, default=DERIVE_OUTPUT_PATH)
    parser.add_argument("--output", type=pathlib.Path, default=COEFF_OUTPUT_PATH)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Verify the committed file matches freshly generated output; exit 1 on "
        "drift, do not write. Requires the input JSON to exist; the default "
        "committed `.derive_output.json` is sufficient.",
    )
    args = parser.parse_args(argv)

    if not args.input.exists():
        print(f"FAIL: missing {args.input} - run `python -m gaussian_codegen.cdf.derive` first", file=sys.stderr)
        return 1

    raw = json.loads(args.input.read_text(encoding="utf-8"))

    num = [quantize(s) for s in raw["num_coeffs_str"]]
    den = [quantize(s) for s in raw["den_coeffs_str"]]
    text = emit_module(num, den)
    text = format_move(text, args.output, REPO_ROOT)

    if args.check:
        if check_move(args.output, text):
            print(f"OK: {rel_or_abs(args.output, REPO_ROOT)} is in sync")
            return 0
        print("FAIL: run `python -m gaussian_codegen.cdf.emit_coefficients` to regenerate", file=sys.stderr)
        return 1

    print(f"Quantized {len(num)} numerator + {len(den)} denominator coefficients at WAD")
    write_move(args.output, text)
    print(f"Wrote {rel_or_abs(args.output, REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
