// AUTO-GENERATED - do not hand-edit.
// Source: scripts/gaussian_codegen/inverse_cdf/derive.py + scripts/gaussian_codegen/inverse_cdf/emit_coefficients.py

/// Numerator and denominator coefficients for the two-region AAA-rational
/// standard-normal quantile (inverse CDF) approximation on the upper half
/// `p ∈ [0.5, 1)`. All values are sign-magnitude pairs at WAD (`10^18`) scale,
/// indexed in ascending power order (index 0 is the constant term).
///
/// - `CENTRAL_*`: the rational in `u = p - 0.5`, used for `p < CENTRAL_THRESHOLD`.
/// - `TAIL_*`: the rational in `r = sqrt(-2 * ln(1 - p))`, used for
///   `p >= CENTRAL_THRESHOLD`; the change of variable linearizes the tail so a
///   low-degree rational stays well-conditioned where a single rational in `p`
///   would underflow.
///
/// Accessors return the underlying `vector<u128>` / `vector<bool>` constants so
/// callers can bind them to a local once per evaluation and index locally inside
/// the Horner loop - avoiding a fresh constant load on every iteration.
///
/// See `inverse_cdf` for the consumer API. This module is regenerated from the
/// AAA fit in `scripts/gaussian_codegen/inverse_cdf/`; do not hand-edit.
module openzeppelin_fp_math::inverse_cdf_coefficients;

// === Constants ===

const CENTRAL_NUM_MAGS: vector<u128> = vector[
    0, 2_506_628_264_469_571_620, 17_211_346_154_536_042_450, 38_745_627_415_944_943_478,
    14_903_030_082_094_174_686, 63_742_838_339_887_065_780, 89_308_112_553_821_106_169,
    33_339_199_771_642_483_787, 1_344_048_680_080_004_914,
];

const CENTRAL_NUM_NEGS: vector<bool> = vector[
    false, false, true, false, true, true, false, true, true,
];

const CENTRAL_DEN_MAGS: vector<u128> = vector[
    1_000_000_000_000_000_000, 6_866_334_200_884_751_752, 14_410_096_174_466_250_106,
    1_244_369_465_584_450_488, 42_814_553_883_204_836_105, 50_062_471_146_621_082_237,
    7_420_086_181_384_510_215, 15_126_647_579_590_311_341, 5_291_880_730_653_744_507,
];

const CENTRAL_DEN_NEGS: vector<bool> = vector[
    false, true, false, false, true, false, true, true, false,
];

const TAIL_NUM_MAGS: vector<u128> = vector[
    3_097_178_363_266_231_710, 6_247_491_208_590_211_237, 3_080_150_817_556_328_677,
    3_328_476_572_435_311_000, 390_491_396_161_536_018,
];

const TAIL_NUM_NEGS: vector<bool> = vector[true, true, false, false, false];

const TAIL_DEN_MAGS: vector<u128> = vector[
    1_000_000_000_000_000_000, 4_683_216_346_383_616_115, 3_347_053_685_424_437_559,
    390_121_875_248_616_364, 5_056_148_107_246,
];

const TAIL_DEN_NEGS: vector<bool> = vector[false, false, false, false, false];

/// Probability split between the central and tail rationals, at the raw `10^9`
/// scale: inputs with `p < this` use the central fit (in `u = p - 0.5`), inputs
/// with `p >= this` use the tail fit (in `r = sqrt(-2 ln(1 - p))`).
const CENTRAL_THRESHOLD_RAW: u128 = 975_000_000;

/// Output saturation clamp `|z|` at the raw `10^9` scale: `inverse_cdf(1)` (and,
/// reflected, `inverse_cdf(0)`) returns this instead of the unrepresentable
/// `±∞`. Equal to the CDF domain bound `cdf_coefficients::max_z_raw()` so
/// `cdf`/`inverse_cdf` agree at the corner: the quantile saturates at the
/// smallest `|z|` the CDF already resolves to exactly `1` (resp. `0`).
const MAX_Z_RAW: u128 = 6_109_410_205;

// === Package Functions ===

/// Central-region numerator magnitudes (ascending power order).
public(package) fun central_num_mags(): vector<u128> { CENTRAL_NUM_MAGS }

/// Central-region numerator sign flags; index `i` paired with `central_num_mags()[i]`.
public(package) fun central_num_negs(): vector<bool> { CENTRAL_NUM_NEGS }

/// Central-region denominator magnitudes (ascending power order).
public(package) fun central_den_mags(): vector<u128> { CENTRAL_DEN_MAGS }

/// Central-region denominator sign flags; index `i` paired with `central_den_mags()[i]`.
public(package) fun central_den_negs(): vector<bool> { CENTRAL_DEN_NEGS }

/// Tail-region numerator magnitudes (ascending power order).
public(package) fun tail_num_mags(): vector<u128> { TAIL_NUM_MAGS }

/// Tail-region numerator sign flags; index `i` paired with `tail_num_mags()[i]`.
public(package) fun tail_num_negs(): vector<bool> { TAIL_NUM_NEGS }

/// Tail-region denominator magnitudes (ascending power order).
public(package) fun tail_den_mags(): vector<u128> { TAIL_DEN_MAGS }

/// Tail-region denominator sign flags; index `i` paired with `tail_den_mags()[i]`.
public(package) fun tail_den_negs(): vector<bool> { TAIL_DEN_NEGS }

/// Central-vs-tail probability split at the raw `10^9` scale (`975_000_000`).
public(package) fun central_threshold_raw(): u128 { CENTRAL_THRESHOLD_RAW }

/// Output saturation clamp `|z|` at the raw `10^9` scale (`6_109_410_205`).
public(package) fun max_z_raw(): u128 { MAX_Z_RAW }
