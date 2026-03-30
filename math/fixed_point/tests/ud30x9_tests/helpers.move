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

public(package) macro fun expect($left: UD30x9, $right: UD30x9) {
    let left = $left;
    let right = $right;
    assert_eq!(left.unwrap(), right.unwrap());
}
