"""Unit tests for the sign-magnitude integer arithmetic in `validate.py` — the
on-chain mirror of the `horner` (primitives) and `cdf` (evaluator) modules.
These primitives are load-bearing: if they drift from the Move implementation,
validation gives false confidence.
"""
from __future__ import annotations

import pytest

from codegen.cdf import validate as v
from codegen.shared import constants

WAD = constants.WAD


# --- signed_add -------------------------------------------------------------


def test_signed_add_same_sign():
    assert v.signed_add((3, False), (5, False)) == (8, False)
    assert v.signed_add((3, True), (5, True)) == (8, True)


def test_signed_add_opposite_sign_inherits_larger():
    assert v.signed_add((5, False), (3, True)) == (2, False)
    assert v.signed_add((3, False), (5, True)) == (2, True)


def test_signed_add_exact_cancellation_is_canonical_zero():
    assert v.signed_add((5, False), (5, True)) == (0, False)


def test_signed_add_zero_operand():
    assert v.signed_add((0, False), (7, True)) == (7, True)
    assert v.signed_add((7, True), (0, False)) == (7, True)


# --- signed_mul_wad ---------------------------------------------------------


def test_signed_mul_wad_unit():
    # 2.0 * 3.0 at WAD scale = 6.0
    assert v.signed_mul_wad((2 * WAD, False), (3 * WAD, False)) == (6 * WAD, False)


def test_signed_mul_wad_sign_xor():
    assert v.signed_mul_wad((2 * WAD, True), (3 * WAD, False)) == (6 * WAD, True)
    assert v.signed_mul_wad((2 * WAD, True), (3 * WAD, True)) == (6 * WAD, False)


def test_signed_mul_wad_floor_to_zero_drops_sign():
    # product floors below one WAD ULP -> canonical zero, sign dropped
    assert v.signed_mul_wad((1, True), (1, False)) == (0, False)


# --- mul_div_nearest (half-up, ties away from zero) -------------------------


@pytest.mark.parametrize(
    "a,b,d,expected",
    [
        (1, 1, 4, 0),  # 0.25 -> down
        (1, 1, 3, 0),  # 0.333 -> down
        (1, 1, 2, 1),  # 0.5 tie -> up
        (2, 1, 3, 1),  # 0.666 -> up
        (3, 1, 2, 2),  # 1.5 tie -> up
        (5, 1, 2, 3),  # 2.5 tie -> up (away from zero)
        (7, 1, 4, 2),  # 1.75 -> up
    ],
)
def test_mul_div_nearest_half_up(a, b, d, expected):
    assert v.mul_div_nearest(a, b, d) == expected


# --- horner_eval (fixed-point Horner at WAD) --------------------------------


def test_horner_eval_constant():
    assert v.horner_eval((2 * WAD, False), [(7 * WAD, False)]) == (7 * WAD, False)


def test_horner_eval_linear():
    # P(z) = 3 + z, at z = 2 -> 5
    coeffs = [(3 * WAD, False), (1 * WAD, False)]
    assert v.horner_eval((2 * WAD, False), coeffs) == (5 * WAD, False)


def test_horner_eval_quadratic_with_signs():
    # P(z) = 1 - 2z + z^2, at z = 3 -> 1 - 6 + 9 = 4
    coeffs = [(1 * WAD, False), (2 * WAD, True), (1 * WAD, False)]
    assert v.horner_eval((3 * WAD, False), coeffs) == (4 * WAD, False)


def test_horner_eval_rejects_empty():
    with pytest.raises(RuntimeError):
        v.horner_eval((WAD, False), [])


# --- cdf_simulate end-to-end against the committed coefficients -------------


@pytest.fixture(scope="module")
def coeffs():
    text = v.COEFF_PATH.read_text(encoding="utf-8")
    return v.parse_coefficients(text)


def test_cdf_simulate_phi0(coeffs):
    num, den = coeffs
    assert v.cdf_simulate(0, False, num, den) == v.HALF_SCALE


def test_cdf_simulate_saturation(coeffs):
    num, den = coeffs
    assert v.cdf_simulate(v.MAX_Z_RAW, False, num, den) == v.SCALE
    assert v.cdf_simulate(v.MAX_Z_RAW, True, num, den) == 0


def test_cdf_simulate_reflection_identity(coeffs):
    num, den = coeffs
    for z_raw in (250_000_000, 1_000_000_000, 3_000_000_000, 6_000_000_000):
        pos = v.cdf_simulate(z_raw, False, num, den)
        neg = v.cdf_simulate(z_raw, True, num, den)
        assert neg == v.SCALE - pos


def test_cdf_simulate_matches_known_phi1(coeffs):
    num, den = coeffs
    # Φ(1) ≈ 0.8413447460685 -> 841_344_746 at 1e9, within the 5-ULP contract
    phi1 = v.cdf_simulate(1_000_000_000, False, num, den)
    assert abs(phi1 - 841_344_746) <= 5
