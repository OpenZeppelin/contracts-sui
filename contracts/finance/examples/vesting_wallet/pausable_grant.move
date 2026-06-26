/// A pausable wrapper around any vesting curve - a worked example of the
/// curve-agnostic wrapper pattern from `vesting_wallet`'s docs.
///
/// `PausableGrant<S, P, C>` nests a `VestingWallet<S, P, C>` and stays generic over
/// the curve (`S`, `P`), so it works with `vesting_wallet_linear`, the quadratic
/// example, or any future curve. It hands out an immutable `&inner` (enough for any
/// curve module to mint a `VestedAmount`), keeps `&mut inner` private, and re-exposes
/// `release` behind a pause check. An employer holding the `GrantAdminCap` can freeze
/// the stream (say, on suspected wrongdoing) and resume it later.
///
/// Releasing needs only `&VestedAmount<S>` and `&mut wallet` - not the witness `S` -
/// which is what lets a wrapper that cannot construct `S` still drive release. The
/// caller picks the curve at the call site:
///
/// ```move
/// let v = vesting_wallet_linear::vested_amount(grant.inner(), clock);
/// grant.release(&v, ctx);
/// ```
///
/// # What the curve-agnostic core can and cannot do
///
/// The primitive only ever pays the wallet's fixed `beneficiary`; it exposes no path
/// to withdraw balance to a third party. So a wrapper that does not own the witness
/// `S` *cannot* claw unvested funds back to the employer - pausing freezes the stream
/// but does not refund it. This example stays honest about that boundary: it pauses, it
/// does not refund.
///
/// Teardown follows the same split. `vesting_wallet::destroy_empty` is permissionless,
/// but it requires a drained wallet and only hands back a `DestroyReceipt` that the
/// curve module must consume with its witness `S`. A curve-agnostic wrapper has no `S`,
/// so it cannot finalize teardown itself. What it *can* do is dissolve the wrapper:
/// `unwrap` consumes the grant and its admin cap and returns the bare nested wallet, so
/// the holder can then run the curve module's teardown (`destroy_empty` + the curve's
/// witness-gated `destroy`) against it. See the tests for the end-to-end flow.
///
/// The wallet must be funded *before* it is wrapped, since `new` consumes it and the
/// wrapper never re-exposes `&mut inner`. Re-enabling top-ups would mean adding a
/// `deposit` passthrough (safe, as deposit is permissionless); it is left out here to
/// keep the surface minimal.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `vesting_wallet` primitive can be integrated. It is not production-ready and must
/// not be deployed as-is.
module openzeppelin_finance::example_pausable_grant;

use openzeppelin_finance::vesting_wallet::{VestingWallet, VestedAmount};

// === Errors ===

/// `release` was called while the grant was paused.
#[error(code = 0)]
const EPaused: vector<u8> = "Grant is paused; releases are frozen";
/// An admin cap was presented for a different grant than the one it controls.
#[error(code = 1)]
const EWrongGrant: vector<u8> = "Admin cap was issued for a different grant";

// === Structs ===

/// A shared, pausable vesting grant wrapping a single curve's wallet. Stays generic
/// over `S`, `P` so one wrapper serves every curve.
public struct PausableGrant<phantom S: drop, P: copy + drop + store, phantom C> has key {
    id: UID,
    /// The nested wallet. Only ever exposed immutably (`inner`); `&mut` stays private.
    inner: VestingWallet<S, P, C>,
    /// When true, `release` aborts.
    paused: bool,
}

/// Authority to pause and resume a specific grant, held by the employer. Bound to its
/// grant by id, mirroring how `VestedAmount` is bound to its wallet.
public struct GrantAdminCap has key, store {
    id: UID,
    grant_id: ID,
}

// === Public Functions ===

