#[test_only]
module openzeppelin_access::two_step_tests;

use openzeppelin_access::two_step_transfer;
use std::unit_test::assert_eq;
use sui::event;
use sui::test_scenario;

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
fun initiate_transfer_emits_event() {
    let owner = @0x1;
    let new_owner = @0x2;
    let mut test = test_scenario::begin(owner);
    let wrapper = two_step_transfer::wrap(new_cap(test.ctx()), test.ctx());
    let wrapper_id = object::id(&wrapper);

    wrapper.initiate_transfer(new_owner, test.ctx());

    let expected_event = two_step_transfer::test_new_transfer_initiated(
        wrapper_id,
        owner,
        new_owner,
    );
    let events = event::events_by_type<two_step_transfer::TransferInitiated<DummyCap>>();
    assert_eq!(events.length(), 1);
    assert_eq!(expected_event, events[0]);

    test.next_tx(owner);
    let request = test.take_shared<two_step_transfer::PendingOwnershipTransfer<DummyCap>>();
    let request_id = object::id(&request);
    let ticket = test_scenario::most_recent_receiving_ticket<
        two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    >(&request_id);
    request.cancel_transfer(ticket, test.ctx());

    test.next_tx(owner);
    let wrapper = test.take_from_sender<two_step_transfer::TwoStepTransferWrapper<DummyCap>>();
    let DummyCap { id } = wrapper.unwrap(test.ctx());
    id.delete();
    test.end();
}

#[test]
fun wrap_roundtrip() {
    let owner = @0x2;
    let mut ctx = dummy_ctx_with_sender(owner);
    let obj = new_cap(&mut ctx);
    let obj_id = object::id(&obj);

    // wrap flow

    let wrapper = two_step_transfer::wrap(obj, &mut ctx);
    let wrapper_id = object::id(&wrapper);

    let expected_event = two_step_transfer::test_new_wrap_executed(wrapper_id, obj_id, owner);

    let events = event::events_by_type<two_step_transfer::WrapExecuted<DummyCap>>();
    assert_eq!(events.length(), 1);
    assert_eq!(expected_event, events[0]);

    // unwrap flow

    let obj = wrapper.unwrap(&mut ctx);

    let expected_event = two_step_transfer::test_new_unwrap_executed(wrapper_id, obj_id, owner);

    let events = event::events_by_type<two_step_transfer::UnwrapExecuted<DummyCap>>();
    assert_eq!(events.length(), 1);
    assert_eq!(expected_event, events[0]);

    let DummyCap { id } = obj;
    id.delete();
}

#[test]
fun borrow_and_return_roundtrip() {
    // Owner wraps an object, borrows it temporarily, and returns it before unwrapping again.
    let owner = @0xA;
    let mut ctx = dummy_ctx_with_sender(owner);
    let mut wrapper = two_step_transfer::wrap(new_cap(&mut ctx), &mut ctx);

    let readonly = wrapper.borrow();
    assert_eq!(object::id(readonly), object::id(wrapper.borrow_mut()));

    let (obj, borrow_token) = wrapper.borrow_val();
    wrapper.return_val(obj, borrow_token);

    let DummyCap { id } = wrapper.unwrap(&mut ctx);
    id.delete();
}

#[test, expected_failure(abort_code = two_step_transfer::EWrongTwoStepTransferWrapper)]
fun return_val_rejects_wrong_wrapper() {
    // Borrow from one wrapper but attempt to return into another—should abort.
    let owner = @0xB;
    let mut ctx = dummy_ctx_with_sender(owner);
    let first = two_step_transfer::wrap(new_cap(&mut ctx), &mut ctx);
    let second = two_step_transfer::wrap(new_cap(&mut ctx), &mut ctx);

    expect_wrapper_mismatch(first, second, &mut ctx);
}

#[test, expected_failure(abort_code = two_step_transfer::EWrongTwoStepTransferObject)]
fun return_val_rejects_wrong_object() {
    // Returning a different object than the one borrowed must fail.
    let owner = @0xC;
    let mut ctx = dummy_ctx_with_sender(owner);
    let wrapper = two_step_transfer::wrap(new_cap(&mut ctx), &mut ctx);

    expect_object_mismatch(wrapper, &mut ctx);
}

