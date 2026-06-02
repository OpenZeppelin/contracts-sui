# `openzeppelin_fp_math` Codegen

This directory is an **offline Python toolkit**. It computes the numeric
constants that the `cdf` (standard-normal CDF) function in `openzeppelin_fp_math`
needs, and writes them into the Move source as generated tables.

Nothing here runs on-chain, and nothing here is needed to *use* the library —
the Move package is fully self-contained at runtime. You only touch this
directory to **(re)generate or re-validate** those constants.

If you just want to consume the library, you can stop reading and head to
the [`openzeppelin_fp_math` package README](../README.md). The rest of
this document is for anyone curious *why* a Move library ships Python, or who
needs to regenerate the tables.

## Why does a Move library ship Python code?

Short version: the `cdf` function needs around twenty carefully-chosen
constants that are genuinely hard to compute; computing them needs
floating-point and arbitrary-precision math that Move doesn't have; and it only
has to happen once. So we do it offline in Python and bake the results into the
Move source.

The longer version is worth understanding.

**What `cdf` computes.** Φ(z) — the *standard-normal CDF* — is the probability
that a normally-distributed value lands at or below `z`: the area under the bell
curve to the left of `z`. It's a building block for options pricing, risk
models, and sampling. What matters for this toolkit is *how* we get the number,
not what it's used for.

**Why you can't just compute it on-chain.** Φ has no elementary formula — it's
defined by an integral with no closed form. The usual ways to evaluate it lean
on `exp(−z²/2)` or the error function `erf`. But Move has **no floating point
and no transcendental functions** — only integer arithmetic on our fixed-point
types. There is no `exp`, no `erf`, nothing to build Φ out of directly.

