"""Emit test-vector Move files for both `sd29x9_base::inverse_cdf` and
`ud30x9_base::inverse_cdf`.

Picks a deterministic, hand-curated set of probability inputs:
- Well-known critical points (0.5, 0.75, 0.841344746, 0.975, 0.99, 0.999,
  0.999999999, 1.0, ...) - exercises the `Φ⁻¹(0.5) = 0` case, the central/tail
  seam at 0.975, the deep tail, and the saturation endpoint.
- 16 evenly spaced points across [0.5, 1] for breadth.
The signed (SD29x9) file additionally includes each point's reflection `1 - p`
(and `p = 0`), so it covers both tails via `Φ⁻¹(p) = -Φ⁻¹(1 - p)`.

For each `p` the expected `Φ⁻¹(p)` is computed at the SD29x9 raw scale (10^9) from
the mpmath `erfinv` oracle evaluated at the *quantized* input `p_raw / 10^9`
(matching what the on-chain code sees). Endpoints saturate: `p >= 1 → +MAX_Z`,
`p = 0 → -MAX_Z`.

Two output files are produced from the same source-of-truth case list:
- `tests/sd29x9_tests/inverse_cdf_test_vectors.move` - full signed range.
- `tests/ud30x9_tests/inverse_cdf_test_vectors.move` - upper half (`p >= 0.5`).
"""
from __future__ import annotations

import argparse
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
from gaussian_codegen.shared.reference import DPS, z_raw_at_decimal

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]

SD29X9_OUTPUT_PATH = (
    REPO_ROOT / "math" / "fixed_point" / "tests" / "sd29x9_tests" / "inverse_cdf_test_vectors.move"
)
UD30X9_OUTPUT_PATH = (
    REPO_ROOT / "math" / "fixed_point" / "tests" / "ud30x9_tests" / "inverse_cdf_test_vectors.move"
)

SCALE = constants.SCALE_DECIMAL
ONE_RAW = SCALE  # p = 1.0
HALF_RAW = constants.HALF_RAW  # p = 0.5
MAX_Z_RAW = constants.INVERSE_CDF_MAX_Z_RAW  # saturation clamp for |z|

# Critical probabilities on the upper half [0.5, 1]; the signed file adds their
# reflections 1 - p (and p = 0).
CRITICAL_P = [
    "0.5",
    "0.55",
    "0.6",
    "0.75",
    "0.841344746",  # Φ(1): expect z ≈ 1
    "0.9",
    "0.95",
    "0.975",  # central/tail seam
    "0.99",
    "0.999",
    "0.9999",
    "0.999999",
    "0.999999999",  # deepest representable: z ≈ 5.998
    "1.0",  # saturates to +MAX_Z
]


def quantize_p(p_str: str) -> int:
    """p at the raw 10^9 scale, nearest-rounded."""
    mp.dps = DPS
    return int(mpf(p_str) * mpf(SCALE) + mpf("0.5"))


def evenly_spaced_p(n: int = 16) -> list[str]:
    """n evenly spaced probabilities across [0.5, 1], as decimal strings."""
    return [str(round(0.5 + i * 0.5 / (n - 1), 9)) for i in range(n)]


def expected_z(p_raw: int) -> tuple[int, bool]:
    """`Φ⁻¹(p_raw / 10^9)` as (magnitude, is_negative) at the raw 10^9 scale.

    Saturation mirrors the on-chain bound: `p >= 1 → +MAX_Z`, `p = 0 → -MAX_Z`."""
    mp.dps = DPS
    if p_raw >= ONE_RAW:
        return MAX_Z_RAW, False
    if p_raw == 0:
        return MAX_Z_RAW, True
    return z_raw_at_decimal(mpf(p_raw) / mpf(SCALE))


def upper_raws() -> list[int]:
    """Sorted unique p_raw on the upper half [0.5, 1]."""
    seen = {quantize_p(s) for s in CRITICAL_P + evenly_spaced_p()}
    return sorted(p for p in seen if HALF_RAW <= p <= ONE_RAW)


def signed_cases() -> list[tuple[int, int, bool]]:
    """(p_raw, expected_mag, expected_neg) across the full range: the upper-half
    points plus their reflections 1 - p (and p = 0)."""
    uppers = upper_raws()
    raws = sorted({*uppers, *(ONE_RAW - u for u in uppers)})
    return [(p_raw, *expected_z(p_raw)) for p_raw in raws]


def upper_cases() -> list[tuple[int, int]]:
    """(p_raw, expected_mag) on the upper half [0.5, 1] (z >= 0)."""
    return [(p_raw, expected_z(p_raw)[0]) for p_raw in upper_raws()]


