// AUTO-GENERATED - do not hand-edit.
// Source: scripts/gaussian_codegen/pdf/derive.py + scripts/gaussian_codegen/pdf/emit_coefficients.py

/// Numerator and denominator coefficients for the generated standard-normal
/// PDF rational on `[0, 6.402729806]`. All values are
/// sign-magnitude pairs at the PDF accumulation scale (`10^36`), indexed in
/// ascending power order (index 0 is the constant term).
///
/// Accessors return the underlying `vector<u128>` / `vector<bool>` constants so
/// callers can bind them to a local once per PDF evaluation and index locally
/// inside the Horner loop - avoiding a fresh constant load on every iteration.
///
/// See `pdf` for the consumer API. This module is regenerated from the pipeline
/// in `scripts/gaussian_codegen/pdf/`; do not hand-edit.
module openzeppelin_fp_math::pdf_coefficients;

// === Constants ===

const NUM_MAGS: vector<u128> = vector[
    398_942_280_318_649_030_000_000_000_000_000_000, 244_930_817_207_461_900_000_000_000_000_000_000,
    6_734_387_499_516_681_000_000_000_000_000_000, 39_443_732_498_613_396_000_000_000_000_000_000,
    9_496_590_782_466_802_000_000_000_000_000_000, 858_375_808_929_000_000_000_000_000_000_000,
    818_645_604_294_010_300_000_000_000_000_000, 174_755_768_053_822_840_000_000_000_000_000,
    18_920_164_717_078_317_000_000_000_000_000, 1_073_484_913_859_684_800_000_000_000_000,
    25_483_531_952_465_393_000_000_000_000,
];

const NUM_NEGS: vector<bool> = vector[
    false, true, true, false, true, true, false, true, false, true, false,
];

const DEN_MAGS: vector<u128> = vector[
    1_000_000_000_000_000_000_000_000_000_000_000_000,
    613_950_523_483_714_800_000_000_000_000_000_000, 483_119_590_841_909_000_000_000_000_000_000_000,
    208_106_018_186_679_230_000_000_000_000_000_000, 92_762_020_213_452_700_000_000_000_000_000_000,
    29_478_485_153_659_970_000_000_000_000_000_000, 8_906_298_306_759_586_000_000_000_000_000_000,
    1_986_272_143_327_121_700_000_000_000_000_000, 383_975_566_107_971_600_000_000_000_000_000,
    47_084_014_210_722_330_000_000_000_000_000, 4_025_680_374_252_376_400_000_000_000_000,
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
