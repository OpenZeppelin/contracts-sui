"""Unit tests for the inverse-CDF codegen: the erfinv oracle, the emit-time
expected values (including saturation and reflection), the tail change-of-variable
integer mirror, and the `inverse_cdf` integer simulation against the committed
coefficients. The shared sign-magnitude Horner arithmetic itself is covered in
`test_validate_mirror`.
"""
from __future__ import annotations

import pytest
from mpmath import ln, mpf, sqrt

from gaussian_codegen.inverse_cdf import emit_test_vectors as tv
from gaussian_codegen.inverse_cdf import validate as v
from gaussian_codegen.shared import arithmetic as A
from gaussian_codegen.shared.reference import ppf


# --- ppf oracle (erfinv) ----------------------------------------------------


def test_ppf_half_is_zero():
    assert float(ppf("0.5")) == 0.0


def test_ppf_known_point():
    # Φ⁻¹(0.975) = 1.959963984540054
    assert abs(float(ppf("0.975")) - 1.959963984540054) < 1e-12


def test_ppf_is_odd_about_half():
    assert abs(float(ppf("0.975")) + float(ppf("0.025"))) < 1e-12


def test_ppf_matches_scipy_central():
    from scipy.stats import norm

    for p in ("0.6", "0.75", "0.9", "0.975"):
        assert abs(float(ppf(p)) - float(norm.ppf(float(p)))) < 1e-12


def test_ppf_beats_scipy_in_deep_tail():
    # scipy's float64 ppf is off by ~5e-9 at p = 1 - 1e-9; the erfinv oracle is not.
    from scipy.stats import norm

    p = "0.999999999"
    assert abs(float(ppf(p)) - float(norm.ppf(float(p)))) > 1e-9


# --- emit-time expected values (oracle, saturation, reflection) -------------


def test_expected_z_half_is_zero():
    assert tv.expected_z(tv.HALF_RAW) == (0, False)


def test_expected_z_known_point():
    assert tv.expected_z(975_000_000) == (1_959_963_985, False)


def test_expected_z_reflection_is_negated():
    assert tv.expected_z(25_000_000) == (1_959_963_985, True)


def test_expected_z_deep_tail():
    assert tv.expected_z(999_999_999) == (5_997_807_015, False)


def test_expected_z_saturates_at_one():
    assert tv.expected_z(tv.ONE_RAW) == (tv.MAX_Z_RAW, False)


def test_expected_z_saturates_at_zero():
    assert tv.expected_z(0) == (tv.MAX_Z_RAW, True)


# --- tail change-of-variable integer mirror ---------------------------------


def test_raw_log2_of_one_half_is_minus_one():
    neg, mag = A.raw_log2(A.SCALE // 2)  # log2(0.5) = -1
    assert neg is True
    assert mag == 10**18  # exactly 1.0 at the 1e18 internal scale


def test_tail_r_wad_matches_mpmath():
    # `r` is carried at the WAD (10^18) accumulation scale; the integer pipeline
    # (log kernel + nearest ln-rescale + nearest sqrt) stays within a few units
    # of the true value at that scale - i.e. ~9 digits below one output ULP.
    for k in (1, 2, 100, 1000, 10**6, 25_000_000):
        p_raw = A.SCALE - k  # 1 - p = k / 1e9
        r_true = sqrt(-2 * ln(mpf(k) / A.SCALE)) * A.WAD
        assert abs(A.tail_r_wad(p_raw) - r_true) <= 4


# --- inverse_cdf integer simulation vs committed coefficients ---------------


@pytest.fixture(scope="module")
def coeffs():
    return v.Coeffs(v.COEFF_PATH.read_text(encoding="utf-8"))


def test_upper_raw_half_is_bit_exact_zero(coeffs):
    assert v.upper_raw(v.HALF_RAW, coeffs) == 0


def test_upper_raw_saturates_at_one(coeffs):
    assert v.upper_raw(v.ONE_RAW, coeffs) == coeffs.max_z


def test_upper_raw_known_point(coeffs):
    # Φ⁻¹(0.975) ≈ 1.959963985 within the 5-ULP contract.
    assert abs(v.upper_raw(975_000_000, coeffs) - 1_959_963_985) <= 5


def test_signed_saturation_endpoints(coeffs):
    assert v.inverse_cdf_signed(v.ONE_RAW, coeffs) == coeffs.max_z
    assert v.inverse_cdf_signed(0, coeffs) == -coeffs.max_z


def test_signed_reflection_identity(coeffs):
    for p_raw in (600_000_000, 750_000_000, 975_000_000, 999_000_000, 999_999_999):
        assert v.inverse_cdf_signed(p_raw, coeffs) == -v.inverse_cdf_signed(v.ONE_RAW - p_raw, coeffs)


def test_signed_deep_tail_both_sides(coeffs):
    assert abs(v.inverse_cdf_signed(999_999_999, coeffs) - 5_997_807_015) <= 5
    assert abs(v.inverse_cdf_signed(1, coeffs) + 5_997_807_015) <= 5


def test_signed_monotone_increasing(coeffs):
    prev = None
    for p_raw in (1, 25_000_000, 250_000_000, 499_999_999, 500_000_000, 750_000_000, 975_000_000, 999_999_999):
        cur = v.inverse_cdf_signed(p_raw, coeffs)
        if prev is not None:
            assert cur >= prev
        prev = cur
