#[test_only]
module openzeppelin_access::delayed_tests;

use openzeppelin_access::delayed_transfer;
use std::unit_test::assert_eq;
use sui::clock;
use sui::event;
use sui::test_scenario;

#[test_only]
public struct DummyCap has key, store {
    id: object::UID,
}

#[test_only]
fun new_cap(ctx: &mut TxContext): DummyCap {
    DummyCap { id: object::new(ctx) }
}

#[test]
fun wrap_emits_events() {
    let owner = @0x1;
    let min_delay_ms = 5;
    let mut test = test_scenario::begin(owner);
    let obj = new_cap(test.ctx());
    let obj_id = object::id(&obj);

    delayed_transfer::wrap(obj, min_delay_ms, owner, test.ctx());

    let events = event::events_by_type<delayed_transfer::WrapExecuted<DummyCap>>();
    assert_eq!(events.length(), 1);

    test.next_tx(owner);
    let mut wrapper = test.take_from_sender<delayed_transfer::DelayedTransferWrapper<DummyCap>>();
    let wrapper_id = object::id(&wrapper);
    let expected_event = delayed_transfer::test_new_wrap_executed(wrapper_id, obj_id, owner);
    assert_eq!(expected_event, events[0]);

    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);
    wrapper.schedule_unwrap(&clk, test.ctx());
    clk.set_for_testing(min_delay_ms);
    let obj = wrapper.unwrap(&clk, test.ctx());
    let DummyCap { id } = obj;
    id.delete();
    clock::destroy_for_testing(clk);
    test.end();
}

#[test]
fun schedule_and_execute_transfer() {
    let owner = @0x1;
    let recipient = @0x2;
    let mut test = test_scenario::begin(owner);
    delayed_transfer::wrap(new_cap(test.ctx()), 5, owner, test.ctx());

    test.next_tx(owner);
    let mut wrapper = test.take_from_sender<delayed_transfer::DelayedTransferWrapper<DummyCap>>();
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(1);

    wrapper.schedule_transfer(recipient, &clk, test.ctx());
    let scheduled = event::events_by_type<delayed_transfer::TransferScheduled<DummyCap>>();
    assert_eq!(scheduled.length(), 1);

    clk.set_for_testing(10);
    wrapper.execute_transfer(&clk, test.ctx());

    let executed = event::events_by_type<delayed_transfer::OwnershipTransferred<DummyCap>>();
    assert_eq!(executed.length(), 1);
    clock::destroy_for_testing(clk);

    test.next_tx(recipient);
    let mut wrapper = test.take_from_sender<delayed_transfer::DelayedTransferWrapper<DummyCap>>();
    let mut cleanup_clk = clock::create_for_testing(test.ctx());
    cleanup_clk.set_for_testing(10);
    wrapper.schedule_unwrap(&cleanup_clk, test.ctx());
    cleanup_clk.set_for_testing(15);
    let obj = wrapper.unwrap(&cleanup_clk, test.ctx());
    let DummyCap { id } = obj;
    id.delete();
    clock::destroy_for_testing(cleanup_clk);
    test.end();
}

#[test]
fun schedule_and_unwrap_after_delay() {
    let owner = @0x3;
    let mut test = test_scenario::begin(owner);
    delayed_transfer::wrap(new_cap(test.ctx()), 7, owner, test.ctx());

    test.next_tx(owner);
    let mut wrapper = test.take_from_sender<delayed_transfer::DelayedTransferWrapper<DummyCap>>();
    let wrapper_id = object::id(&wrapper);

    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    wrapper.schedule_unwrap(&clk, test.ctx());
    let scheduled = event::events_by_type<delayed_transfer::UnwrapScheduled<DummyCap>>();
    assert_eq!(scheduled.length(), 1);

    clk.set_for_testing(10);
    let obj = wrapper.unwrap(&clk, test.ctx());

    let executed = event::events_by_type<delayed_transfer::UnwrapExecuted<DummyCap>>();
    assert_eq!(executed.length(), 1);

    let expected_event = delayed_transfer::test_new_unwrap_executed(
        wrapper_id,
        object::id(&obj),
        owner,
    );
    assert_eq!(expected_event, executed[0]);

    let DummyCap { id } = obj;
    id.delete();

    clock::destroy_for_testing(clk);
    test.end();
}

