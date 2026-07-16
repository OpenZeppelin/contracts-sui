// AUTO-GENERATED - do not hand-edit.
// Source: scripts/gaussian_codegen/inverse_cdf/emit_test_vectors.py (oracle: mpmath erfinv at 100 dps)

/// Deterministic test vectors for `sd29x9_base::inverse_cdf`. Each row asserts
/// that `sd29x9::wrap(p_raw, false).inverse_cdf()` is within `TOLERANCE` raw
/// SD29x9 ULPs (== 5 × 10^-9 absolute) of the signed expected quantile.
module openzeppelin_fp_math::sd29x9_inverse_cdf_test_vectors;

use openzeppelin_fp_math::sd29x9;

const TOLERANCE: u128 = 5; // ≤ 5 ULP at SD29x9 scale (10^-9)

#[error(code = 0)]
const ETestCaseFailed: vector<u8> =
    "inverse_cdf test vector mismatch: actual value deviates from expected by more than the allowed tolerance";

public struct TestCase has copy, drop {
    p_raw: u128,
    expected_mag: u128,
    expected_neg: bool,
}

#[test]
fun inverse_cdf_vectors_match_oracle() {
    let tol = sd29x9::wrap(TOLERANCE, false);
    let cases = vector[
        TestCase { p_raw: 0, expected_mag: 6_109_410_205, expected_neg: true },
        TestCase { p_raw: 1, expected_mag: 5_997_807_015, expected_neg: true },
        TestCase { p_raw: 1_000, expected_mag: 4_753_424_309, expected_neg: true },
        TestCase { p_raw: 100_000, expected_mag: 3_719_016_485, expected_neg: true },
        TestCase { p_raw: 1_000_000, expected_mag: 3_090_232_306, expected_neg: true },
        TestCase { p_raw: 10_000_000, expected_mag: 2_326_347_874, expected_neg: true },
        TestCase { p_raw: 25_000_000, expected_mag: 1_959_963_985, expected_neg: true },
        TestCase { p_raw: 33_333_333, expected_mag: 1_833_914_640, expected_neg: true },
        TestCase { p_raw: 50_000_000, expected_mag: 1_644_853_627, expected_neg: true },
        TestCase { p_raw: 66_666_667, expected_mag: 1_501_085_943, expected_neg: true },
        TestCase { p_raw: 100_000_000, expected_mag: 1_281_551_566, expected_neg: true },
        TestCase { p_raw: 133_333_333, expected_mag: 1_110_771_618, expected_neg: true },
        TestCase { p_raw: 158_655_254, expected_mag: 1_000_000_000, expected_neg: true },
        TestCase { p_raw: 166_666_667, expected_mag: 967_421_565, expected_neg: true },
        TestCase { p_raw: 200_000_000, expected_mag: 841_621_234, expected_neg: true },
        TestCase { p_raw: 233_333_333, expected_mag: 727_913_292, expected_neg: true },
        TestCase { p_raw: 250_000_000, expected_mag: 674_489_750, expected_neg: true },
        TestCase { p_raw: 266_666_667, expected_mag: 622_925_722, expected_neg: true },
        TestCase { p_raw: 300_000_000, expected_mag: 524_400_513, expected_neg: true },
        TestCase { p_raw: 333_333_333, expected_mag: 430_727_300, expected_neg: true },
        TestCase { p_raw: 366_666_667, expected_mag: 340_694_826, expected_neg: true },
        TestCase { p_raw: 400_000_000, expected_mag: 253_347_103, expected_neg: true },
        TestCase { p_raw: 433_333_333, expected_mag: 167_894_006, expected_neg: true },
        TestCase { p_raw: 450_000_000, expected_mag: 125_661_347, expected_neg: true },
        TestCase { p_raw: 466_666_667, expected_mag: 83_651_733, expected_neg: true },
        TestCase { p_raw: 500_000_000, expected_mag: 0, expected_neg: false },
        TestCase { p_raw: 533_333_333, expected_mag: 83_651_733, expected_neg: false },
        TestCase { p_raw: 550_000_000, expected_mag: 125_661_347, expected_neg: false },
        TestCase { p_raw: 566_666_667, expected_mag: 167_894_006, expected_neg: false },
        TestCase { p_raw: 600_000_000, expected_mag: 253_347_103, expected_neg: false },
        TestCase { p_raw: 633_333_333, expected_mag: 340_694_826, expected_neg: false },
        TestCase { p_raw: 666_666_667, expected_mag: 430_727_300, expected_neg: false },
        TestCase { p_raw: 700_000_000, expected_mag: 524_400_513, expected_neg: false },
        TestCase { p_raw: 733_333_333, expected_mag: 622_925_722, expected_neg: false },
        TestCase { p_raw: 750_000_000, expected_mag: 674_489_750, expected_neg: false },
        TestCase { p_raw: 766_666_667, expected_mag: 727_913_292, expected_neg: false },
        TestCase { p_raw: 800_000_000, expected_mag: 841_621_234, expected_neg: false },
        TestCase { p_raw: 833_333_333, expected_mag: 967_421_565, expected_neg: false },
        TestCase { p_raw: 841_344_746, expected_mag: 1_000_000_000, expected_neg: false },
        TestCase { p_raw: 866_666_667, expected_mag: 1_110_771_618, expected_neg: false },
        TestCase { p_raw: 900_000_000, expected_mag: 1_281_551_566, expected_neg: false },
        TestCase { p_raw: 933_333_333, expected_mag: 1_501_085_943, expected_neg: false },
        TestCase { p_raw: 950_000_000, expected_mag: 1_644_853_627, expected_neg: false },
        TestCase { p_raw: 966_666_667, expected_mag: 1_833_914_640, expected_neg: false },
        TestCase { p_raw: 975_000_000, expected_mag: 1_959_963_985, expected_neg: false },
        TestCase { p_raw: 990_000_000, expected_mag: 2_326_347_874, expected_neg: false },
        TestCase { p_raw: 999_000_000, expected_mag: 3_090_232_306, expected_neg: false },
        TestCase { p_raw: 999_900_000, expected_mag: 3_719_016_485, expected_neg: false },
        TestCase { p_raw: 999_999_000, expected_mag: 4_753_424_309, expected_neg: false },
        TestCase { p_raw: 999_999_999, expected_mag: 5_997_807_015, expected_neg: false },
        TestCase { p_raw: 1_000_000_000, expected_mag: 6_109_410_205, expected_neg: false },
    ];
    cases.destroy!(|case| {
        let actual = sd29x9::wrap(case.p_raw, false).inverse_cdf();
        let expected = sd29x9::wrap(case.expected_mag, case.expected_neg);
        let diff = actual.sub(expected).abs();
        assert!(diff.lte(tol), ETestCaseFailed);
    });
}
