"""Tests for the rounding-aware rational refinement helpers."""
from __future__ import annotations

import numpy as np

from gaussian_codegen.shared.rounding_optimize import (
    coefficient_strings,
    midpoint_raw_holdout_grid,
    optimize_rounding_cells,
    optimize_soft_l1,
    refinement_holdout_grid,
    score_quantized_rational,
    score_rational,
    uniform_raw_grid,
)


def test_uniform_raw_grid_stays_inside_half_open_interval():
    grid = uniform_raw_grid(3, 100, 10)
    assert grid[0] == 3
    assert grid[-1] == 99
    assert np.all(np.diff(grid) > 0)


def test_uniform_raw_grid_rejects_duplicate_sampling():
    with np.testing.assert_raises(ValueError):
        uniform_raw_grid(3, 5, 3)


def test_midpoint_raw_holdout_grid_is_deterministic_and_disjoint():
    training = uniform_raw_grid(3, 1_003, 20)
    excluded = np.union1d(training, training[:-1] + 1)
    first = midpoint_raw_holdout_grid(3, 1_003, 40, excluded)
    second = midpoint_raw_holdout_grid(3, 1_003, 40, excluded)

    assert np.array_equal(first, second)
    assert first[0] >= 3
    assert first[-1] < 1_003
    assert np.all(np.diff(first) > 0)
    assert np.intersect1d(first, excluded).size == 0


def test_midpoint_raw_holdout_grid_accepts_last_permitted_repair():
    holdout = midpoint_raw_holdout_grid(0, 6, 2, [1, 2])
    assert np.array_equal(holdout, np.array([3, 4]))


def test_refinement_holdout_grid_excludes_training_and_scoring_inputs():
    holdout = refinement_holdout_grid(10_000, 100, 200, 300, basin_start=1)
    excluded = np.unique(
        np.concatenate(
            [
                uniform_raw_grid(0, 10_000, 100),
                uniform_raw_grid(1, 10_000, 100),
                uniform_raw_grid(0, 10_000, 200),
            ]
        )
    )
    assert np.intersect1d(holdout, excluded).size == 0


def test_score_rational_counts_rounding_cells():
    x = np.array([0.0, 0.2, 0.4, 0.6])
    reference = x.copy()
    exact = score_rational([0.0, 1.0], [1.0], x, reference, 10)
    biased = score_rational([0.06, 1.0], [1.0], x, reference, 10)

    assert exact.correctly_rounded == 4
    assert biased.correctly_rounded == 0


def test_score_quantized_rational_uses_integer_pipeline():
    raw = np.array([0, 1, 2, 3], dtype=np.int64)
    reference = raw.astype(np.float64) / 10
    score = score_quantized_rational(
        ["0", "1"],
        ["1"],
        raw,
        reference,
        wad=1_000,
        output_scale=10,
    )

    assert score.correctly_rounded == 4


def test_score_quantized_rational_covers_signed_horner_and_half_up_ties():
    raw = np.array([4, 5, 6, 7], dtype=np.int64)
    reference = np.array([0.1, 0.2, 0.2, 0.3])
    score = score_quantized_rational(
        ["-0.155", "0.525"],
        ["1"],
        raw,
        reference,
        wad=100,
        output_scale=10,
    )

    # Coefficients quantize to (-16, +53). The exact Horner magnitudes are
    # [5, 10, 15, 21], whose final half-up outputs are [1, 1, 2, 2].
    assert score.correctly_rounded == 2


def test_soft_l1_refinement_reduces_mean_absolute_error():
    x = np.linspace(0.0, 1.0, 2_000)
    reference = x / (1.0 + x)
    seed_num = [0.0, 0.9]
    seed_den = [1.0, 1.0]
    seed_score = score_rational(seed_num, seed_den, x, reference, 1_000)

    optimized = optimize_soft_l1(
        seed_num,
        seed_den,
        x,
        reference,
        domain_max=1.0,
        output_scale=1_000,
        soft_l1_scale_ulp=0.1,
        max_function_evaluations=100,
    )
    refined_score = score_rational(
        optimized.numerator,
        optimized.denominator,
        x,
        reference,
        1_000,
    )

    assert len(optimized.numerator) == len(seed_num)
    assert len(optimized.denominator) == len(seed_den)
    assert optimized.success
    assert refined_score.mean_absolute_error_ulp < seed_score.mean_absolute_error_ulp
    assert refined_score.correctly_rounded > seed_score.correctly_rounded


def test_coefficient_strings_do_not_claim_more_than_float64_precision():
    assert coefficient_strings([1.0 / 3.0]) == ["0.33333333333333331"]


def test_rounding_cell_optimizer_preserves_shape_and_converges():
    x = np.linspace(0.0, 1.0, 2_000)
    reference = x / (1.0 + x)
    seed_num = [0.001, 0.99]
    seed_den = [1.0, 1.0]

    cells = optimize_rounding_cells(
        seed_num,
        seed_den,
        x,
        reference,
        domain_max=1.0,
        output_scale=1_000,
        temperature_ulp=0.02,
        max_iterations=100,
    )
    assert cells.success
    assert len(cells.numerator) == len(seed_num)
    assert len(cells.denominator) == len(seed_den)
