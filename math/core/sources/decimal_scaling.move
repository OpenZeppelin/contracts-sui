module openzeppelin_math::decimal_scaling;

// === Errors ===

/// Value cannot be safely cast to `u64` (exceeds `std::u64::max_value!()`).
#[error(code = 0)]
const ESafeDowncastOverflowedInt: vector<u8> = b"Value cannot be represented as u64";

/// Decimals value is invalid (must be <= 24).
#[error(code = 1)]
const EInvalidDecimals: vector<u8> = b"Decimals value is invalid (must be <= 24)";

// === Constants ===

/// Maximum decimals supported for cross-chain transfers.
///
/// Set to 24 to cover all known blockchain token standards with safety margin:
/// - Ethereum/EVM chains: typically 18 decimals (ETH, most ERC-20 tokens)
/// - Sui/Move chains: typically 6-9 decimals
/// - Stablecoins: typically 6 decimals (USDC, USDT)
/// - Bitcoin: effectively 8 decimals (satoshi)
/// - Solana: typically 9 decimals
///
/// The value 24 provides significant headroom beyond the practical maximum
/// of 18-19 decimals used in production systems.
const MAX_DECIMALS: u8 = 24;

// === Public Functions ===

/// Downcast a `u256` balance to `u64`, handling decimal scaling.
///
/// This function converts token amounts between different decimal precisions,
/// preserving economic value while fitting within `u64` constraints.
///
/// **IMPORTANT: When scaling down (`source_decimals` > `target_decimals`), this
/// function TRUNCATES fractional parts rather than rounding.** For example:
/// - 1.999 tokens → 1 token (NOT 2)
/// - 0.999 tokens → 0 tokens (NOT 1)
///
/// This behavior is standard in blockchain systems to prevent inflation but
/// means precision is permanently lost when scaling to lower decimal places.
///
/// # Arguments
///
/// * `raw_amount` - The original balance (e.g., from Ethereum with 18 decimals).
/// * `source_decimals` - Source chain decimal places (must be <= 24).
/// * `target_decimals` - Target decimal places (must be <= 24, typically 6-9 for Sui).
///
/// # Returns
///
/// The scaled balance as u64
///
/// # Aborts
///
/// * `EInvalidDecimals` - If either decimal value exceeds `MAX_DECIMALS` (24).
/// * `ESafeDowncastOverflowedInt` - If scaled amount exceeds `std::u64::max_value!()`.
///
/// # Examples
///
/// ```
/// // Scaling down: Ethereum to Sui (precision preserved for clean values)
/// // 1.0 token with 18 decimals = 1000000000000000000
/// // 1.0 token with 9 decimals = 1000000000
/// let sui_amount = safe_downcast_balance(1000000000000000000, 18, 9);
/// assert!(sui_amount == 1000000000, 0);
///
/// // Scaling down with truncation (fractional part lost)
/// // 1.999999999 tokens with 9 decimals = 1999999999
/// // Scaled to 0 decimals = 1 (NOT 2 - truncates, does not round)
/// let truncated = safe_downcast_balance(1999999999, 9, 0);
/// assert!(truncated == 1, 0);
///
/// // Scaling up: Sui to Ethereum (no precision loss)
/// // 1.0 token with 9 decimals = 1000000000
/// // 1.0 token with 18 decimals = 1000000000000000000
/// let eth_amount = safe_downcast_balance(1000000000, 9, 18);
/// assert!(eth_amount == 1000000000000000000, 0);
/// ```
public fun safe_downcast_balance(raw_amount: u256, source_decimals: u8, target_decimals: u8): u64 {
    // Validate decimal ranges.
    validate_decimals(source_decimals, target_decimals);

    let scaled_amount = scale_amount(raw_amount, source_decimals, target_decimals);

    // Verify it fits in `u64`.
    assert!(scaled_amount <= (std::u64::max_value!() as u256), ESafeDowncastOverflowedInt);

    scaled_amount as u64
}

