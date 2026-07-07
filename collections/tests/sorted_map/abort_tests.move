/// The abort carve-outs and the total-API contract.
///
/// Every `#[expected_failure]` pins `location = openzeppelin_collections::sorted_map`: the
/// abort must originate in the library, never in the consumer's inlined macro body
/// and never in `std::vector`. The interior-gap borrow case (idx < n) is what distinguishes
/// a real EKeyNotFound from a silent successor-read. The total-API tests assert the
/// complement: every non-carve-out op returns none/false/empty on a miss instead of aborting.
module openzeppelin_collections::sorted_map_abort_tests;

use openzeppelin_collections::sorted_map as sm;
use openzeppelin_collections::sorted_map_test_util as u;
use std::unit_test::assert_eq;

// === borrow / borrow_mut on an absent key -> EKeyNotFound ===

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_map::EKeyNotFound,
        location = openzeppelin_collections::sorted_map,
    ),
]
fun borrow_absent_below_head() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 20, 2);
    u::get(&m, 5); // below head
}

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_map::EKeyNotFound,
        location = openzeppelin_collections::sorted_map,
    ),
]
fun borrow_absent_above_tail() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 20, 2);
    u::get(&m, 99); // above tail: idx == n, assert must precede the OOB read
}

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_map::EKeyNotFound,
        location = openzeppelin_collections::sorted_map,
    ),
]
fun borrow_absent_interior_gap() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 30, 3);
    u::get(&m, 20); // interior gap: idx < n; a pre-assert read would return 30 silently
}

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_map::EKeyNotFound,
        location = openzeppelin_collections::sorted_map,
    ),
]
fun borrow_empty_map() {
    let m = sm::new<u64, u64>();
    u::get(&m, 1);
}

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_map::EKeyNotFound,
        location = openzeppelin_collections::sorted_map,
    ),
]
fun borrow_mut_absent() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::set(&mut m, 7, 0); // borrow_mut on an absent key (idx == n, above tail)
}

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_map::EKeyNotFound,
        location = openzeppelin_collections::sorted_map,
    ),
]
fun borrow_mut_absent_interior_gap() {
    // The interior-gap (idx < n) companion to borrow_mut_absent: a pre-assert &mut read
    // would hand back a live &mut to the SUCCESSOR (30) instead of aborting.
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 10, 1);
    u::ins(&mut m, 30, 3);
    u::set(&mut m, 20, 0); // absent interior key
}

// === destroy_empty on a non-empty map -> ENotEmpty ===

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_map::ENotEmpty,
        location = openzeppelin_collections::sorted_map,
    ),
]
fun destroy_empty_nonempty() {
    let mut m = sm::new<u64, u64>();
    u::ins(&mut m, 1, 1);
    sm::destroy_empty(m);
}

// === pop_front / pop_back on an empty map -> EEmpty ===

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_map::EEmpty,
        location = openzeppelin_collections::sorted_map,
    ),
]
fun pop_front_empty() {
    let mut m = sm::new<u64, u64>();
    let (_k, _v) = sm::pop_front(&mut m);
}

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_map::EEmpty,
        location = openzeppelin_collections::sorted_map,
    ),
]
fun pop_back_empty() {
    let mut m = sm::new<u64, u64>();
    let (_k, _v) = sm::pop_back(&mut m); // n-1 underflow guarded by the empty check
}

// === Total API: every non-carve-out op returns none/false/empty, never aborts ===

#[test]
fun total_api_no_abort_on_miss() {
    // empty map
    let mut m = sm::new<u64, u64>();
    assert!(!u::has(&m, 7));
    assert_eq!(u::rm(&mut m, 7), option::none());
    assert_eq!(u::fnext(&m, 7, true), option::none());
    assert_eq!(u::fprev(&m, 7, true), option::none());
    assert_eq!(u::nxt(&m, 7), option::none());
    assert_eq!(u::prv(&m, 7), option::none());
    assert_eq!(u::kfrom(&m, 7, true, 10), vector[]);
    assert!(sm::head(&m) == option::none() && sm::tail(&m) == option::none());
    assert!(sm::length(&m) == 0 && sm::is_empty(&m));
    assert_eq!(u::ins(&mut m, 7, 70), option::none());
    // populated, miss on an interior gap
    u::ins(&mut m, 9, 90);
    assert!(!u::has(&m, 8));
    assert_eq!(u::rm(&mut m, 8), option::none());
    assert_eq!(u::fnext(&m, 100, true), option::none());
}

#[test]
fun ptb_chain_no_abort() {
    // A PTB-style chain (contains -> find_next -> remove -> insert -> keys_from) must run
    // end to end with no abort, on both an empty and a populated map.
    let mut m = sm::new<u64, u64>();
    let _ = u::has(&m, 1);
    let _ = u::fnext(&m, 1, true);
    let _ = u::rm(&mut m, 1);
    let _ = u::ins(&mut m, 1, 10);
    let _ = u::kfrom(&m, 0, true, 5);
    u::ins(&mut m, 2, 20);
    u::ins(&mut m, 3, 30);
    let _ = u::has(&m, 2);
    let _ = u::fnext(&m, 2, false);
    let _ = u::rm(&mut m, 2);
    let _ = u::ins(&mut m, 2, 22);
    assert_eq!(u::kfrom(&m, 0, true, 5), vector[1, 2, 3]);
}

// === from_sorted_keys_values -> EUnequalLengths / EKeysNotStrictlyIncreasing ===

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_map::EUnequalLengths,
        location = openzeppelin_collections::sorted_map,
    ),
]
fun from_sorted_unequal_lengths() {
    let _m = sm::from_sorted_keys_values!(vector<u64>[1, 2, 3], vector<u64>[10, 20]);
}

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_map::EKeysNotStrictlyIncreasing,
        location = openzeppelin_collections::sorted_map,
    ),
]
fun from_sorted_out_of_order() {
    let _m = sm::from_sorted_keys_values!(vector<u64>[1, 3, 2], vector<u64>[10, 30, 20]);
}

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_map::EKeysNotStrictlyIncreasing,
        location = openzeppelin_collections::sorted_map,
    ),
]
fun from_sorted_duplicate_key() {
    // A duplicate compares equal, so it is NOT strictly increasing - aborts rather than
    // de-duplicating (a resource `V` cannot be silently displaced).
    let _m = sm::from_sorted_keys_values!(vector<u64>[1, 2, 2], vector<u64>[10, 20, 21]);
}
