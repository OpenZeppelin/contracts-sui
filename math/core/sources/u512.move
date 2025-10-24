module openzeppelin_math::u512;

/// Represents a 512-bit unsigned integer as two 256-bit words.
public struct U512 has copy, drop, store {
    hi: u256,
    lo: u256,
}

const HALF_BITS: u8 = 128;
const HALF_MASK: u256 = (1u256 << HALF_BITS) - 1;

#[error(code = 0)]
const ECarryOverflow: vector<u8> = b"Cross-limb addition overflowed";
#[error(code = 1)]
const EUnderflow: vector<u8> = b"Borrow underflowed high limb";
#[error(code = 2)]
const EDivideByZero: vector<u8> = b"Divisor must be non-zero";
#[error(code = 3)]
const EInvalidRemainder: vector<u8> = b"High remainder bits must be zero";

/// Construct a `U512` from its high and low 256-bit components.
public fun new(hi: u256, lo: u256): U512 {
    U512 { hi, lo }
}

/// Return the all-zero `U512` value.
public fun zero(): U512 {
    U512 { hi: 0, lo: 0 }
}

/// Lift a single `u256` into the wide representation.
public fun from_u256(value: u256): U512 {
    U512 { hi: 0, lo: value }
}

/// Accessor for the high 256 bits.
public fun hi(value: &U512): u256 {
    value.hi
}

/// Accessor for the low 256 bits.
public fun lo(value: &U512): u256 {
    value.lo
}

/// Multiply two `u256` integers and return the full 512-bit product using cross-limb accumulation.
///
/// We split both operands into 128-bit halves and compute the four partial products:
/// `p0 = a_lo * b_lo`, `p1 = a_lo * b_hi`, `p2 = a_hi * b_lo`, `p3 = a_hi * b_hi`. Conceptually
/// every bit of the final 512-bit result sits on one of the diagonals of this 2×2 partial-product
/// matrix. We therefore combine the results diagonal-by-diagonal:
///
/// - The lowest limb comes directly from `p0`'s low half.
/// - The second limb sums `p0`'s high half with the low halves of `p1` and `p2`, propagating the
///   carry to the next diagonal.
/// - The third limb adds `p1`'s and `p2`'s high halves plus `p3`'s low half and the carry we just
///   produced.
/// - The top limb adds `p3`'s high half plus any remaining carry.
///
/// The helper `sum_three_u128` performs each diagonal addition in 256-bit space and returns the
/// resulting limb and carry-out, which we feed into the next diagonal. The final compose step packs
/// the four 128-bit outputs into two `u256` words.
public fun mul_u256(a: u256, b: u256): U512 {
    let (a_hi, a_lo) = split_u256(a);
    let (b_hi, b_lo) = split_u256(b);

    let p0 = (a_lo as u256) * (b_lo as u256);
    let p1 = (a_lo as u256) * (b_hi as u256);
    let p2 = (a_hi as u256) * (b_lo as u256);
    let p3 = (a_hi as u256) * (b_hi as u256);

    let (p0_hi, p0_lo) = split_u256(p0);
    let (p1_hi, p1_lo) = split_u256(p1);
    let (p2_hi, p2_lo) = split_u256(p2);
    let (p3_hi, p3_lo) = split_u256(p3);

    let (limb1, carry1) = sum_three_u128(p0_hi, p1_lo, p2_lo);
    let (temp2, carry2a) = sum_three_u128(p1_hi, p2_hi, p3_lo);
    let (limb2, carry2b) = sum_three_u128(temp2, carry1, 0);
    let carry_total = carry2a + carry2b;
    let (limb3, carry3) = sum_three_u128(p3_hi, carry_total, 0);
    assert!(carry3 == 0, ECarryOverflow);

    let hi = compose_u256(limb3, limb2);
    let lo = compose_u256(limb1, p0_lo);
    U512 { hi, lo }
}

