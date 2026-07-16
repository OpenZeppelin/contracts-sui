# `openzeppelin_fp_math` Codegen

This directory is an **offline Python toolkit**. It computes the numeric
constants that the `cdf` (standard-normal CDF), `pdf` (standard-normal PDF), and
`inverse_cdf` (standard-normal quantile) functions in `openzeppelin_fp_math` need,
and writes them into the Move source as generated tables.

Nothing here runs on-chain, and nothing here is needed to *use* the library -
the Move package is fully self-contained at runtime. You only touch this
directory to **(re)generate or re-validate** those constants.

If you just want to consume the library, you can stop reading and head to
the [`openzeppelin_fp_math` package README](../../math/fixed_point/README.md). The rest of
this document is for anyone curious *why* a Move library ships Python, or who
needs to regenerate the tables.

## Why does a Move library ship Python code?

Short version: the `cdf` function needs around twenty carefully-chosen
constants that are genuinely hard to compute; computing them needs
floating-point and arbitrary-precision math that Move doesn't have; and it only
has to happen once. So we do it offline in Python and bake the results into the
Move source.

The longer version is worth understanding.

**What `cdf` computes.** Φ(z) - the *standard-normal CDF* - is the probability
that a normally-distributed value lands at or below `z`: the area under the bell
curve to the left of `z`. It's a building block for options pricing, risk
models, and sampling. What matters for this toolkit is *how* we get the number,
not what it's used for.

**Why you can't just compute it on-chain.** Φ has no elementary formula - it's
defined by an integral with no closed form. The usual ways to evaluate it lean
on `exp(−z²/2)` or the error function `erf`. But Move has **no floating point
and no transcendental functions** - only integer arithmetic on our fixed-point
types. There is no `exp`, no `erf`, nothing to build Φ out of directly.

