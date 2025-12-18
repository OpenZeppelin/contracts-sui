#[test_only]
module openzeppelin_access::delayed_tests;

use openzeppelin_access::delayed_transfer;
use std::unit_test::assert_eq;
use sui::clock;
use sui::event;

#[test_only]
public struct DummyCap has key, store {
    id: object::UID,
}

#[test_only]
public fun dummy_ctx_with_sender(sender: address): TxContext {
    let tx_hash = x"3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532";
    tx_context::new(sender, tx_hash, 0, 0, 0)
}

#[test_only]
fun new_cap(ctx: &mut TxContext): DummyCap {
    DummyCap { id: object::new(ctx) }
}

#[test]
fun schedule_and_execute_transfer() {
    let owner = @0x1;
    let recipient = @0x2;
    let mut ctx = dummy_ctx_with_sender(owner);
    let mut wrapper = delayed_transfer::wrap(new_cap(&mut ctx), 5, &mut ctx);

    let mut clk = clock::create_for_testing(&mut ctx);
    clk.set_for_testing(1);

    wrapper.schedule_transfer(recipient, &clk, owner);
    let scheduled = event::events_by_type<delayed_transfer::TransferScheduled>();
    assert_eq!(scheduled.length(), 1);

    clk.set_for_testing(10);
    wrapper.execute_transfer(&clk, &mut ctx);

    let executed = event::events_by_type<delayed_transfer::OwnershipTransferred>();
    assert_eq!(executed.length(), 1);

    clock::destroy_for_testing(clk);
}

#[test]
fun schedule_and_unwrap_after_delay() {
    let owner = @0x3;
    let mut ctx = dummy_ctx_with_sender(owner);
    let mut wrapper = delayed_transfer::wrap(new_cap(&mut ctx), 7, &mut ctx);

    let mut clk = clock::create_for_testing(&mut ctx);
    clk.set_for_testing(0);

    wrapper.schedule_unwrap(&clk, owner);
    let scheduled = event::events_by_type<delayed_transfer::UnwrapScheduled>();
    assert_eq!(scheduled.length(), 1);

    clk.set_for_testing(10);
    let cap = wrapper.unwrap(&clk, &mut ctx);

    let DummyCap { id } = cap;
    id.delete();

    clock::destroy_for_testing(clk);
}

#[test, expected_failure(abort_code = delayed_transfer::ETransferAlreadyScheduled)]
fun schedule_transfer_rejects_duplicate() {
    // Scheduling twice without cancelling should abort with ETransferAlreadyScheduled.
    let owner = @0x4;
    let mut ctx = dummy_ctx_with_sender(owner);
    let wrapper = delayed_transfer::wrap(new_cap(&mut ctx), 5, &mut ctx);
    let clk = clock::create_for_testing(&mut ctx);
    attempt_double_schedule(wrapper, clk, owner, &mut ctx);
}

#[test, expected_failure(abort_code = delayed_transfer::ETransferAlreadyScheduled)]
fun schedule_unwrap_rejects_duplicate() {
    // Scheduling unwrap twice without cancelling must also abort with ETransferAlreadyScheduled.
    let owner = @0x4;
    let mut ctx = dummy_ctx_with_sender(owner);
    let wrapper = delayed_transfer::wrap(new_cap(&mut ctx), 5, &mut ctx);
    let clk = clock::create_for_testing(&mut ctx);
    attempt_double_unwrap(wrapper, clk, owner, &mut ctx);
}

#[test, expected_failure(abort_code = delayed_transfer::EDelayNotElapsed)]
fun execute_transfer_before_delay_fails() {
    // Attempting to execute before the deadline should abort.
    let owner = @0x5;
    let recipient = @0x6;
    let mut ctx = dummy_ctx_with_sender(owner);
    let wrapper = delayed_transfer::wrap(new_cap(&mut ctx), 10, &mut ctx);
    let clk = clock::create_for_testing(&mut ctx);
    attempt_execute_before_delay(wrapper, clk, owner, recipient, &mut ctx);
}

#[test, expected_failure(abort_code = delayed_transfer::EDelayNotElapsed)]
fun unwrap_before_delay_fails() {
    // Unwrap path must also respect the configured delay.
    let owner = @0x7;
    let mut ctx = dummy_ctx_with_sender(owner);
    let wrapper = delayed_transfer::wrap(new_cap(&mut ctx), 10, &mut ctx);
    let clk = clock::create_for_testing(&mut ctx);
    attempt_early_unwrap(wrapper, clk, owner, &mut ctx);
}

#[test]
fun cancel_allows_reschedule() {
    // After cancelling a pending transfer we should be able to schedule a different action.
    let owner = @0x8;
    let mut ctx = dummy_ctx_with_sender(owner);
    let mut wrapper = delayed_transfer::wrap(new_cap(&mut ctx), 5, &mut ctx);
    let mut clk = clock::create_for_testing(&mut ctx);
    clk.set_for_testing(0);

    wrapper.schedule_transfer(owner, &clk, owner);
    wrapper.cancel_schedule();
    wrapper.schedule_unwrap(&clk, owner);

    let events = event::events_by_type<delayed_transfer::UnwrapScheduled>();
    assert_eq!(events.length(), 1);

    clk.set_for_testing(5);
    let cap = wrapper.unwrap(&clk, &mut ctx);
    let DummyCap { id } = cap;
    id.delete();
    clock::destroy_for_testing(clk);
}

