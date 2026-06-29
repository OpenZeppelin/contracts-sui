/// Safe custody and handoff of a protocol's operator capability using `two_step_transfer`.
///
/// A `Service` is a shared object guarded by a single `OperatorCap`. Whoever holds the cap
/// can pause and resume the service. Because the cap is irreplaceable - lose it to a
/// mistyped address and the service is frozen forever - it is never held bare. It is
/// wrapped in a `TwoStepTransferWrapper<OperatorCap>`, so handing operations to a new
/// custodian is a deliberate initiate -> accept handshake: the wrapper only moves once the
/// recipient explicitly accepts.
///
/// The example shows the three things an integrator does with a wrapped capability:
///  - **Use it in place.** `set_paused` borrows the cap out of the wrapper with the
///    library's `borrow`, so the current custodian operates the service without ever
///    unwrapping or exposing the bare cap.
///  - **Hand it off safely.** The tests drive `initiate_transfer` -> `accept_transfer`
///    (and the `cancel_transfer` reclaim path) directly against the library.
///  - **Keep operating mid-transfer.** While a handoff is pending the wrapper lives inside
///    the request object; `request_borrow_val` lets the current owner pull it back to
///    operate, then `request_return_val` parks it again.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `two_step_transfer` primitive can be integrated. It is not production-ready and must
/// not be deployed as-is.
module openzeppelin_access::example_operator_handoff;

use openzeppelin_access::two_step_transfer::TwoStepTransferWrapper;

// === Errors ===

/// An operator cap was presented for a different service than the one it controls.
#[error(code = 0)]
const EWrongService: vector<u8> = "Operator cap was issued for a different service";

// === Structs ===

/// Authority to operate a `Service`. `key + store` so it can be wrapped by
/// `two_step_transfer`. Bound to one service: it only operates the service whose
/// `operator` field records this cap's id.
public struct OperatorCap has key, store {
    id: UID,
}

/// A shared service whose paused state only its bound `OperatorCap` holder can toggle.
public struct Service has key {
    id: UID,
    /// Id of the `OperatorCap` authorized to operate this service.
    operator: ID,
    paused: bool,
}

// === Public Functions ===

/// Stand up a service: mint its `OperatorCap`, record the cap's id on the service so the
/// two are bound, share the `Service`, and return the cap for the caller to wrap with
/// `two_step_transfer::wrap`.
///
/// #### Parameters
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - The `OperatorCap` controlling the freshly shared `Service`.
public fun new(ctx: &mut TxContext): OperatorCap {
    let cap = OperatorCap { id: object::new(ctx) };
    transfer::share_object(Service {
        id: object::new(ctx),
        operator: object::id(&cap),
        paused: false,
    });
    cap
}

/// Toggle the service's paused state, presenting its bound operator cap as authorization.
///
/// #### Parameters
/// - `self`: The service to toggle.
/// - `cap`: The operator capability bound to this service.
/// - `paused`: New paused state.
///
/// #### Aborts
/// - `EWrongService` if `cap` is not the cap bound to this service.
public fun set_paused(self: &mut Service, cap: &OperatorCap, paused: bool) {
    assert!(object::id(cap) == self.operator, EWrongService);
    self.paused = paused;
}

/// Operate the service through a cap that is still inside its two-step wrapper, borrowing
/// it with the library's `borrow` rather than unwrapping. This is how a custodian uses a
/// safely-wrapped capability day to day.
///
/// #### Parameters
/// - `self`: The service to toggle.
/// - `wrapper`: The wrapper holding the operator cap.
/// - `paused`: New paused state.
public fun set_paused_wrapped(
    self: &mut Service,
    wrapper: &TwoStepTransferWrapper<OperatorCap>,
    paused: bool,
) {
    self.set_paused(wrapper.borrow(), paused)
}

// === View helpers ===

/// Whether the service is currently paused.
public fun is_paused(self: &Service): bool {
    self.paused
}
