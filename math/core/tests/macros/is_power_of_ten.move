#[test_only]
module openzeppelin_math::is_power_of_ten;

use openzeppelin_math::macros;
use std::unit_test::assert_eq;

// Production code at u8–u64 does not route through this macro; these tests pin
// down the macro contract at those widths so a future routing change cannot
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
