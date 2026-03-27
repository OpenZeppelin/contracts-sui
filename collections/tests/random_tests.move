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

#[test]
fun test_max_seed_produces_deterministic_values() {
    let mut random = new(std::u64::max_value!());
    assert_eq!(random.rand(), 4611686018427887908);
    assert_eq!(random.rand(), 16140901064490107605);
    assert_eq!(random.rand(), 5764607523106610609);
}

#[random_test]
fun test_same_seed_produces_same_sequence(seed: u64) {
    let mut random1 = new(seed);
    let mut random2 = new(seed);
    assert_eq!(random1.rand(), random2.rand());
}