def emit_sd29x9_module(cases: list[tuple[int, int, bool]]) -> str:
    banner = auto_generated_banner(
        "scripts/gaussian_codegen/inverse_cdf/emit_test_vectors.py "
        "(oracle: mpmath erfinv at 100 dps)"
    )
    indent = "        "
    rendered = [
        f"TestCase {{ p_raw: {fmt_u128(p_raw)}, "
        f"expected_mag: {fmt_u128(mag)}, expected_neg: {'true' if neg else 'false'} }}"
        for p_raw, mag, neg in cases
    ]
    case_lines = f",\n{indent}".join(rendered)

    return f"""{banner}
/// Deterministic test vectors for `sd29x9_base::inverse_cdf`. Each row asserts
/// that `sd29x9::wrap(p_raw, false).inverse_cdf()` is within `TOLERANCE` raw
/// SD29x9 ULPs (== 5 × 10^-9 absolute) of the signed expected quantile.
module openzeppelin_fp_math::sd29x9_inverse_cdf_test_vectors;

use openzeppelin_fp_math::sd29x9;

const TOLERANCE: u128 = 5; // ≤ 5 ULP at SD29x9 scale (10^-9)

#[error(code = 0)]
const ETestCaseFailed: vector<u8> =
    "inverse_cdf test vector mismatch: actual value deviates from expected by more than the allowed tolerance";

public struct TestCase has copy, drop {{
    p_raw: u128,
    expected_mag: u128,
    expected_neg: bool,
}}

#[test]
fun inverse_cdf_vectors_match_oracle() {{
    let tol = sd29x9::wrap(TOLERANCE, false);
    let cases = vector[
        {case_lines},
    ];
    cases.destroy!(|case| {{
        let actual = sd29x9::wrap(case.p_raw, false).inverse_cdf();
        let expected = sd29x9::wrap(case.expected_mag, case.expected_neg);
        let diff = actual.sub(expected).abs();
        assert!(diff.lte(tol), ETestCaseFailed);
    }});
}}
"""


def emit_ud30x9_module(cases: list[tuple[int, int]]) -> str:
    banner = auto_generated_banner(
        "scripts/gaussian_codegen/inverse_cdf/emit_test_vectors.py "
        "(oracle: mpmath erfinv at 100 dps)"
    )
    indent = "        "
    rendered = [
        f"TestCase {{ p_raw: {fmt_u128(p_raw)}, expected: {fmt_u128(expected)} }}"
        for p_raw, expected in cases
    ]
    case_lines = f",\n{indent}".join(rendered)

    return f"""{banner}
/// Deterministic test vectors for `ud30x9_base::inverse_cdf`. Each row asserts
/// that `ud30x9::wrap(p_raw).inverse_cdf()` is within `TOLERANCE` raw UD30x9 ULPs
/// (== 5 × 10^-9 absolute) of the expected quantile, on the upper half `p ≥ 0.5`.
module openzeppelin_fp_math::ud30x9_inverse_cdf_test_vectors;

use openzeppelin_fp_math::ud30x9;

const TOLERANCE: u128 = 5; // ≤ 5 ULP at UD30x9 scale (10^-9)

#[error(code = 0)]
const ETestCaseFailed: vector<u8> =
    "inverse_cdf test vector mismatch: actual value deviates from expected by more than the allowed tolerance";

public struct TestCase has copy, drop {{
    p_raw: u128,
    expected: u128,
}}

#[test]
fun inverse_cdf_vectors_match_oracle() {{
    let cases = vector[
        {case_lines},
    ];
    cases.destroy!(|case| {{
        let actual = ud30x9::wrap(case.p_raw).inverse_cdf().unwrap();
        let diff = if (actual >= case.expected) actual - case.expected
        else case.expected - actual;
        assert!(diff <= TOLERANCE, ETestCaseFailed);
    }});
}}
"""


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Emit inverse_cdf test vector Move files for SD29x9 and UD30x9."
    )
    parser.add_argument("--sd29x9-output", type=pathlib.Path, default=SD29X9_OUTPUT_PATH)
    parser.add_argument("--ud30x9-output", type=pathlib.Path, default=UD30X9_OUTPUT_PATH)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Verify the committed files match freshly generated output; exit 1 on "
        "drift, do not write.",
    )
    args = parser.parse_args(argv)

    signed = signed_cases()
    upper = upper_cases()

    sd_text = format_move(emit_sd29x9_module(signed), args.sd29x9_output, REPO_ROOT)
    ud_text = format_move(emit_ud30x9_module(upper), args.ud30x9_output, REPO_ROOT)

    if args.check:
        ok = check_move(args.sd29x9_output, sd_text)
        ok = check_move(args.ud30x9_output, ud_text) and ok
        if ok:
            print(f"OK: SD29x9 ({len(signed)}) + UD30x9 ({len(upper)}) test vectors are in sync")
            return 0
        print(
            "FAIL: run `python -m gaussian_codegen.inverse_cdf.emit_test_vectors` to regenerate",
            file=sys.stderr,
        )
        return 1

    print(f"Generating {len(signed)} SD29x9 test vectors")
    print(f"Generating {len(upper)} UD30x9 test vectors (upper half)")
    write_move(args.sd29x9_output, sd_text)
    print(f"Wrote {rel_or_abs(args.sd29x9_output, REPO_ROOT)}")
    write_move(args.ud30x9_output, ud_text)
    print(f"Wrote {rel_or_abs(args.ud30x9_output, REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
