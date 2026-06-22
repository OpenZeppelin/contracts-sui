// mint_cap + set_allowance: the two owner verbs (cap issuance + budget upsert).
//
// Covers the ledger / cap / event surface of the two owner-side verbs: bare
// vault-bound cap issuance, the owner gate, upsert create/overwrite semantics,
// expiry validity and revival, the no-expiry and unlimited-budget sentinels,
// compare-and-set, suspension via amount 0, granted-coin-type tracking,
// per-(cap, coin) independence, cap_id stability, and event emission.
//
// Pool-balance effects need a live AccumulatorRoot, which the unit-test VM
// cannot construct; they are not exercised by this package's tests (they require a live network).
module openzeppelin_allowance::spend_vault_cap_budget_tests;

use openzeppelin_allowance::spend_vault::{Self, SpenderCap};
use openzeppelin_allowance::sv_test_utils::{Self as u, USDC, SUIT, DEEP, FOO};
use std::type_name;
use std::unit_test::{assert_eq, destroy};
use sui::coin;
use sui::event;
use sui::test_scenario as ts;

const OWNER: address = @0xA;
const SPENDER: address = @0xB;
const MAXU64: u64 = 18_446_744_073_709_551_615;

// === mint_cap ===

#[test]
// mint_cap returns a bare, vault-bound cap; NO ledger entry exists for it until
// set_allowance; SpenderCapMinted is emitted bare.
fun mint_cap_is_bare_and_bound() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);

        let cap = spend_vault::mint_cap(&v, &oc, s.ctx());
        let cid = object::id(&cap);

        // cap binds to THIS vault.
        assert_eq!(spend_vault::spender_cap_vault_id(&cap), vid);
        // no entry exists before any set_allowance.
        assert!(!spend_vault::contains<USDC>(&v, cid));
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 0);
        // granted_coin_types is still empty (mint records nothing).
        assert_eq!(spend_vault::granted_coin_types(&v).length(), 0);

        // exactly one SpenderCapMinted, bare.
        let evs = event::events_by_type<spend_vault::SpenderCapMinted>();
        assert_eq!(evs.length(), 1);
        assert_eq!(evs[0], spend_vault::test_new_spender_cap_minted(vid, cid, OWNER));

        transfer::public_transfer(cap, SPENDER);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

#[test, expected_failure(abort_code = spend_vault::EWrongOwnerCap)]
// mint_cap with a FOREIGN OwnerCap aborts EWrongOwnerCap.
fun mint_cap_foreign_owner_aborts() {
    let mut s = ts::begin(OWNER);
    let _vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    s.next_tx(OWNER);
    let v = u::take_vault(&s);
    // an OwnerCap bound to a DIFFERENT vault
    let (_vb, ocb) = spend_vault::new(s.ctx());
    let _cap = spend_vault::mint_cap(&v, &ocb, s.ctx());
    abort
}

#[test]
// two mint_cap calls yield two distinct cap_ids, the only way to get two summing
// budgets for one person.
fun mint_cap_twice_distinct_ids() {
    let mut s = ts::begin(OWNER);
    let _vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);

        let cap1 = spend_vault::mint_cap(&v, &oc, s.ctx());
        let cap2 = spend_vault::mint_cap(&v, &oc, s.ctx());
        assert!(object::id(&cap1) != object::id(&cap2));

        let evs = event::events_by_type<spend_vault::SpenderCapMinted>();
        assert_eq!(evs.length(), 2);

        transfer::public_transfer(cap1, SPENDER);
        transfer::public_transfer(cap2, SPENDER);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

// === set_allowance: create / overwrite ===

