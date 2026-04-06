#[test_only]
module openzeppelin_fp_math::sd29x9_decompose_tests;

use openzeppelin_fp_math::sd29x9;
use openzeppelin_fp_math::sd29x9_test_helpers::{pos, neg};
use std::unit_test::assert_eq;

const SCALE: u128 = 1_000_000_000;
const MAX_POSITIVE_VALUE: u128 = 0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
const MIN_NEGATIVE_VALUE: u128 = 0x8000_0000_0000_0000_0000_0000_0000_0000;

#[test]
fun decompose_zero() {
    let (neg, mag) = sd29x9::zero().decompose();
    assert!(!neg);
    assert_eq!(mag, 0);
}

#[test]
fun decompose_positive_integer() {
    let (neg, mag) = pos(5 * SCALE).decompose();
    assert!(!neg);
    assert_eq!(mag, 5 * SCALE);
}

#[test]
fun decompose_negative_integer() {
    let (neg, mag) = neg(5 * SCALE).decompose();
    assert!(neg);
    assert_eq!(mag, 5 * SCALE);
}

#[test]
fun decompose_positive_fractional() {
    let (neg, mag) = pos(5 * SCALE + 500_000_000).decompose();
    assert!(!neg);
    assert_eq!(mag, 5_500_000_000);
}

#[test]
fun decompose_negative_fractional() {
    let (neg, mag) = neg(5 * SCALE + 500_000_000).decompose();
    assert!(neg);
    assert_eq!(mag, 5_500_000_000);
}

#[test]
fun decompose_smallest_positive() {
    let (neg, mag) = pos(1).decompose();
    assert!(!neg);
    assert_eq!(mag, 1);
}

#[test]
fun decompose_smallest_negative() {
    let (neg, mag) = neg(1).decompose();
    assert!(neg);
    assert_eq!(mag, 1);
}

#[test]
fun decompose_max_value() {
    let (neg, mag) = sd29x9::max().decompose();
    assert!(!neg);
    assert_eq!(mag, MAX_POSITIVE_VALUE);
}

#[test]
fun decompose_min_value() {
    let (neg, mag) = sd29x9::min().decompose();
    assert!(neg);
    assert_eq!(mag, MIN_NEGATIVE_VALUE);
}

#[test]
fun decompose_roundtrip_positive() {
    let original = pos(42 * SCALE);
    let (neg, mag) = original.decompose();
    let reconstructed = sd29x9::wrap(mag, neg);
    assert_eq!(original, reconstructed);
}

#[test]
fun decompose_roundtrip_negative() {
    let original = neg(42 * SCALE);
    let (neg, mag) = original.decompose();
    let reconstructed = sd29x9::wrap(mag, neg);
    assert_eq!(original, reconstructed);
}
