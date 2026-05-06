/// Rounding strategy helpers used by the math primitives.
///
/// This module defines the `RoundingMode` enum and convenience constructors used by helpers
/// such as `mul_div`, `mul_shr`, logarithms, and square root operations across the unsigned
/// integer modules.
module openzeppelin_math::rounding;

// === Structs ===

/// Enumerates the supported rounding strategies shared by arithmetic helpers in this package.
/// - Down: Always round the truncated result down towards zero.
/// - Up: Always round the truncated result up (ceiling).
/// - Nearest: Round to the closest integer, breaking ties by rounding up.
public enum RoundingMode has copy, drop {
    Down,
    Up,
    Nearest,
}

// === Public Functions ===

/// Helper returning the enum value for downward rounding.
public fun down(): RoundingMode { RoundingMode::Down }

/// Helper returning the enum value for upward rounding.
public fun up(): RoundingMode { RoundingMode::Up }

/// Helper returning the enum value for nearest rounding (ties round up).
public fun nearest(): RoundingMode { RoundingMode::Nearest }