#[test]
// create on an absent (cap, T): was_created==true, allowance==budget, expiry set,
// granted_coin_types now has T, AllowanceSet emitted.
fun set_allowance_create_on_absent() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let clk = u::take_clock(&s);

        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            500,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );

        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 500);
        assert_eq!(spend_vault::expiry<USDC>(&v, cid), MAXU64);
        assert!(spend_vault::contains<USDC>(&v, cid));
        // granted_coin_types now records USDC.
        let gct = spend_vault::granted_coin_types(&v);
        assert_eq!(gct.length(), 1);
        assert!(gct.contains(&type_name::with_defining_ids<USDC>()));

        // one AllowanceSet, was_created==true, cas_was_provided==false.
        let evs = event::events_by_type<spend_vault::AllowanceSet>();
        assert_eq!(evs.length(), 1);
        assert_eq!(
            evs[0],
            spend_vault::test_new_allowance_set(
                vid,
                cid,
                type_name::with_defining_ids<USDC>(),
                500,
                MAXU64,
                false,
                true,
                OWNER,
            ),
        );

        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

#[test]
// a second set on the same (cap, T) OVERWRITES (does not add): 500 then 800 -> 800
// (not 1300); was_created==false on the overwrite.
fun set_allowance_overwrite_not_additive() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let clk = u::take_clock(&s);

        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            500,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            800,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );

        // OVERWRITE, not 500+800.
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 800);
        // granted_coin_types not duplicated by the second create-path probe.
        assert_eq!(spend_vault::granted_coin_types(&v).length(), 1);

        // The second emit carries was_created==false.
        let evs = event::events_by_type<spend_vault::AllowanceSet>();
        assert_eq!(evs.length(), 2);
        assert_eq!(
            evs[1],
            spend_vault::test_new_allowance_set(
                vid,
                cid,
                type_name::with_defining_ids<USDC>(),
                800,
                MAXU64,
                false,
                false,
                OWNER,
            ),
        );

        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// === Suspension + revival ===

#[test]
// set amount 0 does NOT abort (no EZeroAmount); contains stays true, allowance
// reads 0 (live-but-suspended).
fun set_allowance_zero_suspends_no_abort() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let clk = u::take_clock(&s);

        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            500,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        // amount 0 = suspend, NOT EZeroAmount.
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            0,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );

        assert!(spend_vault::contains<USDC>(&v, cid));
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 0);

        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

#[test]
// a suspended (amount-0) entry revives to a positive budget in place.
fun set_allowance_revives_suspended() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let clk = u::take_clock(&s);

        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            0,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            500,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );

        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 500);
        assert!(spend_vault::contains<USDC>(&v, cid));

        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

#[test]
// setting a finite future expiry on an expired entry REVIVES it in place (same
// cap_id, same key).
fun set_allowance_future_expiry_revives_expired() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    let exp = u::start_ms() + 1_000;
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let mut clk = u::take_clock(&s);

        // create with a finite expiry, then advance past it (entry now expired).
        spend_vault::set_allowance<USDC>(&mut v, &oc, cid, 500, exp, option::none(), &clk, s.ctx());
        clk.set_for_testing(exp + 50);

        // restate a fresh future expiry -> revives in place.
        let exp2 = exp + 5_000;
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            500,
            exp2,
            option::none(),
            &clk,
            s.ctx(),
        );
        assert_eq!(spend_vault::expiry<USDC>(&v, cid), exp2);
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 500);

        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// === Expiry validity ===

#[test, expected_failure(abort_code = spend_vault::EExpiryInPast)]
// a finite new_expires_at_ms == clock.now aborts EExpiryInPast (closed boundary:
// must be strictly future).
fun set_allowance_expiry_equals_now_aborts() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    s.next_tx(OWNER);
    let mut v = u::take_vault(&s);
    let oc = u::take_owner_cap(&s, OWNER);
    let clk = u::take_clock(&s);
    // now == start_ms; expiry == now aborts EExpiryInPast
    spend_vault::set_allowance<USDC>(
        &mut v,
        &oc,
        cid,
        500,
        u::start_ms(),
        option::none(),
        &clk,
        s.ctx(),
    );
    abort
}

#[test]
// new_expires_at_ms == now + 1 (strictly future) succeeds.
fun set_allowance_expiry_now_plus_one_ok() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    let exp = u::start_ms() + 1;
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let clk = u::take_clock(&s);
        spend_vault::set_allowance<USDC>(&mut v, &oc, cid, 500, exp, option::none(), &clk, s.ctx());
        assert_eq!(spend_vault::expiry<USDC>(&v, cid), exp);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

