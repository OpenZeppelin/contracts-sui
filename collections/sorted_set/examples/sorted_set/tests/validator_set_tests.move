module openzeppelin_sorted_set::validator_set_tests;

use openzeppelin_sorted_set::sorted_set;
use openzeppelin_sorted_set::validator_set::{Self, Validator, ValidatorSet};
use std::unit_test::assert_eq;
use sui::test_scenario as ts;

const ALICE: address = @0x0A;
const BOB: address = @0x0B;

// Validator identity addresses (distinct from the actor addresses above).
const VAL_A: address = @0xA1;
const VAL_B: address = @0xB2;
const VAL_C: address = @0xC3;

// === Scenario 6 - struct-key registry ordered by a custom `_by` comparator ===
//
// A `Validator` struct has no built-in `<`, so every op MUST thread the `outranks` comparator via
// the `_by` macros. Validators are ranked by descending stake; `head` is therefore the top
// validator. Because keys are IMMUTABLE, re-ranking is remove-then-reinsert (`restake`), which is
// shown to preserve cardinality and re-sort correctly.
#[test]
fun struct_key_ranking() {
    let mut scenario = ts::begin(ALICE);

    // Tx1 - ALICE: deploy and share an empty validator registry.
    validator_set::deploy_and_share(ts::ctx(&mut scenario));

    // Tx2 - ALICE: register three validators; a re-register is a no-op (false), not an abort.
    ts::next_tx(&mut scenario, ALICE);
    {
        let mut vs = ts::take_shared<ValidatorSet>(&scenario);
        assert!(validator_set::register(&mut vs, validator_set::validator(100, VAL_A)));
        assert!(validator_set::register(&mut vs, validator_set::validator(300, VAL_B)));
        assert!(validator_set::register(&mut vs, validator_set::validator(200, VAL_C)));
        assert!(!validator_set::register(&mut vs, validator_set::validator(300, VAL_B))); // dup

        assert_eq!(validator_set::count(&vs), 3);
        // head = highest stake under `outranks`.
        assert_eq!(validator_set::top(&vs), option::some(validator_set::validator(300, VAL_B)));
        // ranking is highest-stake-first.
        assert_eq!(
            validator_set::ranking(&vs),
            vector[
                validator_set::validator(300, VAL_B),
                validator_set::validator(200, VAL_C),
                validator_set::validator(100, VAL_A),
            ],
        );
        assert!(validator_set::validators_well_formed(&vs)); // _by order oracle
        ts::return_shared(vs);
    };

    // Tx3 - BOB: re-rank VAL_A (immutable key -> remove + reinsert), then deregister the leader.
    ts::next_tx(&mut scenario, BOB);
    {
        let mut vs = ts::take_shared<ValidatorSet>(&scenario);
        assert!(validator_set::is_registered(&vs, &validator_set::validator(200, VAL_C)));

        // Bump VAL_A from 100 to 250: the old (100, VAL_A) entry is gone, (250, VAL_A) exists.
        assert!(validator_set::restake(&mut vs, validator_set::validator(100, VAL_A), 250));
        assert!(!validator_set::is_registered(&vs, &validator_set::validator(100, VAL_A)));
        assert!(validator_set::is_registered(&vs, &validator_set::validator(250, VAL_A)));
        assert_eq!(validator_set::count(&vs), 3); // cardinality preserved

        assert_eq!(
            validator_set::ranking(&vs),
            vector[
                validator_set::validator(300, VAL_B),
                validator_set::validator(250, VAL_A),
                validator_set::validator(200, VAL_C),
            ],
        );

        // Deregister the leader; VAL_A is promoted to top.
        assert!(validator_set::deregister(&mut vs, &validator_set::validator(300, VAL_B)));
        assert_eq!(validator_set::count(&vs), 2);
        assert_eq!(validator_set::top(&vs), option::some(validator_set::validator(250, VAL_A)));
        assert!(validator_set::validators_well_formed(&vs));
        ts::return_shared(vs);
    };

    ts::end(scenario);
}

// === Scenario 7 - RED test: a coarse comparator silently collapses distinct keys ===
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
    assert!(
        sorted_set::insert_by!(&mut s, a, |x, y| validator_set::stake(x) > validator_set::stake(y)),
    );
    // Second compares EQUAL under stake-only -> "already present" -> false (NO abort).
    assert!(
        !sorted_set::insert_by!(
            &mut s,
            b,
            |x, y| validator_set::stake(x) > validator_set::stake(y),
        ),
    );

    // Silent collapse: only ONE element, and last-write-wins keeps b's address, dropping a's.
    assert_eq!(sorted_set::length(&s), 1);
    let ks = sorted_set::keys(&s);
    assert_eq!(validator_set::addr(vector::borrow(&ks, 0)), VAL_B);
    // Under the injective `outranks` (tie-broken on addr), BOTH would have landed (length 2).
}
