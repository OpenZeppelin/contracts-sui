module openzeppelin_collections::skip_list;

use openzeppelin_collections::random::{Self, Random};
use sui::table;

///
#[error(code = 0)]
const ENodeAlreadyExist: vector<u8> = "Node already exists";

///
#[error(code = 1)]
const ENodeDoesNotExist: vector<u8> = "Node does not exist";

///
#[error(code = 2)]
const ESkipListNotEmpty: vector<u8> = "Skip list not empty";

///
#[error(code = 3)]
const ESkipListIsEmpty: vector<u8> = "Skip list is empty";

///
#[error(code = 4)]
const EInvalidListP: vector<u8> = "Invalid list P-value";

/// The skip list.
public struct SkipList<Key: copy + drop + store, V: store> has key, store {
    /// The id of this skip list.
    id: UID,
    /// The skip list header of each level. i.e. the score of node.
    head: vector<Option<Key>>,
    /// The level0's tail of skip list. i.e. the score of node.
    tail: Option<Key>,
    /// The current level of this skip list.
    level: u64,
    /// The max level of this skip list.
    max_level: u64,
    /// Basic probability of random of node indexer's level i.e. (list_p = 2, level2 = 1/2, level3 = 1/4).
    list_p: u64,
    /// The random for generate ndoe's level
    random: Random,
    /// The table for store node.
    inner: table::Table<Key, Node<Key, V>>,
}

/// The node of skip list.
public struct Node<Key: copy + drop + store, V: store> has store {
    /// The score of node.
    score: Key,
    /// The next node score of node's each level.
    nexts: vector<Option<Key>>,
    /// The prev node score of node.
    prev: Option<Key>,
    /// The data being stored
    value: V,
}

/// Create a new empty skip list.
public fun new<Key: copy + drop + store, V: store>(
    max_level: u64,
    list_p: u64,
    seed: u64,
    ctx: &mut TxContext,
): SkipList<Key, V> {
    assert!(list_p > 1, EInvalidListP);
    let list = SkipList<Key, V> {
        id: object::new(ctx),
        head: vector::empty(),
        tail: option::none(),
        level: 0,
        max_level,
        list_p,
        random: random::new(seed),
        inner: table::new(ctx),
    };
    list
}

/// Return the length of the skip list.
public fun length<Key: copy + drop + store, V: store>(list: &SkipList<Key, V>): u64 {
    list.inner.length()
}

/// Returns true if the skip list is empty (if `length` returns `0`)
public fun is_empty<Key: copy + drop + store, V: store>(list: &SkipList<Key, V>): bool {
    list.inner.length() == 0
}

/// Return the head of the skip list.
public fun head<Key: copy + drop + store, V: store>(list: &SkipList<Key, V>): Option<Key> {
    if (list.is_empty()) {
        return option::none()
    };
    *list.head.borrow(0)
}

/// Return the tail of the skip list.
public fun tail<Key: copy + drop + store, V: store>(list: &SkipList<Key, V>): Option<Key> {
    list.tail
}

/// Destroys an empty skip list
/// Aborts with `ETableNotEmpty` if the list still contains values
public fun destroy_empty<Key: copy + drop + store, V: store + drop>(list: SkipList<Key, V>) {
    let SkipList<Key, V> {
        id,
        head: _,
        tail: _,
        level: _,
        max_level: _,
        list_p: _,
        random: _,
        inner,
    } = list;
    assert!(inner.length() == 0, ESkipListNotEmpty);
    inner.destroy_empty();
    id.delete();
}

/// Returns true if there is a value associated with the score `score` in skip list
public fun contains<Key: copy + drop + store, V: store>(list: &SkipList<Key, V>, score: Key): bool {
    list.inner.contains(score)
}

/// Asserts that the skip list does not contain the given score.
/// Aborts with `ENodeAlreadyExist` if it does.
public fun assert_not_contains<Key: copy + drop + store, V: store>(
    list: &SkipList<Key, V>,
    score: Key,
) {
    assert!(!list.contains(score), ENodeAlreadyExist);
}

