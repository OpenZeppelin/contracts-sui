// Funding surface: deposit, deposit_balance, squash.
//
// These tests cover the permissionless funding paths: deposit and deposit_balance
// emit one Deposited per call with no rights conferred and no granted_coin_types
// written; squash recovers a stray coin emitting one Squashed (distinct from
// Deposited) and is funds-in-only; batched deposits in one tx each succeed.
//
// Pool-balance effects need the accumulator pool, which the unit-test VM cannot
// construct (balance_value needs an &AccumulatorRoot that is unavailable here), so
// these tests assert EVENTS and LEDGER non-effects (granted_coin_types stays empty,
// contains<T> stays false), NOT pool balances; pool balances are not exercised by this package's tests.
module openzeppelin_allowance::spend_vault_fund_tests;

use openzeppelin_allowance::spend_vault::{Self, Vault};
use openzeppelin_allowance::sv_test_utils::{Self as u, USDC, FOO};
use std::type_name;
use std::unit_test::assert_eq;
use sui::balance;
use sui::coin::{Self, Coin};
use sui::event;
use sui::test_scenario as ts;

const OWNER: address = @0xA;
const STRANGER: address = @0xBAD;
const THIRD: address = @0xCAFE;

// A throwaway cap_id (any ID) for contains/allowance probes: deposit/squash never
// create a (cap, T) entry, so contains<T> against ANY cap_id must stay false.
fun some_id(s: &mut ts::Scenario): ID {
    let uid = object::new(s.ctx());
    let id = uid.to_inner();
    uid.delete();
    id
}

// === deposit (permissionless, confers no rights) ===

#[test]
fun deposit_emits_deposited_event() {
    // deposit<USDC>(amt>0) -> exactly one Deposited{vault,coin,amt,sender}.
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 0); // empty vault, no grant
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        spend_vault::deposit(&v, coin::mint_for_testing<USDC>(750, s.ctx()), s.ctx());

        let evs = event::events_by_type<spend_vault::Deposited>();
        assert_eq!(evs.length(), 1);
        assert_eq!(
            evs[0],
            spend_vault::test_new_deposited(vid, type_name::with_defining_ids<USDC>(), 750, OWNER),
        );
        u::return_vault(v);
    };
    s.end();
}

#[test, expected_failure(abort_code = spend_vault::EZeroAmount)]
fun deposit_zero_amount_aborts() {
    // Zero is meaningless on deposit.
    let mut s = ts::begin(OWNER);
    let _vid = u::new_funded_vault<USDC>(&mut s, OWNER, 0);
    s.next_tx(OWNER);
    let v = u::take_vault(&s);
    spend_vault::deposit(&v, coin::mint_for_testing<USDC>(0, s.ctx()), s.ctx());
    abort
}

#[test]
fun deposit_by_non_owner_succeeds_confers_no_rights() {
    // A non-owner deposits -> succeeds, Deposited emitted, but no entry is
    // created: granted_coin_types stays empty and contains<USDC> is false for any cap_id.
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 0);
    s.next_tx(STRANGER);
    {
        let v = u::take_vault(&s);
        let probe = some_id(&mut s);
        spend_vault::deposit(&v, coin::mint_for_testing<USDC>(500, s.ctx()), s.ctx());

        let evs = event::events_by_type<spend_vault::Deposited>();
        assert_eq!(evs.length(), 1);
        assert_eq!(
            evs[0],
            spend_vault::test_new_deposited(
                vid,
                type_name::with_defining_ids<USDC>(),
                500,
                STRANGER,
            ),
        );
        // Confers NO rights: no granted type, no (cap, USDC) entry.
        assert_eq!(spend_vault::granted_coin_types(&v).length(), 0);
        assert!(!spend_vault::contains<USDC>(&v, probe));
        assert_eq!(spend_vault::allowance<USDC>(&v, probe), 0);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun deposit_does_not_write_granted_coin_types() {
    // Depositing FOO must not inflate the owner-only granted set.
    let mut s = ts::begin(OWNER);
    let _vid = u::new_funded_vault<USDC>(&mut s, OWNER, 0);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        spend_vault::deposit(&v, coin::mint_for_testing<FOO>(123, s.ctx()), s.ctx());
        assert_eq!(spend_vault::granted_coin_types(&v).length(), 0); // un-griefable
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun deposit_batched_in_one_tx_succeeds() {
    // The module never assumes it is the sole PTB step; several deposits in
    // one tx all succeed and each emits its own Deposited.
    let mut s = ts::begin(OWNER);
    let _vid = u::new_funded_vault<USDC>(&mut s, OWNER, 0);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        spend_vault::deposit(&v, coin::mint_for_testing<USDC>(100, s.ctx()), s.ctx());
        spend_vault::deposit(&v, coin::mint_for_testing<USDC>(200, s.ctx()), s.ctx());
        spend_vault::deposit(&v, coin::mint_for_testing<FOO>(300, s.ctx()), s.ctx());

        let evs = event::events_by_type<spend_vault::Deposited>();
        assert_eq!(evs.length(), 3);
        // Still no ledger effect from any of them.
        assert_eq!(spend_vault::granted_coin_types(&v).length(), 0);
        u::return_vault(v);
    };
    s.end();
}

// === deposit_balance (the Balance<T> ingress) ===

#[test]
fun deposit_balance_emits_deposited_event() {
    // deposit_balance<USDC>(amt>0) -> one Deposited (same schema as deposit).
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 0);
    s.next_tx(OWNER);
    {
        let v = u::take_vault(&s);
        let b = balance::create_for_testing<USDC>(640);
        spend_vault::deposit_balance<USDC>(&v, b, s.ctx());

        let evs = event::events_by_type<spend_vault::Deposited>();
        assert_eq!(evs.length(), 1);
        assert_eq!(
            evs[0],
            spend_vault::test_new_deposited(vid, type_name::with_defining_ids<USDC>(), 640, OWNER),
        );
        u::return_vault(v);
    };
    s.end();
}

