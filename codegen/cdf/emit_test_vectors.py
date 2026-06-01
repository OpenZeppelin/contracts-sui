"""Emit test-vector Move files for both `sd29x9_base::cdf` and `ud30x9_base::cdf`.

Picks a deterministic, hand-curated set of test inputs:
- Well-known critical points (0, ±0.25, ±0.5, ±1, ±2, ±3, ±4, ±5, ±6, ±6.299,
  ±6.3, ±6.301, ±7) — exercises symmetry, the saturation boundary on both
  sides, and the Φ(0) bit-exact case.
- 16 evenly spaced points across [0, max_z] for breadth.

For each (z, sign) the expected Φ(z) value is computed at the UD30x9 raw scale
(10^9) using the mpmath oracle. Saturation cases (|z| > 6.3) get exact
endpoint values so the test exercises that branch in cdf.

Two output files are produced from the same source-of-truth case list:
- `tests/sd29x9_tests/cdf_test_vectors.move` — all cases (positive + negative).
- `tests/ud30x9_tests/cdf_test_vectors.move` — positive subset.

Both files are `#[test_only]`; each has one `#[test]` driver that iterates the
table and asserts `|actual − expected| ≤ TOLERANCE` (5 ULP).
"""
from __future__ import annotations

import argparse
import pathlib
import sys
from typing import Sequence

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from mpmath import mp, mpf  # noqa: E402

from codegen.shared.move_emit import (  # noqa: E402
    auto_generated_banner,
    fmt_u128,
    write_move,
)
from codegen.shared.reference import DPS, SCALE_DECIMAL, phi as phi_oracle  # noqa: E402

SD29X9_OUTPUT_PATH = (
    REPO_ROOT
    / "math"
    / "fixed_point"
    / "tests"
    / "sd29x9_tests"
    / "cdf_test_vectors.move"
)

UD30X9_OUTPUT_PATH = (
    REPO_ROOT
    / "math"
    / "fixed_point"
    / "tests"
    / "ud30x9_tests"
    / "cdf_test_vectors.move"
)

MAX_Z_RAW_DECIMAL = 6_300_000_000  # 6.3 at UD30x9 scale

CRITICAL_Z = [
    "0",
    "0.25",
    "0.5",
    "1",
    "1.96",
    "2",
    "3",
    "4",
    "5",
    "6",
    "6.299",
    "6.3",
    "6.301",
    "7",
]


def evenly_spaced_z(n: int = 16) -> list[str]:
    """n evenly spaced sample points across [0, 6.3], serialized as decimal strings
    so quantization to 10^9 is unambiguous."""
    return [str(round(i * 6.3 / (n - 1), 4)) for i in range(n)]


def expected_phi_raw(z_str: str, neg: bool) -> int:
    """Φ(±z) at the UD30x9 raw scale, with explicit saturation outside |z| ≤ 6.3."""
    mp.dps = DPS
    z = mpf(z_str)
    if z > mpf("6.3"):
        return 0 if neg else SCALE_DECIMAL
    phi_pos = phi_oracle(z)
    phi_signed = (mpf(1) - phi_pos) if neg else phi_pos
    return int(phi_signed * mpf(SCALE_DECIMAL) + mpf("0.5"))


def quantize_z(z_str: str) -> int:
    """|z| at the UD30x9 raw scale (10^9), nearest-rounded."""
    mp.dps = DPS
    return int(mpf(z_str) * mpf(SCALE_DECIMAL) + mpf("0.5"))


def build_test_cases() -> list[tuple[int, bool, int]]:
    """Build (z_raw, neg, expected_phi_raw) tuples, deduplicated and sorted."""
    seen: set[tuple[int, bool]] = set()
    cases: list[tuple[int, bool, int]] = []
    for z_str in CRITICAL_Z + evenly_spaced_z():
        z_raw = quantize_z(z_str)
        for neg in (False, True):
            if z_raw == 0 and neg:
                continue
            key = (z_raw, neg)
            if key in seen:
                continue
            seen.add(key)
            cases.append((z_raw, neg, expected_phi_raw(z_str, neg)))
    cases.sort(key=lambda c: (c[1], c[0]))
    return cases


