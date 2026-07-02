"""Single source of truth for the scales and domain bound shared across the
codegen pipeline.

These values must stay in lock-step with the on-chain Move code
(`sources/internal/cdf.move`, `sources/internal/horner.move`, and the generated
`cdf_coefficients.move`).
Keeping them here means a change to the CDF domain or a scale is a one-line
edit rather than a hunt across four scripts in three different scales.

The raw-scale constants are *derived* from `MAX_Z` via `Decimal` so they cannot
drift out of sync with the decimal bound.
"""
from __future__ import annotations

from decimal import Decimal

# --- Scales -----------------------------------------------------------------

WAD = 10**18
"""Internal Horner-accumulation scale (`10^18`)."""

SCALE_DECIMAL = 10**9
"""UD30x9 / SD29x9 raw scale (`10^9`) - the type's on-chain representation."""

DPS = 100
"""mpmath decimal places of precision for the Φ oracle, well in excess of WAD."""

# --- CDF domain bound -------------------------------------------------------

MAX_Z = "6.3"
"""Upper bound of the CDF central domain, as an exact decimal string. Inputs
with `|z| >= MAX_Z` saturate to the endpoint instead of consulting the rational."""

_MAX_Z = Decimal(MAX_Z)

MAX_Z_RAW = int(_MAX_Z * SCALE_DECIMAL)
"""`MAX_Z` at the UD30x9 raw scale (`10^9`) - i.e. `6_300_000_000`. Emitted as
the on-chain `cdf_coefficients::MAX_Z_RAW` (the single saturation source of
truth, consumed by `cdf::cdf_nonneg_raw`)."""

MAX_Z_RAW_WAD = int(_MAX_Z * WAD)
"""`MAX_Z` at WAD scale (`10^18`) - i.e. `6_300_000_000_000_000_000`. Kept for
cross-scale consistency checks; the on-chain saturation bound is the raw-scale
`MAX_Z_RAW` above."""

# --- PDF domain bound -------------------------------------------------------

PDF_MAX_Z = "6.5"
"""Upper bound of the PDF central domain, as an exact decimal string. Inputs with
`|z| >= PDF_MAX_Z` saturate to `0`: the density has decayed below the `10^-9`
output resolution there (φ(6.5) ≈ 2.7e-10, which rounds to 0), so the cut-off is
lossless. Slightly wider than the CDF bound because φ's tail reaches the
round-to-zero point later than Φ reaches saturation."""

_PDF_MAX_Z = Decimal(PDF_MAX_Z)

PDF_MAX_Z_RAW = int(_PDF_MAX_Z * SCALE_DECIMAL)
"""`PDF_MAX_Z` at the UD30x9 raw scale (`10^9`) - i.e. `6_500_000_000`. Emitted as
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