#[test, expected_failure(abort_code = spend_vault::EZeroAmount)]
fun deposit_balance_zero_amount_aborts() {
    // Zero is meaningless on deposit_balance.
    let mut s = ts::begin(OWNER);
    let _vid = u::new_funded_vault<USDC>(&mut s, OWNER, 0);
    s.next_tx(OWNER);
    let v = u::take_vault(&s);
    let b = balance::create_for_testing<USDC>(0);
    spend_vault::deposit_balance<USDC>(&v, b, s.ctx());
    abort
}

#[test]
fun deposit_balance_by_non_owner_writes_no_granted_types() {
    // deposit_balance is permissionless and writes no granted set.
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 0);
    s.next_tx(STRANGER);
    {
        let v = u::take_vault(&s);
        let probe = some_id(&mut s);
        let b = balance::create_for_testing<FOO>(900);
        spend_vault::deposit_balance<FOO>(&v, b, s.ctx());

        let evs = event::events_by_type<spend_vault::Deposited>();
        assert_eq!(evs.length(), 1);
        assert_eq!(
            evs[0],
            spend_vault::test_new_deposited(
                vid,
                type_name::with_defining_ids<FOO>(),
                900,
                STRANGER,
            ),
        );
        assert_eq!(spend_vault::granted_coin_types(&v).length(), 0);
        assert!(!spend_vault::contains<FOO>(&v, probe));
        u::return_vault(v);
    };
    s.end();
}

// === squash (permissionless, funds-in-only; Squashed distinct from Deposited) ===

#[test]
fun squash_recovers_stray_coin_emits_squashed() {
    // A stray Coin<USDC> sent to the vault address is recovered by
    // squash -> one Squashed{vault,coin,amt,sender}, and it is DISTINCT from Deposited
    // (no Deposited is emitted on the squash call).
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 0);

    // Tx 1: public_transfer a loose Coin<USDC> to the vault's object address.
    s.next_tx(OWNER);
    let coin_id = {
        let c = coin::mint_for_testing<USDC>(450, s.ctx());
        let cid = object::id(&c);
        transfer::public_transfer(c, vid.to_address());
        cid
    };

    // Tx 2: squash it back into the pool via a receiving ticket.
    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let ticket = ts::receiving_ticket_by_id<Coin<USDC>>(coin_id);
        spend_vault::squash<USDC>(&mut v, ticket, s.ctx());

        let sq = event::events_by_type<spend_vault::Squashed>();
        assert_eq!(sq.length(), 1);
        assert_eq!(
            sq[0],
            spend_vault::test_new_squashed(vid, type_name::with_defining_ids<USDC>(), 450, OWNER),
        );
        // DISTINCT event types: squash emits Squashed, not Deposited.
        let dep = event::events_by_type<spend_vault::Deposited>();
        assert_eq!(dep.length(), 0);
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun squash_by_third_party_succeeds() {
    // squash is permissionless (funds-in-only); a party who is neither owner
    // nor depositor can recover the stray.
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 0);

    s.next_tx(STRANGER);
    let coin_id = {
        let c = coin::mint_for_testing<USDC>(77, s.ctx());
        let cid = object::id(&c);
        transfer::public_transfer(c, vid.to_address());
        cid
    };

    s.next_tx(THIRD);
    {
        let mut v = u::take_vault(&s);
        let ticket = ts::receiving_ticket_by_id<Coin<USDC>>(coin_id);
        spend_vault::squash<USDC>(&mut v, ticket, s.ctx());

        let sq = event::events_by_type<spend_vault::Squashed>();
        assert_eq!(sq.length(), 1);
        assert_eq!(
            sq[0],
            spend_vault::test_new_squashed(vid, type_name::with_defining_ids<USDC>(), 77, THIRD),
        );
        u::return_vault(v);
    };
    s.end();
}

#[test]
fun squash_writes_no_granted_coin_types() {
    // Squashing FOO must not inflate the owner-only granted set.
    let mut s = ts::begin(OWNER);
    let vid = u::new_funded_vault<USDC>(&mut s, OWNER, 0);

    s.next_tx(OWNER);
    let coin_id = {
        let c = coin::mint_for_testing<FOO>(321, s.ctx());
        let cid = object::id(&c);
        transfer::public_transfer(c, vid.to_address());
        cid
    };

    s.next_tx(OWNER);
    {
        let mut v = u::take_vault(&s);
        let probe = some_id(&mut s);
        let ticket = ts::receiving_ticket_by_id<Coin<FOO>>(coin_id);
        spend_vault::squash<FOO>(&mut v, ticket, s.ctx());

        // Funds-in-only, writes no type set, creates no entry.
        assert_eq!(spend_vault::granted_coin_types(&v).length(), 0);
        assert!(!spend_vault::contains<FOO>(&v, probe));
        u::return_vault(v);
    };
    s.end();
}
