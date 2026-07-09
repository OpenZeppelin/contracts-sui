"""Single source of truth for the scales and domain bound shared across the
codegen pipeline.

These values must stay in lock-step with the on-chain Move code
(`sources/internal/{cdf,pdf}.move`, `sources/internal/horner.move`, and the
generated `{cdf,pdf}_coefficients.move`).
Keeping them here means a change to a domain or a scale is a one-line
edit rather than a hunt across the scripts in several different scales.

The raw-scale constants are *derived* from `MAX_Z` via `Decimal` so they cannot
drift out of sync with the decimal bound.
"""
from __future__ import annotations

from decimal import Decimal

# --- Scales -----------------------------------------------------------------

WAD = 10**18
"""Generic Horner-accumulation scale (`10^18`) - the default for the shared
sign-magnitude primitives (`shared/arithmetic.py`) and the scale their primitive
unit tests run at. Individual gaussian families accumulate finer; see `CDF_WAD` /
`PDF_WAD`."""

CDF_WAD = 10**36
"""CDF Horner-accumulation scale (`10^36` = `SCALE_DECIMAL**4`). At `10^18` each
Horner step's floor-truncation discards up to ~`1.9e-5` user-facing ULP, which in
the far tail exceeds Φ's true per-step increment and lets neighboring outputs
invert - a quantization artifact, not a property of the continuous rational (which
is provably monotone). Accumulating at `10^36` drops that noise far below the
smallest in-domain increment, so the quantized output is strictly monotone. Free
at runtime (the arithmetic is already `u256`); the rescaled coefficients still fit
`u128` (~120/128 bits) and the peak `u256` Horner product stays ~10 bits under
`2^256` on the clamped domain (asserted by `cdf/validate.check_overflow_margin`)."""

PDF_WAD = 10**36
"""PDF Horner-accumulation scale (`10^36`). Same rationale as `CDF_WAD`: guarantees
the density is monotone non-increasing in `|z|`. Overflow headroom is tighter than
the CDF (degree 10 + wider tail leave ~8 bits under `2^256`), so the overflow gate
is load-bearing here."""

SCALE_DECIMAL = 10**9
"""UD30x9 / SD29x9 raw scale (`10^9`) - the type's on-chain representation."""

DPS = 100
"""mpmath decimal places of precision for the Φ oracle, well in excess of WAD."""

# --- CDF domain bound -------------------------------------------------------

MAX_Z = "6.109410205"
"""Upper bound of the CDF central domain, as an exact decimal string - the
smallest `z` whose Φ rounds to `1.000000000` at the `10^9` scale (Φ(z) ≥
1 − 0.5e-9, i.e. `1 − Φ ≤ half a ULP`). Verified against a 100-dps mpmath oracle:
Φ(6.109410205) rounds to `1_000_000_000` and Φ(6.109410204) rounds to
`999_999_999`. Serves as both the AAA fit domain and the on-chain saturation
bound - inputs with `|z| >= MAX_Z` saturate to the endpoint (`0` for negative z,
`10^9` for positive z) instead of consulting the rational - so the fit spends no
approximation budget on the dead tail beyond here (where the correctly-rounded
answer is the constant `1`)."""

_MAX_Z = Decimal(MAX_Z)

MAX_Z_RAW = int(_MAX_Z * SCALE_DECIMAL)
"""`MAX_Z` at the UD30x9 raw scale (`10^9`) - i.e. `6_109_410_205`. Emitted as
the on-chain `cdf_coefficients::MAX_Z_RAW` (the single saturation source of
truth, consumed by `cdf::cdf_nonneg_raw`)."""

MAX_Z_RAW_WAD = int(_MAX_Z * WAD)
"""`MAX_Z` at the generic `WAD` scale (`10^18`) - i.e. `6_109_410_205_000_000_000`.
Kept for cross-scale consistency checks; the on-chain CDF accumulates at `CDF_WAD`
and the saturation bound is the raw-scale `MAX_Z_RAW` above."""

