#[test_only]
module openzeppelin_collections::skip_list_tests;

use openzeppelin_collections::skip_list::{Self, SkipList};
use std::unit_test::assert_eq;

// ============================================================
// Helpers
// ============================================================

fun new_list(ctx: &mut TxContext): SkipList<u64, u64> {
    skip_list::new(16, 2, 42, ctx)
}

fun assert_scores(list: &SkipList<u64, u64>, expected: vector<u64>) {
    assert_eq!(skip_list::get_all_scores(list), expected);
}

// ============================================================
// Construction
// ============================================================

#[test]
fun test_new_list_is_empty() {
    let mut ctx = tx_context::dummy();
    let list = new_list(&mut ctx);
    assert!(list.is_empty());
    assert_eq!(list.length(), 0);
    assert!(list.head().is_none());
    assert!(list.tail().is_none());
    list.destroy_empty();
}

#[test]
#[expected_failure(abort_code = skip_list::EInvalidListP)]
fun test_new_list_p_zero_aborts() {
    let mut ctx = tx_context::dummy();
    let list: SkipList<u64, u64> = skip_list::new(16, 0, 42, &mut ctx);
    list.destroy_empty();
}

#[test]
#[expected_failure(abort_code = skip_list::EInvalidListP)]
fun test_new_list_p_one_aborts() {
    let mut ctx = tx_context::dummy();
    let list: SkipList<u64, u64> = skip_list::new(16, 1, 42, &mut ctx);
    list.destroy_empty();
}

// ============================================================
// Single-element operations
// ============================================================

#[test]
fun test_insert_and_remove_single_element() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(10, 100);

    assert!(!list.is_empty());
    assert_eq!(list.length(), 1);
    assert_eq!(*list.head().borrow(), 10);
    assert_eq!(*list.tail().borrow(), 10);
    assert!(list.contains(10));
    assert_eq!(*list.borrow(10), 100);
    skip_list::check_skip_list!(&list);

    let val = list.remove!(10);
    assert_eq!(val, 100);
    assert!(list.is_empty());
    list.destroy_empty();
}

// ============================================================
// Insert ordering
// ============================================================

#[test]
fun test_insert_ascending_order() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    let mut i = 1u64;
    while (i <= 10) { list.insert!(i, i * 10); i = i + 1; };

    assert_eq!(list.length(), 10);
    assert_eq!(*list.head().borrow(), 1);
    assert_eq!(*list.tail().borrow(), 10);
    assert_scores(&list, vector[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    skip_list::check_skip_list!(&list);

    i = 1;
    while (i <= 10) { list.remove!(i); i = i + 1; };
    list.destroy_empty();
}

#[test]
fun test_insert_descending_order() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    let mut i = 10u64;
    while (i > 0) {
        list.insert!(i, i * 10);
        i = i - 1;
    };

    assert_eq!(*list.head().borrow(), 1);
    assert_eq!(*list.tail().borrow(), 10);
    assert_scores(&list, vector[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    skip_list::check_skip_list!(&list);

    i = 1;
    while (i <= 10) { list.remove!(i); i = i + 1; };
    list.destroy_empty();
}

#[test]
fun test_insert_random_order() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    let keys = vector[5, 3, 8, 1, 9, 2, 7, 4, 10, 6];
    let mut i = 0u64;
    while (i < keys.length()) {
        let k = *keys.borrow(i);
        list.insert!(k, k * 10);
        i = i + 1;
    };

    assert_eq!(*list.head().borrow(), 1);
    assert_eq!(*list.tail().borrow(), 10);
    assert_scores(&list, vector[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    skip_list::check_skip_list!(&list);

    i = 1;
    while (i <= 10) { list.remove!(i); i = i + 1; };
    list.destroy_empty();
}

// ============================================================
// Remove operations
// ============================================================

#[test]
fun test_remove_head() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(1, 10);
    list.insert!(2, 20);
    list.insert!(3, 30);

    let val = list.remove!(1);
    assert_eq!(val, 10);
    assert_eq!(*list.head().borrow(), 2);
    assert_eq!(list.length(), 2);
    skip_list::check_skip_list!(&list);

    list.remove!(2);
    list.remove!(3);
    list.destroy_empty();
}

#[test]
fun test_remove_tail() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(1, 10);
    list.insert!(2, 20);
    list.insert!(3, 30);

    let val = list.remove!(3);
    assert_eq!(val, 30);
    assert_eq!(*list.tail().borrow(), 2);
    skip_list::check_skip_list!(&list);

    list.remove!(1);
    list.remove!(2);
    list.destroy_empty();
}

#[test]
fun test_remove_middle() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(1, 10);
    list.insert!(2, 20);
    list.insert!(3, 30);

    let val = list.remove!(2);
    assert_eq!(val, 20);
    assert_scores(&list, vector[1, 3]);
    skip_list::check_skip_list!(&list);

    list.remove!(1);
    list.remove!(3);
    list.destroy_empty();
}

