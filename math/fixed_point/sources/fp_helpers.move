/// Shared helpers for fixed-point arithmetic modules.
module openzeppelin_fp_math::fp_helpers;

/// Returns `floor(sqrt(a))` for a `u256` value using Newton's method.
///
/// Uses a bit-width based initial estimate refined by 6 Newton iterations,
/// guaranteeing convergence for the full `u256` range.
///
/// #### Parameters
/// - `a`: Input value.
///
/// #### Returns
/// - `floor(sqrt(a))`.
public(package) fun sqrt_floor(a: u256): u256 {
    if (a <= 1) {
        return a
    };
    let mut aa = a;
    let mut xn = 1;

    if (aa >= (1 << 128)) { aa = aa >> 128; xn = xn << 64; };
    if (aa >= (1 << 64)) { aa = aa >> 64; xn = xn << 32; };
    if (aa >= (1 << 32)) { aa = aa >> 32; xn = xn << 16; };
    if (aa >= (1 << 16)) { aa = aa >> 16; xn = xn << 8; };
    if (aa >= (1 << 8)) { aa = aa >> 8; xn = xn << 4; };
    if (aa >= (1 << 4)) { aa = aa >> 4; xn = xn << 2; };
    if (aa >= (1 << 2)) { xn = xn << 1; };

    xn = (3 * xn) >> 1;

    xn = (xn + a / xn) >> 1;
    xn = (xn + a / xn) >> 1;
    xn = (xn + a / xn) >> 1;
    xn = (xn + a / xn) >> 1;
    xn = (xn + a / xn) >> 1;
    xn = (xn + a / xn) >> 1;

    if (xn > a / xn) {
        xn - 1
    } else {
        xn
    }
}
