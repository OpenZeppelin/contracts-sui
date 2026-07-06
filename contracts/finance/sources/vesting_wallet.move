/// A curve-agnostic vesting wallet primitive for a single coin type.
///
/// # The primitive
///
/// `VestingWallet<S, P, C>` locks a `Balance<C>` for a single `beneficiary` and
/// tracks how much has already been paid out (`released`). It is parameterized by
/// three types, all chosen at construction:
///
/// - `S` - the *schedule witness*: a `drop`-only struct declared by a curve
///   module. It carries no data; it exists so that only its declaring module can
///   mint a `VestedAmount<S>` or tear the wallet down.
/// - `P` - the *schedule parameters*: a `copy + drop + store` struct declared by
///   the same curve module and held in the wallet's `schedule_params` field. It
///   stores the curve's configuration (start, duration, cliff, ...).
/// - `C` - the *coin type* being vested.
///
/// The wallet itself never interprets the schedule - it only enforces release
/// accounting and conservation of funds. A curve module evaluates its curve for
/// the current clock, mints a `VestedAmount<S>`, and `release` pays out the
/// not-yet-released portion.
///
/// This module ships no curve of its own. The built-in linear-with-cliff schedule
/// lives in the sibling `vesting_wallet_linear` module - the reference curve, and the
/// template downstream schedule modules copy. An integrator who just wants linear
/// vesting touches only `vesting_wallet_linear` and never constructs a bare wallet or
/// mints a `VestedAmount` by hand.
///
/// # Why the schedule is split across type parameters
///
/// A `VestingWallet` is meaningless without a curve, so the curve cannot be an
/// afterthought attached later - it is baked into the wallet's type at
/// construction. Struct fields are module-private in Move, so only the module that
/// declares the schedule structs `S` and `P` can construct values of those types,
/// and therefore only that module can:
///
/// - build a `VestingWallet<S, P, C>` (via `new`, which takes the parameters `P`
///   by value - the value itself is the authority proof), and
/// - mint a `VestedAmount<S>` (via `mint_vested_amount`) or finalize a teardown by
///   consuming the `DestroyReceipt<S, P>` that `destroy_empty` returns (via
///   `consume_receipt`) - both take the witness `S` by value.
///
/// This makes "a wallet without parameters" and "a wallet with the wrong
/// parameters" unrepresentable: the type system, not a runtime check, enforces
/// that every `VestingWallet<S, P, C>` carries exactly the `P` its curve needs and
/// can only be advanced by the curve module that owns `S`.
///
/// # Teardown authority
///
/// `new` mints a `DestroyCap` alongside the wallet, bound to it by id. Finalizing a
/// teardown (`consume_receipt`) requires that cap, so teardown authority is an object
/// the creator can hold, transfer, or wrap - deliberately decoupled from the wallet's
/// `beneficiary`. This matters because `beneficiary` can be an object address, which is
/// never a transaction sender: a `ctx.sender() == beneficiary` gate could never be
/// satisfied for such a wallet, while a cap can. The cap lives in the core primitive
/// (not in any one curve), so every curve - including downstream ones copied from the
/// reference - inherits the same beneficiary-agnostic teardown authority.
///
/// # Custom schedules
///
/// Downstream packages ship their own curve in their own module by following the
/// `vesting_wallet_linear` pattern:
///
/// 1. Declare a witness `public struct MyCurve has drop {}` and a parameters
///    struct `public struct MyParams has copy, drop, store { /* params */ }`.
/// 2. A public `params` constructor that validates and returns a `MyParams`, with
///    `new` as sugar over
///    `vesting_wallet::new<MyCurve, MyParams, C>(params(..), beneficiary, ctx)`.
///    Exposing `params` separately lets a curve-agnostic protocol build the wallet
///    itself (calling `vesting_wallet::new` directly) without routing through `new`.
/// 3. A `vested(&VestingWallet<MyCurve, MyParams, C>, &Clock): VestedAmount<MyCurve>`
///    that ends in `vesting_wallet::mint_vested_amount(wallet, MyCurve {}, amount)`.
/// 4. A teardown that calls `vesting_wallet::destroy_empty(wallet)` to get a
///    `DestroyReceipt<MyCurve, MyParams>`, then
///    `vesting_wallet::consume_receipt(receipt, cap, MyCurve {})` - passing the wallet's
///    `DestroyCap` - to recover the schedule parameters for the curve module to
///    destructure. Gate teardown on the cap, never on `ctx.sender() == beneficiary`: an
///    object beneficiary is never a sender, so that check could never be satisfied.
///
/// The curve must be monotonically non-decreasing in time and bounded above by
/// `balance + released`; violating either makes `release` abort before any state
/// mutation (funds stay safe, but the release path is bricked until the curve is
/// fixed).
///
/// # Topologies
///
/// `VestingWallet<S, P, C>` has `key + store`, so the consumer picks the topology
/// after the constructor returns:
///
/// - **Shared** (recommended): `transfer::public_share_object(wallet)` - anyone
///   can poke `release`. `vesting_wallet_linear` exposes `create_and_share` sugar.
/// - **Owned** (fast path): `transfer::public_transfer(wallet, addr)` - only the
///   holder can pass the wallet by `&mut`, so funding and release are reachable
///   from the holder's transactions only. Outside parties fund it by
///   `public_transfer`ing a `Coin<C>` to the wallet's object address; the holder
///   then claims each with `receive_and_deposit`.
///
/// The `beneficiary` is fixed at construction. To rotate the recipient, point
/// `beneficiary` at a consumer-owned object and rotate ownership of that object
/// instead.
module openzeppelin_finance::vesting_wallet;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::transfer::Receiving;