/// Upcast a `u64` balance to `u256`, handling decimal scaling.
///
/// This function converts token amounts from different decimal precisions,
/// preserving economic value.
///
/// **IMPORTANT: When scaling down (source_decimals > target_decimals), this
/// function TRUNCATES fractional parts.** See `safe_downcast_balance` for details
/// on truncation behavior.
///
/// When scaling up, precision is preserved perfectly. When scaling down,
/// the fractional part is permanently lost (truncated, not rounded).
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
/// * `EInvalidDecimals` - If either decimal value exceeds `MAX_DECIMALS` (24).
///
/// # Examples
///
/// ```
/// // Scaling up: Sui to Ethereum (no precision loss)
/// // 1.0 token with 9 decimals = 1000000000
/// // 1.0 token with 18 decimals = 1000000000000000000
/// let eth_amount = safe_upcast_balance(1000000000, 9, 18);
/// assert!(eth_amount == 1000000000000000000, 0);
///
/// // Scaling down with truncation (fractional part lost)
/// // 1.999 tokens with 9 decimals = 1999000000
/// // Scaled to 0 decimals = 1 (truncated)
/// let truncated = safe_upcast_balance(1999000000, 9, 0);
/// assert!(truncated == 1, 0);
/// ```
public fun safe_upcast_balance(amount: u64, source_decimals: u8, target_decimals: u8): u256 {
    // Validate decimal ranges.
    validate_decimals(source_decimals, target_decimals);
    scale_amount(amount as u256, source_decimals, target_decimals)
}

/// Internal helper to scale an amount between different decimal precisions.
///
/// # Truncation Behavior
///
/// When scaling down (source_decimals > target_decimals), this function uses
/// integer division which TRUNCATES the result. Fractional parts are discarded,
/// not rounded:
/// - 1999 / 1000 = 1 (not 2)
/// - 999 / 1000 = 0 (not 1)
///
/// This is the standard behavior in blockchain systems to prevent inflation
/// through rounding errors, but users must be aware that precision is permanently
/// lost when converting to lower decimal places.
///
/// # Arguments
///
/// * `amount` - The amount to scale (as `u256`).
/// * `source_decimals` - Current decimal precision.
/// * `target_decimals` - Desired decimal precision.
///
/// # Returns
///
/// The scaled amount preserving economic value (subject to truncation when scaling down).
///
/// # Examples
///
/// * Scaling up: amount=1000000, source=6, target=9 → 1000000000 (no precision loss).
/// * Scaling down: amount=1000000000, source=9, target=6 → 1000000 (fractional part lost).
/// * Same decimals: amount=1000000000, source=9, target=9 → 1000000000 (no conversion).
/// * Truncation example: amount=1999000000, source=9, target=0 → 1 (not 2).
fun scale_amount(amount: u256, source_decimals: u8, target_decimals: u8): u256 {
    // Fast path: same decimals, no scaling needed.
    if (source_decimals == target_decimals) {
        amount
    } else if (target_decimals > source_decimals) {
        // Scale up: multiply by 10^(decimals_diff) to increase precision.
        // No precision loss when scaling up.
        let decimals_diff = target_decimals - source_decimals;
        amount * std::u256::pow(10, decimals_diff)
    } else {
        // Scale down: divide by 10^(decimals_diff) to reduce precision.
        // IMPORTANT: Integer division truncates fractional parts.
        // Example: 1999 / 1000 = 1 (truncated, not rounded to 2)
        let decimals_diff = source_decimals - target_decimals;
        amount / std::u256::pow(10, decimals_diff)
    }
}

/// Validate that both decimal values are within acceptable range.
///
/// This function validates both decimal values in a single call for efficiency.
/// Both values must be <= `MAX_DECIMALS` (24). If either value exceeds this limit,
/// the function aborts with `EInvalidDecimals`.
///
/// # Arguments
///
/// * `decimals_a` - First decimal value to validate.
/// * `decimals_b` - Second decimal value to validate.
///
/// # Aborts
///
/// Aborts with `EInvalidDecimals` if either decimal exceeds `MAX_DECIMALS`.
fun validate_decimals(decimals_a: u8, decimals_b: u8) {
    assert!(decimals_a <= MAX_DECIMALS, EInvalidDecimals);
    assert!(decimals_b <= MAX_DECIMALS, EInvalidDecimals);
}
