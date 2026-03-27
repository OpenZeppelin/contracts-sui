/// Pseudo-random number generation utilities for collection tests and helpers.
///
/// This module provides a small stateful generator backed by a deterministic
/// linear congruential generator. It is suitable for reproducible internal flows
/// where callers need cheap evolving values from a `u64` seed.
module openzeppelin_collections::random;

/// Deterministic pseudo-random generator state.
///
/// The generator stores the current seed and updates it in place every time
/// `rand` is called.
public struct Random has copy, drop, store {
    seed: u64,
}

/// Create a new pseudo-random generator from an initial seed.
///
/// #### Parameters
/// - `seed`: Initial generator state.
///
/// #### Returns
/// - A `Random` instance initialised with `seed`.
public(package) fun new(seed: u64): Random {
    Random {
        seed,
    }
}

/// Advance the generator state and return the next pseudo-random value.
///
/// The returned value is also stored back into `r.seed`, so repeated calls on
/// the same generator produce a deterministic sequence derived from the initial
/// seed.
///
/// #### Parameters
/// - `r`: Mutable reference to the generator state.
///
/// #### Returns
/// - The next generated `u64` value.
public(package) fun rand(r: &mut Random): u64 {
    r.seed = (
        (
            ((9223372036854775783u128 * ((r.seed as u128)) + 999983) >> 1) & 0x0000000000000000ffffffffffffffff,
        ) as u64,
    );
    r.seed
}
