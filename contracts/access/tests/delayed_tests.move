module openzeppelin_access::delayed_tests;

use openzeppelin_access::delayed_transfer;
use std::unit_test::assert_eq;
use sui::clock;
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
fun ai_TMP_schedule_and_execute_transfer() {
  let owner = @0x1;
  let recipient = @0x2;
  let mut ctx = dummy_ctx_with_sender(owner);
  let mut wrapper = delayed_transfer::wrap(new_cap(&mut ctx), 5, &mut ctx);

  let mut clk = clock::create_for_testing(&mut ctx);
  clock::set_for_testing(&mut clk, 1);

  delayed_transfer::schedule_transfer(&mut wrapper, recipient, &clk, owner);
  let scheduled = event::events_by_type<delayed_transfer::TransferScheduled>();
  assert_eq!(scheduled.length(), 1);

  clock::set_for_testing(&mut clk, 10);
  delayed_transfer::execute_transfer(wrapper, &clk, &mut ctx);

  let executed = event::events_by_type<delayed_transfer::OwnershipTransferred>();
  assert_eq!(executed.length(), 1);

  clock::destroy_for_testing(clk);
}

#[test]
fun schedule_and_execute_transfer() {
  let owner = @0x1;
  let recipient = @0x2;
  let mut ctx = dummy_ctx_with_sender(owner);
  let mut wrapper = delayed_transfer::wrap(new_cap(&mut ctx), 5, &mut ctx);

  let mut clk = clock::create_for_testing(&mut ctx);
  clock::set_for_testing(&mut clk, 1);

  delayed_transfer::schedule_transfer(&mut wrapper, recipient, &clk, owner);
  let scheduled = event::events_by_type<delayed_transfer::TransferScheduled>();
  assert_eq!(scheduled.length(), 1);

  clock::set_for_testing(&mut clk, 10);
  delayed_transfer::execute_transfer(wrapper, &clk, &mut ctx);

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
  clock::set_for_testing(&mut clk, 0);

  delayed_transfer::schedule_unwrap(&mut wrapper, &clk, owner);
  let scheduled = event::events_by_type<delayed_transfer::UnwrapScheduled>();
  assert_eq!(scheduled.length(), 1);

  clock::set_for_testing(&mut clk, 10);
  let cap = delayed_transfer::unwrap(wrapper, &clk, &mut ctx);

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
  clock::set_for_testing(&mut clk, 0);

  delayed_transfer::schedule_transfer(&mut wrapper, owner, &clk, owner);
  delayed_transfer::cancel_schedule(&mut wrapper);
  delayed_transfer::schedule_unwrap(&mut wrapper, &clk, owner);

  let events = event::events_by_type<delayed_transfer::UnwrapScheduled>();
  assert_eq!(events.length(), 1);

  clock::set_for_testing(&mut clk, 5);
  let cap = delayed_transfer::unwrap(wrapper, &clk, &mut ctx);
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
  clock::set_for_testing(&mut clk, 0);

  let first_id = sui::object::id(delayed_transfer::borrow(&wrapper));
  assert_eq!(first_id, sui::object::id(delayed_transfer::borrow_mut(&mut wrapper)));

  let (cap, borrow_token) = delayed_transfer::borrow_val(&mut wrapper);
  delayed_transfer::return_val(&mut wrapper, cap, borrow_token);

  delayed_transfer::schedule_unwrap(&mut wrapper, &clk, owner);
  clock::set_for_testing(&mut clk, 10);
  let cap = delayed_transfer::unwrap(wrapper, &clk, &mut ctx);
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
  clock::set_for_testing(&mut clk, 0);
  let wrapper = delayed_transfer::wrap(new_cap(&mut ctx), 5, &mut ctx);
  expect_execute_without_pending(wrapper, clk, &mut ctx);
}

#[test, expected_failure(abort_code = delayed_transfer::ENoPendingTransfer)]
fun unwrap_without_pending_fails() {
  let owner = @0x14;
  let mut ctx = dummy_ctx_with_sender(owner);
  let mut clk = clock::create_for_testing(&mut ctx);
  clock::set_for_testing(&mut clk, 0);
  let wrapper = delayed_transfer::wrap(new_cap(&mut ctx), 5, &mut ctx);
  expect_unwrap_without_pending(wrapper, clk, &mut ctx);
}

#[test, expected_failure(abort_code = delayed_transfer::EWrongPendingAction)]
fun execute_transfer_wrong_action_fails() {
  let owner = @0x15;
  let mut ctx = dummy_ctx_with_sender(owner);
  let mut clk = clock::create_for_testing(&mut ctx);
  clock::set_for_testing(&mut clk, 0);
  let mut wrapper = delayed_transfer::wrap(new_cap(&mut ctx), 5, &mut ctx);
  delayed_transfer::schedule_unwrap(&mut wrapper, &clk, owner);
  clock::set_for_testing(&mut clk, 10);
  delayed_transfer::execute_transfer(wrapper, &clk, &mut ctx);
  clock::destroy_for_testing(clk);
}

