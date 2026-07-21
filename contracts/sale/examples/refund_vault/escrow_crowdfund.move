/// An all-or-nothing crowdfunding campaign built directly on `refund_vault`,
/// with no `prefunded_sale` in sight. A worked example of using the vault as
/// the standalone refundable-escrow primitive it is: backers pledge funds
/// toward a goal by a deadline, and the campaign either succeeds (the whole
/// pot goes to the beneficiary) or fails (every backer reclaims exactly what
/// they pledged).
///
/// ### The vault is a dumb escrow; the campaign owns the ledger
///
/// A `RefundVault<P>` holds a single `locked: Balance<P>` and a lifecycle
/// state. It knows nothing about *who* deposited *how much* - it only tracks
/// the pooled total. That per-depositor accounting is the integrator's job, and
/// this example is mostly that job: the `Campaign` keeps a `pledges` table
/// (`backer -> cumulative amount`) alongside the vault, so on failure it can
/// release each backer's exact pledge back to them. The vault moves the money;
/// the campaign remembers whose it is.
///
/// ### The campaign owns the cap
///
/// `open` creates the vault, captures its `RefundVaultCap<P>` inside the
/// `Campaign` object, and shares both in the same call. Consequences:
///
/// - The cap lives in the shared campaign forever, so it can never be lost or
///   sent to the wrong address - the "hold caps in a recoverable container"
///   footgun is designed out rather than documented around.
/// - Sharing the vault in `open` (not in a separate step an integrator could
///   forget) is what keeps the permissionless `refund` path from being bricked
///   - the same reasoning `prefunded_sale::share_and_activate` uses for taking
///   the vault by value.
/// - Every fund movement is gated by campaign policy (goal, deadline,
///   beneficiary) rather than by whoever holds a cap. `finalize` is
///   permissionless but can only ever pay the pre-committed `beneficiary`.
///
/// ### Funds move as balances, into address balances
///
/// The campaign never mints a `Coin<P>`. Pledges arrive as `Balance<P>` and
/// escrow straight into the vault; payouts leave via `balance::send_funds`,
/// which credits the recipient's [address balance](https://docs.sui.io/onchain-finance/asset-custody/address-balances/using-address-balances)
/// rather than transferring a coin object. So `finalize` settles the pot into
/// the beneficiary's address balance and `refund` settles each backer's pledge
/// into theirs - no coin objects, no receipts to hand back.
///
/// ### Lifecycle
///
/// ```text
///   open ──▶  Active (vault accepts pledges within [.., deadline_ms])
///              │
///          pledge ×N
///              │
///              ├──▶ finalize   (permissionless, after deadline, goal met)
///              │       vault Active ─▶ Closed; whole pot ─▶ beneficiary's balance
///              │
///              └──▶ cancel     (permissionless, after deadline, goal missed)
///                      vault Active ─▶ Refunding
///                      refund ×N   (each backer's pledge ─▶ their balance)
///```
///
/// Success and failure are mutually exclusive and fully determined by
/// `(now > deadline, total pledged, goal)`: after the deadline, `finalize`
/// requires the goal met and `cancel` requires it missed, so exactly one of the
/// two applies. Before any settlement the vault stays `Active`; because
/// `finalize`/`cancel` are permissionless, funds never wait on anyone's
/// liveness.
///
/// ### Solvency
///
/// The pledge ledger and the vault stay in lockstep: every `pledge` escrows
/// `amount` in the vault and adds the same `amount` to `pledges[backer]`, so
/// `sum(pledges) == vault.value()` right up to settlement. On failure each
/// `refund` releases exactly `pledges[backer]` and drops that entry, so the sum
/// invariant is preserved and no backer can be shorted or refunded twice.
///
/// ### Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate how
/// the `refund_vault` primitive can be used standalone. It is not
/// production-ready and must not be deployed as-is.
module openzeppelin_sale::example_escrow_crowdfund;

use openzeppelin_sale::refund_vault::{Self, RefundVault, RefundVaultCap};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::event;
use sui::table::{Self, Table};

// === Errors ===

/// `open` was given `goal == 0`; an all-or-nothing campaign needs a positive
/// target, or it would trivially succeed with no pledges.
#[error(code = 0)]
const EZeroGoal: vector<u8> = "The funding goal must be greater than zero";

/// `open` was given a `deadline_ms` that is not in the future.
#[error(code = 1)]
const EDeadlineInPast: vector<u8> = "The deadline must be in the future";

/// A campaign operation was given a vault other than the one paired with the
/// campaign at `open`.
#[error(code = 2)]
const EWrongVault: vector<u8> = "The provided vault is not the one paired with this campaign";

