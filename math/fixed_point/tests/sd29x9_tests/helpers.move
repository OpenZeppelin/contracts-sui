module openzeppelin_fp_math::sd29x9_test_helpers;

use openzeppelin_fp_math::sd29x9::{Self, SD29x9};

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

public(package) fun abs_diff(a: u128, b: u128): u128 {
    if (a >= b) a - b else b - a
}

public(package) fun assert_within(actual: u128, expected: u128, tol: u128) {
    assert!(abs_diff(actual, expected) <= tol);
}
