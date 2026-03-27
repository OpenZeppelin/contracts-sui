#[test_only]
module openzeppelin_collections::random_tests;

use openzeppelin_collections::random::new;
use std::unit_test::assert_eq;

#[test]
fun test_new() {
    let mut random = new(0);
    assert_eq!(random.rand(), 499991);
    assert_eq!(random.rand(), 13835058055276413816);
    assert_eq!(random.rand(), 11529215046140843451);
}

#[test]
fun test_with_seed_0() {
    let mut random = new(0);
    let mut n = 0u64;
    while (n < 1000) {
        let r1 = random.rand();
        let r2 = random.rand();
        let r3 = random.rand();
        assert!(r1 != 0 || r2 != 0 || r3 != 0);
        assert!(!((r1 == r2) && (r2 == r3)));
        n = n + 1;
    }
}

#[random_test]
fun test_rand_produces_distinct_sequential_values(seed: u64) {
    let mut random = new(seed);
    let r1 = random.rand();
    let r2 = random.rand();
    assert!(r1 != r2);
}
