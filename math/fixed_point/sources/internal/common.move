/// Shared helpers for fixed-point package-wide constants and conversions.
///
/// The public `ud30x9` and `sd29x9` modules intentionally expose low-level
/// `wrap`/`unwrap` APIs over raw scaled representations. Conversion helpers
/// live separately and reuse the constants in this module to keep scale-aware
/// bounds, sign handling, and terminology consistent across the package.
module openzeppelin_fp_math::common;

/// Returns the raw fixed-point scale shared by `UD30x9` and `SD29x9`.
///
/// #### Returns
/// - The `10^9` scale factor used to encode one whole unit.
public(package) macro fun scale(): u128 {
    1_000_000_000 // 10^9
}

/// Returns the raw fixed-point scale as `u256`.
///
/// #### Returns
/// - The `10^9` scale factor promoted to `u256`.
public(package) macro fun scale_u256(): u256 {
    1_000_000_000u256 // 10^9
}

/// Returns the sign bit used by `SD29x9`.
///
/// #### Returns
/// - The `1 << 127` bit mask.
public(package) macro fun sign_bit(): u128 {
    1u128 << 127
}

/// Returns the maximum positive raw magnitude representable by `SD29x9`.
///
/// #### Returns
/// - `2^127 - 1`.
public(package) macro fun max_sd29x9_magnitude(): u128 {
    0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF // 2^127 - 1
}

/// Returns the most-negative raw value representable by `SD29x9`.
///
/// #### Returns
/// - The two's-complement encoding of `-2^127`.
public(package) macro fun min_sd29x9_value(): u128 {
    0x8000_0000_0000_0000_0000_0000_0000_0000 // -2^127 in two's complement
}

/// Returns the largest whole unsigned integer that can be converted into
/// `UD30x9` without overflowing after scaling by `10^9`.
///
/// #### Returns
/// - `floor(u128::MAX / 10^9)`.
public(package) macro fun max_ud30x9_whole(): u128 {
    340_282_366_920_938_463_463_374_607_431 // floor(u128::MAX / 10^9)
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
public(package) macro fun max_sd29x9_whole(): u128 {
    170_141_183_460_469_231_731_687_303_715 // floor((2^127 - 1) / 10^9)
}
