#[test_only]
module openzeppelin_math::is_power_of_ten;

use openzeppelin_math::macros;
use std::unit_test::assert_eq;

// Exhaustive macro-level coverage of `is_power_of_ten!` across every supported
// width. u128 and u256 are the production-routed widths; u8–u64 do not currently
// route through the macro but are tested here so a future routing change cannot
// silently regress.
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

#[test]
fun is_power_of_ten_macro_works_on_u128() {
    // Zero is not a power of ten.
    assert_eq!(macros::is_power_of_ten!(0u128), false);

    // Sampled powers across the u128 range (10^0 .. 10^38).
    assert_eq!(macros::is_power_of_ten!(1u128), true);
    assert_eq!(macros::is_power_of_ten!(10u128), true);
    assert_eq!(macros::is_power_of_ten!(100u128), true);
    assert_eq!(macros::is_power_of_ten!(10000u128), true); // 10^4
    assert_eq!(macros::is_power_of_ten!(100000000u128), true); // 10^8
    assert_eq!(macros::is_power_of_ten!(10000000000000000u128), true); // 10^16
    assert_eq!(macros::is_power_of_ten!(10000000000000000000u128), true); // 10^19
    assert_eq!(macros::is_power_of_ten!(100000000000000000000000000000000u128), true); // 10^32
    assert_eq!(macros::is_power_of_ten!(100000000000000000000000000000000000000u128), true); // 10^38 (max power of ten in u128)

    // Off-by-one non-powers around several powers.
    assert_eq!(macros::is_power_of_ten!(9u128), false);
    assert_eq!(macros::is_power_of_ten!(11u128), false);
    assert_eq!(macros::is_power_of_ten!(99u128), false);
    assert_eq!(macros::is_power_of_ten!(101u128), false);
    assert_eq!(macros::is_power_of_ten!(99999999999999999999999999999999999999u128), false); // 10^38 - 1

    // Multiples of ten that are not powers of ten.
    assert_eq!(macros::is_power_of_ten!(20u128), false);
    assert_eq!(macros::is_power_of_ten!(500u128), false);

    // u128::MAX is not a power of ten.
    assert_eq!(macros::is_power_of_ten!(std::u128::max_value!()), false);
}

#[test]
fun is_power_of_ten_macro_works_on_u256() {
    // Zero is not a power of ten.
    assert_eq!(macros::is_power_of_ten!(0u256), false);

    // Sampled powers across the u256 range (10^0 .. 10^77).
    assert_eq!(macros::is_power_of_ten!(1u256), true);
    assert_eq!(macros::is_power_of_ten!(10u256), true);
    assert_eq!(macros::is_power_of_ten!(100u256), true);
    assert_eq!(macros::is_power_of_ten!(10000u256), true); // 10^4
    assert_eq!(macros::is_power_of_ten!(100000000u256), true); // 10^8
    assert_eq!(macros::is_power_of_ten!(10000000000000000u256), true); // 10^16
    assert_eq!(macros::is_power_of_ten!(100000000000000000000000000000000u256), true); // 10^32
    assert_eq!(
        macros::is_power_of_ten!(
            10000000000000000000000000000000000000000000000000000000000000000u256,
        ),
        true,
    ); // 10^64
    assert_eq!(
        macros::is_power_of_ten!(
            100000000000000000000000000000000000000000000000000000000000000000000000000000u256,
        ),
        true,
    ); // 10^77 (max power of ten in u256)

    // Off-by-one non-powers around several powers.
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

    // Multiples of ten that are not powers of ten.
    assert_eq!(macros::is_power_of_ten!(20u256), false);
    assert_eq!(macros::is_power_of_ten!(500u256), false);

    // u256::MAX is not a power of ten.
    assert_eq!(macros::is_power_of_ten!(std::u256::max_value!()), false);
}
