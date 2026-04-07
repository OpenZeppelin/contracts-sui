module openzeppelin_collections::skip_list;

use openzeppelin_collections::random::{Self, Random};
use sui::dynamic_field as field;

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
public struct SkipList<phantom V: store> has key, store {
    /// The id of this skip list.
    id: UID,
    /// The skip list header of each level. i.e. the score of node.
    head: vector<Option<u64>>,
    /// The level0's tail of skip list. i.e. the score of node.
    tail: Option<u64>,
    /// The current level of this skip list.
    level: u64,
    /// The max level of this skip list.
    max_level: u64,
    /// Basic probability of random of node indexer's level i.e. (list_p = 2, level2 = 1/2, level3 = 1/4).
    list_p: u64,
    /// The size of skip list
    size: u64,
    /// The random for generate ndoe's level
    random: Random,
}

/// The node of skip list.
public struct Node<V: store> has store {
    /// The score of node.
    score: u64,
    /// The next node score of node's each level.
    nexts: vector<Option<u64>>,
    /// The prev node score of node.
    prev: Option<u64>,
    /// The data being stored
    value: V,
}

/// Create a new empty skip list.
public fun new<V: store>(max_level: u64, list_p: u64, seed: u64, ctx: &mut TxContext): SkipList<V> {
    assert!(list_p > 1, EInvalidListP);
    let list = SkipList<V> {
        id: object::new(ctx),
        head: vector::empty(),
        tail: option::none(),
        level: 0,
        max_level,
        list_p,
        random: random::new(seed),
        size: 0,
    };
    list
}

/// Return the length of the skip list.
public fun length<V: store>(list: &SkipList<V>): u64 {
    list.size
}

/// Returns true if the skip list is empty (if `length` returns `0`)
public fun is_empty<V: store>(list: &SkipList<V>): bool {
    list.size == 0
}

/// Return the head of the skip list.
public fun head<V: store>(list: &SkipList<V>): Option<u64> {
    if (is_empty(list)) {
        return option::none()
    };
    *vector::borrow(&list.head, 0)
}

/// Return the tail of the skip list.
public fun tail<V: store>(list: &SkipList<V>): Option<u64> {
    list.tail
}

/// Destroys an empty skip list
/// Aborts with `ETableNotEmpty` if the list still contains values
public fun destroy_empty<V: store + drop>(list: SkipList<V>) {
    let SkipList<V> {
        id,
        head: _,
        tail: _,
        level: _,
        max_level: _,
        list_p: _,
        random: _,
        size,
    } = list;
    assert!(size == 0, ESkipListNotEmpty);
    id.delete();
}

/// Returns true if there is a value associated with the score `score` in skip list
public fun contains<V: store>(list: &SkipList<V>, score: u64): bool {
    field::exists_with_type<u64, Node<V>>(&list.id, score)
}

/// Acquire an immutable reference to the `score` element of the skip list `list`.
/// Aborts if element not exist.
public fun borrow<V: store>(list: &SkipList<V>, score: u64): &V {
    &field::borrow<u64, Node<V>>(&list.id, score).value
}

/// Return a mutable reference to the `score` element in the skip list `list`.
/// Aborts if element is not exist.
public fun borrow_mut<V: store>(list: &mut SkipList<V>, score: u64): &mut V {
    &mut field::borrow_mut<u64, Node<V>>(&mut list.id, score).value
}

/// Acquire an immutable reference to the `score` node of the skip list `list`.
/// Aborts if node not exist.
public fun borrow_node<V: store>(list: &SkipList<V>, score: u64): &Node<V> {
    field::borrow<u64, Node<V>>(&list.id, score)
}

/// Return a mutable reference to the `score` node in the skip list `list`.
/// Aborts if node is not exist.
public fun borrow_mut_node<V: store>(list: &mut SkipList<V>, score: u64): &mut Node<V> {
    field::borrow_mut<u64, Node<V>>(&mut list.id, score)
}

/// Return the metadata info of skip list.
public fun metadata<V: store>(
    list: &SkipList<V>,
): (vector<Option<u64>>, Option<u64>, u64, u64, u64, u64) {
    (list.head, list.tail, list.level, list.max_level, list.list_p, list.size)
}

/// Return the next score of the node.
public fun next_score<V: store>(node: &Node<V>): Option<u64> {
    *vector::borrow(&node.nexts, 0)
}

/// Return the prev score of the node.
public fun prev_score<V: store>(node: &Node<V>): Option<u64> {
    node.prev
}

/// Return the immutable reference to the ndoe's value.
public fun borrow_value<V: store>(node: &Node<V>): &V {
    &node.value
}

/// Return the mutable reference to the ndoe's value.
public fun borrow_mut_value<V: store>(node: &mut Node<V>): &mut V {
    &mut node.value
}

