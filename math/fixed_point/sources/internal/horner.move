/// Generic sign-magnitude `u256` arithmetic at a caller-supplied fixed-point
/// scale, plus a Horner polynomial evaluator. Shared by the gaussian function
/// family (`cdf`, `pdf`, and `inverse_cdf`).
///
/// This module is deliberately free of any function-specific coefficient
/// dependency: it provides only the reusable numeric primitives, so each
/// consumer supplies its own coefficient table and accumulation scale (`cdf` and
/// `pdf` run at `10^36`). Concretely it offers a `SignedScaled256` value,
/// sign-aware add and a per-call-scaled multiply (`mul_wad`), and the
/// `horner_eval!` macro that evaluates a polynomial via Horner's method given a
/// `(u128, bool)` coefficient accessor and that scale.
module openzeppelin_fp_math::horner;

// === Errors ===

/// Polynomial must have at least one coefficient.
#[error(code = 0)]
const EEmptyPolynomial: vector<u8> = "Polynomial must have at least one coefficient";

// === Structs ===

/// Sign-magnitude representation used during Horner accumulation at the caller's
/// fixed-point scale.
///
/// The magnitude is `u256` so that the WAD-scale product `a × b` cannot
/// overflow as long as callers keep magnitudes bounded (see the precondition on
/// `mul_wad`). The sign rides as a separate flag because Move lacks
/// signed integer types.
///
/// Visibility note: the type is declared `public` because Move 2024 does not
/// yet support `public(package)` on struct declarations, but it is effectively
/// package-internal: only `public(package)` constructors in this module can
/// produce one, and the abilities deliberately omit `store`/`key` so it cannot
/// be persisted or wrapped in a stored type by an external consumer.
///
/// Convention: zero is always represented canonically as `(mag = 0, neg = false)`.
public struct SignedScaled256 has copy, drop {
    mag: u256,
    neg: bool,
}

// === Package Functions ===

// === Constructors ===

/// The neutral additive element.
public(package) fun zero(): SignedScaled256 {
    SignedScaled256 { mag: 0, neg: false }
}

/// Wrap a non-negative WAD-scaled magnitude.
public(package) fun from_unsigned(mag: u256): SignedScaled256 {
    SignedScaled256 { mag, neg: false }
}

/// Wrap a `(u128 magnitude, bool sign)` coefficient encoding, promoting the
/// magnitude to `u256` and canonicalizing zero to `(0, false)`.
public(package) fun from_coeff(mag: u128, neg: bool): SignedScaled256 {
    let mag_u256 = mag as u256;
    SignedScaled256 {
        mag: mag_u256,
        neg: mag_u256 != 0 && neg,
    }
}

// === Accessors ===

public(package) fun mag(x: &SignedScaled256): u256 { x.mag }

public(package) fun is_neg(x: &SignedScaled256): bool { x.neg }

// === Arithmetic ===

/// Sign-magnitude addition.
/// - Same-sign: add magnitudes, keep the sign.
/// - Opposite-sign: subtract the smaller from the larger, inherit the larger's sign.
/// - Exact cancellation: return canonical zero.
public(package) fun add(a: SignedScaled256, b: SignedScaled256): SignedScaled256 {
    if (a.mag == 0) return b;
    if (b.mag == 0) return a;
    if (a.neg == b.neg) {
        SignedScaled256 { mag: a.mag + b.mag, neg: a.neg }
    } else if (a.mag > b.mag) {
        SignedScaled256 { mag: a.mag - b.mag, neg: a.neg }
    } else if (b.mag > a.mag) {
        SignedScaled256 { mag: b.mag - a.mag, neg: b.neg }
    } else {
        zero()
    }
}

