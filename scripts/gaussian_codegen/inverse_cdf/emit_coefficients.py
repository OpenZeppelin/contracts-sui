"""Read derive.py output, quantize each coefficient to (u128 magnitude, bool sign)
at WAD scale, and emit `inverse_cdf_coefficients.move`.

Unlike `cdf`/`pdf` (one rational), the quantile is split into two regions, so this
module emits two coefficient sets:
- `CENTRAL_{NUM,DEN}_{MAGS,NEGS}` - rational in `u = p - 0.5` for `p < SPLIT`.
- `TAIL_{NUM,DEN}_{MAGS,NEGS}` - rational in `r = sqrt(-2 ln(1 - p))` for `p ≥ SPLIT`.
Both are parallel `vector<u128>`/`vector<bool>` arrays in ascending power order
(index 0 = constant term), at WAD (`10^18`) scale.

Plus two scalars: `CENTRAL_THRESHOLD_RAW` (the `p` split point at `10^9` scale) and
`MAX_Z_RAW` (the `|z|` output saturation clamp at `10^9` scale).
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
from typing import Sequence

from gaussian_codegen.shared.move_emit import (
    auto_generated_banner,
    check_move,
    fmt_u128,
    format_move,
    quantize,
    rel_or_abs,
    render_vector,
    write_move,
)

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]

DERIVE_OUTPUT_PATH = pathlib.Path(__file__).parent / ".derive_output.json"
COEFF_OUTPUT_PATH = (
    REPO_ROOT / "math" / "fixed_point" / "sources" / "internal" / "inverse_cdf_coefficients.move"
)


def _region_vectors(region: dict, prefix: str) -> str:
    """Render the four sign-magnitude vector constants for one region."""
    num = [quantize(s) for s in region["num_coeffs_str"]]
    den = [quantize(s) for s in region["den_coeffs_str"]]
    return "\n\n".join(
        [
            render_vector(f"{prefix}_NUM_MAGS", "u128", [fmt_u128(m) for m, _ in num]),
            render_vector(f"{prefix}_NUM_NEGS", "bool", ["true" if n else "false" for _, n in num]),
            render_vector(f"{prefix}_DEN_MAGS", "u128", [fmt_u128(m) for m, _ in den]),
            render_vector(f"{prefix}_DEN_NEGS", "bool", ["true" if n else "false" for _, n in den]),
        ]
    )


def emit_module(raw: dict) -> str:
    banner = auto_generated_banner(
        "scripts/gaussian_codegen/inverse_cdf/derive.py + "
        "scripts/gaussian_codegen/inverse_cdf/emit_coefficients.py"
    )
    central = _region_vectors(raw["central"], "CENTRAL")
    tail = _region_vectors(raw["tail"], "TAIL")
    threshold_raw = int(raw["split_raw"])
    max_z_raw = int(raw["max_z_raw"])

    return f"""{banner}
/// Numerator and denominator coefficients for the two-region standard-normal
/// quantile (inverse CDF) rational on the upper half
/// `p ∈ [0.5, 1)`. All values are sign-magnitude pairs at WAD (`10^18`) scale,
/// indexed in ascending power order (index 0 is the constant term).
///
/// - `CENTRAL_*`: the rational in `u = p - 0.5`, used for
///   `p < CENTRAL_THRESHOLD`.
/// - `TAIL_*`: the rational in `r = sqrt(-2 * ln(1 - p))`, used for
///   `p >= CENTRAL_THRESHOLD`; the change of variable linearizes the tail so a
///   low-degree rational stays well-conditioned where a single rational in `p`
///   would underflow. The evaluator supplies `r` directly at WAD scale.
///
/// Accessors return the underlying `vector<u128>` / `vector<bool>` constants so
/// callers can bind them to a local once per evaluation and index locally inside
/// the Horner loop - avoiding a fresh constant load on every iteration.
///
/// See `inverse_cdf` for the consumer API. This module is regenerated from the
/// fits in `scripts/gaussian_codegen/inverse_cdf/`; do not hand-edit.
module openzeppelin_fp_math::inverse_cdf_coefficients;

// === Constants ===

{central}

{tail}