#[test]
fun accept_transfer_emits_event() {
    // Prospective owner accepts a valid transfer request and emits TransferAccepted.
    let owner = @0xD;
    let new_owner = @0xE;
    let mut test = test_scenario::begin(owner);
    let wrapper = two_step_transfer::wrap(new_cap(test.ctx()), test.ctx());
    let wrapper_id = object::id(&wrapper);
    wrapper.initiate_transfer(new_owner, test.ctx());

    test.next_tx(new_owner);
    let request = test.take_shared<two_step_transfer::PendingOwnershipTransfer<DummyCap>>();
    let request_id = object::id(&request);
    let ticket = test_scenario::most_recent_receiving_ticket<
        two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    >(&request_id);
    request.accept_transfer(ticket, test.ctx());

    let expected_event = two_step_transfer::test_new_transfer_accepted(
        wrapper_id,
        owner,
        new_owner,
    );
    let events = event::events_by_type<two_step_transfer::TransferAccepted<DummyCap>>();
    assert_eq!(events.length(), 1);
    assert_eq!(expected_event, events[0]);

    test.next_tx(new_owner);
    let wrapper = test.take_from_sender<two_step_transfer::TwoStepTransferWrapper<DummyCap>>();
    let DummyCap { id } = wrapper.unwrap(test.ctx());
    id.delete();
    test.end();
}

#[test, expected_failure(abort_code = two_step_transfer::ENotNewOwner)]
fun accept_transfer_rejects_non_new_owner() {
    let owner = @0x11;
    let new_owner = @0x12;
    let attacker = @0x13;
    let mut test = test_scenario::begin(owner);
    let wrapper = two_step_transfer::wrap(new_cap(test.ctx()), test.ctx());
    wrapper.initiate_transfer(new_owner, test.ctx());

    test.next_tx(attacker);
    let request = test.take_shared<two_step_transfer::PendingOwnershipTransfer<DummyCap>>();
    let request_id = object::id(&request);
    let ticket = test_scenario::most_recent_receiving_ticket<
        two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    >(&request_id);
    request.accept_transfer(ticket, test.ctx());
    test.end();
}

#[test, expected_failure(abort_code = two_step_transfer::EInvalidTransferRequest)]
fun accept_transfer_rejects_mismatched_wrapper() {
    // Accepting a request that references a different wrapper must abort.
    let owner = @0xF;
    let new_owner = @0xE;
    let mut test = test_scenario::begin(owner);
    let wrapper = two_step_transfer::wrap(new_cap(test.ctx()), test.ctx());
    let extra_wrapper = two_step_transfer::wrap(new_cap(test.ctx()), test.ctx());
    wrapper.initiate_transfer(new_owner, test.ctx());
    extra_wrapper.test_transfer_wrapper(owner);

    test.next_tx(owner);
    let request = test.take_shared<two_step_transfer::PendingOwnershipTransfer<DummyCap>>();
    let request_id = object::id(&request);
    let extra_wrapper = test.take_from_sender<
        two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    >();
    extra_wrapper.test_transfer_wrapper(object::id_address(&request));
    test_scenario::return_shared(request);

    test.next_tx(new_owner);
    let request = test.take_shared<two_step_transfer::PendingOwnershipTransfer<DummyCap>>();
    let ticket = test_scenario::most_recent_receiving_ticket<
        two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    >(&request_id);
    request.accept_transfer(ticket, test.ctx());
    test.end();
}

