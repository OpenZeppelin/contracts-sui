module openzeppelin_access::two_step_tests;

use openzeppelin_access::two_step_transfer;
use sui::event;

#[test_only]
public struct DummyCap has key, store {
    id: sui::object::UID,
}

fun new_ctx(sender: address, hint: u64): TxContext {
    sui::tx_context::new(
        sender,
        sui::tx_context::dummy_tx_hash_with_hint(hint),
        0,
        0,
        0,
    )
}

fun new_cap(ctx: &mut TxContext): DummyCap {
    DummyCap { id: sui::object::new(ctx) }
}

#[test]
fun request_emits_event() {
    let owner = @0x1;
    let mut ctx = new_ctx(owner, 0);
    let wrapper = two_step_transfer::wrap(new_cap(&mut ctx), &mut ctx);

    two_step_transfer::request<DummyCap>(sui::object::id(&wrapper), owner, &mut ctx);

    let events = event::events_by_type<two_step_transfer::OwnershipRequested>();
    assert!(std::vector::length(&events) == 1, 0);

    let DummyCap { id } = two_step_transfer::unwrap(wrapper);
    id.delete();
}

#[test]
fun unwrap_returns_inner_cap() {
    let owner = @0x2;
    let mut ctx = new_ctx(owner, 1);
    let wrapper = two_step_transfer::wrap(new_cap(&mut ctx), &mut ctx);

    let cap = two_step_transfer::unwrap(wrapper);
    let DummyCap { id } = cap;
    id.delete();
}
