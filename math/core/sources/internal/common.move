///
/// Common internal utilities used in multiple places of the package.
///
module openzeppelin_math::common;

/// Count the number of leading zeros in a `u256` value.
///
/// Counts the number of leading zero bits in a `u256` value using a binary search method.
/// Starts with the full 256 bits and iteratively right-shifts the value by progressively smaller powers of two
/// (128, 64, 32, 16, 8, 4, 2, 1). For each shift, if the upper half is zero, the number of leading zeros increases by the shift amount.
/// For a value of zero, returns 256; otherwise, returns the count of leading zero bits in the input.
public(package) fun leading_zeros_u256(val: u256): u16 {
    let mut count: u16 = 0;
    let mut value = val;
    let mut shift: u8 = 128;
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
