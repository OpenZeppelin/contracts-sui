/// Helpers for casting `u128` values to fixed-point types.
module openzeppelin_fp_math::casting_u128;

use openzeppelin_fp_math::ud30x9::{UD30x9, wrap};

// === Public Functions ===

/// Converts a `u128` value into a `UD30x9` value.
///
/// #### Parameters
/// - `x`: Raw `u128` value to convert.
///
/// #### Returns
/// - The `UD30x9` representation of `x`.
public fun into_UD30x9(x: u128): UD30x9 {
    wrap(x)
}
