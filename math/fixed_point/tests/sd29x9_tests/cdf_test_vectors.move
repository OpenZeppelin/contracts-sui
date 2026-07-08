// AUTO-GENERATED - do not hand-edit.
// Source: scripts/gaussian_codegen/cdf/emit_test_vectors.py (oracle: mpmath ncdf at 100 dps)

/// Deterministic test vectors for `sd29x9_base::cdf`. Each row asserts the
/// result of `sd29x9::wrap(z_raw, neg).cdf()` matches `expected` to within
/// `TOLERANCE` raw SD29x9 ULPs (== 5 × 10^-9 absolute).
module openzeppelin_fp_math::sd29x9_cdf_test_vectors;

use openzeppelin_fp_math::sd29x9;

const TOLERANCE: u128 = 5; // ≤ 5 ULP at SD29x9 scale (10^-9)

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
        TestCase { z_raw: 407_300_000, neg: false, expected: 658_106_169 },
        TestCase { z_raw: 500_000_000, neg: false, expected: 691_462_461 },
        TestCase { z_raw: 814_600_000, neg: false, expected: 792_349_345 },
        TestCase { z_raw: 1_000_000_000, neg: false, expected: 841_344_746 },
        TestCase { z_raw: 1_221_900_000, neg: false, expected: 889_127_277 },
        TestCase { z_raw: 1_629_200_000, neg: false, expected: 948_364_657 },
        TestCase { z_raw: 1_960_000_000, neg: false, expected: 975_002_105 },
        TestCase { z_raw: 2_000_000_000, neg: false, expected: 977_249_868 },
        TestCase { z_raw: 2_036_500_000, neg: false, expected: 979_149_913 },
        TestCase { z_raw: 2_443_800_000, neg: false, expected: 992_733_260 },
        TestCase { z_raw: 2_851_100_000, neg: false, expected: 997_821_587 },
        TestCase { z_raw: 3_000_000_000, neg: false, expected: 998_650_102 },
        TestCase { z_raw: 3_258_400_000, neg: false, expected: 999_439_788 },
        TestCase { z_raw: 3_665_600_000, neg: false, expected: 999_876_620 },
        TestCase { z_raw: 4_000_000_000, neg: false, expected: 999_968_329 },
        TestCase { z_raw: 4_072_900_000, neg: false, expected: 999_976_784 },
        TestCase { z_raw: 4_480_200_000, neg: false, expected: 999_996_271 },
        TestCase { z_raw: 4_887_500_000, neg: false, expected: 999_999_489 },
        TestCase { z_raw: 5_000_000_000, neg: false, expected: 999_999_713 },
        TestCase { z_raw: 5_294_800_000, neg: false, expected: 999_999_940 },
        TestCase { z_raw: 5_702_100_000, neg: false, expected: 999_999_994 },
        TestCase { z_raw: 6_000_000_000, neg: false, expected: 999_999_999 },
        TestCase { z_raw: 6_109_400_000, neg: false, expected: 999_999_999 },
        TestCase { z_raw: 6_109_410_205, neg: false, expected: 1_000_000_000 },
        TestCase { z_raw: 6_110_000_000, neg: false, expected: 1_000_000_000 },
        TestCase { z_raw: 7_000_000_000, neg: false, expected: 1_000_000_000 },
        TestCase { z_raw: 250_000_000, neg: true, expected: 401_293_674 },
        TestCase { z_raw: 407_300_000, neg: true, expected: 341_893_831 },
        TestCase { z_raw: 500_000_000, neg: true, expected: 308_537_539 },
        TestCase { z_raw: 814_600_000, neg: true, expected: 207_650_655 },
        TestCase { z_raw: 1_000_000_000, neg: true, expected: 158_655_254 },
        TestCase { z_raw: 1_221_900_000, neg: true, expected: 110_872_723 },
        TestCase { z_raw: 1_629_200_000, neg: true, expected: 51_635_343 },
        TestCase { z_raw: 1_960_000_000, neg: true, expected: 24_997_895 },
        TestCase { z_raw: 2_000_000_000, neg: true, expected: 22_750_132 },
        TestCase { z_raw: 2_036_500_000, neg: true, expected: 20_850_087 },
        TestCase { z_raw: 2_443_800_000, neg: true, expected: 7_266_740 },
        TestCase { z_raw: 2_851_100_000, neg: true, expected: 2_178_413 },
        TestCase { z_raw: 3_000_000_000, neg: true, expected: 1_349_898 },
        TestCase { z_raw: 3_258_400_000, neg: true, expected: 560_212 },
        TestCase { z_raw: 3_665_600_000, neg: true, expected: 123_380 },
        TestCase { z_raw: 4_000_000_000, neg: true, expected: 31_671 },
        TestCase { z_raw: 4_072_900_000, neg: true, expected: 23_216 },
        TestCase { z_raw: 4_480_200_000, neg: true, expected: 3_729 },
        TestCase { z_raw: 4_887_500_000, neg: true, expected: 511 },
        TestCase { z_raw: 5_000_000_000, neg: true, expected: 287 },
        TestCase { z_raw: 5_294_800_000, neg: true, expected: 60 },
        TestCase { z_raw: 5_702_100_000, neg: true, expected: 6 },
        TestCase { z_raw: 6_000_000_000, neg: true, expected: 1 },
        TestCase { z_raw: 6_109_400_000, neg: true, expected: 1 },
        TestCase { z_raw: 6_109_410_205, neg: true, expected: 0 },
        TestCase { z_raw: 6_110_000_000, neg: true, expected: 0 },
        TestCase { z_raw: 7_000_000_000, neg: true, expected: 0 },
    ];
    cases.destroy!(|case| {
        let z = sd29x9::wrap(case.z_raw, case.neg);
        let actual = z.cdf().unwrap();
        let diff = if (actual >= case.expected) actual - case.expected else case.expected - actual;
        assert!(diff <= TOLERANCE, ETestCaseFailed);
    });
}
