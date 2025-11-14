module openzeppelin_access::delayed_tests;

use openzeppelin_access::delayed_transfer;
use sui::clock;
use sui::event;
use std::unit_test::assert_eq;

#[test_only]
public struct DummyCap has key, store {
    id: sui::object::UID,
}

public fun new_ctx(sender: address): TxContext {
    let tx_hash = x"3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532";
    tx_context::new(sender, tx_hash, 0, 0, 0)
}

fun new_cap(ctx: &mut TxContext): DummyCap {
    DummyCap { id: sui::object::new(ctx) }
}

#[test]
fun schedule_and_execute_transfer() {
    let owner = @0x1;
    let recipient = @0x2;
    let mut ctx = new_ctx(owner);
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
    let mut ctx = new_ctx(owner);
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
