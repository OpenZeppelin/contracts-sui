/// Downside-risk helper built on the signed fixed-point `SD29x9` type.
///
/// A risk engine that models an asset's periodic return as a normal
/// distribution `N(mean, stddev)` needs two things from a fixed-point library:
/// signed arithmetic (a return can be below its mean, so the deviation is
/// negative) and the standard-normal CDF `Φ`. This module wires both together
/// using `openzeppelin_fp_math::sd29x9`, its scale-aware converter
/// `sd29x9_convert`, and `sd29x9::cdf`.
///
/// The core quantity is the *z-score*, the number of standard deviations a
/// `value` sits from the `mean`:
///
/// ```move
/// z = (value - mean) / stddev
/// ```
///
/// `z` is frequently negative - that is the whole point of reaching for a
/// signed type. Feeding `z` through `Φ` answers the question a risk desk
/// actually cares about: *what is the probability a return lands below this
/// threshold?* `Φ(z)` is that left-tail probability, and `1 - Φ(z) = Φ(-z)`
/// is the right tail. Because `Φ` returns a value in `[0, 1]` it is always
/// non-negative, which lets us hand the probability back to an unsigned
/// consumer by casting it to `UD30x9`.
///
/// This example is deliberately a pure-compute library: every function takes
/// values and returns values, with no objects, capabilities, or transaction
/// context. A downstream protocol would call `probability_below` from inside
/// its own object methods (e.g. to size a margin requirement or gate a
/// withdrawal) - the math layer stays free of storage concerns.
///
/// # Signed handling demonstrated here
///
/// - Negatives are constructed with `sd29x9_convert::from_u64(x, true)`, the
///   sign-flag constructor the type exposes (Move has no native signed int).
/// - `value - mean` via `sub` yields a genuinely negative `SD29x9` when the
///   value is below the mean.
/// - `is_negative` classifies a deviation as downside without inspecting bits.
/// - `negate` flips a left-tail query into a right-tail one, exploiting the
///   exact symmetry `Φ(z) + Φ(-z) = 1` the CDF guarantees.
/// - `try_into_UD30x9` safely narrows a non-negative probability to the
///   unsigned type, returning `none` rather than aborting on the (impossible
///   for a probability, but defended) negative case.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways
/// the `SD29x9` signed fixed-point primitive can be integrated. It is not
/// production-ready and must not be deployed as-is.
module openzeppelin_fp_math::example_zscore;

use openzeppelin_fp_math::sd29x9::SD29x9;
use openzeppelin_fp_math::sd29x9_convert;
use openzeppelin_fp_math::ud30x9::UD30x9;

// === Errors ===

/// A risk profile was built with a non-positive standard deviation. A normal
/// distribution needs `stddev > 0`; a zero or negative spread is meaningless
/// and would make the z-score division abort or invert.
#[error(code = 0)]
const ENonPositiveStdDev: vector<u8> = "Standard deviation must be strictly positive";

// === Structs ===

/// A normal-distribution model of some scalar quantity, e.g. an asset's
/// periodic return. Copyable and storable so a protocol can keep one per
/// market inside its own object. Both fields are signed `SD29x9`: the `mean`
/// can be negative (an asset with negative expected return), while `stddev` is
/// constrained positive at construction.
public struct RiskProfile has copy, drop, store {
    /// Expected value of the distribution. May be negative.
    mean: SD29x9,
    /// Standard deviation (spread). Always strictly positive; enforced in `new`.
    stddev: SD29x9,
}

// === Public Functions ===

/// Build a risk profile from a `mean` and a `stddev`.
///
/// The `mean` is unrestricted - a distribution centered on a negative number
/// is perfectly valid. The `stddev` must be strictly positive, otherwise the
/// z-score division is undefined; we reject it up front with a clear error
/// rather than letting the later `div` surface an opaque divide-by-zero.
///
/// Pure compute: no `TxContext`, no objects. The caller stores the returned
/// value wherever it likes.
///
/// #### Aborts
/// - `ENonPositiveStdDev` if `stddev <= 0`.
public fun new(mean: SD29x9, stddev: SD29x9): RiskProfile {
    // `is_negative` catches a negative spread; `is_zero` catches exactly zero.
    // Together they enforce `stddev > 0` before any division can happen.
    assert!(!stddev.is_negative() && !stddev.is_zero(), ENonPositiveStdDev);
    RiskProfile { mean, stddev }
}

