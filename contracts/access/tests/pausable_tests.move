#[test_only]
module openzeppelin_access::pausable_tests;

use openzeppelin_access::pausable::{Self, Pausable};
use std::unit_test::assert_eq;
use sui::event;

public struct PausableMock has key, store {
    id: UID,
    pausable: Pausable,
}

fun new_pausable_mock(ctx: &mut TxContext): PausableMock {
    PausableMock { id: object::new(ctx), pausable: pausable::new() }
}

fun setup(): (PausableMock, TxContext) {
    let mut ctx = tx_context::dummy();
    let mock = new_pausable_mock(&mut ctx);
    (mock, ctx)
}

#[test]
fun new_creates_unpaused_state() {
    let (mock, ctx) = setup();
    assert_eq!(mock.pausable.is_paused(), false);
    transfer::transfer(mock, ctx.sender());
}

#[test]
fun pause_emits_event() {
    let (mut mock, mut ctx) = setup();

    mock.pausable.pause(&mut ctx);

    let events = event::events_by_type<pausable::Paused>();
    assert_eq!(events.length(), 1);
    assert_eq!(mock.pausable.is_paused(), true);

    transfer::transfer(mock, ctx.sender());
}

#[test]
fun unpause_emits_event() {
    let (mut mock, mut ctx) = setup();

    mock.pausable.pause(&mut ctx);
    mock.pausable.unpause(&mut ctx);

    let unpaused_events = event::events_by_type<pausable::Unpaused>();
    assert_eq!(unpaused_events.length(), 1);
    assert_eq!(mock.pausable.is_paused(), false);

    transfer::transfer(mock, ctx.sender());
}

#[test]
fun multiple_pause_unpause_cycles() {
    let (mut mock, mut ctx) = setup();

    mock.pausable.pause(&mut ctx);
    assert_eq!(mock.pausable.is_paused(), true);

    mock.pausable.unpause(&mut ctx);
    assert_eq!(mock.pausable.is_paused(), false);

    mock.pausable.pause(&mut ctx);
    assert_eq!(mock.pausable.is_paused(), true);

    mock.pausable.unpause(&mut ctx);
    assert_eq!(mock.pausable.is_paused(), false);

    let paused_events = event::events_by_type<pausable::Paused>();
    let unpaused_events = event::events_by_type<pausable::Unpaused>();
    assert_eq!(paused_events.length(), 2);
    assert_eq!(unpaused_events.length(), 2);

    transfer::transfer(mock, ctx.sender());
}

#[test, expected_failure(abort_code = pausable::EEnforcedPause)]
fun pause_when_paused_fails() {
    let (mut mock, mut ctx) = setup();
    mock.pausable.pause(&mut ctx);
    mock.pausable.pause(&mut ctx);
    transfer::transfer(mock, ctx.sender());
}

#[test, expected_failure(abort_code = pausable::EExpectedPause)]
fun unpause_when_not_paused_fails() {
    let (mut mock, mut ctx) = setup();
    mock.pausable.unpause(&mut ctx);
    transfer::transfer(mock, ctx.sender());
}

#[test]
fun assert_not_paused_succeeds_when_unpaused() {
    let (mock, ctx) = setup();
    mock.pausable.assert_not_paused();
    transfer::transfer(mock, ctx.sender());
}

#[test]
fun assert_paused_succeeds_when_paused() {
    let (mut mock, mut ctx) = setup();
    mock.pausable.pause(&mut ctx);
    mock.pausable.assert_paused();
    transfer::transfer(mock, ctx.sender());
}

#[test, expected_failure(abort_code = pausable::EEnforcedPause)]
fun assert_not_paused_fails_when_paused() {
    let (mut mock, mut ctx) = setup();
    mock.pausable.pause(&mut ctx);
    mock.pausable.assert_not_paused();
    transfer::transfer(mock, ctx.sender());
}

#[test, expected_failure(abort_code = pausable::EExpectedPause)]
fun assert_paused_fails_when_not_paused() {
    let (mock, ctx) = setup();
    mock.pausable.assert_paused();
    transfer::transfer(mock, ctx.sender());
}
