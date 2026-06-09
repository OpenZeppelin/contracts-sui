/// A throwaway fixed-supply coin used solely to give the `faucet` example something
/// concrete to hand out. Not part of the rate limiter itself — it just supplies the
/// `Balance` the faucet is funded with.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `RateLimiter` primitive can be integrated. It is not production-ready and must not be
/// deployed as-is.
module openzeppelin_utils::rare_coin;

// === Constants ===

const SUPPLY: u64 = 10_000;

// === Structs ===

/// One-time witness for the coin. The all-caps name matching the module is the Sui
/// convention that lets `init` register this as a currency.
public struct RARE_COIN has drop {}

// === Init ===

/// Mints a fixed supply of 10,000 units to the publisher, freezes the supply, and
/// freezes the metadata. Runs once at publish.
fun init(otw: RARE_COIN, ctx: &mut TxContext) {
    let (mut currency, mut treasury_cap) = sui::coin_registry::new_currency_with_otw(
        otw,
        0,
        "RARE_COIN",
        "Rare Coin",
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

/// Run `init` under test, minting the fixed supply to the sender so a faucet can be funded.
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(RARE_COIN {}, ctx)
}