#[test]
fun borrow_helpers_roundtrip() {
    // Borrow, mutate, and return the capability through all borrow APIs.
    let owner = @0x11;
    let mut ctx = dummy_ctx_with_sender(owner);
    let mut wrapper = delayed_transfer::wrap(new_cap(&mut ctx), 5, &mut ctx);
    let mut clk = clock::create_for_testing(&mut ctx);
    clk.set_for_testing(0);

    let first_id = object::id(delayed_transfer::borrow(&wrapper));
    assert_eq!(first_id, object::id(delayed_transfer::borrow_mut(&mut wrapper)));

    let (cap, borrow_token) = wrapper.borrow_val();
    wrapper.return_val(cap, borrow_token);

    wrapper.schedule_unwrap(&clk, owner);
    clk.set_for_testing(10);
    let cap = wrapper.unwrap(&clk, &mut ctx);
    let DummyCap { id } = cap;
    id.delete();
    clock::destroy_for_testing(clk);
}

#[test, expected_failure(abort_code = delayed_transfer::ENoPendingTransfer)]
fun cancel_without_pending_fails() {
    let owner = @0x12;
    let mut ctx = dummy_ctx_with_sender(owner);
    let wrapper = delayed_transfer::wrap(new_cap(&mut ctx), 5, &mut ctx);
    expect_cancel_without_pending(wrapper, owner, &mut ctx);
}

#[test, expected_failure(abort_code = delayed_transfer::ENoPendingTransfer)]
fun execute_without_pending_fails() {
    let owner = @0x13;
    let mut ctx = dummy_ctx_with_sender(owner);
    let mut clk = clock::create_for_testing(&mut ctx);
    clk.set_for_testing(0);
    let wrapper = delayed_transfer::wrap(new_cap(&mut ctx), 5, &mut ctx);
    expect_execute_without_pending(wrapper, clk, &mut ctx);
}

#[test, expected_failure(abort_code = delayed_transfer::ENoPendingTransfer)]
fun unwrap_without_pending_fails() {
    let owner = @0x14;
    let mut ctx = dummy_ctx_with_sender(owner);
    let mut clk = clock::create_for_testing(&mut ctx);
    clk.set_for_testing(0);
    let wrapper = delayed_transfer::wrap(new_cap(&mut ctx), 5, &mut ctx);
    expect_unwrap_without_pending(wrapper, clk, &mut ctx);
}

#[test, expected_failure(abort_code = delayed_transfer::EWrongPendingAction)]
fun execute_transfer_wrong_action_fails() {
    let owner = @0x15;
    let mut ctx = dummy_ctx_with_sender(owner);
    let mut clk = clock::create_for_testing(&mut ctx);
    clk.set_for_testing(0);
    let mut wrapper = delayed_transfer::wrap(new_cap(&mut ctx), 5, &mut ctx);
    wrapper.schedule_unwrap(&clk, owner);
    clk.set_for_testing(10);
    wrapper.execute_transfer(&clk, &mut ctx);
    clock::destroy_for_testing(clk);
}

#[test, expected_failure(abort_code = delayed_transfer::EWrongPendingAction)]
fun unwrap_wrong_action_fails() {
    let owner = @0x16;
    let recipient = @0x17;
    let mut ctx = dummy_ctx_with_sender(owner);
    let mut clk = clock::create_for_testing(&mut ctx);
    clk.set_for_testing(0);
    let mut wrapper = delayed_transfer::wrap(new_cap(&mut ctx), 5, &mut ctx);
    wrapper.schedule_transfer(recipient, &clk, owner);
    clk.set_for_testing(10);
    let cap = wrapper.unwrap(&clk, &mut ctx);
    let DummyCap { id } = cap;
    id.delete();
    clock::destroy_for_testing(clk);
}

#[test, expected_failure(abort_code = delayed_transfer::EWrongDelayedTransferWrapper)]
fun return_val_rejects_wrong_wrapper() {
    let owner = @0x18;
    let mut ctx = dummy_ctx_with_sender(owner);
    let first = delayed_transfer::wrap(new_cap(&mut ctx), 5, &mut ctx);
    let second = delayed_transfer::wrap(new_cap(&mut ctx), 5, &mut ctx);
    expect_return_wrong_wrapper(first, second, &mut ctx);
}

#[test, expected_failure(abort_code = delayed_transfer::EWrongDelayedTransferObject)]
fun return_val_rejects_wrong_object() {
    let owner = @0x19;
    let mut ctx = dummy_ctx_with_sender(owner);
    let wrapper = delayed_transfer::wrap(new_cap(&mut ctx), 5, &mut ctx);
    expect_return_wrong_object(wrapper, &mut ctx);
}

