# `openzeppelin_fp_math`

Fixed-point decimal types with 9 decimals (10^9), matching Sui coin precision.

## Install

```toml
[dependencies]
openzeppelin_fp_math = { r.mvr = "@openzeppelin-move/fixed-point-math" }
```

## Types

- `UD30x9`: Unsigned decimal fixed-point (internal: 0 to 2^128 - 1; decimal: 0 to ~3.4e29)
- `SD29x9`: Signed decimal fixed-point (two's complement, internal: -2^127 to 2^127 - 1; decimal: ~-1.7e29 to ~1.7e29)

## Operations

- Arithmetic: `add`, `sub`, `mul`, `mul_trunc`, `mul_away`, `div`, `div_trunc`, `div_away`, `pow`, `unchecked_add`, `unchecked_sub`, `mod`, `sqrt`
- Logarithms: `log2`, `ln`, `log10`
- Distributions: `cdf` (standard-normal CDF `Φ`), `pdf` (standard-normal PDF `φ`)
- Comparison: `eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `is_zero`
- `UD30x9` also exposes bitwise helpers: `and`, `and2`, `or`, `xor`, `not`, `lshift`, `rshift`, `unchecked_lshift`, `unchecked_rshift`

## Casting vs Converting

This package uses **casting** and **converting** for different operations:

- **Casting** preserves the fixed-point scale already present in the value.
  It may reinterpret raw bits, or move between fixed-point types with only
  sign and range checks. It does **not** multiply or divide by `10^9`.
- **Converting** changes between whole-number semantics and fixed-point
  semantics. It applies or removes the `10^9` scale factor.

Rule of thumb:

- Use a **cast** when your input is already in raw fixed-point form.
- Use a **conversion** when your input is a whole integer like `42` and you
  mean `42.0`.

## Raw Casts

The core `wrap` / `unwrap` APIs are **raw casts**. They preserve the
underlying fixed-point representation and do not multiply or divide by `10^9`.

- `u128 -> UD30x9`: `into_UD30x9`
- `UD30x9 -> SD29x9`: `into_SD29x9`, `try_into_SD29x9`
- `SD29x9 -> UD30x9`: `into_UD30x9`, `try_into_UD30x9`
- Constructors: `zero`, `one`, `max`, `wrap`
- `SD29x9` only: `min`, `from_bits`

```move
use openzeppelin_fp_math::{sd29x9, ud30x9};

let one = ud30x9::wrap(1_000_000_000); // 1.0
let raw = ud30x9::wrap(42); // Raw bits, not 42.0

let positive = sd29x9::wrap(1_000_000_000, false); // 1.0
let negative = sd29x9::wrap(42, true); // Raw bits for -0.000000042
```

## Cross-Type Fixed-Point Casts

Casting also includes moves between fixed-point types that keep the same
scaled numeric meaning and only validate signedness or range.

```move
use openzeppelin_fp_math::{sd29x9, ud30x9_convert};

let unsigned = ud30x9_convert::from_u128(42); // 42.0
let signed = unsigned.into_SD29x9(); // 42.0 as SD29x9
let roundtrip = signed.into_UD30x9(); // 42.0 as UD30x9
```

These casts do not rescale the value. For example, `42.123456789` stays
`42.123456789`; only the target type changes.

## Whole-Number Conversions

Use the conversion modules when you want semantic integer conversions that
apply the fixed-point scale for you.

```move
use openzeppelin_fp_math::{sd29x9_convert, ud30x9_convert};

let whole = ud30x9_convert::from_u128(42); // 42.0
let back = whole.to_u128_trunc(); // 42

let delta = sd29x9_convert::from_u128(5, true); // -5.0
let (magnitude, is_negative) = delta.to_parts_trunc();
// magnitude == 5, is_negative == true
```

Because Move does not provide a native signed integer type for this package,
`SD29x9` conversions use an unsigned magnitude plus a sign flag instead of a
single `i128`-style input or output.

## Logarithms

`log2`, `ln`, and `log10` are computed from a shared `log2` kernel; `ln` and
`log10` apply a base-conversion factor on top.

- **UD30x9** aborts for `0 < x < 1` because the fixed-point logarithm would be
  negative; **UD30x9** also aborts for `x == 0` because the log operation is
  undefined/invalid. Rounds down.
- **SD29x9** aborts on `x <= 0`. Rounds toward zero, matching `mul_trunc`,
  `div_trunc`, and `pow` in the same module.

`log10` is exact on integer powers of ten (including sub-unit `10^-k` on
`SD29x9`): `log10(10^k) == k * SCALE`.

```move
use openzeppelin_fp_math::{sd29x9, ud30x9_convert};

let two = ud30x9_convert::from_u128(2);
let _ = two.log2();   // 1.0
let _ = two.ln();     // 0.693147180
let _ = two.log10();  // 0.301029995

let half = sd29x9::wrap(500_000_000, false); // 0.5
let _ = half.log2();  // -1.0
```

## Standard-normal CDF

`Φ(z)` is the standard-normal cumulative distribution function: the probability
that a standard-normal draw lands at or below `z` (the area under the bell curve
to the left of `z`). It is a building block for options pricing, risk models,
and sampling. Both fixed-point types expose it:

- `UD30x9::cdf` takes non-negative `z` and returns `Φ(z) ∈ [0.5, 1]`.
- `SD29x9::cdf` takes signed `z` and returns `Φ(z) ∈ [0, 1]`.

Properties:

- **Accuracy**: max absolute error `≤ 5 × 10⁻⁹` (5 ULP at the `10⁹` scale);
  empirical worst case `~7 × 10⁻¹⁰`.
- **Domain**: effective input range `|z| ≤ 6.3`; beyond that the result
  saturates.
- **Saturation**: exactly `0` for `z ≤ -6.3` (SD29x9) and exactly `1` for
  `z ≥ 6.3`.
- **Φ(0)**: exactly `0.5`.
- **Symmetry**: `cdf(z) + cdf(z.negate())` is exactly `1` for every `SD29x9`
  input.
- **Execution**: pure, deterministic, and object-free integer math - no storage,
  no Sui objects; identical inputs always yield identical outputs.

```move
use openzeppelin_fp_math::{sd29x9, ud30x9};

let z = ud30x9::wrap(1_000_000_000); // 1.0
let p = z.cdf(); // 0.841344746  (P(Z ≤ 1))

let neg = sd29x9::wrap(1_000_000_000, true); // -1.0
let q = neg.cdf(); // 0.158655254  (P(Z ≤ -1))
```

Limitations: the approximation is defined on `|z| ≤ 6.3` and saturates outside
that range; `10⁻⁹` is the finest distinction the output can represent. There is
no floating point - results are exact fixed-point integer arithmetic.

## Standard-normal PDF

`φ(z)` is the standard-normal probability density function
`e^(-z^2/2) / sqrt(2*pi)`: the height of the bell curve at `z`, and the
derivative of `Φ`. It appears in options Greeks (gamma, vega), maximum-likelihood
objectives, and density estimation. Both fixed-point types expose it:

- `UD30x9::pdf` takes non-negative `z` and returns `φ(z) ∈ [0, φ(0)]`.
- `SD29x9::pdf` takes signed `z` and returns `φ(z) ∈ [0, φ(0)]` (always non-negative).

Properties:

- **Accuracy**: max absolute error `≤ 5 × 10⁻⁹` (5 ULP at the `10⁹` scale);
  empirical worst case `~6 × 10⁻¹⁰`.
- **Domain**: effective input range `|z| ≤ 6.5`; beyond that the result
  saturates to `0`.
- **Peak**: `φ(0) = 0.398942280` (`1/sqrt(2*pi)`), returned exactly.
- **Symmetry**: even - `pdf(z)` equals `pdf(z.negate())` for every `SD29x9` input.
- **Execution**: pure, deterministic, and object-free integer math - no storage,
  no Sui objects; identical inputs always yield identical outputs.

```move
use openzeppelin_fp_math::{sd29x9, ud30x9};

let z = ud30x9::wrap(1_000_000_000); // 1.0
let d = z.pdf(); // 0.241970725  (height of the bell curve at z = 1)

let neg = sd29x9::wrap(1_000_000_000, true); // -1.0
let e = neg.pdf(); // 0.241970725  (φ is even)
```

Limitations: the approximation is defined on `|z| ≤ 6.5` and saturates to `0`
outside that range; `10⁻⁹` is the finest distinction the output can represent.

## Usage Example

```move
use openzeppelin_fp_math::{sd29x9, sd29x9_convert, ud30x9, ud30x9_convert};

let price1 = ud30x9_convert::from_u128(1).add(ud30x9::wrap(500_000_000)); // 1.5
let price2 = ud30x9_convert::from_u128(2); // 2.0
let total = price1.add(price2); // 3.5

let balance = sd29x9_convert::from_u128(10, false); // 10.0
let adjustment = sd29x9_convert::from_u128(2, true).add(sd29x9::wrap(500_000_000, true)); // -2.5
let new_balance = balance.add(adjustment); // 7.5

let one = ud30x9::wrap(1000000000); // 1.0
let third_down = one.div_trunc(ud30x9::wrap(3000000000)); // 0.333333333
let third_up = one.div_away(ud30x9::wrap(3000000000)); // 0.333333334
```

## Generated code

The standard-normal CDF (`cdf`) and PDF (`pdf`) are backed by AAA-rational
approximations whose coefficients and test vectors are generated offline and must
**not** be hand-edited (each carries an `AUTO-GENERATED` banner):

- `sources/internal/cdf_coefficients.move`
- `sources/internal/pdf_coefficients.move`
- `tests/{sd29x9_tests,ud30x9_tests}/cdf_test_vectors.move`
- `tests/{sd29x9_tests,ud30x9_tests}/pdf_test_vectors.move`

To regenerate them — or to re-validate the committed coefficients against
`scipy` — see [`scripts/gaussian_codegen/`](../../scripts/gaussian_codegen/README.md).

## Learn More

- [Fixed-point math package overview](https://docs.openzeppelin.com/contracts-sui/1.x/fixed-point)
- [Fixed-point math API reference](https://docs.openzeppelin.com/contracts-sui/1.x/api/fixed-point)
- [OpenZeppelin Contracts for Sui](https://docs.openzeppelin.com/contracts-sui)
