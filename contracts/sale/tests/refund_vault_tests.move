// RefundVault state-machine + cap-gating tests.
//
// The vault is a standalone escrow primitive: Active accepts deposits; the
// terminal states do not. Refunding supports per-amount releases; Closed
// supports a single full withdrawal. All mutations are cap-gated.
module openzeppelin_sale::refund_vault_tests;

use openzeppelin_sale::refund_vault;
use openzeppelin_sale::test_utils::{Self as u, USDC};
use std::unit_test::{assert_eq, destroy};
use sui::event;

// === Happy paths ===

#[test]
fun new_starts_active_and_empty() {
    let mut ctx = tx_context::dummy();
    let (vault, cap) = refund_vault::new<USDC>(&mut ctx);
    assert!(vault.is_active());
    assert_eq!(vault.value(), 0);
    assert_eq!(cap.cap_vault_id(), object::id(&vault));

    let created = event::events_by_type<refund_vault::RefundVaultCreated<USDC>>();
    assert_eq!(created.length(), 1);
    assert_eq!(
        created[0],
        refund_vault::test_new_refund_vault_created<USDC>(object::id(&vault), object::id(&cap)),
    );

    destroy(vault);
    destroy(cap);
}

#[test]
fun deposit_then_close_then_withdraw_all() {
    let mut ctx = tx_context::dummy();
    let (mut vault, cap) = refund_vault::new<USDC>(&mut ctx);

    vault.deposit(&cap, u::pay_balance(300));
    vault.deposit(&cap, u::pay_balance(700));
    assert_eq!(vault.value(), 1_000);

    vault.flip_to_closed(&cap);
    assert!(vault.is_closed());
    let out = vault.withdraw_all(&cap);
    assert_eq!(out.value(), 1_000);
    assert_eq!(vault.value(), 0);

    // Events: two deposits (300 then 700), one Active->Closed transition, one full release.
    let vid = object::id(&vault);
    let deposits = event::events_by_type<refund_vault::VaultDeposit<USDC>>();
    assert_eq!(deposits.length(), 2);
    assert_eq!(deposits[0], refund_vault::test_new_vault_deposit<USDC>(vid, 300, 300));
    assert_eq!(deposits[1], refund_vault::test_new_vault_deposit<USDC>(vid, 700, 1_000));
    let changes = event::events_by_type<refund_vault::VaultStateChanged<USDC>>();
    assert_eq!(changes.length(), 1);
    assert_eq!(
        changes[0],
        refund_vault::test_new_vault_state_changed<USDC>(
            vid,
            refund_vault::test_state_active(),
            refund_vault::test_state_closed(),
        ),
    );
    let releases = event::events_by_type<refund_vault::VaultRelease<USDC>>();
    assert_eq!(releases.length(), 1);
    assert_eq!(releases[0], refund_vault::test_new_vault_release<USDC>(vid, 1_000, 0));

    destroy(out);
    destroy(vault);
    destroy(cap);
}

#[test]
fun deposit_then_refunding_then_release_partial() {
    let mut ctx = tx_context::dummy();
    let (mut vault, cap) = refund_vault::new<USDC>(&mut ctx);

    vault.deposit(&cap, u::pay_balance(1_000));
    vault.flip_to_refunding(&cap);
    assert!(vault.is_refunding());

    let part = vault.release_balance(&cap, 400);
    assert_eq!(part.value(), 400);
    assert_eq!(vault.value(), 600); // remaining covers outstanding

    // Events: one deposit, one Active->Refunding transition, one partial release.
    let vid = object::id(&vault);
    let deposits = event::events_by_type<refund_vault::VaultDeposit<USDC>>();
    assert_eq!(deposits.length(), 1);
    assert_eq!(deposits[0], refund_vault::test_new_vault_deposit<USDC>(vid, 1_000, 1_000));
    let changes = event::events_by_type<refund_vault::VaultStateChanged<USDC>>();
    assert_eq!(changes.length(), 1);
    assert_eq!(
        changes[0],
        refund_vault::test_new_vault_state_changed<USDC>(
            vid,
            refund_vault::test_state_active(),
            refund_vault::test_state_refunding(),
        ),
    );
    let releases = event::events_by_type<refund_vault::VaultRelease<USDC>>();
    assert_eq!(releases.length(), 1);
    assert_eq!(releases[0], refund_vault::test_new_vault_release<USDC>(vid, 400, 600));

    destroy(part);
    destroy(vault);
    destroy(cap);
}

