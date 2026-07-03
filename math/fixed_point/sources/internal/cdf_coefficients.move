// AUTO-GENERATED - do not hand-edit.
// Source: scripts/gaussian_codegen/cdf/derive.py + scripts/gaussian_codegen/cdf/emit_coefficients.py

/// Numerator and denominator coefficients for the AAA-rational standard-normal
/// CDF approximation on the central domain `[0, 6.109410205]`. All values are
/// sign-magnitude pairs at CDF WAD (`10^36`) scale, indexed in ascending power
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
    500_000_000_000_000_000_000_000_000_000_000_000, 191_644_129_403_732_850_214_709_228_035_000_000,
    18_160_659_862_250_687_922_607_124_006_300_000, 15_010_484_919_441_066_510_195_246_818_800_000,
    10_892_663_380_406_893_693_032_944_799_700_000, 757_943_964_976_078_150_277_774_394_902_000,
    12_668_322_773_369_489_523_339_612_520_800, 278_361_733_381_861_571_098_556_526_595_000,
    51_791_945_560_809_352_460_460_089_921_100, 9_129_186_566_947_362_890_702_723_890_300,
];

const NUM_NEGS: vector<bool> = vector[
    false, false, true, false, false, true, true, false, true, false,
];

const DEN_MAGS: vector<u128> = vector[
    1_000_000_000_000_000_000_000_000_000_000_000_000,
    414_596_303_534_481_427_187_968_695_756_000_000, 294_478_714_121_507_272_445_317_888_430_000_000,
    71_958_769_476_445_545_829_126_141_312_300_000, 24_069_553_563_781_609_489_275_593_631_800_000,
    1_517_458_057_031_624_367_050_613_427_290_000, 91_313_485_467_058_927_338_625_915_439_400,
    296_025_247_214_266_612_846_004_900_738_000, 53_052_499_633_910_312_713_123_211_341_600,
    9_162_763_505_778_062_352_448_431_297_940,
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
