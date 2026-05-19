#[test_only]
module openzeppelin_math::is_power_of_ten;

use openzeppelin_math::macros;
use std::unit_test::assert_eq;

// Explicit zero guard returns false on u128 and u256 instantiations.
#[test]
fun is_power_of_ten_returns_false_for_zero_u128() {
    assert_eq!(macros::is_power_of_ten!(0u128), false);
}

#[test]
fun is_power_of_ten_returns_false_for_zero_u256() {
    assert_eq!(macros::is_power_of_ten!(0u256), false);
}

// 10^0 = 1 is a power of ten.
#[test]
fun is_power_of_ten_returns_true_for_one_u128() {
    assert_eq!(macros::is_power_of_ten!(1u128), true);
}

#[test]
fun is_power_of_ten_returns_true_for_one_u256() {
    assert_eq!(macros::is_power_of_ten!(1u256), true);
}

// Positive cases — sampled exponents covering low, mid, and u128 boundary.
#[test]
fun is_power_of_ten_returns_true_for_sampled_powers_u128() {
    assert_eq!(macros::is_power_of_ten!(10u128), true); // 10^1
    assert_eq!(macros::is_power_of_ten!(100000u128), true); // 10^5
    assert_eq!(macros::is_power_of_ten!(10000000000000000000u128), true); // 10^19
    assert_eq!(macros::is_power_of_ten!(100000000000000000000000000000000000000u128), true); // 10^38, u128 boundary
}

// Positive cases — sampled exponents covering low, mid, and u256 boundary
// (including values beyond the u128 range to exercise generic widening at u256 width).
#[test]
fun is_power_of_ten_returns_true_for_sampled_powers_u256() {
    assert_eq!(macros::is_power_of_ten!(10u256), true); // 10^1
    assert_eq!(macros::is_power_of_ten!(100000u256), true); // 10^5
    assert_eq!(macros::is_power_of_ten!(10000000000000000000u256), true); // 10^19
    assert_eq!(macros::is_power_of_ten!(100000000000000000000000000000000000000u256), true); // 10^38
    assert_eq!(
        macros::is_power_of_ten!(100000000000000000000000000000000000000000000000000u256),
        true,
    ); // 10^50
    assert_eq!(
        macros::is_power_of_ten!(
            100000000000000000000000000000000000000000000000000000000000000000000000000000u256,
        ),
        true,
    ); // 10^77, u256 boundary
}

// Boundary negatives — values one below and one above sampled powers.
#[test]
fun is_power_of_ten_returns_false_at_boundaries_u128() {
    assert_eq!(macros::is_power_of_ten!(9u128), false); // 10^1 - 1
    assert_eq!(macros::is_power_of_ten!(11u128), false); // 10^1 + 1
    assert_eq!(macros::is_power_of_ten!(99u128), false); // 10^2 - 1
    assert_eq!(macros::is_power_of_ten!(101u128), false); // 10^2 + 1
    assert_eq!(macros::is_power_of_ten!(99999999999999999999999999999999999999u128), false); // 10^38 - 1
    assert_eq!(macros::is_power_of_ten!(100000000000000000000000000000000000001u128), false); // 10^38 + 1
}

#[test]
fun is_power_of_ten_returns_false_at_boundaries_u256() {
    assert_eq!(macros::is_power_of_ten!(9u256), false);
    assert_eq!(macros::is_power_of_ten!(11u256), false);
    assert_eq!(macros::is_power_of_ten!(99u256), false);
    assert_eq!(macros::is_power_of_ten!(101u256), false);
    assert_eq!(
        macros::is_power_of_ten!(
            99999999999999999999999999999999999999999999999999999999999999999999999999999u256,
        ),
        false,
    ); // 10^77 - 1
    assert_eq!(
        macros::is_power_of_ten!(
            100000000000000000000000000000000000000000000000000000000000000000000000000001u256,
        ),
        false,
    ); // 10^77 + 1
}

// Arbitrary non-powers.
#[test]
fun is_power_of_ten_returns_false_for_non_powers_u128() {
    assert_eq!(macros::is_power_of_ten!(2u128), false);
    assert_eq!(macros::is_power_of_ten!(3u128), false);
    assert_eq!(macros::is_power_of_ten!(999u128), false);
}

