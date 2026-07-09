module openzeppelin_collections::sorted_set_validator_set_tests;

use openzeppelin_collections::sorted_set;
use openzeppelin_collections::sorted_set_validator_set::{
    Self as validator_set,
    Validator,
    ValidatorSet
};
use std::unit_test::assert_eq;
use sui::test_scenario as ts;

const ALICE: address = @0x0A;
const BOB: address = @0x0B;

// Validator identity addresses (distinct from the actor addresses above).
const VAL_A: address = @0xA1;
const VAL_B: address = @0xB2;
const VAL_C: address = @0xC3;

// === Scenario 5 - struct-key registry ordered by a custom `_by` comparator ===
//
// A `Validator` struct has no built-in `<`, so every op MUST thread the `outranks` comparator via
// the `_by` macros. Validators are ranked by descending stake; `head` is therefore the top
// validator. Because keys are IMMUTABLE, re-ranking is remove-then-reinsert (`restake`), which is
// shown to preserve cardinality and re-sort correctly.
#[test]
fun struct_key_ranking() {
    let mut scenario = ts::begin(ALICE);

    // Tx1 - ALICE: deploy and share an empty validator registry.
    validator_set::deploy_and_share(scenario.ctx());

    // Tx2 - ALICE: register three validators; a re-register is a no-op (false), not an abort.
    scenario.next_tx(ALICE);
    {
        let mut vs = scenario.take_shared<ValidatorSet>();
        assert!(vs.register(validator_set::validator(100, VAL_A)));
        assert!(vs.register(validator_set::validator(300, VAL_B)));
        assert!(vs.register(validator_set::validator(200, VAL_C)));
        assert!(!vs.register(validator_set::validator(300, VAL_B))); // dup

        assert_eq!(vs.count(), 3);
        // head = highest stake under `outranks`.
        assert_eq!(vs.top(), option::some(validator_set::validator(300, VAL_B)));
        // ranking is highest-stake-first.
        assert_eq!(
            vs.ranking(),
            vector[
                validator_set::validator(300, VAL_B),
                validator_set::validator(200, VAL_C),
                validator_set::validator(100, VAL_A),
            ],
        );
        assert!(vs.validators_well_formed()); // _by order oracle
        ts::return_shared(vs);
    };

    // Tx3 - BOB: re-rank VAL_A (immutable key -> remove + reinsert), then deregister the leader.
    scenario.next_tx(BOB);
    {
        let mut vs = scenario.take_shared<ValidatorSet>();
        assert!(vs.is_registered(&validator_set::validator(200, VAL_C)));

        // Bump VAL_A from 100 to 250: the old (100, VAL_A) entry is gone, (250, VAL_A) exists.
        assert!(vs.restake(validator_set::validator(100, VAL_A), 250));
        assert!(!vs.is_registered(&validator_set::validator(100, VAL_A)));
        assert!(vs.is_registered(&validator_set::validator(250, VAL_A)));
        assert_eq!(vs.count(), 3); // cardinality preserved

        assert_eq!(
            vs.ranking(),
            vector[
                validator_set::validator(300, VAL_B),
                validator_set::validator(250, VAL_A),
                validator_set::validator(200, VAL_C),
            ],
        );

        // Deregister the leader; VAL_A is promoted to top.
        vs.deregister(&validator_set::validator(300, VAL_B));
        assert_eq!(vs.count(), 2);
        assert_eq!(vs.top(), option::some(validator_set::validator(250, VAL_A)));
        assert!(vs.validators_well_formed());
        ts::return_shared(vs);
    };

    scenario.end();
}

// === Scenario 7 - restake onto an already-occupied slot is an atomic no-op ===
//
// `restake` removes the old entry then re-inserts at the new rank. Because the set keys on the
// whole `(stake, addr)`, one address can hold two entries at once - so `(new_stake, addr)` may
// ALREADY be registered when a re-rank targets it. The re-insert then collides, and `restake`
// must restore the removed entry and report `false`, never silently drop a validator.
#[test]
fun restake_onto_occupied_slot_is_atomic() {
    let mut scenario = ts::begin(ALICE);

    // Tx1 - ALICE: deploy and share an empty validator registry.
    validator_set::deploy_and_share(scenario.ctx());

    // Tx2 - ALICE: register two entries for the SAME address at different stakes, then re-rank the
    // lower one onto the higher one's occupied slot.
    scenario.next_tx(ALICE);
    {
        let mut vs = scenario.take_shared<ValidatorSet>();
        assert!(vs.register(validator_set::validator(100, VAL_A)));
        assert!(vs.register(validator_set::validator(250, VAL_A)));
        assert_eq!(vs.count(), 2);

        // Re-rank (100, VAL_A) -> 250: (250, VAL_A) already occupies that slot, so this is a no-op.
        assert!(!vs.restake(validator_set::validator(100, VAL_A), 250));

        // Atomic: the removed entry is restored and nothing was dropped.
        assert_eq!(vs.count(), 2);
        assert!(vs.is_registered(&validator_set::validator(100, VAL_A)));
        assert!(vs.is_registered(&validator_set::validator(250, VAL_A)));
        assert!(vs.validators_well_formed());
        ts::return_shared(vs);
    };

    scenario.end();
}

// === Scenario 6 - RED test: a coarse comparator silently collapses distinct keys ===
//
// INTENTIONAL MISUSE - do NOT copy this comparator. It demonstrates the central footgun: the set
// stores no comparator and cannot check the one you pass. A COARSE (non-injective) comparator that
// orders by stake ALONE (ignoring `addr`) is not a strict total order over distinct validators -
// two equal-stake validators compare EQUAL, so the set treats them as one element. The result is
// SILENT: no abort fires, and last-write-wins overwrites the stored key bytes. This is exactly why
// the real `validator_set` breaks ties on `addr` (an injective `outranks`). No key is "lost" in the
// resource sense (the value is the trivial Unit and the set stays well-formed under the coarse
// order); the harm is that first-seen gating becomes unsound.
#[test]
fun coarse_comparator_silently_collapses_distinct_validators() {
    let mut s = sorted_set::new<Validator>();
    let a = validator_set::validator(100, VAL_A);
    let b = validator_set::validator(100, VAL_B); // distinct addr, SAME stake

    // First insert lands.
    assert!(s.upsert_by!(a, |x, y| x.stake() > y.stake()));
    // Second compares EQUAL under stake-only -> "already present" -> false (NO abort).
    assert!(!s.upsert_by!(b, |x, y| x.stake() > y.stake()));

    // Silent collapse: only ONE element, and last-write-wins overwrites with b's address (the
    // second, compare-equal insert replaced the stored key even though it returned false).
    assert_eq!(s.length(), 1);
    let ks = s.keys();
    assert_eq!(ks.borrow(0).addr(), VAL_B);
    // Under the injective `outranks` (tie-broken on addr), BOTH would have landed (length 2).
}