// === Errors ===

/// `destroy_empty` was called on a wallet that still holds a balance.
#[error(code = 0)]
const ENotEmpty: vector<u8> = "Wallet still holds a balance";

/// A `VestedAmount` was used against a different wallet than the one it was minted
/// for.
#[error(code = 1)]
const EWalletMismatch: vector<u8> = "VestedAmount does not match this wallet";

/// A `VestedAmount` attests a cumulative total below what the wallet has already
/// released - a stale attestation or a curve that regressed.
#[error(code = 2)]
const EVestedBelowReleased: vector<u8> = "Vested amount is below the amount already released";

/// A `deposit` would push the wallet's lifetime total (`balance + released`) past
/// `u64::MAX`, which the wallet's `u64` accounting cannot represent.
#[error(code = 3)]
const EBalanceOverflow: vector<u8> = "Deposit would overflow the wallet's lifetime total";

/// A `release` attests more than the wallet's funded total (`balance + released`),
/// so the current balance cannot cover the releasable amount.
#[error(code = 4)]
const EInsufficientBalance: vector<u8> = "Releasable amount exceeds the wallet's balance";

/// The `DestroyCap` passed to `consume_receipt` was minted for a different wallet than
/// the one being torn down.
#[error(code = 5)]
const EWrongCap: vector<u8> = "DestroyCap does not match this wallet";

// === Structs ===

/// The vesting wallet. `schedule_params` and `beneficiary` are fixed at
/// construction; only `balance` and `released` change over time. Curve modules
/// read `balance + released` as the wallet's "current total" when evaluating the
/// schedule, so deposits made after the schedule starts can participate
/// retroactively (the reference linear curve does this).
public struct VestingWallet<phantom S: drop, P: copy + drop + store, phantom C> has key, store {
    id: UID,
    /// Recipient of every `release`, read fresh from this field at call time.
    beneficiary: address,
    /// Cumulative amount paid out so far. Monotonically non-decreasing.
    released: u64,
    /// Funds held by the wallet that have not yet been released.
    balance: Balance<C>,
    /// The curve's stored configuration. Opaque to the wallet; only the declaring
    /// curve module interprets it.
    schedule_params: P,
}

