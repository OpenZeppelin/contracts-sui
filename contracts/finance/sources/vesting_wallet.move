/// A curve-agnostic vesting wallet primitive for a single coin type.
///
/// # The primitive
///
/// `VestingWallet<C, T>` locks a `Balance<T>` for a single `beneficiary` and
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
/// * build a `VestingWallet<C, T>` (via `new`, which takes the schedule by
///   value — the value itself is the authority proof), and
/// * mint a `VestedAmount<C>` (via `mint_vested`).
///
/// This makes "a wallet without parameters" and "a wallet with the wrong
/// parameters" unrepresentable: the type system, not a runtime check, enforces
/// that every `VestingWallet<C, T>` carries exactly the `C` its curve needs.
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
/// 3. A `vested(&VestingWallet<MyCurve, T>, &Clock): VestedAmount<MyCurve>` that
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
/// `VestingWallet<C, T>` has `key + store`, so the consumer picks the topology
/// after the constructor returns:
/// * **Shared** (recommended): `transfer::public_share_object(wallet)` — anyone
///   can poke `release`. `linear_vesting` exposes `create_and_share` sugar.
/// * **Owned** (fast path): `transfer::public_transfer(wallet, addr)` — only the
///   holder can pass the wallet by `&mut`, so funding and release are reachable
///   from the holder's transactions only. Outside parties fund it by
///   `public_transfer`ing a `Coin<T>` to the wallet's object address; the holder
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

const EZeroDuration: u64 = 0;
const ENotEnded: u64 = 1;
const ENotEmpty: u64 = 2;

// === Types ===

/// The vesting wallet. `start_ms` and `duration_ms` are fixed at construction;
/// only `balance` and `released` move over time. The `schedule` field holds the
/// curve `C` (identity + parameters). Curve modules read `balance + released` as
/// the wallet's "current total" when evaluating the schedule, so deposits made
/// after `start_ms` can participate retroactively (the reference linear curve
/// does this).
public struct VestingWallet<C: store, phantom T> has key, store {
    id: UID,
    beneficiary: address,
    start_ms: u64,
    duration_ms: u64,
    released: u64,
    balance: Balance<T>,
    schedule: C,
}

/// A vested-amount witness produced by curve `C`. Hot potato: no abilities, so
/// it must be created and consumed in the same PTB. Only the module that
/// declares `C` can mint one (via `mint_vested`).
public struct VestedAmount<phantom C> {
    amount: u64,
}

// === Events ===

public struct Created<phantom C, phantom T> has copy, drop {
    wallet_id: ID,
    beneficiary: address,
    start_ms: u64,
    duration_ms: u64,
}

public struct Deposited<phantom C, phantom T> has copy, drop {
    wallet_id: ID,
    amount: u64,
}

public struct Released<phantom C, phantom T> has copy, drop {
    wallet_id: ID,
    beneficiary: address,
    amount: u64,
}

