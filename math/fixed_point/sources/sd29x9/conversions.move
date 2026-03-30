/// Scale-aware conversions between whole signed magnitudes and `SD29x9`.
///
/// Use this module when you want to convert semantic integer values such as
/// `42` or `-42` into fixed-point values such as `42.0` or `-42.0`, or convert
/// `SD29x9` values back into whole integers by truncating the fractional part.
///
/// Move does not offer a native signed integer type suitable for this package,
/// so conversions into `SD29x9` accept an unsigned magnitude plus a sign flag,
/// and conversions back to a simple signed form return `(magnitude, is_negative)`.
///
/// This module is intentionally separate from raw casting helpers like
/// `sd29x9::wrap`, `sd29x9::from_bits`, and `u128_cast::into_SD29x9`, which
/// preserve raw scaled bits without applying or removing the `10^9` scale.
module openzeppelin_fp_math::sd29x9_convert;

use openzeppelin_fp_math::common;
use openzeppelin_fp_math::sd29x9::{Self, SD29x9, two_complement};

// === Errors ===

/// Whole signed magnitude cannot be scaled into `SD29x9`.
#[error(code = 0)]
const EOverflow: vector<u8> = "Whole integer overflows SD29x9 once scaled by 10^9";

/// Negative `SD29x9` values cannot be converted to unsigned integers.
#[error(code = 1)]
const ENegativeValue: vector<u8> =
    "Negative SD29x9 value cannot be converted to an unsigned integer";

/// Truncated whole part does not fit in `u64`.
#[error(code = 2)]
const EIntegerOverflow: vector<u8> = "Truncated whole part does not fit in u64";

// === Integer -> Fixed-Point ===

/// Converts a whole `u64` magnitude into `SD29x9` by multiplying it by `10^9`
/// and applying the provided sign.
///
/// #### Parameters
/// - `x`: Whole signed magnitude to scale into fixed-point form.
/// - `is_negative`: Whether the result should be negative.
///
/// #### Returns
/// - The `SD29x9` representation of `x.0` or `-x.0`.
public fun from_u64(x: u64, is_negative: bool): SD29x9 {
    from_u128(x as u128, is_negative)
}

/// Converts a whole `u128` magnitude into `SD29x9` by multiplying it by `10^9`
/// and applying the provided sign.
///
/// #### Parameters
/// - `x`: Whole signed magnitude to scale into fixed-point form.
/// - `is_negative`: Whether the result should be negative.
///
/// #### Returns
/// - The `SD29x9` representation of `x.0` or `-x.0`.
///
/// #### Aborts
/// - Aborts if `x * 10^9` would overflow the `SD29x9` raw representation.
public fun from_u128(x: u128, is_negative: bool): SD29x9 {
    assert!(x <= common::max_sd29x9_whole(), EOverflow);
    sd29x9::wrap(x * common::scale(), is_negative)
}

/// Tries to convert a whole `u128` magnitude into `SD29x9` by multiplying it
/// by `10^9` and applying the provided sign.
///
/// #### Parameters
/// - `x`: Whole signed magnitude to scale into fixed-point form.
/// - `is_negative`: Whether the result should be negative.
///
/// #### Returns
/// - `some(SD29x9)` when the scaled magnitude fits, otherwise `none`.
public fun try_from_u128(x: u128, is_negative: bool): Option<SD29x9> {
    if (x > common::max_sd29x9_whole()) {
        option::none()
    } else {
        option::some(sd29x9::wrap(x * common::scale(), is_negative))
    }
}

// === Fixed-Point -> Integer ===

/// Converts an `SD29x9` value into a truncated whole-number magnitude plus its
/// sign flag.
///
/// #### Parameters
/// - `x`: Fixed-point value to convert.
///
/// #### Returns
/// - `(magnitude, is_negative)` where `magnitude` is the truncated whole-number
///   portion of the absolute value of `x`.
///
/// The sign flag is always `false` when the `magnitude` part is zero.
public fun to_parts_trunc(x: SD29x9): (u128, bool) {
    let bits = x.unwrap();
    let (neg, mag) = if ((bits & common::sign_bit()) != 0) {
        (true, two_complement(bits))
    } else {
        (false, bits)
    };
    let whole = mag / common::scale();
    (whole, neg && (whole != 0))
}

/// Converts a non-negative `SD29x9` value into a whole `u128` by truncating its
/// fractional part.
///
/// #### Parameters
/// - `x`: Fixed-point value to convert.
///
/// #### Returns
/// - The whole-number portion of `x`.
///
/// #### Aborts
/// - Aborts if `x` is negative.
public fun to_u128_trunc(x: SD29x9): u128 {
    let bits = x.unwrap();
    assert!((bits & common::sign_bit()) == 0, ENegativeValue);
    bits / common::scale()
}

/// Tries to convert a non-negative `SD29x9` value into a whole `u128` by
/// truncating its fractional part.
///
/// #### Parameters
/// - `x`: Fixed-point value to convert.
///
/// #### Returns
/// - `some(u128)` when `x` is non-negative, otherwise `none`.
public fun try_to_u128_trunc(x: SD29x9): Option<u128> {
    let bits = x.unwrap();
    if ((bits & common::sign_bit()) != 0) {
        option::none()
    } else {
        option::some(bits / common::scale())
    }
}

/// Converts a non-negative `SD29x9` value into a whole `u64` by truncating its
/// fractional part.
///
/// #### Parameters
/// - `x`: Fixed-point value to convert.
///
/// #### Returns
/// - The whole-number portion of `x`, provided it fits in `u64`.
///
/// #### Aborts
/// - Aborts if `x` is negative.
/// - Aborts if the truncated whole-number portion exceeds `u64::MAX`.
public fun to_u64_trunc(x: SD29x9): u64 {
    let whole = to_u128_trunc(x);
    assert!(whole <= (std::u64::max_value!() as u128), EIntegerOverflow);
    whole as u64
}

/// Tries to convert a non-negative `SD29x9` value into a whole `u64` by
/// truncating its fractional part.
///
/// #### Parameters
/// - `x`: Fixed-point value to convert.
///
/// #### Returns
/// - `some(u64)` when `x` is non-negative and the truncated whole-number
///   portion fits in `u64`, otherwise `none`.
public fun try_to_u64_trunc(x: SD29x9): Option<u64> {
    let whole = try_to_u128_trunc(x);
    if (whole.is_none()) {
        option::none()
    } else {
        let whole = whole.destroy_some();
        if (whole > (std::u64::max_value!() as u128)) {
            option::none()
        } else {
            option::some(whole as u64)
        }
    }
}
