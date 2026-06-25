module openzeppelin_math::example_median_oracle_tests;

use openzeppelin_math::example_median_oracle::{Self as oracle, PriceOracle};
use openzeppelin_math::rounding;
use std::unit_test::assert_eq;
use sui::test_scenario as ts;

const ADMIN: address = @0xA;

// Odd window: the median is the single middle sample (rounding is irrelevant).
#[test]
fun median_of_odd_window() {
    let mut scenario = ts::begin(ADMIN);
    oracle::new(scenario.ctx());
    scenario.next_tx(ADMIN);

    let mut o = scenario.take_shared<PriceOracle>();
    o.report(5);
    o.report(1);
    o.report(3);
    // Sorted [1, 3, 5] -> middle is 3.
    assert_eq!(o.median_price(rounding::nearest()), 3);

    ts::return_shared(o);
    scenario.end();
}

// Even window: the two middle samples are combined, and the rounding mode decides the tie.
#[test]
fun median_of_even_window_respects_rounding() {
    let mut scenario = ts::begin(ADMIN);
    oracle::new(scenario.ctx());
    scenario.next_tx(ADMIN);

    let mut o = scenario.take_shared<PriceOracle>();
    o.report(1);
    o.report(2);
    o.report(3);
    o.report(4);
    // Middle samples 2 and 3 combine to 2.5.
    assert_eq!(o.median_price(rounding::down()), 2);
    assert_eq!(o.median_price(rounding::up()), 3);

    ts::return_shared(o);
    scenario.end();
}

// A single outlier moves the median by at most one rank.
#[test]
fun outlier_barely_moves_the_median() {
    let mut scenario = ts::begin(ADMIN);
    oracle::new(scenario.ctx());
    scenario.next_tx(ADMIN);

    let mut o = scenario.take_shared<PriceOracle>();
    o.report(12);
    o.report(10);
    o.report(13);
    o.report(11);
    o.report(1_000_000);
    // Sorted [10, 11, 12, 13, 1_000_000] -> middle is 12, not dragged by the outlier.
    assert_eq!(o.median_price(rounding::nearest()), 12);

    ts::return_shared(o);
    scenario.end();
}

// `sorted_prices` returns an ascending copy without disturbing stored order.
#[test]
fun sorted_view_is_ascending() {
    let mut scenario = ts::begin(ADMIN);
    oracle::new(scenario.ctx());
    scenario.next_tx(ADMIN);

    let mut o = scenario.take_shared<PriceOracle>();
    o.report(5);
    o.report(1);
    o.report(3);
    assert_eq!(o.sorted_prices(), vector[1, 3, 5]);
    // The stored window is unchanged, so the median still reads correctly afterwards.
    assert_eq!(o.median_price(rounding::nearest()), 3);

    ts::return_shared(o);
    scenario.end();
}

// The window is bounded: the oldest sample is evicted once the cap is exceeded.
#[test]
fun window_is_bounded_and_evicts_oldest() {
    let mut scenario = ts::begin(ADMIN);
    oracle::new(scenario.ctx());
    scenario.next_tx(ADMIN);

    let mut o = scenario.take_shared<PriceOracle>();
    // Report nine prices into an eight-slot window; the first (1) is evicted.
    let mut p = 1;
    while (p <= 9) {
        o.report(p);
        p = p + 1;
    };
    assert_eq!(o.sample_count(), oracle::max_samples());
    assert_eq!(o.sorted_prices(), vector[2, 3, 4, 5, 6, 7, 8, 9]);

    ts::return_shared(o);
    scenario.end();
}

// Reading the median before any report aborts.
#[test, expected_failure(abort_code = oracle::ENoSamples)]
fun empty_oracle_median_aborts() {
    let mut scenario = ts::begin(ADMIN);
    oracle::new(scenario.ctx());
    scenario.next_tx(ADMIN);

    let o = scenario.take_shared<PriceOracle>();
    o.median_price(rounding::nearest());

    abort
}
