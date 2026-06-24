// AUTO-GENERATED - do not hand-edit.
// Source: scripts/gaussian_codegen/pdf/derive.py + scripts/gaussian_codegen/pdf/emit_coefficients.py

/// Numerator and denominator coefficients for the AAA-rational standard-normal
/// PDF approximation on the central domain `[0, 6.5]`. All values are
/// sign-magnitude pairs at WAD (`10^18`) scale, indexed in ascending power
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
    398_942_280_401_432_703, 243_682_528_979_925_695, 6_113_455_562_268_052, 38_429_708_451_226_089,
    9_276_301_209_837_938, 765_821_456_887_331, 760_313_207_992_554, 161_306_473_870_742,
    17_288_358_428_393, 969_443_049_628, 22_720_142_473,
];

const NUM_NEGS: vector<bool> = vector[
    false, true, true, false, true, true, false, true, false, true, false,
];

const DEN_MAGS: vector<u128> = vector[
    1_000_000_000_000_000_000, 610_821_521_152_797_392, 484_675_942_747_581_427,
    209_082_745_173_570_015, 94_090_575_365_160_142, 30_122_678_859_589_593, 9_227_019_395_501_040,
    2_088_314_380_007_018, 411_680_000_485_108, 51_544_534_988_644, 4_495_157_958_802,
];

const DEN_NEGS: vector<bool> = vector[
    false, true, false, true, false, true, false, true, false, true, false,
];

/// Saturation threshold |z| at the raw `10^9` scale: inputs with |z| ≥ this
/// saturate to `0` (the density has decayed below the `10^-9` output resolution)
/// instead of consulting the rational. Single source of truth for the
/// central-domain bound, consumed by `pdf::pdf_nonneg_raw`.
const MAX_Z_RAW: u128 = 6_500_000_000;

// === Package Functions ===

/// Numerator magnitudes (ascending power order).
public(package) fun pdf_num_mags(): vector<u128> { NUM_MAGS }

/// Numerator sign flags (ascending power order); index `i` paired with `pdf_num_mags()[i]`.
public(package) fun pdf_num_negs(): vector<bool> { NUM_NEGS }

/// Denominator magnitudes (ascending power order).
public(package) fun pdf_den_mags(): vector<u128> { DEN_MAGS }

/// Denominator sign flags (ascending power order); index `i` paired with `pdf_den_mags()[i]`.
public(package) fun pdf_den_negs(): vector<bool> { DEN_NEGS }

/// Saturation threshold |z| at the raw `10^9` scale (`6_500_000_000`).
public(package) fun max_z_raw(): u128 { MAX_Z_RAW }
