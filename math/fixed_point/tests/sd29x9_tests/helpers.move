#[test_only]
module openzeppelin_fp_math::sd29x9_test_helpers;

use openzeppelin_fp_math::sd29x9::{Self, SD29x9};
use std::unit_test::assert_eq;

public struct Pair has drop {
    x: SD29x9,
    y: SD29x9,
}

public(package) fun pair(x: SD29x9, y: SD29x9): Pair { Pair { x, y } }

public(package) fun unpack(p: Pair): (SD29x9, SD29x9) {
    let Pair { x, y } = p;
    (x, y)
}

public(package) fun pos(raw: u128): SD29x9 {
    sd29x9::wrap(raw, false)
}

public(package) fun neg(raw: u128): SD29x9 {
    sd29x9::wrap(raw, true)
}

public(package) fun expect(left: SD29x9, right: SD29x9) {
    assert_eq!(left.unwrap(), right.unwrap());
}

// inspired by `std::unit_test::assert_ref_eq`
public(package) macro fun expect_ne($left: SD29x9, $right: SD29x9) {
    let left = $left;
    let right = $right;
    let left = left.unwrap();
    let right = right.unwrap();
    let res = left == right;
    if (res) {
        std::debug::print(&b"Assertion failed:".to_string());
        std::debug::print(left);
        std::debug::print(&b"==".to_string());
        std::debug::print(right);
        assert!(false);
    }
}
