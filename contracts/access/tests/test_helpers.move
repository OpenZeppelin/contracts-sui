#[test_only]
module openzeppelin_access::test_helpers;

public fun dummy_ctx_with_sender(sender: address): TxContext {
    let tx_hash = x"3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532";
    tx_context::new(sender, tx_hash, 0, 0, 0)
}
