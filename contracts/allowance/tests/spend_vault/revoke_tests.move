// Unit coverage for the cap-disposal surface: revoke<T>, revoke_all, renounce,
// and delete_orphaned_cap. Exercises per-coin idempotent revoke, whole-cap
// revoke_all and renounce, orphaned-cap cleanup, cap/entry lifecycle
// independence, non-retroactive timing, and the canonical Revoked / Renounced /
// CapDeleted events.
//
// These paths never touch the accumulator, so there are no pool-balance effects
// to cover here.
module openzeppelin_allowance::spend_vault_revoke_tests;

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

// === revoke<T> ===

#[test]
fun revoke_live_entry_returns_true_and_removes() {
    // Revoke a live (cap, USDC) -> true, entry gone, one Revoked
    // {was_present: true}.
    let mut s = ts::begin(OWNER);
    let (vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);

        let was_present = spend_vault::revoke<USDC>(&mut v, &oc, cid, s.ctx());
        assert!(was_present);
        assert!(!spend_vault::contains<USDC>(&v, cid));

        let evs = event::events_by_type<spend_vault::Revoked>();
        assert_eq!(evs.length(), 1);
        assert_eq!(
            evs[0],
            spend_vault::test_new_revoked(vid, cid, type_name::with_defining_ids<USDC>(), true, OWNER),
        );

        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun revoke_again_is_idempotent_no_op() {
    // A second revoke of the now-absent (cap, USDC) -> false, NO abort,
    // one Revoked {was_present: false} (the typo'd-cap_id signal).
    let mut s = ts::begin(OWNER);
    let (vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let first = spend_vault::revoke<USDC>(&mut v, &oc, cid, s.ctx());
        assert!(first);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    // second revoke in its own tx for a clean event count.
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let again = spend_vault::revoke<USDC>(&mut v, &oc, cid, s.ctx());
        assert!(!again);
        let evs = event::events_by_type<spend_vault::Revoked>();
        assert_eq!(evs.length(), 1);
        assert_eq!(
            evs[0],
            spend_vault::test_new_revoked(vid, cid, type_name::with_defining_ids<USDC>(), false, OWNER),
        );
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun revoke_never_granted_coin_returns_false() {
    // Revoking a (cap, FOO) that was never granted -> false, no abort.
    let mut s = ts::begin(OWNER);
    let (vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let was_present = spend_vault::revoke<FOO>(&mut v, &oc, cid, s.ctx());
        assert!(!was_present);
        let evs = event::events_by_type<spend_vault::Revoked>();
        assert_eq!(evs.length(), 1);
        assert_eq!(
            evs[0],
            spend_vault::test_new_revoked(vid, cid, type_name::with_defining_ids<FOO>(), false, OWNER),
        );
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun revoke_one_coin_leaves_other_coin_intact() {
    // revoke<USDC> on a USDC+SUIT cap leaves (cap, SUIT)
    // live and spendable.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = build_two_coin_cap(&mut s);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let was_present = spend_vault::revoke<USDC>(&mut v, &oc, cid, s.ctx());
        assert!(was_present);
        assert!(!spend_vault::contains<USDC>(&v, cid));
        // SUIT untouched.
        assert!(spend_vault::contains<SUIT>(&v, cid));
        assert_eq!(spend_vault::allowance<SUIT>(&v, cid), 300);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    // SUIT still spendable.
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        let b = spend_vault::spend<SUIT>(&mut v, &cap, 100, &clk, s.ctx());
        assert_eq!(b.value(), 100);
        assert_eq!(spend_vault::allowance<SUIT>(&v, cid), 200);
        destroy(b);
        ts::return_to_sender(&s, cap);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

#[test, expected_failure(abort_code = spend_vault::EWrongOwnerCap)]
fun revoke_foreign_owner_cap_aborts() {
    // revoke's only abort is EWrongOwnerCap.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(OWNER);
    {
        let mut va = u::take_vault(&s);
        // an OwnerCap bound to a DIFFERENT vault.
        let (_vb, ocb) = spend_vault::new(s.ctx());
        spend_vault::revoke<USDC>(&mut va, &ocb, cid, s.ctx()); // EWrongOwnerCap
        abort
    }
}

#[test, expected_failure(abort_code = spend_vault::ENoAllowance)]
fun revoke_then_spend_aborts_no_allowance() {
    // After revoke the (cap, USDC) entry is truly gone, so a subsequent spend
    // aborts ENoAllowance (not suspended-at-zero).
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let _ = spend_vault::revoke<USDC>(&mut v, &oc, cid, s.ctx());
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        let _b = spend_vault::spend<USDC>(&mut v, &cap, 100, &clk, s.ctx()); // ENoAllowance
        abort
    }
}

#[test]
fun revoke_non_retroactive_spend_first_then_revoke() {
    // A spend sequenced BEFORE the owner's revoke succeeds and is not
    // clawed back; the later revoke also succeeds.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    // tx A: spend succeeds.
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        let b = spend_vault::spend<USDC>(&mut v, &cap, 200, &clk, s.ctx());
        assert_eq!(b.value(), 200);
        assert_eq!(spend_vault::allowance<USDC>(&v, cid), 300);
        destroy(b);
        ts::return_to_sender(&s, cap);
        u::return_vault(v);
        u::return_clock(clk);
    };
    // tx B: revoke succeeds (was_present true, the spend stands).
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let was_present = spend_vault::revoke<USDC>(&mut v, &oc, cid, s.ctx());
        assert!(was_present);
        assert!(!spend_vault::contains<USDC>(&v, cid));
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

#[test, expected_failure(abort_code = spend_vault::ENoAllowance)]
fun revoke_non_retroactive_revoke_first_then_spend_aborts() {
    // Reversed order: revoke (tx A) then spend (tx B) -> ENoAllowance.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let _ = spend_vault::revoke<USDC>(&mut v, &oc, cid, s.ctx());
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        let _b = spend_vault::spend<USDC>(&mut v, &cap, 100, &clk, s.ctx()); // ENoAllowance
        abort
    }
}

#[test]
fun revoke_suspended_entry_returns_true() {
    // No allowance state can race revoke into failure. A suspended
    // (remaining == 0) entry is still present, so revoke returns true and removes it.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 0, MAXU64); // suspended
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        assert!(spend_vault::contains<USDC>(&v, cid)); // suspended-but-present
        let was_present = spend_vault::revoke<USDC>(&mut v, &oc, cid, s.ctx());
        assert!(was_present);
        assert!(!spend_vault::contains<USDC>(&v, cid));
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun revoke_unlimited_entry_returns_true() {
    // An unlimited (remaining == u64::MAX) grant is ordinary to
    // revoke; the sentinel state does not block removal.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, MAXU64, MAXU64);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        let was_present = spend_vault::revoke<USDC>(&mut v, &oc, cid, s.ctx());
        assert!(was_present);
        assert!(!spend_vault::contains<USDC>(&v, cid));
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun revoke_expired_entry_returns_true() {
    // An EXPIRED entry cannot race revoke into failure; revoke is
    // time-blind and removes it, returning true.
    let mut s = ts::begin(OWNER);
    let exp = u::start_ms() + 1_000;
    let (_vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, exp);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        // the clock is irrelevant: revoke never reads it.
        let was_present = spend_vault::revoke<USDC>(&mut v, &oc, cid, s.ctx());
        assert!(was_present);
        assert!(!spend_vault::contains<USDC>(&v, cid));
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

// === revoke_all ===

#[test]
fun revoke_all_three_coin_cap_removes_all() {
    // A 3-coin cap (USDC, SUIT, DEEP) -> revoke_all removes all
    // three, emits 3 Revoked, every contains is false afterward.
    let mut s = ts::begin(OWNER);
    let (vid, cid) = build_three_coin_cap(&mut s);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        spend_vault::revoke_all(&mut v, &oc, cid, s.ctx());

        // one Revoked per removed coin (order is granted_coin_types insertion order,
        // but we assert by membership for robustness).
        let evs = event::events_by_type<spend_vault::Revoked>();
        assert_eq!(evs.length(), 3);
        assert!(evs.contains(&revoked_ev(vid, cid, type_name::with_defining_ids<USDC>())));
        assert!(evs.contains(&revoked_ev(vid, cid, type_name::with_defining_ids<SUIT>())));
        assert!(evs.contains(&revoked_ev(vid, cid, type_name::with_defining_ids<DEEP>())));

        assert!(!spend_vault::contains<USDC>(&v, cid));
        assert!(!spend_vault::contains<SUIT>(&v, cid));
        assert!(!spend_vault::contains<DEEP>(&v, cid));

        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

#[test, expected_failure(abort_code = spend_vault::ENoAllowance)]
fun revoke_all_then_spend_aborts_no_allowance() {
    // After revoke_all every (cap, T) is gone, so spends abort ENoAllowance.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = build_three_coin_cap(&mut s);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        spend_vault::revoke_all(&mut v, &oc, cid, s.ctx());
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        let _b = spend_vault::spend<USDC>(&mut v, &cap, 100, &clk, s.ctx()); // ENoAllowance
        abort
    }
}

#[test]
fun revoke_all_zero_entry_cap_succeeds_no_events() {
    // revoke_all on a bare cap (no (cap, T) entries) succeeds and emits
    // nothing (total on ledger state).
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = bare_cap_vault(&mut s);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        spend_vault::revoke_all(&mut v, &oc, cid, s.ctx());
        let evs = event::events_by_type<spend_vault::Revoked>();
        assert_eq!(evs.length(), 0);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun revoke_all_does_not_touch_second_cap() {
    // revoke_all on cap1 leaves cap2's USDC live and spendable
    // (it only builds keys with this cap_id).
    let mut s = ts::begin(OWNER);
    let (_vid, cid1, cid2) = two_caps_both_usdc(&mut s);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        spend_vault::revoke_all(&mut v, &oc, cid1, s.ctx());
        // cap1 dead, cap2 untouched.
        assert!(!spend_vault::contains<USDC>(&v, cid1));
        assert!(spend_vault::contains<USDC>(&v, cid2));
        assert_eq!(spend_vault::allowance<USDC>(&v, cid2), 700);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    // cap2 still spendable (take it by id: both caps live at SPENDER).
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap2 = ts::take_from_address_by_id<SpenderCap>(&s, SPENDER, cid2);
        let b = spend_vault::spend<USDC>(&mut v, &cap2, 100, &clk, s.ctx());
        assert_eq!(b.value(), 100);
        assert_eq!(spend_vault::allowance<USDC>(&v, cid2), 600);
        destroy(b);
        ts::return_to_address(SPENDER, cap2);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

#[test, expected_failure(abort_code = spend_vault::EWrongOwnerCap)]
fun revoke_all_foreign_owner_cap_aborts() {
    // revoke_all's only abort is EWrongOwnerCap.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = build_three_coin_cap(&mut s);
    s.next_tx(OWNER);
    {
        let mut va = u::take_vault(&s);
        let (_vb, ocb) = spend_vault::new(s.ctx());
        spend_vault::revoke_all(&mut va, &ocb, cid, s.ctx()); // EWrongOwnerCap
        abort
    }
}

#[test]
fun revoke_all_ungriefable_by_permissionless_deposit() {
    // A permissionless deposit<FOO> of dust does NOT inflate
    // granted_coin_types; revoke_all still works over only the owner-granted types.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = build_two_coin_cap(&mut s); // owner granted {USDC, SUIT}
    // anyone deposits junk FOO dust (permissionless, confers no rights, writes no set).
    s.next_tx(@0xBAD);
    {
        let v = u::take_vault(&s);
        spend_vault::deposit<FOO>(&v, coin::mint_for_testing<FOO>(7, s.ctx()), s.ctx());
        // granted_coin_types is unchanged: still exactly the two owner grants.
        assert_eq!(spend_vault::granted_coin_types(&v).length(), 2);
        u::return_vault(v);
    };
    // revoke_all still removes exactly the owner-granted set, emits 2 Revoked.
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        spend_vault::revoke_all(&mut v, &oc, cid, s.ctx());
        let evs = event::events_by_type<spend_vault::Revoked>();
        assert_eq!(evs.length(), 2);
        assert!(!spend_vault::contains<USDC>(&v, cid));
        assert!(!spend_vault::contains<SUIT>(&v, cid));
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun revoke_all_single_coin_emits_one_revoked() {
    // A one-coin cap -> revoke_all emits exactly one Revoked and removes it.
    let mut s = ts::begin(OWNER);
    let (vid, cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        spend_vault::revoke_all(&mut v, &oc, cid, s.ctx());
        let evs = event::events_by_type<spend_vault::Revoked>();
        assert_eq!(evs.length(), 1);
        assert_eq!(evs[0], revoked_ev(vid, cid, type_name::with_defining_ids<USDC>()));
        assert!(!spend_vault::contains<USDC>(&v, cid));
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun revoke_all_twice_second_call_emits_nothing() {
    // revoke_all is total and idempotent; a second call on the same cap
    // (now empty) removes nothing and emits zero Revoked.
    let mut s = ts::begin(OWNER);
    let (_vid, cid) = build_two_coin_cap(&mut s);
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        spend_vault::revoke_all(&mut v, &oc, cid, s.ctx());
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        spend_vault::revoke_all(&mut v, &oc, cid, s.ctx()); // all probes are no-ops
        let evs = event::events_by_type<spend_vault::Revoked>();
        assert_eq!(evs.length(), 0);
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

// === renounce ===

#[test]
fun renounce_three_coin_cap_removes_all_and_deletes_cap() {
    // Renounce a cap with 3 live coin entries -> all removed, cap consumed,
    // one Renounced; the cap cannot be taken again.
    let mut s = ts::begin(OWNER);
    let (vid, cid) = build_three_coin_cap(&mut s);
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        spend_vault::renounce(&mut v, cap, s.ctx()); // consumes the cap

        assert!(!spend_vault::contains<USDC>(&v, cid));
        assert!(!spend_vault::contains<SUIT>(&v, cid));
        assert!(!spend_vault::contains<DEEP>(&v, cid));

        let evs = event::events_by_type<spend_vault::Renounced>();
        assert_eq!(evs.length(), 1);
        assert_eq!(evs[0], spend_vault::test_new_renounced(vid, cid, SPENDER));

        u::return_vault(v);
    };
    // The cap is gone: SPENDER holds no SpenderCap any more.
    s.next_tx(SPENDER);
    {
        assert!(!ts::has_most_recent_for_address<SpenderCap>(SPENDER));
    };
    s.end();
}

#[test]
fun renounce_already_revoked_entries_still_succeeds() {
    // Total on ledger state: a cap whose entries were ALL already revoked
    // still renounces successfully and the cap is deleted.
    let mut s = ts::begin(OWNER);
    let (vid, cid) = build_two_coin_cap(&mut s);
    // owner revokes everything first.
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        spend_vault::revoke_all(&mut v, &oc, cid, s.ctx());
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    // spender renounces the now-empty cap: still succeeds, cap deleted.
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        spend_vault::renounce(&mut v, cap, s.ctx());
        let evs = event::events_by_type<spend_vault::Renounced>();
        assert_eq!(evs.length(), 1);
        assert_eq!(evs[0], spend_vault::test_new_renounced(vid, cid, SPENDER));
        u::return_vault(v);
    };
    s.next_tx(SPENDER);
    {
        assert!(!ts::has_most_recent_for_address<SpenderCap>(SPENDER));
    };
    s.end();
}

#[test, expected_failure(abort_code = spend_vault::EWrongVault)]
fun renounce_foreign_cap_aborts() {
    // renounce's only abort is EWrongVault, a cap bound to a different vault.
    let mut s = ts::begin(OWNER);
    let (_vid, _cid) = u::setup_granted<USDC>(&mut s, OWNER, SPENDER, 1_000, 500, MAXU64);
    s.next_tx(SPENDER);
    {
        let mut va = u::take_vault(&s);
        // a cap bound to a DIFFERENT vault.
        let (vb, ocb) = spend_vault::new(s.ctx());
        let foreign = spend_vault::mint_cap(&vb, &ocb, s.ctx());
        spend_vault::renounce(&mut va, foreign, s.ctx()); // EWrongVault
        abort
    }
}

#[test]
fun renounce_one_cap_leaves_second_cap_intact() {
    // renounce only removes the renounced cap's own (cap, T)
    // entries (keyed by object::id(&cap)); a second cap's USDC stays live.
    let mut s = ts::begin(OWNER);
    let (_vid, cid1, cid2) = two_caps_both_usdc(&mut s);
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let cap1 = ts::take_from_address_by_id<SpenderCap>(&s, SPENDER, cid1);
        spend_vault::renounce(&mut v, cap1, s.ctx());
        // cap1 gone, cap2 untouched.
        assert!(!spend_vault::contains<USDC>(&v, cid1));
        assert!(spend_vault::contains<USDC>(&v, cid2));
        assert_eq!(spend_vault::allowance<USDC>(&v, cid2), 700);
        u::return_vault(v);
    };
    // cap2 still spendable.
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let clk = u::take_clock(&s);
        let cap2 = ts::take_from_address_by_id<SpenderCap>(&s, SPENDER, cid2);
        let b = spend_vault::spend<USDC>(&mut v, &cap2, 100, &clk, s.ctx());
        assert_eq!(b.value(), 100);
        destroy(b);
        ts::return_to_address(SPENDER, cap2);
        u::return_vault(v);
        u::return_clock(clk);
    };
    s.end();
}

// === delete_orphaned_cap ===

#[test]
fun delete_orphaned_cap_after_vault_destroyed() {
    // On an ORPHANED cap (vault destroyed first) -> succeeds, one
    // CapDeleted {vault_id, cap_id}.
    let mut s = ts::begin(OWNER);
    let (vid, cid) = bare_cap_vault(&mut s);
    // owner destroys the vault, orphaning the cap.
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        spend_vault::destroy(v, oc, s.ctx());
    };
    // the orphaned cap can still be disposed of.
    s.next_tx(SPENDER);
    {
        let cap = ts::take_from_sender<SpenderCap>(&s);
        spend_vault::delete_orphaned_cap(cap);
        let evs = event::events_by_type<spend_vault::CapDeleted>();
        assert_eq!(evs.length(), 1);
        assert_eq!(evs[0], spend_vault::test_new_cap_deleted(vid, cid));
    };
    s.end();
}

#[test]
fun delete_orphaned_cap_on_live_cap_strands_entries() {
    // Deleting a LIVE cap with 2 entries succeeds but STRANDS
    // both (contains<T> still true); the owner then revoke_all's to recover them.
    let mut s = ts::begin(OWNER);
    let (vid, cid) = build_two_coin_cap(&mut s);
    // spender deletes the live cap.
    s.next_tx(SPENDER);
    {
        let cap = ts::take_from_sender<SpenderCap>(&s);
        spend_vault::delete_orphaned_cap(cap);
        let evs = event::events_by_type<spend_vault::CapDeleted>();
        assert_eq!(evs.length(), 1);
        assert_eq!(evs[0], spend_vault::test_new_cap_deleted(vid, cid));
    };
    // entries STRANDED: still visible, no cap can re-match them.
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        assert!(spend_vault::contains<USDC>(&v, cid));
        assert!(spend_vault::contains<SUIT>(&v, cid));
        // owner cleanup: revoke_all recovers the stranded entries.
        let oc = u::take_owner_cap(&s, OWNER);
        spend_vault::revoke_all(&mut v, &oc, cid, s.ctx());
        assert!(!spend_vault::contains<USDC>(&v, cid));
        assert!(!spend_vault::contains<SUIT>(&v, cid));
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun delete_orphaned_cap_bare_live_cap_succeeds() {
    // delete_orphaned_cap is total and vault-blind; a bare cap (no
    // entries) on a still-LIVE vault deletes cleanly and emits CapDeleted.
    let mut s = ts::begin(OWNER);
    let (vid, cid) = bare_cap_vault(&mut s);
    s.next_tx(SPENDER);
    {
        let cap = ts::take_from_sender<SpenderCap>(&s);
        spend_vault::delete_orphaned_cap(cap);
        let evs = event::events_by_type<spend_vault::CapDeleted>();
        assert_eq!(evs.length(), 1);
        assert_eq!(evs[0], spend_vault::test_new_cap_deleted(vid, cid));
    };
    // the cap is gone.
    s.next_tx(SPENDER);
    {
        assert!(!ts::has_most_recent_for_address<SpenderCap>(SPENDER));
    };
    s.end();
}

// When granted_coin_types holds a coin (SUIT, via a 2nd cap) the target cap never
// held, revoke_all on the 1st cap skips SUIT (the loop's `if (contains(key))` FALSE
// branch: a no-op probe with no Revoked) and removes only USDC. One Revoked is
// emitted per present coin only; iterating granted_coin_types over an absent key is
// a harmless probe.
#[test]
fun revoke_all_skips_coin_target_cap_never_held() {
    let mut s = ts::begin(OWNER);
    // capX holds USDC; capY holds SUIT, so granted_coin_types = {USDC, SUIT}.
    let vid;
    let cidx;
    let cidy;
    {
        let clk = u::clock_at(u::start_ms(), s.ctx());
        let (mut v, oc) = spend_vault::new(s.ctx());
        vid = object::id(&v);
        spend_vault::deposit(&v, coin::mint_for_testing<USDC>(10_000, s.ctx()), s.ctx());
        spend_vault::deposit(&v, coin::mint_for_testing<SUIT>(10_000, s.ctx()), s.ctx());
        let capx = spend_vault::mint_cap(&v, &oc, s.ctx());
        cidx = object::id(&capx);
        let capy = spend_vault::mint_cap(&v, &oc, s.ctx());
        cidy = object::id(&capy);
        spend_vault::set_allowance<USDC>(&mut v, &oc, cidx, 500, MAXU64, option::none(), &clk, s.ctx());
        spend_vault::set_allowance<SUIT>(&mut v, &oc, cidy, 300, MAXU64, option::none(), &clk, s.ctx());
        transfer::public_transfer(capx, SPENDER);
        transfer::public_transfer(capy, SPENDER);
        spend_vault::share(v);
        transfer::public_transfer(oc, OWNER);
        clk.share_for_testing();
    };
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let oc = u::take_owner_cap(&s, OWNER);
        spend_vault::revoke_all(&mut v, &oc, cidx, s.ctx());
        // Exactly ONE Revoked (USDC, present); SUIT is in granted_coin_types but never
        // held by capX, so it is skipped with no emit.
        let evs = event::events_by_type<spend_vault::Revoked>();
        assert_eq!(evs.length(), 1);
        assert!(evs.contains(&revoked_ev(vid, cidx, type_name::with_defining_ids<USDC>())));
        assert!(!spend_vault::contains<USDC>(&v, cidx));
        assert!(spend_vault::contains<SUIT>(&v, cidy)); // capY untouched
        ts::return_to_sender(&s, oc);
        u::return_vault(v);
    };
    s.end();
}

// Given a permissionless junk-type deposit by a third party, when the spender
// renounces, iteration stays owner-bounded (granted_coin_types is not inflated) and
// renounce removes all held coins and deletes the cap. granted_coin_types is
// owner-written and un-griefable.
#[test]
fun renounce_ungriefable_by_permissionless_deposit() {
    let mut s = ts::begin(OWNER);
    let (vid, cid) = build_three_coin_cap(&mut s); // granted = {USDC, SUIT, DEEP}
    // A third party deposits junk FOO dust (permissionless; writes no granted type).
    s.next_tx(@0xBAD);
    {
        let v = u::take_vault(&s);
        spend_vault::deposit<FOO>(&v, coin::mint_for_testing<FOO>(7, s.ctx()), s.ctx());
        assert_eq!(spend_vault::granted_coin_types(&v).length(), 3); // not inflated
        u::return_vault(v);
    };
    // Spender renounces: iteration bounded by the 3 owner-granted types.
    s.next_tx(SPENDER);
    {
        let mut v = u::take_vault(&s);
        let cap = ts::take_from_sender<SpenderCap>(&s);
        spend_vault::renounce(&mut v, cap, s.ctx());
        assert!(!spend_vault::contains<USDC>(&v, cid));
        assert!(!spend_vault::contains<SUIT>(&v, cid));
        assert!(!spend_vault::contains<DEEP>(&v, cid));
        let evs = event::events_by_type<spend_vault::Renounced>();
        assert_eq!(evs.length(), 1);
        assert_eq!(evs[0], spend_vault::test_new_renounced(vid, cid, SPENDER));
        u::return_vault(v);
    };
    s.end();
}

// === Helpers ===

/// One tx: vault funded with USDC + SUIT, a cap granted both (500 / 300).
/// Returns (vid, cid). OwnerCap -> OWNER, SpenderCap -> SPENDER, Clock shared.
fun build_two_coin_cap(s: &mut ts::Scenario): (ID, ID) {
    let clk = u::clock_at(u::start_ms(), s.ctx());
    let (mut v, oc) = spend_vault::new(s.ctx());
    let vid = object::id(&v);
    spend_vault::deposit(&v, coin::mint_for_testing<USDC>(10_000, s.ctx()), s.ctx());
    spend_vault::deposit(&v, coin::mint_for_testing<SUIT>(10_000, s.ctx()), s.ctx());
    let cap = spend_vault::mint_cap(&v, &oc, s.ctx());
    let cid = object::id(&cap);
    spend_vault::set_allowance<USDC>(&mut v, &oc, cid, 500, MAXU64, option::none(), &clk, s.ctx());
    spend_vault::set_allowance<SUIT>(&mut v, &oc, cid, 300, MAXU64, option::none(), &clk, s.ctx());
    transfer::public_transfer(cap, SPENDER);
    spend_vault::share(v);
    transfer::public_transfer(oc, OWNER);
    clk.share_for_testing();
    (vid, cid)
}

/// One tx: vault funded with USDC + SUIT + DEEP, a cap granted all three
/// (500 / 300 / 100). Returns (vid, cid).
fun build_three_coin_cap(s: &mut ts::Scenario): (ID, ID) {
    let clk = u::clock_at(u::start_ms(), s.ctx());
    let (mut v, oc) = spend_vault::new(s.ctx());
    let vid = object::id(&v);
    spend_vault::deposit(&v, coin::mint_for_testing<USDC>(10_000, s.ctx()), s.ctx());
    spend_vault::deposit(&v, coin::mint_for_testing<SUIT>(10_000, s.ctx()), s.ctx());
    spend_vault::deposit(&v, coin::mint_for_testing<DEEP>(10_000, s.ctx()), s.ctx());
    let cap = spend_vault::mint_cap(&v, &oc, s.ctx());
    let cid = object::id(&cap);
    spend_vault::set_allowance<USDC>(&mut v, &oc, cid, 500, MAXU64, option::none(), &clk, s.ctx());
    spend_vault::set_allowance<SUIT>(&mut v, &oc, cid, 300, MAXU64, option::none(), &clk, s.ctx());
    spend_vault::set_allowance<DEEP>(&mut v, &oc, cid, 100, MAXU64, option::none(), &clk, s.ctx());
    transfer::public_transfer(cap, SPENDER);
    spend_vault::share(v);
    transfer::public_transfer(oc, OWNER);
    clk.share_for_testing();
    (vid, cid)
}

/// One tx: a shared vault with a BARE cap (minted, no (cap, T) entry). Returns
/// (vid, cid). OwnerCap -> OWNER, SpenderCap -> SPENDER, Clock shared.
fun bare_cap_vault(s: &mut ts::Scenario): (ID, ID) {
    let clk = u::clock_at(u::start_ms(), s.ctx());
    let (v, oc) = spend_vault::new(s.ctx());
    let vid = object::id(&v);
    let cap = spend_vault::mint_cap(&v, &oc, s.ctx());
    let cid = object::id(&cap);
    transfer::public_transfer(cap, SPENDER);
    spend_vault::share(v);
    transfer::public_transfer(oc, OWNER);
    clk.share_for_testing();
    (vid, cid)
}

/// One tx: a vault funded with USDC and TWO caps both granted USDC (cap1=500,
/// cap2=700), both SpenderCaps sent to SPENDER. Returns (vid, cid1, cid2).
fun two_caps_both_usdc(s: &mut ts::Scenario): (ID, ID, ID) {
    let clk = u::clock_at(u::start_ms(), s.ctx());
    let (mut v, oc) = spend_vault::new(s.ctx());
    let vid = object::id(&v);
    spend_vault::deposit(&v, coin::mint_for_testing<USDC>(10_000, s.ctx()), s.ctx());
    let cap1 = spend_vault::mint_cap(&v, &oc, s.ctx());
    let cid1 = object::id(&cap1);
    let cap2 = spend_vault::mint_cap(&v, &oc, s.ctx());
    let cid2 = object::id(&cap2);
    spend_vault::set_allowance<USDC>(&mut v, &oc, cid1, 500, MAXU64, option::none(), &clk, s.ctx());
    spend_vault::set_allowance<USDC>(&mut v, &oc, cid2, 700, MAXU64, option::none(), &clk, s.ctx());
    transfer::public_transfer(cap1, SPENDER);
    transfer::public_transfer(cap2, SPENDER);
    spend_vault::share(v);
    transfer::public_transfer(oc, OWNER);
    clk.share_for_testing();
    (vid, cid1, cid2)
}

/// Build the canonical Revoked{was_present: true, by: OWNER} value for a
/// revoke_all leg, for membership assertions over the emitted batch.
fun revoked_ev(vault_id: ID, cap_id: ID, coin_type: type_name::TypeName): spend_vault::Revoked {
    spend_vault::test_new_revoked(vault_id, cap_id, coin_type, true, OWNER)
}
