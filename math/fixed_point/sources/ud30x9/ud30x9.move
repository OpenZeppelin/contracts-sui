/// Unsigned decimal fixed-point type `UD30x9`.
///
/// This module defines the `UD30x9` decimal fixed-point type, which represents
/// unsigned real numbers using a `u128` scaled by `10^9`.
///
/// Why UD30x9:
/// - Matches Sui's native coin decimals (9), making conversions from token
///   amounts straightforward and less error-prone.
/// - Uses a decimal scale that is intuitive for humans, UIs, and offchain
///   systems, avoiding binary fixed-point surprises.
/// - Fits efficiently in `u128`, keeping storage and arithmetic lightweight
///   compared to `u256`-based decimal types.
/// - Well-suited for boundary values such as prices, fees, percentages, and
///   protocol parameters, while heavier math can still rely on `uq64x64`
///   internally.
module openzeppelin_fp_math::ud30x9;

/// The `UD30x9` decimal fixed-point type.
public struct UD30x9(u128) has copy, drop, store;

// === Constants ===

const SCALE: u128 = 1_000_000_000; // 10^9

// === Functions ===

public use fun openzeppelin_fp_math::ud30x9_base::abs as UD30x9.abs;
public use fun openzeppelin_fp_math::ud30x9_base::add as UD30x9.add;
public use fun openzeppelin_fp_math::ud30x9_base::and as UD30x9.and;
public use fun openzeppelin_fp_math::ud30x9_base::and2 as UD30x9.and2;
public use fun openzeppelin_fp_math::ud30x9_base::ceil as UD30x9.ceil;
public use fun openzeppelin_fp_math::ud30x9_base::div as UD30x9.div;
public use fun openzeppelin_fp_math::ud30x9_base::eq as UD30x9.eq;
public use fun openzeppelin_fp_math::ud30x9_base::floor as UD30x9.floor;
public use fun openzeppelin_fp_math::ud30x9_base::gt as UD30x9.gt;
public use fun openzeppelin_fp_math::ud30x9_base::gte as UD30x9.gte;
public use fun openzeppelin_fp_math::ud30x9_base::into_SD29x9 as UD30x9.into_SD29x9;
public use fun openzeppelin_fp_math::ud30x9_base::is_zero as UD30x9.is_zero;
public use fun openzeppelin_fp_math::ud30x9_base::lshift as UD30x9.lshift;
public use fun openzeppelin_fp_math::ud30x9_base::unchecked_lshift as UD30x9.unchecked_lshift;
public use fun openzeppelin_fp_math::ud30x9_base::lt as UD30x9.lt;
public use fun openzeppelin_fp_math::ud30x9_base::lte as UD30x9.lte;
public use fun openzeppelin_fp_math::ud30x9_base::mod as UD30x9.mod;
public use fun openzeppelin_fp_math::ud30x9_base::mul as UD30x9.mul;
public use fun openzeppelin_fp_math::ud30x9_base::neq as UD30x9.neq;
public use fun openzeppelin_fp_math::ud30x9_base::not as UD30x9.not;
public use fun openzeppelin_fp_math::ud30x9_base::or as UD30x9.or;
public use fun openzeppelin_fp_math::ud30x9_base::pow as UD30x9.pow;
public use fun openzeppelin_fp_math::ud30x9_base::rshift as UD30x9.rshift;
public use fun openzeppelin_fp_math::ud30x9_base::sub as UD30x9.sub;
public use fun openzeppelin_fp_math::ud30x9_base::try_into_SD29x9 as UD30x9.try_into_SD29x9;
public use fun openzeppelin_fp_math::ud30x9_base::unchecked_add as UD30x9.unchecked_add;
public use fun openzeppelin_fp_math::ud30x9_base::unchecked_sub as UD30x9.unchecked_sub;
public use fun openzeppelin_fp_math::ud30x9_base::xor as UD30x9.xor;

/// Constructs the zero value in `UD30x9` representation.
///
/// #### Returns
/// - The `UD30x9` representation of `0`.
public fun zero(): UD30x9 {
    UD30x9(0)
}

/// Constructs the value of one in `UD30x9` representation.
///
/// #### Returns
/// - The `UD30x9` representation of `1`.
public fun one(): UD30x9 {
    UD30x9(SCALE)
}

/// Constructs the maximum representable `UD30x9` value.
///
/// #### Returns
/// - The largest possible `UD30x9` value.
public fun max(): UD30x9 {
    UD30x9(std::u128::max_value!())
}

// === Casting helpers ===

/// Wraps raw `u128` bits into a `UD30x9` value.
///
/// #### Parameters
/// - `x`: Raw fixed-point value to wrap.
///
/// #### Returns
/// - The wrapped `UD30x9` value.
public fun wrap(x: u128): UD30x9 {
    UD30x9(x)
}

/// Returns the underlying `u128` value of a `UD30x9` value.
///
/// #### Parameters
/// - `x`: Value to unwrap.
///
/// #### Returns
/// - The underlying `u128` value.
public fun unwrap(x: UD30x9): u128 {
    x.0
}