#[test]
fun test_remove_all_then_reinsert() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(5, 50);
    list.insert!(10, 100);
    list.insert!(15, 150);
    list.remove!(5);
    list.remove!(10);
    list.remove!(15);

    assert!(list.is_empty());
    assert!(list.head().is_none());
    assert!(list.tail().is_none());

    list.insert!(20, 200);
    list.insert!(25, 250);
    assert_eq!(list.length(), 2);
    assert_eq!(*list.head().borrow(), 20);
    assert_eq!(*list.tail().borrow(), 25);
    skip_list::check_skip_list!(&list);

    list.remove!(20);
    list.remove!(25);
    list.destroy_empty();
}

// ============================================================
// Contains / assertions
// ============================================================

#[test]
fun test_contains_after_insert_and_remove() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    assert!(!list.contains(1));
    list.insert!(1, 10);
    assert!(list.contains(1));
    list.remove!(1);
    assert!(!list.contains(1));
    list.destroy_empty();
}

#[test]
fun test_assert_contains_passes() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(42, 420);
    list.assert_contains(42);
    list.remove!(42);
    list.destroy_empty();
}

#[test]
#[expected_failure(abort_code = skip_list::ENodeDoesNotExist)]
fun test_assert_contains_aborts_when_missing() {
    let mut ctx = tx_context::dummy();
    let list = new_list(&mut ctx);
    list.assert_contains(42);
    list.destroy_empty();
}

#[test]
fun test_assert_not_contains_passes() {
    let mut ctx = tx_context::dummy();
    let list = new_list(&mut ctx);
    list.assert_not_contains(42);
    list.destroy_empty();
}

#[test]
#[expected_failure(abort_code = skip_list::ENodeAlreadyExist)]
fun test_assert_not_contains_aborts_when_present() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(42, 420);
    list.assert_not_contains(42);
    list.remove!(42);
    list.destroy_empty();
}

// ============================================================
// Duplicate insert / missing remove / destroy non-empty
// ============================================================

#[test]
#[expected_failure(abort_code = skip_list::ENodeAlreadyExist)]
fun test_insert_duplicate_aborts() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(1, 10);
    list.insert!(1, 20);
    list.remove!(1);
    list.destroy_empty();
}

#[test]
#[expected_failure(abort_code = skip_list::ENodeDoesNotExist)]
fun test_remove_nonexistent_aborts() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.remove!(99);
    list.destroy_empty();
}

#[test]
#[expected_failure(abort_code = skip_list::ESkipListNotEmpty)]
fun test_destroy_nonempty_aborts() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(1, 10);
    list.destroy_empty();
}

// ============================================================
// Borrow / borrow_mut
// ============================================================

#[test]
#[expected_failure]
fun test_borrow_nonexistent_aborts() {
    let mut ctx = tx_context::dummy();
    let list = new_list(&mut ctx);
    list.borrow(99);
    list.destroy_empty();
}

#[test]
#[expected_failure]
fun test_borrow_mut_nonexistent_aborts() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    *list.borrow_mut(99) = 0;
    list.destroy_empty();
}

#[test]
#[expected_failure]
fun test_borrow_node_nonexistent_aborts() {
    let mut ctx = tx_context::dummy();
    let list = new_list(&mut ctx);
    list.borrow_node(99);
    list.destroy_empty();
}

#[test]
#[expected_failure]
fun test_borrow_mut_node_nonexistent_aborts() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.borrow_mut_node(99);
    list.destroy_empty();
}

#[test]
fun test_borrow_returns_correct_value() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(5, 500);
    list.insert!(10, 1000);
    assert_eq!(*list.borrow(5), 500);
    assert_eq!(*list.borrow(10), 1000);
    list.remove!(5);
    list.remove!(10);
    list.destroy_empty();
}

#[test]
fun test_borrow_mut_modifies_value() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(5, 500);
    *list.borrow_mut(5) = 999;
    assert_eq!(*list.borrow(5), 999);
    list.remove!(5);
    list.destroy_empty();
}

// ============================================================
// Node accessors
// ============================================================

