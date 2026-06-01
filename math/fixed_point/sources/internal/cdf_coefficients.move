// AUTO-GENERATED — do not hand-edit.
// Source: codegen/cdf/derive.py + codegen/cdf/emit_coefficients.py
// Regenerated: 2026-05-09

/// Numerator and denominator coefficients for the AAA-rational standard-normal
/// CDF approximation on `[0, max_z()]`. All values are sign-magnitude pairs at
/// WAD (`10^18`) scale, indexed in ascending power order (index 0 is the
/// constant term).
///
/// Accessors return the underlying `vector<u128>` / `vector<bool>` constants so
/// callers can bind them to a local once per CDF evaluation and index locally
/// inside the Horner loop — avoiding a fresh constant load on every iteration.
///
/// See `cdf` for the consumer API. This module is regenerated from the AAA fit
/// in `codegen/cdf/`; do not hand-edit.
#[allow(implicit_const_copy)]
module openzeppelin_fp_math::cdf_coefficients;

const NUM_MAGS: vector<u128> = vector[
    500_000_000_000_000_000,
    190_807_717_061_735_534,
    18_477_727_278_488_185,
    15_046_897_503_881_893,
    10_871_372_336_577_149,
    775_678_067_926_219,
    10_553_581_641_750,
    278_046_679_204_823,
    51_956_067_695_861,
    9_138_288_955_547,
];

const NUM_NEGS: vector<bool> = vector[
    false,
    false,
    true,
    false,
    false,
    true,
    true,
    false,
    true,
    false,
];

const DEN_MAGS: vector<u128> = vector[
    1_000_000_000_000_000_000,
    416_269_127_949_675_211,
    295_179_293_486_155_403,
    72_444_870_896_004_164,
    24_192_138_702_674_457,
    1_556_994_781_007_028,
    87_710_899_979_885,
    295_740_460_136_491,
    53_227_628_287_723,
    9_172_353_790_188,
];

const DEN_NEGS: vector<bool> = vector[
    false,
    true,
    false,
    true,
    false,
    true,
    true,
    false,
    true,
    false,
];

/// Number of numerator coefficients (polynomial degree = result − 1).
const NUM_LEN: u64 = 10;

/// Number of denominator coefficients (polynomial degree = result − 1).
const DEN_LEN: u64 = 10;

/// Saturation threshold |z| at WAD scale: |z| ≥ this returns the saturated CDF
/// value (0 for negative z, 10^9 for positive z) without consulting the rational.
const MAX_Z_WAD: u128 = 6_300_000_000_000_000_000;

/// Internal arithmetic scale used by the coefficient encoding (WAD = 10^18).
const SCALE_WAD: u128 = 1_000_000_000_000_000_000;

/// Numerator magnitudes (ascending power order).
public(package) fun cdf_num_mags(): vector<u128> { NUM_MAGS }

/// Numerator sign flags (ascending power order); index `i` paired with `cdf_num_mags()[i]`.
public(package) fun cdf_num_negs(): vector<bool> { NUM_NEGS }

/// Denominator magnitudes (ascending power order).
public(package) fun cdf_den_mags(): vector<u128> { DEN_MAGS }

/// Denominator sign flags (ascending power order); index `i` paired with `cdf_den_mags()[i]`.
public(package) fun cdf_den_negs(): vector<bool> { DEN_NEGS }

/// Number of numerator coefficients.
public(package) fun cdf_num_len(): u64 { NUM_LEN }

/// Number of denominator coefficients.
public(package) fun cdf_den_len(): u64 { DEN_LEN }

/// Saturation threshold |z| at WAD scale.
public(package) fun max_z(): u128 { MAX_Z_WAD }

/// Internal arithmetic scale (WAD = 10^18).
public(package) fun scale(): u128 { SCALE_WAD }