/// A transient attestation that curve `S` has vested a cumulative `amount` for a
/// specific wallet. It has only `drop` - no `copy`, `store`, or `key` - so it
/// cannot be duplicated, stored, or held across transactions: it lives only within
/// the PTB that mints it. It is *not* a hot potato; `release` and `releasable` take
/// it by reference, so it is simply dropped at the end of the transaction.
///
/// Only the module that declares the witness `S` can mint one (via
/// `mint_vested_amount`), so the `amount` is unforgeable in any other module. The
/// `wallet_id` stamp binds the attestation to the wallet it was minted against;
/// `release` and `releasable` reject it against any other wallet.
///
/// `drop` (rather than abilityless forced consumption) is safe: it cannot be used
/// to over-release. `release` pays out `amount - released`, reading the wallet's
/// `released` *fresh* on each call and writing it back, so re-using or dropping the
/// same attestation across multiple `release` calls pays nothing after the first.
/// Combined with the `wallet_id` binding (a favorable attestation minted against a
/// side wallet is rejected here), there is no double-spend to forbid - so requiring
/// the caller to explicitly consume the attestation would buy no extra safety.
///
/// # Why minting and spending are separated
///
/// `VestedAmount` deliberately splits two authorities, and that split is what lets
/// a third party wrap a `VestingWallet` without breaking encapsulation:
///
/// - *Attestation* ("this much is vested") needs the witness `S`, so only the
///   curve module can produce it (`mint_vested_amount` takes `&VestingWallet` plus
///   an `S`).
/// - *Execution* ("move the funds") needs only `&VestedAmount<S>` and `&mut wallet`
///   - not `S` - so `release` can be called by code that has no access to `S`.
///
/// A curve-agnostic wrapper that nests the wallet (`inner: VestingWallet<..>`) only
/// needs to expose an immutable `&inner` (so any curve module can mint an
/// attestation) and keep `&mut inner` private. It re-exposes `release` as its own
/// function that takes `&VestedAmount<S>`, enforces its own invariants, then
/// delegates to `inner.release(..)`. The caller flow stays curve-agnostic:
///
/// ```move
/// let v = some_curve::vested_amount(wrapper.inner(), clock);
/// wrapper.release(&v, ctx);
/// ```
///
/// Handing out `&inner` is safe: it only allows views and curve-gated minting of an
/// inert attestation; no funds move without `&mut`, which the wrapper never
/// exposes. If `release` instead required `S`, this would be impossible - a
/// curve-agnostic wrapper cannot construct `S`, so it would have to expose
/// `&mut inner` and lose all control over deposits and releases.
public struct VestedAmount<phantom S> has drop {
    /// Id of the wallet this attestation was minted for.
    wallet_id: ID,
    /// Cumulative vested total at mint time - not the incremental releasable amount.
    amount: u64,
}

/// Carries a destroyed wallet's id and schedule params back to its curve. A HOT POTATO
/// that only `consume_receipt` (witness-gated, and gated on the matching `DestroyCap`)
/// can consume it. This is what drags the curve into the PTB to finalize, and lets it
/// veto by aborting. The `wallet_id` is carried so the cap can be matched against the
/// now-destroyed wallet at consume time.
public struct DestroyReceipt<phantom S, P> {
    wallet_id: ID,
    /// The curve's stored configuration. Opaque to the wallet; only the declaring
    /// curve module interprets it.
    params: P,
}

/// Authority to finalize the teardown of one specific wallet. Minted by `new` alongside
/// the wallet and bound to it by `wallet_id`; consumed by `consume_receipt`, which
/// rejects any cap whose `wallet_id` does not match the wallet being torn down.
///
/// Teardown authority travels with the cap, not with the wallet's `beneficiary`.
/// This is what makes teardown reachable for a wallet whose beneficiary is an object
/// address (which can never be a `ctx.sender()`); see the module's "Teardown authority"
/// note. The cap carries no `drop`, so it cannot be silently discarded - it is retired
/// only by tearing the wallet down.
public struct DestroyCap has key, store {
    id: UID,
    /// Id of the wallet this cap authorizes the teardown of.
    wallet_id: ID,
}

// === Events ===

/// Emitted by `new` when a wallet is created.
public struct Created<phantom S, P, phantom C> has copy, drop {
    wallet_id: ID,
    beneficiary: address,
    schedule_params: P,
}