# --- PDF domain bound -------------------------------------------------------

PDF_MAX_Z = "6.402729806"
"""Upper bound of the PDF central domain, as an exact decimal string - the
smallest `z` whose φ rounds to `0` at the `10^9` scale (φ(z) < 0.5e-9). Verified
against a 100-dps mpmath oracle: φ(6.402729806) rounds to `0` and φ(6.402729805)
rounds to `1`. Serves as both the AAA fit domain and the on-chain saturation-to-0
bound. Wider than the CDF bound because φ's tail reaches the round-to-zero point
later than Φ reaches saturation."""

_PDF_MAX_Z = Decimal(PDF_MAX_Z)

PDF_MAX_Z_RAW = int(_PDF_MAX_Z * SCALE_DECIMAL)
"""`PDF_MAX_Z` at the UD30x9 raw scale (`10^9`) - i.e. `6_402_729_806`. Emitted as
the on-chain `pdf_coefficients::MAX_Z_RAW` (the saturation source of truth,
consumed by `pdf::pdf_nonneg_raw`)."""

# --- Inverse-CDF (quantile) domain / range bounds -------------------------------

HALF_RAW = SCALE_DECIMAL // 2
"""`Φ⁻¹(0.5) = 0` input probability at the raw `10^9` scale - i.e. `500_000_000`.
The lower bound of the quantile's representable upper half: `inverse_cdf` on
`UD30x9` accepts `p ∈ [0.5, 1]`, and the signed `SD29x9` variant reflects `p < 0.5`
via `Φ⁻¹(p) = −Φ⁻¹(1−p)`."""

INVERSE_CDF_MAX_Z = "6.3"
"""Output saturation clamp for the quantile, as an exact decimal string: the
largest `|z|` `inverse_cdf` returns. Deliberately equal to the CDF domain bound
`MAX_Z` so the two functions agree at the corner (`cdf(6.3)` saturates to `1`, so
`inverse_cdf(1)` saturates to `6.3`). The deepest real value at `10^9` input
resolution is `Φ⁻¹(1 − 10⁻⁹) ≈ 5.998`, so `6.3` is only ever returned for the
exact endpoint `p = 1`."""

_INVERSE_CDF_MAX_Z = Decimal(INVERSE_CDF_MAX_Z)

INVERSE_CDF_MAX_Z_RAW = int(_INVERSE_CDF_MAX_Z * SCALE_DECIMAL)
"""`INVERSE_CDF_MAX_Z` at the raw `10^9` scale - i.e. `6_300_000_000`. Emitted as
the on-chain `inverse_cdf_coefficients::MAX_Z_RAW` (the output saturation source of
truth, consumed by `inverse_cdf::inverse_cdf_upper_raw`)."""

INVERSE_CDF_SPLIT = "0.975"
"""Probability breakpoint between the two rational fits, as an exact decimal
string. `p < SPLIT` uses the central rational in `u = p − 0.5`; `p ≥ SPLIT` uses
the tail rational in `r = sqrt(−2·ln(1 − p))`. This is the classic Acklam/AS241
central-vs-tail split point."""

_INVERSE_CDF_SPLIT = Decimal(INVERSE_CDF_SPLIT)

INVERSE_CDF_SPLIT_RAW = int(_INVERSE_CDF_SPLIT * SCALE_DECIMAL)
"""`INVERSE_CDF_SPLIT` at the raw `10^9` scale - i.e. `975_000_000`. Emitted as the
on-chain `inverse_cdf_coefficients::CENTRAL_THRESHOLD_RAW`."""

INVERSE_CDF_TAIL_MIN_P = "1e-9"
"""Smallest tail probability the fit must cover: one raw `10^9` ULP away from the
`0`/`1` endpoints. Beyond this the input cannot get closer to the endpoint in the
`UD30x9`/`SD29x9` representation, so the fit domain stops here and `p = 1` (and,
reflected, `p = 0`) saturate to `±MAX_Z`."""
