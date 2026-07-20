// Allowlist compliance-slot tests.
//
// `AllowEntry<S>` is a single-use, no-ability ticket: minted by the compliance
// module (gated by `AllowlistAdminCap<S>`), consumed once by the sale's `purchase`
// with its sale_id + buyer asserted. The single-PTB consume coupling
// and the symmetric allowlist gate are exercised end-to-end in
// `prefunded_sale_purchase_tests`; here we pin the entry's own consume asserts.
module openzeppelin_sale::allowlist_tests;

use openzeppelin_sale::allowlist;
use openzeppelin_sale::test_utils::SALE;
use std::unit_test::{assert_eq, destroy};

#[test]
fun new_admin_and_consume_returns_max_amount() {
    let mut ctx = tx_context::dummy();
    let sale_id = object::id_from_address(@0x5A1E);
    let buyer = @0xB0B;

    let admin = allowlist::new_admin<SALE>(sale_id, &mut ctx);
    assert_eq!(admin.admin_sale_id(), sale_id);

    let entry = admin.new_entry(buyer, 500);
    let max = entry.consume(sale_id, buyer);
    assert_eq!(max, 500);

    destroy(admin);
}

// consume rejects an entry minted for a different sale.
#[test, expected_failure(abort_code = allowlist::EWrongSaleId)]
fun consume_wrong_sale_aborts() {
    let mut ctx = tx_context::dummy();
    let admin = allowlist::new_admin<SALE>(object::id_from_address(@0x5A1E), &mut ctx);
    let entry = admin.new_entry(@0xB0B, 0);
    let _ = entry.consume(object::id_from_address(@0x0E0E), @0xB0B); // aborts
    abort
}

// consume rejects an entry whose buyer is not the sender.
#[test, expected_failure(abort_code = allowlist::EWrongBuyer)]
fun consume_wrong_buyer_aborts() {
    let mut ctx = tx_context::dummy();
    let sale_id = object::id_from_address(@0x5A1E);
    let admin = allowlist::new_admin<SALE>(sale_id, &mut ctx);
    let entry = admin.new_entry(@0xB0B, 0);
    let _ = entry.consume(sale_id, @0xBAD); // aborts
    abort
}