def emit_sd29x9_module(cases: list[tuple[int, bool, int]]) -> str:
    banner = auto_generated_banner(
        "codegen/cdf/emit_test_vectors.py (oracle: mpmath ncdf at 100 dps)"
    )

    indent = "        "
    rendered = [
        f"TestCase {{ z_raw: {fmt_u128(z_raw)}, neg: {'true' if neg else 'false'}, expected: {fmt_u128(expected)} }}"
        for z_raw, neg, expected in cases
    ]
    case_lines = f",\n{indent}".join(rendered)

    return f"""{banner}
/// Deterministic test vectors for `sd29x9_base::cdf`. Each row asserts the
/// result of `sd29x9::wrap(z_raw, neg).cdf()` matches `expected` to within
/// `TOLERANCE` raw SD29x9 ULPs (== 5 × 10^-9 absolute).
#[test_only]
module openzeppelin_fp_math::sd29x9_cdf_test_vectors;

use openzeppelin_fp_math::sd29x9;

const TOLERANCE: u128 = 5; // ≤ 5 ULP at UD30x9 scale (10^-9)

const ETestCaseFailed: u64 = 0;

public struct TestCase has copy, drop {{
    z_raw: u128,
    neg: bool,
    expected: u128,
}}

#[test]
fun test_cdf_vectors() {{
    let cases = vector[
        {case_lines},
    ];
    let mut i = 0;
    let n = cases.length();
    while (i < n) {{
        let case = cases[i];
        let z = sd29x9::wrap(case.z_raw, case.neg);
        let actual = z.cdf().unwrap();
        let diff = if (actual >= case.expected) actual - case.expected else case.expected - actual;
        assert!(diff <= TOLERANCE, ETestCaseFailed);
        i = i + 1;
    }};
}}
"""


def emit_ud30x9_module(cases: list[tuple[int, bool, int]]) -> str:
    """UD30x9 variant: positive-only cases, no `neg` field."""
    banner = auto_generated_banner(
        "codegen/cdf/emit_test_vectors.py (oracle: mpmath ncdf at 100 dps)"
    )

    indent = "        "
    rendered = [
        f"TestCase {{ z_raw: {fmt_u128(z_raw)}, expected: {fmt_u128(expected)} }}"
        for z_raw, neg, expected in cases
        if not neg
    ]
    case_lines = f",\n{indent}".join(rendered)

    return f"""{banner}
/// Deterministic test vectors for `ud30x9_base::cdf`. Each row asserts the
/// result of `ud30x9::wrap(z_raw).cdf()` matches `expected` to within
/// `TOLERANCE` raw UD30x9 ULPs (== 5 × 10^-9 absolute).
#[test_only]
module openzeppelin_fp_math::ud30x9_cdf_test_vectors;

use openzeppelin_fp_math::ud30x9;

const TOLERANCE: u128 = 5; // ≤ 5 ULP at UD30x9 scale (10^-9)

const ETestCaseFailed: u64 = 0;

public struct TestCase has copy, drop {{
    z_raw: u128,
    expected: u128,
}}

#[test]
fun test_cdf_vectors() {{
    let cases = vector[
        {case_lines},
    ];
    let mut i = 0;
    let n = cases.length();
    while (i < n) {{
        let case = cases[i];
        let z = ud30x9::wrap(case.z_raw);
        let actual = z.cdf().unwrap();
        let diff = if (actual >= case.expected) actual - case.expected else case.expected - actual;
        assert!(diff <= TOLERANCE, ETestCaseFailed);
        i = i + 1;
    }};
}}
"""


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Emit cdf test vector Move files for SD29x9 and UD30x9."
    )
    parser.add_argument("--sd29x9-output", type=pathlib.Path, default=SD29X9_OUTPUT_PATH)
    parser.add_argument("--ud30x9-output", type=pathlib.Path, default=UD30X9_OUTPUT_PATH)
    args = parser.parse_args(argv)

    cases = build_test_cases()
    positive_cases = [c for c in cases if not c[1]]
    print(f"Generating {len(cases)} SD29x9 test vectors")
    print(f"Generating {len(positive_cases)} UD30x9 test vectors (positive subset)")

    sd_text = emit_sd29x9_module(cases)
    write_move(args.sd29x9_output, sd_text)
    print(f"Wrote {args.sd29x9_output.relative_to(REPO_ROOT)}")

    ud_text = emit_ud30x9_module(cases)
    write_move(args.ud30x9_output, ud_text)
    print(f"Wrote {args.ud30x9_output.relative_to(REPO_ROOT)}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
