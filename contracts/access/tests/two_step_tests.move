module openzeppelin_access::two_step_tests;

use openzeppelin_access::two_step_transfer;
use std::unit_test::assert_eq;
use sui::event;

#[test_only]
public struct DummyCap has key, store {
    id: sui::object::UID,
}

#[test_only]
public fun dummy_ctx_with_sender(sender: address): TxContext {
    let tx_hash = x"3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532";
    tx_context::new(sender, tx_hash, 0, 0, 0)
}

#[test_only]
fun new_cap(ctx: &mut TxContext): DummyCap {
    DummyCap { id: sui::object::new(ctx) }
}

#[test]
fun request_emits_event() {
    let owner = @0x1;
    let mut ctx = dummy_ctx_with_sender(owner);
    let wrapper = two_step_transfer::wrap(new_cap(&mut ctx), &mut ctx);

    two_step_transfer::request<DummyCap>(sui::object::id(&wrapper), owner, &mut ctx);

    let events = event::events_by_type<two_step_transfer::OwnershipRequested>();
    assert_eq!(events.length(), 1);

    let DummyCap { id } = two_step_transfer::unwrap(wrapper);
    id.delete();
}

#[test]
fun unwrap_returns_inner_cap() {
    let owner = @0x2;
    let mut ctx = dummy_ctx_with_sender(owner);
    let wrapper = two_step_transfer::wrap(new_cap(&mut ctx), &mut ctx);

    let cap = two_step_transfer::unwrap(wrapper);
    let DummyCap { id } = cap;
    id.delete();
}

#[test]
fun borrow_and_return_roundtrip() {
    // Owner wraps a cap, borrows it temporarily, and returns it before unwrapping again.
    let owner = @0xA;
    let mut ctx = dummy_ctx_with_sender(owner);
    let mut wrapper = two_step_transfer::wrap(new_cap(&mut ctx), &mut ctx);

    let readonly = two_step_transfer::borrow(&wrapper);
    std::unit_test::assert_eq!(
        sui::object::id(readonly),
        sui::object::id(two_step_transfer::borrow_mut(&mut wrapper)),
    );

    let (cap, borrow_token) = two_step_transfer::borrow_val(&mut wrapper);
    two_step_transfer::return_val(&mut wrapper, cap, borrow_token);

    let DummyCap { id } = two_step_transfer::unwrap(wrapper);
    id.delete();
}

#[test, expected_failure(abort_code = two_step_transfer::EWrongTwoStepTransferWrapper)]
fun return_val_rejects_wrong_wrapper() {
    // Borrow from one wrapper but attempt to return into another—should abort.
    let owner = @0xB;
    let mut ctx = dummy_ctx_with_sender(owner);
    let first = two_step_transfer::wrap(new_cap(&mut ctx), &mut ctx);
    let second = two_step_transfer::wrap(new_cap(&mut ctx), &mut ctx);

    expect_wrapper_mismatch(first, second);
}

#[test, expected_failure(abort_code = two_step_transfer::EWrongTwoStepTransferObject)]
fun return_val_rejects_wrong_capability() {
    // Returning a different capability than the one borrowed must fail.
    let owner = @0xC;
    let mut ctx = dummy_ctx_with_sender(owner);
    let wrapper = two_step_transfer::wrap(new_cap(&mut ctx), &mut ctx);

    expect_capability_mismatch(wrapper, &mut ctx);
}

#[test]
fun transfer_emits_event() {
    // Owner approves a valid transfer request and emits OwnershipTransferred.
    let owner = @0xD;
    let new_owner = @0xE;
    let mut ctx = dummy_ctx_with_sender(owner);
    let wrapper = two_step_transfer::wrap(new_cap(&mut ctx), &mut ctx);

    let request = two_step_transfer::test_new_request<DummyCap>(
        sui::object::id(&wrapper),
        new_owner,
        &mut ctx,
    );
    two_step_transfer::transfer(wrapper, request, &mut ctx);

    let events = event::events_by_type<two_step_transfer::OwnershipTransferred>();
    assert_eq!(events.length(), 1);
}

#[test, expected_failure(abort_code = two_step_transfer::EInvalidTransferRequest)]
fun transfer_rejects_mismatched_request() {
    // Passing a request that references a different wrapper must abort.
    let owner = @0xF;
    let mut ctx = dummy_ctx_with_sender(owner);
    let wrapper = two_step_transfer::wrap(new_cap(&mut ctx), &mut ctx);
    let other_wrapper = two_step_transfer::wrap(new_cap(&mut ctx), &mut ctx);

    expect_mismatched_request(wrapper, other_wrapper, owner, &mut ctx);
}

#[test]
fun reject_destroys_request() {
    // Owner can discard a pending request without emitting transfer events.
    let owner = @0x10;
    let mut ctx = dummy_ctx_with_sender(owner);
    let wrapper = two_step_transfer::wrap(new_cap(&mut ctx), &mut ctx);

    let request = two_step_transfer::test_new_request<DummyCap>(
        sui::object::id(&wrapper),
        owner,
        &mut ctx,
    );
    two_step_transfer::reject(request);

    let events = event::events_by_type<two_step_transfer::OwnershipTransferred>();
    assert_eq!(events.length(), 0);

    let DummyCap { id } = two_step_transfer::unwrap(wrapper);
    id.delete();
}

fun expect_wrapper_mismatch(
    mut first: two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    mut second: two_step_transfer::TwoStepTransferWrapper<DummyCap>,
) {
    let (cap, borrow_token) = two_step_transfer::borrow_val(&mut first);
    two_step_transfer::return_val(&mut second, cap, borrow_token);

    let DummyCap { id } = two_step_transfer::unwrap(first);
    id.delete();
    let DummyCap { id } = two_step_transfer::unwrap(second);
    id.delete();
}

fun expect_capability_mismatch(
    mut wrapper: two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    ctx: &mut TxContext,
) {
    let (borrowed_cap, borrow_token) = two_step_transfer::borrow_val(&mut wrapper);
    let DummyCap { id } = borrowed_cap;
    id.delete();
    let bogus_cap = new_cap(ctx);
    two_step_transfer::return_val(&mut wrapper, bogus_cap, borrow_token);

    let DummyCap { id } = two_step_transfer::unwrap(wrapper);
    id.delete();
}

fun expect_mismatched_request(
    wrapper: two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    other_wrapper: two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    owner: address,
    ctx: &mut TxContext,
) {
    let bad_request = two_step_transfer::test_new_request<DummyCap>(
        sui::object::id(&other_wrapper),
        owner,
        ctx,
    );
    two_step_transfer::transfer(wrapper, bad_request, ctx);

    let DummyCap { id } = two_step_transfer::unwrap(other_wrapper);
    id.delete();
}