#[test]
fun test_node_accessors() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(10, 100);
    list.insert!(20, 200);
    list.insert!(30, 300);

    let node10 = list.borrow_node(10);
    assert_eq!(node10.score(), 10);
    assert_eq!(*node10.borrow_value(), 100);
    assert!(node10.prev_score().is_none());
    assert_eq!(*node10.next_score().borrow(), 20);

    let node20 = list.borrow_node(20);
    assert_eq!(*node20.prev_score().borrow(), 10);
    assert_eq!(*node20.next_score().borrow(), 30);

    let node30 = list.borrow_node(30);
    assert!(node30.next_score().is_none());
    assert_eq!(*node30.prev_score().borrow(), 20);

    list.remove!(10);
    list.remove!(20);
    list.remove!(30);
    list.destroy_empty();
}

#[test]
fun test_borrow_mut_value_through_node() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(7, 70);
    let node = list.borrow_mut_node(7);
    *node.borrow_mut_value() = 777;
    assert_eq!(*list.borrow(7), 777);
    list.remove!(7);
    list.destroy_empty();
}

// ============================================================
// find_next / find_prev
// ============================================================

#[test]
fun test_find_next_inclusive() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(10, 100);
    list.insert!(20, 200);
    list.insert!(30, 300);
    assert_eq!(*list.find_next!(10, true).borrow(), 10);
    assert_eq!(*list.find_next!(20, true).borrow(), 20);
    assert_eq!(*list.find_next!(30, true).borrow(), 30);
    list.remove!(10);
    list.remove!(20);
    list.remove!(30);
    list.destroy_empty();
}

#[test]
fun test_find_next_exclusive() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(10, 100);
    list.insert!(20, 200);
    list.insert!(30, 300);
    assert_eq!(*list.find_next!(10, false).borrow(), 20);
    assert_eq!(*list.find_next!(20, false).borrow(), 30);
    assert!(list.find_next!(30, false).is_none());
    list.remove!(10);
    list.remove!(20);
    list.remove!(30);
    list.destroy_empty();
}

#[test]
fun test_find_next_between_keys() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(10, 100);
    list.insert!(30, 300);
    assert_eq!(*list.find_next!(20, true).borrow(), 30);
    assert_eq!(*list.find_next!(20, false).borrow(), 30);
    list.remove!(10);
    list.remove!(30);
    list.destroy_empty();
}

#[test]
fun test_find_next_on_empty_list() {
    let mut ctx = tx_context::dummy();
    let list = new_list(&mut ctx);
    assert!(list.find_next!(10, true).is_none());
    list.destroy_empty();
}

#[test]
fun test_find_next_beyond_tail() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(10, 100);
    list.insert!(20, 200);
    assert!(list.find_next!(50, true).is_none());
    list.remove!(10);
    list.remove!(20);
    list.destroy_empty();
}

#[test]
fun test_find_next_before_head() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(100, 1);
    list.insert!(200, 2);
    assert_eq!(*list.find_next!(5, true).borrow(), 100);
    list.remove!(100);
    list.remove!(200);
    list.destroy_empty();
}

#[test]
fun test_find_prev_inclusive() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(10, 100);
    list.insert!(20, 200);
    list.insert!(30, 300);
    assert_eq!(*list.find_prev!(10, true).borrow(), 10);
    assert_eq!(*list.find_prev!(20, true).borrow(), 20);
    assert_eq!(*list.find_prev!(30, true).borrow(), 30);
    list.remove!(10);
    list.remove!(20);
    list.remove!(30);
    list.destroy_empty();
}

#[test]
fun test_find_prev_exclusive() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(10, 100);
    list.insert!(20, 200);
    list.insert!(30, 300);
    assert!(list.find_prev!(10, false).is_none());
    assert_eq!(*list.find_prev!(20, false).borrow(), 10);
    assert_eq!(*list.find_prev!(30, false).borrow(), 20);
    list.remove!(10);
    list.remove!(20);
    list.remove!(30);
    list.destroy_empty();
}

#[test]
fun test_find_prev_between_keys() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(10, 100);
    list.insert!(30, 300);
    assert_eq!(*list.find_prev!(20, true).borrow(), 10);
    assert_eq!(*list.find_prev!(20, false).borrow(), 10);
    list.remove!(10);
    list.remove!(30);
    list.destroy_empty();
}

#[test]
fun test_find_prev_on_empty_list() {
    let mut ctx = tx_context::dummy();
    let list = new_list(&mut ctx);
    assert!(list.find_prev!(10, true).is_none());
    list.destroy_empty();
}

#[test]
fun test_find_prev_before_head() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(100, 1);
    list.insert!(200, 2);
    assert!(list.find_prev!(5, true).is_none());
    list.remove!(100);
    list.remove!(200);
    list.destroy_empty();
}

// ============================================================
// Head / tail tracking
// ============================================================

