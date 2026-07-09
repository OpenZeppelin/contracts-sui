/// The abort surface: two set-owned library aborts - `EEmpty` (pop on an empty set) and
/// `EKeysNotSorted` (`from_sorted_keys!` on unsorted input) - each asserted at THIS module's
/// location/code; two more are DELEGATED and surface at the wrapped MAP - `remove!` on an absent
/// key (`sorted_map::EKeyNotFound`) and `add!` / `add_by!` on a duplicate key
/// (`sorted_map::EKeyAlreadyExists`). The rest is the affirmative total-API contract for mid-PTB
/// chaining: every op except `remove!`, `add!` / `add_by!`, and the pops is total.
///
/// Every set-owned `#[expected_failure]` pins BOTH `abort_code = ...sorted_set::E*` AND
/// `location = openzeppelin_collections::sorted_set` - the SET's location. The bypass and
/// remove-absent tests prove the caveat: a `sorted_map` op reached through `inner_mut` (or
/// delegated to, as `remove!` does) leaks the MAP's abort instead.
module openzeppelin_collections::sorted_set_abort_tests;

use openzeppelin_collections::sorted_map as sm;
use openzeppelin_collections::sorted_set as ss;
use openzeppelin_collections::sorted_set_test_util as u;
use std::unit_test::assert_eq;

// === the ONE abort: pop_front/pop_back on empty -> set-owned EEmpty ===

#[test, expected_failure(abort_code = ss::EEmpty, location = ss)]
fun pop_front_empty_aborts_at_set() {
    let mut s = ss::new<u64>();
    s.pop_front();
}

#[test, expected_failure(abort_code = ss::EEmpty, location = ss)]
fun pop_back_empty_aborts_at_set() {
    let mut s = ss::new<u64>();
    s.pop_back();
}

#[test, expected_failure(abort_code = ss::EEmpty, location = ss)]
fun pop_front_after_draining_aborts_at_set() {
    // Drain a singleton, then pop the now-empty set: still the SET's EEmpty.
    let mut s = ss::singleton<u64>(1);
    let _ = s.pop_front();
    s.pop_front();
}

// === from_sorted_keys! on unsorted input -> set-owned EKeysNotSorted at the SET's location ===

#[test, expected_failure(abort_code = ss::EKeysNotSorted, location = ss)]
fun from_sorted_out_of_order_aborts_at_set() {
    // A strictly decreasing adjacent pair (3 then 2) is unsorted -> EKeysNotSorted at the SET.
    let _s = u::from_sorted(vector[1u64, 3, 2]);
}

#[test, expected_failure(abort_code = ss::EKeysNotSorted, location = ss)]
fun from_sorted_by_reverse_out_of_order_aborts_at_set() {
    // Under `>`, "sorted" means descending-numeric; an ascending step (1 then 2) is a decrease.
    let _s = u::from_sorted_rev(vector[3u64, 1, 2]);
}

#[test, expected_failure(abort_code = ss::EKeysNotSorted, location = ss)]
fun from_sorted_minimal_decrease_aborts_at_set() {
    // The decrease is the FIRST comparison (i == 1), not a later pair as in [1,3,2] - so the abort
    // fires on the very first adjacent check, with only one element built so far.
    let _s = u::from_sorted(vector[2u64, 1]);
}

// === bypass caveat: a direct inner-map pop leaks the MAP's abort, not the set's ===

#[test, expected_failure(abort_code = sm::EEmpty, location = sm)]
fun inner_mut_direct_pop_empty_aborts_at_map() {
    // A consumer DEFEATS the set's location guarantee by calling sorted_map::pop_front through
    // inner_mut on an empty inner map: it aborts at the MAP's location with the MAP's code 2,
    // NOT the set's code 0. This is exactly why inner_mut is "not a supported API" - use the
    // set's own pop_*. The set's location guarantee holds only for the set's OWN pop_front/back.
    let mut s = ss::new<u64>();
    u::misuse_pop_front_inner(&mut s);
}

