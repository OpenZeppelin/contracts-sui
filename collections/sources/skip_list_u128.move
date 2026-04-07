module openzeppelin_collections::skip_list_u128;

use openzeppelin_collections::skip_list::SkipList;

public fun find_next<V: store>(list: &SkipList<u128, V>, score: u128, include: bool): Option<u128> {
    list.find_next_u128(score, include)
}

public fun find_prev<V: store>(list: &SkipList<u128, V>, score: u128, include: bool): Option<u128> {
    list.find_prev_u128(score, include)
}
