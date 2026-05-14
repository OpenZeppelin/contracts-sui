#[test_only]
module openzeppelin_fp_math::ud30x9_sqrt_tests;

use openzeppelin_fp_math::ud30x9;
use openzeppelin_fp_math::ud30x9_test_helpers::fixed;
use std::unit_test::assert_eq;

const SCALE: u128 = 1_000_000_000;

// ==== Tests ====

#[test]
fun sqrt_of_zero_is_zero() {
    assert_eq!(ud30x9::zero().sqrt(), ud30x9::zero());
}

#[test]
fun sqrt_of_one_is_one() {
    assert_eq!(ud30x9::one().sqrt(), ud30x9::one());
}

#[test]
fun sqrt_of_perfect_integer_squares() {
    // sqrt(4.0) = 2.0
    assert_eq!(fixed(4 * SCALE).sqrt(), fixed(2 * SCALE));
    // sqrt(9.0) = 3.0
    assert_eq!(fixed(9 * SCALE).sqrt(), fixed(3 * SCALE));
    // sqrt(16.0) = 4.0
    assert_eq!(fixed(16 * SCALE).sqrt(), fixed(4 * SCALE));
    // sqrt(25.0) = 5.0
    assert_eq!(fixed(25 * SCALE).sqrt(), fixed(5 * SCALE));
    // sqrt(100.0) = 10.0
    assert_eq!(fixed(100 * SCALE).sqrt(), fixed(10 * SCALE));
    // sqrt(10000.0) = 100.0
    assert_eq!(fixed(10_000 * SCALE).sqrt(), fixed(100 * SCALE));
    // sqrt(1000000.0) = 1000.0
    assert_eq!(fixed(1_000_000 * SCALE).sqrt(), fixed(1_000 * SCALE));
}

#[test]
fun sqrt_of_perfect_fractional_squares() {
    // sqrt(0.25) = 0.5
    assert_eq!(fixed(250_000_000).sqrt(), fixed(500_000_000));
    // sqrt(0.01) = 0.1
    assert_eq!(fixed(10_000_000).sqrt(), fixed(100_000_000));
    // sqrt(2.25) = 1.5
    assert_eq!(fixed(2_250_000_000).sqrt(), fixed(1_500_000_000));
    // sqrt(6.25) = 2.5
    assert_eq!(fixed(6_250_000_000).sqrt(), fixed(2_500_000_000));
}

#[test]
fun sqrt_of_smallest_representable_input() {
    // sqrt(0.000000001) = sqrt(1e-9) = ~0.000031622
    // raw = 1, result = floor(sqrt(1 * 10^9)) = floor(31622.776...) = 31622
    assert_eq!(fixed(1).sqrt(), fixed(31_622));
}

#[test]
fun sqrt_truncates_irrational_results() {
    // sqrt(2.0) = 1.41421356237... -> 1.414213562
    assert_eq!(fixed(2 * SCALE).sqrt(), fixed(1_414_213_562));
    // sqrt(3.0) = 1.73205080756... -> 1.732050807
    assert_eq!(fixed(3 * SCALE).sqrt(), fixed(1_732_050_807));
    // sqrt(5.0) = 2.23606797749... -> 2.236067977
    assert_eq!(fixed(5 * SCALE).sqrt(), fixed(2_236_067_977));
}

#[test]
fun sqrt_handles_values_near_perfect_squares() {
    // sqrt(1.000000001) -> 1.000000000 (just barely above 1.0, floor is 1.0)
    assert_eq!(fixed(SCALE + 1).sqrt(), fixed(SCALE));
    // sqrt(0.999999999) -> 0.999999999 (floor(sqrt(0.999999999e18)) = floor(999999999.5e0) = 999999999)
    assert_eq!(fixed(SCALE - 1).sqrt(), fixed(SCALE - 1));
    // sqrt(4.000000001) -> 2.000000000 (just above 4.0)
    assert_eq!(fixed(4 * SCALE + 1).sqrt(), fixed(2 * SCALE));
    // sqrt(3.999999999) -> 1.999999999
    assert_eq!(fixed(4 * SCALE - 1).sqrt(), fixed(2 * SCALE - 1));
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
        assert_eq!(root.mul(root), x);
    });
}

#[random_test]
fun sqrt_floor_property(raw: u128) {
    // For all values: sqrt(x)^2 <= x * SCALE < (sqrt(x) + 1)^2
    let x = ud30x9::wrap(raw);
    let r = x.sqrt().unwrap() as u256;
    let scaled = (raw as u256) * (SCALE as u256);
    assert!(r * r <= scaled);
    assert!((r + 1) * (r + 1) > scaled);
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
    assert_eq!(fixed(10_000_000_000 * SCALE).sqrt(), fixed(100_000 * SCALE));

    // sqrt(1000000000000.0) = 1000000.0 (1e12 is a perfect square of 1e6)
    assert_eq!(fixed(1_000_000_000_000 * SCALE).sqrt(), fixed(1_000_000 * SCALE));
}

#[random_test]
fun sqrt_monotonicity(x: u128, y: u128) {
    // For x <= y, sqrt(x) <= sqrt(y)
    let (x, y) = if (x <= y) (x, y) else (y, x);
    assert!(ud30x9::wrap(x).sqrt().unwrap() <= ud30x9::wrap(y).sqrt().unwrap());
}