/// Compute the z-score of `value` under this profile: how many standard
/// deviations `value` lies from the mean, signed.
///
/// ```move
/// z = (value - mean) / stddev
/// ```
///
/// The result is negative when `value < mean` and the quotient is nonzero -
/// the signed type is what makes that representable. `sub` produces the
/// (possibly negative) deviation; `div` then scales it by the (positive)
/// spread, preserving the sign of the numerator. One rounding caveat: `div`
/// truncates toward zero and collapses a zero magnitude to the canonical,
/// non-negative `zero()`, so a deviation smaller than one raw unit (`10^-9`)
/// times `stddev` yields a zero z-score even when `value < mean`. Use
/// `is_downside`, which reads the sign of the deviation without dividing,
/// for a rounding-independent direction test.
///
/// #### Aborts
/// - Aborts if the deviation overflows the `SD29x9` range (only for extreme
///   inputs far outside any realistic return).
public fun z_score(self: &RiskProfile, value: SD29x9): SD29x9 {
    let deviation = value.sub(self.mean);
    deviation.div(self.stddev)
}

/// Probability that a draw from this distribution falls at or below
/// `threshold`: the left-tail probability `Φ(z)`.
///
/// This is the headline integration - it turns a raw `value` into a
/// probability in `[0, 1]`. A margin engine might call this to ask "what is
/// the chance the next return is below the liquidation threshold?".
///
/// Returns a non-negative `SD29x9` (the CDF range is `[0, 1]`); use
/// `probability_as_ud30x9` to narrow it to the unsigned type for an unsigned
/// consumer.
///
/// #### Aborts
/// - Aborts if the z-score computation overflows the `SD29x9` range (extreme
///   inputs only).
public fun probability_below(self: &RiskProfile, threshold: SD29x9): SD29x9 {
    self.z_score(threshold).cdf()
}

/// Probability that a draw from this distribution falls strictly above
/// `threshold`: the right-tail probability `1 - Φ(z) = Φ(-z)`.
///
/// Rather than computing `1 - Φ(z)` by subtraction, we exploit the exact
/// symmetry of the standard normal, `Φ(z) + Φ(-z) = 1`, and evaluate the CDF
/// at the negated z-score. `negate` is the signed-type operation that makes
/// this a one-liner, and the library documents this identity as bit-exact for
/// every input, so the two tails always sum to exactly `1`.
///
/// #### Aborts
/// - Aborts if the z-score computation overflows the `SD29x9` range (extreme
///   inputs only).
public fun probability_above(self: &RiskProfile, threshold: SD29x9): SD29x9 {
    self.z_score(threshold).negate().cdf()
}

// === View helpers ===

/// The configured mean.
public fun mean(self: &RiskProfile): SD29x9 {
    self.mean
}

/// The configured standard deviation.
public fun stddev(self: &RiskProfile): SD29x9 {
    self.stddev
}

/// Whether `value` is on the downside of the distribution, i.e. strictly below
/// the mean. Reads the sign of the deviation directly via `is_negative`
/// instead of recomputing a comparison - the cheapest possible classification.
public fun is_downside(self: &RiskProfile, value: SD29x9): bool {
    value.sub(self.mean).is_negative()
}

/// Narrow a probability produced by this module to the unsigned `UD30x9`
/// type, for handing to an unsigned downstream consumer.
///
/// `try_into_UD30x9` returns `none` for a negative input. A probability is
/// never negative, so in practice this always yields `some`; using the
/// fallible variant keeps the conversion total and makes the non-negativity
/// assumption explicit at the call site rather than risking an abort.
public fun probability_as_ud30x9(probability: SD29x9): Option<UD30x9> {
    probability.try_into_UD30x9()
}

/// Convenience constructor mirroring how an integrator would feed whole-number
/// inputs (e.g. basis points already scaled off-chain) into the model: wrap a
/// `u64` magnitude with an explicit sign. Demonstrates the sign-flag
/// constructor that stands in for a native signed integer.
public fun from_signed_whole(magnitude: u64, is_negative: bool): SD29x9 {
    sd29x9_convert::from_u64(magnitude, is_negative)
}
