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
    allowlist::create_and_keep(vector[7, 7, 3], scenario.ctx());

    // Tx2 - ALICE: confirm de-dup, then a FIRST-TIME approval emits exactly one Approved event.
    scenario.next_tx(ALICE);
    {
        let mut list = scenario.take_from_sender<Allowlist>();
        assert_eq!(list.count(), 2); // {3, 7}, not 3 inputs
        assert_eq!(list.members(), vector[3, 7]); // ascending, de-duplicated

        let added = list.approve(5);
        assert!(added); // newly added -> true
        assert_eq!(event::events_by_type<Approved>().length(), 1); // emitted once
        assert_eq!(list.count(), 3);
        scenario.return_to_sender(list);
    };

    // Tx3 - ALICE: re-approving 5 is a no-op (false) and emits NOTHING; revoking 3 emits once.
    scenario.next_tx(ALICE);
    {
        let mut list = scenario.take_from_sender<Allowlist>();
        let again = list.approve(5);
        assert!(!again); // already present -> false
        assert_eq!(event::events_by_type<Approved>().length(), 0); // polarity: no emit on re-add
        assert_eq!(list.count(), 3); // unchanged

        let revoked = list.revoke(3);
        assert!(revoked); // was present -> true
        assert_eq!(event::events_by_type<Revoked>().length(), 1);
        assert!(!list.is_approved(3));
        assert!(list.members_well_formed()); // order oracle: still sorted

        list.transfer_to(BOB); // hand the owned object to BOB
    };

    // Tx4 - BOB: now owns the list, sees the same membership; revoking an absent id is total.
    scenario.next_tx(BOB);
    {
        let mut list = scenario.take_from_sender<Allowlist>();
        assert!(list.is_approved(5) && list.is_approved(7));
        assert!(!list.is_approved(3));

        let r = list.revoke(99);
        assert!(!r); // absent -> false, no abort
        assert_eq!(event::events_by_type<Revoked>().length(), 0);
        assert_eq!(list.count(), 2);
        scenario.return_to_sender(list);
    };

    scenario.end();
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
    allowlist::create_and_keep(vector[1, 2], scenario.ctx());

    // Tx2 - ALICE: strict-approve a duplicate id (1 is already present) - aborts EAlreadyApproved.
    scenario.next_tx(ALICE);
    {
        let mut list = scenario.take_from_sender<Allowlist>();
        list.approve_strict(1); // aborts here: 1 is already approved
        scenario.return_to_sender(list); // unreachable; satisfies the type checker
    };

    scenario.end();
}
