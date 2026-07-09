/// The comparator-contract suite: the central footgun, the public but unchecked `inner_mut`
/// order-ONLY corruption surface, the comparator-execution contract,
/// membership-is-under-the-comparator / coarse-comparator integrity, and the reused
/// cross-package well-formedness check.
///
/// The defining set property proved here: every corruption is ORDER-ONLY - the keys are always
/// still PRESENT (the value is the trivial `Unit`), so a desorted set is recoverable by rebuilding
/// under a consistent comparator; NO value is ever lost. The well-formedness check
/// `sorted_map::is_well_formed[_by]!(inner(&set))` turns each violation into a red test.
module openzeppelin_collections::sorted_set_comparator_tests;

use openzeppelin_collections::sorted_map as sm;
use openzeppelin_collections::sorted_set as ss;
use openzeppelin_collections::sorted_set_test_util as u;
use std::unit_test::assert_eq;

// A comparator that always aborts at runtime. Routed through a function call (not an inline
// `abort`) so the expanded search! body stays statically reachable - an inline aborting lambda
// makes the macro's loop body dead code, which the lint flags both here and in the shipped map.
const EAbortingComparator: u64 = 0xCAFE;

fun aborting_lt(_a: &u64, _b: &u64): bool { abort EAbortingComparator }

// === a reverse comparator used CONSISTENTLY is legitimate ===

#[test]
fun reverse_comparator_consistent() {
    let mut s = ss::new<u64>();
    u::ins_rev(&mut s, 10);
    u::ins_rev(&mut s, 30);
    u::ins_rev(&mut s, 20);
    assert!(u::wf_rev(&s)); // well-formed under the reverse order it was built with
    assert!(!u::wf(&s)); // and NOT well-formed under `<` - order is relative to the lt
    assert_eq!(s.head(), option::some(30)); // head = largest numeric under reverse lt
    assert_eq!(s.tail(), option::some(10));
    assert_eq!(s.keys(), vector[30u64, 20, 10]); // stored descending-numeric
}

// === add_by threads a reverse comparator: strict fresh inserts stay well-formed under `>` ===

#[test]
fun add_by_reverse_comparator() {
    // Strict insert of distinct keys in arbitrary order under `>`: consistently reversed, so
    // well-formed under `>` and NOT under `<`. The strict-insert counterpart to
    // `reverse_comparator_consistent` (which builds via the total `upsert`).
    let mut s = ss::new<u64>();
    u::add_rev(&mut s, 10);
    u::add_rev(&mut s, 30);
    u::add_rev(&mut s, 20);
    assert!(u::wf_rev(&s));
    assert!(!u::wf(&s));
    assert_eq!(s.keys(), vector[30u64, 20, 10]); // stored descending-numeric
}

// === a non-strict `<=` never derives equality -> duplicates land ===

#[test]
fun nonstrict_comparator_creates_duplicates() {
    let mut s = ss::new<u64>();
    assert!(u::ins_le(&mut s, 5)); // first 5 -> fresh
    // `<=` makes search! treat the existing 5 as "less", so equality is never detected: the
    // second 5 is also reported FRESH (returns true) and inserted AGAIN. The set's de-dup is
    // only as strict as the comparator's derived equality.
    assert!(u::ins_le(&mut s, 5)); // duplicate, yet reported newly-added
    assert_eq!(s.length(), 2); // apparent duplicate landed
    assert!(!u::wf(&s)); // adjacent equal pair -> not strictly increasing under `<`
}

// === mixing comparators aborts on a present key / desorts - no value lost ===

#[test, expected_failure(abort_code = sm::EKeyNotFound, location = sm)]
fun removing_with_wrong_comparator_aborts() {
    // Build ascending with `<`, then remove the HEAD under `>`: the descending search reads
    // ascending data and walks away from 10, reporting not-found -> remove! ABORTS EKeyNotFound
    // though 10 is present. The abort unwinds the removal, so no value is lost.
    // (A key sitting exactly at a search midpoint, e.g. 20 here, would be found by luck; the head
    // is the robust miss.)
    let mut s = u::fromk(vector[10u64, 20, 30]);
    u::rem_gt(&mut s, 10);
    abort
}