/// Wrap an already-funded wallet in a pausable grant, share the grant, and return the
/// admin cap to the caller. Taking a pre-built `VestingWallet` (rather than
/// constructing it here) is what keeps the wrapper generic over the curve - the
/// caller picks the curve module.
public fun new<S: drop, P: copy + drop + store, C>(
    inner: VestingWallet<S, P, C>,
    ctx: &mut TxContext,
): GrantAdminCap {
    let grant = PausableGrant { id: object::new(ctx), inner, paused: false };
    let cap = GrantAdminCap { id: object::new(ctx), grant_id: object::id(&grant) };
    transfer::share_object(grant);
    cap
}

/// Immutable view onto the nested wallet - the only access a curve module needs to
/// mint a `VestedAmount` against it. Safe to hand out: no funds move without `&mut`,
/// which never escapes this module.
public fun inner<S: drop, P: copy + drop + store, C>(
    self: &PausableGrant<S, P, C>,
): &VestingWallet<S, P, C> {
    &self.inner
}

/// Release the vested-but-unreleased portion to the beneficiary, unless paused. Takes
/// only `&VestedAmount` (no witness), so any curve module's attestation works.
/// Permissionless when not paused - the beneficiary is fixed in the wallet.
///
/// #### Aborts
/// - `EPaused` if the grant is currently paused.
/// - `EWalletMismatch` if `vested` was not minted for this wallet.
/// - `EVestedBelowReleased` if `vested.amount` is below the amount already released.
/// - `EInsufficientBalance` if the balance cannot cover the releasable amount, i.e.
///   the curve attested more than `balance + released`.
public fun release<S: drop, P: copy + drop + store, C>(
    self: &mut PausableGrant<S, P, C>,
    vested: &VestedAmount<S>,
) {
    assert!(!self.paused, EPaused);
    self.inner.release(vested);
}

/// Freeze releases. Idempotent.
///
/// #### Aborts
/// - `EWrongGrant` if `cap` controls a different grant.
public fun pause<S: drop, P: copy + drop + store, C>(
    self: &mut PausableGrant<S, P, C>,
    cap: &GrantAdminCap,
) {
    assert!(cap.grant_id == object::id(self), EWrongGrant);
    self.paused = true;
}

/// Resume releases. Idempotent.
///
/// #### Aborts
/// - `EWrongGrant` if `cap` controls a different grant.
public fun resume<S: drop, P: copy + drop + store, C>(
    self: &mut PausableGrant<S, P, C>,
    cap: &GrantAdminCap,
) {
    assert!(cap.grant_id == object::id(self), EWrongGrant);
    self.paused = false;
}

/// Dissolve the grant: consume the grant and its admin cap and return the nested
/// wallet to the caller. This is the curve-agnostic half of teardown - the wrapper
/// holds no witness `S`, so it cannot consume a `DestroyReceipt` itself; it stops at
/// handing back the bare wallet. The caller finishes teardown through the curve
/// module: `vesting_wallet::destroy_empty(wallet, root)` for the receipt, then the curve's
/// witness-gated `destroy` to consume it (which can impose its own gates, e.g. that
/// the schedule has ended).
///
/// Cap-gated like `pause`/`resume`: only the employer can dissolve the grant. The
/// returned wallet still only ever pays its fixed `beneficiary`, so unwrapping confers
/// no power to redirect funds - it just lifts the pause wrapper off.
///
/// #### Aborts
/// - `EWrongGrant` if `cap` controls a different grant.
public fun unwrap<S: drop, P: copy + drop + store, C>(
    self: PausableGrant<S, P, C>,
    cap: GrantAdminCap,
): VestingWallet<S, P, C> {
    assert!(cap.grant_id == object::id(&self), EWrongGrant);
    let PausableGrant { id, inner, .. } = self;
    let GrantAdminCap { id: cap_id, .. } = cap;
    id.delete();
    cap_id.delete();
    inner
}

// === View helpers ===

/// Whether releases are currently frozen.
public fun is_paused<S: drop, P: copy + drop + store, C>(self: &PausableGrant<S, P, C>): bool {
    self.paused
}
