/// An on-chain median price oracle built on `openzeppelin_math::vector`.
///
/// Aggregating reporter prices with the *median* rather than the mean is what makes an
/// oracle robust: a single manipulated or fat-fingered quote can drag a mean arbitrarily
/// far, but it can only nudge the median by one rank. This example keeps a bounded sliding
/// window of recent prices in a shared object and exposes two reads backed by the library:
///
///  - `median_price` uses the precompiled `median_u64` wrapper. The `median!` macro is
///    also available and generic over width, but it inlines ~750 bytes at every call site,
///    so the precompiled wrapper is the right choice for a function called repeatedly
///    on-chain. On an even-length window the two middle samples are combined using the
///    caller's `RoundingMode`.
///  - `sorted_prices` uses the in-place `quick_sort!` macro on a *copy* of the window, so
///    a caller can read min / max / percentiles without disturbing the stored insertion
///    order that the eviction policy depends on.
///
/// The window is bounded to `MAX_SAMPLES`: each report evicts the oldest sample once the
/// cap is reached, keeping the stored vector small (the style guide forbids unbounded
/// vectors inside objects).
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `openzeppelin_math` vector primitives can be integrated. It is not production-ready and
/// must not be deployed as-is: a real oracle additionally needs multiple independent
/// reporters, staleness checks, and deviation bounds.
module openzeppelin_math::example_median_oracle;

use openzeppelin_math::rounding::RoundingMode;
use openzeppelin_math::vector as oz_vector;

// === Errors ===

/// A median was requested before any price was reported.
#[error(code = 0)]
const ENoSamples: vector<u8> = "Oracle has no reported prices";

/// A reporter cap was presented for a different oracle than the one it authorizes.
#[error(code = 1)]
const EWrongOracle: vector<u8> = "Reporter cap was issued for a different oracle";

// === Constants ===

/// Maximum number of price samples retained; the oldest is evicted past this bound.
const MAX_SAMPLES: u64 = 8;

// === Structs ===

/// Shared oracle holding a bounded sliding window of recent reporter prices.
public struct PriceOracle has key {
    id: UID,
    /// Recent prices in insertion order (oldest first). Bounded to `MAX_SAMPLES`.
    prices: vector<u64>,
}

/// Authority to report prices to one `PriceOracle`. Reporting is capability-gated so an
/// arbitrary caller cannot poison the feed; the cap is bound to its oracle via `oracle_id`.
public struct ReporterCap has key, store {
    id: UID,
    /// Id of the `PriceOracle` this cap may report to.
    oracle_id: ID,
}

// === Public Functions ===

/// Create and share an empty oracle, returning a `ReporterCap` bound to it.
///
/// #### Parameters
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - A `ReporterCap` authorizing reports to the freshly shared oracle.
public fun new(ctx: &mut TxContext): ReporterCap {
    let oracle = PriceOracle { id: object::new(ctx), prices: vector[] };
    let cap = ReporterCap { id: object::new(ctx), oracle_id: object::id(&oracle) };
    transfer::share_object(oracle);
    cap
}

/// Append a reported price, evicting the oldest sample once `MAX_SAMPLES` is exceeded so
/// the stored window stays bounded. Gated by the oracle's `ReporterCap`.
///
/// #### Parameters
/// - `self`: The oracle to update.
/// - `cap`: The reporter cap bound to this oracle.
/// - `price`: The newly reported price.
///
/// #### Aborts
/// - `EWrongOracle` if `cap` is not bound to this oracle.
public fun report(self: &mut PriceOracle, cap: &ReporterCap, price: u64) {
    assert!(cap.oracle_id == object::id(self), EWrongOracle);
    self.prices.push_back(price);
    if (self.prices.length() > MAX_SAMPLES) {
        self.prices.remove(0);
    };
}

// === View helpers ===

/// The median of the retained prices.
///
/// On an even-length window the two middle samples are combined using `rounding_mode`.
///
/// #### Parameters
/// - `self`: The oracle to read.
/// - `rounding_mode`: How to round when the window length is even.
///
/// #### Returns
/// - The median price.
///
/// #### Aborts
/// - `ENoSamples` if no price has been reported.
public fun median_price(self: &PriceOracle, rounding_mode: RoundingMode): u64 {
    assert!(!self.prices.is_empty(), ENoSamples);
    oz_vector::median_u64(&self.prices, rounding_mode)
}

/// A sorted (ascending) copy of the retained prices, e.g. for min / max / percentile reads.
/// The copy is sorted in place with `quick_sort!`, leaving the stored insertion order
/// untouched.
///
/// #### Parameters
/// - `self`: The oracle to read.
///
/// #### Returns
/// - The retained prices, ascending.
public fun sorted_prices(self: &PriceOracle): vector<u64> {
    let mut sorted = self.prices;
    oz_vector::quick_sort!(&mut sorted);
    sorted
}

/// The number of retained samples.
///
/// #### Parameters
/// - `self`: The oracle to read.
public fun sample_count(self: &PriceOracle): u64 {
    self.prices.length()
}

/// The maximum number of samples the window retains.
public fun max_samples(): u64 {
    MAX_SAMPLES
}
