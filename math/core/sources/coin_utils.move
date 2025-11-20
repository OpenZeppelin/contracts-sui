module openzeppelin_math::coin_utils;

// === Errors ===

/// Value cannot be safely cast to `u64` (exceeds `std::u64::max_value!()`).
#[error(code = 0)]
const ESafeDowncastOverflowedInt: vector<u8> = b"Value cannot be represented as u64";

/// Decimals value is invalid (must be <= 24).
#[error(code = 1)]
const EInvalidDecimals: vector<u8> = b"Decimals value is invalid (must be <= 24)";

// === Constants ===

/// Maximum decimals supported for cross-chain transfers.
/// Covers all known real-world tokens with a safety margin.
const MAX_DECIMALS: u8 = 24;

// === Public Functions ===

/// Downcast a `u256` balance to `u64`, handling decimal scaling.
///
/// This function converts token amounts between different decimal precisions,
/// preserving economic value while fitting within `u64` constraints.
///
/// # Arguments
///
/// * `raw_amount` - The original balance (e.g., from Ethereum with 18 decimals).
/// * `raw_decimals` - Source chain decimal places (must be <= 24).
/// * `scaled_decimals` - Target decimal places (must be <= 24, typically 6-9 for Sui).
///
/// # Returns
///
/// The scaled balance as u64
///
/// # Aborts
///
/// * `EInvalidDecimals` - If decimals are greater than `MAX_DECIMALS`.
/// * `ESafeDowncastOverflowedInt` - If scaled amount exceeds `std::u64::max_value!()`.
///
/// # Examples
///
/// ```
/// // Ethereum: 1 token with 18 decimals = 1000000000000000000
/// // Sui: 1 token with 9 decimals = 1000000000
/// let sui_amount = safe_downcast_balance(1000000000000000000, 18, 9);
/// assert!(sui_amount == 1000000000, 0);
/// ```
public fun safe_downcast_balance(raw_amount: u256, raw_decimals: u8, scaled_decimals: u8): u64 {
    // Validate decimal ranges.
    validate_decimals(raw_decimals, scaled_decimals);

    let scaled_amount = scale_amount(raw_amount, raw_decimals, scaled_decimals);

    // Verify it fits in `u64`.
    assert!(scaled_amount <= (std::u64::max_value!() as u256), ESafeDowncastOverflowedInt);

    (scaled_amount as u64)
}

/// Upcast a `u64` balance to `u256`, handling decimal scaling.
///
/// This function converts token amounts from different decimal precisions, preserving economic value.
///
/// # Arguments
///
/// * `amount` - The balance in `u64`.
/// * `source_decimals` - Source decimal places (must be <= 24, typically 6-9 for Sui).
/// * `target_decimals` - Target decimal places (must be <= 24, e.g., 18 for Ethereum).
///
/// # Returns
///
/// The scaled balance as `u256`.
///
/// # Aborts
///
/// * `EInvalidDecimals` - If decimals are greater than `MAX_DECIMALS`.
///
/// # Examples
///
/// ```
/// // Sui: 1 token with 9 decimals = 1000000000
/// // Ethereum: 1 token with 18 decimals = 1000000000000000000
/// let eth_amount = safe_upcast_balance(1000000000, 9, 18);
/// assert!(eth_amount == 1000000000000000000, 0);
/// ```
public fun safe_upcast_balance(amount: u64, source_decimals: u8, target_decimals: u8): u256 {
    // Validate decimal ranges.
    validate_decimals(source_decimals, target_decimals);

    let amount_u256 = (amount as u256);

    scale_amount(amount_u256, source_decimals, target_decimals)
}

/// Internal helper to scale an amount between different decimal precisions.
///
/// # Arguments
///
/// * `amount` - The amount to scale (as `u256`).
/// * `source_decimals` - Current decimal precision.
/// * `target_decimals` - Desired decimal precision.
///
/// # Returns
///
/// The scaled amount preserving economic value.
///
/// # Examples
///
/// * Scaling up: amount=1000000, source=6, target=9 → 1000000000.
/// * Scaling down: amount=1000000000, source=9, target=6 → 1000000.
/// * Same: amount=1000000000, source=9, target=9 → 1000000000.
fun scale_amount(amount: u256, source_decimals: u8, target_decimals: u8): u256 {
    // Fast path: same decimals, no scaling needed.
    if (source_decimals == target_decimals) {
        return amount
    };

    if (target_decimals > source_decimals) {
        // Scale up: multiply by 10^(decimal_diff) to increase precision.
        let decimal_diff = target_decimals - source_decimals;
        amount * std::u256::pow(10, decimal_diff)
    } else {
        // Scale down: divide by 10^(decimal_diff) to reduce precision.
        let decimal_diff = source_decimals - target_decimals;
        amount / std::u256::pow(10, decimal_diff)
    }
}

/// Validate that both decimal values are within acceptable range.
///
/// This function validates both decimal values in a single call for efficiency.
/// If either value exceeds `MAX_DECIMALS`, the function aborts with `EInvalidDecimals`.
///
/// # Aborts
///
/// Aborts with `EInvalidDecimals` if either decimal exceeds `MAX_DECIMALS`.
fun validate_decimals(decimal_a: u8, decimal_b: u8) {
    assert!(decimal_a <= MAX_DECIMALS, EInvalidDecimals);
    assert!(decimal_b <= MAX_DECIMALS, EInvalidDecimals);
}
