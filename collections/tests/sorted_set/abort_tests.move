/// The abort surface: exactly ONE library abort (`EEmpty`), asserted FIRST at THIS
/// module's location/code, plus the affirmative total-API contract for mid-PTB chaining.
/// The set is "total except ONE" - strictly more total than the map's abort carve-outs.
///
/// Every set-owned `#[expected_failure]` pins BOTH `abort_code = ...sorted_set::EEmpty` AND
/// `location = openzeppelin_collections::sorted_set` - code 0 at the SET's location. The bypass
/// test proves the caveat: a direct `sorted_map::pop_front(inner_mut(set))` leaks the
/// MAP's abort instead.
module openzeppelin_collections::sorted_set_abort_tests;

use openzeppelin_collections::sorted_set as ss;
use openzeppelin_collections::sorted_set_test_util as u;
use std::unit_test::assert_eq;

// === the ONE abort: pop_front/pop_back on empty -> set-owned EEmpty ===

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_set::EEmpty,
        location = openzeppelin_collections::sorted_set,
    ),
]
fun pop_front_empty_aborts_at_set() {
    let mut s = ss::new<u64>();
    s.pop_front();
}

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_set::EEmpty,
        location = openzeppelin_collections::sorted_set,
    ),
]
fun pop_back_empty_aborts_at_set() {
    let mut s = ss::new<u64>();
    s.pop_back();
}

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_set::EEmpty,
        location = openzeppelin_collections::sorted_set,
    ),
]
fun pop_front_after_draining_aborts_at_set() {
    // Drain a singleton, then pop the now-empty set: still the SET's EEmpty.
    let mut s = ss::singleton<u64>(1);
    let _ = s.pop_front();
    s.pop_front();
}

// === bypass caveat: a direct inner-map pop leaks the MAP's abort, not the set's ===

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_map::EEmpty,
        location = openzeppelin_collections::sorted_map,
    ),
]
fun inner_mut_direct_pop_empty_aborts_at_map() {
    // A consumer DEFEATS the set's location guarantee by calling sorted_map::pop_front through
    // inner_mut on an empty inner map: it aborts at the MAP's location with the MAP's code 2,
    // NOT the set's code 0. This is exactly why inner_mut is "not a supported API" - use the
    // set's own pop_*. The set's location guarantee holds only for the set's OWN pop_front/back.
    let mut s = ss::new<u64>();
    u::misuse_pop_front_inner(&mut s);
}

#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_map::EEmpty,
        location = openzeppelin_collections::sorted_map,
    ),
]
fun inner_mut_direct_pop_back_empty_aborts_at_map() {
    // Symmetric to the pop_front bypass: a direct sorted_map::pop_back through inner_mut on an
    // empty inner map ALSO leaks the MAP's location with the MAP's code 2, not the set's code 0.
    let mut s = ss::new<u64>();
    u::misuse_pop_back_inner(&mut s);
}

// === affirmative total API: every non-pop op returns none/false/empty, never aborts ===

#[test]
fun total_api_no_abort_on_empty() {
    let mut s = ss::new<u64>();
    assert!(!u::has(&s, 7));
    assert!(!u::rem(&mut s, 7)); // remove absent -> false, no abort
    assert_eq!(u::fnext(&s, 7, true), option::none());
    assert_eq!(u::fprev(&s, 7, true), option::none());
    assert_eq!(u::nkey(&s, 7), option::none());
    assert_eq!(u::pkey(&s, 7), option::none());
    assert_eq!(u::page(&s, 7, true, 10), vector[]);
    assert!(s.head() == option::none() && s.tail() == option::none());
    assert!(s.length() == 0 && s.is_empty());
    assert_eq!(s.keys(), vector[]);
    assert!(u::ins(&mut s, 7)); // insert returns a bool, never aborts
}

#[test]
fun total_api_no_abort_on_miss() {
    // populated set, miss on an interior gap and past the tail.
    let mut s = u::fromk(vector[9u64, 11]);
    assert!(!u::has(&s, 10));
    assert!(!u::rem(&mut s, 10));
    assert_eq!(u::fnext(&s, 100, true), option::none());
    assert_eq!(u::fprev(&s, 0, true), option::none());
}

#[test]
fun ptb_shaped_chain_no_abort() {
    // A PTB-style chain (contains -> find_next -> remove -> insert -> keys_from) must run end to
    // end with no abort, on both an empty and a populated set - nothing unwinds an earlier
    // command. Routed through helpers so the chain expands no macros.
    let mut s = ss::new<u64>();
    let _ = u::has(&s, 1);
    let _ = u::fnext(&s, 1, true);
    let _ = u::rem(&mut s, 1);
    let _ = u::ins(&mut s, 1);
    let _ = u::page(&s, 0, true, 5);
    u::ins(&mut s, 2);
    u::ins(&mut s, 3);
    let _ = u::has(&s, 2);
    let _ = u::fnext(&s, 2, false);
    let _ = u::rem(&mut s, 2);
    let _ = u::ins(&mut s, 2);
    assert_eq!(u::page(&s, 0, true, 5), vector[1u64, 2, 3]);
}