#[test]
// new_expires_at_ms == u64::MAX (no-expiry sentinel) always passes; the
// expires_at_ms == u64::MAX equality short-circuits the strictly-future check
// before any comparison against "now".
fun set_allowance_expiry_sentinel_ok() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let clk = u::take_clock(&s);
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            500,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        assert_eq!(spend_vault::expiry<USDC>(&v, cid), MAXU64);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// === Sentinels ===

#[test]
// budget u64::MAX (unlimited) AND expiry u64::MAX (no-expiry) both succeed.
fun set_allowance_unlimited_budget_and_no_expiry() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let clk = u::take_clock(&s);
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            MAXU64,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), MAXU64);
        assert_eq!(spend_vault::expiry<USDC>(&v, cid), MAXU64);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// === CAS ===

#[test]
// Some(e) matching the current remaining overwrites (set 400 with Some(400)).
// cas_was_provided==true on the AllowanceSet.
fun set_allowance_cas_match_overwrites() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let clk = u::take_clock(&s);

        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            400,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        // CAS: expect 400 (current), set to 250.
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            250,
            MAXU64,
            option::some(400),
            &clk,
            s.ctx(),
        );
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 250);

        let evs = event::events_by_type<spend_vault::AllowanceSet>();
        assert_eq!(evs.length(), 2);
        assert_eq!(
            evs[1],
            spend_vault::test_new_allowance_set(
                vid,
                cid,
                type_name::with_defining_ids<USDC>(),
                250,
                MAXU64,
                true,
                false,
                OWNER,
            ),
        );

        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

#[test, expected_failure(abort_code = spend_vault::EUnexpectedAllowance)]
// Some(e) MISMATCH (expect a value other than current remaining) aborts
// EUnexpectedAllowance.
fun set_allowance_cas_mismatch_aborts() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    s.next_tx(OWNER);
    let mut v = u::take_vault(&s);
    let oc = u::take_owner_cap(&s, OWNER);
    let clk = u::take_clock(&s);
    spend_vault::set_allowance<USDC>(&mut v, &oc, cid, 400, MAXU64, option::none(), &clk, s.ctx());
    // current remaining is 400; expecting 399 aborts EUnexpectedAllowance
    spend_vault::set_allowance<USDC>(
        &mut v,
        &oc,
        cid,
        250,
        MAXU64,
        option::some(399),
        &clk,
        s.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = spend_vault::EUnexpectedAllowance)]
// Some(e) on an ABSENT (cap, T) aborts EUnexpectedAllowance; you cannot CAS-match
// a value that does not exist.
fun set_allowance_cas_on_absent_aborts() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    s.next_tx(OWNER);
    let mut v = u::take_vault(&s);
    let oc = u::take_owner_cap(&s, OWNER);
    let clk = u::take_clock(&s);
    // never created (cap, USDC); a CAS of Some(0) still aborts (absent != match)
    spend_vault::set_allowance<USDC>(&mut v, &oc, cid, 500, MAXU64, option::some(0), &clk, s.ctx());
    abort
}

#[test]
// None is the unconditional create/overwrite; the create event records
// cas_was_provided==false.
fun set_allowance_none_unconditional_create() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let clk = u::take_clock(&s);
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            700,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 700);
        let evs = event::events_by_type<spend_vault::AllowanceSet>();
        assert_eq!(evs.length(), 1);
        // cas_was_provided flag is false on the None path.
        assert_eq!(
            evs[0],
            spend_vault::test_new_allowance_set(
                vid,
                cid,
                type_name::with_defining_ids<USDC>(),
                700,
                MAXU64,
                false,
                true,
                OWNER,
            ),
        );
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

#[test]
// CAS compares the RAW remaining including the unlimited sentinel: Some(u64::MAX)
// matches an unlimited entry and overwrites.
fun set_allowance_cas_matches_unlimited_sentinel() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let clk = u::take_clock(&s);
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            MAXU64,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        // expect the unlimited sentinel; reduce to a finite budget.
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            600,
            MAXU64,
            option::some(MAXU64),
            &clk,
            s.ctx(),
        );
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 600);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

