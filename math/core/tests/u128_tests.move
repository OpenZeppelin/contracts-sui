module openzeppelin_math::u128_tests {
    use openzeppelin_math::{macros, rounding, u128};
    use std::unit_test::assert_eq;

    // === mul_div ===

    // Sanity-check rounding before we switch to the wide helper.
    #[test]
    fun mul_div_rounding_modes() {
        let (down_overflow, down) = u128::mul_div(70, 10, 4, rounding::down());
        assert_eq!(down_overflow, false);
        assert_eq!(down, 175);

        let (up_overflow, up) = u128::mul_div(5, 3, 4, rounding::up());
        assert_eq!(up_overflow, false);
        assert_eq!(up, 4);

        let (nearest_overflow, nearest) = u128::mul_div(7, 10, 4, rounding::nearest());
        assert_eq!(nearest_overflow, false);
        assert_eq!(nearest, 18);
    }

    // Straightforward division should not be perturbed by rounding.
    #[test]
    fun mul_div_exact_division() {
        let (overflow, exact) = u128::mul_div(8_000, 2, 4, rounding::up());
        assert_eq!(overflow, false);
        assert_eq!(exact, 4_000);
    }

    // Keep coverage over the shared macro guard.
    #[test, expected_failure(abort_code = macros::EDivideByZero)]
    fun mul_div_rejects_zero_denominator() {
        u128::mul_div(1, 1, 0, rounding::down());
    }

    // Casting down from u256 must still flag when values exceed u128’s range.
    #[test]
    fun mul_div_detects_overflow() {
        let (overflow, result) = u128::mul_div(std::u128::max_value!(), 2, 1, rounding::down());
        assert_eq!(overflow, true);
        assert_eq!(result, 0);
    }

    // === average ===

    #[test]
    fun average_rounding_modes() {
        let down = u128::average(7, 10, rounding::down());
        assert_eq!(down, 8);

        let up = u128::average(7, 10, rounding::up());
        assert_eq!(up, 9);

        let nearest = u128::average(1, 2, rounding::nearest());
        assert_eq!(nearest, 2);
    }

    #[test]
    fun average_is_commutative() {
        let left = u128::average(1_000, 100, rounding::nearest());
        let right = u128::average(100, 1_000, rounding::nearest());
        assert_eq!(left, right);
    }
}
