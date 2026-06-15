/// A curve-agnostic vesting wallet primitive for a single coin type.
///
/// # The primitive
///
/// `VestingWallet<C, C>` locks a `Balance<C>` for a single `beneficiary` and
/// tracks how much has been paid out (`released`). The type `C` is the
/// *schedule*: a struct, owned by the module that declares it, that both
/// identifies the curve and stores its parameters. The wallet itself never
/// interprets the schedule — it only enforces release accounting and
/// conservation of funds. A curve module mints a `VestedAmount<C>` for the
/// current clock, and `release` pays out the not-yet-released portion.
///
/// This module ships no curve of its own. The built-in linear-with-cliff
/// schedule lives in the sibling `linear_vesting` module — the reference
/// curve, and the template downstream schedule modules copy. An integrator who
/// just wants linear vesting touches only `linear_vesting` and never
/// constructs a bare wallet or mints a `VestedAmount` by hand.
///
/// # Why the schedule is a type parameter
///
/// A `VestingWallet` is meaningless without a curve, so the curve cannot be an
/// afterthought attached later — it is baked into the wallet's type at
/// construction. Struct fields are module-private in Move, so only the module
/// that declares a schedule struct `C` can construct a `C` value, and therefore
/// only that module can:
///
/// * build a `VestingWallet<C, C>` (via `new`, which takes the schedule by
///   value — the value itself is the authority proof), and
/// * mint a `VestedAmount<C>` (via `mint_vested`).
///
/// This makes "a wallet without parameters" and "a wallet with the wrong
/// parameters" unrepresentable: the type system, not a runtime check, enforces
/// that every `VestingWallet<C, C>` carries exactly the `C` its curve needs.
///
/// # Custom schedules
///
/// Downstream packages ship their own curve in their own module by following
/// the `linear_vesting` pattern:
///
/// 1. Declare `public struct MyCurve has store, drop { /* params */ }`
///    (`store` so it lives in the wallet, `drop` so it can be used as a mint
///    witness).
/// 2. A constructor that validates params and calls
///    `vesting_wallet::new(MyCurve { .. }, beneficiary, start_ms, duration_ms, ctx)`.
/// 3. A `vested(&VestingWallet<MyCurve, C>, &Clock): VestedAmount<MyCurve>` that
///    ends in `vesting_wallet::mint_vested(MyCurve { .. }, amount)`.
/// 4. A teardown that calls `vesting_wallet::destroy_empty`, which returns the
///    schedule for the curve module to destructure.
///
/// The curve must be monotonically non-decreasing in time and bounded above by
/// `balance + released`; violating either makes `release` abort before any
/// state mutation (funds stay safe, but the release path is bricked until the
/// curve is fixed).
///
/// # Topologies
///
/// `VestingWallet<C, C>` has `key + store`, so the consumer picks the topology
/// after the constructor returns:
/// * **Shared** (recommended): `transfer::public_share_object(wallet)` — anyone
///   can poke `release`. `linear_vesting` exposes `create_and_share` sugar.
/// * **Owned** (fast path): `transfer::public_transfer(wallet, addr)` — only the
///   holder can pass the wallet by `&mut`, so funding and release are reachable
///   from the holder's transactions only. Outside parties fund it by
///   `public_transfer`ing a `Coin<C>` to the wallet's object address; the holder
///   then claims each with `receive_and_deposit`.
///
/// The `beneficiary` is fixed at construction (mirroring OpenZeppelin's
/// `VestingWallet`). To rotate the recipient, point `beneficiary` at a
/// consumer-owned object and rotate ownership of that object instead.
module openzeppelin_finance::vesting_wallet;

use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::transfer::Receiving;

// === Errors ===

const ENotEmpty: u64 = 0;
const EScheduleParamsMismatch: u64 = 1;

// === Types ===

/// The vesting wallet. `start_ms` and `duration_ms` are fixed at construction;
/// only `balance` and `released` move over time. The `schedule` field holds the
/// curve `P` (identity + parameters). Curve modules read `balance + released` as
/// the wallet's "current total" when evaluating the schedule, so deposits made
/// after `start_ms` can participate retroactively (the reference linear curve
/// does this).
public struct VestingWallet<phantom S: drop, P: copy + drop + store, phantom C> has key, store {
    id: UID,
    beneficiary: address,
    released: u64,
    balance: Balance<C>,
    schedule_params: P,
}

/// A vested-amount witness produced by curve `P`. Hot potato: no abilities, so
/// it must be created and consumed in the same PTB. Only the module that
/// declares `P` can mint one (via `mint_vested`).
public struct VestedAmount<phantom S> {
    amount: u64,
}

// === Events ===

public struct Created<phantom S, P, phantom C> has copy, drop {
    wallet_id: ID,
    beneficiary: address,
    schedule_params: P,
}

public struct Deposited<phantom S, phantom C> has copy, drop {
    wallet_id: ID,
    amount: u64,
}

public struct Released<phantom S, phantom C> has copy, drop {
    wallet_id: ID,
    beneficiary: address,
    amount: u64,
}

public struct Destroyed<phantom S, phantom C> has copy, drop {
    wallet_id: ID,
    beneficiary: address,
    total_released: u64,
}

// === Primitive ===

