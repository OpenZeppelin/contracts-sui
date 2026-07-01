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
`999_999_999`. Serves as both the fit domain and the on-chain saturation
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
rounds to `1`. Serves as both the fit domain and the on-chain saturation-to-0
bound. Wider than the CDF bound because φ's tail reaches the round-to-zero point
later than Φ reaches saturation."""

_PDF_MAX_Z = Decimal(PDF_MAX_Z)

PDF_MAX_Z_RAW = int(_PDF_MAX_Z * SCALE_DECIMAL)
"""`PDF_MAX_Z` at the UD30x9 raw scale (`10^9`) - i.e. `6_402_729_806`. Emitted as
the on-chain `pdf_coefficients::MAX_Z_RAW` (the saturation source of truth,
consumed by `pdf::pdf_nonneg_raw`)."""
