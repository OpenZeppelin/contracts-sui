// Unit coverage for the non-root vault reads: allowance<T>, expiry<T>,
// contains<T>, granted_coin_types, owner_cap_vault_id, spender_cap_vault_id.
// These reads are total (every read returns a documented default and never
// aborts, in any vault state), and this file pins their definitional values
// and the absent-vs-suspended disambiguation.
//
// NOTE: balance_value<T> and spendable_now<T> take &AccumulatorRoot, which the
// unit-test VM cannot construct; those reads are covered by integration tests.
module openzeppelin_allowance::spend_vault_reads_tests;

use openzeppelin_allowance::spend_vault::{Self, SpenderCap};
use openzeppelin_allowance::sv_test_utils::{Self as u, USDC, SUIT, DEEP, FOO};
use std::type_name;
use std::unit_test::assert_eq;
use sui::test_scenario as ts;

const OWNER: address = @0xA;
const SPENDER: address = @0xB;
const MAXU64: u64 = 18_446_744_073_709_551_615;

// === allowance<T> ===

#[test]
fun allowance_absent_is_zero() {
    // A never-granted (cap, T) reads 0, no abort.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        // granted for USDC, but FOO was never granted on this cap.
        assert_eq!(spend_vault::allowance<FOO>(&v, cid), 0);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun allowance_live_grant_is_raw_remaining() {
    // allowance == raw remaining of the live entry.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 500);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun allowance_suspended_entry_is_zero() {
    // A suspended (remaining==0) entry reads 0 (same surface value as absent).
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 0, MAXU64);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 0);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun allowance_unlimited_entry_is_sentinel() {
    // An unlimited grant reads the u64::MAX sentinel, not a volume.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, MAXU64, MAXU64);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), MAXU64);
        u::return_vault(v);
    };
    s.end();
}

// === expiry<T> ===

#[test]
fun expiry_absent_is_zero() {
    // Absent (cap, T) -> expiry 0, no abort.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        assert_eq!(spend_vault::expiry<FOO>(&v, cid), 0);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun expiry_finite_grant_is_raw_value() {
    // expiry == the raw finite expires_at_ms of the entry.
    let mut s = ts::begin(OWNER);
    let exp = u::start_ms() + 5_000;
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, exp);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        assert_eq!(spend_vault::expiry<USDC>(&v, cid), exp);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun expiry_no_expiry_grant_is_sentinel() {
    // A no-expiry grant reads the u64::MAX sentinel.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        assert_eq!(spend_vault::expiry<USDC>(&v, cid), MAXU64);
        u::return_vault(v);
    };
    s.end();
}

// === contains<T>: the absent-vs-suspended disambiguator ===