/// Build a new wallet around a schedule and return it by value. Returning by
/// value (rather than sharing internally) lets the caller chain creation,
/// funding, and topology selection in a single PTB. The `schedule` is taken by
/// value: since only the declaring module can construct a `C`, supplying one is
/// the authority proof that the caller is that curve module.
public fun new<S: drop, P: copy + drop + store, C>(
    schedule_params: P,
    beneficiary: address,
    ctx: &mut TxContext,
): VestingWallet<S, P, C> {
    let wallet = VestingWallet<S, P, C> {
        id: object::new(ctx),
        beneficiary,
        released: 0,
        balance: balance::zero<C>(),
        schedule_params,
    };

    event::emit(Created<S, P, C> {
        wallet_id: object::id(&wallet),
        beneficiary,
        schedule_params,
    });

    wallet
}

/// Mint a `VestedAmount<P>`. Witness-gated: callers must supply a value of type
/// `P`, and only the module that declares `P` can construct one. The amount is
/// unforgeable in any other module.
public fun mint_vested<S: drop, P: copy + drop + store, C>(
    wallet: &VestingWallet<S, P, C>,
    _w: S,
    params: P,
    amount: u64,
): VestedAmount<S> {
    // TODO: move this to appropriate docs/README place.
    // Protects against potential exploit:
    // 1. Beneficiary creates a new wallet through the same schedule, but with modified parameters
    // 2. Beneficiary mints `VestedAmount` using the new schedule, i.e. not the one stored in the wallet
    // 3. Beneficiary releases more funds than the wallet would allow under the intended schedule
    assert!(wallet.schedule_params == params, EScheduleParamsMismatch);
    VestedAmount { amount }
}

/// Read the cumulative vested total recorded in a `VestedAmount<P>` without
/// consuming it.
public fun amount<S>(vested: &VestedAmount<S>): u64 {
    vested.amount
}

/// Add a coin to the wallet's balance. Permissionless — the beneficiary's
/// identity is data, not a capability, and anyone may fund.
public fun deposit<S: drop, P: copy + drop + store, C>(
    wallet: &mut VestingWallet<S, P, C>,
    coin: Coin<C>,
) {
    let amount = coin.value();
    wallet.balance.join(coin.into_balance());
    event::emit(Deposited<P, C> { wallet_id: object::id(wallet), amount });
}

/// Claim a coin that an upstream emitter `public_transfer`'d to this wallet's
/// object address, then funnel it through the standard deposit path. Used by
/// emission schedules and payroll robots that don't hold a wallet reference.
public fun receive_and_deposit<S: drop, P: copy + drop + store, C>(
    wallet: &mut VestingWallet<S, P, C>,
    receiving: Receiving<Coin<C>>,
) {
    let coin = transfer::public_receive(&mut wallet.id, receiving);
    deposit(wallet, coin);
}

/// Consume a curve-supplied `VestedAmount<P>` and send the not-yet-released
/// portion to the beneficiary. Permissionless: anyone holding wallet and
/// vested-amount references can poke this. The recipient is always read fresh
/// from `wallet.beneficiary` at call time.
///
/// If the curve says nothing new is vested (already drained at this clock), the
/// call still consumes the hot potato but emits no event and transfers no coin.
public fun release<S: drop, P: copy + drop + store, C>(
    wallet: &mut VestingWallet<S, P, C>,
    vested: VestedAmount<S>,
    ctx: &mut TxContext,
) {
    let VestedAmount { amount: vested_total } = vested;
    let releasable = vested_total - wallet.released;
    if (releasable == 0) return;

    wallet.released = wallet.released + releasable;
    let coin = coin::from_balance(wallet.balance.split(releasable), ctx);
    let beneficiary = wallet.beneficiary;
    transfer::public_transfer(coin, beneficiary);

    event::emit(Released<P, C> {
        wallet_id: object::id(wallet),
        beneficiary,
        amount: releasable,
    });
}

/// Consume a fully-drained, fully-ended wallet to reclaim storage rebate and
/// return its schedule to the caller (the curve module destructures it).
/// Permissionless. Coins `public_transfer`'d to a destroyed wallet's address
/// after this call have no path back — pair destruction with halting any
/// upstream emissions that target this wallet.
public fun destroy_empty<S: drop, P: copy + drop + store, C>(wallet: VestingWallet<S, P, C>): P {
    assert!(wallet.balance.value() == 0, ENotEmpty);

    let wallet_id = object::id(&wallet);
    let beneficiary = wallet.beneficiary;
    let total_released = wallet.released;

    let VestingWallet {
        id,
        beneficiary: _,
        released: _,
        balance,
        schedule_params,
    } = wallet;
    balance.destroy_zero();
    id.delete();

    event::emit(Destroyed<P, C> { wallet_id, beneficiary, total_released });

    schedule_params
}

// === Views and accessors ===

/// What `release` would pay out if the supplied `VestedAmount<P>` were consumed
/// now: `vested.amount - wallet.released`. Takes the witness by reference so the
/// caller can still consume it in a subsequent `release`.
public fun available<S: drop, P: copy + drop + store, C>(
    wallet: &VestingWallet<S, P, C>,
    vested: &VestedAmount<P>,
): u64 {
    vested.amount - wallet.released
}

/// Read the wallet's schedule (curve identity + parameters). Ungated: curve
/// parameters are public information.
public fun schedule_params<S: drop, P: copy + drop + store, C>(wallet: &VestingWallet<S, P, C>): P {
    wallet.schedule_params
}

public fun beneficiary<S: drop, P: copy + drop + store, C>(
    wallet: &VestingWallet<S, P, C>,
): address {
    wallet.beneficiary
}

public fun released<S: drop, P: copy + drop + store, C>(wallet: &VestingWallet<S, P, C>): u64 {
    wallet.released
}

public fun balance<S: drop, P: copy + drop + store, C>(wallet: &VestingWallet<S, P, C>): u64 {
    wallet.balance.value()
}