/// Asserts that the skip list contains the given score.
/// Aborts with `ENodeDoesNotExist` if it does not.
public fun assert_contains<Key: copy + drop + store, V: store>(
    list: &SkipList<Key, V>,
    score: Key,
) {
    assert!(list.contains(score), ENodeDoesNotExist);
}

/// Acquire an immutable reference to the `score` element of the skip list `list`.
/// Aborts if element not exist.
public fun borrow<Key: copy + drop + store, V: store>(list: &SkipList<Key, V>, score: Key): &V {
    let node = list.inner.borrow(score);
    &node.value
}

/// Return a mutable reference to the `score` element in the skip list `list`.
/// Aborts if element is not exist.
public fun borrow_mut<Key: copy + drop + store, V: store>(
    list: &mut SkipList<Key, V>,
    score: Key,
): &mut V {
    let node = list.inner.borrow_mut(score);
    &mut node.value
}

/// Acquire an immutable reference to the `score` node of the skip list `list`.
/// Aborts if node not exist.
public fun borrow_node<Key: copy + drop + store, V: store>(
    list: &SkipList<Key, V>,
    score: Key,
): &Node<Key, V> {
    list.inner.borrow(score)
}

/// Return a mutable reference to the `score` node in the skip list `list`.
/// Aborts if node is not exist.
public fun borrow_mut_node<Key: copy + drop + store, V: store>(
    list: &mut SkipList<Key, V>,
    score: Key,
): &mut Node<Key, V> {
    list.inner.borrow_mut(score)
}

/// Return the metadata info of skip list.
public fun metadata<Key: copy + drop + store, V: store>(
    list: &SkipList<Key, V>,
): (vector<Option<Key>>, Option<Key>, u64, u64, u64, u64) {
    (list.head, list.tail, list.level, list.max_level, list.list_p, list.inner.length())
}

/// Return the current level of the skip list.
public fun level<Key: copy + drop + store, V: store>(list: &SkipList<Key, V>): u64 {
    list.level
}

/// Return an immutable reference to the head vector of the skip list.
public fun head_vec<Key: copy + drop + store, V: store>(
    list: &SkipList<Key, V>,
): &vector<Option<Key>> {
    &list.head
}

/// Return a mutable reference to the head vector of the skip list.
public fun head_vec_mut<Key: copy + drop + store, V: store>(
    list: &mut SkipList<Key, V>,
): &mut vector<Option<Key>> {
    &mut list.head
}

/// Set the tail of the skip list.
public fun set_tail<Key: copy + drop + store, V: store>(
    list: &mut SkipList<Key, V>,
    new_tail: Option<Key>,
) {
    list.tail = new_tail;
}

/// Remove a node from the skip list's inner table and return it.
public fun remove_node<Key: copy + drop + store, V: store>(
    list: &mut SkipList<Key, V>,
    score: Key,
): Node<Key, V> {
    list.inner.remove(score)
}

/// Add a node to the skip list's inner table.
public fun add_node<Key: copy + drop + store, V: store>(
    list: &mut SkipList<Key, V>,
    score: Key,
    node: Node<Key, V>,
) {
    list.inner.add(score, node);
}

/// Return the score of the node.
public fun score<Key: copy + drop + store, V: store>(node: &Node<Key, V>): Key {
    node.score
}

/// Return the next score of the node.
public fun next_score<Key: copy + drop + store, V: store>(node: &Node<Key, V>): Option<Key> {
    *node.nexts.borrow(0)
}

/// Return an immutable reference to the nexts vector of the node.
public fun nexts<Key: copy + drop + store, V: store>(node: &Node<Key, V>): &vector<Option<Key>> {
    &node.nexts
}

/// Return a mutable reference to the nexts vector of the node.
public fun nexts_mut<Key: copy + drop + store, V: store>(
    node: &mut Node<Key, V>,
): &mut vector<Option<Key>> {
    &mut node.nexts
}

/// Return the prev score of the node.
public fun prev_score<Key: copy + drop + store, V: store>(node: &Node<Key, V>): Option<Key> {
    node.prev
}

