// AUTO-GENERATED - do not hand-edit.
// Source: scripts/gaussian_codegen/inverse_cdf/derive.py + scripts/gaussian_codegen/inverse_cdf/emit_coefficients.py

/// Numerator and denominator coefficients for the two-region standard-normal
/// quantile (inverse CDF) rational on the upper half
/// `p ∈ [0.5, 1)`. All values are sign-magnitude pairs at WAD (`10^18`) scale,
/// indexed in ascending power order (index 0 is the constant term).
///
/// - `CENTRAL_*`: the rational in `u = p - 0.5`, used for
///   `p < CENTRAL_THRESHOLD`.
/// - `TAIL_*`: the rational in `r = sqrt(-2 * ln(1 - p))`, used for
///   `p >= CENTRAL_THRESHOLD`; the change of variable linearizes the tail so a
///   low-degree rational stays well-conditioned where a single rational in `p`
///   would underflow. The evaluator supplies `r` directly at WAD scale.
///
/// Accessors return the underlying `vector<u128>` / `vector<bool>` constants so
/// callers can bind them to a local once per evaluation and index locally inside
/// the Horner loop - avoiding a fresh constant load on every iteration.
///
/// See `inverse_cdf` for the consumer API. This module is regenerated from the
/// fits in `scripts/gaussian_codegen/inverse_cdf/`; do not hand-edit.
module openzeppelin_fp_math::inverse_cdf_coefficients;

// === Constants ===

const CENTRAL_NUM_MAGS: vector<u128> = vector[
    83_972_306, 2_506_628_254_154_931_000, 16_367_705_161_149_370_000, 33_543_029_084_694_709_000,
    4_664_071_409_401_003_600, 66_749_240_883_508_804_000, 76_683_461_193_510_112_000,
    20_089_216_772_437_418_000, 4_626_216_279_451_577_800,
];

const CENTRAL_NUM_NEGS: vector<bool> = vector[
    false, false, true, false, true, true, false, true, true,
];

const CENTRAL_DEN_MAGS: vector<u128> = vector[
    1_000_000_000_000_000_000, 6_529_770_225_105_169_200, 12_334_556_167_734_767_000,
    4_976_833_894_244_148_100, 41_843_124_728_576_022_000, 40_368_251_986_910_948_000,
    1_464_143_571_324_117_500, 16_255_923_057_278_231_000, 4_340_275_740_493_888_500,
];

const CENTRAL_DEN_NEGS: vector<bool> = vector[
    false, true, false, false, true, false, false, true, false,
];

const TAIL_NUM_MAGS: vector<u128> = vector[
    3_094_339_710_561_733_600, 6_207_376_019_943_557_000, 3_075_018_098_279_669_000,
    3_306_509_139_927_573_000, 386_804_656_519_127_650,
];

const TAIL_NUM_NEGS: vector<bool> = vector[true, true, false, false, false];

const TAIL_DEN_MAGS: vector<u128> = vector[
    1_000_000_000_000_000_000, 4_664_193_128_006_789_000, 3_324_846_871_342_176_000,
    386_441_302_093_894_930, 4_952_204_793_303,
];

const TAIL_DEN_NEGS: vector<bool> = vector[false, false, false, false, false];

/// Probability split between the central and tail rationals, at the raw `10^9`
/// scale: inputs with `p < this` use the central fit (in `u = p - 0.5`), inputs
/// with `p >= this` use the tail fit (in `r = sqrt(-2 ln(1 - p))`).
const CENTRAL_THRESHOLD_RAW: u128 = 975_000_000;

/// Output saturation clamp `|z|` at the raw `10^9` scale: `inverse_cdf(1)` (and,
/// reflected, `inverse_cdf(0)`) returns this instead of the unrepresentable
/// `±∞`. Matches the CDF domain bound so `cdf`/`inverse_cdf` agree at the corner.
const MAX_Z_RAW: u128 = 6_300_000_000;

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

/// Output saturation clamp `|z|` at the raw `10^9` scale (`6_300_000_000`).
public(package) fun max_z_raw(): u128 { MAX_Z_RAW }
