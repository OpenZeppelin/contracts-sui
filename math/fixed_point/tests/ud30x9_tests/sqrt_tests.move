#[test_only]
module openzeppelin_fp_math::ud30x9_sqrt_tests;

use openzeppelin_fp_math::ud30x9;
use openzeppelin_fp_math::ud30x9_test_helpers::{fixed, expect, pair, unpack};

const SCALE: u128 = 1_000_000_000;

// ==== Tests ====

#[test]
fun sqrt_of_zero_is_zero() {
    expect(fixed(0).sqrt(), fixed(0));
}

#[test]
fun sqrt_of_one_is_one() {
    expect(fixed(SCALE).sqrt(), fixed(SCALE));
}

#[test]
fun sqrt_of_perfect_integer_squares() {
    // sqrt(4.0) = 2.0
    expect(fixed(4 * SCALE).sqrt(), fixed(2 * SCALE));
    // sqrt(9.0) = 3.0
    expect(fixed(9 * SCALE).sqrt(), fixed(3 * SCALE));
    // sqrt(16.0) = 4.0
    expect(fixed(16 * SCALE).sqrt(), fixed(4 * SCALE));
    // sqrt(25.0) = 5.0
    expect(fixed(25 * SCALE).sqrt(), fixed(5 * SCALE));
    // sqrt(100.0) = 10.0
    expect(fixed(100 * SCALE).sqrt(), fixed(10 * SCALE));
    // sqrt(10000.0) = 100.0
    expect(fixed(10_000 * SCALE).sqrt(), fixed(100 * SCALE));
    // sqrt(1000000.0) = 1000.0
    expect(fixed(1_000_000 * SCALE).sqrt(), fixed(1_000 * SCALE));
}

#[test]
fun sqrt_of_perfect_fractional_squares() {
    // sqrt(0.25) = 0.5
    expect(fixed(250_000_000).sqrt(), fixed(500_000_000));
    // sqrt(0.01) = 0.1
    expect(fixed(10_000_000).sqrt(), fixed(100_000_000));
    // sqrt(2.25) = 1.5
    expect(fixed(2_250_000_000).sqrt(), fixed(1_500_000_000));
    // sqrt(6.25) = 2.5
    expect(fixed(6_250_000_000).sqrt(), fixed(2_500_000_000));
}

#[test]
fun sqrt_of_smallest_representable_input() {
    // sqrt(0.000000001) = sqrt(1e-9) = ~0.000031622
    // raw = 1, result = floor(sqrt(1 * 10^9)) = floor(31622.776...) = 31622
    expect(fixed(1).sqrt(), fixed(31_622));
}

#[test]
fun sqrt_truncates_irrational_results() {
    // sqrt(2.0) = 1.41421356237... -> 1.414213562
    expect(fixed(2 * SCALE).sqrt(), fixed(1_414_213_562));
    // sqrt(3.0) = 1.73205080756... -> 1.732050807
    expect(fixed(3 * SCALE).sqrt(), fixed(1_732_050_807));
    // sqrt(5.0) = 2.23606797749... -> 2.236067977
    expect(fixed(5 * SCALE).sqrt(), fixed(2_236_067_977));
}

#[test]
fun sqrt_handles_values_near_perfect_squares() {
    // sqrt(1.000000001) -> 1.000000000 (just barely above 1.0, floor is 1.0)
    expect(fixed(SCALE + 1).sqrt(), fixed(SCALE));
    // sqrt(0.999999999) -> 0.999999999 (floor(sqrt(0.999999999e18)) = floor(999999999.5e0) = 999999999)
    expect(fixed(SCALE - 1).sqrt(), fixed(SCALE - 1));
    // sqrt(4.000000001) -> 2.000000000 (just above 4.0)
    expect(fixed(4 * SCALE + 1).sqrt(), fixed(2 * SCALE));
    // sqrt(3.999999999) -> 1.999999999
    expect(fixed(4 * SCALE - 1).sqrt(), fixed(2 * SCALE - 1));
}

#[test]
fun sqrt_squared_roundtrip_for_perfect_squares() {
    let values = vector[
        fixed(4 * SCALE),
        fixed(9 * SCALE),
        fixed(25 * SCALE),
        fixed(250_000_000), // 0.25
        fixed(10_000_000), // 0.01
    ];
    values.destroy!(|x| {
        let root = x.sqrt();
        expect(root.mul(root), x);
    });
}

#[test]
fun sqrt_floor_property_for_non_perfect_squares() {
    // For non-perfect squares: sqrt(x)^2 <= x < (sqrt(x) + smallest_step)^2
    // We verify using raw u256 arithmetic to avoid fixed-point overflow concerns
    let values = vector[
        fixed(2 * SCALE),
        fixed(3 * SCALE),
        fixed(5 * SCALE),
        fixed(7 * SCALE),
        fixed(SCALE + 1), // 1.000000001
        fixed(123_456_789), // 0.123456789
    ];
    values.destroy!(|x| {
        let r = x.sqrt().unwrap() as u256;
        let scaled = (x.unwrap() as u256) * (SCALE as u256);
        // r^2 <= x * SCALE
        assert!(r * r <= scaled);
        // (r+1)^2 > x * SCALE
        assert!((r + 1) * (r + 1) > scaled);
    });
}

#[test]
fun sqrt_of_max_value() {
    // sqrt(ud30x9::max()) should not abort and satisfy the floor property
    let result = ud30x9::max().sqrt();
    let r = result.unwrap() as u256;
    let max_scaled = (ud30x9::max().unwrap() as u256) * (SCALE as u256);
    assert!(r * r <= max_scaled);
    assert!((r + 1) * (r + 1) > max_scaled);
}

#[test]
fun sqrt_of_large_values() {
    // sqrt(10000000000.0) = 100000.0 (1e10 is a perfect square of 1e5)
    expect(
        fixed(10_000_000_000 * SCALE).sqrt(),
        fixed(100_000 * SCALE),
    );

    // sqrt(1000000000000.0) = 1000000.0 (1e12 is a perfect square of 1e6)
    expect(
        fixed(1_000_000_000_000 * SCALE).sqrt(),
        fixed(1_000_000 * SCALE),
    );
}

#[test]
fun sqrt_monotonicity() {
    // For x < y, sqrt(x) <= sqrt(y)
    let pairs = vector[
        pair(fixed(SCALE), fixed(2 * SCALE)),
        pair(fixed(2 * SCALE), fixed(3 * SCALE)),
        pair(fixed(100_000_000), fixed(SCALE)),
        pair(fixed(SCALE), fixed(100 * SCALE)),
        pair(fixed(1), fixed(SCALE)),
    ];
    pairs.destroy!(|p| {
        let (x, y) = p.unpack();
        assert!(x.sqrt().unwrap() <= y.sqrt().unwrap());
    });
}
