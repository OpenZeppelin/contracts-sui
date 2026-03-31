module fixed_window_example::fixed_window;

use sui::clock::Clock;

const SCOPE_KIND_GLOBAL: u8 = 0;
const SCOPE_KIND_ADDRESS: u8 = 1;

#[error(code = 0)]
const EPolicyMismatch: vector<u8> = b"Policy mismatch";
#[error(code = 1)]
const ERateLimited: vector<u8> = b"Rate limited";
#[error(code = 2)]
const EPolicyDisabled: vector<u8> = b"Policy disabled";
#[error(code = 3)]
const EInvalidPolicy: vector<u8> = b"Invalid policy";

public struct Policy<phantom Tag> has key, store {
    id: UID,
    version: u16,
    window_ms: u64,
    limit: u64,
    enabled: bool,
}

public struct State<phantom Tag> has key, store {
    id: UID,
    policy_id: ID,
    scope_kind: u8,
    scope_key_hash: vector<u8>,
    window_start_ms: u64,
    used: u64,
}

public fun create_policy<Tag>(version: u16, window_ms: u64, limit: u64, ctx: &mut TxContext): Policy<Tag> {
    assert!(window_ms > 0, EInvalidPolicy);
    Policy {
        id: object::new(ctx),
        version,
        window_ms,
        limit,
        enabled: true,
    }
}

public fun create_global_state<Tag>(policy: &Policy<Tag>, clock: &Clock, ctx: &mut TxContext): State<Tag> {
    State {
        id: object::new(ctx),
        policy_id: object::id(policy),
        scope_kind: SCOPE_KIND_GLOBAL,
        scope_key_hash: vector[],
        window_start_ms: clock.timestamp_ms(),
        used: 0,
    }
}

public fun create_for_address<Tag>(
    policy: &Policy<Tag>,
    owner: address,
    clock: &Clock,
    ctx: &mut TxContext,
): State<Tag> {
    let _ = owner;
    State {
        id: object::new(ctx),
        policy_id: object::id(policy),
        scope_kind: SCOPE_KIND_ADDRESS,
        scope_key_hash: vector[],
        window_start_ms: clock.timestamp_ms(),
        used: 0,
    }
}

public fun available<Tag>(policy: &Policy<Tag>, state: &State<Tag>, clock: &Clock): u64 {
    assert_policy(policy, state);
    let used = current_used(policy, state, clock.timestamp_ms());
    if (used >= policy.limit) {
        0
    } else {
        policy.limit - used
    }
}

public fun consume_or_abort<Tag>(policy: &Policy<Tag>, state: &mut State<Tag>, amount: u64, clock: &Clock) {
    assert!(policy.enabled, EPolicyDisabled);
    assert_policy(policy, state);
    let now_ms = clock.timestamp_ms();
    let (window_start_ms, used) = current_window(policy, state, now_ms);
    assert!(used + amount <= policy.limit, ERateLimited);
    state.window_start_ms = window_start_ms;
    state.used = used + amount;
}

public fun destroy_policy<Tag>(policy: Policy<Tag>) {
    let Policy { id, version: _, window_ms: _, limit: _, enabled: _ } = policy;
    id.delete();
}

public fun destroy_state<Tag>(state: State<Tag>) {
    let State { id, policy_id: _, scope_kind: _, scope_key_hash: _, window_start_ms: _, used: _ } = state;
    id.delete();
}

fun assert_policy<Tag>(policy: &Policy<Tag>, state: &State<Tag>) {
    assert!(state.policy_id == object::id(policy), EPolicyMismatch);
}

fun current_used<Tag>(policy: &Policy<Tag>, state: &State<Tag>, now_ms: u64): u64 {
    let (_, used) = current_window(policy, state, now_ms);
    used
}

fun current_window<Tag>(policy: &Policy<Tag>, state: &State<Tag>, now_ms: u64): (u64, u64) {
    if (now_ms >= state.window_start_ms + policy.window_ms) {
        (now_ms, 0)
    } else {
        (state.window_start_ms, state.used)
    }
}
