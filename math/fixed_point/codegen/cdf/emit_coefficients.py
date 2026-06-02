"""Read derive.py output, quantize each coefficient to (u128 magnitude, bool sign)
at WAD scale, and emit `cdf_coefficients.move`.

Coefficient layout in the emitted module:
- `NUM_MAGS: vector<u128>` and `NUM_NEGS: vector<bool>` (parallel arrays).
- `DEN_MAGS: vector<u128>` and `DEN_NEGS: vector<bool>` (parallel arrays).
- Both vectors are in **ascending power order** (index 0 = constant term).

Accessors `cdf_num_coeff(i) / cdf_den_coeff(i)` return `(magnitude, is_negative)`
matching the reference package's `coefficients` API shape.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
from typing import Sequence

from mpmath import mp, mpf

from codegen.shared import constants
from codegen.shared.move_emit import (
    auto_generated_banner,
    check_move,
    fmt_u128,
    write_move,
)

REPO_ROOT = pathlib.Path(__file__).resolve().parents[4]

WAD = constants.WAD
MAX_Z_RAW_WAD = constants.MAX_Z_RAW_WAD

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
        "math/fixed_point/codegen/cdf/derive.py + math/fixed_point/codegen/cdf/emit_coefficients.py"
    )

    num_mag_items = [fmt_u128(m) for m, _ in num]
    num_neg_items = ["true" if n else "false" for _, n in num]
    den_mag_items = [fmt_u128(m) for m, _ in den]
    den_neg_items = ["true" if n else "false" for _, n in den]
    num_len = len(num)
    den_len = len(den)

    return f"""{banner}
/// Numerator and denominator coefficients for the AAA-rational standard-normal
/// CDF approximation on `[0, max_z()]`. All values are sign-magnitude pairs at
/// WAD (`10^18`) scale, indexed in ascending power order (index 0 is the
/// constant term).
///
/// Accessors return the underlying `vector<u128>` / `vector<bool>` constants so
/// callers can bind them to a local once per CDF evaluation and index locally
/// inside the Horner loop — avoiding a fresh constant load on every iteration.
///
/// See `cdf` for the consumer API. This module is regenerated from the AAA fit
/// in `math/fixed_point/codegen/cdf/`; do not hand-edit.
#[allow(implicit_const_copy)]
module openzeppelin_fp_math::cdf_coefficients;

{render_vector("NUM_MAGS", "u128", num_mag_items)}

{render_vector("NUM_NEGS", "bool", num_neg_items)}

{render_vector("DEN_MAGS", "u128", den_mag_items)}

{render_vector("DEN_NEGS", "bool", den_neg_items)}

/// Number of numerator coefficients (polynomial degree = result − 1).
const NUM_LEN: u64 = {num_len};

/// Number of denominator coefficients (polynomial degree = result − 1).
const DEN_LEN: u64 = {den_len};

/// Saturation threshold |z| at WAD scale: |z| ≥ this returns the saturated CDF
/// value (0 for negative z, 10^9 for positive z) without consulting the rational.
const MAX_Z_WAD: u128 = {fmt_u128(MAX_Z_RAW_WAD)};

/// Internal arithmetic scale used by the coefficient encoding (WAD = 10^18).
const SCALE_WAD: u128 = {fmt_u128(WAD)};

/// Numerator magnitudes (ascending power order).
public(package) fun cdf_num_mags(): vector<u128> {{ NUM_MAGS }}

/// Numerator sign flags (ascending power order); index `i` paired with `cdf_num_mags()[i]`.
public(package) fun cdf_num_negs(): vector<bool> {{ NUM_NEGS }}

/// Denominator magnitudes (ascending power order).
public(package) fun cdf_den_mags(): vector<u128> {{ DEN_MAGS }}

/// Denominator sign flags (ascending power order); index `i` paired with `cdf_den_mags()[i]`.
public(package) fun cdf_den_negs(): vector<bool> {{ DEN_NEGS }}

/// Number of numerator coefficients.
public(package) fun cdf_num_len(): u64 {{ NUM_LEN }}

/// Number of denominator coefficients.
public(package) fun cdf_den_len(): u64 {{ DEN_LEN }}

/// Saturation threshold |z| at WAD scale.
public(package) fun max_z(): u128 {{ MAX_Z_WAD }}

/// Internal arithmetic scale (WAD = 10^18).
public(package) fun scale(): u128 {{ SCALE_WAD }}
"""


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Emit cdf_coefficients.move.")
    parser.add_argument("--input", type=pathlib.Path, default=DERIVE_OUTPUT_PATH)
    parser.add_argument("--output", type=pathlib.Path, default=COEFF_OUTPUT_PATH)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Verify the committed file matches freshly generated output; exit 1 on "
        "drift, do not write. Requires a prior `derive` run for the JSON input.",
    )
    args = parser.parse_args(argv)

    if not args.input.exists():
        print(f"FAIL: missing {args.input} — run `python -m codegen.cdf.derive` first", file=sys.stderr)
        return 1

    raw = json.loads(args.input.read_text(encoding="utf-8"))

    num = [quantize(s) for s in raw["num_coeffs_str"]]
    den = [quantize(s) for s in raw["den_coeffs_str"]]
    text = emit_module(num, den)

    if args.check:
        if check_move(args.output, text):
            print(f"OK: {args.output.relative_to(REPO_ROOT)} is in sync")
            return 0
        print("FAIL: run `python -m codegen.cdf.emit_coefficients` to regenerate", file=sys.stderr)
        return 1

    print(f"Quantized {len(num)} numerator + {len(den)} denominator coefficients at WAD")
    write_move(args.output, text)
    print(f"Wrote {args.output.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
