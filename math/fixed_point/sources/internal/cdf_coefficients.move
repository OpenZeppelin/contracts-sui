// AUTO-GENERATED - do not hand-edit.
// Source: scripts/gaussian_codegen/cdf/derive.py + scripts/gaussian_codegen/cdf/emit_coefficients.py

/// Numerator and denominator coefficients for the AAA-rational standard-normal
/// CDF approximation on the central domain `[0, 6.3]`. All values are
/// sign-magnitude pairs at WAD (`10^18`) scale, indexed in ascending power
/// order (index 0 is the constant term).
///
/// Accessors return the underlying `vector<u128>` / `vector<bool>` constants so
/// callers can bind them to a local once per CDF evaluation and index locally
/// inside the Horner loop - avoiding a fresh constant load on every iteration.
///
/// See `cdf` for the consumer API. This module is regenerated from the AAA fit
/// in `scripts/gaussian_codegen/cdf/`; do not hand-edit.
module openzeppelin_fp_math::cdf_coefficients;

// === Constants ===

const NUM_MAGS: vector<u128> = vector[
    500_000_000_000_000_000, 190_807_717_061_735_534, 18_477_727_278_488_185, 15_046_897_503_881_893,
    10_871_372_336_577_149, 775_678_067_926_219, 10_553_581_641_750, 278_046_679_204_823,
    51_956_067_695_861, 9_138_288_955_547,
];

const NUM_NEGS: vector<bool> = vector[
    false, false, true, false, false, true, true, false, true, false,
];

const DEN_MAGS: vector<u128> = vector[
    1_000_000_000_000_000_000, 416_269_127_949_675_211, 295_179_293_486_155_403,
    72_444_870_896_004_164, 24_192_138_702_674_457, 1_556_994_781_007_028, 87_710_899_979_885,
    295_740_460_136_491, 53_227_628_287_723, 9_172_353_790_188,
];

const DEN_NEGS: vector<bool> = vector[
    false, true, false, true, false, true, true, false, true, false,
];

/// Saturation threshold |z| at the raw `10^9` scale: inputs with |z| ≥ this
/// saturate to the endpoint (0 for negative z, 10^9 for positive z) instead of
/// consulting the rational. Single source of truth for the central-domain
/// bound, consumed by `cdf::cdf_nonneg_raw`.
const MAX_Z_RAW: u128 = 6_300_000_000;

// === Package Functions ===

/// Numerator magnitudes (ascending power order).
public(package) fun cdf_num_mags(): vector<u128> { NUM_MAGS }

/// Numerator sign flags (ascending power order); index `i` paired with `cdf_num_mags()[i]`.
public(package) fun cdf_num_negs(): vector<bool> { NUM_NEGS }

/// Denominator magnitudes (ascending power order).
public(package) fun cdf_den_mags(): vector<u128> { DEN_MAGS }

/// Denominator sign flags (ascending power order); index `i` paired with `cdf_den_mags()[i]`.
public(package) fun cdf_den_negs(): vector<bool> { DEN_NEGS }

/// Saturation threshold |z| at the raw `10^9` scale (`6_300_000_000`).
public(package) fun max_z_raw(): u128 { MAX_Z_RAW }