#[test]
fun contains_absent_is_false() {
    // A never-granted (cap, T) is NOT in the ledger.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        assert!(!spend_vault::contains<FOO>(&v, cid));
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun contains_live_grant_is_true() {
    // A live grant is present.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        assert!(spend_vault::contains<USDC>(&v, cid));
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun contains_suspended_at_zero_is_true() {
    // The disambiguator. allowance==0 AND contains==true means SUSPENDED
    // (cap still valid), distinct from a never-granted/revoked entry.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 0, MAXU64);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 0); // looks empty by value
        assert!(spend_vault::contains<USDC>(&v, cid)); // but the entry is live
        u::return_vault(v);
    };
    s.end();
}

// === granted_coin_types ===

#[test]
fun granted_coin_types_fresh_vault_is_empty() {
    // A fresh vault (no grants) has an empty granted-type set.
    let mut s = ts::begin(OWNER);
    // new_funded_vault funds USDC but grants nothing -> the granted set stays empty.
    let _vid = u::new_funded_vault<USDC>(&mut s, OWNER, 1_000);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        assert_eq!(spend_vault::granted_coin_types(&v).length(), 0);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun granted_coin_types_lists_both_granted_types() {
    // After granting USDC and SUIT on one cap, both appear (length 2).
    let mut s = ts::begin(OWNER);
    let _cid = build_two_grant_cap(&mut s);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        let types = spend_vault::granted_coin_types(&v);
        assert_eq!(types.length(), 2);
        assert!(types.contains(&type_name::with_defining_ids<USDC>()));
        assert!(types.contains(&type_name::with_defining_ids<SUIT>()));
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun granted_coin_types_excludes_deposited_only_types() {
    // deposit<T> writes NO type set. A deposited-only coin (DEEP) is never
    // enumerated; only the owner-granted USDC is.
    let mut s = ts::begin(OWNER);
    {
        let (mut v, oc) = spend_vault::new(s.ctx());
        let clk = u::clock_at(u::start_ms(), s.ctx());
        // grant USDC (records USDC), but only DEPOSIT DEEP (records nothing).
        spend_vault::deposit(&v, sui::coin::mint_for_testing<DEEP>(1_000, s.ctx()), s.ctx());
        let cap = spend_vault::mint_cap(&v, &oc, s.ctx());
        let cid = object::id(&cap);
        spend_vault::set_allowance<USDC>(&mut v, &oc, cid, 500, MAXU64, option::none(), &clk, s.ctx());
        transfer::public_transfer(cap, SPENDER);
        spend_vault::share(v);
        transfer::public_transfer(oc, OWNER);
        clk.share_for_testing();
    };
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        let types = spend_vault::granted_coin_types(&v);
        assert_eq!(types.length(), 1);
        assert!(types.contains(&type_name::with_defining_ids<USDC>()));
        assert!(!types.contains(&type_name::with_defining_ids<DEEP>())); // deposited-only excluded
        u::return_vault(v);
    };
    s.end();
}

// === Cap binding reads ===

#[test]
fun owner_cap_vault_id_matches_vault() {
    // owner_cap_vault_id(&oc) == object::id(&v).
    let mut s = ts::begin(OWNER);
    let (vid, _cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        assert_eq!(spend_vault::owner_cap_vault_id(&oc), vid);
        assert_eq!(spend_vault::owner_cap_vault_id(&oc), object::id(&v));
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun spender_cap_vault_id_matches_vault() {
    // spender_cap_vault_id(&cap) == object::id(&v).
    let mut s = ts::begin(OWNER);
    let (vid, _cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(SPENDER);
    {
        let v = u::take_vault(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        assert_eq!(spend_vault::spender_cap_vault_id(&cap), vid);
        assert_eq!(spend_vault::spender_cap_vault_id(&cap), object::id(&v));
        ts::return_to_sender(&s, cap);
        u::return_vault(v);
    };
    s.end();
}

// === Totality sweeps ===

#[test]
fun reads_after_revoke_all_default_and_never_abort() {
    // After a (cap, T) is granted then revoked, EVERY read returns a default
    // (allowance 0, expiry 0, contains false) and NONE aborts.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    // Owner revokes the (cap, USDC) entry.
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let was_present = spend_vault::revoke<USDC>(&mut v, &oc, cid, s.ctx());
        assert!(was_present);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    // Now every read on the revoked (cap, USDC) is at its default, no abort.
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 0);
        assert_eq!(spend_vault::expiry<USDC>(&v, cid), 0);
        assert!(!spend_vault::contains<USDC>(&v, cid));
        // granted_coin_types is grows-only: USDC stays recorded even after revoke.
        assert_eq!(spend_vault::granted_coin_types(&v).length(), 1);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun reads_on_fresh_never_touched_cap_id_are_defaults() {
    // A brand-new cap_id that was never set against the vault: every read
    // defaults (allowance 0, expiry 0, contains false), no abort.
    let mut s = ts::begin(OWNER);
    let (_vid, _cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        // Mint a fresh, budgetless cap: a never-touched cap_id.
        let fresh = spend_vault::mint_cap(&v, &oc, s.ctx());
        let fresh_id = object::id(&fresh);

        assert_eq!(spend_vault::allowance<USDC>(&v, fresh_id), 0);
        assert_eq!(spend_vault::expiry<USDC>(&v, fresh_id), 0);
        assert!(!spend_vault::contains<USDC>(&v, fresh_id));

        spend_vault::delete_orphaned_cap(fresh);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun reads_on_unrelated_arbitrary_cap_id_are_defaults() {
    // Reads keyed by a cap_id belonging to a DIFFERENT vault still default
    // cleanly (the lookup is just absent), never abort.
    let mut s = ts::begin(OWNER);
    let (_vid, _cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        // A foreign vault's owner cap id, unknown to this vault's ledger.
        let (vb, ocb) = spend_vault::new(s.ctx());
        let foreign_id = object::id(&ocb);

        assert_eq!(spend_vault::allowance<USDC>(&v, foreign_id), 0);
        assert_eq!(spend_vault::expiry<SUIT>(&v, foreign_id), 0);
        assert!(!spend_vault::contains<DEEP>(&v, foreign_id));

        spend_vault::share(vb);
        transfer::public_transfer(ocb, OWNER);
        u::return_vault(v);
    };
    s.end();
}

// === Helpers ===

/// One tx: vault funded with USDC + SUIT, a cap granted both. Returns the cap_id.
fun build_two_grant_cap(s: &mut ts::Scenario): ID {
    let clk = u::clock_at(u::start_ms(), s.ctx());
    let (mut v, oc) = spend_vault::new(s.ctx());
    spend_vault::deposit(&v, sui::coin::mint_for_testing<USDC>(10_000, s.ctx()), s.ctx());
    spend_vault::deposit(&v, sui::coin::mint_for_testing<SUIT>(10_000, s.ctx()), s.ctx());
    let cap = spend_vault::mint_cap(&v, &oc, s.ctx());
    let cid = object::id(&cap);
    spend_vault::set_allowance<USDC>(&mut v, &oc, cid, 500, MAXU64, option::none(), &clk, s.ctx());
    spend_vault::set_allowance<SUIT>(&mut v, &oc, cid, 300, MAXU64, option::none(), &clk, s.ctx());
    transfer::public_transfer(cap, SPENDER);
    spend_vault::share(v);
    transfer::public_transfer(oc, OWNER);
    clk.share_for_testing();
    cid
}