/// Set the prev score of the node.
public fun set_prev<Key: copy + drop + store, V: store>(
    node: &mut Node<Key, V>,
    prev: Option<Key>,
) {
    node.prev = prev;
}

/// Return the immutable reference to the ndoe's value.
public fun borrow_value<Key: copy + drop + store, V: store>(node: &Node<Key, V>): &V {
    &node.value
}

/// Return the mutable reference to the ndoe's value.
public fun borrow_mut_value<Key: copy + drop + store, V: store>(node: &mut Node<Key, V>): &mut V {
    &mut node.value
}

/// Insert a score-value into skip list, abort if the score already exist.
/// Works only with unsigned integer keys.
public macro fun insert<$Int, $V: store>($list: &mut SkipList<$Int, $V>, $score: $Int, $v: $V) {
    insert_by!($list, $score, $v, |x, y| *x <= *y)
}

/// Insert a score-value into skip list, abort if the score already exist.
/// Accepts a `$le` comparator for generic key types.
public macro fun insert_by<$Key: copy + drop + store, $V: store>(
    $list: &mut SkipList<$Key, $V>,
    $score: $Key,
    $v: $V,
    $le: |&$Key, &$Key| -> bool,
) {
    let list = $list;
    let score = $score;

    list.assert_not_contains(score);

    let (level, mut new_node) = list.create_node(score, $v);
    let (mut l, mut nexts, mut prev) = (list.level(), list.head_vec_mut(), option::none());
    let mut opt_l0_next_score = option::none();
    let mut is_new_tail = false;
    while (l > 0) {
        let mut opt_next_score = nexts.borrow_mut(l - 1);
        while (opt_next_score.is_some_and!(|next_score| $le(next_score, &score))) {
            let node = list.borrow_mut_node(*opt_next_score.borrow());
            prev = option::some(node.score());
            nexts = node.nexts_mut();
            opt_next_score = nexts.borrow_mut(l - 1);
        };
        if (level >= l) {
            new_node.nexts_mut().push_back(*opt_next_score);
            if (l == 1) {
                new_node.set_prev(prev);
                if (opt_next_score.is_some()) {
                    opt_l0_next_score = *opt_next_score;
                } else {
                    is_new_tail = true;
                }
            };
            opt_next_score.swap_or_fill(score);
        };
        l = l - 1;
    };
    if (is_new_tail) {
        list.set_tail(option::some(score));
    };
    if (opt_l0_next_score.is_some()) {
        let next_node = list.borrow_mut_node(*opt_l0_next_score.borrow());
        next_node.set_prev(option::some(score));
    };

    new_node.nexts_mut().reverse();
    list.add_node(score, new_node);
}

/// Remove the score-value from skip list, abort if the score not exist in list.
/// Works only with unsigned integer keys.
public macro fun remove<$Int, $V: store>($list: &mut SkipList<$Int, $V>, $score: $Int): $V {
    remove_by!($list, $score, |x, y| *x <= *y)
}

/// Remove the score-value from skip list, abort if the score not exist in list.
/// Accepts a `$le` comparator for generic key types.
public macro fun remove_by<$Key: copy + drop + store, $V: store>(
    $list: &mut SkipList<$Key, $V>,
    $score: $Key,
    $le: |&$Key, &$Key| -> bool,
): $V {
    let list = $list;
    let score = $score;

    list.assert_contains(score);
    let node = list.remove_node(score);
    let (mut l, mut nexts) = (list.level(), list.head_vec_mut());
    while (l > 0) {
        let mut opt_next_score = nexts.borrow_mut(l - 1);
        while (opt_next_score.is_some_and!(|next_score| $le(next_score, &score))) {
            let next_score = opt_next_score.borrow();
            if ($le(&score, next_score)) {
                *opt_next_score = *node.nexts().borrow(l - 1);
            } else {
                let node = list.borrow_mut_node(*next_score);
                nexts = node.nexts_mut();
                opt_next_score = nexts.borrow_mut(l - 1);
            }
        };
        l = l - 1;
    };

    if (list.tail().is_some_and!(|t| $le(t, &score) && $le(&score, t))) {
        list.set_tail(node.prev_score());
    };

    let opt_l0_next_score = node.next_score();
    if (opt_l0_next_score.is_some()) {
        let next_node = list.borrow_mut_node(*opt_l0_next_score.borrow());
        next_node.set_prev(node.prev_score());
    };

    node.drop_node()
}

