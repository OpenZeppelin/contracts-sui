module openzeppelin_allowance::defi_keeper_tests;

use openzeppelin_allowance::defi_keeper::{Self, Service};
use openzeppelin_allowance::example_coin::{Self, EXAMPLE_COIN};
use openzeppelin_allowance::spend_vault::{Self, Vault, OwnerCap, SpenderCap};
use std::type_name;
use std::unit_test::{assert_eq, destroy};
use sui::clock::{Self, Clock};
use sui::coin::Coin;
use sui::event;
use sui::test_scenario::{Self as ts, Scenario};

const USER: address = @0xACE; // owns the vault AND registers with the keeper
const OPERATOR: address = @0xCAFE; // runs the keeper service
const MALLORY: address = @0xBAD; // not the operator

const NOW_MS: u64 = 1_700_000_000_000;
const NO_EXPIRY: u64 = 18_446_744_073_709_551_615; // u64::MAX sentinel

// Shared setup over EXAMPLE_COIN: USER mints the coin supply and creates + funds a
// vault, keeping the OwnerCap; OPERATOR creates a service pinned to it; USER mints
// one cap, grants it an EXAMPLE_COIN budget, and hands it into custody. Returns the
// scenario, the vault's id, and the cap's id.
fun setup(): (Scenario, ID, ID) {
    let mut scenario = ts::begin(USER);

    // Tx 1 (USER): mint the example coin supply to the user.
    example_coin::init_for_testing(scenario.ctx());

    // Tx 2 (USER): create + fund + share the vault; keep the OwnerCap; share a clock.
    scenario.next_tx(USER);
    let vault_id = {
        let mut funding = scenario.take_from_sender<Coin<EXAMPLE_COIN>>();
        let mut clk = clock::create_for_testing(scenario.ctx());
        clk.set_for_testing(NOW_MS);

        let (vault, owner_cap) = spend_vault::new(scenario.ctx());
        let vault_id = object::id(&vault);
        vault.deposit(funding.split(1_000, scenario.ctx()), scenario.ctx());
        vault.share();
        transfer::public_transfer(owner_cap, USER);
        transfer::public_transfer(funding, USER);
        clk.share_for_testing();
        vault_id
    };

    // Tx 3 (OPERATOR): create the keeper service pinned to that vault.
    scenario.next_tx(OPERATOR);
    {
        defi_keeper::create(vault_id, scenario.ctx());
    };

    // Tx 4 (USER): mint a cap, grant an EXAMPLE_COIN budget, and hand it straight
    // into custody by value, so the cap never has to touch the user's wallet.
    scenario.next_tx(USER);
    let cap_id = {
        let mut vault = scenario.take_shared<Vault>();
        let mut service = scenario.take_shared<Service>();
        let clk = scenario.take_shared<Clock>();
        let owner_cap = scenario.take_from_sender<OwnerCap>();

        let cap = vault.mint_cap(&owner_cap, scenario.ctx());
        let cap_id = object::id(&cap);
        vault.set_allowance<EXAMPLE_COIN>(
            &owner_cap,
            cap_id,
            300,
            NO_EXPIRY,
            option::none(),
            &clk,
            scenario.ctx(),
        );
        service.register(cap, scenario.ctx());
        assert!(service.is_registered(USER));

        scenario.return_to_sender(owner_cap);
        ts::return_shared(vault);
        ts::return_shared(service);
        ts::return_shared(clk);
        cap_id
    };

    (scenario, vault_id, cap_id)
}

// Happy path: the operator draws funds through the user's custodied cap; the owner
// raises the budget mid-custody and the same embedded cap keeps working.
#[test]
fun keeper_executes_topup_and_cap_survives_owner_update() {
    let (mut scenario, vault_id, cap_id) = setup();

    // Tx 5 (OPERATOR): draw 100 through the custodied cap and route it to the user.
    scenario.next_tx(OPERATOR);
    {
        let mut vault = scenario.take_shared<Vault>();
        let mut service = scenario.take_shared<Service>();
        let clk = scenario.take_shared<Clock>();

        let funds = service.execute_topup<EXAMPLE_COIN>(
            &mut vault,
            USER,
            100,
            &clk,
            scenario.ctx(),
        );
        assert_eq!(funds.value(), 100);
        transfer::public_transfer(funds.into_coin(scenario.ctx()), USER);
        assert_eq!(vault.allowance<EXAMPLE_COIN>(cap_id), 200);

        // Spent.caller is ctx.sender(), which in a keeper flow is the OPERATOR who
        // drove the spend, NOT the USER who owns the cap and its budget.
        let evs = event::events_by_type<spend_vault::Spent>();
        assert_eq!(evs.length(), 1);
        assert_eq!(
            evs[0],
            spend_vault::test_new_spent(
                vault_id,
                cap_id,
                type_name::with_defining_ids<EXAMPLE_COIN>(),
                100,
                200,
                OPERATOR,
            ),
        );

        ts::return_shared(vault);
        ts::return_shared(service);
        ts::return_shared(clk);
    };

    // Tx 6 (USER, as vault owner): raise the budget using only the cap's id while the
    // cap sits inside the service. The embedded cap is untouched.
    scenario.next_tx(USER);
    {
        let mut vault = scenario.take_shared<Vault>();
        let clk = scenario.take_shared<Clock>();
        let owner_cap = scenario.take_from_sender<OwnerCap>();

        let current = vault.allowance<EXAMPLE_COIN>(cap_id);
        vault.set_allowance<EXAMPLE_COIN>(
            &owner_cap,
            cap_id,
            500,
            NO_EXPIRY,
            option::some(current), // CAS on a read-derived update, always
            &clk,
            scenario.ctx(),
        );

        scenario.return_to_sender(owner_cap);
        ts::return_shared(vault);
        ts::return_shared(clk);
    };

    // Tx 7 (OPERATOR): spend again under the new budget with the same embedded cap.
    // No re-registration needed: owner maintenance never breaks an integration
    // holding the cap.
    scenario.next_tx(OPERATOR);
    {
        let mut vault = scenario.take_shared<Vault>();
        let mut service = scenario.take_shared<Service>();
        let clk = scenario.take_shared<Clock>();

        let funds = service.execute_topup<EXAMPLE_COIN>(
            &mut vault,
            USER,
            400,
            &clk,
            scenario.ctx(),
        );
        transfer::public_transfer(funds.into_coin(scenario.ctx()), USER);
        assert_eq!(vault.allowance<EXAMPLE_COIN>(cap_id), 100);

        ts::return_shared(vault);
        ts::return_shared(service);
        ts::return_shared(clk);
    };

    scenario.end();
}

