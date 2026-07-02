module openzeppelin_fp_math::cdf_monotonicity_tests;

use openzeppelin_fp_math::sd29x9_test_helpers::neg;
use openzeppelin_fp_math::ud30x9_test_helpers::fixed;
use std::unit_test::assert_eq;

// Neighbor-resolution monotonicity for `Φ`: the output must never decrease
// between *adjacent* representable inputs (1 raw ULP, 10^-9, apart). The offline
// codegen gate (`cdf/validate.check_neighbor_monotonicity`) proves this
// exhaustively over the whole tail; these in-VM windows confirm the deployed Move
// evaluator agrees at the historically at-risk points. Before the 10^36
// accumulation scale, floor-truncation noise produced ~6,400 such 1-ULP
// inversions clustered in this mid-tail band; the coarse 64-point grid sweeps in
// the other test modules step ~10^8 raw inputs apart and cannot see them.
//
// Each window scans 1,000 consecutive raw inputs in its own test - the Move VM's
// per-test budget does not allow folding every window into one loop.

const WINDOW: u64 = 1_000;
const ONE_RAW: u128 = 1_000_000_000;

// Scan `count` consecutive raw inputs upward from `start`, asserting Φ is
// non-decreasing between every neighbor.
fun assert_neighbor_monotone(start: u128, count: u64) {
    let mut prev = fixed(start - 1).cdf().unwrap();
    count.do!(|off| {
        let curr = fixed(start + (off as u128)).cdf().unwrap();
        assert!(curr >= prev);
        prev = curr;
    });
}

#[test]
fun monotone_at_first_prefix_inversion_onset() {
    // z = 4.533726001 was the first 1-ULP inversion before the 10^36 fix; the
    // window straddles it.
    assert_neighbor_monotone(4_533_726_000, WINDOW);
}

#[test]
fun monotone_in_mid_tail() {
    assert_neighbor_monotone(5_000_000_000, WINDOW);
}

#[test]
fun monotone_just_below_saturation() {
    // Ends at 6.109410204 = max_z_raw - 1, the last representable input inside
    // the central domain: the window abuts the saturation boundary.
    assert_neighbor_monotone(6_109_409_205, WINDOW);
}

#[test]
fun negative_branch_neighbor_monotone() {
    // Reflection Φ(-z) = 1 - Φ(z): as |z| grows by one raw ULP, Φ(-|z|) must be
    // non-increasing. Exercises the signed reflection + underflow-guard path at
    // neighbor resolution.
    let start: u128 = 5_000_000_000;
    let mut prev = neg(start - 1).cdf().unwrap();
    WINDOW.do!(|off| {
        let curr = neg(start + (off as u128)).cdf().unwrap();
        assert!(curr <= prev);
        prev = curr;
    });
}

#[test]
fun no_overflow_at_peak_product_input() {
    // The peak u256 Horner intermediate forms near the top of the central domain.
    // Evaluating there must not abort (u256 overflow) and must return a valid
    // probability; the codegen `check_overflow_margin` gate proves the ~10-bit
    // headroom offline, this confirms the deployed evaluator does not abort.
    let top: u128 = 6_109_410_204; // largest in-domain raw input (max_z_raw - 1)
    let v = fixed(top).cdf().unwrap();
    assert!(v <= ONE_RAW);
    assert_eq!(v + neg(top).cdf().unwrap(), ONE_RAW); // reflection intact at the extreme
}
