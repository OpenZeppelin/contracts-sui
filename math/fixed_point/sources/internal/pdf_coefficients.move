// AUTO-GENERATED - do not hand-edit.
// Source: scripts/gaussian_codegen/pdf/derive.py + scripts/gaussian_codegen/pdf/emit_coefficients.py

/// Numerator and denominator coefficients for the AAA-rational standard-normal
/// PDF approximation on the central domain `[0, 6.402729806]`. All values are
/// sign-magnitude pairs at PDF WAD (`10^36`) scale, indexed in ascending power
/// order (index 0 is the constant term).
///
/// Accessors return the underlying `vector<u128>` / `vector<bool>` constants so
/// callers can bind them to a local once per PDF evaluation and index locally
/// inside the Horner loop - avoiding a fresh constant load on every iteration.
///
/// See `pdf` for the consumer API. This module is regenerated from the AAA fit
/// in `scripts/gaussian_codegen/pdf/`; do not hand-edit.
module openzeppelin_fp_math::pdf_coefficients;

// === Constants ===

const NUM_MAGS: vector<u128> = vector[
    398_942_280_401_432_702_863_218_082_712_000_000, 242_845_591_915_512_138_341_059_407_047_000_000,
    7_515_209_832_807_452_884_244_003_304_050_000, 39_059_690_028_550_475_676_539_608_407_300_000,
    9_246_599_927_889_617_118_412_438_177_210_000, 882_317_025_523_044_149_273_120_510_895_000,
    805_072_538_317_029_935_744_293_267_827_000, 169_962_283_839_163_075_466_635_217_033_000,
    18_238_186_447_068_571_887_180_658_287_200, 1_026_030_533_040_147_957_148_494_467_040,
    24_149_847_266_550_430_844_548_792_287,
];

const NUM_NEGS: vector<bool> = vector[
    false, true, true, false, true, true, false, true, false, true, false,
];

const DEN_MAGS: vector<u128> = vector[
    1_000_000_000_000_000_000_000_000_000_000_000_000,
    608_723_630_070_529_357_412_518_780_677_000_000, 481_162_240_074_944_379_062_467_375_242_000_000,
    206_454_420_004_627_854_884_559_885_310_000_000, 92_406_895_193_707_558_364_226_155_254_400_000,
    29_358_779_982_775_302_702_265_622_337_200_000, 8_928_486_102_925_772_786_688_066_853_350_000,
    2_001_801_922_991_593_601_004_648_348_120_000, 391_838_007_846_665_825_466_191_107_571_000,
    48_645_760_468_599_333_623_318_559_121_700, 4_239_884_861_025_459_643_350_476_186_250,
];

const DEN_NEGS: vector<bool> = vector[
    false, true, false, true, false, true, false, true, false, true, false,
];

/// Saturation threshold |z| at the raw `10^9` scale: inputs with |z| ≥ this
/// saturate to `0` (the density has decayed below the `10^-9` output resolution)
/// instead of consulting the rational. Single source of truth for the
/// central-domain bound, consumed by `pdf::pdf_nonneg_raw`.
const MAX_Z_RAW: u128 = 6_402_729_806;

// === Package Functions ===

/// Numerator magnitudes (ascending power order).
public(package) fun pdf_num_mags(): vector<u128> { NUM_MAGS }

/// Numerator sign flags (ascending power order); index `i` paired with `pdf_num_mags()[i]`.
public(package) fun pdf_num_negs(): vector<bool> { NUM_NEGS }

/// Denominator magnitudes (ascending power order).
public(package) fun pdf_den_mags(): vector<u128> { DEN_MAGS }

/// Denominator sign flags (ascending power order); index `i` paired with `pdf_den_mags()[i]`.
public(package) fun pdf_den_negs(): vector<bool> { DEN_NEGS }

/// Saturation threshold |z| at the raw `10^9` scale (`6_402_729_806`).
public(package) fun max_z_raw(): u128 { MAX_Z_RAW }
