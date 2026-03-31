/// Internal helper for binary exponentiation of fixed-point values stored as `u256`.
module openzeppelin_fp_math::pow_u256;

/// Computes `base^exp` using binary exponentiation in fixed-point arithmetic.
///
/// Each multiplication step divides by `scale` to keep values in fixed-point representation.
/// Intermediate values and the final result are checked against `max_value`.
///
/// #### Parameters
/// - `base`: The base value in fixed-point representation (already scaled).
/// - `exp`: The exponent. Must be non-zero.
/// - `scale`: The fixed-point scale factor (e.g. `10^9`).
/// - `max_value`: The maximum permitted intermediate or final value.
///
/// #### Returns
/// - `option::some(result)` on success, or `option::none()` if any intermediate value or
///   the final result exceeds `max_value`.
public(package) fun binary_pow(mut base: u256, mut exp: u8, scale: u256, max_value: u256): Option<u256> {
    let mut result = scale;
    while (exp != 0) {
        if ((exp & 1) == 1) {
            result = result * base / scale;
            if (result > max_value) return option::none();
        };
        exp = exp >> 1;
        if (exp != 0) {
            base = base * base / scale;
            if (base > max_value) return option::none();
        };
    };
    option::some(result)
}