#[test]
// CAS compares the RAW remaining including 0: Some(0) matches a suspended entry
// and revives it.
fun set_allowance_cas_matches_suspended_zero() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let clk = u::take_clock(&s);
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            0,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        // current remaining is 0 (suspended); Some(0) matches.
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            500,
            MAXU64,
            option::some(0),
            &clk,
            s.ctx(),
        );
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 500);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// === Owner gate + precedence ===

#[test, expected_failure(abort_code = spend_vault::EWrongOwnerCap)]
// set_allowance with a FOREIGN OwnerCap aborts EWrongOwnerCap first.
fun set_allowance_foreign_owner_aborts() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    s.next_tx(OWNER);
    let mut v = u::take_vault(&s);
    let clk = u::take_clock(&s);
    // an OwnerCap for a DIFFERENT vault
    let (_vb, ocb) = spend_vault::new(s.ctx());
    spend_vault::set_allowance<USDC>(&mut v, &ocb, cid, 500, MAXU64, option::none(), &clk, s.ctx());
    abort
}

#[test, expected_failure(abort_code = spend_vault::EWrongOwnerCap)]
// precedence: with a foreign owner cap AND a past expiry, EWrongOwnerCap wins over
// EExpiryInPast (the owner gate is checked first).
fun precedence_wrong_owner_beats_expiry_in_past() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    s.next_tx(OWNER);
    let mut v = u::take_vault(&s);
    let clk = u::take_clock(&s);
    let (_vb, ocb) = spend_vault::new(s.ctx());
    // foreign cap AND expiry == now (past): the gate fires before the expiry check
    spend_vault::set_allowance<USDC>(
        &mut v,
        &ocb,
        cid,
        500,
        u::start_ms(),
        option::none(),
        &clk,
        s.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = spend_vault::EExpiryInPast)]
// precedence: with a past expiry AND a CAS mismatch, EExpiryInPast wins over
// EUnexpectedAllowance (the expiry check fires before the CAS check).
fun precedence_expiry_in_past_beats_cas_mismatch() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    s.next_tx(OWNER);
    let mut v = u::take_vault(&s);
    let oc = u::take_owner_cap(&s, OWNER);
    let clk = u::take_clock(&s);
    // create so a CAS could otherwise be evaluated, then trigger past-expiry + CAS mismatch
    spend_vault::set_allowance<USDC>(&mut v, &oc, cid, 400, MAXU64, option::none(), &clk, s.ctx());
    // expiry == now (past) AND CAS expects 999 (mismatch): the expiry check fires first
    spend_vault::set_allowance<USDC>(
        &mut v,
        &oc,
        cid,
        250,
        u::start_ms(),
        option::some(999),
        &clk,
        s.ctx(),
    );
    abort
}

// === set_allowance is upsert, never ENoAllowance ===

