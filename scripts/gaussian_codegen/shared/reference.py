"""High-precision standard-normal CDF, PDF, and quantile oracle.

The mpmath oracle (100 dps) is used where we need values exact far beyond the
target scales: emitting bit-exact test vectors and quantizing the derived
coefficients. The `cdf`/`pdf` *derivation* and *validation* scripts instead
measure error against `scipy.stats.norm.cdf` / `scipy.stats.norm.pdf` (float64,
accurate to ~1e-16 - three orders of magnitude tighter than the 5e-9 error
budget), so scipy is the reference there. The quantile is the exception:
`scipy.stats.norm.ppf` is off by up to ~5e-9 in the deep tail, so
`inverse_cdf`'s derive and validate use the mpmath `erfinv`-based `ppf` below.
Where both are exact the two agree to float64 precision;
`sanity_check_against_scipy()` asserts it.
"""
from __future__ import annotations

from mpmath import erfinv, mp, mpf, ncdf, npdf, sqrt

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


def ppf(p) -> mpf:
    """Standard-normal quantile (inverse CDF) `Φ⁻¹(p)` at 100 dps.

    Uses the closed form `Φ⁻¹(p) = sqrt(2) · erfinv(2p − 1)`, which mpmath
    evaluates accurately across the whole open interval `(0, 1)` - including the
    deep tail, where `scipy.stats.norm.ppf` (float64) is off by up to ~5e-9 and is
    therefore *not* a usable oracle here. Accepts any value mpmath can coerce.
    """
    _ensure_dps()
    return sqrt(mpf(2)) * erfinv(2 * mpf(p) - 1)


def z_raw_at_decimal(p, scale: int = SCALE_DECIMAL) -> tuple[int, bool]:
    """`Φ⁻¹(p)` as a `(magnitude, is_negative)` integer pair at the given decimal
    scale, nearest-rounded (ties up on the magnitude).

    Defaults to scale=10^9 (the SD29x9 raw scale). Used when emitting test
    vectors so the expected value is the Move return type's exact bit pattern.
    """
    z = ppf(p)
    neg = z < 0
    mag = (-z if neg else z) * mpf(scale)
    return int(mag + mpf("0.5")), bool(neg)


def sanity_check_against_scipy(tolerance: float = 1e-15) -> None:
    """Spot-check the mpmath oracles against scipy.stats.norm.cdf / norm.pdf /
    norm.ppf at well-known points."""
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

    # Central points only: scipy's float64 ppf loses accuracy in the deep tail,
    # so the mpmath erfinv oracle is checked against it only where they agree.
    for p_str in ("0.5", "0.6", "0.75", "0.9", "0.975"):
        ours = float(ppf(p_str))
        theirs = float(norm.ppf(float(p_str)))
        diff = abs(ours - theirs)
        if diff > tolerance:
            raise AssertionError(
                f"mpmath Φ⁻¹ disagrees with scipy at p={p_str}: "
                f"mpmath={ours}, scipy={theirs}, diff={diff:.2e}"
            )


if __name__ == "__main__":
    sanity_check_against_scipy()
    print(f"phi(0)   = {phi(0)}")
    print(f"phi(1)   = {phi(1)}")
    print(f"phi(6.3) = {phi('6.3')}")
    print("OK - mpmath oracle matches scipy within 1e-15")
