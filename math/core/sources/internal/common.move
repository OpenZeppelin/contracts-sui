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
