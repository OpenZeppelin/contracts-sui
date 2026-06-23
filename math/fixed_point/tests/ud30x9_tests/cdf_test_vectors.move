// AUTO-GENERATED - do not hand-edit.
// Source: scripts/gaussian_codegen/cdf/emit_test_vectors.py (oracle: mpmath ncdf at 100 dps)

/// Deterministic test vectors for `ud30x9_base::cdf`. Each row asserts the
/// result of `ud30x9::wrap(z_raw).cdf()` matches `expected` to within
/// `TOLERANCE` raw UD30x9 ULPs (== 5 × 10^-9 absolute).
#[test_only]
module openzeppelin_fp_math::ud30x9_cdf_test_vectors;

use openzeppelin_fp_math::ud30x9;

const TOLERANCE: u128 = 5; // ≤ 5 ULP at UD30x9 scale (10^-9)

#[error(code = 0)]
const ETestCaseFailed: vector<u8> =
    "cdf test vector mismatch: |actual - expected| exceeded TOLERANCE";

public struct TestCase has copy, drop {
    z_raw: u128,
    expected: u128,
}

#[test]
fun cdf_vectors_match_oracle() {
    let cases = vector[
        TestCase { z_raw: 0, expected: 500_000_000 },
        TestCase { z_raw: 250_000_000, expected: 598_706_326 },
        TestCase { z_raw: 420_000_000, expected: 662_757_273 },
        TestCase { z_raw: 500_000_000, expected: 691_462_461 },
        TestCase { z_raw: 840_000_000, expected: 799_545_807 },
        TestCase { z_raw: 1_000_000_000, expected: 841_344_746 },
        TestCase { z_raw: 1_260_000_000, expected: 896_165_319 },
        TestCase { z_raw: 1_680_000_000, expected: 953_521_342 },
        TestCase { z_raw: 1_960_000_000, expected: 975_002_105 },
        TestCase { z_raw: 2_000_000_000, expected: 977_249_868 },
        TestCase { z_raw: 2_100_000_000, expected: 982_135_579 },
        TestCase { z_raw: 2_520_000_000, expected: 994_132_258 },
        TestCase { z_raw: 2_940_000_000, expected: 998_358_939 },
        TestCase { z_raw: 3_000_000_000, expected: 998_650_102 },
        TestCase { z_raw: 3_360_000_000, expected: 999_610_288 },
        TestCase { z_raw: 3_780_000_000, expected: 999_921_586 },
        TestCase { z_raw: 4_000_000_000, expected: 999_968_329 },
        TestCase { z_raw: 4_200_000_000, expected: 999_986_654 },
        TestCase { z_raw: 4_620_000_000, expected: 999_998_081 },
        TestCase { z_raw: 5_000_000_000, expected: 999_999_713 },
        TestCase { z_raw: 5_040_000_000, expected: 999_999_767 },
        TestCase { z_raw: 5_460_000_000, expected: 999_999_976 },
        TestCase { z_raw: 5_880_000_000, expected: 999_999_998 },
        TestCase { z_raw: 6_000_000_000, expected: 999_999_999 },
        TestCase { z_raw: 6_299_000_000, expected: 1_000_000_000 },
        TestCase { z_raw: 6_300_000_000, expected: 1_000_000_000 },
        TestCase { z_raw: 6_301_000_000, expected: 1_000_000_000 },
        TestCase { z_raw: 7_000_000_000, expected: 1_000_000_000 },
    ];
    cases.destroy!(|case| {
        let z = ud30x9::wrap(case.z_raw);
        let actual = z.cdf().unwrap();
        let diff = if (actual >= case.expected) actual - case.expected else case.expected - actual;
        assert!(diff <= TOLERANCE, ETestCaseFailed);
    });
}
