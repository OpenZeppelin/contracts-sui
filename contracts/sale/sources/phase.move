module openzeppelin_sale::phase;

// === Errors ===

/// A phase-gated operation required the `Init` phase but the sale was past it.
#[error(code = 0)]
const ENotInit: vector<u8> = "The sale must be in the setup phase";

/// A phase-gated operation required the `Active` phase: the sale was not yet
/// activated, or has already closed.
#[error(code = 1)]
const ENotActive: vector<u8> = "The sale must be open";

/// A phase-gated operation required the `Finalized` phase, e.g. a claim before the
/// sale was finalized.
#[error(code = 2)]
const ENotFinalized: vector<u8> = "The sale must have closed successfully first";

/// A phase-gated operation required the `Cancelled` phase, e.g. a refund before the
/// sale was cancelled.
#[error(code = 3)]
const ENotCancelled: vector<u8> = "The sale must have been cancelled";

/// A phase-gated operation required a terminal phase (`Finalized` or `Cancelled`).
#[error(code = 4)]
const ENotTerminal: vector<u8> = "The sale must have ended";

/// `cancel` was called on a sale already in the `Cancelled` phase.
#[error(code = 5)]
const EAlreadyCancelled: vector<u8> = "The sale has already been cancelled";

// === Structs ===

/// Lifecycle phases shared by every sale flavor.
///
/// Transitions:
///   - `Init      -> Active`                  via the flavor's `share_and_activate`
///   - `Active    -> Finalized`               via the flavor's `finalize`
///   - `Active    -> Cancelled`               via the flavor's `cancel_*`
///
/// `Finalized` and `Cancelled` are terminal.
public enum Phase has copy, drop, store {
    /// Sale exists but is not yet shared. Setup functions (deposit
    /// inventory, configure caps, pair vault, enable allowlist) run
    /// in this phase. Authority is implicit: holding the sale value
    /// by `&mut`.
    Init,
    /// Sale is shared. Purchases are accepted within
    /// `[opens_at_ms, closes_at_ms]`.
    Active,
    /// Successful close. Buyers can `claim`. Admin can withdraw
    /// proceeds and any unallocated inventory.
    Finalized,
    /// Failed close. Buyers can `refund` from the paired vault.
    /// Admin can withdraw unallocated inventory.
    Cancelled,
}

// === Public Functions ===

/// Assert the phase is `Init`.
///
/// #### Parameters
/// - `p`: The phase to check.
///
/// #### Aborts
/// - `ENotInit` if `p` is not `Init`.
public fun assert_init(p: &Phase) {
    assert!(p.is_init(), ENotInit);
}

/// Assert the phase is `Active`.
///
/// #### Parameters
/// - `p`: The phase to check.
///
/// #### Aborts
/// - `ENotActive` if `p` is not `Active`.
public fun assert_active(p: &Phase) {
    assert!(p.is_active(), ENotActive);
}

/// Assert the phase is `Finalized`.
///
/// #### Parameters
/// - `p`: The phase to check.
///
/// #### Aborts
/// - `ENotFinalized` if `p` is not `Finalized`.
public fun assert_finalized(p: &Phase) {
    assert!(p.is_finalized(), ENotFinalized);
}

/// Assert the phase is `Cancelled`.
///
/// #### Parameters
/// - `p`: The phase to check.
///
/// #### Aborts
/// - `ENotCancelled` if `p` is not `Cancelled`.
public fun assert_cancelled(p: &Phase) {
    assert!(p.is_cancelled(), ENotCancelled);
}

/// Assert the phase is terminal (`Finalized` or `Cancelled`).
///
/// #### Parameters
/// - `p`: The phase to check.
///
/// #### Aborts
/// - `ENotTerminal` if `p` is neither `Finalized` nor `Cancelled`.
public fun assert_terminal(p: &Phase) {
    assert!(p.is_finalized() || p.is_cancelled(), ENotTerminal);
}

// === Package Functions ===

/// Construct the initial `Init` phase. Called once by a sale flavor's `create_sale`.
///
/// #### Returns
/// - A `Phase` in the `Init` state.
public(package) fun phase_init(): Phase { Phase::Init }

/// Transition `Init -> Active`.
///
/// #### Parameters
/// - `phase`: The phase to advance, mutated in place.
///
/// #### Aborts
/// - `ENotInit` if `phase` is not `Init`.
public(package) fun activate(phase: &mut Phase) {
    assert!(phase.is_init(), ENotInit);
    *phase = Phase::Active;
}

/// Transition `Active -> Finalized`.
///
/// #### Parameters
/// - `phase`: The phase to advance, mutated in place.
///
/// #### Aborts
/// - `ENotActive` if `phase` is not `Active`.
public(package) fun finalize(phase: &mut Phase) {
    assert!(phase.is_active(), ENotActive);
    *phase = Phase::Finalized;
}

/// Transition to `Cancelled`. The only guard is non-idempotency; the calling sale
/// flavor enforces the `Active`-only precondition before reaching this.
///
/// #### Parameters
/// - `phase`: The phase to cancel, mutated in place.
///
/// #### Aborts
/// - `EAlreadyCancelled` if `phase` is already `Cancelled`.
public(package) fun cancel(phase: &mut Phase) {
    assert!(!phase.is_cancelled(), EAlreadyCancelled);
    *phase = Phase::Cancelled;
}

/// True if the phase is `Init`.
public(package) fun is_init(p: &Phase): bool {
    match (p) {
        Phase::Init => true,
        _ => false,
    }
}

/// True if the phase is `Active`.
public(package) fun is_active(p: &Phase): bool {
    match (p) {
        Phase::Active => true,
        _ => false,
    }
}

/// True if the phase is `Finalized`.
public(package) fun is_finalized(p: &Phase): bool {
    match (p) {
        Phase::Finalized => true,
        _ => false,
    }
}

/// True if the phase is `Cancelled`.
public(package) fun is_cancelled(p: &Phase): bool {
    match (p) {
        Phase::Cancelled => true,
        _ => false,
    }
}
