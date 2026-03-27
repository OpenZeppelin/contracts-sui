module openzeppelin_collections::random;

public struct Random has copy, drop, store {
    seed: u64,
}

public(package) fun new(seed: u64): Random {
    Random {
        seed,
    }
}

public(package) fun rand(r: &mut Random): u64 {
    r.seed = (
        (
            ((9223372036854775783u128 * ((r.seed as u128)) + 999983) >> 1) & 0x0000000000000000ffffffffffffffff,
        ) as u64,
    );
    r.seed
}
