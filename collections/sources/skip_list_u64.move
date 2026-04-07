module openzeppelin_collections::skip_list_u64;

use openzeppelin_collections::skip_list::SkipList;

public fun find_prev<V: store>(list: &SkipList<u64, V>, score: u64, include: bool): Option<u64> {
    list.find_prev_u64(score, include)
}
