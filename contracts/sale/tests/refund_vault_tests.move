// RefundVault state-machine + cap-gating tests.
//
// The vault is a standalone escrow primitive: Active accepts deposits; the
// terminal states do not. Refunding supports per-amount releases; Closed
// supports a single full withdrawal. All mutations are cap-gated.
module openzeppelin_sale::refund_vault_tests;

use openzeppelin_sale::refund_vault;
use openzeppelin_sale::test_utils::{Self as tu, USDC};
use std::unit_test::{assert_eq, destroy};

// === Happy paths ===

#[test]
fun new_starts_active_and_empty() {
    let mut ctx = tx_context::dummy();
    let (vault, cap) = refund_vault::new<USDC>(&mut ctx);
    assert_eq!(vault.is_active(), true);
    assert_eq!(vault.value(), 0);
    assert_eq!(cap.cap_vault_id(), object::id(&vault));
    destroy(vault);
    destroy(cap);
}

#[test]
fun deposit_then_close_then_withdraw_all() {
    let mut ctx = tx_context::dummy();
    let (mut vault, cap) = refund_vault::new<USDC>(&mut ctx);

    vault.deposit(&cap, tu::pay_balance(300));
    vault.deposit(&cap, tu::pay_balance(700));
    assert_eq!(vault.value(), 1_000);

    vault.flip_to_closed(&cap);
    assert_eq!(vault.is_closed(), true);
    let out = vault.withdraw_all(&cap);
    assert_eq!(out.value(), 1_000);
    assert_eq!(vault.value(), 0);

    destroy(out);
    destroy(vault);
    destroy(cap);
}

#[test]
fun deposit_then_refunding_then_release_partial() {
    let mut ctx = tx_context::dummy();
    let (mut vault, cap) = refund_vault::new<USDC>(&mut ctx);

    vault.deposit(&cap, tu::pay_balance(1_000));
    vault.flip_to_refunding(&cap);
    assert_eq!(vault.is_refunding(), true);

    let part = vault.release_balance(&cap, 400);
    assert_eq!(part.value(), 400);
    assert_eq!(vault.value(), 600); // remaining covers outstanding

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

    vault.deposit(&cap, tu::pay_balance(0));
    assert_eq!(vault.value(), 0);
    assert_eq!(vault.is_active(), true);

    // Still accepts real deposits after the no-op.
    vault.deposit(&cap, tu::pay_balance(500));
    assert_eq!(vault.value(), 500);

    destroy(vault);
    destroy(cap);
}

// === Cap-gating ===

#[test, expected_failure(abort_code = refund_vault::EWrongVaultCap)]
fun deposit_with_wrong_cap_aborts() {
    let mut ctx = tx_context::dummy();
    let (mut vault, cap) = refund_vault::new<USDC>(&mut ctx);
    let (other_vault, other_cap) = refund_vault::new<USDC>(&mut ctx);

    vault.deposit(&other_cap, tu::pay_balance(1)); // aborts: cap is for other_vault

    destroy(vault);
    destroy(cap);
    destroy(other_vault);
    destroy(other_cap);
}

// === State guards ===

// deposit requires Active.
#[test, expected_failure(abort_code = refund_vault::ENotActiveState)]
fun deposit_after_refunding_aborts() {
    let mut ctx = tx_context::dummy();
    let (mut vault, cap) = refund_vault::new<USDC>(&mut ctx);
    vault.flip_to_refunding(&cap);
    vault.deposit(&cap, tu::pay_balance(1)); // aborts
    destroy(vault);
    destroy(cap);
}

// release requires Refunding.
#[test, expected_failure(abort_code = refund_vault::ENotRefundingState)]
fun release_in_active_aborts() {
    let mut ctx = tx_context::dummy();
    let (mut vault, cap) = refund_vault::new<USDC>(&mut ctx);
    vault.deposit(&cap, tu::pay_balance(100));
    let part = vault.release_balance(&cap, 1); // aborts: not Refunding
    destroy(part);
    destroy(vault);
    destroy(cap);
}

// release cannot exceed the locked balance.
#[test, expected_failure(abort_code = refund_vault::EInsufficientLocked)]
fun release_over_locked_aborts() {
    let mut ctx = tx_context::dummy();
    let (mut vault, cap) = refund_vault::new<USDC>(&mut ctx);
    vault.deposit(&cap, tu::pay_balance(100));
    vault.flip_to_refunding(&cap);
    let part = vault.release_balance(&cap, 101); // aborts
    destroy(part);
    destroy(vault);
    destroy(cap);
}

// withdraw_all requires Closed.
#[test, expected_failure(abort_code = refund_vault::ENotClosedState)]
fun withdraw_all_in_active_aborts() {
    let mut ctx = tx_context::dummy();
    let (mut vault, cap) = refund_vault::new<USDC>(&mut ctx);
    let part = vault.withdraw_all(&cap); // aborts: not Closed
    destroy(part);
    destroy(vault);
    destroy(cap);
}

// Transitions are one-way: Refunding cannot flip to Closed.
#[test, expected_failure(abort_code = refund_vault::ENotActiveState)]
fun flip_to_closed_from_refunding_aborts() {
    let mut ctx = tx_context::dummy();
    let (mut vault, cap) = refund_vault::new<USDC>(&mut ctx);
    vault.flip_to_refunding(&cap);
    vault.flip_to_closed(&cap); // aborts: source must be Active
    destroy(vault);
    destroy(cap);
}