/// Probability split between the central and tail rationals, at the raw `10^9`
/// scale: inputs with `p < this` use the central fit (in `u = p - 0.5`), inputs
/// with `p >= this` use the tail fit (in `r = sqrt(-2 ln(1 - p))`).
const CENTRAL_THRESHOLD_RAW: u128 = {fmt_u128(threshold_raw)};

/// Output saturation clamp `|z|` at the raw `10^9` scale: `inverse_cdf(1)` (and,
/// reflected, `inverse_cdf(0)`) returns this instead of the unrepresentable
/// `±∞`. Equal to the CDF domain bound `cdf_coefficients::max_z_raw()` so
/// `cdf`/`inverse_cdf` agree at the corner: the quantile saturates at the
/// smallest `|z|` the CDF already resolves to exactly `1` (resp. `0`).
const MAX_Z_RAW: u128 = {fmt_u128(max_z_raw)};

// === Package Functions ===

/// Central-region numerator magnitudes (ascending power order).
public(package) fun central_num_mags(): vector<u128> {{ CENTRAL_NUM_MAGS }}

/// Central-region numerator sign flags; index `i` paired with `central_num_mags()[i]`.
public(package) fun central_num_negs(): vector<bool> {{ CENTRAL_NUM_NEGS }}

/// Central-region denominator magnitudes (ascending power order).
public(package) fun central_den_mags(): vector<u128> {{ CENTRAL_DEN_MAGS }}

/// Central-region denominator sign flags; index `i` paired with `central_den_mags()[i]`.
public(package) fun central_den_negs(): vector<bool> {{ CENTRAL_DEN_NEGS }}

/// Tail-region numerator magnitudes (ascending power order).
public(package) fun tail_num_mags(): vector<u128> {{ TAIL_NUM_MAGS }}

/// Tail-region numerator sign flags; index `i` paired with `tail_num_mags()[i]`.
public(package) fun tail_num_negs(): vector<bool> {{ TAIL_NUM_NEGS }}

/// Tail-region denominator magnitudes (ascending power order).
public(package) fun tail_den_mags(): vector<u128> {{ TAIL_DEN_MAGS }}

/// Tail-region denominator sign flags; index `i` paired with `tail_den_mags()[i]`.
public(package) fun tail_den_negs(): vector<bool> {{ TAIL_DEN_NEGS }}

/// Central-vs-tail probability split at the raw `10^9` scale (`975_000_000`).
public(package) fun central_threshold_raw(): u128 {{ CENTRAL_THRESHOLD_RAW }}

/// Output saturation clamp `|z|` at the raw `10^9` scale (`{fmt_u128(max_z_raw)}`).
public(package) fun max_z_raw(): u128 {{ MAX_Z_RAW }}
"""


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Emit inverse_cdf_coefficients.move.")
    parser.add_argument("--input", type=pathlib.Path, default=DERIVE_OUTPUT_PATH)
    parser.add_argument("--output", type=pathlib.Path, default=COEFF_OUTPUT_PATH)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Verify the committed file matches freshly generated output; exit 1 on "
        "drift, do not write. Reads the committed `.derive_output.json`.",
    )
    args = parser.parse_args(argv)

    if not args.input.exists():
        print(
            f"FAIL: missing {args.input} - run `python -m gaussian_codegen.inverse_cdf.derive` first",
            file=sys.stderr,
        )
        return 1

    raw = json.loads(args.input.read_text(encoding="utf-8"))
    text = emit_module(raw)
    text = format_move(text, args.output, REPO_ROOT)

    if args.check:
        if check_move(args.output, text):
            print(f"OK: {rel_or_abs(args.output, REPO_ROOT)} is in sync")
            return 0
        print(
            "FAIL: run `python -m gaussian_codegen.inverse_cdf.emit_coefficients` to regenerate",
            file=sys.stderr,
        )
        return 1

    n_central = raw["central"]["n_coeffs"]
    n_tail = raw["tail"]["n_coeffs"]
    print(f"Quantized central ({n_central}) + tail ({n_tail}) coefficient pairs at WAD")
    write_move(args.output, text)
    print(f"Wrote {rel_or_abs(args.output, REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