**The trick: approximate the curve, don't compute it.** Instead of evaluating Φ,
we approximate the *whole curve* with a **rational function** `N(z) / D(z)` -
one polynomial divided by another. With the right coefficients, a degree-9
rational matches Φ to about `10⁻⁹` across the domain using nothing but
multiplies and a single divide - operations Move *does* have. (The approach is
from [Evan Kim's "On-Chain Atomic Gaussian Math"](https://paragraph.com/@evandekim/on-chain-atomic-gaussian-math);
we re-derived our own coefficients rather than copying his.)

**Why the work is split offline/on-chain.** Finding those coefficients is heavy
numerical work; *evaluating* them is trivial. So we split it:

- **Offline, once (this toolkit):** feed high-precision samples of Φ to a
  curve-fitting algorithm, get near-optimal coefficients, validate them against
  a 100-digit reference, and write them into Move as integer constants.
- **On-chain, every call (the Move code):** evaluate the two polynomials with
  Horner's method and divide. A handful of integer multiplies - deterministic,
  constant gas. See `../../math/fixed_point/sources/internal/cdf.move` (and the shared primitives in
  `../../math/fixed_point/sources/internal/horner.move`).

**Why AAA, and why Python.** The fitting algorithm is **AAA** (Adaptive
Antoulas–Anderson). You hand it samples of a function and it automatically
produces a near-optimal rational fit - no hand-tuning of degree or coefficient
placement. It ships in `scipy.interpolate.AAA` (added in SciPy 1.15.0), and the
high-precision reference math uses `mpmath`. Neither could run on-chain - they
need floats and arbitrary precision and are far too expensive - which is exactly
why this half lives here, offline, and only the cheap half ships in Move.

Even symmetry makes it cheaper still: we fit only the right half
`[0, 6.109410205]` (the point at which Φ rounds to 1 at `10⁻⁹` resolution) and
the Move code reflects negatives via Φ(−z) = 1 − Φ(z).

## How the pipeline fits together

Three stages, four scripts. Generation flows left to right; `validate.py` is an
independent re-check that closes the loop.

```text
derive.py ──► .derive_output.json ──┬─► emit_coefficients.py ──► cdf_coefficients.move
(AAA fit)        (chosen coeffs)     └─► emit_test_vectors.py  ──► cdf_test_vectors.move (×2)

validate.py ──► parses the committed cdf_coefficients.move, re-runs it, checks vs scipy
```

- **`derive.py`** - runs the AAA fit at the pinned polynomial degree (held fixed
  across regenerations so a precision/domain change never silently moves it),
  checks it meets the `5×10⁻⁹` error target, and writes the coefficients to a JSON
  intermediate. `--report` prints the full per-degree error sweep.
- **`emit_coefficients.py`** - reads that JSON, quantizes the coefficients to
  fixed-point integers, and writes `cdf_coefficients.move`.
- **`emit_test_vectors.py`** - emits the Move test vectors (expected Φ at chosen
  `z`, taken straight from the high-precision `mpmath` oracle).
- **`validate.py`** - the independent check, and the CI gate. It does **not**
  re-derive: it parses the committed `cdf_coefficients.move` and re-runs the
  exact on-chain integer arithmetic (at the `10^36` accumulation scale) in Python.
  It asserts the quantized error stays within budget (≤ 5 ULP at `10⁻⁹`) against
  `scipy`, plus two exhaustive tail gates (`shared/gates.py`): neighbor-resolution
  monotonicity (no 1-ULP inversion between adjacent raw inputs) and u256 overflow
  margin (the peak Horner product stays under `2^256` with headroom).

The split is deliberate. Deriving needs the heavy `scipy`/`mpmath` machinery;
validating only needs to confirm the *committed* numbers are still correct,
which is cheap enough to run in CI on every change.

## Requirements

- Python ≥ 3.10
- `mpmath ≥ 1.3`, `scipy ≥ 1.15`, `numpy ≥ 1.26`

> `scipy.interpolate.AAA` was introduced in SciPy **1.15.0**; earlier releases
> will fail to import in `derive.py`.

### Reproducing the committed tables byte-for-byte

The floor pins above guarantee *correct* output, not *identical* output: a
future `scipy.interpolate.AAA` could shift the fit. The committed coefficients
were generated with these exact versions - pin to them to reproduce the tables
byte-for-byte:

| Package | Version |
|---------|---------|
| Python  | 3.13.5  |
| mpmath  | 1.4.1   |
| scipy   | 1.18.0  |
| numpy   | 2.5.0   |

## Install

From the repo root:

```sh
python3 -m venv scripts/gaussian_codegen/.venv
source scripts/gaussian_codegen/.venv/bin/activate
pip install -e "scripts/gaussian_codegen[dev]"   # omit [dev] to skip pytest
```

This installs the `gaussian_codegen` package (editable) so `python -m gaussian_codegen.cdf.*`
works from any directory. `make -C scripts/gaussian_codegen install` does the same.

## Generate (CDF)

```sh
python -m gaussian_codegen.cdf.derive            # AAA fit + degree sweep → .derive_output.json
python -m gaussian_codegen.cdf.emit_coefficients # → math/fixed_point/sources/internal/cdf_coefficients.move
python -m gaussian_codegen.cdf.emit_test_vectors # → tests/{sd29x9_tests,ud30x9_tests}/cdf_test_vectors.move
python -m gaussian_codegen.cdf.validate          # re-checks the committed coefficient module against scipy
```

## Generate (PDF)

```sh
python -m gaussian_codegen.pdf.derive            # AAA fit + degree sweep → .derive_output.json
python -m gaussian_codegen.pdf.emit_coefficients # → math/fixed_point/sources/internal/pdf_coefficients.move
python -m gaussian_codegen.pdf.emit_test_vectors # → tests/{sd29x9_tests,ud30x9_tests}/pdf_test_vectors.move
python -m gaussian_codegen.pdf.validate          # re-checks the committed coefficient module against scipy
```

## Generate (Inverse CDF)

```sh
python -m gaussian_codegen.inverse_cdf.derive            # two-region AAA fit → .derive_output.json
python -m gaussian_codegen.inverse_cdf.emit_coefficients # → math/fixed_point/sources/internal/inverse_cdf_coefficients.move
python -m gaussian_codegen.inverse_cdf.emit_test_vectors # → tests/{sd29x9_tests,ud30x9_tests}/inverse_cdf_test_vectors.move
python -m gaussian_codegen.inverse_cdf.validate          # re-checks the committed coefficients against the erfinv oracle
```

Unlike `cdf`/`pdf`, the quantile `Φ⁻¹(p)` is fit as **two** rationals - a central
one in `u = p - 0.5` and a tail one in `r = sqrt(-2·ln(1-p))` - because a single
rational in `p` underflows the fixed-point evaluator near `p = 1`. The two-region
scheme takes after Acklam/AS241 - the tail change of variable is Acklam's - but
the split point and the fitted tables are this project's own. The on-chain tail
builds `r` from the internal `raw_log2` and `u256::sqrt` kernels (`ln` is derived
from `log2`), not the typed `sd29x9_base::ln`/`sqrt`. Its oracle is mpmath
`erfinv` (scipy's float64 `ppf` is off by ~5e-9 in the deep tail, so it is not
usable here).
Accordingly `inverse_cdf/.derive_output.json` nests a `central` and a `tail` fit
object rather than the single coefficient set the `cdf`/`pdf` schema uses.

Or via the Makefile (`make -C scripts/gaussian_codegen <target>`): `regen` (derive
+ both emitters for each family; the emitters format their own output),
`validate`, `check` (drift guard), `test` (pytest), `ci` (what CI runs).

Both emitters format their output with the repo's Move formatter
(`@mysten/prettier-plugin-move`) as their final step, so what they write is
exactly what lands in the committed files - no separate `prettier --write` pass
is needed. This requires `npm ci` at the repo root (for the prettier plugin);
the emitters abort with a clear message if prettier is missing.

Each family's `derive.py` writes a JSON intermediate
(`scripts/gaussian_codegen/<family>/.derive_output.json`, e.g. `cdf/` and `pdf/`)
that its `emit_*.py` scripts consume. It is committed, so the coefficient drift
guard can run in CI without re-deriving (see below).

### Drift guard

Both emitters accept `--check`: they render to memory and compare against the
committed Move file byte-for-byte, exiting non-zero on any difference (without
writing). The banner carries no timestamp, so the output is deterministic.

Both checks are exact: each emitter formats its output (via the prettier plugin)
before the byte-comparison, so `--check` matches the committed, formatter-clean
file with no spurious formatting drift. `emit_coefficients --check` reads the
committed `.derive_output.json`; `emit_test_vectors --check` needs no JSON (it
recomputes expected values from the mpmath oracle).

### What CI runs

CI runs `validate.py`, both `--check` drift guards (`emit_coefficients` and
`emit_test_vectors`), and the Python unit tests (`pytest`); it runs `npm ci` so
the emitters can format. Re-deriving the fit (`derive.py`) stays local-only: CI
checks the committed coefficients against the committed `.derive_output.json`
rather than re-running the AAA fit, whose result is sensitive to solver and
library versions.

## `.derive_output.json` schema

The contract between `derive.py` and the emitters. Coefficients are decimal
strings (serialized from mpmath at 100 dps); everything else is informational.

| Key | Type | Meaning |
|-----|------|---------|
| `degree` / `n_coeffs` | int | Chosen polynomial degree and coefficient count |
| `max_error` / `worst_z` | float | Worst-case error of the float fit and where it occurs |
| `target_error` | float | The error budget the sweep had to meet |
| `max_z` / `wad` / `scale_decimal` | str | The domain bound and scales (see `shared/constants.py`) |
| `num_coeffs_str` / `den_coeffs_str` | list[str] | N(z), D(z) coefficients, ascending power order |
| `support_points` / `support_values` / `weights` | list[float] | Raw AAA barycentric form (audit aid) |

## Layout

```text
gaussian_codegen/
├── Makefile             # install / regen / validate / check / ci / test
├── shared/
│   ├── constants.py     # single source of truth: WAD scales, domain bounds
│   ├── reference.py     # mpmath oracle: Φ, φ, and Φ⁻¹ (erfinv) at 100 dps
│   ├── aaa.py           # AAA barycentric → N(z)/D(z) polynomial conversion
│   ├── arithmetic.py    # integer mirror of the on-chain Horner / ln / sqrt kernels
│   ├── gates.py         # exhaustive neighbor-monotonicity + u256 overflow gates
│   └── move_emit.py     # Move literal / banner / drift-check helpers
├── cdf/                 # derive.py, emit_coefficients.py, emit_test_vectors.py, validate.py
├── pdf/                 # (same shape)
├── inverse_cdf/         # (same shape; two-region central + tail fit)
└── tests/               # pytest: quantizer, emitter boundary, arithmetic mirror, per-family
```

## Adding a new function family

`pdf/`, `inverse_cdf/`, etc. follow the same shape. Roughly:

1. Add any new shared bound/scale to `shared/constants.py` (don't hardcode it).
2. Create `<family>/derive.py` - fit and write `<family>/.derive_output.json`
   (add the dotfile to `.gitignore`).
3. Create `<family>/emit_*.py` - quantize/emit the Move file(s), reusing the
   `shared/move_emit.py` helpers and adding a `--check` mode.
4. Create `<family>/validate.py` - re-run the on-chain integer arithmetic in
   Python and assert the error bound against the committed Move file.
5. Add unit tests under `tests/`, and wire `validate` + the new drift check
   into `.github/workflows/test.yml` and the `Makefile`.

## Generated files

Both committed Move files carry an `AUTO-GENERATED` banner and must not be
hand-edited; regenerate via the steps above.

| Path | Generated by |
|------|--------------|
| `math/fixed_point/sources/internal/cdf_coefficients.move` | `scripts/gaussian_codegen/cdf/derive.py` + `scripts/gaussian_codegen/cdf/emit_coefficients.py` |
| `math/fixed_point/tests/sd29x9_tests/cdf_test_vectors.move` | `scripts/gaussian_codegen/cdf/emit_test_vectors.py` |
| `math/fixed_point/tests/ud30x9_tests/cdf_test_vectors.move` | `scripts/gaussian_codegen/cdf/emit_test_vectors.py` |
| `math/fixed_point/sources/internal/pdf_coefficients.move` | `scripts/gaussian_codegen/pdf/derive.py` + `scripts/gaussian_codegen/pdf/emit_coefficients.py` |
| `math/fixed_point/tests/sd29x9_tests/pdf_test_vectors.move` | `scripts/gaussian_codegen/pdf/emit_test_vectors.py` |
| `math/fixed_point/tests/ud30x9_tests/pdf_test_vectors.move` | `scripts/gaussian_codegen/pdf/emit_test_vectors.py` |
| `math/fixed_point/sources/internal/inverse_cdf_coefficients.move` | `scripts/gaussian_codegen/inverse_cdf/derive.py` + `scripts/gaussian_codegen/inverse_cdf/emit_coefficients.py` |
| `math/fixed_point/tests/sd29x9_tests/inverse_cdf_test_vectors.move` | `scripts/gaussian_codegen/inverse_cdf/emit_test_vectors.py` |
| `math/fixed_point/tests/ud30x9_tests/inverse_cdf_test_vectors.move` | `scripts/gaussian_codegen/inverse_cdf/emit_test_vectors.py` |
