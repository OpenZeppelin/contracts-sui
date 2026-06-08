/// A throwaway fixed-supply coin used solely to give the faucet examples
/// (`simple_faucet`, `tiered_faucet`) something concrete to hand out. Not part of the
/// rate limiter itself — it just supplies the `Balance` the faucets are funded with.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `RateLimiter` primitive can be integrated. It is not production-ready and must not be
/// deployed as-is.
module openzeppelin_utils::rare_coin;

/// One-time witness for the coin. The all-caps name matching the module is the Sui
/// convention that lets `init` register this as a currency.
public struct RARE_COIN has drop {}

/// Mints a fixed supply of 10,000 units to the publisher, freezes the supply, and
/// freezes the metadata. Runs once at publish.
fun init(witness: RARE_COIN, ctx: &mut TxContext) {
    let (mut currency, mut treasury_cap) = sui::coin_registry::new_currency_with_otw(
        witness,
        0,
        "RARE_COIN",
        "Rare Coin",
        "",
        "",
        ctx,
    );

    let coins = treasury_cap.mint(10_000, ctx);
    currency.make_supply_fixed(treasury_cap);
    let metadata_cap = currency.finalize(ctx);
    transfer::public_freeze_object(metadata_cap);
    transfer::public_transfer(coins, ctx.sender());
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(RARE_COIN {}, ctx)
}
