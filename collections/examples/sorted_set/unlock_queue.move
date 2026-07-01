/// Ordered-drain / priority-queue pattern - and the home of the library's SINGLE abort.
///
/// A `SortedSet<u64>` of unique unlock TIMESTAMPS in a SHARED vesting object, drained
/// earliest-first. Because the set keeps its keys sorted, the smallest is always at the front
/// and the largest at the back, so it doubles as a min/max priority queue with O(1) peeks.
///
/// # The one abort in the whole library
/// Every other set operation is total (returns `Option` / `bool` / `vector` / `u64`). The ONLY
/// exception is popping an extreme of an EMPTY set: `pop_front` / `pop_back` abort `EEmpty`.
/// Crucially the set asserts its OWN `EEmpty` (code 0) FIRST, before delegating to the wrapped
/// map, so the abort surfaces at `openzeppelin_collections::sorted_set` - a consumer's
/// `#[expected_failure]` must pin that location, NOT the map's. We expose both a guarded drain
/// (`is_empty` first) and the raw `pop_front`/`pop_back` wrappers so a test can trigger the abort.
///
/// `head` / `tail` are the non-aborting counterparts: they PEEK the earliest / latest deadline
/// as an `Option`, returning `none` on an empty queue instead of aborting.
///
/// Lifecycle: `deploy_and_share` -> `schedule` / `cancel` -> `next_deadline` / `last_deadline`
/// (peek) -> `process_earliest` / `process_latest` (pop). A shared object: writers serialize
/// per object.
///
/// # Disclaimer
///
/// This module is an **unaudited example**, provided purely to illustrate ways the
/// `SortedSet` can be integrated. It is not production-ready and must not be deployed
/// as-is.
module openzeppelin_collections::sorted_set_unlock_queue;

use openzeppelin_collections::sorted_set::{Self, SortedSet};
use sui::event;

#[test_only]
use openzeppelin_collections::sorted_map;

/// A queue of unique unlock timestamps, drained in chronological order.
public struct UnlockQueue has key {
    id: UID,
    deadlines: SortedSet<u64>,
}

/// Emitted when a deadline is processed (popped) off the queue.
public struct Unlocked has copy, drop { deadline: u64 }

/// Create a queue seeded from `initial` deadlines (DE-DUPLICATED by `from_keys!`), share it,
/// and return its `ID`.
public fun deploy_and_share(initial: vector<u64>, ctx: &mut TxContext): ID {
    let q = UnlockQueue { id: object::new(ctx), deadlines: sorted_set::from_keys!(initial) };
    let id = object::id(&q);
    transfer::share_object(q);
    id
}

/// Schedule `deadline`. Returns `true` iff newly scheduled (a duplicate returns `false`,
/// no abort).
public fun schedule(q: &mut UnlockQueue, deadline: u64): bool {
    sorted_set::insert!(&mut q.deadlines, deadline)
}

/// Cancel `deadline`. Returns `true` iff it WAS scheduled (cancelling an absent one returns
/// `false`, no abort).
public fun cancel(q: &mut UnlockQueue, deadline: u64): bool {
    sorted_set::remove!(&mut q.deadlines, &deadline)
}

/// The EARLIEST scheduled deadline, WITHOUT removing it, or `none` if empty. O(1), never aborts.
public fun next_deadline(q: &UnlockQueue): Option<u64> {
    sorted_set::head(&q.deadlines)
}

/// The LATEST scheduled deadline, or `none` if empty. O(1), never aborts.
public fun last_deadline(q: &UnlockQueue): Option<u64> {
    sorted_set::tail(&q.deadlines)
}

/// Number of pending deadlines.
public fun pending(q: &UnlockQueue): u64 {
    sorted_set::length(&q.deadlines)
}

/// True iff no deadlines remain - guard `process_earliest` / `process_latest` with this.
public fun is_empty(q: &UnlockQueue): bool {
    sorted_set::is_empty(&q.deadlines)
}

/// Pop and process the EARLIEST deadline, returning it. ABORTS `EEmpty` (the set's own, code 0,
/// at `location = openzeppelin_collections::sorted_set`) if the queue is empty - guard with
/// `is_empty` or peek `next_deadline` first.
public fun process_earliest(q: &mut UnlockQueue): u64 {
    let deadline = sorted_set::pop_front(&mut q.deadlines);
    event::emit(Unlocked { deadline });
    deadline
}

/// Pop and process the LATEST deadline (the other extreme), returning it. Same `EEmpty` abort
/// on an empty queue.
public fun process_latest(q: &mut UnlockQueue): u64 {
    let deadline = sorted_set::pop_back(&mut q.deadlines);
    event::emit(Unlocked { deadline });
    deadline
}

// === Test-only order check ===

/// True iff the embedded set is correctly ordered (reaches the map oracle via `inner_ref`).
#[test_only]
public fun deadlines_well_formed(q: &UnlockQueue): bool {
    sorted_map::is_well_formed!(sorted_set::inner_ref(&q.deadlines))
}
