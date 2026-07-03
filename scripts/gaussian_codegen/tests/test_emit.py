"""Unit tests for the quantizer and the test-vector expected-value oracle."""
from __future__ import annotations

from gaussian_codegen.cdf import emit_test_vectors as tv
from gaussian_codegen.shared import constants
from gaussian_codegen.shared.move_emit import quantize

WAD = constants.WAD
SCALE = constants.SCALE_DECIMAL


# --- quantize (coefficient -> (u128 mag, sign) at WAD) ----------------------


def test_quantize_positive():
    assert quantize("0.5") == (5 * 10**17, False)


def test_quantize_negative():
    assert quantize("-0.5") == (5 * 10**17, True)


def test_quantize_one():
    assert quantize("1") == (WAD, False)


def test_quantize_zero_is_canonical():
    assert quantize("0") == (0, False)


def test_quantize_tiny_negative_canonicalizes_to_zero():
    # rounds to magnitude 0 at WAD -> the sign flag is dropped (matches the
    # on-chain canonical zero)
    assert quantize("-1e-30") == (0, False)


def test_quantize_rounds_half_up():
    # 5e-19 * 10^18 = 0.5 exactly -> rounds up to magnitude 1
    assert quantize("5e-19") == (1, False)


def test_quantize_at_family_wad():
    # an explicit family scale overrides the default 10^18: 0.5 at 10^36 -> 5e35
    assert quantize("0.5", constants.CDF_WAD) == (5 * 10**35, False)


# --- expected_phi_raw saturation boundary mirrors the on-chain `>=` ----------


def test_expected_phi_raw_phi0():
    assert tv.expected_phi_raw("0", False) == 5 * 10**8  # Φ(0) = 0.5


def test_expected_phi_raw_saturates_at_max_z_inclusive():
    # z == 6.109410205 quantizes to MAX_Z_RAW, which the chain saturates (z_raw >= MAX_Z_RAW)
    assert tv.expected_phi_raw("6.109410205", False) == SCALE
    assert tv.expected_phi_raw("6.109410205", True) == 0


def test_expected_phi_raw_inside_uses_oracle():
    # z = 6 (< 6.109410205, not saturated) -> oracle value, strictly below 1.0.
    # (Φ rounds up to exactly 1e9 only at z >= 6.109410205, which is why the
    # saturation boundary must be the integer `z_raw >= MAX_Z_RAW` check.)
    assert tv.expected_phi_raw("6", False) == 999_999_999


def test_expected_phi_raw_above_max_z_saturates():
    assert tv.expected_phi_raw("7", False) == SCALE
    assert tv.expected_phi_raw("7", True) == 0