#[test]
fun mixed_comparator_insert_desorts_no_value_lost() {
    // Build ascending with `<`, then insert under `>`: 5 lands under the wrong order, desorting
    // the set (the `<` well-formedness check catches it). Crucially, ALL keys are still present -
    // order-only corruption, recoverable by rebuild.
    let mut s = u::fromk(vector[10u64, 20, 30]);
    u::ins_gt(&mut s, 5);
    assert!(!u::wf(&s)); // desorted under `<`
    assert_eq!(s.length(), 4);
    let ks = s.keys(); // faithfully reflects the (corrupted) stored order, no re-sort
    assert!(ks.contains(&5) && ks.contains(&10) && ks.contains(&20) && ks.contains(&30)); // nothing lost
}

// === inner_mut is the order-ONLY corruption surface - caught by the well-formedness check ===

#[test]
fun inner_mut_wrong_index_desorts_no_value_lost() {
    // Drive the wrapped map's insert_at at a WRONG index through inner_mut: 99 prepended at
    // index 0 of [10,20,30] -> [99,10,20,30], desorted. The check catches it; all keys present.
    let mut s = u::fromk(vector[10u64, 20, 30]);
    u::misuse_insert_at(&mut s, 0, 99); // 99 at the FRONT - maximal value, wrong slot
    assert!(!u::wf(&s));
    assert_eq!(s.length(), 4);
    let ks = s.keys();
    assert!(ks.contains(&99) && ks.contains(&10) && ks.contains(&20) && ks.contains(&30));
    // keys() faithfully reflects the corrupted PHYSICAL order - it does NOT re-sort or mask the
    // disorder. A bug where keys() silently re-sorted would still pass the membership
    // check above; this exact-order assert pins the no-masking guarantee.
    assert_eq!(ks, vector[99u64, 10, 20, 30]);
}

#[test]
fun inner_mut_inconsistent_comparator_desorts_no_value_lost() {
    // Drive the wrapped map's upsert_by! with an inconsistent comparator through inner_mut.
    let mut s = u::fromk(vector[10u64, 20, 30]);
    u::misuse_insert_inconsistent(&mut s, 5); // inserts 5 under `>` against `<`-sorted data
    assert!(!u::wf(&s));
    assert_eq!(s.length(), 4);
    let ks = s.keys();
    assert!(ks.contains(&5) && ks.contains(&10) && ks.contains(&20) && ks.contains(&30));
}

// === membership is under-the-comparator, not byte-identity (coarse comparator) ===

#[test]
fun coarse_comparator_first_bytes_win() {
    // Key ordered on `id` ALONE: Key{1,100} and Key{1,200} compare EQUAL.
    let mut s = ss::new<u::Key>();
    assert!(u::ins_k(&mut s, u::mk(1, 100))); // newly added
    assert!(!u::ins_k(&mut s, u::mk(1, 200))); // compare-equal -> "already present" (FALSE)
    assert_eq!(u::len_k(&s), 1); // collapsed to ONE element
    let ks = u::keys_k(&s);
    assert_eq!(u::key_tag(&ks[0]), 100); // ...AND the FIRST inserted key's bytes survive (reuse)
    assert!(u::wf_k(&s)); // a coarse-but-consistent comparator keeps the set well-formed
}

#[test]
fun coarse_from_keys_keeps_first() {
    // from_keys over compare-equal variants keeps the FIRST in input order (upsert reuses stored).
    let s = u::fromk_k(vector[u::mk(1, 10), u::mk(2, 20), u::mk(1, 30)]);
    assert_eq!(u::len_k(&s), 2); // ids {1,2} -> 2 distinct
    let ks = u::keys_k(&s); // sorted by id: [Key{1,_}, Key{2,_}]
    assert_eq!(u::key_tag(&ks[0]), 10); // id=1 kept the FIRST (tag 10), not the last (tag 30)
    assert_eq!(u::key_tag(&ks[1]), 20);
}

#[test]
fun coarse_contains_remove_match_any_byte_variant() {
    // contains!/remove! match ANY stored key compare-equal to the probe, regardless of bytes.
    let mut s = ss::new<u::Key>();
    u::ins_k(&mut s, u::mk(7, 111));
    assert!(u::has_k(&s, 7)); // probe Key{7,0} matches stored Key{7,111} under id-order
    u::rem_k(&mut s, 7); // removes it (was-present)
    assert!(!u::has_k(&s, 7));
    assert_eq!(u::len_k(&s), 0);
}