#[test, expected_failure(abort_code = delayed_transfer::EWrongPendingAction)]
fun unwrap_wrong_action_fails() {
  let owner = @0x16;
  let recipient = @0x17;
  let mut ctx = dummy_ctx_with_sender(owner);
  let mut clk = clock::create_for_testing(&mut ctx);
  clock::set_for_testing(&mut clk, 0);
  let mut wrapper = delayed_transfer::wrap(new_cap(&mut ctx), 5, &mut ctx);
  delayed_transfer::schedule_transfer(&mut wrapper, recipient, &clk, owner);
  clock::set_for_testing(&mut clk, 10);
  let cap = delayed_transfer::unwrap(wrapper, &clk, &mut ctx);
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
  clock::set_for_testing(&mut clk, 0);
  delayed_transfer::schedule_transfer(&mut wrapper, owner, &clk, owner);
  delayed_transfer::schedule_transfer(&mut wrapper, owner, &clk, owner);

  // Cleanup path (never reached on failure).
  clock::set_for_testing(&mut clk, 10);
  let cap = delayed_transfer::unwrap(wrapper, &clk, ctx);
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
  clock::set_for_testing(&mut clk, 0);
  delayed_transfer::schedule_transfer(&mut wrapper, recipient, &clk, owner);
  clock::set_for_testing(&mut clk, 5);
  delayed_transfer::execute_transfer(wrapper, &clk, ctx);

  clock::destroy_for_testing(clk);
}

fun attempt_early_unwrap(
  mut wrapper: delayed_transfer::DelayedTransferWrapper<DummyCap>,
  mut clk: clock::Clock,
  owner: address,
  ctx: &mut TxContext,
) {
  clock::set_for_testing(&mut clk, 0);
  delayed_transfer::schedule_unwrap(&mut wrapper, &clk, owner);
  clock::set_for_testing(&mut clk, 5);
  let cap = delayed_transfer::unwrap(wrapper, &clk, ctx);
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
  clock::set_for_testing(&mut clk, 0);
  delayed_transfer::schedule_unwrap(&mut wrapper, &clk, owner);
  delayed_transfer::schedule_unwrap(&mut wrapper, &clk, owner);

  clock::set_for_testing(&mut clk, 10);
  let cap = delayed_transfer::unwrap(wrapper, &clk, ctx);
  let DummyCap { id } = cap;
  id.delete();
  clock::destroy_for_testing(clk);
}

fun expect_cancel_without_pending(
  mut wrapper: delayed_transfer::DelayedTransferWrapper<DummyCap>,
  owner: address,
  ctx: &mut TxContext,
) {
  delayed_transfer::cancel_schedule(&mut wrapper);

  let mut clk = clock::create_for_testing(ctx);
  clock::set_for_testing(&mut clk, 0);
  delayed_transfer::schedule_unwrap(&mut wrapper, &clk, owner);
  clock::set_for_testing(&mut clk, 1);
  let cap = delayed_transfer::unwrap(wrapper, &clk, ctx);
  let DummyCap { id } = cap;
  id.delete();
  clock::destroy_for_testing(clk);
}

fun expect_execute_without_pending(
  wrapper: delayed_transfer::DelayedTransferWrapper<DummyCap>,
  mut clk: clock::Clock,
  ctx: &mut TxContext,
) {
  clock::set_for_testing(&mut clk, 0);
  delayed_transfer::execute_transfer(wrapper, &clk, ctx);
  clock::destroy_for_testing(clk);
}

fun expect_unwrap_without_pending(
  wrapper: delayed_transfer::DelayedTransferWrapper<DummyCap>,
  mut clk: clock::Clock,
  ctx: &mut TxContext,
) {
  clock::set_for_testing(&mut clk, 0);
  let cap = delayed_transfer::unwrap(wrapper, &clk, ctx);
  let DummyCap { id } = cap;
  id.delete();
  clock::destroy_for_testing(clk);
}

fun expect_return_wrong_wrapper(
  mut first: delayed_transfer::DelayedTransferWrapper<DummyCap>,
  mut second: delayed_transfer::DelayedTransferWrapper<DummyCap>,
  ctx: &mut TxContext,
) {
  let (cap, token) = delayed_transfer::borrow_val(&mut first);
  delayed_transfer::return_val(&mut second, cap, token);

  let mut clk = clock::create_for_testing(ctx);
  clock::set_for_testing(&mut clk, 1);
  let cap_first = delayed_transfer::unwrap(first, &clk, ctx);
  let DummyCap { id } = cap_first;
  id.delete();
  let cap_second = delayed_transfer::unwrap(second, &clk, ctx);
  let DummyCap { id } = cap_second;
  id.delete();
  clock::destroy_for_testing(clk);
}

fun expect_return_wrong_object(
  mut wrapper: delayed_transfer::DelayedTransferWrapper<DummyCap>,
  ctx: &mut TxContext,
) {
  let (borrowed, token) = delayed_transfer::borrow_val(&mut wrapper);
  let DummyCap { id } = borrowed;
  id.delete();

  let bogus = new_cap(ctx);
  delayed_transfer::return_val(&mut wrapper, bogus, token);

  let mut clk = clock::create_for_testing(ctx);
  clock::set_for_testing(&mut clk, 1);
  let cap = delayed_transfer::unwrap(wrapper, &clk, ctx);
  let DummyCap { id } = cap;
  id.delete();
  clock::destroy_for_testing(clk);
}
