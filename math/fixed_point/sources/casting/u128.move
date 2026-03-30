/// Raw casting helpers from `u128` into fixed-point types.
///
/// These helpers do **not** apply the fixed-point scale. They simply wrap the
/// provided `u128` bits into the target type. For example, casting the integer
/// `42` with these helpers produces the raw fixed-point value `42`, not the
/// semantic decimal value `42.0`.
///
/// Use the dedicated conversion modules `ud30x9_convert` and `sd29x9_convert`
/// when you want whole-number semantics that multiply or divide by `10^9`.
module openzeppelin_fp_math::u128_cast;

use openzeppelin_fp_math::sd29x9::{Self, SD29x9};
use openzeppelin_fp_math::ud30x9::{Self, UD30x9};

/// Casts raw `u128` fixed-point bits into `UD30x9`.
///
/// #### Parameters
/// - `x`: Raw fixed-point bits to wrap.
///
/// #### Returns
/// - The `UD30x9` value with raw bits `x`.
public fun into_UD30x9(x: u128): UD30x9 {
    ud30x9::wrap(x)
}

/// Casts a raw `u128` magnitude into `SD29x9`, applying the provided sign bit
/// convention but not the fixed-point scale.
///
/// #### Parameters
/// - `x`: Raw fixed-point magnitude to wrap.
/// - `is_negative`: Whether the wrapped value should be negative.
///
/// #### Returns
/// - The `SD29x9` value with raw scaled magnitude `x`.
///
/// #### Aborts
/// - Aborts if the raw magnitude cannot be represented as `SD29x9`.
public fun into_SD29x9(x: u128, is_negative: bool): SD29x9 {
    sd29x9::wrap(x, is_negative)
}