public macro fun find_next<$Int, $V: store>(
    $list: &SkipList<$Int, $V>,
    $score: $Int,
    $include: bool,
): Option<$Int> {
    find_next_by!($list, $score, $include, |x, y| *x <= *y)
}

/// Return the next score.
public macro fun find_next_by<$Key: copy + drop + store, $V: store>(
    $list: &SkipList<$Key, $V>,
    $score: $Key,
    $include: bool,
    $le: |&$Key, &$Key| -> bool,
): Option<$Key> {
    let list = $list;
    let score = $score;
    let include = $include;

    let opt_finded_score = list.find_by!(score, $le);
    if (opt_finded_score.is_none()) {
        return opt_finded_score
    };
    let finded_score = opt_finded_score.borrow();
    if ($le(&score, finded_score)) {
        if (!$le(finded_score, &score) || include) {
            return opt_finded_score
        };
    };
    let node = list.borrow_node(*finded_score);
    node.next_score()
}

public macro fun find_prev<$Int, $V: store>(
    $list: &SkipList<$Int, $V>,
    $score: $Int,
    $include: bool,
): Option<$Int> {
    find_prev_by!($list, $score, $include, |x, y| *x <= *y)
}

/// Return the prev socre.
public macro fun find_prev_by<$Key: copy + drop + store, $V: store>(
    $list: &SkipList<$Key, $V>,
    $score: $Key,
    $include: bool,
    $le: |&$Key, &$Key| -> bool,
): Option<$Key> {
    let list = $list;
    let score = $score;
    let include = $include;

    let opt_finded_score = list.find_by!(score, $le);
    if (opt_finded_score.is_none()) {
        return opt_finded_score
    };
    let finded_score = opt_finded_score.borrow();
    if ($le(finded_score, &score)) {
        if (!$le(&score, finded_score) || include) {
            return opt_finded_score
        };
    };
    let node = list.borrow_node(*finded_score);
    node.prev_score()
}

/// Find the nearest score. 1. score, 2. prev, 3. next
public macro fun find_by<$Key: copy + drop + store, $V: store>(
    $list: &SkipList<$Key, $V>,
    $score: $Key,
    $le: |&$Key, &$Key| -> bool,
): Option<$Key> {
    let list = $list;
    let score = $score;

    if (list.level() == 0) {
        return option::none()
    };
    let (mut l, mut nexts, mut current_score) = (list.level(), list.head_vec(), option::none());
    while (l > 0) {
        let mut opt_next_score = *nexts.borrow(l - 1);
        while (option::is_some_and!(&opt_next_score, |next_score| $le(next_score, &score))) {
            let next_score = opt_next_score.borrow();
            if ($le(&score, next_score)) {
                return option::some(*next_score)
            } else {
                let node = list.borrow_node(*next_score);
                current_score = opt_next_score;
                nexts = node.nexts();
                opt_next_score = *nexts.borrow(l - 1);
            };
        };
        if (l == 1 && current_score.is_some()) {
            return current_score
        };
        l = l - 1;
    };
    return list.head()
}

fun rand_level<Key: copy + drop + store, V: store>(seed: u64, list: &SkipList<Key, V>): u64 {
    let mut level = 1;
    let mut mod = list.list_p;
    while ((seed % mod) == 0 && level < list.level + 1) {
        mod = mod * list.list_p;
        level = level + 1;
        if (level > list.level) {
            if (level >= list.max_level) {
                level = list.max_level;
                break
            } else {
                level = list.level + 1;
                break
            }
        }
    };
    level
}

