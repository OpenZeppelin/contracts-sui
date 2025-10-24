module openzeppelin_math::rounding;

/// Enumerates the supported rounding strategies for `mul_div`.
/// - Down: Always round the truncated result down towards zero.
/// - Up: Always round the truncated result up (ceiling).
/// - Nearest: Round to the closest integer, breaking ties by rounding up.
public enum RoundingMode has copy, drop {
    Down,
    Up,
    Nearest,
}

/// Helper returning the enum value for downward rounding.
public fun down(): RoundingMode { RoundingMode::Down }

/// Helper returning the enum value for upward rounding.
public fun up(): RoundingMode { RoundingMode::Up }

/// Helper returning the enum value for nearest rounding (ties round up).
public fun nearest(): RoundingMode { RoundingMode::Nearest }