// The sender gate is the integration's security boundary: a `SpenderCap` is a bearer
// instrument, so without this operator check `execute_topup` would be world-drainable
// across every coin the cap is budgeted for.
#[test, expected_failure(abort_code = defi_keeper::ENotOperator)]
fun topup_by_non_operator_is_rejected() {
    let (mut scenario, _vault_id, _cap_id) = setup();

    // Tx 5 (MALLORY): tries to drive the keeper's custodied cap.
    scenario.next_tx(MALLORY);
    {
        let mut vault = scenario.take_shared<Vault>();
        let mut service = scenario.take_shared<Service>();
        let clk = scenario.take_shared<Clock>();

        let funds = service.execute_topup<EXAMPLE_COIN>(
            &mut vault,
            USER,
            100,
            &clk,
            scenario.ctx(),
        );
        destroy(funds); // unreachable, the gate aborts first

        ts::return_shared(vault);
        ts::return_shared(service);
        ts::return_shared(clk);
    };

    abort
}

// The custody boundary: validate a cap's vault binding before accepting it. A cap
// minted against some other vault is rejected at register time, not discovered at
// spend time.
#[test, expected_failure(abort_code = defi_keeper::EWrongVaultForService)]
fun register_cap_from_wrong_vault_is_rejected() {
    let (mut scenario, _vault_id, _cap_id) = setup();

    // Tx 5 (USER): create a SECOND vault, mint a cap against it, and try to register
    // that cap with the service pinned to the first vault.
    scenario.next_tx(USER);
    {
        let mut service = scenario.take_shared<Service>();

        let (other_vault, other_owner_cap) = spend_vault::new(scenario.ctx());
        let foreign_cap = other_vault.mint_cap(&other_owner_cap, scenario.ctx());

        service.register(foreign_cap, scenario.ctx()); // aborts here

        // Unreachable cleanup to keep the type checker satisfied.
        other_vault.share();
        transfer::public_transfer(other_owner_cap, USER);
        ts::return_shared(service);
    };

    abort
}

// Driving the keeper for a user who never registered a cap aborts ENotRegistered:
// there is no cap in custody to borrow, so the lookup fails before any spend.
#[test, expected_failure(abort_code = defi_keeper::ENotRegistered)]
fun topup_for_unregistered_user_is_rejected() {
    let (mut scenario, _vault_id, _cap_id) = setup();

    // Tx 5 (OPERATOR): MALLORY never registered, so there is no custodied cap.
    scenario.next_tx(OPERATOR);
    {
        let mut vault = scenario.take_shared<Vault>();
        let mut service = scenario.take_shared<Service>();
        let clk = scenario.take_shared<Clock>();

        // Aborts at the custody lookup before any cap is borrowed.
        let funds = service.execute_topup<EXAMPLE_COIN>(
            &mut vault,
            MALLORY,
            100,
            &clk,
            scenario.ctx(),
        );
        destroy(funds); // unreachable

        ts::return_shared(vault);
        ts::return_shared(service);
        ts::return_shared(clk);
    };

    abort
}

// Reclaiming custody with `unregister` returns the SpenderCap and leaves the
// underlying grant live: the holder can spend directly with the recovered cap.
#[test]
fun unregister_returns_cap_and_grant_stays_live() {
    let (mut scenario, _vault_id, cap_id) = setup();

    // Tx 5 (USER): pull the cap back out of custody and keep it in the wallet.
    scenario.next_tx(USER);
    {
        let mut service = scenario.take_shared<Service>();

        assert!(service.is_registered(USER));
        let cap = service.unregister(scenario.ctx());
        assert_eq!(object::id(&cap), cap_id); // the same cap comes back
        assert!(!service.is_registered(USER)); // custody is now empty

        transfer::public_transfer(cap, USER);
        ts::return_shared(service);
    };

    // Tx 6 (USER): the grant is untouched by the custody change; the holder spends
    // the recovered cap directly against the vault.
    scenario.next_tx(USER);
    {
        let mut vault = scenario.take_shared<Vault>();
        let clk = scenario.take_shared<Clock>();
        let cap = scenario.take_from_sender<SpenderCap>();

        let bal = vault.spend<EXAMPLE_COIN>(&cap, 100, &clk, scenario.ctx());
        assert_eq!(bal.value(), 100);
        assert_eq!(vault.allowance<EXAMPLE_COIN>(cap_id), 200);
        destroy(bal);

        scenario.return_to_sender(cap);
        ts::return_shared(vault);
        ts::return_shared(clk);
    };

    scenario.end();
}