#[test, expected_failure(abort_code = sm::EEmpty, location = sm)]
fun inner_mut_direct_pop_back_empty_aborts_at_map() {
    // Symmetric to the pop_front bypass: a direct sorted_map::pop_back through inner_mut on an
    // empty inner map ALSO leaks the MAP's location with the MAP's code 2, not the set's code 0.
    let mut s = ss::new<u64>();
    u::misuse_pop_back_inner(&mut s);
}

// === remove! on an absent key aborts, DELEGATED to the map's location/code ===

#[test, expected_failure(abort_code = sm::EKeyNotFound, location = sm)]
fun remove_absent_aborts_at_map() {
    // remove! delegates to the wrapped map's remove_by!, which aborts EKeyNotFound on an absent
    // key. Unlike the set's OWN EEmpty, this abort surfaces at the MAP's location - the set never
    // re-checks membership itself.
    let mut s = u::fromk(vector[9u64, 11]);
    u::rem(&mut s, 10); // interior gap -> aborts at the map
}

// === add / add_by on a present key -> DELEGATED sorted_map::EKeyAlreadyExists at the MAP ===

#[test, expected_failure(abort_code = sm::EKeyAlreadyExists, location = sm)]
fun add_duplicate_aborts_at_map() {
    // add! delegates to the wrapped map's add_by!, which aborts EKeyAlreadyExists on a duplicate.
    // Like remove!, this abort surfaces at the MAP's location, not the set's.
    let mut s = ss::new<u64>();
    u::add(&mut s, 5);
    u::add(&mut s, 5);
}

#[test, expected_failure(abort_code = sm::EKeyAlreadyExists, location = sm)]
fun add_by_duplicate_aborts_at_map() {
    // Same delegated abort under a custom comparator (reverse `>`).
    let mut s = ss::new<u64>();
    u::add_rev(&mut s, 5);
    u::add_rev(&mut s, 5);
}

#[test, expected_failure(abort_code = sm::EKeyAlreadyExists, location = sm)]
fun add_coarse_equal_key_aborts_at_map() {
    // A COMPARE-EQUAL key is a duplicate: same id, different tag compares equal under id-order,
    // so the second add aborts even though the key bytes differ.
    let mut s = ss::new<u::Key>();
    u::add_k(&mut s, u::mk(1, 100));
    u::add_k(&mut s, u::mk(1, 200)); // id=1 already present -> EKeyAlreadyExists at the map
}

// === affirmative total API: every op except remove!/pop returns none/false/empty, never aborts ===

#[test]
fun total_api_no_abort_on_empty() {
    let mut s = ss::new<u64>();
    assert!(!u::has(&s, 7));
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
    let s = u::fromk(vector[9u64, 11]);
    assert!(!u::has(&s, 10));
    assert_eq!(u::fnext(&s, 100, true), option::none());
    assert_eq!(u::fprev(&s, 0, true), option::none());
}

#[test]
fun ptb_shaped_chain_no_abort() {
    // A PTB-style chain (contains -> find_next -> insert -> remove -> keys_from) must run end to
    // end with no abort - nothing unwinds an earlier command. `remove!` aborts on an absent key,
    // so each remove here targets a key the chain just inserted. Routed through helpers so the
    // chain expands no macros.
    let mut s = ss::new<u64>();
    let _ = u::has(&s, 1);
    let _ = u::fnext(&s, 1, true);
    let _ = u::ins(&mut s, 1);
    u::rem(&mut s, 1); // remove the key just inserted
    let _ = u::page(&s, 0, true, 5);
    u::ins(&mut s, 1);
    u::ins(&mut s, 2);
    u::ins(&mut s, 3);
    let _ = u::has(&s, 2);
    let _ = u::fnext(&s, 2, false);
    u::rem(&mut s, 2);
    u::ins(&mut s, 2);
    assert_eq!(u::page(&s, 0, true, 5), vector[1u64, 2, 3]);
}
