module openzeppelin_sorted_set::unlock_queue_tests;

use openzeppelin_sorted_set::unlock_queue::{Self, UnlockQueue};
use std::unit_test::assert_eq;
use sui::test_scenario as ts;

const ALICE: address = @0x0A;
const BOB: address = @0x0B;
const CAROL: address = @0x0C;

// === Scenario 4 - ordered drain: peek the extremes, pop earliest-first ===
//
// The set doubles as a min/max priority queue. A shared `UnlockQueue` is seeded from deadlines
// containing a DUPLICATE (de-duplicated), inspected via O(1) `head`/`tail` peeks, then drained
// in chronological order with `pop_front`. Three actors take turns on the one shared object.
#[test]
fun drain_earliest_first() {
    let mut scenario = ts::begin(ALICE);

    // Tx1 - ALICE: deploy a queue seeded from [30, 10, 20, 10]; the duplicate 10 collapses.
    unlock_queue::deploy_and_share(vector[30, 10, 20, 10], ts::ctx(&mut scenario));

    // Tx2 - BOB: peek the extremes and schedule more (one new, one duplicate).
    ts::next_tx(&mut scenario, BOB);
    {
        let mut q = ts::take_shared<UnlockQueue>(&scenario);
        assert_eq!(unlock_queue::pending(&q), 3); // {10, 20, 30}
        assert_eq!(unlock_queue::next_deadline(&q), option::some(10)); // earliest, O(1) peek
        assert_eq!(unlock_queue::last_deadline(&q), option::some(30)); // latest, O(1) peek

        assert!(unlock_queue::schedule(&mut q, 25)); // new -> true
        assert!(!unlock_queue::schedule(&mut q, 10)); // duplicate -> false, no abort
        assert_eq!(unlock_queue::pending(&q), 4); // {10, 20, 25, 30}
        assert!(unlock_queue::deadlines_well_formed(&q)); // order oracle on a POPULATED set (n=4)
        ts::return_shared(q);
    };

    // Tx3 - CAROL: drain in order, cancel one, then drain the last via the other extreme.
    ts::next_tx(&mut scenario, CAROL);
    {
        let mut q = ts::take_shared<UnlockQueue>(&scenario);
        assert_eq!(unlock_queue::process_earliest(&mut q), 10); // pop_front: smallest
        assert_eq!(unlock_queue::process_earliest(&mut q), 20);
        assert_eq!(unlock_queue::pending(&q), 2); // {25, 30}
        assert_eq!(unlock_queue::next_deadline(&q), option::some(25));

        assert!(unlock_queue::cancel(&mut q, 30)); // remove the tail
        assert_eq!(unlock_queue::pending(&q), 1); // {25}
        assert_eq!(unlock_queue::process_latest(&mut q), 25); // pop_back: largest (now only)

        assert!(unlock_queue::is_empty(&q));
        assert!(unlock_queue::deadlines_well_formed(&q)); // an empty set is well-formed
        ts::return_shared(q);
    };

    ts::end(scenario);
}

// === Scenario 5 - the library's ONE abort: pop on an empty set ===
//
// `pop_front`/`pop_back` are the only operations in the whole library that abort, and only on an
// EMPTY set (`EEmpty`). The set asserts its OWN `EEmpty` (code 0) BEFORE delegating to the wrapped
// map, so the abort surfaces at `location = openzeppelin_sorted_set::sorted_set`. Pinning the
// wrapped map's location (`openzeppelin_sorted_map::sorted_map`, code 2) here would make this test
// FAIL - that branch is never reached through the set's own `pop_*`.
#[test]
#[
    expected_failure(
        abort_code = openzeppelin_sorted_set::sorted_set::EEmpty,
        location = openzeppelin_sorted_set::sorted_set,
    ),
]
fun process_empty_queue_aborts() {
    let mut scenario = ts::begin(ALICE);

    // Tx1 - ALICE: deploy a queue holding a single deadline.
    unlock_queue::deploy_and_share(vector[5], ts::ctx(&mut scenario));

    // Tx2 - ALICE: drain the only deadline, emptying the queue.
    ts::next_tx(&mut scenario, ALICE);
    {
        let mut q = ts::take_shared<UnlockQueue>(&scenario);
        assert_eq!(unlock_queue::process_earliest(&mut q), 5);
        ts::return_shared(q);
    };

    // Tx3 - ALICE: pop the now-empty queue - aborts EEmpty at the SET's location.
    ts::next_tx(&mut scenario, ALICE);
    {
        let mut q = ts::take_shared<UnlockQueue>(&scenario);
        unlock_queue::process_earliest(&mut q); // aborts here
        ts::return_shared(q); // unreachable; satisfies the type checker
    };

    ts::end(scenario);
}
