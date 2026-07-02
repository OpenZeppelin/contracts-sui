module openzeppelin_fp_math::pdf_monotonicity_tests;

use openzeppelin_fp_math::sd29x9_test_helpers::{neg, pos};
use openzeppelin_fp_math::ud30x9_test_helpers::fixed;
use std::unit_test::assert_eq;

// Neighbor-resolution monotonicity for `φ`: the density is non-increasing in |z|,
// so the output must never rise between *adjacent* representable inputs (1 raw
// ULP, 10^-9, apart). The offline codegen gate
// (`pdf/validate.check_neighbor_monotonicity`) proves this exhaustively over the
// whole tail; these in-VM windows confirm the deployed Move evaluator agrees at
// the historically at-risk points. Before the 10^36 accumulation scale,
// floor-truncation noise produced 1-ULP up-blips clustered in this mid-tail band;
// the coarse 64-point grid sweeps elsewhere step ~10^8 raw inputs apart and
// cannot see them.
//
// Each window scans 1,000 consecutive raw inputs in its own test - the Move VM's
// per-test budget does not allow folding every window into one loop.

const WINDOW: u64 = 1_000;
const PDF_0_RAW: u128 = 398_942_280; // φ(0), the peak

// Scan `count` consecutive raw inputs upward from `start`, asserting φ is
// non-increasing between every neighbor.
fun assert_neighbor_monotone(start: u128, count: u64) {
    let mut prev = fixed(start - 1).pdf().unwrap();
    count.do!(|off| {
        let curr = fixed(start + (off as u128)).pdf().unwrap();
        assert!(curr <= prev);
        prev = curr;
    });
}

#[test]
fun monotone_in_mid_tail() {
    // z ≈ 5.0: one of the bands where the 10^18-era up-blips clustered.
    assert_neighbor_monotone(5_000_000_000, WINDOW);
}

#[test]
fun monotone_at_upblip_band() {
    // z ≈ 5.5: the densest pre-fix up-blip band.
    assert_neighbor_monotone(5_500_000_000, WINDOW);
}

#[test]
fun monotone_just_below_saturation() {
    // Ends at 6.402729805 = max_z_raw - 1, the last representable input inside
    // the central domain: the window abuts the saturation boundary.
    assert_neighbor_monotone(6_402_728_806, WINDOW);
}

#[test]
fun pdf_even_and_no_overflow_at_peak_product_input() {
    // The peak u256 Horner intermediate forms near the top of the central domain.
    // Evaluating there must not abort (u256 overflow) and must stay a valid
    // density; the codegen `check_overflow_margin` gate proves the ~8-bit headroom
    // offline. φ is even, so ±z agree at the extreme input.
    let top: u128 = 6_402_729_805; // largest in-domain raw input (max_z_raw - 1)
    let v = fixed(top).pdf().unwrap();
    assert!(v <= PDF_0_RAW);
    assert_eq!(pos(top).pdf().unwrap(), neg(top).pdf().unwrap());
}
