"""High-precision standard-normal CDF and PDF oracle.

The mpmath oracle (100 dps) is used where we need values exact far beyond the
target scales: emitting bit-exact test vectors and quantizing the derived
coefficients. Coefficient *derivation* (`<family>/derive.py`) and *validation*
(`<family>/validate.py`) instead measure error against `scipy.stats.norm.cdf` /
`scipy.stats.norm.pdf` (float64, accurate to ~1e-16 - three orders of magnitude
tighter than the 5e-9 error budget), so scipy is the reference there. The two
agree to float64 precision; `sanity_check_against_scipy()` asserts it.
"""
from __future__ import annotations

from mpmath import mp, mpf, ncdf, npdf

from gaussian_codegen.shared.constants import DPS, SCALE_DECIMAL

# Set once at import time. Callers that change `mp.dps` should restore it
# (or call `_ensure_dps()` before evaluating).
mp.dps = DPS


def _ensure_dps() -> None:
    if mp.dps < DPS:
        mp.dps = DPS


def phi(z) -> mpf:
    """Standard-normal CDF Φ(z) at 100 dps. Accepts any value mpmath can coerce."""
    _ensure_dps()
    return ncdf(mpf(z))


def pdf(z) -> mpf:
    """Standard-normal PDF phi(z) = e^(-z^2/2) / sqrt(2*pi) at 100 dps. Accepts
    any value mpmath can coerce."""
    _ensure_dps()
    return npdf(mpf(z))


def phi_raw_at_decimal(z, scale: int = SCALE_DECIMAL) -> int:
    """Φ(z) as an integer at the given decimal scale, nearest-rounded (ties up).

    Defaults to scale=10^9 (the UD30x9 raw scale). Used when emitting test
    vectors so the expected value is the Move return type's exact bit pattern.
    """
    val = phi(z) * mpf(scale)
    return int(val + mpf("0.5"))


def sanity_check_against_scipy(tolerance: float = 1e-15) -> None:
    """Spot-check the mpmath oracles against scipy.stats.norm.cdf / norm.pdf at
    well-known points."""
    from scipy.stats import norm

    for z_str in ("0", "0.5", "1", "2", "3", "6.3"):
        ours = float(phi(z_str))
        theirs = float(norm.cdf(float(z_str)))
        diff = abs(ours - theirs)
        if diff > tolerance:
            raise AssertionError(
                f"mpmath Φ disagrees with scipy at z={z_str}: "
                f"mpmath={ours}, scipy={theirs}, diff={diff:.2e}"
            )

    for z_str in ("0", "0.5", "1", "2", "3", "6.5"):
        ours = float(pdf(z_str))
        theirs = float(norm.pdf(float(z_str)))
        diff = abs(ours - theirs)
        if diff > tolerance:
            raise AssertionError(
                f"mpmath φ disagrees with scipy at z={z_str}: "
                f"mpmath={ours}, scipy={theirs}, diff={diff:.2e}"
            )


if __name__ == "__main__":
    sanity_check_against_scipy()
    print(f"phi(0)   = {phi(0)}")
    print(f"phi(1)   = {phi(1)}")
    print(f"phi(6.3) = {phi('6.3')}")
    print("OK - mpmath oracle matches scipy within 1e-15")