#[test]
fun from_keys_validator_recipe() {
    // from_keys de-duplicates silently. The documented recipe to REJECT duplicates
    // vec_set-style is `build, then assert!(length == input_len, EDup)`. This shows the recipe's
    // discriminant: a dup-containing input yields length < n; a distinct input yields length == n.
    let dup_input = vector[1u64, 2, 2, 3];
    let n_dup = dup_input.length();
    let s_dup = u::fromk(dup_input);
    assert!(s_dup.length() != n_dup); // recipe FIRES: 3 != 4 -> caller would abort EDup

    let ok_input = vector[1u64, 2, 3];
    let n_ok = ok_input.length();
    let s_ok = u::fromk(ok_input);
    assert_eq!(s_ok.length(), n_ok); // recipe PASSES: 3 == 3
}

#[test]
fun injective_comparator_control() {
    // Control: under an INJECTIVE comparator (integer `<`), membership-under-the-
    // comparator coincides with byte-identity, so first-seen gating is well-defined and the
    // coarse-comparator overwrite behavior is invisible.
    let mut s = ss::new<u64>();
    assert!(u::ins(&mut s, 1)); // first-seen -> true (well-defined)
    assert!(!u::ins(&mut s, 1)); // exact same value -> false; no hidden byte overwrite
    assert_eq!(s.length(), 1);
}

// === non-deterministic comparator corrupts even a would-be well-formed set ===

#[test]
fun nondeterministic_comparator_corrupts() {
    // A comparator whose answer depends on a captured mutable counter - NOT purely on its (a, b)
    // arguments - is NON-DETERMINISTIC within a single binary search: the SAME pair compares
    // differently on different calls, so one search takes contradictory branches and places a key
    // out of order EVEN on otherwise-sorted data. Here, inserting 5 into [10,20,30] with a
    // counter-only `lt` lands it at index 2 ([10,20,5,30]); the honest `<` check catches the
    // disorder. (The bare-form default `|a,b| *a<*b` is pure/deterministic by construction and is
    // exercised throughout the rest of the suite. Mutation-reentrancy - a comparator mutating the
    // set mid-search - is foreclosed by the borrow checker; see the commented snippet in
    // type_tests.)
    let mut s = u::fromk(vector[10u64, 20, 30]);
    let mut calls = 0u64;
    s.upsert_by!(&5, |_a, _b| { calls = calls + 1; calls % 2 == 1 });
    assert!(!u::wf(&s)); // a non-deterministic lt produced a non-well-formed set
    assert_eq!(s.length(), 4); // 5 was inserted (at the wrong slot), not dropped
}

// === the map's well-formedness check is reusable cross-package via inner ===

#[test]
fun well_formedness_check_reuse_cross_package() {
    // sorted_map::is_well_formed[_by]!(ss::inner(&set)) is callable from the SET package's
    // tests - positive on a clean set, negative on a corrupted one. (A *production* call fails to
    // compile - #[test_only]; see the commented snippet in type_tests.)
    let clean = u::fromk(vector[3u64, 1, 2]);
    assert!(u::wf(&clean)); // bare check (integer `<`)
    let clean_k = u::fromk_k(vector[u::mk(2, 0), u::mk(1, 0)]);
    assert!(u::wf_k(&clean_k)); // `_by` check on a struct key
    let mut corrupt = u::fromk(vector[10u64, 20]);
    u::misuse_insert_at(&mut corrupt, 0, 99);
    assert!(!u::wf(&corrupt)); // check detects the disorder
}

// === a desorted set exhibits APPARENT MEMBERSHIP LOSS - a present key reads absent ===

#[test]
fun desort_apparent_membership_loss() {
    // This negative/security scenario is a RED test: a desort must make a present key read ABSENT
    // with NO abort (a silently de-listed member). Every other corruption test asserts the OPPOSITE
    // (the key is still findable / physically present).
    // Desort via inner_mut: 99 (maximal) forced to index 0 of [10,20,30] -> inner [99,10,20,30].
    let mut s = u::fromk(vector[10u64, 20, 30]);
    u::misuse_insert_at(&mut s, 0, 99);
    assert!(!u::wf(&s)); // desorted under `<`
    assert!(s.keys().contains(&99)); // 99 is PHYSICALLY present - no value lost
    // ...yet the `<` binary search walks right past index 0, so contains! reports 99 ABSENT:
    // apparent membership loss, no abort. (For an allowlist/registry this is a security event.)
    assert!(!u::has(&s, 99));
}

// === a reverse comparator threaded consistently is a FULLY working set ===