#[test]
fun cancel_transfer_emits_event() {
    // Owner can cancel a pending request and emits a TransferCancelled event.
    let owner = @0x10;
    let new_owner = @0x11;
    let mut test = test_scenario::begin(owner);
    let wrapper = two_step_transfer::wrap(new_cap(test.ctx()), test.ctx());
    let wrapper_id = object::id(&wrapper);
    wrapper.initiate_transfer(new_owner, test.ctx());

    test.next_tx(owner);
    let request = test.take_shared<two_step_transfer::PendingOwnershipTransfer<DummyCap>>();
    let request_id = object::id(&request);
    let ticket = test_scenario::most_recent_receiving_ticket<
        two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    >(&request_id);
    request.cancel_transfer(ticket, test.ctx());

    let expected_event = two_step_transfer::test_new_transfer_cancelled(
        wrapper_id,
        owner,
        new_owner,
    );

    let events = event::events_by_type<two_step_transfer::TransferCancelled<DummyCap>>();
    assert_eq!(events.length(), 1);
    assert_eq!(expected_event, events[0]);

    test.next_tx(owner);
    let wrapper = test.take_from_sender<two_step_transfer::TwoStepTransferWrapper<DummyCap>>();
    let DummyCap { id } = wrapper.unwrap(test.ctx());
    id.delete();
    test.end();
}

#[test, expected_failure(abort_code = two_step_transfer::ENotOwner)]
fun cancel_transfer_rejects_non_owner() {
    let owner = @0x12;
    let new_owner = @0x13;
    let attacker = @0x14;
    let mut test = test_scenario::begin(owner);
    let wrapper = two_step_transfer::wrap(new_cap(test.ctx()), test.ctx());
    wrapper.initiate_transfer(new_owner, test.ctx());

    test.next_tx(attacker);
    let request = test.take_shared<two_step_transfer::PendingOwnershipTransfer<DummyCap>>();
    let request_id = object::id(&request);
    let ticket = test_scenario::most_recent_receiving_ticket<
        two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    >(&request_id);
    request.cancel_transfer(ticket, test.ctx());
    test.end();
}

#[test]
fun request_borrow_val_roundtrip() {
    let owner = @0x20;
    let new_owner = @0x21;
    let mut test = test_scenario::begin(owner);
    let wrapper = two_step_transfer::wrap(new_cap(test.ctx()), test.ctx());
    wrapper.initiate_transfer(new_owner, test.ctx());

    test.next_tx(owner);
    let mut request = test.take_shared<two_step_transfer::PendingOwnershipTransfer<DummyCap>>();
    let request_id = object::id(&request);
    let ticket = test_scenario::most_recent_receiving_ticket<
        two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    >(&request_id);
    let (wrapper, borrow) = request.request_borrow_val(ticket, test.ctx());
    request.request_return_val(wrapper, borrow);
    test_scenario::return_shared(request);

    test.next_tx(owner);
    let request = test.take_shared<two_step_transfer::PendingOwnershipTransfer<DummyCap>>();
    let request_id = object::id(&request);
    let ticket = test_scenario::most_recent_receiving_ticket<
        two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    >(&request_id);
    request.cancel_transfer(ticket, test.ctx());

    test.next_tx(owner);
    let wrapper = test.take_from_sender<two_step_transfer::TwoStepTransferWrapper<DummyCap>>();
    let DummyCap { id } = wrapper.unwrap(test.ctx());
    id.delete();
    test.end();
}

#[test, expected_failure(abort_code = two_step_transfer::ENotOwner)]
fun request_borrow_val_rejects_non_owner() {
    let owner = @0x21;
    let new_owner = @0x22;
    let attacker = @0x23;
    let mut test = test_scenario::begin(owner);
    let wrapper = two_step_transfer::wrap(new_cap(test.ctx()), test.ctx());
    wrapper.initiate_transfer(new_owner, test.ctx());

    test.next_tx(attacker);
    let mut request = test.take_shared<two_step_transfer::PendingOwnershipTransfer<DummyCap>>();
    let request_id = object::id(&request);
    let ticket = test_scenario::most_recent_receiving_ticket<
        two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    >(&request_id);
    let (wrapper, borrow) = request.request_borrow_val(ticket, test.ctx());
    request.request_return_val(wrapper, borrow);
    test_scenario::return_shared(request);
    test.end();
}

