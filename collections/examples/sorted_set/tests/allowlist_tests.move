module openzeppelin_collections::sorted_set_allowlist_tests;

use openzeppelin_collections::sorted_set_allowlist::{
    Self as allowlist,
    Allowlist,
    Approved,
    Revoked
};
use std::unit_test::assert_eq;
use sui::event;
use sui::test_scenario as ts;

const ALICE: address = @0x0A;
const BOB: address = @0x0B;

// === Scenario 1 - membership lifecycle: de-dup seed, bool-gated events, owned handoff ===
//
// Teaches the canonical set integration. An owned `Allowlist` is seeded with a DUPLICATE id
// (de-duplicated by `from_keys!`), then driven through approve / re-approve / revoke. The proof
// that `insert!`/`remove!`'s bool gates side effects correctly is the per-transaction EVENT
// count: a first-time approval emits exactly one `Approved`; a re-approval of the same id emits
// NONE (the polarity is `insert! == newly-added`, not the inverse). Finally ALICE hands the
// owned object to BOB, who sees the same membership - the embedded set travels inline.
#[test]
fun membership_lifecycle() {
    let mut scenario = ts::begin(ALICE);

    // Tx1 - ALICE: create an allowlist seeded from [7, 7, 3]. The duplicate 7 collapses.
    allowlist::create_and_keep(vector[7, 7, 3], ts::ctx(&mut scenario));

    // Tx2 - ALICE: confirm de-dup, then a FIRST-TIME approval emits exactly one Approved event.
    ts::next_tx(&mut scenario, ALICE);
    {
        let mut list = ts::take_from_sender<Allowlist>(&scenario);
        assert_eq!(allowlist::count(&list), 2); // {3, 7}, not 3 inputs
        assert_eq!(allowlist::members(&list), vector[3, 7]); // ascending, de-duplicated

        let added = allowlist::approve(&mut list, 5);
        assert!(added); // newly added -> true
        assert_eq!(event::events_by_type<Approved>().length(), 1); // emitted once
        assert_eq!(allowlist::count(&list), 3);
        ts::return_to_sender(&scenario, list);
    };

    // Tx3 - ALICE: re-approving 5 is a no-op (false) and emits NOTHING; revoking 3 emits once.
    ts::next_tx(&mut scenario, ALICE);
    {
        let mut list = ts::take_from_sender<Allowlist>(&scenario);
        let again = allowlist::approve(&mut list, 5);
        assert!(!again); // already present -> false
        assert_eq!(event::events_by_type<Approved>().length(), 0); // polarity: no emit on re-add
        assert_eq!(allowlist::count(&list), 3); // unchanged

        let revoked = allowlist::revoke(&mut list, 3);
        assert!(revoked); // was present -> true
        assert_eq!(event::events_by_type<Revoked>().length(), 1);
        assert!(!allowlist::is_approved(&list, 3));
        assert!(allowlist::members_well_formed(&list)); // order oracle: still sorted

        allowlist::transfer_to(list, BOB); // hand the owned object to BOB
    };

    // Tx4 - BOB: now owns the list, sees the same membership; revoking an absent id is total.
    ts::next_tx(&mut scenario, BOB);
    {
        let mut list = ts::take_from_sender<Allowlist>(&scenario);
        assert!(allowlist::is_approved(&list, 5) && allowlist::is_approved(&list, 7));
        assert!(!allowlist::is_approved(&list, 3));

        let r = allowlist::revoke(&mut list, 99);
        assert!(!r); // absent -> false, no abort
        assert_eq!(event::events_by_type<Revoked>().length(), 0);
        assert_eq!(allowlist::count(&list), 2);
        ts::return_to_sender(&scenario, list);
    };

    ts::end(scenario);
}

// === Scenario 2 - opt-in strict insert: recover vec_set's abort-on-duplicate ===
//
// The set's `insert!` is total, but a one-line `assert!(insert!(...), E)` recovers
// `sui::vec_set::insert`'s abort-on-duplicate when the integrator WANTS it. `approve_strict`
// does exactly that, aborting the integrator's OWN `EAlreadyApproved` (NOT a library abort -
// the location is this example module, not openzeppelin_collections::sorted_set).
#[test]
#[
    expected_failure(
        abort_code = openzeppelin_collections::sorted_set_allowlist::EAlreadyApproved,
        location = openzeppelin_collections::sorted_set_allowlist,
    ),
]
fun approve_strict_rejects_duplicate() {
    let mut scenario = ts::begin(ALICE);

    // Tx1 - ALICE: seed an allowlist with {1, 2}.
    allowlist::create_and_keep(vector[1, 2], ts::ctx(&mut scenario));

    // Tx2 - ALICE: strict-approve a duplicate id (1 is already present) - aborts EAlreadyApproved.
    ts::next_tx(&mut scenario, ALICE);
    {
        let mut list = ts::take_from_sender<Allowlist>(&scenario);
        allowlist::approve_strict(&mut list, 1); // aborts here: 1 is already approved
        ts::return_to_sender(&scenario, list); // unreachable; satisfies the type checker
    };

    ts::end(scenario);
}