/// Insert a score-value into skip list, abort if the score alread exist.
public fun insert<V: store>(list: &mut SkipList<V>, score: u64, v: V) {
    assert!(!contains(list, score), ENodeAlreadyExist);
    let (level, mut new_node) = list.create_node(score, v);
    let (mut l, mut nexts, mut prev) = (list.level, &mut list.head, option::none());
    let mut opt_l0_next_score = option::none();
    while (l > 0) {
        let mut opt_next_score = nexts.borrow_mut(l - 1);
        while (option::is_some_and!(opt_next_score, |next_score| *next_score <= score)) {
            let node = field::borrow_mut<u64, Node<V>>(
                &mut list.id,
                *opt_next_score.borrow(),
            );
            prev = option::some(node.score);
            nexts = &mut node.nexts;
            opt_next_score = nexts.borrow_mut(l - 1);
        };
        if (level >= l) {
            new_node.nexts.push_back(*opt_next_score);
            if (l == 1) {
                new_node.prev = prev;
                if (opt_next_score.is_some()) {
                    opt_l0_next_score = *opt_next_score;
                } else {
                    list.tail = option::some(score);
                }
            };
            opt_next_score.swap_or_fill(score);
        };
        l = l - 1;
    };
    if (opt_l0_next_score.is_some()) {
        let next_node = list.borrow_mut_node(*opt_l0_next_score.borrow());
        next_node.prev = option::some(score);
    };

    new_node.nexts.reverse();
    field::add(&mut list.id, score, new_node);
    list.size = list.size + 1;
}

/// Remove the score-value from skip list, abort if the score not exist in list.
public fun remove<V: store>(list: &mut SkipList<V>, score: u64): V {
    assert!(contains(list, score), ENodeDoesNotExist);
    let (mut l, mut nexts) = (list.level, &mut list.head);
    let node: Node<V> = field::remove(&mut list.id, score);
    while (l > 0) {
        let mut opt_next_score = nexts.borrow_mut(l - 1);
        while (option::is_some_and!(opt_next_score, |next_score| *next_score <= score)) {
            let next_score = opt_next_score.borrow();
            if (next_score == score) {
                *opt_next_score = *node.nexts.borrow(l - 1);
            } else {
                let node = list.borrow_mut_node(*next_score);
                nexts = &mut node.nexts;
                opt_next_score = nexts.borrow_mut(l - 1);
            }
        };
        l = l - 1;
    };

    if (list.tail.borrow() == score) {
        list.tail = node.prev;
    };

    let opt_l0_next_score = node.nexts.borrow(0);
    if (opt_l0_next_score.is_some()) {
        let next_node = list.borrow_mut_node(*opt_l0_next_score.borrow());
        next_node.prev = node.prev;
    };
    list.size = list.size - 1;

    node.drop_node()
}

/// Return the next score.
public fun find_next<V: store>(list: &SkipList<V>, score: u64, include: bool): Option<u64> {
    let opt_finded_score = list.find(score);
    if (opt_finded_score.is_none()) {
        return opt_finded_score
    };
    let finded_score = *opt_finded_score.borrow();
    if ((include && finded_score == score) || (finded_score > score)) {
        return opt_finded_score
    };
    let node = list.borrow_node(finded_score);
    *node.nexts.borrow(0)
}

/// Return the prev socre.
public fun find_prev<V: store>(list: &SkipList<V>, score: u64, include: bool): Option<u64> {
    let opt_finded_score = list.find(score);
    if (opt_finded_score.is_none()) {
        return opt_finded_score
    };
    let finded_score = *opt_finded_score.borrow();
    if ((include && finded_score == score) || (finded_score < score)) {
        return opt_finded_score
    };
    let node = list.borrow_node(finded_score);
    node.prev
}

/// Find the nearest score. 1. score, 2. prev, 3. next
fun find<V: store>(list: &SkipList<V>, score: u64): Option<u64> {
    if (list.size == 0) {
        return option::none()
    };
    let (mut l, mut nexts, mut current_score) = (list.level, &list.head, option::none());
    while (l > 0) {
        let mut opt_next_score = *nexts.borrow(l - 1);
        while (option::is_some_and!(&opt_next_score, |next_score| *next_score <= score)) {
            let next_score = opt_next_score.borrow();
            if (next_score == score) {
                return option::some(*next_score)
            } else {
                let node = list.borrow_node(*next_score);
                current_score = opt_next_score;
                nexts = &node.nexts;
                opt_next_score = *vector::borrow(nexts, l - 1);
            };
        };
        if (l == 1 && current_score.is_some()) {
            return current_score
        };
        l = l - 1;
    };
    return *vector::borrow(&list.head, 0)
}

fun rand_level<V: store>(seed: u64, list: &SkipList<V>): u64 {
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
fun create_node<V: store>(list: &mut SkipList<V>, score: u64, value: V): (u64, Node<V>) {
    let rand = random::rand(&mut list.random);
    let level = rand_level(rand, list);

    // Create a new level for skip list.
    if (level > list.level) {
        list.level = level;
        list.head.push_back(option::none());
    };

    (
        level,
        Node<V> {
            score,
            nexts: vector::empty(),
            prev: option::none(),
            value,
        },
    )
}

fun drop_node<V: store>(node: Node<V>): V {
    let Node {
        score: _,
        nexts: _,
        prev: _,
        value,
    } = node;
    value
}
