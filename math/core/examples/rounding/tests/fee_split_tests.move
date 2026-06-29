module openzeppelin_math::example_fee_split_tests;

use openzeppelin_math::example_fee_split;
use openzeppelin_math::rounding;
use std::unit_test::assert_eq;

// A split is only useful if its two parts reconstruct the whole. Every test below
// runs the result through this helper so the `fee + payout == total` invariant is
// checked on every path, not just asserted once.
fun assert_sums_to_whole(fee: u64, payout: u64, total: u64) {
    assert_eq!(fee + payout, total);
}

// The single input that motivates the whole example: a fee that lands on a fraction,
// so Down, Up, and Nearest all have something to say. `998 * 125 / 10_000 = 12.475`.
//   - Down -> 12 (drops the 0.475)
//   - Up   -> 13 (keeps any remainder)
//   - Nearest -> 12 (0.475 < 0.5, rounds down)
// Up genuinely differs from both Down and Nearest here, and the payout flips with it.
#[test]
fun rounding_modes_diverge_on_fractional_fee() {
    let total = 998;
    let bps = 125; // 1.25%

    let (fee_user, payout_user) = example_fee_split::split_user_favorable(total, bps);
    let (fee_proto, payout_proto) = example_fee_split::split_protocol_favorable(total, bps);
    let (fee_near, payout_near) = example_fee_split::split_nearest(total, bps);

    // Exact, pinned fee figures: the three modes do NOT collapse to one value.
    assert_eq!(fee_user, 12); // rounded down
    assert_eq!(fee_proto, 13); // rounded up
    assert_eq!(fee_near, 12); // 0.475 rounds to nearest = down

    // The spare sub-unit lands on the protocol when rounding up, on the user otherwise.
    assert_eq!(payout_user, 986);
    assert_eq!(payout_proto, 985);
    assert_eq!(payout_near, 986);

    // Every mode still reconstructs the whole exactly.
    assert_sums_to_whole(fee_user, payout_user, total);
    assert_sums_to_whole(fee_proto, payout_proto, total);
    assert_sums_to_whole(fee_near, payout_near, total);
}

// The mirror case where Nearest rounds UP instead of down: `1006 * 125 / 10_000 =
// 12.575`, so 0.575 >= 0.5 ties toward Up. Down still differs from both, confirming
// Nearest is a genuine third behavior and not an alias of one fixed side.
#[test]
fun nearest_rounds_up_above_the_half() {
    let total = 1006;
    let bps = 125; // 1.25%

    let (fee_down, payout_down) = example_fee_split::split_user_favorable(total, bps);
    let (fee_up, payout_up) = example_fee_split::split_protocol_favorable(total, bps);
    let (fee_near, payout_near) = example_fee_split::split_nearest(total, bps);

    assert_eq!(fee_down, 12);
    assert_eq!(fee_up, 13);
    assert_eq!(fee_near, 13); // 0.575 rounds to nearest = up

    assert_eq!(payout_down, 994);
    assert_eq!(payout_up, 993);
    assert_eq!(payout_near, 993);

    assert_sums_to_whole(fee_down, payout_down, total);
    assert_sums_to_whole(fee_up, payout_up, total);
    assert_sums_to_whole(fee_near, payout_near, total);
}

// When the fee divides evenly the rounding mode is irrelevant: all three modes agree
// and the invariant still holds. `10_000_000 * 250 / 10_000 = 250_000` exactly.
#[test]
fun exact_division_is_mode_independent() {
    let total = 10_000_000;
    let bps = 250; // 2.5%

    let (fee_user, payout_user) = example_fee_split::split_user_favorable(total, bps);
    let (fee_proto, payout_proto) = example_fee_split::split_protocol_favorable(total, bps);
    let (fee_near, payout_near) = example_fee_split::split_nearest(total, bps);

    assert_eq!(fee_user, 250_000);
    assert_eq!(fee_proto, 250_000);
    assert_eq!(fee_near, 250_000);

    assert_eq!(payout_user, 9_750_000);
    assert_eq!(payout_proto, 9_750_000);
    assert_eq!(payout_near, 9_750_000);

    assert_sums_to_whole(fee_user, payout_user, total);
    assert_sums_to_whole(fee_proto, payout_proto, total);
    assert_sums_to_whole(fee_near, payout_near, total);
}

// Boundary modes: a 0% fee gives the user everything, a 100% fee gives the protocol
// everything. Both must still split exactly (no off-by-one at the extremes).
#[test]
fun boundary_fees_split_exactly() {
    let total = 777;

    let (fee_zero, payout_zero) = example_fee_split::split_protocol_favorable(total, 0);
    assert_eq!(fee_zero, 0);
    assert_eq!(payout_zero, total);
    assert_sums_to_whole(fee_zero, payout_zero, total);

    let (fee_full, payout_full) = example_fee_split::split_user_favorable(total, 10_000);
    assert_eq!(fee_full, total);
    assert_eq!(payout_full, 0);
    assert_sums_to_whole(fee_full, payout_full, total);
}

// `bps_of` is the raw fee calculation the splitters wrap. Pinning it directly shows the
// explicit `mul_div` rounding contract on the same fractional input as the first test.
#[test]
fun bps_of_exposes_raw_rounding() {
    let amount = 998;
    let bps = 125;

    assert_eq!(example_fee_split::bps_of(amount, bps, rounding::down()), 12);
    assert_eq!(example_fee_split::bps_of(amount, bps, rounding::up()), 13);
    assert_eq!(example_fee_split::bps_of(amount, bps, rounding::nearest()), 12);
}

// A fee above 100% would force `payout = total - fee` to underflow and silently mint
// value out of thin air. The guard rejects it with a named, deterministic abort before
// any arithmetic runs. End on a bare abort sentinel with no cleanup, per convention.
#[test, expected_failure(abort_code = example_fee_split::EInvalidBps)]
fun rejects_fee_above_one_hundred_percent() {
    example_fee_split::split_protocol_favorable(1_000, 10_001);
    abort
}
