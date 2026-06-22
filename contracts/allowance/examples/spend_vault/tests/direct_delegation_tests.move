module openzeppelin_allowance::direct_delegation_tests;

use openzeppelin_allowance::direct_delegation;
use openzeppelin_allowance::example_coin::{Self, EXAMPLE_COIN};
use openzeppelin_allowance::spend_vault::{Self, Vault};
use std::type_name;
use std::unit_test::{assert_eq, destroy};
use sui::clock::{Self, Clock};
use sui::coin::Coin;
use sui::event;
use sui::test_scenario as ts;

const OWNER: address = @0xACE;
const DELEGATE: address = @0xB0B;

const DAY_MS: u64 = 86_400_000;
const NOW_MS: u64 = 1_000 * DAY_MS; // arbitrary test "now"
const NO_EXPIRY: u64 = 18_446_744_073_709_551_615; // u64::MAX sentinel

// Happy path: the owner opens a funded, budgeted allowance for a known delegate, the
// delegate spends, the owner raises then suspends then revokes the grant, and the
// owner drains the pool and tears the vault down.
//
// Funding: the example coin's `init_for_testing` mints the fixed supply to the
// publisher; the owner deposits a slice of it through `open_allowance`.
//
// Teardown uses the root-free `withdraw<T>` + `destroy` rather than the
// `drain_one_coin` / `tear_down` wrappers: `withdraw_all<T>` reads the accumulator,
// which the unit-test VM cannot construct.
#[test]
fun direct_delegation_full_lifecycle() {
    let mut scenario = ts::begin(OWNER);

    // Tx 1 (OWNER): mint the example coin supply to the owner.
    example_coin::init_for_testing(scenario.ctx());

    // Tx 2 (OWNER): open a funded, budgeted allowance for the delegate. The wrapper
    // creates the vault, deposits the funding, mints a cap, and grants a budget, then
    // returns `(vault, cap, owner_cap)` for the caller to wire: share the vault,
    // transfer the cap to the delegate, and keep the OwnerCap. A clock is created +
    // shared so the later txs can reach it as a shared input.
    scenario.next_tx(OWNER);
    let (cap_id, owner_cap) = {
        let mut funding = scenario.take_from_sender<Coin<EXAMPLE_COIN>>();
        let mut clk = clock::create_for_testing(scenario.ctx());
        clk.set_for_testing(NOW_MS);

        // Fund the allowance with 1_000 units; keep the rest in the owner's wallet.
        let stake = funding.split(1_000, scenario.ctx());
        let (vault, cap, owner_cap) = direct_delegation::open_allowance<EXAMPLE_COIN>(
            stake,
            400,
            NOW_MS + 30 * DAY_MS,
            &clk,
            scenario.ctx(),
        );
        let cap_id = object::id(&cap);

        // Compose the edges in this tx: share the vault, hand the cap to the delegate.
        spend_vault::share(vault);
        transfer::public_transfer(cap, DELEGATE);

        transfer::public_transfer(funding, OWNER);
        clk.share_for_testing();

        scenario.next_tx(OWNER);
        (cap_id, owner_cap)
    };

    // Tx 3 (DELEGATE): spend 150 to the delegate's wallet through the cap.
    scenario.next_tx(DELEGATE);
    {
        let mut vault = scenario.take_shared<Vault>();
        let clk = scenario.take_shared<Clock>();
        let cap = scenario.take_from_sender<spend_vault::SpenderCap>();

        let coin = direct_delegation::spend_to_wallet<EXAMPLE_COIN>(
            &mut vault,
            &cap,
            150,
            &clk,
            scenario.ctx(),
        );
        assert_eq!(vault.allowance<EXAMPLE_COIN>(cap_id), 250);
        destroy(coin);

        scenario.return_to_sender(cap);
        ts::return_shared(vault);
        ts::return_shared(clk);
    };

    // Tx 4 (OWNER): raise the budget (CAS idiom), then suspend, then revoke the coin.
    scenario.next_tx(OWNER);
    {
        let mut vault = scenario.take_shared<Vault>();
        let clk = scenario.take_shared<Clock>();

        direct_delegation::change_budget<EXAMPLE_COIN>(
            &mut vault,
            &owner_cap,
            cap_id,
            500,
            NOW_MS + 60 * DAY_MS,
            &clk,
            scenario.ctx(),
        );
        assert_eq!(vault.allowance<EXAMPLE_COIN>(cap_id), 500);

        direct_delegation::suspend<EXAMPLE_COIN>(
            &mut vault,
            &owner_cap,
            cap_id,
            &clk,
            scenario.ctx(),
        );
        assert_eq!(vault.allowance<EXAMPLE_COIN>(cap_id), 0);
        assert!(vault.contains<EXAMPLE_COIN>(cap_id)); // suspended, entry still present

        let was_present = direct_delegation::revoke_one_coin<EXAMPLE_COIN>(
            &mut vault,
            &owner_cap,
            cap_id,
            scenario.ctx(),
        );
        assert!(was_present);
        assert!(!vault.contains<EXAMPLE_COIN>(cap_id)); // entry gone

        ts::return_shared(vault);
        ts::return_shared(clk);
    };

    // Tx 5 (OWNER): drain the remaining pool and tear the vault down. Pool after the
    // single 150 spend: 1_000 - 150 = 850. The root-free partial `withdraw<T>` drains
    // it, then `destroy` removes the (now empty) ledger and the UIDs.
    scenario.next_tx(OWNER);
    {
        let mut vault = scenario.take_shared<Vault>();

        let bal = vault.withdraw<EXAMPLE_COIN>(&owner_cap, 850, scenario.ctx());
        assert_eq!(bal.value(), 850);
        destroy(bal);

        vault.destroy(owner_cap, scenario.ctx());
    };

    scenario.end();
}

