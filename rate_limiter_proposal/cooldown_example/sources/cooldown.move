module cooldown_example::cooldown;

use sui::clock::Clock;

const SCOPE_KIND_GLOBAL: u8 = 0;
const SCOPE_KIND_ADDRESS: u8 = 1;

#[error(code = 0)]
const EPolicyMismatch: vector<u8> = "Policy mismatch";
#[error(code = 1)]
const ERateLimited: vector<u8> = "Rate limited";
#[error(code = 2)]
const EPolicyDisabled: vector<u8> = "Policy disabled";
#[error(code = 3)]
const EInvalidPolicy: vector<u8> = "Invalid policy";

public struct Policy<phantom Tag> has key, store {
    id: UID,
    version: u16,
    cooldown_ms: u64,
    enabled: bool,
}

public struct State<phantom Tag> has key, store {
    id: UID,
    policy_id: ID,
    scope_kind: u8,
    scope_key_hash: vector<u8>,
    last_action_ms: u64,
    has_acted: bool,
}

public fun create_policy<Tag>(version: u16, cooldown_ms: u64, ctx: &mut TxContext): Policy<Tag> {
    assert!(cooldown_ms > 0, EInvalidPolicy);
    Policy {
        id: object::new(ctx),
        version,
        cooldown_ms,
        enabled: true,
    }
}

public fun create_global_state<Tag>(
    policy: &Policy<Tag>,
    clock: &Clock,
    ctx: &mut TxContext,
): State<Tag> {
    State {
        id: object::new(ctx),
        policy_id: object::id(policy),
        scope_kind: SCOPE_KIND_GLOBAL,
        scope_key_hash: vector[],
        last_action_ms: clock.timestamp_ms(),
        has_acted: false,
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
        last_action_ms: clock.timestamp_ms(),
        has_acted: false,
    }
}

public fun available<Tag>(policy: &Policy<Tag>, state: &State<Tag>, clock: &Clock): u64 {
    assert_policy(policy, state);
    if (!state.has_acted) {
        1
    } else if (clock.timestamp_ms() >= state.last_action_ms + policy.cooldown_ms) {
        1
    } else {
        0
    }
}

public fun consume_or_abort<Tag>(
    policy: &Policy<Tag>,
    state: &mut State<Tag>,
    amount: u64,
    clock: &Clock,
) {
    assert!(policy.enabled, EPolicyDisabled);
    assert_policy(policy, state);
    let _ = amount;
    if (state.has_acted) {
        assert!(clock.timestamp_ms() >= state.last_action_ms + policy.cooldown_ms, ERateLimited);
    };
    state.last_action_ms = clock.timestamp_ms();
    state.has_acted = true;
}

public fun destroy_policy<Tag>(policy: Policy<Tag>) {
    let Policy { id, version: _, cooldown_ms: _, enabled: _ } = policy;
    id.delete();
}

public fun destroy_state<Tag>(state: State<Tag>) {
    let State {
        id,
        policy_id: _,
        scope_kind: _,
        scope_key_hash: _,
        last_action_ms: _,
        has_acted: _,
    } = state;
    id.delete();
}

fun assert_policy<Tag>(policy: &Policy<Tag>, state: &State<Tag>) {
    assert!(state.policy_id == object::id(policy), EPolicyMismatch);
}
