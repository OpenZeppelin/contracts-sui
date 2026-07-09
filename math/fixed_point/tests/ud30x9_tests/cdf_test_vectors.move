// AUTO-GENERATED - do not hand-edit.
// Source: scripts/gaussian_codegen/cdf/emit_test_vectors.py (oracle: mpmath ncdf at 100 dps)

/// Deterministic test vectors for `ud30x9_base::cdf`. Each row asserts the
/// result of `ud30x9::wrap(z_raw).cdf()` matches `expected` to within
/// `TOLERANCE` raw UD30x9 ULPs (== 5 × 10^-9 absolute).
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
        TestCase { z_raw: 407_300_000, expected: 658_106_169 },
        TestCase { z_raw: 500_000_000, expected: 691_462_461 },
        TestCase { z_raw: 814_600_000, expected: 792_349_345 },
        TestCase { z_raw: 1_000_000_000, expected: 841_344_746 },
        TestCase { z_raw: 1_221_900_000, expected: 889_127_277 },
        TestCase { z_raw: 1_629_200_000, expected: 948_364_657 },
        TestCase { z_raw: 1_960_000_000, expected: 975_002_105 },
        TestCase { z_raw: 2_000_000_000, expected: 977_249_868 },
        TestCase { z_raw: 2_036_500_000, expected: 979_149_913 },
        TestCase { z_raw: 2_443_800_000, expected: 992_733_260 },
        TestCase { z_raw: 2_851_100_000, expected: 997_821_587 },
        TestCase { z_raw: 3_000_000_000, expected: 998_650_102 },
        TestCase { z_raw: 3_258_400_000, expected: 999_439_788 },
        TestCase { z_raw: 3_665_600_000, expected: 999_876_620 },
        TestCase { z_raw: 4_000_000_000, expected: 999_968_329 },
        TestCase { z_raw: 4_072_900_000, expected: 999_976_784 },
        TestCase { z_raw: 4_480_200_000, expected: 999_996_271 },
        TestCase { z_raw: 4_887_500_000, expected: 999_999_489 },
        TestCase { z_raw: 5_000_000_000, expected: 999_999_713 },
        TestCase { z_raw: 5_294_800_000, expected: 999_999_940 },
        TestCase { z_raw: 5_702_100_000, expected: 999_999_994 },
        TestCase { z_raw: 6_000_000_000, expected: 999_999_999 },
        TestCase { z_raw: 6_109_400_000, expected: 999_999_999 },
        TestCase { z_raw: 6_109_410_205, expected: 1_000_000_000 },
        TestCase { z_raw: 6_110_000_000, expected: 1_000_000_000 },
        TestCase { z_raw: 7_000_000_000, expected: 1_000_000_000 },
    ];
    cases.destroy!(|case| {
        let z = ud30x9::wrap(case.z_raw);
        let actual = z.cdf().unwrap();
        let diff = if (actual >= case.expected) actual - case.expected else case.expected - actual;
        assert!(diff <= TOLERANCE, ETestCaseFailed);
    });
}
