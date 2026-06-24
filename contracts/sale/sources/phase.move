module openzeppelin_sale::phase;

#[error(code = 0)]
const ENotInit: vector<u8> = "Sale must be in Init phase";

#[error(code = 1)]
const ENotActive: vector<u8> = "Sale must be in Active phase";

#[error(code = 2)]
const ENotFinalized: vector<u8> = "Sale must be in Finalized phase";

#[error(code = 3)]
const ENotCancelled: vector<u8> = "Sale must be in Cancelled phase";

#[error(code = 4)]
const ENotTerminal: vector<u8> = "Sale must be in a terminal phase (Finalized or Cancelled)";

#[error(code = 5)]
const EAlreadyCancelled: vector<u8> = "Already in the Cancelled phase";

/// Lifecycle phases shared by every sale flavor.
///
/// Transitions:
///   - `Init      → Active`                  via the flavor's `share_and_activate`
///   - `Active    → Finalized`               via the flavor's `finalize`
///   - `Active    → Cancelled`               via the flavor's `cancel_*`
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

public(package) fun phase_init(): Phase { Phase::Init }

public(package) fun activate(phase: &mut Phase) {
    assert!(phase.is_init(), ENotInit);
    *phase = Phase::Active;
}

public(package) fun finalize(phase: &mut Phase) {
    assert!(phase.is_active(), ENotActive);
    *phase = Phase::Finalized;
}

public(package) fun cancel(phase: &mut Phase) {
    assert!(!phase.is_cancelled(), EAlreadyCancelled);
    *phase = Phase::Cancelled;
}

public(package) fun is_init(p: &Phase): bool {
    match (p) {
        Phase::Init => true,
        _ => false,
    }
}

public(package) fun is_active(p: &Phase): bool {
    match (p) {
        Phase::Active => true,
        _ => false,
    }
}

public(package) fun is_finalized(p: &Phase): bool {
    match (p) {
        Phase::Finalized => true,
        _ => false,
    }
}

public(package) fun is_cancelled(p: &Phase): bool {
    match (p) {
        Phase::Cancelled => true,
        _ => false,
    }
}

public fun assert_init(p: &Phase) {
    assert!(p.is_init(), ENotInit);
}

public fun assert_active(p: &Phase) {
    assert!(p.is_active(), ENotActive);
}

public fun assert_finalized(p: &Phase) {
    assert!(p.is_finalized(), ENotFinalized);
}

public fun assert_cancelled(p: &Phase) {
    assert!(p.is_cancelled(), ENotCancelled);
}

public fun assert_terminal(p: &Phase) {
    assert!(p.is_finalized() || p.is_cancelled(), ENotTerminal);
}
