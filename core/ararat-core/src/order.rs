// Port of the midpoint step of rocicorp's fractional-indexing (CC0). Integer positions were not
// used because a move would renumber siblings, and each renumbered sibling becomes a sync write.

const DIGITS: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

pub fn key_between(lo: Option<&str>, hi: Option<&str>) -> String {
    let lo = lo.unwrap_or("");
    if let Some(hi) = hi {
        assert!(lo < hi, "key_between needs lo < hi, got {lo:?} >= {hi:?}");
    }
    midpoint(lo.as_bytes(), hi.map(str::as_bytes))
}

fn midpoint(a: &[u8], b: Option<&[u8]>) -> String {
    if let Some(b) = b {
        let common = (0..b.len())
            .take_while(|&i| a.get(i).copied().unwrap_or(DIGITS[0]) == b[i])
            .count();
        if common > 0 {
            let prefix = String::from_utf8(b[..common].to_vec()).unwrap();
            return prefix + &midpoint(a.get(common..).unwrap_or(&[]), Some(&b[common..]));
        }
    }
    let da = a.first().map_or(0, |&c| digit(c));
    let db = b.and_then(|b| b.first()).map_or(DIGITS.len(), |&c| digit(c));
    if db - da > 1 {
        return (DIGITS[(da + db).div_ceil(2)] as char).to_string();
    }
    match b {
        Some(b) if b.len() > 1 => (b[0] as char).to_string(),
        _ => (DIGITS[da] as char).to_string() + &midpoint(a.get(1..).unwrap_or(&[]), None),
    }
}

fn digit(c: u8) -> usize {
    DIGITS.iter().position(|&d| d == c).expect("order key outside the base-62 alphabet")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_sort_between_their_neighbours() {
        let mut keys = vec![key_between(None, None)];
        for _ in 0..50 {
            let last = keys.last().unwrap().clone();
            keys.push(key_between(Some(&last), None));
        }
        for _ in 0..50 {
            let first = keys[0].clone();
            keys.insert(0, key_between(None, Some(&first)));
        }
        for i in 0..40 {
            let k = key_between(Some(&keys[i]), Some(&keys[i + 1]));
            keys.insert(i + 1, k);
        }
        assert!(keys.windows(2).all(|w| w[0] < w[1]), "{keys:?}");
        assert!(keys.iter().all(|k| !k.ends_with('0')));
    }

    #[test]
    fn repeated_inserts_at_one_spot_stay_ordered() {
        let (lo, mut hi) = (key_between(None, None), None::<String>);
        let mut inserted = Vec::new();
        for _ in 0..200 {
            let k = key_between(Some(&lo), hi.as_deref());
            if let Some(h) = &hi {
                assert!(lo < k && k < *h);
            }
            inserted.push(k.clone());
            hi = Some(k);
        }
    }
}