fun attempt_double_schedule(
    mut wrapper: delayed_transfer::DelayedTransferWrapper<DummyCap>,
    mut clk: clock::Clock,
    owner: address,
    ctx: &mut TxContext,
) {
    clk.set_for_testing(0);
    wrapper.schedule_transfer(owner, &clk, owner);
    wrapper.schedule_transfer(owner, &clk, owner);

    // Cleanup path (never reached on failure).
    clk.set_for_testing(10);
    let cap = wrapper.unwrap(&clk, ctx);
    let DummyCap { id } = cap;
    id.delete();
    clock::destroy_for_testing(clk);
}

fun attempt_execute_before_delay(
    mut wrapper: delayed_transfer::DelayedTransferWrapper<DummyCap>,
    mut clk: clock::Clock,
    owner: address,
    recipient: address,
    ctx: &mut TxContext,
) {
    clk.set_for_testing(0);
    wrapper.schedule_transfer(recipient, &clk, owner);
    clk.set_for_testing(5);
    wrapper.execute_transfer(&clk, ctx);

    clock::destroy_for_testing(clk);
}

fun attempt_early_unwrap(
    mut wrapper: delayed_transfer::DelayedTransferWrapper<DummyCap>,
    mut clk: clock::Clock,
    owner: address,
    ctx: &mut TxContext,
) {
    clk.set_for_testing(0);
    wrapper.schedule_unwrap(&clk, owner);
    clk.set_for_testing(5);
    let cap = wrapper.unwrap(&clk, ctx);
    let DummyCap { id } = cap;
    id.delete();

    clock::destroy_for_testing(clk);
}

fun attempt_double_unwrap(
    mut wrapper: delayed_transfer::DelayedTransferWrapper<DummyCap>,
    mut clk: clock::Clock,
    owner: address,
    ctx: &mut TxContext,
) {
    clk.set_for_testing(0);
    wrapper.schedule_unwrap(&clk, owner);
    wrapper.schedule_unwrap(&clk, owner);

    clk.set_for_testing(10);
    let cap = wrapper.unwrap(&clk, ctx);
    let DummyCap { id } = cap;
    id.delete();
    clock::destroy_for_testing(clk);
}

fun expect_cancel_without_pending(
    mut wrapper: delayed_transfer::DelayedTransferWrapper<DummyCap>,
    owner: address,
    ctx: &mut TxContext,
) {
    wrapper.cancel_schedule();

    let mut clk = clock::create_for_testing(ctx);
    clk.set_for_testing(0);
    wrapper.schedule_unwrap(&clk, owner);
    clk.set_for_testing(1);
    let cap = wrapper.unwrap(&clk, ctx);
    let DummyCap { id } = cap;
    id.delete();
    clock::destroy_for_testing(clk);
}

fun expect_execute_without_pending(
    wrapper: delayed_transfer::DelayedTransferWrapper<DummyCap>,
    mut clk: clock::Clock,
    ctx: &mut TxContext,
) {
    clk.set_for_testing(0);
    wrapper.execute_transfer(&clk, ctx);
    clock::destroy_for_testing(clk);
}

fun expect_unwrap_without_pending(
    wrapper: delayed_transfer::DelayedTransferWrapper<DummyCap>,
    mut clk: clock::Clock,
    ctx: &mut TxContext,
) {
    clk.set_for_testing(0);
    let cap = wrapper.unwrap(&clk, ctx);
    let DummyCap { id } = cap;
    id.delete();
    clock::destroy_for_testing(clk);
}

fun expect_return_wrong_wrapper(
    mut first: delayed_transfer::DelayedTransferWrapper<DummyCap>,
    mut second: delayed_transfer::DelayedTransferWrapper<DummyCap>,
    ctx: &mut TxContext,
) {
    let (cap, token) = first.borrow_val();
    second.return_val(cap, token);

    let mut clk = clock::create_for_testing(ctx);
    clk.set_for_testing(1);
    let cap_first = first.unwrap(&clk, ctx);
    let DummyCap { id } = cap_first;
    id.delete();
    let cap_second = second.unwrap(&clk, ctx);
    let DummyCap { id } = cap_second;
    id.delete();
    clock::destroy_for_testing(clk);
}

fun expect_return_wrong_object(
    mut wrapper: delayed_transfer::DelayedTransferWrapper<DummyCap>,
    ctx: &mut TxContext,
) {
    let (borrowed, token) = wrapper.borrow_val();
    let DummyCap { id } = borrowed;
    id.delete();

    let bogus = new_cap(ctx);
    wrapper.return_val(bogus, token);

    let mut clk = clock::create_for_testing(ctx);
    clk.set_for_testing(1);
    let cap = wrapper.unwrap(&clk, ctx);
    let DummyCap { id } = cap;
    id.delete();
    clock::destroy_for_testing(clk);
}