#[test, expected_failure(abort_code = two_step_transfer::EInvalidTransferRequest)]
fun request_return_val_rejects_wrong_wrapper() {
    let owner = @0x30;
    let new_owner = @0x31;
    let mut test = test_scenario::begin(owner);
    let wrapper = two_step_transfer::wrap(new_cap(test.ctx()), test.ctx());
    let extra_wrapper = two_step_transfer::wrap(new_cap(test.ctx()), test.ctx());
    extra_wrapper.test_transfer_wrapper(owner);
    wrapper.initiate_transfer(new_owner, test.ctx());

    test.next_tx(owner);
    let mut request = test.take_shared<two_step_transfer::PendingOwnershipTransfer<DummyCap>>();
    let request_id = object::id(&request);
    let extra_wrapper = test.take_from_sender<
        two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    >();
    let ticket = test_scenario::most_recent_receiving_ticket<
        two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    >(&request_id);
    let (wrapper, borrow) = request.request_borrow_val(ticket, test.ctx());
    let DummyCap { id } = wrapper.unwrap(test.ctx());
    id.delete();

    request.request_return_val(extra_wrapper, borrow);
    test_scenario::return_shared(request);
    test.end();
}

#[test, expected_failure(abort_code = two_step_transfer::EInvalidTransferRequest)]
fun cancel_transfer_rejects_mismatched_wrapper() {
    let owner = @0x40;
    let new_owner = @0x41;
    let mut test = test_scenario::begin(owner);
    let wrapper = two_step_transfer::wrap(new_cap(test.ctx()), test.ctx());
    let extra_wrapper = two_step_transfer::wrap(new_cap(test.ctx()), test.ctx());
    wrapper.initiate_transfer(new_owner, test.ctx());
    extra_wrapper.test_transfer_wrapper(owner);

    test.next_tx(owner);
    let request = test.take_shared<two_step_transfer::PendingOwnershipTransfer<DummyCap>>();
    let request_id = object::id(&request);
    let extra_wrapper = test.take_from_sender<
        two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    >();
    extra_wrapper.test_transfer_wrapper(object::id_address(&request));
    test_scenario::return_shared(request);

    test.next_tx(owner);
    let request = test.take_shared<two_step_transfer::PendingOwnershipTransfer<DummyCap>>();
    let ticket = test_scenario::most_recent_receiving_ticket<
        two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    >(&request_id);
    request.cancel_transfer(ticket, test.ctx());
    test.end();
}

#[test]
fun request_borrow_val_inner_cap_roundtrip() {
    let owner = @0x42;
    let new_owner = @0x43;
    let mut test = test_scenario::begin(owner);
    let wrapper = two_step_transfer::wrap(new_cap(test.ctx()), test.ctx());
    wrapper.initiate_transfer(new_owner, test.ctx());

    test.next_tx(owner);
    let mut request = test.take_shared<two_step_transfer::PendingOwnershipTransfer<DummyCap>>();
    let request_id = object::id(&request);
    let ticket = test_scenario::most_recent_receiving_ticket<
        two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    >(&request_id);
    let (mut wrapper, request_borrow) = request.request_borrow_val(ticket, test.ctx());

    let (obj, obj_borrow) = wrapper.borrow_val();
    wrapper.return_val(obj, obj_borrow);

    request.request_return_val(wrapper, request_borrow);
    test_scenario::return_shared(request);

    test.next_tx(owner);
    let request = test.take_shared<two_step_transfer::PendingOwnershipTransfer<DummyCap>>();
    let request_id = object::id(&request);
    let ticket = test_scenario::most_recent_receiving_ticket<
        two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    >(&request_id);
    request.cancel_transfer(ticket, test.ctx());

    test.next_tx(owner);
    let wrapper = test.take_from_sender<two_step_transfer::TwoStepTransferWrapper<DummyCap>>();
    let DummyCap { id } = wrapper.unwrap(test.ctx());
    id.delete();
    test.end();
}