**The trick: approximate the curve, don't compute it.** Instead of evaluating Φ,
we approximate the *whole curve* with a **rational function** `N(z) / D(z)` —
one polynomial divided by another. With the right coefficients, a degree-9
rational matches Φ to about `10⁻⁹` across the domain using nothing but
multiplies and a single divide — operations Move *does* have. (The approach is
from [Evan Kim's "On-Chain Atomic Gaussian Math"](https://paragraph.com/@evandekim/on-chain-atomic-gaussian-math);
we re-derived our own coefficients rather than copying his.)

**Why the work is split offline/on-chain.** Finding those coefficients is heavy
numerical work; *evaluating* them is trivial. So we split it:

- **Offline, once (this toolkit):** feed high-precision samples of Φ to a
  curve-fitting algorithm, get near-optimal coefficients, validate them against
  a 100-digit reference, and write them into Move as integer constants.
- **On-chain, every call (the Move code):** evaluate the two polynomials with
  Horner's method and divide. A handful of integer multiplies — deterministic,
  constant gas. See `../sources/internal/cdf.move` (and the shared primitives in
  `../sources/internal/horner.move`).

**Why AAA, and why Python.** The fitting algorithm is **AAA** (Adaptive
Antoulas–Anderson). You hand it samples of a function and it automatically
produces a near-optimal rational fit — no hand-tuning of degree or coefficient
placement. It ships in `scipy.interpolate.AAA` (added in SciPy 1.15.0), and the
high-precision reference math uses `mpmath`. Neither could run on-chain — they
need floats and arbitrary precision and are far too expensive — which is exactly
why this half lives here, offline, and only the cheap half ships in Move.

Even symmetry makes it cheaper still: we fit only the right half `[0, 6.3]` and
the Move code reflects negatives via Φ(−z) = 1 − Φ(z).

## How the pipeline fits together

Three stages, four scripts. Generation flows left to right; `validate.py` is an
independent re-check that closes the loop.

```
derive.py ──► .derive_output.json ──┬─► emit_coefficients.py ──► cdf_coefficients.move
(AAA fit)        (chosen coeffs)     └─► emit_test_vectors.py  ──► cdf_test_vectors.move (×2)

validate.py ──► parses the committed cdf_coefficients.move, re-runs it, checks vs scipy
```

- **`derive.py`** — runs the AAA fit, sweeps the polynomial degree, picks the
  smallest one that meets the `5×10⁻⁹` error target, and writes the chosen
  coefficients to a JSON intermediate.
- **`emit_coefficients.py`** — reads that JSON, quantizes the coefficients to
  fixed-point integers, and writes `cdf_coefficients.move`.
- **`emit_test_vectors.py`** — emits the Move test vectors (expected Φ at chosen
  `z`, taken straight from the high-precision `mpmath` oracle).
- **`validate.py`** — the independent check, and the CI gate. It does **not**
  re-derive: it parses the committed `cdf_coefficients.move` and re-runs the
  exact on-chain integer arithmetic in Python, asserting the quantized error
  stays within budget (≤ 5 ULP at `10⁻⁹`) against `scipy`.

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
were generated with these exact versions — pin to them to reproduce the tables
byte-for-byte:

| Package | Version |
|---------|---------|
| Python  | 3.14.2  |
| mpmath  | 1.4.1   |
| scipy   | 1.17.1  |
| numpy   | 2.4.4   |

## Install

From the repo root:

```sh
python3 -m venv math/fixed_point/codegen/.venv
source math/fixed_point/codegen/.venv/bin/activate
pip install -e "math/fixed_point/codegen[dev]"   # omit [dev] to skip pytest
```

This installs the `codegen` package (editable) so `python -m codegen.cdf.*`
works from any directory. `make -C math/fixed_point/codegen install` does the same.

## Generate (CDF)

```sh
python -m codegen.cdf.derive            # AAA fit + degree sweep → .derive_output.json
python -m codegen.cdf.emit_coefficients # → math/fixed_point/sources/internal/cdf_coefficients.move
python -m codegen.cdf.emit_test_vectors # → tests/{sd29x9_tests,ud30x9_tests}/cdf_test_vectors.move
python -m codegen.cdf.validate          # re-checks the committed coefficient module against scipy
```

Or via the Makefile (`make -C math/fixed_point/codegen <target>`): `regen` (the first three),
`validate`, `check` (drift guard), `test` (pytest), `ci` (what CI runs).

`derive.py` writes a JSON intermediate (`math/fixed_point/codegen/cdf/.derive_output.json`,
gitignored) that the `emit_*.py` scripts consume.

### Drift guard

Both emitters accept `--check`: they render to memory and compare against the
committed Move file byte-for-byte, exiting non-zero on any difference (without
writing). Output is deterministic — the banner carries no timestamp — so a
no-op regeneration produces no diff. `emit_test_vectors --check` is standalone;
`emit_coefficients --check` needs a prior `derive` run for the JSON input.

### What CI runs

CI runs `validate.py`, `emit_test_vectors --check` (the test-vector drift
guard), and the Python unit tests (`pytest`). Coefficient re-derivation stays
local-only: it depends on the gitignored `.derive_output.json`, and the
committed coefficients are instead guarded semantically by `validate.py`.

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

```
codegen/
├── Makefile             # install / regen / validate / check / ci / test
├── shared/
│   ├── constants.py     # single source of truth: WAD, scales, domain bound
│   ├── reference.py     # mpmath oracle for Φ at 100 dps
│   └── move_emit.py     # Move literal / banner / drift-check helpers
├── cdf/
│   ├── derive.py
│   ├── emit_coefficients.py
│   ├── emit_test_vectors.py
│   └── validate.py
└── tests/               # pytest: quantizer, emitter boundary, arithmetic mirror
```

## Adding a new function family

`pdf/`, `inverse_cdf/`, etc. follow the same shape. Roughly:

1. Add any new shared bound/scale to `shared/constants.py` (don't hardcode it).
2. Create `<family>/derive.py` — fit and write `<family>/.derive_output.json`
   (add the dotfile to `.gitignore`).
3. Create `<family>/emit_*.py` — quantize/emit the Move file(s), reusing the
   `shared/move_emit.py` helpers and adding a `--check` mode.
4. Create `<family>/validate.py` — re-run the on-chain integer arithmetic in
   Python and assert the error bound against the committed Move file.
5. Add unit tests under `tests/`, and wire `validate` + the new drift check
   into `.github/workflows/test.yml` and the `Makefile`.

## Generated files

Both committed Move files carry an `AUTO-GENERATED` banner and must not be
hand-edited; regenerate via the steps above.

| Path | Generated by |
|------|--------------|
| `math/fixed_point/sources/internal/cdf_coefficients.move` | `math/fixed_point/codegen/cdf/derive.py` + `math/fixed_point/codegen/cdf/emit_coefficients.py` |
| `math/fixed_point/tests/sd29x9_tests/cdf_test_vectors.move` | `math/fixed_point/codegen/cdf/emit_test_vectors.py` |
| `math/fixed_point/tests/ud30x9_tests/cdf_test_vectors.move` | `math/fixed_point/codegen/cdf/emit_test_vectors.py` |