#[test, expected_failure(abort_code = delayed_transfer::ETransferAlreadyScheduled)]
fun schedule_transfer_rejects_duplicate() {
    // Scheduling twice without cancelling should abort with ETransferAlreadyScheduled.
    let owner = @0x4;
    let mut test = test_scenario::begin(owner);
    delayed_transfer::wrap(new_cap(test.ctx()), 5, owner, test.ctx());

    test.next_tx(owner);
    let wrapper = test.take_from_sender<delayed_transfer::DelayedTransferWrapper<DummyCap>>();
    let clk = clock::create_for_testing(test.ctx());
    attempt_double_schedule(wrapper, owner, clk, test.ctx());
    test.end();
}

#[test, expected_failure(abort_code = delayed_transfer::ETransferAlreadyScheduled)]
fun schedule_unwrap_rejects_duplicate() {
    // Scheduling unwrap twice without cancelling must also abort with ETransferAlreadyScheduled.
    let owner = @0x4;
    let mut test = test_scenario::begin(owner);
    delayed_transfer::wrap(new_cap(test.ctx()), 5, owner, test.ctx());

    test.next_tx(owner);
    let wrapper = test.take_from_sender<delayed_transfer::DelayedTransferWrapper<DummyCap>>();
    let clk = clock::create_for_testing(test.ctx());
    attempt_double_unwrap(wrapper, clk, test.ctx());
    test.end();
}

#[test, expected_failure(abort_code = delayed_transfer::EDelayNotElapsed)]
fun execute_transfer_before_delay_fails() {
    // Attempting to execute before the deadline should abort.
    let owner = @0x5;
    let recipient = @0x6;
    let mut test = test_scenario::begin(owner);
    delayed_transfer::wrap(new_cap(test.ctx()), 10, owner, test.ctx());

    test.next_tx(owner);
    let wrapper = test.take_from_sender<delayed_transfer::DelayedTransferWrapper<DummyCap>>();
    let clk = clock::create_for_testing(test.ctx());
    attempt_execute_before_delay(wrapper, recipient, clk, test.ctx());
    test.end();
}

#[test, expected_failure(abort_code = delayed_transfer::EDelayNotElapsed)]
fun unwrap_before_delay_fails() {
    // Unwrap path must also respect the configured delay.
    let owner = @0x7;
    let mut test = test_scenario::begin(owner);
    delayed_transfer::wrap(new_cap(test.ctx()), 10, owner, test.ctx());

    test.next_tx(owner);
    let wrapper = test.take_from_sender<delayed_transfer::DelayedTransferWrapper<DummyCap>>();
    let clk = clock::create_for_testing(test.ctx());
    attempt_early_unwrap(wrapper, clk, test.ctx());
    test.end();
}

#[test]
fun cancel_schedule_allows_reschedule() {
    // After cancelling a pending transfer we should be able to schedule a different action.
    let owner = @0x8;
    let mut test = test_scenario::begin(owner);
    delayed_transfer::wrap(new_cap(test.ctx()), 5, owner, test.ctx());

    test.next_tx(owner);
    let mut wrapper = test.take_from_sender<delayed_transfer::DelayedTransferWrapper<DummyCap>>();
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    wrapper.schedule_transfer(owner, &clk, test.ctx());

    wrapper.cancel_schedule();

    let events = event::events_by_type<delayed_transfer::PendingTransferCancelled<DummyCap>>();
    assert_eq!(events.length(), 1);

    let expected_event = delayed_transfer::test_new_pending_transfer_cancelled(
        object::id(&wrapper),
    );
    assert_eq!(expected_event, events[0]);

    wrapper.schedule_unwrap(&clk, test.ctx());

    let events = event::events_by_type<delayed_transfer::UnwrapScheduled<DummyCap>>();
    assert_eq!(events.length(), 1);

    clk.set_for_testing(5);
    let obj = wrapper.unwrap(&clk, test.ctx());
    let DummyCap { id } = obj;
    id.delete();
    clock::destroy_for_testing(clk);
    test.end();
}

