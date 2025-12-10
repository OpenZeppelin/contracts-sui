/// Pausable mechanism to control emergency stops in contract functionality.
///
/// Provides a boolean flag (`paused`) that can be toggled to temporarily halt operations.
/// Integrators embed the `Pausable` struct and use `assert_not_paused()` or `assert_paused()`
/// guards in their functions to enforce the pause state.
///
/// Events are emitted when pausing or unpausing to enable off-chain tracking of state changes.
module openzeppelin_access::pausable;

use sui::event;

/// State tracker for pause status. Embed this in your contract's shared object or capability
/// to enable pause control.
public struct Pausable has store {
    paused: bool,
}

// === Errors ===

#[error(code = 0)]
const EEnforcedPause: vector<u8> = b"EnforcedPause";
#[error(code = 1)]
const EExpectedPause: vector<u8> = b"ExpectedPause";

// === Events ===

/// Emitted when the pause is triggered by `account`.
public struct Paused has copy, drop {
    account: address,
}

/// Emitted when the pause is lifted by `account`.
public struct Unpaused has copy, drop {
    account: address,
}

// === Functions ===

/// Create a new `Pausable` instance in the unpaused state.
public fun new(): Pausable {
    Pausable { paused: false }
}

/// Triggers the paused state.
///
/// Requirements:
///
/// - The contract is not paused.
///
/// Emits a `Paused` event.
public fun pause(self: &mut Pausable, ctx: &mut TxContext) {
    self.assert_not_paused();
    self.paused = true;
    event::emit(Paused { account: ctx.sender() });
}

/// Lifts the pause on the contract.
///
/// Requirements:
///
/// - The contract is paused.
///
/// Emits an `Unpaused` event.
public fun unpause(self: &mut Pausable, ctx: &mut TxContext) {
    self.assert_paused();
    self.paused = false;
    event::emit(Unpaused { account: ctx.sender() });
}

/// Check whether the contract is currently paused.
public fun is_paused(self: &Pausable): bool {
    self.paused
}

/// Revert if the contract is paused. Use as a guard in pausable operations.
public fun assert_not_paused(self: &Pausable) {
    assert!(!self.paused, EEnforcedPause);
}

/// Revert if the contract is not paused. Use when an operation requires the paused state.
public fun assert_paused(self: &Pausable) {
    assert!(self.paused, EExpectedPause);
}
