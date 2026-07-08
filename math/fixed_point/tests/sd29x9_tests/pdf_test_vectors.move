// AUTO-GENERATED - do not hand-edit.
// Source: scripts/gaussian_codegen/pdf/emit_test_vectors.py (oracle: mpmath npdf at 100 dps)

/// Deterministic test vectors for `sd29x9_base::pdf`. Each row asserts the
/// result of `sd29x9::wrap(z_raw, neg).pdf()` matches `expected` to within
/// `TOLERANCE` raw SD29x9 ULPs (== 5 × 10^-9 absolute). Both signs of each `z`
/// share one `expected` value, checking that `pdf` is even.
module openzeppelin_fp_math::sd29x9_pdf_test_vectors;

use openzeppelin_fp_math::sd29x9;

const TOLERANCE: u128 = 5; // ≤ 5 ULP at SD29x9 scale (10^-9)

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
        TestCase { z_raw: 426_800_000, neg: false, expected: 364_212_550 },
        TestCase { z_raw: 500_000_000, neg: false, expected: 352_065_327 },
        TestCase { z_raw: 853_700_000, neg: false, expected: 277_110_100 },
        TestCase { z_raw: 1_000_000_000, neg: false, expected: 241_970_725 },
        TestCase { z_raw: 1_280_500_000, neg: false, expected: 175_734_902 },
        TestCase { z_raw: 1_707_400_000, neg: false, expected: 92_870_808 },
        TestCase { z_raw: 1_960_000_000, neg: false, expected: 58_440_944 },
        TestCase { z_raw: 2_000_000_000, neg: false, expected: 53_990_967 },
        TestCase { z_raw: 2_134_200_000, neg: false, expected: 40_911_530 },
        TestCase { z_raw: 2_561_100_000, neg: false, expected: 15_017_259 },
        TestCase { z_raw: 2_987_900_000, neg: false, expected: 4_595_344 },
        TestCase { z_raw: 3_000_000_000, neg: false, expected: 4_431_848 },
        TestCase { z_raw: 3_414_800_000, neg: false, expected: 1_171_620 },
        TestCase { z_raw: 3_841_600_000, neg: false, expected: 249_043 },
        TestCase { z_raw: 4_000_000_000, neg: false, expected: 133_830 },
        TestCase { z_raw: 4_268_500_000, neg: false, expected: 44_103 },
        TestCase { z_raw: 4_695_300_000, neg: false, expected: 6_512 },
        TestCase { z_raw: 5_000_000_000, neg: false, expected: 1_487 },
        TestCase { z_raw: 5_122_200_000, neg: false, expected: 801 },
        TestCase { z_raw: 5_549_000_000, neg: false, expected: 82 },
        TestCase { z_raw: 5_975_900_000, neg: false, expected: 7 },
        TestCase { z_raw: 6_000_000_000, neg: false, expected: 6 },
        TestCase { z_raw: 6_402_700_000, neg: false, expected: 1 },
        TestCase { z_raw: 6_402_729_806, neg: false, expected: 0 },
        TestCase { z_raw: 6_410_000_000, neg: false, expected: 0 },
        TestCase { z_raw: 7_000_000_000, neg: false, expected: 0 },
        TestCase { z_raw: 250_000_000, neg: true, expected: 386_668_117 },
        TestCase { z_raw: 426_800_000, neg: true, expected: 364_212_550 },
        TestCase { z_raw: 500_000_000, neg: true, expected: 352_065_327 },
        TestCase { z_raw: 853_700_000, neg: true, expected: 277_110_100 },
        TestCase { z_raw: 1_000_000_000, neg: true, expected: 241_970_725 },
        TestCase { z_raw: 1_280_500_000, neg: true, expected: 175_734_902 },
        TestCase { z_raw: 1_707_400_000, neg: true, expected: 92_870_808 },
        TestCase { z_raw: 1_960_000_000, neg: true, expected: 58_440_944 },
        TestCase { z_raw: 2_000_000_000, neg: true, expected: 53_990_967 },
        TestCase { z_raw: 2_134_200_000, neg: true, expected: 40_911_530 },
        TestCase { z_raw: 2_561_100_000, neg: true, expected: 15_017_259 },
        TestCase { z_raw: 2_987_900_000, neg: true, expected: 4_595_344 },
        TestCase { z_raw: 3_000_000_000, neg: true, expected: 4_431_848 },
        TestCase { z_raw: 3_414_800_000, neg: true, expected: 1_171_620 },
        TestCase { z_raw: 3_841_600_000, neg: true, expected: 249_043 },
        TestCase { z_raw: 4_000_000_000, neg: true, expected: 133_830 },
        TestCase { z_raw: 4_268_500_000, neg: true, expected: 44_103 },
        TestCase { z_raw: 4_695_300_000, neg: true, expected: 6_512 },
        TestCase { z_raw: 5_000_000_000, neg: true, expected: 1_487 },
        TestCase { z_raw: 5_122_200_000, neg: true, expected: 801 },
        TestCase { z_raw: 5_549_000_000, neg: true, expected: 82 },
        TestCase { z_raw: 5_975_900_000, neg: true, expected: 7 },
        TestCase { z_raw: 6_000_000_000, neg: true, expected: 6 },
        TestCase { z_raw: 6_402_700_000, neg: true, expected: 1 },
        TestCase { z_raw: 6_402_729_806, neg: true, expected: 0 },
        TestCase { z_raw: 6_410_000_000, neg: true, expected: 0 },
        TestCase { z_raw: 7_000_000_000, neg: true, expected: 0 },
    ];
    cases.destroy!(|case| {
        let z = sd29x9::wrap(case.z_raw, case.neg);
        let actual = z.pdf().unwrap();
        let diff = if (actual >= case.expected) actual - case.expected else case.expected - actual;
        assert!(diff <= TOLERANCE, ETestCaseFailed);
    });
}
