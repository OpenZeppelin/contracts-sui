module openzeppelin_access::example_operator_handoff_tests;

use openzeppelin_access::example_operator_handoff::{Self as handoff, Service, OperatorCap};
use openzeppelin_access::two_step_transfer::{
    Self as two_step,
    TwoStepTransferWrapper,
    PendingOwnershipTransfer,
};
use std::unit_test::destroy;
use sui::test_scenario as ts;

const OWNER: address = @0xA;
const NEW_OP: address = @0xB;
const RANDOM: address = @0xCAFE;

/// Discard a reclaimed operator cap by unwrapping its wrapper and dropping the bare cap.
fun burn_wrapper(wrapper: TwoStepTransferWrapper<OperatorCap>, ctx: &mut TxContext) {
    destroy(wrapper.unwrap(ctx));
}

// Full lifecycle: wrap the cap, operate the service through the wrapper, then hand custody
// to a new operator who must accept before the wrapper moves.
#[test]
fun wrap_operate_and_hand_off() {
    let mut scenario = ts::begin(OWNER);
    let wrapper = two_step::wrap(handoff::new(scenario.ctx()), scenario.ctx());

    // The current custodian operates without unwrapping the cap.
    scenario.next_tx(OWNER);
    let mut service = scenario.take_shared<Service>();
    service.set_paused_wrapped(&wrapper, true);
    assert!(service.is_paused());
    ts::return_shared(service);

    // Initiate the handoff: the wrapper is parked in a shared request via TTO.
    wrapper.initiate_transfer(NEW_OP, scenario.ctx());

    // The new operator accepts and receives the wrapper.
    scenario.next_tx(NEW_OP);
    let request = scenario.take_shared<PendingOwnershipTransfer<OperatorCap>>();
    let ticket = ts::most_recent_receiving_ticket<TwoStepTransferWrapper<OperatorCap>>(
        &object::id(&request),
    );
    request.accept_transfer(ticket, scenario.ctx());

    // The new operator now drives the service through the same wrapper.
    scenario.next_tx(NEW_OP);
    let wrapper = scenario.take_from_sender<TwoStepTransferWrapper<OperatorCap>>();
    let mut service = scenario.take_shared<Service>();
    service.set_paused_wrapped(&wrapper, false);
    assert!(!service.is_paused());

    ts::return_shared(service);
    burn_wrapper(wrapper, scenario.ctx());
    scenario.end();
}

// The current owner can back out of a pending handoff and reclaim the wrapper intact.
#[test]
fun owner_cancels_and_reclaims() {
    let mut scenario = ts::begin(OWNER);
    let wrapper = two_step::wrap(handoff::new(scenario.ctx()), scenario.ctx());
    wrapper.initiate_transfer(NEW_OP, scenario.ctx());

    // The owner cancels; the wrapper is returned to the address that initiated.
    scenario.next_tx(OWNER);
    let request = scenario.take_shared<PendingOwnershipTransfer<OperatorCap>>();
    let ticket = ts::most_recent_receiving_ticket<TwoStepTransferWrapper<OperatorCap>>(
        &object::id(&request),
    );
    request.cancel_transfer(ticket, scenario.ctx());

    scenario.next_tx(OWNER);
    let wrapper = scenario.take_from_sender<TwoStepTransferWrapper<OperatorCap>>();
    burn_wrapper(wrapper, scenario.ctx());
    scenario.end();
}

// Even mid-handoff the owner keeps operating: pull the wrapper out of the pending request
// with `request_borrow_val`, use it, and park it back with `request_return_val`.
#[test]
fun operate_through_pending_request() {
    let mut scenario = ts::begin(OWNER);
    let wrapper = two_step::wrap(handoff::new(scenario.ctx()), scenario.ctx());
    wrapper.initiate_transfer(NEW_OP, scenario.ctx());

    scenario.next_tx(OWNER);
    let mut request = scenario.take_shared<PendingOwnershipTransfer<OperatorCap>>();
    let ticket = ts::most_recent_receiving_ticket<TwoStepTransferWrapper<OperatorCap>>(
        &object::id(&request),
    );
    let (wrapper, borrow) = request.request_borrow_val(ticket, scenario.ctx());

    let mut service = scenario.take_shared<Service>();
    service.set_paused_wrapped(&wrapper, true);
    assert!(service.is_paused());
    ts::return_shared(service);

    request.request_return_val(wrapper, borrow);
    ts::return_shared(request);
    scenario.end();
}

// Only the designated recipient can accept; a bystander is rejected.
#[test, expected_failure(abort_code = two_step::ENotNewOwner)]
fun non_recipient_cannot_accept() {
    let mut scenario = ts::begin(OWNER);
    let wrapper = two_step::wrap(handoff::new(scenario.ctx()), scenario.ctx());
    wrapper.initiate_transfer(NEW_OP, scenario.ctx());

    scenario.next_tx(RANDOM);
    let request = scenario.take_shared<PendingOwnershipTransfer<OperatorCap>>();
    let ticket = ts::most_recent_receiving_ticket<TwoStepTransferWrapper<OperatorCap>>(
        &object::id(&request),
    );
    request.accept_transfer(ticket, scenario.ctx());

    abort
}

// An operator cap minted for one service cannot operate a different service.
#[test, expected_failure(abort_code = handoff::EWrongService)]
fun foreign_cap_cannot_operate() {
    let mut scenario = ts::begin(OWNER);
    // Stand up service A (its cap is unused here), then service B with its cap.
    let _cap_a = handoff::new(scenario.ctx());
    scenario.next_tx(OWNER);
    let id_a = ts::most_recent_id_shared<Service>().destroy_some();
    let cap_b = handoff::new(scenario.ctx());

    scenario.next_tx(OWNER);
    let mut service_a = ts::take_shared_by_id<Service>(&scenario, id_a);
    // Cap B is bound to service B, so it cannot pause service A.
    service_a.set_paused(&cap_b, true);

    abort
}
