"""Single source of truth for the scales and domain bound shared across the
codegen pipeline.

These values must stay in lock-step with the on-chain Move code
(`sources/internal/gaussian.move` and the generated `cdf_coefficients.move`).
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
"""UD30x9 / SD29x9 raw scale (`10^9`) — the type's on-chain representation."""

DPS = 100
"""mpmath decimal places of precision for the Φ oracle, well in excess of WAD."""

# --- CDF domain bound -------------------------------------------------------

MAX_Z = "6.3"
"""Upper bound of the CDF central domain, as an exact decimal string. Inputs
with `|z| >= MAX_Z` saturate to the endpoint instead of consulting the rational."""

_MAX_Z = Decimal(MAX_Z)

MAX_Z_RAW = int(_MAX_Z * SCALE_DECIMAL)
"""`MAX_Z` at the UD30x9 raw scale (`10^9`) — i.e. `6_300_000_000`. Mirrors the
on-chain `MAX_Z_RAW` saturation threshold in `gaussian.move`."""

MAX_Z_RAW_WAD = int(_MAX_Z * WAD)
"""`MAX_Z` at WAD scale (`10^18`) — i.e. `6_300_000_000_000_000_000`. Mirrors the
on-chain `MAX_Z_WAD` constant in `cdf_coefficients.move`."""
