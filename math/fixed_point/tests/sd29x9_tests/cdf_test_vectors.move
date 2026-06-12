// AUTO-GENERATED — do not hand-edit.
// Source: math/fixed_point/codegen/cdf/emit_test_vectors.py (oracle: mpmath ncdf at 100 dps)

/// Deterministic test vectors for `sd29x9_base::cdf`. Each row asserts the
/// result of `sd29x9::wrap(z_raw, neg).cdf()` matches `expected` to within
/// `TOLERANCE` raw SD29x9 ULPs (== 5 × 10^-9 absolute).
#[test_only]
module openzeppelin_fp_math::sd29x9_cdf_test_vectors;

use openzeppelin_fp_math::sd29x9;

const TOLERANCE: u128 = 5; // ≤ 5 ULP at UD30x9 scale (10^-9)

#[error(code = 0)]
const ETestCaseFailed: vector<u8> =
    "cdf test vector mismatch: |actual - expected| exceeded TOLERANCE";

public struct TestCase has copy, drop {
    z_raw: u128,
    neg: bool,
    expected: u128,
}

#[test]
fun cdf_vectors_match_oracle() {
    let cases = vector[
        TestCase { z_raw: 0, neg: false, expected: 500_000_000 },
        TestCase { z_raw: 250_000_000, neg: false, expected: 598_706_326 },
        TestCase { z_raw: 420_000_000, neg: false, expected: 662_757_273 },
        TestCase { z_raw: 500_000_000, neg: false, expected: 691_462_461 },
        TestCase { z_raw: 840_000_000, neg: false, expected: 799_545_807 },
        TestCase { z_raw: 1_000_000_000, neg: false, expected: 841_344_746 },
        TestCase { z_raw: 1_260_000_000, neg: false, expected: 896_165_319 },
        TestCase { z_raw: 1_680_000_000, neg: false, expected: 953_521_342 },
        TestCase { z_raw: 1_960_000_000, neg: false, expected: 975_002_105 },
        TestCase { z_raw: 2_000_000_000, neg: false, expected: 977_249_868 },
        TestCase { z_raw: 2_100_000_000, neg: false, expected: 982_135_579 },
        TestCase { z_raw: 2_520_000_000, neg: false, expected: 994_132_258 },
        TestCase { z_raw: 2_940_000_000, neg: false, expected: 998_358_939 },
        TestCase { z_raw: 3_000_000_000, neg: false, expected: 998_650_102 },
        TestCase { z_raw: 3_360_000_000, neg: false, expected: 999_610_288 },
        TestCase { z_raw: 3_780_000_000, neg: false, expected: 999_921_586 },
        TestCase { z_raw: 4_000_000_000, neg: false, expected: 999_968_329 },
        TestCase { z_raw: 4_200_000_000, neg: false, expected: 999_986_654 },
        TestCase { z_raw: 4_620_000_000, neg: false, expected: 999_998_081 },
        TestCase { z_raw: 5_000_000_000, neg: false, expected: 999_999_713 },
        TestCase { z_raw: 5_040_000_000, neg: false, expected: 999_999_767 },
        TestCase { z_raw: 5_460_000_000, neg: false, expected: 999_999_976 },
        TestCase { z_raw: 5_880_000_000, neg: false, expected: 999_999_998 },
        TestCase { z_raw: 6_000_000_000, neg: false, expected: 999_999_999 },
        TestCase { z_raw: 6_299_000_000, neg: false, expected: 1_000_000_000 },
        TestCase { z_raw: 6_300_000_000, neg: false, expected: 1_000_000_000 },
        TestCase { z_raw: 6_301_000_000, neg: false, expected: 1_000_000_000 },
        TestCase { z_raw: 7_000_000_000, neg: false, expected: 1_000_000_000 },
        TestCase { z_raw: 250_000_000, neg: true, expected: 401_293_674 },
        TestCase { z_raw: 420_000_000, neg: true, expected: 337_242_727 },
        TestCase { z_raw: 500_000_000, neg: true, expected: 308_537_539 },
        TestCase { z_raw: 840_000_000, neg: true, expected: 200_454_193 },
        TestCase { z_raw: 1_000_000_000, neg: true, expected: 158_655_254 },
        TestCase { z_raw: 1_260_000_000, neg: true, expected: 103_834_681 },
        TestCase { z_raw: 1_680_000_000, neg: true, expected: 46_478_658 },
        TestCase { z_raw: 1_960_000_000, neg: true, expected: 24_997_895 },
        TestCase { z_raw: 2_000_000_000, neg: true, expected: 22_750_132 },
        TestCase { z_raw: 2_100_000_000, neg: true, expected: 17_864_421 },
        TestCase { z_raw: 2_520_000_000, neg: true, expected: 5_867_742 },
        TestCase { z_raw: 2_940_000_000, neg: true, expected: 1_641_061 },
        TestCase { z_raw: 3_000_000_000, neg: true, expected: 1_349_898 },
        TestCase { z_raw: 3_360_000_000, neg: true, expected: 389_712 },
        TestCase { z_raw: 3_780_000_000, neg: true, expected: 78_414 },
        TestCase { z_raw: 4_000_000_000, neg: true, expected: 31_671 },
        TestCase { z_raw: 4_200_000_000, neg: true, expected: 13_346 },
        TestCase { z_raw: 4_620_000_000, neg: true, expected: 1_919 },
        TestCase { z_raw: 5_000_000_000, neg: true, expected: 287 },
        TestCase { z_raw: 5_040_000_000, neg: true, expected: 233 },
        TestCase { z_raw: 5_460_000_000, neg: true, expected: 24 },
        TestCase { z_raw: 5_880_000_000, neg: true, expected: 2 },
        TestCase { z_raw: 6_000_000_000, neg: true, expected: 1 },
        TestCase { z_raw: 6_299_000_000, neg: true, expected: 0 },
        TestCase { z_raw: 6_300_000_000, neg: true, expected: 0 },
        TestCase { z_raw: 6_301_000_000, neg: true, expected: 0 },
        TestCase { z_raw: 7_000_000_000, neg: true, expected: 0 },
    ];
    cases.destroy!(|case| {
        let z = sd29x9::wrap(case.z_raw, case.neg);
        let actual = z.cdf().unwrap();
        let diff = if (actual >= case.expected) actual - case.expected else case.expected - actual;
        assert!(diff <= TOLERANCE, ETestCaseFailed);
    });
}
