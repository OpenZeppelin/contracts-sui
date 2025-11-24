///
/// Common internal utilities used in multiple places of the package.
///
module openzeppelin_math::common;

/// Count the number of leading zeros in an unsigned integer value of arbitrary bit width.
///
/// This function counts the number of leading zero bits in a value of a given bit width (such as u8, u16, u32, u64, u128, or u256)
/// using a binary search method. It starts with the full bit width and iteratively right-shifts the value by progressively smaller
/// powers of two (bit_width/2, bit_width/4, ..., 1). For each shift, if the upper portion is zero, the number of leading zeros increases
/// by the shift amount. If the input value is zero, it returns bit_width. Otherwise, it returns the count of leading zero bits for the
/// value, respecting the provided bit width.
public(package) fun clz(val: u256, bit_width: u16): u16 {
    if (val == 0) {
        return bit_width
    };

    let mut count: u16 = 0;
    let mut value = val;
    let mut shift: u8 = (bit_width / 2) as u8;
    while (shift > 0) {
        let shifted = value >> shift;
        if (shifted == 0) {
            count = count + (shift as u16);
        } else {
            value = shifted;
        };
        shift = shift / 2;
    };

    count
}

/// Return the position of the most significant bit (MSB) in an unsigned integer value of arbitrary bit width.
///
/// This function returns the zero-based index of the most significant set bit in a value of a given bit width
/// (such as u8, u16, u32, u64, u128, or u256). The MSB position is calculated as `bit_width - 1 - clz(val, bit_width)`,
/// where `clz` is the count of leading zeros. For a zero input, the function returns 0 by convention.
public(package) fun msb(val: u256, bit_width: u16): u8 {
    if (val == 0) {
        return 0
    };
    // clz result for non-zero is guaranteed to be less than bit_width, so the subtraction is safe
    (bit_width - 1 - clz(val, bit_width)) as u8
}