/// A `pledge` was attempted after the deadline had passed.
#[error(code = 3)]
const ECampaignClosed: vector<u8> = "The campaign is no longer accepting pledges";

/// A `pledge` was made with a zero-value payment.
#[error(code = 4)]
const EZeroPledge: vector<u8> = "The pledge must be greater than zero";

/// A settlement (`finalize` / `cancel`) was attempted before the deadline.
#[error(code = 5)]
const EBeforeDeadline: vector<u8> = "The campaign cannot be settled before its deadline";

/// `finalize` was called on a campaign that did not reach its goal.
#[error(code = 6)]
const EGoalNotMet: vector<u8> = "The campaign cannot be finalized: the goal was not reached";

/// `cancel` was called on a campaign that reached its goal; it must be finalized.
#[error(code = 7)]
const EGoalMet: vector<u8> = "The campaign cannot be cancelled: it reached its goal";

/// A `refund` was requested by an address with no outstanding pledge (it never
/// pledged, or already refunded).
#[error(code = 8)]
const ENoPledge: vector<u8> = "There is no pledge to refund for this address";

// === Structs ===

/// An all-or-nothing crowdfunding campaign over `Balance<P>`. Owns the paired
/// refund vault's controller cap and a per-backer pledge ledger. Created and
/// shared by `open`; never transferred or destroyed.
public struct Campaign<phantom P> has key {
    id: UID,
    /// Id of the paired refund vault holding the pooled pledges.
    vault_id: ID,
    /// Controller cap for the paired vault, wrapped so it never leaves the campaign.
    vault_cap: RefundVaultCap<P>,
    /// Address whose balance receives the entire pot if the campaign succeeds.
    beneficiary: address,
    /// Minimum total pledged for the campaign to succeed.
    goal: u64,
    /// Pledging closes at this timestamp (ms); settlement opens after it.
    deadline_ms: u64,
    /// Cumulative amount pledged per backer, so refunds pay each back exactly.
    pledges: Table<address, u64>,
}

// === Events ===

/// Emitted by `open` when a campaign is created.
public struct CampaignOpened<phantom P> has copy, drop {
    campaign_id: ID,
    vault_id: ID,
    beneficiary: address,
    goal: u64,
    deadline_ms: u64,
}

/// Emitted by `pledge` for each successful pledge.
public struct Pledged<phantom P> has copy, drop {
    campaign_id: ID,
    backer: address,
    /// Amount added by this pledge.
    amount: u64,
    /// Total pooled in the vault after this pledge.
    total_pledged: u64,
}

/// Emitted by `finalize` when a campaign succeeds and the pot is paid out.
public struct CampaignFinalized<phantom P> has copy, drop {
    campaign_id: ID,
    /// Total credited to the beneficiary's balance.
    raised: u64,
    beneficiary: address,
}

/// Emitted by `cancel` when a campaign fails and enters refunding.
public struct CampaignCancelled<phantom P> has copy, drop {
    campaign_id: ID,
    /// Total pooled at cancellation, now reclaimable by backers.
    raised: u64,
}

/// Emitted by `refund` when a backer reclaims their pledge.
public struct Refunded<phantom P> has copy, drop {
    campaign_id: ID,
    backer: address,
    amount: u64,
}

// === Public Functions ===

/// Open a campaign: create its refund vault, capture the vault's controller cap
/// inside the campaign, and share both. Returns the new campaign's id.
///
/// The vault is created and shared here (rather than by the caller) so it is
/// always public and always empty at start, and so the permissionless `refund`
/// path can never be bricked by a forgotten sharing step.
///
/// #### Parameters
/// - `beneficiary`: Address whose balance receives the pot if the campaign succeeds.
/// - `goal`: Minimum total pledged for the campaign to succeed; must be positive.
/// - `deadline_ms`: Timestamp (ms) after which pledging closes and settlement opens.
/// - `clock`: Sui `Clock`, read for the current timestamp.
/// - `ctx`: Transaction context, used to allocate the campaign, vault, and cap `UID`s.
///
/// #### Returns
/// - The id of the shared `Campaign<P>`.
///
/// #### Aborts
/// - `EZeroGoal` if `goal == 0`.
/// - `EDeadlineInPast` if `deadline_ms <= now`.
public fun open<P>(
    beneficiary: address,
    goal: u64,
    deadline_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    assert!(goal > 0, EZeroGoal);
    assert!(deadline_ms > clock.timestamp_ms(), EDeadlineInPast);

    let (vault, vault_cap) = refund_vault::new<P>(ctx);
    let vault_id = object::id(&vault);

    let campaign = Campaign<P> {
        id: object::new(ctx),
        vault_id,
        vault_cap,
        beneficiary,
        goal,
        deadline_ms,
        pledges: table::new<address, u64>(ctx),
    };
    let campaign_id = object::id(&campaign);

    event::emit(CampaignOpened<P> { campaign_id, vault_id, beneficiary, goal, deadline_ms });

    transfer::share_object(campaign);
    vault.share();

    campaign_id
}

