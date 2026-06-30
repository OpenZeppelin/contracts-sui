// Lifecycle enum tests for `phase`.
//
// The phase module enforces the *source-state* asserts on each transition.
// Note the terminal-ness of `Finalized` is enforced at the sale layer (every
// sale transition calls `assert_active` first), not inside `phase::cancel`
// (which only asserts `!is_cancelled`). The sale-layer guards are exercised in
// `prefunded_sale_lifecycle_tests`.
module openzeppelin_sale::phase_tests;

use openzeppelin_sale::phase;
use std::unit_test::assert_eq;

#[test]
fun init_then_activate_then_finalize() {
    let mut p = phase::phase_init();
    assert_eq!(p.is_init(), true);
    p.activate();
    assert_eq!(p.is_active(), true);
    p.finalize();
    assert_eq!(p.is_finalized(), true);
}

#[test]
fun init_then_activate_then_cancel() {
    let mut p = phase::phase_init();
    p.activate();
    p.cancel();
    assert_eq!(p.is_cancelled(), true);
}

// activate is only valid from Init.
#[test, expected_failure(abort_code = phase::ENotInit)]
fun activate_from_active_aborts() {
    let mut p = phase::phase_init();
    p.activate();
    p.activate(); // aborts: ENotInit
}

// finalize is only valid from Active.
#[test, expected_failure(abort_code = phase::ENotActive)]
fun finalize_from_init_aborts() {
    let mut p = phase::phase_init();
    p.finalize(); // aborts: ENotActive
}

// cancel cannot be repeated.
#[test, expected_failure(abort_code = phase::EAlreadyCancelled)]
fun cancel_twice_aborts() {
    let mut p = phase::phase_init();
    p.activate();
    p.cancel();
    p.cancel(); // aborts: EAlreadyCancelled
}
