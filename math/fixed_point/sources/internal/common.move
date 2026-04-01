/// Shared helpers for fixed-point package-wide constants and conversions.
///
/// The public `ud30x9` and `sd29x9` modules intentionally expose low-level
/// `wrap`/`unwrap` APIs over raw scaled representations. Conversion helpers
/// live separately and reuse the constants in this module to keep scale-aware
/// bounds, sign handling, and terminology consistent across the package.
module openzeppelin_fp_math::common;

/// Decimal scale used by all fixed-point types in this package.
const SCALE: u128 = 1_000_000_000; // 10^9

/// Maximum positive raw magnitude representable by `SD29x9`.
const MAX_SD29X9_MAGNITUDE: u128 = 0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF; // 2^127 - 1

/// Most-negative raw two's-complement value representable by `SD29x9`.
const MIN_SD29X9_VALUE: u128 = 0x8000_0000_0000_0000_0000_0000_0000_0000; // -2^127 in two's complement

/// Sign bit used by the `SD29x9` two's-complement representation.
const SIGN_BIT: u128 = 1u128 << 127;

/// Returns the raw fixed-point scale shared by `UD30x9` and `SD29x9`.
///
/// #### Returns
/// - The `10^9` scale factor used to encode one whole unit.
public(package) fun scale(): u128 {
    SCALE
}

/// Returns the raw fixed-point scale as `u256`.
///
/// #### Returns
/// - The `10^9` scale factor promoted to `u256`.
public(package) fun scale_u256(): u256 {
    SCALE as u256
}

/// Returns the sign bit used by `SD29x9`.
///
/// #### Returns
/// - The `1 << 127` bit mask.
public(package) fun sign_bit(): u128 {
    SIGN_BIT
}

/// Returns the maximum positive raw magnitude representable by `SD29x9`.
///
/// #### Returns
/// - `2^127 - 1`.
public(package) fun max_sd29x9_magnitude(): u128 {
    MAX_SD29X9_MAGNITUDE
}

/// Returns the most-negative raw value representable by `SD29x9`.
///
/// #### Returns
/// - The two's-complement encoding of `-2^127`.
public(package) fun min_sd29x9_value(): u128 {
    MIN_SD29X9_VALUE
}

/// Returns the largest whole unsigned integer that can be converted into
/// `UD30x9` without overflowing after scaling by `10^9`.
///
/// #### Returns
/// - `floor(u128::MAX / 10^9)`.
public(package) fun max_ud30x9_whole(): u128 {
    (std::u128::max_value!()) / SCALE
}

/// Returns the largest whole-magnitude integer that can be converted into
/// `SD29x9` without overflowing after scaling by `10^9`.
///
/// This bound applies to both positive and negative whole numbers. Because
/// `SD29x9` stores values in signed two's-complement form, negative whole
/// conversions accept a magnitude plus a sign flag instead of a native signed
/// integer input.
///
/// #### Returns
/// - `floor((2^127 - 1) / 10^9)`.
public(package) fun max_sd29x9_whole(): u128 {
    MAX_SD29X9_MAGNITUDE / SCALE
}