/// Returns the square root of a number. If the number is not a perfect square, the value is rounded
/// towards zero.
///
/// This method is based on Newton's method for computing square roots. The algorithm is restricted to only
/// using integer operations.
public(package) fun sqrt_floor(a: u256): u256 {
    // Take care of easy edge cases: sqrt(0) = 0 and sqrt(1) = 1
    if (a <= 1) {
        return a
    };
    let mut aa = a;
    let mut xn = 1;

    // In this function, we use Newton's method to get a root of `f(x) := x² - a`. It involves building a
    // sequence x_n that converges toward sqrt(a). For each iteration x_n, we also define the error between
    // the current value as `ε_n = | x_n - sqrt(a) |`.
    //
    // For our first estimation, we consider `e` the smallest power of 2 which is bigger than the square root
    // of the target. (i.e. `2**(e-1) ≤ sqrt(a) < 2**e`). We know that `e ≤ 128` because `(2¹²⁸)² = 2²⁵⁶` is
    // bigger than any uint256.
    //
    // By noticing that
    // `2**(e-1) ≤ sqrt(a) < 2**e → (2**(e-1))² ≤ a < (2**e)² → 2**(2*e-2) ≤ a < 2**(2*e)`
    // we can deduce that `e - 1` is `log2(a) / 2`. We can thus compute `x_n = 2**(e-1)` using a method similar
    // to the msb function.
    if (aa >= (1 << 128)) {
        aa = aa >> 128;
        xn = xn << 64;
    };
    if (aa >= (1 << 64)) {
        aa = aa >> 64;
        xn = xn << 32;
    };
    if (aa >= (1 << 32)) {
        aa = aa >> 32;
        xn = xn << 16;
    };
    if (aa >= (1 << 16)) {
        aa = aa >> 16;
        xn = xn << 8;
    };
    if (aa >= (1 << 8)) {
        aa = aa >> 8;
        xn = xn << 4;
    };
    if (aa >= (1 << 4)) {
        aa = aa >> 4;
        xn = xn << 2;
    };
    if (aa >= (1 << 2)) {
        xn = xn << 1;
    };

    // We now have x_n such that `x_n = 2**(e-1) ≤ sqrt(a) < 2**e = 2 * x_n`. This implies ε_n ≤ 2**(e-1).
    //
    // We can refine our estimation by noticing that the middle of that interval minimizes the error.
    // If we move x_n to equal 2**(e-1) + 2**(e-2), then we reduce the error to ε_n ≤ 2**(e-2).
    // This is going to be our x_0 (and ε_0).
    xn = (3 * xn) >> 1; // ε_0 := | x_0 - sqrt(a) | ≤ 2**(e-2)

    // From here, Newton's method give us:
    // x_{n+1} = (x_n + a / x_n) / 2
    //
    // One should note that:
    // x_{n+1}² - a = ((x_n + a / x_n) / 2)² - a
    //              = ((x_n² + a) / (2 * x_n))² - a
    //              = (x_n⁴ + 2 * a * x_n² + a²) / (4 * x_n²) - a
    //              = (x_n⁴ + 2 * a * x_n² + a² - 4 * a * x_n²) / (4 * x_n²)
    //              = (x_n⁴ - 2 * a * x_n² + a²) / (4 * x_n²)
    //              = (x_n² - a)² / (2 * x_n)²
    //              = ((x_n² - a) / (2 * x_n))²
    //              ≥ 0
    // Which proves that for all n ≥ 1, sqrt(a) ≤ x_n
    //
    // This gives us the proof of quadratic convergence of the sequence:
    // ε_{n+1} = | x_{n+1} - sqrt(a) |
    //         = | (x_n + a / x_n) / 2 - sqrt(a) |
    //         = | (x_n² + a - 2*x_n*sqrt(a)) / (2 * x_n) |
    //         = | (x_n - sqrt(a))² / (2 * x_n) |
    //         = | ε_n² / (2 * x_n) |
    //         = ε_n² / | (2 * x_n) |
    //
    // For the first iteration, we have a special case where x_0 is known:
    // ε_1 = ε_0² / | (2 * x_0) |
    //     ≤ (2**(e-2))² / (2 * (2**(e-1) + 2**(e-2)))
    //     ≤ 2**(2*e-4) / (3 * 2**(e-1))
    //     ≤ 2**(e-3) / 3
    //     ≤ 2**(e-3-log2(3))
    //     ≤ 2**(e-4.5)
    //
    // For the following iterations, we use the fact that, 2**(e-1) ≤ sqrt(a) ≤ x_n:
    // ε_{n+1} = ε_n² / | (2 * x_n) |
    //         ≤ (2**(e-k))² / (2 * 2**(e-1))
    //         ≤ 2**(2*e-2*k) / 2**e
    //         ≤ 2**(e-2*k)
    xn = (xn + a / xn) >> 1; // ε_1 := | x_1 - sqrt(a) | ≤ 2**(e-4.5)  -- special case, see above
    xn = (xn + a / xn) >> 1; // ε_2 := | x_2 - sqrt(a) | ≤ 2**(e-9)    -- general case with k = 4.5
    xn = (xn + a / xn) >> 1; // ε_3 := | x_3 - sqrt(a) | ≤ 2**(e-18)   -- general case with k = 9
    xn = (xn + a / xn) >> 1; // ε_4 := | x_4 - sqrt(a) | ≤ 2**(e-36)   -- general case with k = 18
    xn = (xn + a / xn) >> 1; // ε_5 := | x_5 - sqrt(a) | ≤ 2**(e-72)   -- general case with k = 36
    xn = (xn + a / xn) >> 1; // ε_6 := | x_6 - sqrt(a) | ≤ 2**(e-144)  -- general case with k = 72

    // Because e ≤ 128 (as discussed during the first estimation phase), we now have reached a precision
    // ε_6 ≤ 2**(e-144) < 1. Given we're operating on integers, then we can ensure that xn is now either
    // sqrt(a) or sqrt(a) + 1.
    if (xn > a / xn) {
        xn - 1
    } else {
        xn
    }
}
