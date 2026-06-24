"""Unit tests for the PDF codegen: the expected-value oracle and the
`pdf_simulate` integer mirror (the parallel of `test_emit` / `test_validate_mirror`
for the CDF). The shared sign-magnitude arithmetic itself is covered in
`test_validate_mirror`.
"""
from __future__ import annotations

import pytest
from mpmath import mpf

from gaussian_codegen.pdf import emit_test_vectors as tv
from gaussian_codegen.pdf import validate as v
from gaussian_codegen.shared.reference import pdf as pdf_oracle


# --- expected_pdf_raw (oracle, evenness, saturation boundary) ---------------


def test_expected_pdf_raw_peak_at_zero():
    assert tv.expected_pdf_raw("0") == 398_942_280  # φ(0) = 1/√(2π)


def test_expected_pdf_raw_known_points():
    assert tv.expected_pdf_raw("1") == 241_970_725
    assert tv.expected_pdf_raw("2") == 53_990_967


def test_expected_pdf_raw_inside_uses_oracle():
    # z = 6 (< 6.5, not saturated) -> oracle value, strictly positive.
    expected = int(pdf_oracle(mpf("6")) * mpf(v.SCALE) + mpf("0.5"))
    assert tv.expected_pdf_raw("6") == expected
    assert expected > 0


def test_expected_pdf_raw_saturates_at_max_z_inclusive():
    # z == 6.5 quantizes to MAX_Z_RAW, which the chain saturates (z_raw >= MAX_Z_RAW)
    assert tv.expected_pdf_raw("6.5") == 0


def test_expected_pdf_raw_above_max_z_saturates():
    assert tv.expected_pdf_raw("7") == 0


# --- pdf_simulate end-to-end against the committed coefficients --------------


@pytest.fixture(scope="module")
def coeffs():
    text = v.COEFF_PATH.read_text(encoding="utf-8")
    return v.parse_coefficients(text)


def test_pdf_simulate_peak_is_bit_exact(coeffs):
    num, den = coeffs
    # No z=0 special case: with D(0) = 1 the rational returns the exact peak.
    assert v.pdf_simulate(0, num, den) == 398_942_280


def test_pdf_simulate_saturation(coeffs):
    num, den = coeffs
    assert v.pdf_simulate(v.MAX_Z_RAW, num, den) == 0
    assert v.pdf_simulate(v.MAX_Z_RAW + 1, num, den) == 0


def test_pdf_simulate_matches_known_phi1(coeffs):
    num, den = coeffs
    # φ(1) ≈ 0.241970725 -> 241_970_725 at 1e9, within the 5-ULP contract
    assert abs(v.pdf_simulate(1_000_000_000, num, den) - 241_970_725) <= 5


def test_pdf_simulate_monotone_decreasing(coeffs):
    num, den = coeffs
    prev = v.pdf_simulate(0, num, den)
    for z_raw in (250_000_000, 1_000_000_000, 2_000_000_000, 3_000_000_000, 5_000_000_000):
        cur = v.pdf_simulate(z_raw, num, den)
        assert cur <= prev
        prev = cur
