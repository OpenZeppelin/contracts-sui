/// A shared reward treasury governed entirely by `access_control` roles.
///
/// This is a worked example of the role-based access control pattern from
/// `access_control`'s docs: a protocol whose privileged actions are gated by typed
/// `Auth<Role>` witnesses rather than by a hand-rolled `assert!(sender == admin)`.
///
/// The protocol's One-Time Witness, `EXAMPLE_REWARD_TREASURY`, is the *root role* (the
/// super admin). Three additional roles live in this same module, which is what the
/// library's home-module rule requires:
///  - `DistributorRole` - may withdraw rewards from the treasury.
///  - `PauserRole`       - may freeze and resume withdrawals.
///  - `GuardianRole`     - administers `PauserRole` (see below).
///
/// `init` wires a small role hierarchy: the root admin keeps direct authority over
/// `DistributorRole`, but delegates management of `PauserRole` to `GuardianRole` via
/// `set_role_admin`. So a guardian - not only the root admin - can appoint and remove
/// pausers, which is the everyday reason `set_role_admin` exists.
///
/// # The `Auth<Role>` flow
///
/// A privileged action takes `&Auth<Role>` and performs *no* body checks: the witness
/// is unforgeable because the only registry that can mint `Auth<DistributorRole>` is the
/// unique one rooted at this module. A caller mints the witness and spends it in the same
/// PTB:
///
/// ```move
/// let auth = registry.new_auth<_, DistributorRole>(ctx); // aborts unless sender holds the role
/// let coin = treasury.withdraw(&auth, amount, ctx);
/// ```
///
/// The witness authorizes the *role*, not a specific treasury object - that is the point
/// of role-based control. Funding is deliberately permissionless (anyone can top up the
/// rewards pool); only the spend and pause paths are gated.
///
/// The tests also exercise the timelocked root-admin handoff (`begin`/`accept` transfer
/// and renounce), the integration story for rotating or retiring protocol governance.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `access_control` primitive can be integrated. It is not production-ready and must not
/// be deployed as-is.
module openzeppelin_access::example_reward_treasury;

use openzeppelin_access::access_control::{Self, AccessControl, Auth};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;

// === Errors ===

/// A withdrawal was attempted while the treasury was paused.
#[error(code = 0)]
const EPaused: vector<u8> = "Treasury is paused; withdrawals are frozen";

// === Constants ===

/// Timelock applied to root-admin transfer and renounce. Seven days in milliseconds.
const ADMIN_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Structs ===

/// One-Time Witness and root role of the protocol's `AccessControl` registry.
public struct EXAMPLE_REWARD_TREASURY has drop {}

/// May withdraw rewards from the treasury. Administered by the root role.
public struct DistributorRole {}

/// May pause and resume withdrawals. Administered by `GuardianRole`.
public struct PauserRole {}

/// Administers `PauserRole`: appoints and removes pausers without needing the root admin.
public struct GuardianRole {}

/// Shared rewards pool. Funding is permissionless; withdrawals are role-gated and can be
/// frozen by a pauser.
public struct RewardTreasury has key {
    id: UID,
    funds: Balance<SUI>,
    paused: bool,
}

// === Events ===

/// Emitted on every successful withdrawal, attributing it to the authorized distributor.
public struct RewardsWithdrawn has copy, drop {
    by: address,
    amount: u64,
}

// === Init ===

/// Stand up the protocol on first publish: create the registry rooted at this module's
/// OTW, seed the role hierarchy, and share both the registry and the treasury.
///
/// The publisher becomes the default admin (root role holder). It immediately grants
/// itself `GuardianRole` so there is a live guardian, then delegates `PauserRole`
/// administration to `GuardianRole`.
fun init(otw: EXAMPLE_REWARD_TREASURY, ctx: &mut TxContext) {
    let mut registry = access_control::new(otw, ADMIN_DELAY_MS, ctx);

    // The publisher (root admin) becomes the first guardian...
    registry.grant_role<_, GuardianRole>(ctx.sender(), ctx);
    // ...and from now on guardians, not only the root admin, manage pausers.
    registry.set_role_admin<_, PauserRole, GuardianRole>(ctx);

    transfer::share_object(RewardTreasury {
        id: object::new(ctx),
        funds: balance::zero(),
        paused: false,
    });
    transfer::public_share_object(registry);
}

// === Public Functions ===

/// Top up the rewards pool. Permissionless: anyone may fund the treasury, mirroring how
/// real reward pools accept contributions from many sources.
///
/// #### Parameters
/// - `self`: The treasury to fund.
/// - `payment`: Coins added to the pool.
public fun fund(self: &mut RewardTreasury, payment: Coin<SUI>) {
    self.funds.join(payment.into_balance());
}

/// Withdraw `amount` from the pool. Gated by `DistributorRole`: the caller must present an
/// `Auth<DistributorRole>` minted from this protocol's registry. Returns the coins for the
/// caller to route in the same PTB.
///
/// #### Parameters
/// - `self`: The treasury to draw from.
/// - `auth`: Proof of `DistributorRole` membership, minted via `access_control::new_auth`.
/// - `amount`: Units to withdraw.
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - A `Coin<SUI>` for `amount`, taken from the pool.
///
/// #### Aborts
/// - `EPaused` if withdrawals are currently frozen.
public fun withdraw(
    self: &mut RewardTreasury,
    auth: &Auth<DistributorRole>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<SUI> {
    assert!(!self.paused, EPaused);
    event::emit(RewardsWithdrawn { by: auth.auth_addr(), amount });
    coin::from_balance(self.funds.split(amount), ctx)
}

/// Freeze or resume withdrawals. Gated by `PauserRole`.
///
/// #### Parameters
/// - `self`: The treasury to toggle.
/// - `auth`: Proof of `PauserRole` membership.
/// - `paused`: New paused state.
public fun set_paused(self: &mut RewardTreasury, _: &Auth<PauserRole>, paused: bool) {
    self.paused = paused;
}

// === View helpers ===

/// Whether withdrawals are currently frozen.
public fun is_paused(self: &RewardTreasury): bool {
    self.paused
}

/// The rewards pool's current balance.
public fun available(self: &RewardTreasury): u64 {
    self.funds.value()
}

// === Test-Only Helpers ===

/// Run `init` under test, constructing the OTW manually (allowed in a `#[test_only]`
/// context) so a scenario can stand up the protocol.
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(EXAMPLE_REWARD_TREASURY {}, ctx)
}

/// Reconstruct a `RewardsWithdrawn` event for assertions.
#[test_only]
public fun test_new_rewards_withdrawn(by: address, amount: u64): RewardsWithdrawn {
    RewardsWithdrawn { by, amount }
}