#[test]
fun reverse_comparator_membership_polarity_pop() {
    // Build [30,20,10] (stored descending-numeric under `>`). Pins reverse upsert_by polarity,
    // contains_by/remove_by under `>` (activating the previously-dead has_rev/rem_rev helpers), and
    // that pop_* (which take NO comparator) read the PHYSICAL front/back.
    let mut s = ss::new<u64>();
    assert!(u::ins_rev(&mut s, 10)); // fresh under reverse `<` -> true
    assert!(u::ins_rev(&mut s, 30));
    assert!(u::ins_rev(&mut s, 20));
    assert!(!u::ins_rev(&mut s, 20)); // dup under reverse -> false (idempotent)
    assert_eq!(s.length(), 3);
    assert!(u::has_rev(&s, 20)); // contains_by present under reverse
    assert!(!u::has_rev(&s, 99)); // contains_by absent under reverse
    u::rem_rev(&mut s, 20); // remove_by present under reverse (removes middle)
    assert!(!u::has_rev(&s, 20));
    assert!(u::wf_rev(&s)); // still well-formed under the reverse order it was built with
    // pop_front/pop_back read the PHYSICAL endpoints of the stored [30,10]:
    assert_eq!(s.pop_front(), 30); // stored front = numeric-largest
    assert_eq!(s.pop_back(), 10); // stored back = numeric-smallest
    assert!(s.is_empty());
}

#[test]
fun reverse_comparator_navigation() {
    // Navigation under a reverse comparator: find_next = lt-ceiling, find_prev = lt-floor, both
    // about lt-extremes (numeric-descending), NOT numeric order. Stored [30,20,10] (lt = `>`).
    // First-ever exercise of find_next_by/find_prev_by/next_key_by/prev_key_by with a consumer
    // lambda (reverse-_by, previously reached only via the bare `<`).
    let mut s = ss::new<u64>();
    u::ins_rev(&mut s, 30);
    u::ins_rev(&mut s, 20);
    u::ins_rev(&mut s, 10);
    assert_eq!(u::fnext_rev(&s, 25, true), option::some(20)); // lt-ceiling of 25 = largest <= 25
    assert_eq!(u::fnext_rev(&s, 20, true), option::some(20)); // include hit
    assert_eq!(u::fnext_rev(&s, 20, false), option::some(10)); // strict lt-next = next smaller
    assert_eq!(u::fprev_rev(&s, 25, true), option::some(30)); // lt-floor of 25 = smallest >= 25
    assert_eq!(u::fprev_rev(&s, 20, false), option::some(30)); // strict lt-prev = next larger
    assert_eq!(u::nkey_rev(&s, 10), option::none()); // 10 is the lt-tail -> forward cursor ends
    assert_eq!(u::pkey_rev(&s, 30), option::none()); // 30 is the lt-head -> backward cursor ends
    assert_eq!(u::nkey_rev(&s, 30), option::some(20)); // forward cursor step under reverse
    assert_eq!(u::pkey_rev(&s, 10), option::some(20)); // backward cursor step under reverse
}

#[test]
fun reverse_comparator_pagination() {
    // keys_from_by under a reverse comparator: pages walk the stored (descending-numeric) order,
    // contiguous and resumable with include==false. The ONLY branch where the page macro threads
    // the lambda is search!'s start-index computation - previously untested for a non-default lt.
    let mut s = ss::new<u64>();
    u::ins_rev(&mut s, 10);
    u::ins_rev(&mut s, 30);
    u::ins_rev(&mut s, 20);
    u::ins_rev(&mut s, 40);
    u::ins_rev(&mut s, 50); // stored [50,40,30,20,10]
    assert_eq!(u::page_rev(&s, 50, true, 2), vector[50u64, 40]);
    assert_eq!(u::page_rev(&s, 40, false, 2), vector[30u64, 20]); // resume strictly past 40 under >
    assert_eq!(u::page_rev(&s, 20, false, 10), vector[10u64]); // fewer than limit at the lt-tail
    assert_eq!(u::page_rev(&s, 10, false, 10), vector[]); // past the lt-tail
    assert_eq!(s.keys(), vector[50u64, 40, 30, 20, 10]); // stored descending-numeric
}

// === struct-key navigation + pagination via _by - the ONLY path for non-int K ===

