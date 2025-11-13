module openzeppelin_access::delayed_tests;

use openzeppelin_access::delayed_transfer;
use sui::clock;
use sui::event;

#[test_only]
public struct DummyCap has key, store {
    id: sui::object::UID,
}

fun new_ctx(sender: address, hint: u64): sui::tx_context::TxContext {
    sui::tx_context::new(
        sender,
        sui::tx_context::dummy_tx_hash_with_hint(hint),
        0,
        0,
        0,
    )
}

fun new_cap(ctx: &mut sui::tx_context::TxContext): DummyCap {
    DummyCap { id: sui::object::new(ctx) }
}

#[test]
fun schedule_and_execute_transfer() {
    let owner = @0x1;
    let recipient = @0x2;
    let mut ctx = new_ctx(owner, 0);
    let mut wrapper = delayed_transfer::wrap(new_cap(&mut ctx), 5, &mut ctx);

    let mut clk = clock::create_for_testing(&mut ctx);
    clock::set_for_testing(&mut clk, 1);

    delayed_transfer::schedule_transfer(&mut wrapper, recipient, &clk, owner);
    let scheduled = event::events_by_type<delayed_transfer::TransferScheduled>();
    assert!(std::vector::length(&scheduled) == 1, 0);

    clock::set_for_testing(&mut clk, 10);
    delayed_transfer::execute_transfer(wrapper, &clk, &mut ctx);

    let executed = event::events_by_type<delayed_transfer::OwnershipTransferred>();
    assert!(std::vector::length(&executed) == 1, 1);

    clock::destroy_for_testing(clk);
}

#[test]
fun schedule_and_unwrap_after_delay() {
    let owner = @0x3;
    let mut ctx = new_ctx(owner, 1);
    let mut wrapper = delayed_transfer::wrap(new_cap(&mut ctx), 7, &mut ctx);

    let mut clk = clock::create_for_testing(&mut ctx);
    clock::set_for_testing(&mut clk, 0);

    delayed_transfer::schedule_unwrap(&mut wrapper, &clk, owner);
    let scheduled = event::events_by_type<delayed_transfer::UnwrapScheduled>();
    assert!(std::vector::length(&scheduled) == 1, 0);

    clock::set_for_testing(&mut clk, 10);
    let cap = delayed_transfer::unwrap(wrapper, &clk, &mut ctx);

    let DummyCap { id } = cap;
    id.delete();

    clock::destroy_for_testing(clk);
}
