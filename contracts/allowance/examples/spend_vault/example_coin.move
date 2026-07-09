/// A throwaway fixed-supply coin used solely to give the `spend_vault` examples a
/// concrete coin type to fund a vault with. Not part of the allowance primitive
/// itself: it just supplies the `Coin` / `Balance` the examples escrow and spend.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `spend_vault` allowance primitive can be integrated. It is not production-ready and
/// must not be deployed as-is.
module openzeppelin_allowance::example_coin;

// === Constants ===

const SUPPLY: u64 = 1_000_000;

// === Structs ===

/// One-time witness for the coin. The all-caps name matching the module is the Sui
/// convention that lets `init` register this as a currency.
public struct EXAMPLE_COIN has drop {}

// === Init ===

/// Mints a fixed supply of 1,000,000 units to the publisher, freezes the supply, and
/// freezes the metadata. Runs once at publish.
fun init(otw: EXAMPLE_COIN, ctx: &mut TxContext) {
    let (mut currency, mut treasury_cap) = sui::coin_registry::new_currency_with_otw(
        otw,
        0,
        "EXAMPLE_COIN",
        "Example Coin",
        "",
        "",
        ctx,
    );

    let coins = treasury_cap.mint(SUPPLY, ctx);
    currency.make_supply_fixed(treasury_cap);
    currency.finalize_and_delete_metadata_cap(ctx);
    transfer::public_transfer(coins, ctx.sender());
}

// === Test-Only Helpers ===

/// Run `init` under test, minting the fixed supply to the sender so an example vault
/// can be funded.
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(EXAMPLE_COIN {}, ctx)
}
