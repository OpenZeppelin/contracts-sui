/// Shared internal utilities used across the fixed-point package.
module openzeppelin_fp_math::common;

/// Divides `numerator` by `denominator` and rounds up when the division is inexact.
///
/// #### Parameters
/// - `numerator`: Dividend.
/// - `denominator`: Divisor. Must be non-zero.
///
/// #### Returns
/// - `numerator / denominator` when exact, otherwise that quotient plus one.
public(package) fun div_away_u256(numerator: u256, denominator: u256): u256 {
    let quotient = numerator / denominator;
    if (quotient * denominator == numerator) {
        quotient
    } else {
        quotient + 1
    }
}