#[test]
// set_allowance on a never-granted (cap, T) does NOT abort ENoAllowance; it CREATES
// (the upsert), distinguishing set_allowance from spend.
fun set_allowance_on_absent_never_no_allowance() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let clk = u::take_clock(&s);
        // FOO never granted; this creates rather than aborting ENoAllowance.
        assert!(!spend_vault::contains<FOO>(&v, cid));
        spend_vault::set_allowance<FOO>(
            &mut v,
            &oc,
            cid,
            123,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        assert!(spend_vault::contains<FOO>(&v, cid));
        assert_eq!(spend_vault::allowance<FOO>(&v, cid), 123);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// === cap_id stability: the load-bearing composition property ===

#[test]
// across create, raise, lower, suspend(0), renew-expiry, the SpenderCap object's id
// is unchanged and the SAME cap still spends under the final params. The owner uses
// cap_id (ID), never the cap object.
fun cap_id_stable_across_all_updates_then_spends() {
    let mut s = ts::begin(OWNER);

    // Setup in one tx: vault funded, cap minted+held by SPENDER, no grant yet.
    let cid_holder: ID;
    {
        let clk = u::clock_at(u::start_ms(), s.ctx());
        let (v, oc) = spend_vault::new(s.ctx());
        let vid = object::id(&v);
        spend_vault::deposit(&v, coin::mint_for_testing<USDC>(10_000, s.ctx()), s.ctx());
        let cap = spend_vault::mint_cap(&v, &oc, s.ctx());
        cid_holder = object::id(&cap);
        let _ = vid;
        transfer::public_transfer(cap, SPENDER);
        spend_vault::share(v);
        transfer::public_transfer(oc, OWNER);
        clk.share_for_testing();
    };
    let cid = cid_holder;

    // Owner runs the full lifecycle of param changes, all keyed by cid.
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let clk = u::take_clock(&s);
        let exp = u::start_ms() + 1_000_000;

        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            500,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        ); // create
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            900,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        ); // raise
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            200,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        ); // lower
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            0,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        ); // suspend
        spend_vault::set_allowance<USDC>(&mut v, &oc, cid, 350, exp, option::none(), &clk, s.ctx()); // revive + renew expiry

        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 350);
        assert_eq!(spend_vault::expiry<USDC>(&v, cid), exp);

        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };

    // The cap held by SPENDER is unchanged: its id still equals cid, and it spends
    // under the final params (350).
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        // cap object id is bit-stable across every owner update.
        assert_eq!(object::id(&cap), cid);

        let b = spend_vault::spend<USDC>(&mut v, &cap, 350, &clk, s.ctx());
        assert_eq!(b.value(), 350);
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 0);
        destroy(b);

        ts::return_to_sender(&s, cap);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// === granted_coin_types completeness / un-griefability ===

#[test]
// set_allowance<USDC>-create then <SUIT>-create => granted_coin_types is
// {USDC, SUIT}; re-set<USDC> (update) does NOT duplicate; a deposit<FOO> does NOT
// add FOO (permissionless funding writes no on-chain type set).
fun granted_coin_types_sole_writer_and_ungriefable() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let clk = u::take_clock(&s);

        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            500,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::set_allowance<SUIT>(
            &mut v,
            &oc,
            cid,
            300,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );

        let gct = spend_vault::granted_coin_types(&v);
        assert_eq!(gct.length(), 2);
        assert!(gct.contains(&type_name::with_defining_ids<USDC>()));
        assert!(gct.contains(&type_name::with_defining_ids<SUIT>()));

        // re-set USDC (update, not create) does not duplicate the type.
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            999,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        assert_eq!(spend_vault::granted_coin_types(&v).length(), 2);

        // a permissionless deposit<FOO> writes NO on-chain type set.
        spend_vault::deposit(&v, coin::mint_for_testing<FOO>(50, s.ctx()), s.ctx());
        let gct2 = spend_vault::granted_coin_types(&v);
        assert_eq!(gct2.length(), 2);
        assert!(!gct2.contains(&type_name::with_defining_ids<FOO>()));

        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// A phantom cap_id (never minted) is accepted by set_allowance: it creates a fresh
// entry (AllowanceSet.was_created == true) and adds T to the grows-only
// granted_coin_types. After revoke<T> removes the entry, T STILL appears in
// granted_coin_types (the set is never pruned).
#[test]
fun phantom_cap_id_creates_entry_and_grows_granted_types_permanently() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    // A cap_id that was never minted: derived from an arbitrary address.
    let phantom = object::id_from_address(@0xDEAD);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let clk = u::take_clock(&s);

        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            phantom,
            500,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );

        // The phantom cap_id created a fresh entry: was_created == true.
        let evs = event::events_by_type<spend_vault::AllowanceSet>();
        assert_eq!(evs.length(), 1);
        assert_eq!(
            evs[0],
            spend_vault::test_new_allowance_set(
                vid,
                phantom,
                type_name::with_defining_ids<USDC>(),
                500,
                MAXU64,
                false,
                true,
                OWNER,
            ),
        );
        // USDC is now in granted_coin_types.
        let gct = spend_vault::granted_coin_types(&v);
        assert_eq!(gct.length(), 1);
        assert!(gct.contains(&type_name::with_defining_ids<USDC>()));

        // Revoke the phantom entry: it is removed, but USDC stays in granted_coin_types.
        let was_present = spend_vault::revoke<USDC>(&mut v, &oc, phantom, s.ctx());
        assert!(was_present);
        assert!(!spend_vault::contains<USDC>(&v, phantom));
        // grows-only: USDC is never pruned from granted_coin_types.
        let gct2 = spend_vault::granted_coin_types(&v);
        assert_eq!(gct2.length(), 1);
        assert!(gct2.contains(&type_name::with_defining_ids<USDC>()));

        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// === per-(cap,coin) no-reset independence ===