#[test]
fun struct_key_navigation_by() {
    // For a non-integer key the bare nav forms won't compile (no built-in `<`), so the _by forms are
    // the ONLY navigation path - and they were entirely untested. Ordered on `id`, stored [10,20,30].
    let s = u::fromk_k(vector[u::mk(10, 0), u::mk(20, 0), u::mk(30, 0)]);
    assert_eq!(u::fnext_k(&s, 15, true), option::some(u::mk(20, 0))); // ceiling of a gap
    assert_eq!(u::fnext_k(&s, 20, false), option::some(u::mk(30, 0))); // strict next
    assert_eq!(u::fprev_k(&s, 25, true), option::some(u::mk(20, 0))); // floor of a gap
    assert_eq!(u::fprev_k(&s, 20, false), option::some(u::mk(10, 0))); // strict prev
    assert_eq!(u::nkey_k(&s, 30), option::none()); // next_key(tail) terminates
    assert_eq!(u::pkey_k(&s, 10), option::none()); // prev_key(head) terminates
    assert_eq!(u::nkey_k(&s, 10), option::some(u::mk(20, 0))); // forward cursor step
}

#[test]
fun keys_from_by_struct_keys() {
    // Pagination for non-integer keys - keys_from_by is the ONLY pagination path (bare won't
    // compile). Stored ids [1,2,3,4,5].
    let s = u::fromk_k(vector[u::mk(1, 0), u::mk(2, 0), u::mk(3, 0), u::mk(4, 0), u::mk(5, 0)]);
    assert_eq!(u::page_k(&s, 1, true, 2), vector[u::mk(1, 0), u::mk(2, 0)]);
    assert_eq!(u::page_k(&s, 2, false, 2), vector[u::mk(3, 0), u::mk(4, 0)]); // resume past id 2
    assert_eq!(u::page_k(&s, 4, false, 10), vector[u::mk(5, 0)]); // fewer than limit at the tail

    // A COARSE comparator collapses compare-equal keys; pagination emits ONE key
    // per equivalence class (carrying the FIRST inserted bytes), never a duplicate page.
    let c = u::fromk_k(vector[u::mk(1, 10), u::mk(1, 20), u::mk(2, 30)]); // ids collapse to {1,2}
    let pg = u::page_k(&c, 1, true, 10);
    assert_eq!(pg.length(), 2); // one entry per id-equivalence class, no dup page
    assert_eq!(u::key_tag(&pg[0]), 10); // id=1 kept the FIRST inserted bytes (tag 10)
    assert_eq!(u::key_id(&pg[1]), 2);
}

// === the MISS half - under `<=`, contains/remove miss the equal-comparing key ===

#[test, expected_failure(abort_code = sm::EKeyNotFound, location = sm)]
fun nonstrict_comparator_misses_equal_key() {
    // `<=` never derives equality, so two 5s both land (the "duplicate" half is tested elsewhere)
    // AND a probe for 5 under `<=` MISSES it (the previously-untested miss half): search!
    // treats the stored 5 as strictly less and walks past it.
    let mut s = ss::new<u64>();
    u::ins_le(&mut s, 5);
    u::ins_le(&mut s, 5);
    assert_eq!(s.length(), 2); // two equal-comparing keys landed
    assert!(!u::has_le(&s, 5)); // ...yet contains_by under `<=` MISSES the present key
    u::rem_le(&mut s, 5); // remove_by under `<=` aborts;
    abort
}

// === from_keys_by BULK builder threads a reverse comparator ===

#[test]
fun from_keys_by_reverse_integer() {
    // The reverse direction was only ever built via upsert_by (ins_rev); this pins the BULK builder
    // (from_keys_by's do!-loop) threading a reverse lt - yields descending-numeric, well-formed
    // under `>` and NOT under `<`.
    let s = ss::from_keys_by!(vector[10u64, 30, 20], |a, b| *a > *b);
    assert_eq!(s.keys(), vector[30u64, 20, 10]); // descending-numeric (ascending under >)
    assert_eq!(s.head(), option::some(30)); // lt-smallest = numeric-largest
    assert_eq!(s.tail(), option::some(10));
    assert!(u::wf_rev(&s)); // well-formed under >
    assert!(!u::wf(&s)); // ...and NOT under < - order is relative to lt
}

// === a consumer lt that ABORTS unwinds the set op (the totality carve-out boundary) ===

#[test, expected_failure(abort_code = EAbortingComparator)]
fun aborting_comparator_propagates() {
    // An aborting comparator aborts the set op at the comparator's location (this module).
    // `upsert`/`contains` totality is library-semantic only; a consumer-supplied
    // abort is the caller's, not the library's.
    let mut s = u::fromk(vector[1u64, 2, 3]);
    s.upsert_by!(&5, |a, b| aborting_lt(a, b));
}