/// Emitted by `deposit` (and `receive_and_deposit`) when a non-zero amount is
/// added. A deposit of a zero-value coin emits no event.
public struct Deposited<phantom S, phantom C> has copy, drop {
    wallet_id: ID,
    /// Amount added to the balance by this deposit.
    amount: u64,
}

/// Emitted by `release` when a non-zero amount is paid to the beneficiary. A
/// release that pays out nothing emits no event.
public struct Released<phantom S, phantom C> has copy, drop {
    wallet_id: ID,
    beneficiary: address,
    /// Amount paid to the beneficiary by this release (the incremental portion,
    /// not the cumulative `released` total).
    amount: u64,
}

/// Emitted by `destroy_empty` when a drained wallet is torn down.
public struct Destroyed<phantom S, phantom C> has copy, drop {
    wallet_id: ID,
    beneficiary: address,
    /// Total amount released over the wallet's lifetime.
    total_released: u64,
}

// === Public Functions ===

/// Build a new wallet around a schedule and return it by value, together with the
/// `DestroyCap` that authorizes its eventual teardown. Returning by value (rather than
/// sharing internally) lets the caller chain creation, funding, and topology selection
/// in a single PTB; the cap is a separate owned object the caller routes wherever
/// teardown authority should live (see the module's "Teardown authority" note).
///
/// The type parameters are:
/// - `S` - the curve's `drop`-only schedule witness
/// - `P` - the curve's `copy + drop + store` parameters struct
/// - `C` - the coin type being vested
///
/// See the module overview for the full rationale.
///
/// #### Parameters
/// - `schedule_params`: The curve's stored configuration, opaque to the wallet.
/// - `beneficiary`: Address that every `release` pays out to.
/// - `ctx`: Transaction context, used to allocate the wallet's `UID`.
///
/// #### Returns
/// - A fresh `VestingWallet<S, P, C>` with a zero balance and nothing released,
///   owned by the caller (pick a topology before the PTB ends).
/// - A `DestroyCap` bound to that wallet by id, required later by `consume_receipt`.
public fun new<S: drop, P: copy + drop + store, C>(
    schedule_params: P,
    beneficiary: address,
    ctx: &mut TxContext,
): (VestingWallet<S, P, C>, DestroyCap) {
    let wallet = VestingWallet<S, P, C> {
        id: object::new(ctx),
        beneficiary,
        released: 0,
        balance: balance::zero<C>(),
        schedule_params,
    };
    let wallet_id = object::id(&wallet);

    event::emit(Created<S, P, C> {
        wallet_id,
        beneficiary,
        schedule_params,
    });

    (wallet, DestroyCap { id: object::new(ctx), wallet_id })
}

/// Mint a `VestedAmount<S>` recording `amount` as the cumulative vested total for
/// `wallet`. Witness-gated: callers must supply a value of type `S`, and only the
/// module that declares `S` can construct one, so the `amount` is unforgeable in
/// any other module.
///
/// This indirection is what lets a `VestingWallet` be driven curve-agnostically -
/// through another protocol, or gated behind another contract - without curve
/// modules needing to know about every wrapper. See `VestedAmount` for the full
/// rationale.
///
/// #### Parameters
/// - `wallet`: The wallet the attestation is bound to (by id).
/// - `_w`: The curve witness `S`; proves the caller is the declaring curve module.
/// - `amount`: The cumulative vested total this attestation asserts. Trusted, not
///   validated here - see the note below.
///
/// #### Returns
/// - A `VestedAmount<S>` stamped with this wallet's id.
public fun mint_vested_amount<S: drop, P: copy + drop + store, C>(
    wallet: &VestingWallet<S, P, C>,
    _w: S,
    amount: u64,
): VestedAmount<S> {
    // `amount` is supplied by the caller and is NOT validated here. The primitive
    // only stamps it with this wallet's id, binding the witness to the wallet it was
    // minted against - `release`/`releasable` reject it against any other wallet. That
    // stamp defeats the cross-wallet attack (mint a favorable amount from a side wallet
    // built with modified params, then redeem it against the target): the side wallet's
    // id won't match the target.
    //
    // What the stamp CANNOT check is whether `amount` is honest for *this* wallet. The
    // curve module is responsible for that: `amount` must be a monotonically
    // non-decreasing, `balance + released`-bounded function of this wallet's
    // `schedule_params`. The wallet trusts the witness `S` and never re-derives the
    // curve; a curve module that mints a dishonest amount against its own wallet would
    // over-release (bounded only by the wallet's balance). Curve modules MUST uphold
    // this invariant.
    VestedAmount { wallet_id: object::id(wallet), amount }
}

