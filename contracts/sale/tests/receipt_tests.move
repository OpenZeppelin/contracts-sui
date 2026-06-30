// Receipt construction / view / consume tests.
//
// `Receipt<S>` non-transferability is a *type-level* property (`key` only, no
// `store`, package-private transfer path) enforced at compile time — it cannot
// be exercised at runtime and is documented in the test artifact's Out of Scope.
// These tests pin the data carried by a receipt and the consume round-trip,
// which the sale's claim/refund paths depend on.
module openzeppelin_sale::receipt_tests;

use openzeppelin_sale::receipt;
use openzeppelin_sale::test_utils::SALE;
use std::unit_test::assert_eq;

#[test]
fun new_receipt_exposes_fields() {
    let mut ctx = tx_context::dummy();
    let sale_id = object::id_from_address(@0x5A1E);
    let buyer = @0xB0B;

    let r = receipt::new_receipt<SALE>(sale_id, buyer, 100, 250, 1_700, &mut ctx);
    assert_eq!(r.sale_id(), sale_id);
    assert_eq!(r.buyer(), buyer);
    assert_eq!(r.paid(), 100);
    assert_eq!(r.allocation(), 250);
    assert_eq!(r.purchased_at_ms(), 1_700);

    // consume returns the same tuple and deletes the UID.
    let (s, b, p, a, t) = r.consume();
    assert_eq!(s, sale_id);
    assert_eq!(b, buyer);
    assert_eq!(p, 100);
    assert_eq!(a, 250);
    assert_eq!(t, 1_700);
}
