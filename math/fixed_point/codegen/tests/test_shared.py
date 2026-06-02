"""Unit tests for the shared codegen helpers (constants + Move emission)."""
from __future__ import annotations

import pytest

from codegen.shared import constants
from codegen.shared.move_emit import (
    auto_generated_banner,
    check_move,
    fmt_u128,
    write_move,
)


# --- constants --------------------------------------------------------------


def test_constants_literal_values():
    assert constants.WAD == 10**18
    assert constants.SCALE_DECIMAL == 10**9
    assert constants.MAX_Z == "6.3"
    assert constants.MAX_Z_RAW == 6_300_000_000
    assert constants.MAX_Z_RAW_WAD == 6_300_000_000_000_000_000


def test_raw_scales_are_internally_consistent():
    # The WAD-scale bound is the decimal-scale bound promoted by 10^9.
    assert constants.WAD // constants.SCALE_DECIMAL == 10**9
    assert constants.MAX_Z_RAW_WAD == constants.MAX_Z_RAW * (constants.WAD // constants.SCALE_DECIMAL)


# --- fmt_u128 / grouping ----------------------------------------------------


@pytest.mark.parametrize(
    "n,expected",
    [
        (0, "0"),
        (1, "1"),
        (123, "123"),
        (1234, "1_234"),
        (1_000_000, "1_000_000"),
        (6_300_000_000_000_000_000, "6_300_000_000_000_000_000"),
    ],
)
def test_fmt_u128_grouping(n, expected):
    assert fmt_u128(n) == expected


def test_fmt_u128_rejects_negative():
    with pytest.raises(ValueError):
        fmt_u128(-1)


def test_fmt_u128_rejects_overflow():
    with pytest.raises(ValueError):
        fmt_u128(2**128)


def test_fmt_u128_accepts_max_u128():
    assert fmt_u128(2**128 - 1)  # boundary value does not raise


# --- banner -----------------------------------------------------------------


def test_banner_is_deterministic_and_dateless():
    b1 = auto_generated_banner("math/fixed_point/codegen/cdf/derive.py")
    b2 = auto_generated_banner("math/fixed_point/codegen/cdf/derive.py")
    assert b1 == b2  # no timestamp -> stable output
    assert "Regenerated" not in b1
    assert "AUTO-GENERATED" in b1
    assert "math/fixed_point/codegen/cdf/derive.py" in b1


# --- check_move drift guard -------------------------------------------------


def test_check_move_roundtrip(tmp_path):
    path = tmp_path / "x.move"
    content = "module a::b;\n"
    write_move(path, content)
    assert check_move(path, content) is True
    # trailing-newline is normalized exactly like write_move
    assert check_move(path, "module a::b;") is True


def test_check_move_detects_drift(tmp_path):
    path = tmp_path / "x.move"
    write_move(path, "module a::b;\n")
    assert check_move(path, "module a::c;\n") is False


def test_check_move_missing_file(tmp_path):
    assert check_move(tmp_path / "nope.move", "x") is False