#[test]
// set USDC, SUIT, DEEP on one cap; updating USDC's remaining leaves SUIT and DEEP
// entries bit-identical (no iteration, no sibling access).
fun set_allowance_per_coin_no_reset() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    let suit_exp = u::start_ms() + 7_000;
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let clk = u::take_clock(&s);

        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            500,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::set_allowance<SUIT>(
            &mut v,
            &oc,
            cid,
            300,
            suit_exp,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::set_allowance<DEEP>(
            &mut v,
            &oc,
            cid,
            700,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );

        // update only USDC.
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            50,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );

        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 50);
        // SUIT bit-identical (remaining + expiry).
        assert_eq!(spend_vault::allowance<SUIT>(&v, cid), 300);
        assert_eq!(spend_vault::expiry<SUIT>(&v, cid), suit_exp);
        // DEEP bit-identical.
        assert_eq!(spend_vault::allowance<DEEP>(&v, cid), 700);
        assert_eq!(spend_vault::expiry<DEEP>(&v, cid), MAXU64);

        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

#[test]
// cross-cap: two caps each set for USDC are independent entries; updating cap-X's
// USDC never alters cap-Y's USDC (distinct cap_ids = distinct keys).
fun set_allowance_cross_cap_independent() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);

    let cid_x: ID;
    let cid_y: ID;
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let clk = u::take_clock(&s);

        let cap_x = spend_vault::mint_cap(&v, &oc, s.ctx());
        let cap_y = spend_vault::mint_cap(&v, &oc, s.ctx());
        cid_x = object::id(&cap_x);
        cid_y = object::id(&cap_y);
        let _ = vid;

        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid_x,
            500,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid_y,
            300,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );

        // update cap-X only.
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid_x,
            50,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        assert_eq!(spend_vault::allowance<USDC>(&v, cid_x), 50);
        // cap-Y untouched.
        assert_eq!(spend_vault::allowance<USDC>(&v, cid_y), 300);

        transfer::public_transfer(cap_x, SPENDER);
        transfer::public_transfer(cap_y, SPENDER);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// === Additional coverage ===

#[test]
// the SpenderCapMinted.by is ctx.sender(); minting via a NON-owner-address sender
// that holds the OwnerCap still attributes `by` to that sender (the cap, not
// identity, is the gate). Here OWNER holds the cap but a second tx sender mints.
fun mint_cap_by_is_sender_not_owner_identity() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    // Move the OwnerCap to SPENDER, then SPENDER mints: `by` must be SPENDER.
    s.next_tx(OWNER);
    {
        let oc = u::take_owner_cap(&s, OWNER);
        transfer::public_transfer(oc, SPENDER);
    };
    s.next_tx(SPENDER);
    {
        let v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, SPENDER);
        let cap = spend_vault::mint_cap(&v, &oc, s.ctx());
        let cid = object::id(&cap);
        let evs = event::events_by_type<spend_vault::SpenderCapMinted>();
        assert_eq!(evs.length(), 1);
        assert_eq!(evs[0], spend_vault::test_new_spender_cap_minted(vid, cid, SPENDER));
        transfer::public_transfer(cap, SPENDER);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

