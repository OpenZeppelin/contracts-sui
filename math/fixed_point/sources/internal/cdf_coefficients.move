// AUTO-GENERATED - do not hand-edit.
// Source: scripts/gaussian_codegen/cdf/derive.py + scripts/gaussian_codegen/cdf/emit_coefficients.py

/// Numerator and denominator coefficients for the generated standard-normal
/// CDF rational on `[0, 6.109410205]`. All values are
/// sign-magnitude pairs at the CDF accumulation scale (`10^36`), indexed in
/// ascending power order (index 0 is the constant term).
///
/// Accessors return the underlying `vector<u128>` / `vector<bool>` constants so
/// callers can bind them to a local once per CDF evaluation and index locally
/// inside the Horner loop - avoiding a fresh constant load on every iteration.
///
/// See `cdf` for the consumer API. This module is regenerated from the pipeline
/// in `scripts/gaussian_codegen/cdf/`; do not hand-edit.
module openzeppelin_fp_math::cdf_coefficients;

// === Constants ===

const NUM_MAGS: vector<u128> = vector[
    499_999_999_931_627_600_000_000_000_000_000_000, 201_344_633_657_689_930_000_000_000_000_000_000,
    18_142_911_236_019_663_000_000_000_000_000_000, 13_415_870_988_773_860_000_000_000_000_000_000,
    11_356_372_246_199_778_000_000_000_000_000_000, 662_256_861_047_578_100_000_000_000_000_000,
    110_013_502_156_884_070_000_000_000_000_000, 296_583_963_510_674_570_000_000_000_000_000,
    53_171_864_774_407_530_000_000_000_000_000, 8_767_949_922_896_122_000_000_000_000_000,
];

const NUM_NEGS: vector<bool> = vector[
    false, false, true, false, false, true, true, false, true, false,
];

const DEN_MAGS: vector<u128> = vector[
    1_000_000_000_000_000_000_000_000_000_000_000_000,
    395_195_302_227_244_360_000_000_000_000_000_000, 279_034_566_289_613_500_000_000_000_000_000_000,
    62_826_204_733_947_440_000_000_000_000_000_000, 20_293_781_568_698_408_000_000_000_000_000_000,
    376_473_797_332_801_000_000_000_000_000_000, 353_454_429_138_273_050_000_000_000_000_000,
    330_479_433_760_428_200_000_000_000_000_000, 55_345_973_632_131_670_000_000_000_000_000,
    8_824_023_536_977_782_000_000_000_000_000,
];

const DEN_NEGS: vector<bool> = vector[
    false, true, false, true, false, true, true, false, true, false,
];

/// Saturation threshold |z| at the raw `10^9` scale: inputs with |z| ≥ this
/// saturate to the endpoint (0 for negative z, 10^9 for positive z) instead of
/// consulting the rational. Single source of truth for the central-domain
/// bound, consumed by `cdf::cdf_nonneg_raw`.
const MAX_Z_RAW: u128 = 6_109_410_205;

// === Package Functions ===

/// Numerator magnitudes (ascending power order).
public(package) fun cdf_num_mags(): vector<u128> { NUM_MAGS }

/// Numerator sign flags (ascending power order); index `i` paired with `cdf_num_mags()[i]`.
public(package) fun cdf_num_negs(): vector<bool> { NUM_NEGS }

/// Denominator magnitudes (ascending power order).
public(package) fun cdf_den_mags(): vector<u128> { DEN_MAGS }

/// Denominator sign flags (ascending power order); index `i` paired with `cdf_den_mags()[i]`.
public(package) fun cdf_den_negs(): vector<bool> { DEN_NEGS }

/// Saturation threshold |z| at the raw `10^9` scale (`6_109_410_205`).
public(package) fun max_z_raw(): u128 { MAX_Z_RAW }
