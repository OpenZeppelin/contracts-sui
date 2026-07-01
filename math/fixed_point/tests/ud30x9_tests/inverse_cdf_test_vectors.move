// AUTO-GENERATED - do not hand-edit.
// Source: scripts/gaussian_codegen/inverse_cdf/emit_test_vectors.py (oracle: mpmath erfinv at 100 dps)

/// Deterministic test vectors for `ud30x9_base::inverse_cdf`. Each row asserts
/// that `ud30x9::wrap(p_raw).inverse_cdf()` is within `TOLERANCE` raw UD30x9 ULPs
/// (== 5 × 10^-9 absolute) of the expected quantile, on the upper half `p ≥ 0.5`.
module openzeppelin_fp_math::ud30x9_inverse_cdf_test_vectors;

use openzeppelin_fp_math::ud30x9;

const TOLERANCE: u128 = 5; // ≤ 5 ULP at UD30x9 scale (10^-9)

#[error(code = 0)]
const ETestCaseFailed: vector<u8> =
    "inverse_cdf test vector mismatch: |actual - expected| exceeded TOLERANCE";

public struct TestCase has copy, drop {
    p_raw: u128,
    expected: u128,
}

#[test]
fun inverse_cdf_vectors_match_oracle() {
    let cases = vector[
        TestCase { p_raw: 500_000_000, expected: 0 },
        TestCase { p_raw: 533_333_333, expected: 83_651_733 },
        TestCase { p_raw: 550_000_000, expected: 125_661_347 },
        TestCase { p_raw: 566_666_667, expected: 167_894_006 },
        TestCase { p_raw: 600_000_000, expected: 253_347_103 },
        TestCase { p_raw: 633_333_333, expected: 340_694_826 },
        TestCase { p_raw: 666_666_667, expected: 430_727_300 },
        TestCase { p_raw: 700_000_000, expected: 524_400_513 },
        TestCase { p_raw: 733_333_333, expected: 622_925_722 },
        TestCase { p_raw: 750_000_000, expected: 674_489_750 },
        TestCase { p_raw: 766_666_667, expected: 727_913_292 },
        TestCase { p_raw: 800_000_000, expected: 841_621_234 },
        TestCase { p_raw: 833_333_333, expected: 967_421_565 },
        TestCase { p_raw: 841_344_746, expected: 1_000_000_000 },
        TestCase { p_raw: 866_666_667, expected: 1_110_771_618 },
        TestCase { p_raw: 900_000_000, expected: 1_281_551_566 },
        TestCase { p_raw: 933_333_333, expected: 1_501_085_943 },
        TestCase { p_raw: 950_000_000, expected: 1_644_853_627 },
        TestCase { p_raw: 966_666_667, expected: 1_833_914_640 },
        TestCase { p_raw: 975_000_000, expected: 1_959_963_985 },
        TestCase { p_raw: 990_000_000, expected: 2_326_347_874 },
        TestCase { p_raw: 999_000_000, expected: 3_090_232_306 },
        TestCase { p_raw: 999_900_000, expected: 3_719_016_485 },
        TestCase { p_raw: 999_999_000, expected: 4_753_424_309 },
        TestCase { p_raw: 999_999_999, expected: 5_997_807_015 },
        TestCase { p_raw: 1_000_000_000, expected: 6_300_000_000 },
    ];
    cases.destroy!(|case| {
        let actual = ud30x9::wrap(case.p_raw).inverse_cdf().unwrap();
        let diff = if (actual >= case.expected) actual - case.expected else case.expected - actual;
        assert!(diff <= TOLERANCE, ETestCaseFailed);
    });
}