#[test]
// suspension via amount 0 on a PRESENT entry overwrites in place; the AllowanceSet
// carries new_amount==0 and was_created==false (not a create).
fun set_allowance_suspend_event_flags() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let clk = u::take_clock(&s);
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            500,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            0,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        let evs = event::events_by_type<spend_vault::AllowanceSet>();
        assert_eq!(evs.length(), 2);
        assert_eq!(
            evs[1],
            spend_vault::test_new_allowance_set(
                vid,
                cid,
                type_name::with_defining_ids<USDC>(),
                0,
                MAXU64,
                false,
                false,
                OWNER,
            ),
        );
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

#[test]
// a finite-value CAS match (Some(200) on a 200 entry) overwrites; the new entry
// reflects the new amount AND a new finite future expiry in one call.
fun set_allowance_cas_match_with_new_expiry() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    let exp = u::start_ms() + 9_000;
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let clk = u::take_clock(&s);
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            200,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            150,
            exp,
            option::some(200),
            &clk,
            s.ctx(),
        );
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 150);
        assert_eq!(spend_vault::expiry<USDC>(&v, cid), exp);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

#[test]
// granted_coin_types is grows-only and stable: after revoke removes a (cap, T)
// entry it still lists T (the set is not pruned). Verified indirectly here by
// re-setting the same T (update) leaving length unchanged across the lifecycle.
fun granted_coin_types_grows_only_no_dup_across_lifecycle() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let clk = u::take_clock(&s);
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            500,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        assert_eq!(spend_vault::granted_coin_types(&v).length(), 1);
        // suspend (update), revive (update), raise (update): no new type entry.
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            0,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            500,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            900,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        assert_eq!(spend_vault::granted_coin_types(&v).length(), 1);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

#[test]
// minting two caps and setting an allowance on only ONE leaves the other cap
// entry-less (mint creates no entry; only the targeted set_allowance does).
fun set_allowance_targets_only_named_cap() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);

    let cid_a: ID;
    let cid_b: ID;
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let clk = u::take_clock(&s);

        let cap_a = spend_vault::mint_cap(&v, &oc, s.ctx());
        let cap_b = spend_vault::mint_cap(&v, &oc, s.ctx());
        cid_a = object::id(&cap_a);
        cid_b = object::id(&cap_b);
        let _ = vid;

        // grant only cap A.
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid_a,
            500,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        assert!(spend_vault::contains<USDC>(&v, cid_a));
        // cap B has NO entry (mint created none, no set targeted it).
        assert!(!spend_vault::contains<USDC>(&v, cid_b));
        assert_eq!(spend_vault::allowance<USDC>(&v, cid_b), 0);

        transfer::public_transfer(cap_a, SPENDER);
        transfer::public_transfer(cap_b, SPENDER);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

#[test]
// revoke<USDC> on one coin of a multi-coin cap leaves SUIT spendable (per-coin
// independence on the owner verb pair). granted_coin_types stays grows-only.
fun revoke_one_coin_leaves_other_grant_intact() {
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    let cid = mint_one_cap(&mut s, vid);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let clk = u::take_clock(&s);
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            500,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::set_allowance<SUIT>(
            &mut v,
            &oc,
            cid,
            300,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );

        let was_present = spend_vault::revoke<USDC>(&mut v, &oc, cid, s.ctx());
        assert!(was_present);
        // USDC gone, SUIT intact.
        assert!(!spend_vault::contains<USDC>(&v, cid));
        assert!(spend_vault::contains<SUIT>(&v, cid));
        assert_eq!(spend_vault::allowance<SUIT>(&v, cid), 300);
        // granted_coin_types is grows-only: USDC still listed though its entry is gone.
        let gct = spend_vault::granted_coin_types(&v);
        assert_eq!(gct.length(), 2);
        assert!(gct.contains(&type_name::with_defining_ids<USDC>()));

        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// === CAS under interleaving / read-derived updates ===

// Given a spend was sequenced between the owner's read and write, when the CAS
// expects the stale pre-spend value, it aborts EUnexpectedAllowance. This drives
// the value stale via a REAL interleaved spend (the race CAS defends), unlike the
// literal-seeded set_allowance_cas_mismatch_aborts.
#[test, expected_failure(abort_code = spend_vault::EUnexpectedAllowance)]
fun set_allowance_cas_stale_after_spend_aborts() {
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 10_000, 400, MAXU64);
    // A spend lands first: remaining 400 -> 350.
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        let b = spend_vault::spend<USDC>(&mut v, &cap, 50, &clk, s.ctx());
        destroy(b);
        ts::return_to_sender(&s, cap);
        u::return_vault(v);
        u::return_clock(clk);
    };
    // Owner CAS-updates against the STALE pre-spend value 400 -> aborts.
    s.next_tx(OWNER);
    let mut v = u::take_vault(&s);
    let clk = u::take_clock(&s);
    let oc = u::take_owner_cap(&s, OWNER);
    spend_vault::set_allowance<USDC>(
        &mut v,
        &oc,
        cid,
        200,
        MAXU64,
        option::some(400),
        &clk,
        s.ctx(),
    );
    abort
}