/// Pledge `payment` toward the campaign. The funds escrow in the vault and are
/// credited to `ctx.sender()`'s cumulative pledge; a backer may pledge multiple
/// times and the amounts accumulate. Delivers no receipt - the campaign's
/// ledger is the record of who pledged what.
///
/// #### Parameters
/// - `campaign`: The shared campaign, still open.
/// - `vault`: The campaign's paired refund vault.
/// - `payment`: The backer's pledge, escrowed in full.
/// - `clock`: Sui `Clock`, read for the current timestamp.
/// - `ctx`: Transaction context.
///
/// #### Aborts
/// - `EWrongVault` if `vault` is not the one paired with this campaign.
/// - `ECampaignClosed` if `now > deadline_ms`.
/// - `EZeroPledge` if `payment` has zero value.
/// - `refund_vault::ENotActiveState` / `refund_vault::EWrongVaultCap` propagated
///   from the vault deposit (guarded by the campaign's invariants - the vault is
///   `Active` until the deadline and the cap always matches - so unreachable in
///   normal operation).
public fun pledge<P>(
    campaign: &mut Campaign<P>,
    vault: &mut RefundVault<P>,
    payment: Balance<P>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(object::id(vault) == campaign.vault_id, EWrongVault);
    assert!(clock.timestamp_ms() <= campaign.deadline_ms, ECampaignClosed);
    let amount = payment.value();
    assert!(amount > 0, EZeroPledge);

    let backer = ctx.sender();
    vault.deposit(&campaign.vault_cap, payment);

    if (campaign.pledges.contains(backer)) {
        let pledged = campaign.pledges.borrow_mut(backer);
        *pledged = *pledged + amount;
    } else {
        campaign.pledges.add(backer, amount);
    };

    event::emit(Pledged<P> {
        campaign_id: object::id(campaign),
        backer,
        amount,
        total_pledged: vault.value(),
    });
}

/// Settle a successful campaign. **Permissionless.** Closes the vault and
/// credits the entire pot to the campaign's committed `beneficiary` via
/// `balance::send_funds`.
///
/// Allowed once the deadline has passed with the goal met (`now > deadline_ms`
/// and pooled pledges `>= goal`).
///
/// #### Parameters
/// - `campaign`: The shared campaign, past its deadline with the goal met.
/// - `vault`: The campaign's paired refund vault.
/// - `clock`: Sui `Clock`, read for the current timestamp.
///
/// #### Aborts
/// - `EWrongVault` if `vault` is not the one paired with this campaign.
/// - `EBeforeDeadline` if `now <= deadline_ms`.
/// - `EGoalNotMet` if the pooled pledges are below `goal`.
/// - `refund_vault::ENotActiveState` / `refund_vault::ENotClosedState` /
///   `refund_vault::EWrongVaultCap` propagated from closing and draining the
///   vault (guarded by the campaign's invariants, so unreachable in normal
///   operation).
public fun finalize<P>(campaign: &mut Campaign<P>, vault: &mut RefundVault<P>, clock: &Clock) {
    assert!(object::id(vault) == campaign.vault_id, EWrongVault);
    assert!(clock.timestamp_ms() > campaign.deadline_ms, EBeforeDeadline);
    assert!(vault.value() >= campaign.goal, EGoalNotMet);

    vault.flip_to_closed(&campaign.vault_cap);
    let pot = vault.withdraw_all(&campaign.vault_cap);
    let beneficiary = campaign.beneficiary;

    event::emit(CampaignFinalized<P> {
        campaign_id: object::id(campaign),
        raised: pot.value(),
        beneficiary,
    });

    // Settlement is permissionless, so the pot goes to the campaign's committed
    // beneficiary, never the caller - credited to their address balance.
    balance::send_funds(pot, beneficiary);
}

