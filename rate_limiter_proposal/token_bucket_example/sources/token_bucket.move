module token_bucket_example::token_bucket;

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
    capacity: u64,
    refill_numerator: u64,
    refill_denominator_ms: u64,
    initial_tokens: u64,
    enabled: bool,
}

public struct State<phantom Tag> has key, store {
    id: UID,
    policy_id: ID,
    scope_kind: u8,
    scope_key_hash: vector<u8>,
    available: u64,
    last_refill_ms: u64,
    fractional_remainder: u64,
}

public fun create_policy<Tag>(
    version: u16,
    capacity: u64,
    refill_numerator: u64,
    refill_denominator_ms: u64,
    initial_tokens: u64,
    ctx: &mut TxContext,
): Policy<Tag> {
    assert!(refill_denominator_ms > 0, EInvalidPolicy);
    assert!(initial_tokens <= capacity, EInvalidPolicy);
    Policy {
        id: object::new(ctx),
        version,
        capacity,
        refill_numerator,
        refill_denominator_ms,
        initial_tokens,
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
        available: policy.initial_tokens,
        last_refill_ms: clock.timestamp_ms(),
        fractional_remainder: 0,
    }
}

public fun create_for_address<Tag>(
    policy: &Policy<Tag>,
    owner: address,
    clock: &Clock,
    ctx: &mut TxContext,
): State<Tag> {
    let scope_key_hash = vector[];
    let _ = owner;
    State {
        id: object::new(ctx),
        policy_id: object::id(policy),
        scope_kind: SCOPE_KIND_ADDRESS,
        scope_key_hash,
        available: policy.initial_tokens,
        last_refill_ms: clock.timestamp_ms(),
        fractional_remainder: 0,
    }
}

public fun create_for_address_with_available<Tag>(
    policy: &Policy<Tag>,
    owner: address,
    initial_available: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): State<Tag> {
    let scope_key_hash = vector[];
    let _ = owner;
    assert!(initial_available <= policy.capacity, EInvalidPolicy);
    State {
        id: object::new(ctx),
        policy_id: object::id(policy),
        scope_kind: SCOPE_KIND_ADDRESS,
        scope_key_hash,
        available: initial_available,
        last_refill_ms: clock.timestamp_ms(),
        fractional_remainder: 0,
    }
}

public fun available<Tag>(policy: &Policy<Tag>, state: &State<Tag>, clock: &Clock): u64 {
    assert_policy(policy, state);
    let (available, _, _) = refilled_values(policy, state, clock.timestamp_ms());
    available
}

public fun initial_tokens<Tag>(policy: &Policy<Tag>): u64 {
    policy.initial_tokens
}

public fun consume_or_abort<Tag>(
    policy: &Policy<Tag>,
    state: &mut State<Tag>,
    amount: u64,
    clock: &Clock,
) {
    assert!(policy.enabled, EPolicyDisabled);
    assert_policy(policy, state);
    let (available, last_refill_ms, fractional_remainder) = refilled_values(
        policy,
        state,
        clock.timestamp_ms(),
    );
    assert!(available >= amount, ERateLimited);
    state.available = available - amount;
    state.last_refill_ms = last_refill_ms;
    state.fractional_remainder = fractional_remainder;
}

public fun destroy_policy<Tag>(policy: Policy<Tag>) {
    let Policy {
        id,
        version: _,
        capacity: _,
        refill_numerator: _,
        refill_denominator_ms: _,
        initial_tokens: _,
        enabled: _,
    } = policy;
    id.delete();
}

public fun destroy_state<Tag>(state: State<Tag>) {
    let State {
        id,
        policy_id: _,
        scope_kind: _,
        scope_key_hash: _,
        available: _,
        last_refill_ms: _,
        fractional_remainder: _,
    } = state;
    id.delete();
}

fun assert_policy<Tag>(policy: &Policy<Tag>, state: &State<Tag>) {
    assert!(state.policy_id == object::id(policy), EPolicyMismatch);
}

fun refilled_values<Tag>(policy: &Policy<Tag>, state: &State<Tag>, now_ms: u64): (u64, u64, u64) {
    let elapsed_ms = now_ms - state.last_refill_ms;
    if (elapsed_ms == 0) {
        return (state.available, state.last_refill_ms, state.fractional_remainder)
    };

    let accrual =
        (elapsed_ms as u128) * (policy.refill_numerator as u128) + (state.fractional_remainder as u128);
    let whole = (accrual / (policy.refill_denominator_ms as u128)) as u64;
    let remainder = (accrual % (policy.refill_denominator_ms as u128)) as u64;
    let mut available = state.available;
    let mut fractional_remainder = remainder;
    if (whole > 0) {
        available = if (whole >= policy.capacity - available) {
            fractional_remainder = 0;
            policy.capacity
        } else {
            available + whole
        };
    };
    (available, now_ms, fractional_remainder)
}