public struct Destroyed<phantom C, phantom T> has copy, drop {
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
public fun new<C: store, T>(
    schedule: C,
    beneficiary: address,
    start_ms: u64,
    duration_ms: u64,
    ctx: &mut TxContext,
): VestingWallet<C, T> {
    assert!(duration_ms > 0, EZeroDuration);

    let wallet = VestingWallet<C, T> {
        id: object::new(ctx),
        beneficiary,
        start_ms,
        duration_ms,
        released: 0,
        balance: balance::zero<T>(),
        schedule,
    };

    event::emit(Created<C, T> {
        wallet_id: object::id(&wallet),
        beneficiary,
        start_ms,
        duration_ms,
    });

    wallet
}

/// Mint a `VestedAmount<C>`. Witness-gated: callers must supply a value of type
/// `C`, and only the module that declares `C` can construct one. The amount is
/// unforgeable in any other module.
public fun mint_vested<C: drop>(_w: C, amount: u64): VestedAmount<C> {
    // TODO: potential exploit:
    // 1. Beneficiary creates a new wallet through the same schedule, but with modified parameters
    // 2. Beneficiary mints `VestedAmount` using the new schedule, i.e. not the one stored in the wallet
    // 3. Beneficiary releases more funds than the wallet would allow under the intended schedule
    // Consider asserting w == wallet.schedule
    VestedAmount { amount }
}

/// Read the cumulative vested total recorded in a `VestedAmount<C>` without
/// consuming it.
public fun amount<C>(vested: &VestedAmount<C>): u64 {
    vested.amount
}

/// Add a coin to the wallet's balance. Permissionless — the beneficiary's
/// identity is data, not a capability, and anyone may fund.
public fun deposit<C: store, T>(wallet: &mut VestingWallet<C, T>, coin: Coin<T>) {
    let amount = coin.value();
    wallet.balance.join(coin.into_balance());
    event::emit(Deposited<C, T> { wallet_id: object::id(wallet), amount });
}

/// Claim a coin that an upstream emitter `public_transfer`'d to this wallet's
/// object address, then funnel it through the standard deposit path. Used by
/// emission schedules and payroll robots that don't hold a wallet reference.
public fun receive_and_deposit<C: store, T>(
    wallet: &mut VestingWallet<C, T>,
    receiving: Receiving<Coin<T>>,
) {
    let coin = transfer::public_receive(&mut wallet.id, receiving);
    deposit(wallet, coin);
}

/// Consume a curve-supplied `VestedAmount<C>` and send the not-yet-released
/// portion to the beneficiary. Permissionless: anyone holding wallet and
/// vested-amount references can poke this. The recipient is always read fresh
/// from `wallet.beneficiary` at call time.
///
/// If the curve says nothing new is vested (already drained at this clock), the
/// call still consumes the hot potato but emits no event and transfers no coin.
public fun release<C: store, T>(
    wallet: &mut VestingWallet<C, T>,
    vested: VestedAmount<C>,
    ctx: &mut TxContext,
) {
    let VestedAmount { amount: vested_total } = vested;
    let releasable = vested_total - wallet.released;
    if (releasable == 0) return;

    wallet.released = wallet.released + releasable;
    let coin = coin::from_balance(wallet.balance.split(releasable), ctx);
    let beneficiary = wallet.beneficiary;
    transfer::public_transfer(coin, beneficiary);

    event::emit(Released<C, T> {
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
public fun destroy_empty<C: store, T>(wallet: VestingWallet<C, T>, clock: &Clock): C {
    // TODO: consider removing this check, as it might only matter that the balance == 0
    assert!(clock.timestamp_ms() >= wallet.start_ms + wallet.duration_ms, ENotEnded);
    assert!(wallet.balance.value() == 0, ENotEmpty);

    let wallet_id = object::id(&wallet);
    let beneficiary = wallet.beneficiary;
    let total_released = wallet.released;

    let VestingWallet {
        id,
        beneficiary: _,
        start_ms: _,
        duration_ms: _,
        released: _,
        balance,
        schedule,
    } = wallet;
    balance.destroy_zero();
    id.delete();

    event::emit(Destroyed<C, T> { wallet_id, beneficiary, total_released });

    schedule
}

// === Views and accessors ===

/// What `release` would pay out if the supplied `VestedAmount<C>` were consumed
/// now: `vested.amount - wallet.released`. Takes the witness by reference so the
/// caller can still consume it in a subsequent `release`.
public fun available<C: store, T>(wallet: &VestingWallet<C, T>, vested: &VestedAmount<C>): u64 {
    vested.amount - wallet.released
}

/// Read the wallet's schedule (curve identity + parameters). Ungated: curve
/// parameters are public information.
public fun schedule<C: store, T>(wallet: &VestingWallet<C, T>): &C {
    &wallet.schedule
}

/// Mutably borrow the schedule. Witness-gated — only the curve module (which can
/// construct a `C`) may mutate its own parameters.
public fun schedule_mut<C: store + drop, T>(_w: C, wallet: &mut VestingWallet<C, T>): &mut C {
    &mut wallet.schedule
}

public fun beneficiary<C: store, T>(wallet: &VestingWallet<C, T>): address { wallet.beneficiary }

public fun start<C: store, T>(wallet: &VestingWallet<C, T>): u64 { wallet.start_ms }

public fun duration<C: store, T>(wallet: &VestingWallet<C, T>): u64 { wallet.duration_ms }

public fun end<C: store, T>(wallet: &VestingWallet<C, T>): u64 {
    wallet.start_ms + wallet.duration_ms
}

public fun released<C: store, T>(wallet: &VestingWallet<C, T>): u64 { wallet.released }

public fun balance<C: store, T>(wallet: &VestingWallet<C, T>): u64 { wallet.balance.value() }
