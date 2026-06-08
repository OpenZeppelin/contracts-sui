module openzeppelin_utils::rare_coin;

public struct RARE_COIN has drop {}

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
