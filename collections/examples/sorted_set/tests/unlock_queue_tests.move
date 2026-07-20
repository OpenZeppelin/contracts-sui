module openzeppelin_collections::sorted_set_unlock_queue_tests;

use openzeppelin_collections::sorted_set as ss;
use openzeppelin_collections::sorted_set_unlock_queue::{
    Self as unlock_queue,
    UnlockQueue,
    Unlocked,
};
use std::unit_test::assert_eq;
use sui::event;
use sui::test_scenario as ts;

const ALICE: address = @0x0A;
const BOB: address = @0x0B;
const CAROL: address = @0x0C;

// === Scenario 3 - ordered drain: peek the extremes, pop earliest-first ===
//
// The set doubles as a min/max priority queue. A shared `UnlockQueue` is seeded from deadlines
// containing a DUPLICATE (de-duplicated), inspected via O(1) `head`/`tail` peeks, then drained
// in chronological order with `pop_front`. Three actors take turns on the one shared object.
#[test]
fun drain_earliest_first() {
    let mut scenario = ts::begin(ALICE);

    // Tx1 - ALICE: deploy a queue seeded from [30, 10, 20, 10]; the duplicate 10 collapses.
    unlock_queue::deploy_and_share(vector[30, 10, 20, 10], scenario.ctx());

    // Tx2 - BOB: peek the extremes and schedule more (one new, one duplicate).
    scenario.next_tx(BOB);
    {
        let mut q = scenario.take_shared<UnlockQueue>();
        assert_eq!(q.pending(), 3); // {10, 20, 30}
        assert_eq!(q.next_deadline(), option::some(10)); // earliest, O(1) peek
        assert_eq!(q.last_deadline(), option::some(30)); // latest, O(1) peek

        assert!(q.schedule(25)); // new -> true
        assert!(!q.schedule(10)); // duplicate -> false, no abort
        assert_eq!(q.pending(), 4); // {10, 20, 25, 30}
        assert!(q.deadlines_well_formed()); // order oracle on a POPULATED set (n=4)
        ts::return_shared(q);
    };

    // Tx3 - CAROL: drain in order, cancel one, then drain the last via the other extreme.
    scenario.next_tx(CAROL);
    {
        let mut q = scenario.take_shared<UnlockQueue>();
        assert_eq!(q.process_earliest(), 10); // pop_front: smallest
        assert_eq!(q.process_earliest(), 20);
        assert_eq!(q.pending(), 2); // {25, 30}
        assert_eq!(q.next_deadline(), option::some(25));

        q.cancel(30); // remove the tail
        assert_eq!(q.pending(), 1); // {25}
        assert_eq!(q.process_latest(), 25); // pop_back: largest (now only)

        // Each pop emitted an `Unlocked` carrying THIS queue's id - consumers watching another
        // (permissionless) instance can tell the events apart.
        let qid = object::id(&q);
        assert_eq!(
            event::events_by_type<Unlocked>(),
            vector[
                unlock_queue::unlocked_event(qid, 10),
                unlock_queue::unlocked_event(qid, 20),
                unlock_queue::unlocked_event(qid, 25),
            ],
        );

        assert!(q.is_empty());
        assert!(q.deadlines_well_formed()); // an empty set is well-formed
        ts::return_shared(q);
    };

    scenario.end();
}

// === Scenario 4 - processing an empty queue aborts at the set ===
//
// This scenario isolates the queue's empty-pop path (`EEmpty`). The set asserts its OWN `EEmpty`
// (code 0) BEFORE delegating to the wrapped map, so the abort surfaces at
// `location = openzeppelin_collections::sorted_set`. Pinning the wrapped map's location
// (`openzeppelin_collections::sorted_map`, code 2) here would make this test FAIL - that branch is
// never reached through the set's own `pop_*`.
#[test, expected_failure(abort_code = ss::EEmpty, location = ss)]
fun process_empty_queue_aborts() {
    let mut scenario = ts::begin(ALICE);

    // Tx1 - ALICE: deploy a queue holding a single deadline.
    unlock_queue::deploy_and_share(vector[5], scenario.ctx());

    // Tx2 - ALICE: drain the only deadline, emptying the queue.
    scenario.next_tx(ALICE);
    {
        let mut q = scenario.take_shared<UnlockQueue>();
        assert_eq!(q.process_earliest(), 5);
        ts::return_shared(q);
    };

    // Tx3 - ALICE: pop the now-empty queue - aborts EEmpty at the SET's location.
    scenario.next_tx(ALICE);
    {
        let mut q = scenario.take_shared<UnlockQueue>();
        q.process_earliest(); // aborts here
        ts::return_shared(q); // unreachable; satisfies the type checker
    };

    scenario.end();
}