/// Add a coin to the wallet's balance. Permissionless - the beneficiary's
/// identity is data, not a capability, and anyone may fund.
///
/// A deposit of a zero-value coin is a no-op: the (empty) balance is consumed but
/// nothing changes and no `Deposited` event is emitted.
///
/// #### Aborts
/// - `EBalanceOverflow` if the deposit would push the wallet's lifetime total
///   `balance + released` (== `Σ(deposits)`) past `u64::MAX`, which would
///   indefinitely brick the release path.
public fun deposit<S: drop, P: copy + drop + store, C>(
    wallet: &mut VestingWallet<S, P, C>,
    coin: Coin<C>,
) {
    let amount = coin.value();

    assert!(
        std::u64::max_value!() - wallet.balance.value() - wallet.released >= amount,
        EBalanceOverflow,
    );

    wallet.balance.join(coin.into_balance());
    if (amount == 0) return;
    event::emit(Deposited<S, C> { wallet_id: object::id(wallet), amount });
}

/// Claim a coin that an upstream emitter `public_transfer`'d to this wallet's
/// object address, then funnel it through the standard deposit path. Used by
/// emission schedules and payroll robots that don't hold a wallet reference.
///
/// #### Aborts
/// - `EBalanceOverflow` if claiming the coin would overflow the wallet's
///   lifetime total. Unlike a direct `deposit`, the coin was already transferred to
///   the wallet's address by an earlier transaction, so an abort here leaves it
///   parked at that address with no claim path - it is stranded (the same class as
///   a coin sent after `destroy_empty`). High-volume emitters should track the
///   wallet's `balance + released` headroom before transferring.
public fun receive_and_deposit<S: drop, P: copy + drop + store, C>(
    wallet: &mut VestingWallet<S, P, C>,
    receiving: Receiving<Coin<C>>,
) {
    let coin = transfer::public_receive(&mut wallet.id, receiving);
    wallet.deposit(coin);
}

/// Pay the not-yet-released portion attested by `vested` to the beneficiary.
/// Permissionless: anyone holding references to the wallet and a `VestedAmount` can
/// poke this. The recipient is always read fresh from `wallet.beneficiary` at call
/// time. `vested` is borrowed, not consumed, so the same attestation can still be
/// passed to a later call in the PTB.
///
/// If nothing new is vested since the last release (the wallet is already drained
/// at this clock), the call is a no-op: no coin is transferred and no event is
/// emitted.
///
/// #### Parameters
/// - `wallet`: The wallet to release from.
/// - `vested`: A `VestedAmount<S>` minted for this wallet by its curve module.
/// - `ctx`: Transaction context, used to mint the payout coin.
///
/// #### Aborts
/// - `EWalletMismatch` if `vested` was not minted for this wallet.
/// - `EVestedBelowReleased` if `vested.amount` is below the amount already released.
/// - `EInsufficientBalance` if the balance cannot cover the releasable amount, i.e.
///   the curve attested more than `balance + released`.
public fun release<S: drop, P: copy + drop + store, C>(
    wallet: &mut VestingWallet<S, P, C>,
    vested: &VestedAmount<S>,
    ctx: &mut TxContext,
) {
    let VestedAmount { wallet_id, amount: vested_amount } = vested;
    assert!(wallet_id == object::id(wallet), EWalletMismatch);
    assert!(*vested_amount >= wallet.released, EVestedBelowReleased);

    let releasable = *vested_amount - wallet.released;
    if (releasable == 0) return;
    assert!(releasable <= wallet.balance.value(), EInsufficientBalance);

    wallet.released = wallet.released + releasable;
    let coin = coin::from_balance(wallet.balance.split(releasable), ctx);
    let beneficiary = wallet.beneficiary;
    transfer::public_transfer(coin, beneficiary);

    event::emit(Released<S, C> {
        wallet_id: object::id(wallet),
        beneficiary,
        amount: releasable,
    });
}

