module openzeppelin_access::ownable_tests;

use openzeppelin_access::ownable;

#[test_only]
public struct ImmediateTransferOTW has drop {}

#[test]
fun transfer_ownership_moves_cap_to_new_owner() {
    let owner = @0xA;
    let recipient = @0xB;
    let mut ctx = tx_context::new(
        owner,
        tx_context::dummy_tx_hash_with_hint(0),
        0,
        0,
        0,
    );

    let owner_cap = ownable::create_immediate_owner_cap_for_testing<ImmediateTransferOTW>(&mut ctx);
    assert!(ownable::is_immediate_transfer_policy(&owner_cap));

    let cap_id = object::id(&owner_cap);
    ownable::transfer_ownership(owner_cap, recipient, &mut ctx);

    let (
        emitted_cap_id,
        previous_owner,
        new_owner,
    ) = ownable::last_transfer_event_fields_for_testing();
    assert!(emitted_cap_id == cap_id);
    assert!(previous_owner == owner);
    assert!(new_owner == recipient);
}
