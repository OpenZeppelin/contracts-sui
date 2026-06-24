// AUTO-GENERATED - do not hand-edit.
// Source: scripts/gaussian_codegen/pdf/emit_test_vectors.py (oracle: mpmath npdf at 100 dps)

/// Deterministic test vectors for `sd29x9_base::pdf`. Each row asserts the
/// result of `sd29x9::wrap(z_raw, neg).pdf()` matches `expected` to within
/// `TOLERANCE` raw SD29x9 ULPs (== 5 × 10^-9 absolute). Both signs of each `z`
/// share one `expected` value, checking that `pdf` is even.
module openzeppelin_fp_math::sd29x9_pdf_test_vectors;

use openzeppelin_fp_math::sd29x9;

const TOLERANCE: u128 = 5; // ≤ 5 ULP at UD30x9 scale (10^-9)

#[error(code = 0)]
const ETestCaseFailed: vector<u8> =
    "pdf test vector mismatch: |actual - expected| exceeded TOLERANCE";

public struct TestCase has copy, drop {
    z_raw: u128,
    neg: bool,
    expected: u128,
}

#[test]
fun pdf_vectors_match_oracle() {
    let cases = vector[
        TestCase { z_raw: 0, neg: false, expected: 398_942_280 },
        TestCase { z_raw: 250_000_000, neg: false, expected: 386_668_117 },
        TestCase { z_raw: 433_300_000, neg: false, expected: 363_195_879 },
        TestCase { z_raw: 500_000_000, neg: false, expected: 352_065_327 },
        TestCase { z_raw: 866_700_000, neg: false, expected: 274_028_551 },
        TestCase { z_raw: 1_000_000_000, neg: false, expected: 241_970_725 },
        TestCase { z_raw: 1_300_000_000, neg: false, expected: 171_368_592 },
        TestCase { z_raw: 1_733_300_000, neg: false, expected: 88_823_593 },
        TestCase { z_raw: 1_960_000_000, neg: false, expected: 58_440_944 },
        TestCase { z_raw: 2_000_000_000, neg: false, expected: 53_990_967 },
        TestCase { z_raw: 2_166_700_000, neg: false, expected: 38_149_868 },
        TestCase { z_raw: 2_600_000_000, neg: false, expected: 13_582_969 },
        TestCase { z_raw: 3_000_000_000, neg: false, expected: 4_431_848 },
        TestCase { z_raw: 3_033_300_000, neg: false, expected: 4_008_280 },
        TestCase { z_raw: 3_466_700_000, neg: false, expected: 980_015 },
        TestCase { z_raw: 3_900_000_000, neg: false, expected: 198_655 },
        TestCase { z_raw: 4_000_000_000, neg: false, expected: 133_830 },
        TestCase { z_raw: 4_333_300_000, neg: false, expected: 33_376 },
        TestCase { z_raw: 4_766_700_000, neg: false, expected: 4_645 },
        TestCase { z_raw: 5_000_000_000, neg: false, expected: 1_487 },
        TestCase { z_raw: 5_200_000_000, neg: false, expected: 536 },
        TestCase { z_raw: 5_633_300_000, neg: false, expected: 51 },
        TestCase { z_raw: 6_000_000_000, neg: false, expected: 6 },
        TestCase { z_raw: 6_066_700_000, neg: false, expected: 4 },
        TestCase { z_raw: 6_499_000_000, neg: false, expected: 0 },
        TestCase { z_raw: 6_500_000_000, neg: false, expected: 0 },
        TestCase { z_raw: 6_501_000_000, neg: false, expected: 0 },
        TestCase { z_raw: 7_000_000_000, neg: false, expected: 0 },
        TestCase { z_raw: 250_000_000, neg: true, expected: 386_668_117 },
        TestCase { z_raw: 433_300_000, neg: true, expected: 363_195_879 },
        TestCase { z_raw: 500_000_000, neg: true, expected: 352_065_327 },
        TestCase { z_raw: 866_700_000, neg: true, expected: 274_028_551 },
        TestCase { z_raw: 1_000_000_000, neg: true, expected: 241_970_725 },
        TestCase { z_raw: 1_300_000_000, neg: true, expected: 171_368_592 },
        TestCase { z_raw: 1_733_300_000, neg: true, expected: 88_823_593 },
        TestCase { z_raw: 1_960_000_000, neg: true, expected: 58_440_944 },
        TestCase { z_raw: 2_000_000_000, neg: true, expected: 53_990_967 },
        TestCase { z_raw: 2_166_700_000, neg: true, expected: 38_149_868 },
        TestCase { z_raw: 2_600_000_000, neg: true, expected: 13_582_969 },
        TestCase { z_raw: 3_000_000_000, neg: true, expected: 4_431_848 },
        TestCase { z_raw: 3_033_300_000, neg: true, expected: 4_008_280 },
        TestCase { z_raw: 3_466_700_000, neg: true, expected: 980_015 },
        TestCase { z_raw: 3_900_000_000, neg: true, expected: 198_655 },
        TestCase { z_raw: 4_000_000_000, neg: true, expected: 133_830 },
        TestCase { z_raw: 4_333_300_000, neg: true, expected: 33_376 },
        TestCase { z_raw: 4_766_700_000, neg: true, expected: 4_645 },
        TestCase { z_raw: 5_000_000_000, neg: true, expected: 1_487 },
        TestCase { z_raw: 5_200_000_000, neg: true, expected: 536 },
        TestCase { z_raw: 5_633_300_000, neg: true, expected: 51 },
        TestCase { z_raw: 6_000_000_000, neg: true, expected: 6 },
        TestCase { z_raw: 6_066_700_000, neg: true, expected: 4 },
        TestCase { z_raw: 6_499_000_000, neg: true, expected: 0 },
        TestCase { z_raw: 6_500_000_000, neg: true, expected: 0 },
        TestCase { z_raw: 6_501_000_000, neg: true, expected: 0 },
        TestCase { z_raw: 7_000_000_000, neg: true, expected: 0 },
    ];
    cases.destroy!(|case| {
        let z = sd29x9::wrap(case.z_raw, case.neg);
        let actual = z.pdf().unwrap();
        let diff = if (actual >= case.expected) actual - case.expected else case.expected - actual;
        assert!(diff <= TOLERANCE, ETestCaseFailed);
    });
}