/// Consume a drained wallet to reclaim its storage rebate, emit `Destroyed`, and return
/// a `DestroyReceipt<S, P>` carrying the destroyed wallet's id and schedule parameters.
///
/// This call is permissionless - it takes no witness and no cap - so a curve-agnostic
/// holder of the wallet can drain its rebate without access to `S`. The receipt is a hot
/// potato that only `consume_receipt` can unwrap, and that call requires both the
/// declaring curve's witness `S` and the wallet's `DestroyCap`; so the curve is still
/// dragged into the teardown PTB (and can veto by aborting), and the teardown only
/// finalizes for the cap holder. A `destroy_empty` whose matching `consume_receipt`
/// never runs - because the caller lacks the cap or the curve vetoes - reverts with the
/// whole PTB, since the receipt cannot otherwise be retired. This is the same authority
/// split as `VestedAmount`: one half stays callable without the witness, the other half
/// is gated.
///
/// Coins `public_transfer`'d to a destroyed wallet's address after this call have no
/// path back - pair destruction with halting any upstream emissions that target this
/// wallet.
///
/// #### Parameters
/// - `wallet`: The wallet to destroy. Must hold a zero balance.
///
/// #### Returns
/// - A `DestroyReceipt<S, P>` carrying the wallet's schedule parameters, to be passed to
///   `consume_receipt`.
///
/// #### Aborts
/// - `ENotEmpty` if the wallet still holds a balance.
public fun destroy_empty<S: drop, P: copy + drop + store, C>(
    wallet: VestingWallet<S, P, C>,
): DestroyReceipt<S, P> {
    assert!(wallet.balance.value() == 0, ENotEmpty);

    let wallet_id = object::id(&wallet);
    let beneficiary = wallet.beneficiary;
    let total_released = wallet.released;

    let VestingWallet { id, balance, schedule_params, .. } = wallet;
    balance.destroy_zero();
    id.delete();

    event::emit(Destroyed<S, C> { wallet_id, beneficiary, total_released });

    DestroyReceipt { wallet_id, params: schedule_params }
}

/// Unwrap a `DestroyReceipt<S, P>` to recover the destroyed wallet's schedule
/// parameters, consuming the wallet's `DestroyCap` in the process. Gated two ways:
///
/// - **Witness `_w: S`** - only the declaring curve can call this, so it (and only it)
///   sees the real `P`, runs any teardown logic, and can abort (reverting the whole
///   teardown, since the wallet was destroyed in the same PTB) if destruction should not
///   be accepted.
/// - **`cap: DestroyCap`** - must be the cap `new` minted for this exact wallet. This is
///   the teardown authority, deliberately decoupled from `beneficiary` so a wallet whose
///   beneficiary is an object address can still be torn down. The cap is retired here.
///
/// #### Parameters
/// - `receipt`: The `DestroyReceipt<S, P>` returned by `destroy_empty`.
/// - `cap`: The `DestroyCap` `new` minted for this wallet. Consumed by the call.
/// - `_w`: The curve witness `S`.
///
/// #### Returns
/// - The destroyed wallet's schedule parameters `P`, for the curve module to use and
///   destructure.
///
/// #### Aborts
/// - `EWrongCap` if `cap` was minted for a different wallet than this receipt's.
public fun consume_receipt<S: drop, P: copy + drop + store>(
    receipt: DestroyReceipt<S, P>,
    cap: DestroyCap,
    _w: S,
): P {
    let DestroyReceipt { wallet_id, params } = receipt;
    let DestroyCap { id, wallet_id: cap_wallet_id } = cap;
    assert!(cap_wallet_id == wallet_id, EWrongCap);
    id.delete();
    params
}