/// Create a new skip list node
public fun create_node<Key: copy + drop + store, V: store>(
    list: &mut SkipList<Key, V>,
    score: Key,
    value: V,
): (u64, Node<Key, V>) {
    let rand = random::rand(&mut list.random);
    let level = rand_level(rand, list);

    // Create a new level for skip list.
    if (level > list.level) {
        list.level = level;
        list.head.push_back(option::none());
    };

    (
        level,
        Node<Key, V> {
            score,
            nexts: vector::empty(),
            prev: option::none(),
            value,
        },
    )
}

public fun drop_node<Key: copy + drop + store, V: store>(node: Node<Key, V>): V {
    let Node {
        score: _,
        nexts: _,
        prev: _,
        value,
    } = node;
    value
}

#[test_only]
public fun print_skip_list<Key: copy + drop + store, V: store>(list: &SkipList<Key, V>) {
    if (list.length() == 0) {
        return
    };
    let mut next_score = list.head();
    while (next_score.is_some()) {
        let node = list.borrow_node(*next_score.borrow());
        next_score = node.next_score();
        std::debug::print(node);
    };
}

#[test_only]
public macro fun check_skip_list<$Key: copy + drop + store, $V: store>($list: &SkipList<$Key, $V>) {
    check_skip_list_by!($list, |a, b| *a > *b)
}

#[test_only]
public macro fun check_skip_list_by<$Key: copy + drop + store, $V: store>(
    $list: &SkipList<$Key, $V>,
    $gt: |&$Key, &$Key| -> bool,
) {
    let list = $list;
    if (list.level() == 0) {
        assert!(list.length() == 0, 0);
    } else {
        // Check level 0
        let (mut size, mut opt_next_score, mut tail, mut prev, mut current_score) = (
            0,
            list.head(),
            option::none(),
            option::none(),
            option::none(),
        );
        while (opt_next_score.is_some()) {
            let next_score = *opt_next_score.borrow();
            let next_node = list.borrow_node(next_score);
            if (current_score.is_some()) {
                assert!($gt(&next_score, current_score.borrow()), 0);
            };
            assert!(next_node.score() == next_score, 0);
            if (prev.is_none()) {
                assert!(next_node.prev_score().is_none(), 0)
            } else {
                assert!(*next_node.prev_score().borrow() == *prev.borrow(), 0);
            };
            prev = option::some(next_node.score());
            tail = option::some(next_node.score());
            current_score.swap_or_fill(next_node.score());
            size = size + 1;
            opt_next_score = next_node.next_score();
        };
        if (tail.is_none()) {
            assert!(list.tail().is_none(), 0);
        } else {
            assert!(*list.tail().borrow() == *tail.borrow(), 0);
        };
        assert!(size == list.length(), 0);

        // Check indexer levels
        let mut l = list.level() - 1;
        while (l > 0) {
            let mut opt_next_l_score = *list.head_vec().borrow(l);
            let mut opt_next_0_score = *list.head_vec().borrow(0);
            while (opt_next_0_score.is_some()) {
                let next_0_score = *opt_next_0_score.borrow();
                let node = list.borrow_node(next_0_score);
                if (opt_next_l_score.is_none() || $gt(opt_next_l_score.borrow(), &node.score())) {
                    assert!(node.nexts().length() <= l, 0);
                } else {
                    if (node.nexts().length() > l) {
                        assert!(*opt_next_l_score.borrow() == node.score(), 0);
                        opt_next_l_score = *node.nexts().borrow(l);
                    }
                };
                opt_next_0_score = *node.nexts().borrow(0);
            };
            l = l - 1;
        };
    };
}

#[test_only]
public fun get_all_scores<Key: copy + drop + store, V: store>(
    list: &SkipList<Key, V>,
): vector<Key> {
    let (mut opt_next_score, mut scores) = (list.head(), vector::empty<Key>());
    while (opt_next_score.is_some()) {
        let next_score = *opt_next_score.borrow();
        let next_node = list.borrow_node(next_score);
        scores.push_back(next_node.score());
        opt_next_score = next_node.next_score();
    };
    scores
}