#[test]
fun test_head_and_tail_track_extremes() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);

    list.insert!(50, 0);
    assert_eq!(*list.head().borrow(), 50);
    assert_eq!(*list.tail().borrow(), 50);

    list.insert!(10, 0);
    assert_eq!(*list.head().borrow(), 10);
    assert_eq!(*list.tail().borrow(), 50);

    list.insert!(90, 0);
    assert_eq!(*list.head().borrow(), 10);
    assert_eq!(*list.tail().borrow(), 90);

    list.remove!(10);
    assert_eq!(*list.head().borrow(), 50);

    list.remove!(90);
    assert_eq!(*list.tail().borrow(), 50);

    list.remove!(50);
    assert!(list.head().is_none());
    assert!(list.tail().is_none());
    list.destroy_empty();
}

// ============================================================
// Prev/next link consistency after removals
// ============================================================

#[test]
fun test_prev_next_links_consistent_after_removals() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(10, 0);
    list.insert!(20, 0);
    list.insert!(30, 0);
    list.insert!(40, 0);
    list.insert!(50, 0);

    list.remove!(30);
    let node20 = list.borrow_node(20);
    assert_eq!(*node20.next_score().borrow(), 40);
    let node40 = list.borrow_node(40);
    assert_eq!(*node40.prev_score().borrow(), 20);
    skip_list::check_skip_list!(&list);

    list.remove!(10);
    list.remove!(20);
    list.remove!(40);
    list.remove!(50);
    list.destroy_empty();
}

// ============================================================
// Larger-scale tests
// ============================================================

#[test]
fun test_insert_100_elements() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    let n = 100u64;
    let mut i = 0u64;
    while (i < n) { list.insert!(i, i); i = i + 1; };

    assert_eq!(list.length(), n);
    assert_eq!(*list.head().borrow(), 0);
    assert_eq!(*list.tail().borrow(), n - 1);
    skip_list::check_skip_list!(&list);

    i = 0;
    while (i < n) { assert_eq!(*list.borrow(i), i); i = i + 1; };

    i = 0;
    while (i < n) { list.remove!(i); i = i + 1; };
    list.destroy_empty();
}

#[test]
fun test_insert_reverse_50_elements() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    let n = 50u64;
    let mut i = n;
    while (i > 0) { list.insert!(i, i * 10); i = i - 1; };

    assert_eq!(list.length(), n);
    assert_eq!(*list.head().borrow(), 1);
    assert_eq!(*list.tail().borrow(), n);
    skip_list::check_skip_list!(&list);

    i = 1;
    while (i <= n) { list.remove!(i); i = i + 1; };
    list.destroy_empty();
}

#[test]
fun test_remove_evens_preserves_odds() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    let mut i = 1u64;
    while (i <= 20) { list.insert!(i, i); i = i + 1; };

    i = 2;
    while (i <= 20) { list.remove!(i); i = i + 2; };

    assert_eq!(list.length(), 10);
    assert_scores(&list, vector[1, 3, 5, 7, 9, 11, 13, 15, 17, 19]);
    skip_list::check_skip_list!(&list);

    i = 1;
    while (i <= 19) { list.remove!(i); i = i + 2; };
    list.destroy_empty();
}

// ============================================================
// Different max_level and list_p values
// ============================================================

#[test]
fun test_small_max_level_large_list_p() {
    let mut ctx = tx_context::dummy();
    let mut list: SkipList<u64, u64> = skip_list::new(2, 4, 99, &mut ctx);
    let mut i = 1u64;
    while (i <= 30) { list.insert!(i, i); i = i + 1; };

    assert_eq!(list.length(), 30);
    assert_eq!(*list.head().borrow(), 1);
    assert_eq!(*list.tail().borrow(), 30);
    assert!(list.level() <= 2);
    skip_list::check_skip_list!(&list);

    i = 1;
    while (i <= 30) { list.remove!(i); i = i + 1; };
    list.destroy_empty();
}

// ============================================================
// Metadata
// ============================================================

#[test]
fun test_metadata_on_empty_list() {
    let mut ctx = tx_context::dummy();
    let list = new_list(&mut ctx);
    let (_head, tail, level, max_level, list_p, length) = list.metadata();
    assert!(tail.is_none());
    assert_eq!(level, 0);
    assert_eq!(max_level, 16);
    assert_eq!(list_p, 2);
    assert_eq!(length, 0);
    list.destroy_empty();
}