// Given the owner reads allowance then CAS-updates with that exact value in ONE tx,
// it succeeds (read-decide-write is atomic on the locked shared Vault: the
// documented race-free idiom).
#[test]
fun set_allowance_read_then_cas_atomic_succeeds() {
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 10_000, 400, MAXU64);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let current = spend_vault::allowance<USDC>(&v, cid); // read
        // CAS on the value just read, same tx: proceeds iff nothing raced in between.
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cid,
            250,
            MAXU64,
            option::some(current),
            &clk,
            s.ctx(),
        );
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 250);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// Given interleaved deposit + partial withdraw + revoke on a DIFFERENT cap, it
// leaves the target (capA, USDC) entry bit-identical (only spend lowers it, only
// set_allowance raises it).
#[test]
fun set_allowance_target_entry_stable_under_interleaving() {
    let mut s = ts::begin(OWNER);
    let cida;
    let cidb;
    {
        let clk = u::clock_at(u::start_ms(), s.ctx());
        let (mut v, oc) = spend_vault::new(s.ctx());
        spend_vault::deposit(&v, coin::mint_for_testing<USDC>(10_000, s.ctx()), s.ctx());
        let capa = spend_vault::mint_cap(&v, &oc, s.ctx());
        cida = object::id(&capa);
        let capb = spend_vault::mint_cap(&v, &oc, s.ctx());
        cidb = object::id(&capb);
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cida,
            400,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        spend_vault::set_allowance<USDC>(
            &mut v,
            &oc,
            cidb,
            700,
            MAXU64,
            option::none(),
            &clk,
            s.ctx(),
        );
        transfer::public_transfer(capa, SPENDER);
        transfer::public_transfer(capb, SPENDER);
        spend_vault::share(v);
        transfer::public_transfer(oc, OWNER);
        clk.share_for_testing();
    };
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        // Operations that must NOT touch (capA, USDC):
        spend_vault::deposit(&v, coin::mint_for_testing<USDC>(5_000, s.ctx()), s.ctx());
        let b = spend_vault::withdraw<USDC>(&mut v, &oc, 1_000, s.ctx());
        destroy(b);
        let _ = spend_vault::revoke<USDC>(&mut v, &oc, cidb, s.ctx()); // a DIFFERENT cap
        // (capA, USDC) is bit-identical.
        assert_eq!(spend_vault::allowance<USDC>(&v, cida), 400);
        assert_eq!(spend_vault::expiry<USDC>(&v, cida), MAXU64);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

// === Helpers ===

/// Mint one cap, transfer it to SPENDER, return its cap_id. Runs in a fresh OWNER
/// tx after a vault already exists (e.g. via new_funded_vault).
fun mint_one_cap(s: &mut ts::Scenario, _vid: ID): ID {
    s.next_tx(OWNER);
    let v = u::take_vault(s);
    let oc = u::take_owner_cap(s, OWNER);
    let cap = spend_vault::mint_cap(&v, &oc, s.ctx());
    let cid = object::id(&cap);
    transfer::public_transfer(cap, SPENDER);
    ts::return_to_sender(s, oc);
    u::return_vault(v);
    cid
}