/// Divide a 512-bit numerator by a 256-bit divisor.
///
/// Returns `(overflow, quotient, remainder)` where `overflow` is `true` when the
/// exact quotient does not fit in 256 bits.
public fun div_rem_u256(numerator: U512, divisor: u256): (bool, u256, u256) {
    assert!(divisor != 0, EDivideByZero);

    let mut quotient = 0u256;
    let mut remainder = zero();

    let mut i: u16 = 0;
    while (i < 512) {
        let idx = 511 - i;
        remainder = shift_left1(&remainder);
        let bit = get_bit(&numerator, idx);
        if (bit == 1) {
            remainder.lo = remainder.lo | 1;
        };

        if (ge_u256(&remainder, divisor)) {
            if (idx >= 256) {
                return (true, 0, 0)
            };
            remainder = sub_u256(remainder, divisor);
            quotient = quotient | (1u256 << (idx as u8));
        };

        i = i + 1;
    };

    assert!(remainder.hi == 0, EInvalidRemainder);
    (false, quotient, remainder.lo)
}

/// === Internal helpers ===

#[test_only]
public fun trigger_carry_overflow_for_testing() {
    let (_limb, carry) = sum_three_u128(
        std::u128::max_value!(),
        std::u128::max_value!(),
        std::u128::max_value!(),
    );
    let (_limb2, carry3) = sum_three_u128(
        std::u128::max_value!(),
        carry,
        std::u128::max_value!(),
    );
    assert!(carry3 == 0, ECarryOverflow);
}

#[test_only]
public fun trigger_underflow_for_testing() {
    let value = new(0, 0);
    let other = 1;
    let borrow = if (value.lo < other) 1 else 0;
    if (borrow == 1) {
        assert!(value.hi > 0, EUnderflow);
    }
}

#[test_only]
public fun trigger_invalid_remainder_for_testing() {
    let remainder = new(1, 0);
    assert!(remainder.hi == 0, EInvalidRemainder);
}

/// Split a `u256` into two `u128` halves (hi, lo).
fun split_u256(value: u256): (u128, u128) {
    let lo = (value & HALF_MASK) as u128;
    let hi = (value >> HALF_BITS) as u128;
    (hi, lo)
}

/// Reassemble two `u128` halves (hi, lo) into a single `u256`.
fun compose_u256(hi: u128, lo: u128): u256 {
    ((hi as u256) << HALF_BITS) | (lo as u256)
}

/// Add three `u128` values and return the lower limb plus carry-out.
fun sum_three_u128(a: u128, b: u128, c: u128): (u128, u128) {
    let total = (a as u256) + (b as u256) + (c as u256);
    (((total & HALF_MASK) as u128), ((total >> HALF_BITS) as u128))
}

/// Shift a 512-bit value left by one bit, preserving the carry between limbs.
fun shift_left1(value: &U512): U512 {
    let hi = (value.hi << 1) | (value.lo >> 255);
    let lo = value.lo << 1;
    U512 { hi, lo }
}

/// Return the bit at `idx` where index 0 is the least significant bit of the low limb.
fun get_bit(value: &U512, idx: u16): u8 {
    if (idx >= 256) {
        let shift = (idx - 256) as u8;
        ((value.hi >> shift) & 1) as u8
    } else {
        ((value.lo >> (idx as u8)) & 1) as u8
    }
}

/// Check whether `value` is greater than or equal to a `u256` scalar.
fun ge_u256(value: &U512, other: u256): bool {
    if (value.hi != 0) true else value.lo >= other
}

/// Subtract a `u256` scalar from a `U512`, handling a potential borrow from the high limb.
fun sub_u256(value: U512, other: u256): U512 {
    let new_lo = value.lo - other;
    let borrow = if (value.lo < other) 1 else 0;
    if (borrow == 1) {
        assert!(value.hi > 0, EUnderflow);
        U512 { hi: value.hi - 1, lo: new_lo }
    } else {
        U512 { hi: value.hi, lo: new_lo }
    }
}