// === View helpers ===

/// What `release` would pay out for the supplied `VestedAmount<S>` right now:
/// `vested.amount - wallet.released`. Borrows `vested`, so the same attestation can
/// still be passed to a subsequent `release`.
///
/// #### Parameters
/// - `wallet`: The wallet to query.
/// - `vested`: A `VestedAmount<S>` minted for this wallet by its curve module.
///
/// #### Returns
/// - The releasable amount: the attested cumulative total minus what has already
///   been released.
///
/// #### Aborts
/// - `EWalletMismatch` if `vested` was not minted for this wallet.
/// - `EVestedBelowReleased` if `vested.amount` is below the amount already released.
public fun releasable<S: drop, P: copy + drop + store, C>(
    wallet: &VestingWallet<S, P, C>,
    vested: &VestedAmount<S>,
): u64 {
    let VestedAmount { wallet_id, amount: vested_amount } = vested;
    assert!(wallet_id == object::id(wallet), EWalletMismatch);
    assert!(*vested_amount >= wallet.released, EVestedBelowReleased);
    *vested_amount - wallet.released
}

/// Read the cumulative vested total recorded in a `VestedAmount<S>` without
/// consuming it.
///
/// #### Parameters
/// - `vested`: The `VestedAmount<S>` to read.
///
/// #### Returns
/// - The cumulative vested total recorded in `vested`.
public fun amount<S>(vested: &VestedAmount<S>): u64 {
    vested.amount
}

/// Read the wallet's schedule parameters. Ungated - curve parameters are public
/// information.
///
/// #### Parameters
/// - `wallet`: The wallet to query.
///
/// #### Returns
/// - The wallet's stored schedule parameters.
public fun schedule_params<S: drop, P: copy + drop + store, C>(wallet: &VestingWallet<S, P, C>): P {
    wallet.schedule_params
}

/// Address that receives every `release`.
///
/// #### Parameters
/// - `wallet`: The wallet to query.
///
/// #### Returns
/// - The address that receives every `release`.
public fun beneficiary<S: drop, P: copy + drop + store, C>(
    wallet: &VestingWallet<S, P, C>,
): address {
    wallet.beneficiary
}

/// Cumulative amount released so far.
///
/// #### Parameters
/// - `wallet`: The wallet to query.
///
/// #### Returns
/// - The cumulative amount released so far.
public fun released<S: drop, P: copy + drop + store, C>(wallet: &VestingWallet<S, P, C>): u64 {
    wallet.released
}

/// Funds currently held by the wallet and not yet released.
///
/// #### Parameters
/// - `wallet`: The wallet to query.
///
/// #### Returns
/// - The funds currently held by the wallet and not yet released.
public fun balance<S: drop, P: copy + drop + store, C>(wallet: &VestingWallet<S, P, C>): u64 {
    wallet.balance.value()
}

// === Test-Only Helpers ===

/// Build a `Created` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_created<S, P, C>(
    wallet_id: ID,
    beneficiary: address,
    schedule_params: P,
): Created<S, P, C> {
    Created { wallet_id, beneficiary, schedule_params }
}

/// Build a `Deposited` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_deposited<S, C>(wallet_id: ID, amount: u64): Deposited<S, C> {
    Deposited { wallet_id, amount }
}

/// Build a `Released` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_released<S, C>(
    wallet_id: ID,
    beneficiary: address,
    amount: u64,
): Released<S, C> {
    Released { wallet_id, beneficiary, amount }
}

/// Build a `Destroyed` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_destroyed<S, C>(
    wallet_id: ID,
    beneficiary: address,
    total_released: u64,
): Destroyed<S, C> {
    Destroyed { wallet_id, beneficiary, total_released }
}

/// Read a `DestroyReceipt`'s `params` for test assertions; the receipt is otherwise
/// opaque (a hot potato with private fields).
#[test_only]
public fun test_receipt_params<S, P: copy>(receipt: &DestroyReceipt<S, P>): P {
    receipt.params
}