/// Add a `(u128 magnitude, bool sign)` coefficient to `acc`, promoting the
/// coefficient to `u256` and folding the cast + sign-magnitude add into a
/// single step. Equivalent to `add(acc, from_coeff(mag, neg))`
/// but avoids materializing the intermediate `SignedScaled256` - used on the
/// `horner_eval!` hot inner loop.
public(package) fun add_coeff(acc: SignedScaled256, mag: u128, neg: bool): SignedScaled256 {
    let m = mag as u256;
    if (m == 0) return acc; // adding zero is a no-op (also covers canonicalization)
    if (acc.mag == 0) return SignedScaled256 { mag: m, neg };
    if (acc.neg == neg) {
        SignedScaled256 { mag: acc.mag + m, neg: acc.neg }
    } else if (acc.mag > m) {
        SignedScaled256 { mag: acc.mag - m, neg: acc.neg }
    } else if (m > acc.mag) {
        SignedScaled256 { mag: m - acc.mag, neg }
    } else {
        zero()
    }
}

/// Scaled multiplication: `(a × b) / wad` with truncation toward zero on the
/// magnitude (equivalent to `mul_div(..., Down)` rounding) and XOR signs. `wad`
/// is the caller's fixed-point accumulation scale, passed per call so each
/// gaussian family runs at its own precision (`cdf` and `pdf` use `10^36`).
/// Zero canonicalization ensures any product whose magnitude floors to zero
/// returns canonical zero.
///
/// #### Precondition
/// The caller must keep magnitudes bounded so that the full-width product
/// `a.mag × b.mag` fits in `u256` (`< 2^256`); this is **not** checked here, for
/// efficiency. At `wad = 10^36` the peak intermediate is ~`1.1 × 10^74` for the
/// CDF (`|z| ≤ 6.109410205`; 246 bits, ~10 under `2^256`) and ~`2.6 × 10^74` for
/// the PDF (`|z| ≤ 6.402729806`; 248 bits, ~8 under `2^256`). A new consumer, a
/// higher degree, or a wider domain must re-establish this bound - the codegen's
/// `check_overflow_margin` gate does so for the committed tables.
///
/// #### Aborts
/// - Arithmetic overflow if the full-width product `a.mag * b.mag` exceeds `u256`.
///   The caller guarantees this cannot happen (see Precondition); it is not
///   checked here.
public(package) fun mul_wad(a: SignedScaled256, b: SignedScaled256, wad: u256): SignedScaled256 {
    let mag = (a.mag * b.mag) / wad;
    let neg = mag != 0 && a.neg != b.neg;
    SignedScaled256 { mag, neg }
}

// === Horner Evaluator ===

/// Helper used by `horner_eval!` so the macro body can preflight the length
/// without referencing a module-private constant from the caller's scope.
public(package) fun assert_polynomial_nonempty(len: u64) {
    assert!(len > 0, EEmptyPolynomial);
}

/// Evaluate the polynomial
///
///   `c[len-1] · z^(len-1) + ... + c[1] · z + c[0]`
///
/// via Horner's method. Coefficients are pulled in *ascending* power order by
/// `$coeff_at`, which returns `(u128 magnitude, bool is_negative)` at WAD
/// scale. The accessor is invoked exactly once per coefficient.
///
/// All arithmetic is sign-magnitude `u256` at scale `$wad`; `$z` must already be
/// scaled to `$wad`.
///
/// #### Precondition
/// Inherits `mul_wad`'s bound: the caller must keep `$z` and the coefficients
/// small enough that no intermediate `acc.mag × z.mag` exceeds `u256`. Satisfied
/// for the CDF and PDF by their saturation guards at `$wad = 10^36` (see `mul_wad`).
///
/// #### Aborts
/// - Aborts with `EEmptyPolynomial` if `$len == 0`.
public(package) macro fun horner_eval(
    $z: SignedScaled256,
    $len: u64,
    $coeff_at: |u64| -> (u128, bool),
    $wad: u256,
): SignedScaled256 {
    let z = $z;
    let len = $len;
    let wad = $wad;
    assert_polynomial_nonempty(len);

    let last = len - 1;
    let (m_last, n_last) = $coeff_at(last);
    let mut acc = from_coeff(m_last, n_last);

    let mut i = last;
    while (i > 0) {
        i = i - 1;
        acc = mul_wad(acc, z, wad);
        let (m_i, n_i) = $coeff_at(i);
        acc = add_coeff(acc, m_i, n_i);
    };
    acc
}
