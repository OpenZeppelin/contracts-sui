"""Unit tests for the sign-magnitude integer arithmetic in `shared/arithmetic.py`
- the on-chain mirror of the `horner` Move primitives - and the end-to-end
`cdf_simulate` evaluator in `cdf/validate.py`. These primitives are load-bearing:
if they drift from the Move implementation, validation gives false confidence.
"""
from __future__ import annotations

import pytest

from gaussian_codegen.cdf import validate as v
from gaussian_codegen.shared import arithmetic as arith
from gaussian_codegen.shared import constants
from gaussian_codegen.shared import gates

WAD = constants.WAD


# --- add --------------------------------------------------------------------


def test_add_same_sign():
    assert arith.add((3, False), (5, False)) == (8, False)
    assert arith.add((3, True), (5, True)) == (8, True)


def test_add_opposite_sign_inherits_larger():
    assert arith.add((5, False), (3, True)) == (2, False)
    assert arith.add((3, False), (5, True)) == (2, True)


def test_add_exact_cancellation_is_canonical_zero():
    assert arith.add((5, False), (5, True)) == (0, False)


def test_add_zero_operand():
    assert arith.add((0, False), (7, True)) == (7, True)
    assert arith.add((7, True), (0, False)) == (7, True)


# --- mul_wad ----------------------------------------------------------------


def test_mul_wad_unit():
    # 2.0 * 3.0 at WAD scale = 6.0
    assert arith.mul_wad((2 * WAD, False), (3 * WAD, False)) == (6 * WAD, False)


def test_mul_wad_sign_xor():
    assert arith.mul_wad((2 * WAD, True), (3 * WAD, False)) == (6 * WAD, True)
    assert arith.mul_wad((2 * WAD, True), (3 * WAD, True)) == (6 * WAD, False)


def test_mul_wad_floor_to_zero_drops_sign():
    # product floors below one WAD ULP -> canonical zero, sign dropped
    assert arith.mul_wad((1, True), (1, False)) == (0, False)


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
    assert arith.mul_div_nearest(a, b, d) == expected


# --- horner_eval (fixed-point Horner at WAD) --------------------------------


def test_horner_eval_constant():
    assert arith.horner_eval((2 * WAD, False), [(7 * WAD, False)]) == (7 * WAD, False)


def test_horner_eval_linear():
    # P(z) = 3 + z, at z = 2 -> 5
    coeffs = [(3 * WAD, False), (1 * WAD, False)]
    assert arith.horner_eval((2 * WAD, False), coeffs) == (5 * WAD, False)


def test_horner_eval_quadratic_with_signs():
    # P(z) = 1 - 2z + z^2, at z = 3 -> 1 - 6 + 9 = 4
    coeffs = [(1 * WAD, False), (2 * WAD, True), (1 * WAD, False)]
    assert arith.horner_eval((3 * WAD, False), coeffs) == (4 * WAD, False)


def test_horner_eval_canonicalizes_zero_leading_coeff():
    # Mirrors the Move `horner_eval_zero_polynomial_canonicalizes` test: the
    # seed goes through canonicalization, so (0, True) must become (0, False).
    assert arith.horner_eval((WAD, False), [(0, True)]) == (0, False)


def test_horner_eval_rejects_empty():
    with pytest.raises(RuntimeError):
        arith.horner_eval((WAD, False), [])


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


# --- shared.gates (neighbor monotonicity + overflow margin) -----------------


def test_horner_peak_product_matches_manual():
    # The peak product is the largest acc.mag * z.mag fed into a `// wad` step.
    # For P(z) = c0 + c1 z the only Horner step multiplies acc=c1 by z.
    z = (2 * WAD, False)
    peak = arith.horner_peak_product(z, [(3 * WAD, False), (1 * WAD, False)], WAD)
    assert peak == (1 * WAD) * (2 * WAD)  # c1 * z, before the `// wad` divide


def test_check_overflow_margin_committed_cdf(coeffs):
    num, den = coeffs
    bits, headroom = gates.check_overflow_margin(num, den, v.ACC_SCALE, v.SCALE, v.MAX_Z_RAW)
    assert bits <= 256
    assert headroom >= gates.MIN_HEADROOM_BITS


def test_check_neighbor_monotonicity_committed_cdf_window(coeffs):
    num, den = coeffs
    # A small in-domain tail window: the gate runs and confirms no inversion
    # (it raises RuntimeError on any confirmed inversion).
    pairs, _ = gates.check_neighbor_monotonicity(
        num, den, v.ACC_SCALE, v.SCALE, 5_000_000_000, 5_000_200_000, increasing=True
    )
    assert pairs > 0
