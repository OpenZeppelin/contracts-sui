/// Scale-aware conversions between whole unsigned integers and `UD30x9`.
///
/// Use this module when you want to convert semantic integer values such as
/// `42` into fixed-point values such as `42.0`, or convert `UD30x9` values
/// back into whole integers by truncating the fractional part.
///
/// This module is intentionally separate from raw casting helpers like
/// `ud30x9::wrap`, which preserve the raw fixed-point bits without applying
/// the `10^9` scale factor.
module openzeppelin_fp_math::ud30x9_convert;

use openzeppelin_fp_math::common;
use openzeppelin_fp_math::ud30x9::{Self, UD30x9};

// === Errors ===

/// Whole unsigned integer cannot be scaled into `UD30x9`.
#[error(code = 0)]
const EOverflow: vector<u8> = "Whole integer overflows UD30x9 once scaled by 10^9";

/// Truncated whole part does not fit in `u64`.
#[error(code = 1)]
const EIntegerOverflow: vector<u8> = "Truncated whole part does not fit in u64";

// === Public Functions ===

// === Integer -> Fixed-Point ===

/// Converts a whole `u64` integer into `UD30x9` by multiplying it by `10^9`.
///
/// #### Parameters
/// - `x`: Whole unsigned integer to scale into fixed-point form.
///
/// #### Returns
/// - The `UD30x9` representation of `x.0`.
public fun from_u64(x: u64): UD30x9 {
    from_u128(x as u128)
}

/// Converts a whole `u128` integer into `UD30x9` by multiplying it by `10^9`.
///
/// #### Parameters
/// - `x`: Whole unsigned integer to scale into fixed-point form.
///
/// #### Returns
/// - The `UD30x9` representation of `x.0`.
///
/// #### Aborts
/// - Aborts if `x * 10^9` would overflow the `UD30x9` raw representation.
public fun from_u128(x: u128): UD30x9 {
    assert!(x <= common::max_ud30x9_whole!(), EOverflow);
    ud30x9::wrap(x * common::scale!())
}

/// Tries to convert a whole `u128` integer into `UD30x9` by multiplying it by
/// `10^9`.
///
/// #### Parameters
/// - `x`: Whole unsigned integer to scale into fixed-point form.
///
/// #### Returns
/// - `some(UD30x9)` when `x` fits once scaled, otherwise `none`.
public fun try_from_u128(x: u128): Option<UD30x9> {
    if (x > common::max_ud30x9_whole!()) {
        option::none()
    } else {
        option::some(ud30x9::wrap(x * common::scale!()))
    }
}

// === Fixed-Point -> Integer ===

/// Converts a `UD30x9` value into a whole `u128` by truncating its fractional
/// part.
///
/// #### Parameters
/// - `x`: Fixed-point value to convert.
///
/// #### Returns
/// - The whole-number portion of `x`, computed as `floor(x)`.
public fun to_u128_trunc(x: UD30x9): u128 {
    x.unwrap() / common::scale!()
}

/// Converts a `UD30x9` value into a whole `u64` by truncating its fractional
/// part.
///
/// #### Parameters
/// - `x`: Fixed-point value to convert.
///
/// #### Returns
/// - The whole-number portion of `x`, provided it fits in `u64`.
///
/// #### Aborts
/// - Aborts if the truncated whole-number portion exceeds `u64::MAX`.
public fun to_u64_trunc(x: UD30x9): u64 {
    let whole = to_u128_trunc(x);
    assert!(whole <= (std::u64::max_value!() as u128), EIntegerOverflow);
    whole as u64
}

/// Tries to convert a `UD30x9` value into a whole `u64` by truncating its
/// fractional part.
///
/// #### Parameters
/// - `x`: Fixed-point value to convert.
///
/// #### Returns
/// - `some(u64)` when the truncated whole-number portion fits in `u64`,
///   otherwise `none`.
public fun try_to_u64_trunc(x: UD30x9): Option<u64> {
    let whole = to_u128_trunc(x);
    if (whole > (std::u64::max_value!() as u128)) {
        option::none()
    } else {
        option::some(whole as u64)
    }
}