#[test]
fun test_metadata_on_nonempty_list() {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(1, 10);
    list.insert!(5, 50);
    list.insert!(6, 60);
    list.insert!(7, 70);

    let (head, tail, level, max_level, list_p, length) = list.metadata();
    assert!(head.length() >= 1);
    assert!(tail.is_some());
    assert!(level >= 1);
    assert_eq!(max_level, 16);
    assert_eq!(list_p, 2);
    assert_eq!(length, 4);

    list.remove!(1);
    list.remove!(5);
    list.remove!(6);
    list.remove!(7);
    list.destroy_empty();
}

// ============================================================
// Property-based / random tests
// ============================================================

#[random_test]
fun test_prop_insert_remove_single_key(key: u64) {
    let mut ctx = tx_context::dummy();
    let mut list = new_list(&mut ctx);
    list.insert!(key, key);
    assert!(list.contains(key));
    assert_eq!(list.length(), 1);
    assert_eq!(*list.head().borrow(), key);
    assert_eq!(*list.tail().borrow(), key);
    assert_eq!(*list.borrow(key), key);

    let val = list.remove!(key);
    assert_eq!(val, key);
    assert!(list.is_empty());
    list.destroy_empty();
}

#[random_test]
fun test_prop_ordering_invariant(seed: u64) {
    let mut ctx = tx_context::dummy();
    let mut list: SkipList<u64, u64> = skip_list::new(16, 2, seed, &mut ctx);

    let base = seed % 1000;
    let mut i = 0u64;
    while (i < 20) {
        let key = base + i * 7 + (seed / (i + 1)) % 5;
        if (!list.contains(key)) { list.insert!(key, i); };
        i = i + 1;
    };

    skip_list::check_skip_list!(&list);

    let scores = skip_list::get_all_scores(&list);
    let mut j = 1u64;
    while (j < scores.length()) {
        assert!(*scores.borrow(j - 1) < *scores.borrow(j));
        j = j + 1;
    };

    if (scores.length() > 0) {
        assert_eq!(*list.head().borrow(), *scores.borrow(0));
        assert_eq!(*list.tail().borrow(), *scores.borrow(scores.length() - 1));
    };

    j = 0;
    while (j < scores.length()) { list.remove!(*scores.borrow(j)); j = j + 1; };
    list.destroy_empty();
}

#[random_test]
fun test_prop_insert_then_remove_all_is_empty(seed: u64) {
    let mut ctx = tx_context::dummy();
    let mut list: SkipList<u64, u64> = skip_list::new(8, 2, seed, &mut ctx);

    let n = 15u64;
    let mut i = 0u64;
    while (i < n) { list.insert!(i, i); i = i + 1; };
    assert_eq!(list.length(), n);

    i = n;
    while (i > 0) {
        i = i - 1;
        list.remove!(i);
        skip_list::check_skip_list!(&list);
    };

    assert!(list.is_empty());
    assert!(list.head().is_none());
    assert!(list.tail().is_none());
    list.destroy_empty();
}

#[random_test]
fun test_prop_contains_correct_after_partial_removal(seed: u64) {
    let mut ctx = tx_context::dummy();
    let mut list: SkipList<u64, u64> = skip_list::new(8, 2, seed, &mut ctx);

    let n = 20u64;
    let mut i = 0u64;
    while (i < n) { list.insert!(i, i); i = i + 1; };

    i = 0;
    while (i < n) { list.remove!(i); i = i + 2; };

    i = 0;
    while (i < n) {
        if (i % 2 == 0) { assert!(!list.contains(i)); } else { assert!(list.contains(i)); };
        i = i + 1;
    };
    skip_list::check_skip_list!(&list);

    i = 1;
    while (i < n) { list.remove!(i); i = i + 2; };
    list.destroy_empty();
}

#[random_test]
fun test_prop_find_next_prev_consistent(seed: u64) {
    let mut ctx = tx_context::dummy();
    let mut list: SkipList<u64, u64> = skip_list::new(8, 2, seed, &mut ctx);

    let keys = vector[100, 200, 300, 400, 500];
    let mut i = 0u64;
    while (i < keys.length()) { list.insert!(*keys.borrow(i), i); i = i + 1; };

    i = 0;
    while (i < keys.length()) {
        let k = *keys.borrow(i);
        assert_eq!(*list.find_next!(k, true).borrow(), k);
        assert_eq!(*list.find_prev!(k, true).borrow(), k);
        i = i + 1;
    };

    assert_eq!(*list.find_next!(150, true).borrow(), 200);
    assert_eq!(*list.find_prev!(150, true).borrow(), 100);
    assert!(list.find_next!(550, true).is_none());
    assert!(list.find_prev!(50, true).is_none());

    i = 0;
    while (i < keys.length()) { list.remove!(*keys.borrow(i)); i = i + 1; };
    list.destroy_empty();
}