/// Settle a failed campaign. **Permissionless.** Flips the vault to refunding;
/// backers then reclaim their pledges individually via `refund`.
///
/// Allowed once the deadline has passed with the goal missed (`now >
/// deadline_ms` and pooled pledges `< goal`).
///
/// #### Parameters
/// - `campaign`: The shared campaign, past its deadline with the goal missed.
/// - `vault`: The campaign's paired refund vault.
/// - `clock`: Sui `Clock`, read for the current timestamp.
///
/// #### Aborts
/// - `EWrongVault` if `vault` is not the one paired with this campaign.
/// - `EBeforeDeadline` if `now <= deadline_ms`.
/// - `EGoalMet` if the pooled pledges reached `goal`.
/// - `refund_vault::ENotActiveState` / `refund_vault::EWrongVaultCap` propagated
///   from flipping the vault to refunding (guarded by the campaign's invariants,
///   so unreachable in normal operation).
public fun cancel<P>(campaign: &mut Campaign<P>, vault: &mut RefundVault<P>, clock: &Clock) {
    assert!(object::id(vault) == campaign.vault_id, EWrongVault);
    assert!(clock.timestamp_ms() > campaign.deadline_ms, EBeforeDeadline);
    assert!(vault.value() < campaign.goal, EGoalMet);

    vault.flip_to_refunding(&campaign.vault_cap);

    event::emit(CampaignCancelled<P> {
        campaign_id: object::id(campaign),
        raised: vault.value(),
    });
}

/// Reclaim the caller's pledge from a cancelled campaign. Credits the full
/// cumulative pledge `ctx.sender()` made to their address balance via
/// `balance::send_funds`, and clears their ledger entry so the refund cannot be
/// taken twice.
///
/// #### Parameters
/// - `campaign`: The shared, cancelled campaign.
/// - `vault`: The campaign's paired refund vault, in the refunding state.
/// - `ctx`: Transaction context.
///
/// #### Aborts
/// - `EWrongVault` if `vault` is not the one paired with this campaign.
/// - `ENoPledge` if the caller has no outstanding pledge (never pledged, or
///   already refunded).
/// - `refund_vault::ENotRefundingState` if the campaign has not been cancelled
///   (the vault is not yet refunding).
/// - `refund_vault::EWrongVaultCap` / `refund_vault::EInsufficientLocked`
///   propagated from the vault release (guarded by the campaign's invariants -
///   the cap always matches and the ledger never exceeds the pooled balance - so
///   unreachable in normal operation).
public fun refund<P>(campaign: &mut Campaign<P>, vault: &mut RefundVault<P>, ctx: &mut TxContext) {
    assert!(object::id(vault) == campaign.vault_id, EWrongVault);
    let backer = ctx.sender();
    assert!(campaign.pledges.contains(backer), ENoPledge);

    let amount = campaign.pledges.remove(backer);
    let funds = vault.release_balance(&campaign.vault_cap, amount);

    event::emit(Refunded<P> { campaign_id: object::id(campaign), backer, amount });

    // The backer reclaims their own pledge, credited to their address balance.
    balance::send_funds(funds, backer);
}

// === View helpers ===

/// The address whose balance is paid the pot if the campaign succeeds.
public fun beneficiary<P>(campaign: &Campaign<P>): address { campaign.beneficiary }

/// The funding goal.
public fun goal<P>(campaign: &Campaign<P>): u64 { campaign.goal }

/// The pledging deadline (ms).
public fun deadline_ms<P>(campaign: &Campaign<P>): u64 { campaign.deadline_ms }

/// The id of the paired refund vault.
public fun vault_id<P>(campaign: &Campaign<P>): ID { campaign.vault_id }

/// The cumulative amount `backer` has pledged; `0` if they never pledged or
/// have already refunded.
///
/// #### Parameters
/// - `campaign`: The campaign to query.
/// - `backer`: The address to look up.
///
/// #### Returns
/// - The backer's outstanding pledge, or `0`.
public fun pledge_of<P>(campaign: &Campaign<P>, backer: address): u64 {
    if (campaign.pledges.contains(backer)) *campaign.pledges.borrow(backer) else 0
}

// === Test-Only Helpers ===
//
// Event struct fields are module-private, so tests in other modules cannot build
// an expected event to compare against `event::events_by_type`. These mirror the
// `test_new_*` seam used by `refund_vault` and `openzeppelin_finance::vesting_wallet`,
// and let tests attest `send_funds` payouts (address-balance credits are not
// readable in the unit-test VM).

/// Build a `CampaignFinalized` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_campaign_finalized<P>(
    campaign_id: ID,
    raised: u64,
    beneficiary: address,
): CampaignFinalized<P> {
    CampaignFinalized { campaign_id, raised, beneficiary }
}

/// Build a `Refunded` event value for asserting against `event::events_by_type`.
#[test_only]
public fun test_new_refunded<P>(campaign_id: ID, backer: address, amount: u64): Refunded<P> {
    Refunded { campaign_id, backer, amount }
}
