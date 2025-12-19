/// # UD30x9 Fixed-Point Type
///
/// This module defines the `UD30x9` decimal fixed-point type, which represents
/// unsigned real numbers using a `u128` scaled by `10^9`.
///
/// ## Why UD30x9
/// - Matches Sui’s native coin decimals (9), making conversions from token
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

// === Functions ===

public use fun openzeppelin_fp_math::ud30x9_base::add as UD30x9.add;
public use fun openzeppelin_fp_math::ud30x9_base::and as UD30x9.and;
public use fun openzeppelin_fp_math::ud30x9_base::and2 as UD30x9.and2;
public use fun openzeppelin_fp_math::ud30x9_base::eq as UD30x9.eq;
public use fun openzeppelin_fp_math::ud30x9_base::gt as UD30x9.gt;
public use fun openzeppelin_fp_math::ud30x9_base::gte as UD30x9.gte;
public use fun openzeppelin_fp_math::ud30x9_base::is_zero as UD30x9.is_zero;
public use fun openzeppelin_fp_math::ud30x9_base::lshift as UD30x9.lshift;
public use fun openzeppelin_fp_math::ud30x9_base::lt as UD30x9.lt;
public use fun openzeppelin_fp_math::ud30x9_base::lte as UD30x9.lte;
public use fun openzeppelin_fp_math::ud30x9_base::mod_ as UD30x9.mod_;
public use fun openzeppelin_fp_math::ud30x9_base::neq as UD30x9.neq;
public use fun openzeppelin_fp_math::ud30x9_base::not as UD30x9.not;
public use fun openzeppelin_fp_math::ud30x9_base::or as UD30x9.or;
public use fun openzeppelin_fp_math::ud30x9_base::rshift as UD30x9.rshift;
public use fun openzeppelin_fp_math::ud30x9_base::sub as UD30x9.sub;
public use fun openzeppelin_fp_math::ud30x9_base::unchecked_add as UD30x9.unchecked_add;
public use fun openzeppelin_fp_math::ud30x9_base::unchecked_sub as UD30x9.unchecked_sub;
public use fun openzeppelin_fp_math::ud30x9_base::xor as UD30x9.xor;

// === Casting helpers ===

/// Wraps a `u128` number into a `UD30x9` value type.
public(package) fun wrap(x: u128): UD30x9 {
    UD30x9(x)
}

/// Unwraps a `UD30x9` value into a `u128`.
public(package) fun unwrap(x: UD30x9): u128 {
    x.0
}
