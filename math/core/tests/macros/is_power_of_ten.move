#[test_only]
module openzeppelin_math::is_power_of_ten;

use openzeppelin_math::macros;
use std::unit_test::assert_eq;

// The macro is generic over `$Int` for any unsigned integer type. Production code
// only instantiates the macro at u128 and u256 (covered indirectly by `u128_tests`
// and `u256_tests`); these tests pin down the contract at the smaller widths so a
// future routing change at u8–u64 cannot silently regress.
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

// u256_max exercises the largest possible exponent (log10_floor returns 77) and confirms
// `std::u256::pow(10, 77)` does not overflow — the unique INV-R6 enforcement point that
// `u256_tests::is_power_of_ten_*` does not cover directly.
#[test]
fun is_power_of_ten_returns_false_for_u256_max() {
    assert_eq!(macros::is_power_of_ten!(std::u256::max_value!()), false);
}