#[test]
fun borrow_and_return_roundtrip() {
    // Borrow, mutate, and return the wrapped object through all borrow APIs.
    let owner = @0x11;
    let mut test = test_scenario::begin(owner);
    delayed_transfer::wrap(new_cap(test.ctx()), 5, owner, test.ctx());

    test.next_tx(owner);
    let mut wrapper = test.take_from_sender<delayed_transfer::DelayedTransferWrapper<DummyCap>>();
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);

    let first_id = object::id(delayed_transfer::borrow(&wrapper));
    assert_eq!(first_id, object::id(delayed_transfer::borrow_mut(&mut wrapper)));

    let (obj, borrow_token) = wrapper.borrow_val();
    wrapper.return_val(obj, borrow_token);

    wrapper.schedule_unwrap(&clk, test.ctx());
    clk.set_for_testing(10);
    let obj = wrapper.unwrap(&clk, test.ctx());
    let DummyCap { id } = obj;
    id.delete();
    clock::destroy_for_testing(clk);
    test.end();
}

#[test, expected_failure(abort_code = delayed_transfer::ENoPendingTransfer)]
fun cancel_schedule_without_pending_fails() {
    let owner = @0x12;
    let mut test = test_scenario::begin(owner);
    delayed_transfer::wrap(new_cap(test.ctx()), 5, owner, test.ctx());

    test.next_tx(owner);
    let wrapper = test.take_from_sender<delayed_transfer::DelayedTransferWrapper<DummyCap>>();
    expect_cancel_without_pending(wrapper, test.ctx());
    test.end();
}

#[test, expected_failure(abort_code = delayed_transfer::ENoPendingTransfer)]
fun execute_transfer_without_pending_fails() {
    let owner = @0x13;
    let mut test = test_scenario::begin(owner);
    delayed_transfer::wrap(new_cap(test.ctx()), 5, owner, test.ctx());

    test.next_tx(owner);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);
    let wrapper = test.take_from_sender<delayed_transfer::DelayedTransferWrapper<DummyCap>>();
    expect_execute_without_pending(wrapper, clk, test.ctx());
    test.end();
}

#[test, expected_failure(abort_code = delayed_transfer::ENoPendingTransfer)]
fun unwrap_without_pending_fails() {
    let owner = @0x14;
    let mut test = test_scenario::begin(owner);
    delayed_transfer::wrap(new_cap(test.ctx()), 5, owner, test.ctx());

    test.next_tx(owner);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);
    let wrapper = test.take_from_sender<delayed_transfer::DelayedTransferWrapper<DummyCap>>();
    expect_unwrap_without_pending(wrapper, clk, test.ctx());
    test.end();
}

#[test, expected_failure(abort_code = delayed_transfer::EWrongPendingAction)]
fun execute_transfer_wrong_action_fails() {
    let owner = @0x15;
    let mut test = test_scenario::begin(owner);
    delayed_transfer::wrap(new_cap(test.ctx()), 5, owner, test.ctx());

    test.next_tx(owner);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);
    let mut wrapper = test.take_from_sender<delayed_transfer::DelayedTransferWrapper<DummyCap>>();
    wrapper.schedule_unwrap(&clk, test.ctx());
    clk.set_for_testing(10);
    wrapper.execute_transfer(&clk, test.ctx());
    clock::destroy_for_testing(clk);
    test.end();
}

#[test, expected_failure(abort_code = delayed_transfer::EWrongPendingAction)]
fun unwrap_wrong_action_fails() {
    let owner = @0x16;
    let recipient = @0x17;
    let mut test = test_scenario::begin(owner);
    delayed_transfer::wrap(new_cap(test.ctx()), 5, owner, test.ctx());

    test.next_tx(owner);
    let mut clk = clock::create_for_testing(test.ctx());
    clk.set_for_testing(0);
    let mut wrapper = test.take_from_sender<delayed_transfer::DelayedTransferWrapper<DummyCap>>();
    wrapper.schedule_transfer(recipient, &clk, test.ctx());
    clk.set_for_testing(10);
    let obj = wrapper.unwrap(&clk, test.ctx());
    let DummyCap { id } = obj;
    id.delete();
    clock::destroy_for_testing(clk);
    test.end();
}

#[test, expected_failure(abort_code = delayed_transfer::EWrongDelayedTransferWrapper)]
fun return_val_rejects_wrong_wrapper() {
    let owner = @0x18;
    let mut test = test_scenario::begin(owner);
    delayed_transfer::wrap(new_cap(test.ctx()), 5, owner, test.ctx());
    delayed_transfer::wrap(new_cap(test.ctx()), 5, owner, test.ctx());

    test.next_tx(owner);
    let first = test.take_from_sender<delayed_transfer::DelayedTransferWrapper<DummyCap>>();
    let second = test.take_from_sender<delayed_transfer::DelayedTransferWrapper<DummyCap>>();
    expect_return_wrong_wrapper(first, second, test.ctx());
    test.end();
}