// A zero-value deposit is a no-op: the balance is consumed, but the locked
// amount and state are unchanged (and no VaultDeposit event is emitted). The
// vault stays fully usable afterwards.
#[test]
fun deposit_zero_is_noop() {
    let mut ctx = tx_context::dummy();
    let (mut vault, cap) = refund_vault::new<USDC>(&mut ctx);

    vault.deposit(&cap, u::pay_balance(0));
    assert_eq!(vault.value(), 0);
    assert!(vault.is_active());
    // The zero-value deposit emitted no VaultDeposit event.
    assert_eq!(event::events_by_type<refund_vault::VaultDeposit<USDC>>().length(), 0);

    // Still accepts real deposits after the no-op.
    vault.deposit(&cap, u::pay_balance(500));
    assert_eq!(vault.value(), 500);
    // Only the non-zero deposit produced an event.
    assert_eq!(event::events_by_type<refund_vault::VaultDeposit<USDC>>().length(), 1);

    destroy(vault);
    destroy(cap);
}

// withdraw_all on an empty (closed) vault is idempotent: it returns an empty
// balance and emits no VaultRelease event.
#[test]
fun withdraw_all_empty_emits_no_event() {
    let mut ctx = tx_context::dummy();
    let (mut vault, cap) = refund_vault::new<USDC>(&mut ctx);

    vault.flip_to_closed(&cap);
    let out = vault.withdraw_all(&cap);
    assert_eq!(out.value(), 0);
    assert_eq!(event::events_by_type<refund_vault::VaultRelease<USDC>>().length(), 0);

    destroy(out);
    destroy(vault);
    destroy(cap);
}

// === Cap-gating ===

#[test, expected_failure(abort_code = refund_vault::EWrongVaultCap)]
fun deposit_with_wrong_cap_aborts() {
    let mut ctx = tx_context::dummy();
    let (mut vault, _cap) = refund_vault::new<USDC>(&mut ctx);
    let (_other_vault, other_cap) = refund_vault::new<USDC>(&mut ctx);

    vault.deposit(&other_cap, u::pay_balance(1)); // aborts: cap is for other_vault
    abort
}

// === State guards ===

// deposit requires Active.
#[test, expected_failure(abort_code = refund_vault::ENotActiveState)]
fun deposit_after_refunding_aborts() {
    let mut ctx = tx_context::dummy();
    let (mut vault, cap) = refund_vault::new<USDC>(&mut ctx);
    vault.flip_to_refunding(&cap);
    vault.deposit(&cap, u::pay_balance(1)); // aborts
    abort
}

// release requires Refunding.
#[test, expected_failure(abort_code = refund_vault::ENotRefundingState)]
fun release_in_active_aborts() {
    let mut ctx = tx_context::dummy();
    let (mut vault, cap) = refund_vault::new<USDC>(&mut ctx);
    vault.deposit(&cap, u::pay_balance(100));
    let _part = vault.release_balance(&cap, 1); // aborts: not Refunding
    abort
}

// release cannot exceed the locked balance.
#[test, expected_failure(abort_code = refund_vault::EInsufficientLocked)]
fun release_over_locked_aborts() {
    let mut ctx = tx_context::dummy();
    let (mut vault, cap) = refund_vault::new<USDC>(&mut ctx);
    vault.deposit(&cap, u::pay_balance(100));
    vault.flip_to_refunding(&cap);
    let _part = vault.release_balance(&cap, 101); // aborts
    abort
}

// withdraw_all requires Closed.
#[test, expected_failure(abort_code = refund_vault::ENotClosedState)]
fun withdraw_all_in_active_aborts() {
    let mut ctx = tx_context::dummy();
    let (mut vault, cap) = refund_vault::new<USDC>(&mut ctx);
    let _part = vault.withdraw_all(&cap); // aborts: not Closed
    abort
}

// Transitions are one-way: Refunding cannot flip to Closed.
#[test, expected_failure(abort_code = refund_vault::ENotActiveState)]
fun flip_to_closed_from_refunding_aborts() {
    let mut ctx = tx_context::dummy();
    let (mut vault, cap) = refund_vault::new<USDC>(&mut ctx);
    vault.flip_to_refunding(&cap);
    vault.flip_to_closed(&cap); // aborts: source must be Active
    abort
}
