/// # Casting from u128 to fixed-point types
///
/// This module provides helper functions to cast a `u128` number into a fixed-point type.
module openzeppelin_fp_math::casting_u128;

use openzeppelin_fp_math::ud30x9::{UD30x9, wrap};

public fun into_UD30x9(x: u128): UD30x9 {
    wrap(x)
}
