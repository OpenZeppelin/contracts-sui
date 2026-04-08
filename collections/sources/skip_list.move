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
public fun head<Key: copy + drop + store, V: store>(list: &SkipList<Key, V>): &vector<Option<Key>> {
    &list.head
}

/// Return the next score of the node.
public fun next_score<Key: copy + drop + store, V: store>(node: &Node<Key, V>): Option<Key> {
    *node.nexts.borrow(0)
}

/// Return an immutable reference to the nexts vector of the node.
public fun nexts<Key: copy + drop + store, V: store>(node: &Node<Key, V>): &vector<Option<Key>> {
    &node.nexts
}

/// Return the prev score of the node.
public fun prev_score<Key: copy + drop + store, V: store>(node: &Node<Key, V>): Option<Key> {
    node.prev
}

/// Return the immutable reference to the ndoe's value.
public fun borrow_value<Key: copy + drop + store, V: store>(node: &Node<Key, V>): &V {
    &node.value
}

/// Return the mutable reference to the ndoe's value.
public fun borrow_mut_value<Key: copy + drop + store, V: store>(node: &mut Node<Key, V>): &mut V {
    &mut node.value
}

// /// Insert a score-value into skip list, abort if the score alread exist.
// public fun insert<Key: copy + drop + store, V: store>(list: &mut SkipList<Key, V>, score: Key, v: V) {
//     assert!(!list.contains(score), ENodeAlreadyExist);
//     let (level, mut new_node) = list.create_node(score, v);
//     let (mut l, mut nexts, mut prev) = (list.level, &mut list.head, option::none());
//     let mut opt_l0_next_score = option::none();
//     while (l > 0) {
//         let mut opt_next_score = nexts.borrow_mut(l - 1);
//         while (option::is_some_and!(opt_next_score, |next_score| *next_score <= score)) {
//             let node = list
//                 .inner
//                 .borrow_mut(
//                     *opt_next_score.borrow(),
//                 );
//             prev = option::some(node.score);
//             nexts = &mut node.nexts;
//             opt_next_score = nexts.borrow_mut(l - 1);
//         };
//         if (level >= l) {
//             new_node.nexts.push_back(*opt_next_score);
//             if (l == 1) {
//                 new_node.prev = prev;
//                 if (opt_next_score.is_some()) {
//                     opt_l0_next_score = *opt_next_score;
//                 } else {
//                     list.tail = option::some(score);
//                 }
//             };
//             opt_next_score.swap_or_fill(score);
//         };
//         l = l - 1;
//     };
//     if (opt_l0_next_score.is_some()) {
//         let next_node = list.borrow_mut_node(*opt_l0_next_score.borrow());
//         next_node.prev = option::some(score);
//     };

//     new_node.nexts.reverse();
//     list.inner.add(score, new_node);
// }

// /// Remove the score-value from skip list, abort if the score not exist in list.
// public fun remove<Key: copy + drop + store, V: store>(list: &mut SkipList<Key, V>, score: Key): V {
//     assert!(list.contains(score), ENodeDoesNotExist);
//     let (mut l, mut nexts) = (list.level, &mut list.head);
//     let node = list.inner.remove(score);
//     while (l > 0) {
//         let mut opt_next_score = nexts.borrow_mut(l - 1);
//         while (option::is_some_and!(opt_next_score, |next_score| *next_score <= score)) {
//             let next_score = opt_next_score.borrow();
//             if (next_score == score) {
//                 *opt_next_score = *node.nexts.borrow(l - 1);
//             } else {
//                 let node = list.borrow_mut_node(*next_score);
//                 nexts = &mut node.nexts;
//                 opt_next_score = nexts.borrow_mut(l - 1);
//             }
//         };
//         l = l - 1;
//     };

//     if (list.tail.borrow() == score) {
//         list.tail = node.prev;
//     };

//     let opt_l0_next_score = node.nexts.borrow(0);
//     if (opt_l0_next_score.is_some()) {
//         let next_node = list.inner.borrow_mut(*opt_l0_next_score.borrow());
//         next_node.prev = node.prev;
//     };

//     node.drop_node()
// }

public(package) fun find_next_u64<V: store>(
    list: &SkipList<u64, V>,
    score: u64,
    include: bool,
): Option<u64> {
    find_next_by!(list, score, include, |x, y| *x <= *y)
}

public(package) fun find_next_u128<V: store>(
    list: &SkipList<u128, V>,
    score: u128,
    include: bool,
): Option<u128> {
    find_next_by!(list, score, include, |x, y| *x <= *y)
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

public(package) fun find_prev_u64<V: store>(
    list: &SkipList<u64, V>,
    score: u64,
    include: bool,
): Option<u64> {
    find_prev_by!(list, score, include, |x, y| *x <= *y)
}

public(package) fun find_prev_u128<V: store>(
    list: &SkipList<u128, V>,
    score: u128,
    include: bool,
): Option<u128> {
    find_prev_by!(list, score, include, |x, y| *x <= *y)
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
macro fun find_by<$Key: copy + drop + store, $V: store>(
    $list: &SkipList<$Key, $V>,
    $score: $Key,
    $le: |&$Key, &$Key| -> bool,
): Option<$Key> {
    let list = $list;
    let score = $score;

    if (list.level() == 0) {
        return option::none()
    };
    let (mut l, mut nexts, mut current_score) = (list.level(), list.head(), option::none());
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
    return *list.head().borrow(0)
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
fun create_node<Key: copy + drop + store, V: store>(
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

fun drop_node<Key: copy + drop + store, V: store>(node: Node<Key, V>): V {
    let Node {
        score: _,
        nexts: _,
        prev: _,
        value,
    } = node;
    value
}