#[test, expected_failure(abort_code = two_step_transfer::EInvalidTransferRequest)]
fun request_return_val_rejects_wrong_request() {
    let owner = @0x44;
    let new_owner = @0x45;
    let mut test = test_scenario::begin(owner);
    let wrapper = two_step_transfer::wrap(new_cap(test.ctx()), test.ctx());
    wrapper.initiate_transfer(new_owner, test.ctx());

    test.next_tx(owner);
    let mut request = test.take_shared<two_step_transfer::PendingOwnershipTransfer<DummyCap>>();
    let request_id = object::id(&request);
    let ticket = test_scenario::most_recent_receiving_ticket<
        two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    >(&request_id);
    let (wrapper, borrow) = request.request_borrow_val(ticket, test.ctx());

    let temp_cap = new_cap(test.ctx());
    let wrong_wrapper_id = object::id(&temp_cap);
    let DummyCap { id } = temp_cap;
    id.delete();

    let bogus_request = two_step_transfer::test_new_request<DummyCap>(
        wrong_wrapper_id,
        owner,
        new_owner,
        test.ctx(),
    );

    bogus_request.request_return_val(wrapper, borrow);
    bogus_request.test_destroy_request();
    test_scenario::return_shared(request);
    test.end();
}

#[test]
fun consecutive_transfers() {
    let owner_a = @0x46;
    let owner_b = @0x47;
    let owner_c = @0x48;
    let mut test = test_scenario::begin(owner_a);
    let wrapper = two_step_transfer::wrap(new_cap(test.ctx()), test.ctx());

    // A → B
    wrapper.initiate_transfer(owner_b, test.ctx());

    test.next_tx(owner_b);
    let request = test.take_shared<two_step_transfer::PendingOwnershipTransfer<DummyCap>>();
    let request_id = object::id(&request);
    let ticket = test_scenario::most_recent_receiving_ticket<
        two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    >(&request_id);
    request.accept_transfer(ticket, test.ctx());

    // B → C
    test.next_tx(owner_b);
    let wrapper = test.take_from_sender<two_step_transfer::TwoStepTransferWrapper<DummyCap>>();
    wrapper.initiate_transfer(owner_c, test.ctx());

    test.next_tx(owner_c);
    let request = test.take_shared<two_step_transfer::PendingOwnershipTransfer<DummyCap>>();
    let request_id = object::id(&request);
    let ticket = test_scenario::most_recent_receiving_ticket<
        two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    >(&request_id);
    request.accept_transfer(ticket, test.ctx());

    // C unwraps
    test.next_tx(owner_c);
    let wrapper = test.take_from_sender<two_step_transfer::TwoStepTransferWrapper<DummyCap>>();
    let DummyCap { id } = wrapper.unwrap(test.ctx());
    id.delete();
    test.end();
}

#[test]
fun new_owner_can_use_wrapper_after_accept() {
    let owner = @0x49;
    let new_owner = @0x4A;
    let mut test = test_scenario::begin(owner);
    let wrapper = two_step_transfer::wrap(new_cap(test.ctx()), test.ctx());
    wrapper.initiate_transfer(new_owner, test.ctx());

    test.next_tx(new_owner);
    let request = test.take_shared<two_step_transfer::PendingOwnershipTransfer<DummyCap>>();
    let request_id = object::id(&request);
    let ticket = test_scenario::most_recent_receiving_ticket<
        two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    >(&request_id);
    request.accept_transfer(ticket, test.ctx());

    test.next_tx(new_owner);
    let mut wrapper = test.take_from_sender<two_step_transfer::TwoStepTransferWrapper<DummyCap>>();
    let _ref = wrapper.borrow();
    let (obj, borrow_token) = wrapper.borrow_val();
    wrapper.return_val(obj, borrow_token);

    let DummyCap { id } = wrapper.unwrap(test.ctx());
    id.delete();
    test.end();
}

fun expect_wrapper_mismatch(
    mut first: two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    mut second: two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    ctx: &mut TxContext,
) {
    let (obj, borrow_token) = first.borrow_val();
    second.return_val(obj, borrow_token);

    let DummyCap { id } = first.unwrap(ctx);
    id.delete();
    let DummyCap { id } = second.unwrap(ctx);
    id.delete();
}

fun expect_object_mismatch(
    mut wrapper: two_step_transfer::TwoStepTransferWrapper<DummyCap>,
    ctx: &mut TxContext,
) {
    let (borrowed_cap, borrow_token) = wrapper.borrow_val();
    let DummyCap { id } = borrowed_cap;
    id.delete();
    let bogus_cap = new_cap(ctx);
    wrapper.return_val(bogus_cap, borrow_token);

    let DummyCap { id } = wrapper.unwrap(ctx);
    id.delete();
}
