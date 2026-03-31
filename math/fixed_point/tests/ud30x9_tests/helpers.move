#[test_only]
module openzeppelin_fp_math::ud30x9_test_helpers;

use openzeppelin_fp_math::ud30x9::{Self, UD30x9};
use std::unit_test::assert_eq;

public struct Pair has drop {
    x: UD30x9,
    y: UD30x9,
}

public(package) fun pair(x: UD30x9, y: UD30x9): Pair { Pair { x, y } }

public(package) fun unpack(p: Pair): (UD30x9, UD30x9) {
    let Pair { x, y } = p;
    (x, y)
}

public(package) fun fixed(value: u128): UD30x9 {
    ud30x9::wrap(value)
}

public(package) fun expect(left: UD30x9, right: UD30x9) {
    assert_eq!(left.unwrap(), right.unwrap());
}

// inspired by `std::unit_test::assert_ref_eq`
public(package) macro fun expect_ne($left: UD30x9, $right: UD30x9) {
    let left = $left;
    let right = $right;
    let left = left.unwrap();
    let right = right.unwrap();
    let res = left == right;
    if (res) {
        std::debug::print(&b"Assertion failed:".to_string());
        std::debug::print(&left);
        std::debug::print(&b"==".to_string());
        std::debug::print(&right);
        assert!(false);
    }
}