#[test, expected_failure(abort_code = delayed_transfer::EWrongDelayedTransferObject)]
fun return_val_rejects_wrong_object() {
    let owner = @0x19;
    let mut test = test_scenario::begin(owner);
    delayed_transfer::wrap(new_cap(test.ctx()), 5, owner, test.ctx());

    test.next_tx(owner);
    let wrapper = test.take_from_sender<delayed_transfer::DelayedTransferWrapper<DummyCap>>();
    expect_return_wrong_object(wrapper, test.ctx());
    test.end();
}

fun attempt_double_schedule(
    mut wrapper: delayed_transfer::DelayedTransferWrapper<DummyCap>,
    owner: address,
    mut clk: clock::Clock,
    ctx: &mut TxContext,
) {
    clk.set_for_testing(0);
    wrapper.schedule_transfer(owner, &clk, ctx);
    wrapper.schedule_transfer(owner, &clk, ctx);

    // Cleanup path (never reached on failure).
    clk.set_for_testing(10);
    let obj = wrapper.unwrap(&clk, ctx);
    let DummyCap { id } = obj;
    id.delete();
    clock::destroy_for_testing(clk);
}

fun attempt_execute_before_delay(
    mut wrapper: delayed_transfer::DelayedTransferWrapper<DummyCap>,
    recipient: address,
    mut clk: clock::Clock,
    ctx: &mut TxContext,
) {
    clk.set_for_testing(0);
    wrapper.schedule_transfer(recipient, &clk, ctx);
    clk.set_for_testing(5);
    wrapper.execute_transfer(&clk, ctx);

    clock::destroy_for_testing(clk);
}

fun attempt_early_unwrap(
    mut wrapper: delayed_transfer::DelayedTransferWrapper<DummyCap>,
    mut clk: clock::Clock,
    ctx: &mut TxContext,
) {
    clk.set_for_testing(0);
    wrapper.schedule_unwrap(&clk, ctx);
    clk.set_for_testing(5);
    let obj = wrapper.unwrap(&clk, ctx);
    let DummyCap { id } = obj;
    id.delete();

    clock::destroy_for_testing(clk);
}

fun attempt_double_unwrap(
    mut wrapper: delayed_transfer::DelayedTransferWrapper<DummyCap>,
    mut clk: clock::Clock,
    ctx: &mut TxContext,
) {
    clk.set_for_testing(0);
    wrapper.schedule_unwrap(&clk, ctx);
    wrapper.schedule_unwrap(&clk, ctx);

    clk.set_for_testing(10);
    let obj = wrapper.unwrap(&clk, ctx);
    let DummyCap { id } = obj;
    id.delete();
    clock::destroy_for_testing(clk);
}

fun expect_cancel_without_pending(
    mut wrapper: delayed_transfer::DelayedTransferWrapper<DummyCap>,
    ctx: &mut TxContext,
) {
    wrapper.cancel_schedule();

    let mut clk = clock::create_for_testing(ctx);
    clk.set_for_testing(0);
    wrapper.schedule_unwrap(&clk, ctx);
    clk.set_for_testing(1);
    let obj = wrapper.unwrap(&clk, ctx);
    let DummyCap { id } = obj;
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
    let obj = wrapper.unwrap(&clk, ctx);
    let DummyCap { id } = obj;
    id.delete();
    clock::destroy_for_testing(clk);
}

fun expect_return_wrong_wrapper(
    mut first: delayed_transfer::DelayedTransferWrapper<DummyCap>,
    mut second: delayed_transfer::DelayedTransferWrapper<DummyCap>,
    ctx: &mut TxContext,
) {
    let (obj, token) = first.borrow_val();
    second.return_val(obj, token);

    let mut clk = clock::create_for_testing(ctx);
    clk.set_for_testing(1);
    first.schedule_unwrap(&clk, ctx);
    second.schedule_unwrap(&clk, ctx);
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
    wrapper.schedule_unwrap(&clk, ctx);
    let obj = wrapper.unwrap(&clk, ctx);
    let DummyCap { id } = obj;
    id.delete();
    clock::destroy_for_testing(clk);
}