#[test]
fun is_power_of_ten_returns_false_for_non_powers_u256() {
    assert_eq!(macros::is_power_of_ten!(2u256), false);
    assert_eq!(macros::is_power_of_ten!(3u256), false);
    assert_eq!(macros::is_power_of_ten!(999u256), false);
}

// The macro is generic over `$Int` for any unsigned integer type. Production code
// only instantiates the macro at u128 and u256, but the macro body is intrinsically
// type-generic — these tests pin down the contract at the smaller widths.
#[test]
fun is_power_of_ten_macro_works_on_u8() {
    assert_eq!(macros::is_power_of_ten!(0u8), false);
    assert_eq!(macros::is_power_of_ten!(1u8), true);
    assert_eq!(macros::is_power_of_ten!(10u8), true);
    assert_eq!(macros::is_power_of_ten!(100u8), true);
    assert_eq!(macros::is_power_of_ten!(11u8), false);
    assert_eq!(macros::is_power_of_ten!(std::u8::max_value!()), false);
}

#[test]
fun is_power_of_ten_macro_works_on_u16() {
    assert_eq!(macros::is_power_of_ten!(0u16), false);
    assert_eq!(macros::is_power_of_ten!(1u16), true);
    assert_eq!(macros::is_power_of_ten!(10000u16), true);
    assert_eq!(macros::is_power_of_ten!(9999u16), false);
    assert_eq!(macros::is_power_of_ten!(std::u16::max_value!()), false);
}

#[test]
fun is_power_of_ten_macro_works_on_u32() {
    assert_eq!(macros::is_power_of_ten!(0u32), false);
    assert_eq!(macros::is_power_of_ten!(1u32), true);
    assert_eq!(macros::is_power_of_ten!(1000000000u32), true);
    assert_eq!(macros::is_power_of_ten!(999999999u32), false);
    assert_eq!(macros::is_power_of_ten!(std::u32::max_value!()), false);
}

#[test]
fun is_power_of_ten_macro_works_on_u64() {
    assert_eq!(macros::is_power_of_ten!(0u64), false);
    assert_eq!(macros::is_power_of_ten!(1u64), true);
    assert_eq!(macros::is_power_of_ten!(10000000000000000000u64), true); // 10^19
    assert_eq!(macros::is_power_of_ten!(9999999999999999999u64), false);
    assert_eq!(macros::is_power_of_ten!(std::u64::max_value!()), false);
}

// log10_floor cascade boundary at k=64.
// log10_floor's outermost dispatch branch is `if (value >= TEN_POW_64)`. No other test in
// the package (neither is_power_of_ten nor log10's own test suite) exercises this exact
// threshold. A regression in log10_floor's k=64 branch would silently skew the predicate
// for every exponent at or above 64 without any existing test catching it.
#[test]
fun is_power_of_ten_at_log10_floor_cascade_boundary_u256() {
    assert_eq!(
        macros::is_power_of_ten!(
            10000000000000000000000000000000000000000000000000000000000000000u256,
        ),
        true,
    ); // 10^64
    assert_eq!(
        macros::is_power_of_ten!(
            9999999999999999999999999999999999999999999999999999999999999999u256,
        ),
        false,
    ); // 10^64 - 1
    assert_eq!(
        macros::is_power_of_ten!(
            10000000000000000000000000000000000000000000000000000000000000001u256,
        ),
        false,
    ); // 10^64 + 1
}

// TYPE_MAX is not a power of ten, and the macro must not abort.
// For u256_max, log10_floor returns 77 — this exercises the largest possible exponent
// and confirms std::u256::pow(10, 77) does not overflow.
#[test]
fun is_power_of_ten_returns_false_for_u128_max() {
    assert_eq!(macros::is_power_of_ten!(std::u128::max_value!()), false);
}

#[test]
fun is_power_of_ten_returns_false_for_u256_max() {
    assert_eq!(macros::is_power_of_ten!(std::u256::max_value!()), false);
}