// An over-budget spend aborts `EAllowanceExceeded`: the delegate's 400-unit grant
// cannot draw 500.
#[test, expected_failure(abort_code = spend_vault::EAllowanceExceeded)]
fun spend_over_budget_aborts() {
    let mut scenario = ts::begin(OWNER);

    example_coin::init_for_testing(scenario.ctx());

    scenario.next_tx(OWNER);
    {
        let funding = scenario.take_from_sender<Coin<EXAMPLE_COIN>>();
        let mut clk = clock::create_for_testing(scenario.ctx());
        clk.set_for_testing(NOW_MS);

        let (vault, cap, owner_cap) = direct_delegation::open_allowance<EXAMPLE_COIN>(
            funding, // fund with the whole supply: the pool is not the limit here
            400,
            NO_EXPIRY,
            &clk,
            scenario.ctx(),
        );
        spend_vault::share(vault);
        transfer::public_transfer(cap, DELEGATE);
        transfer::public_transfer(owner_cap, OWNER);
        clk.share_for_testing();
    };

    // Tx (DELEGATE): try to draw 500 against a 400 budget. Aborts before any funds move.
    scenario.next_tx(DELEGATE);
    {
        let mut vault = scenario.take_shared<Vault>();
        let clk = scenario.take_shared<Clock>();
        let cap = scenario.take_from_sender<spend_vault::SpenderCap>();

        // Aborts inside `spend_to_wallet` before any Coin is produced; the binding
        // exists only so the over-budget abort path type-checks.
        let coin = direct_delegation::spend_to_wallet<EXAMPLE_COIN>(
            &mut vault,
            &cap,
            500,
            &clk,
            scenario.ctx(),
        );
        destroy(coin);

        scenario.return_to_sender(cap);
        ts::return_shared(vault);
        ts::return_shared(clk);
    };

    abort
}

// Integrator confirmation pattern: when an owner UPDATES a grant they believe
// already exists, they should confirm `AllowanceSet.was_created == false`.
//
// `set_allowance` keys the budget on a bare `cap_id: ID` that the library never
// validates against a live cap. If the owner passes a `cap_id` that matches NO
// existing (cap, T) grant - the classic cause is a typo'd id - `set_allowance`
// does not abort: it silently CREATES a brand-new budget and emits
// `AllowanceSet { was_created: true }`. The intended grant is left untouched and
// a budget is now provisioned against an id that may belong to no cap at all.
//
// The defense is to read `was_created` (or call `contains<T>` first): on a known
// update it MUST be `false`. A surprise `true` is the silent-create signal -
// stop and re-check the id before trusting the write. This test pins both edges:
// a fresh create reports `true`, and a same-(cap, T) overwrite reports `false`.
#[test]
fun was_created_confirms_intended_cap() {
    let mut scenario = ts::begin(OWNER);

    // Tx 1 (OWNER): mint the example coin supply, then build a vault + one cap.
    example_coin::init_for_testing(scenario.ctx());

    scenario.next_tx(OWNER);
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(NOW_MS);

    let (mut vault, owner_cap) = spend_vault::new(scenario.ctx());
    let vault_id = object::id(&vault);
    let cap = vault.mint_cap(&owner_cap, scenario.ctx());
    let cap_id = object::id(&cap);

    // Tx A: CREATE the (cap, EXAMPLE_COIN) grant. No CAS guard on a fresh create,
    // so `expected` is `option::none()`. The emitted event must report
    // `was_created == true`: this id matched no prior grant, a budget was minted.
    vault.set_allowance<EXAMPLE_COIN>(
        &owner_cap,
        cap_id,
        400,
        NO_EXPIRY,
        option::none(),
        &clk,
        scenario.ctx(),
    );
    let create_evs = event::events_by_type<spend_vault::AllowanceSet>();
    assert_eq!(create_evs.length(), 1);
    assert_eq!(
        create_evs[0],
        spend_vault::test_new_allowance_set(
            vault_id,
            cap_id,
            type_name::with_defining_ids<EXAMPLE_COIN>(),
            400,
            NO_EXPIRY,
            false, // cas_was_provided: none() passed
            true, // was_created: this is the create branch
            OWNER,
        ),
    );

    // Tx B: UPDATE the SAME (cap, EXAMPLE_COIN) grant to a new budget. Because the
    // id and coin type match the existing entry, `set_allowance` overwrites in
    // place and the event reports `was_created == false` - the confirmation an
    // integrator looks for before trusting an owner-side update.
    scenario.next_tx(OWNER);
    vault.set_allowance<EXAMPLE_COIN>(
        &owner_cap,
        cap_id,
        600,
        NO_EXPIRY,
        option::none(),
        &clk,
        scenario.ctx(),
    );
    let update_evs = event::events_by_type<spend_vault::AllowanceSet>();
    assert_eq!(update_evs.length(), 1); // only Tx B's event lives in this tx
    assert_eq!(
        update_evs[0],
        spend_vault::test_new_allowance_set(
            vault_id,
            cap_id,
            type_name::with_defining_ids<EXAMPLE_COIN>(),
            600,
            NO_EXPIRY,
            false,
            false, // was_created: the overwrite branch - the intended grant existed
            OWNER,
        ),
    );

    // Teardown: no funds were deposited, so the pool is empty and `destroy` needs
    // no prior drain. Dispose the cap and clock, then tear the vault down.
    destroy(cap);
    clk.destroy_for_testing();
    vault.destroy(owner_cap, scenario.ctx());

    scenario.end();
}
