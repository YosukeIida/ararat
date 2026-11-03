use ararat_core::{import::arc_sidebar, model::{Lifecycle, Op, Profile, Record, Workspace}};
fn workspace() -> Workspace {
    let mut ws = arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json")).unwrap();
    ws.spaces[1].profile = Profile::Default;
    ws
}
fn ids(ws: &Workspace, parent: &str) -> Vec<String> { ws.children(parent).iter().map(|i| i.id.clone()).collect() }
fn replay(ws: &mut Workspace, f: impl FnOnce(&mut Workspace) -> Vec<Op>) -> Vec<Op> {
    let mut copy = ws.clone(); let ops = f(ws);
    for op in &ops { copy.apply(op); }
    assert_eq!(*ws, copy); ws.check_tree().unwrap(); ops
}
#[test]
fn concurrent_append_ties_allow_drops_and_folder_creation() {
    let base = workspace(); let mut a = base.clone(); let mut b = base;
    a.move_item("tab-spec", "today-work", 0, false).unwrap();
    let ops = b.move_item("tab-mail", "today-work", 0, false).unwrap(); for op in &ops { a.apply(op); }
    assert_eq!(a.items["tab-spec"].membership.order, a.items["tab-mail"].membership.order);
    let first = a.children("today-work")[0].id.clone(); let last = a.children("today-work")[1].id.clone();
    replay(&mut a, |ws| ws.move_item("split-1", "today-work", 1, false).unwrap());
    assert_eq!(ids(&a, "today-work"), [first, "split-1".into(), last]);
    let mut ws = workspace(); let mut peer = ws.clone();
    ws.create_folder("a", "A", "pin-home", 0, &[]).unwrap(); peer.create_folder("b", "B", "pin-home", 0, &[]).unwrap();
    ws.apply(&Op::Put(Record::Item(peer.items["b"].clone())));
    replay(&mut ws, |ws| ws.create_folder("middle", "Middle", "pin-home", 1, &[]).unwrap());
    assert_eq!(ids(&ws, "pin-home"), ["a", "middle", "b"]);
}
#[test]
fn import_repair_ties_allow_a_drop_between_orphans() {
    let json = include_str!("fixtures/arc-sidebar-synthetic.json")
        .replace(r#""id": "tab-mail", "parentID": "fav-default""#, r#""id": "tab-mail", "parentID": "gone-1""#)
        .replace(r#""id": "tab-spec", "parentID": "folder-docs""#, r#""id": "tab-spec", "parentID": "gone-2""#);
    let mut ws = arc_sidebar(&json).unwrap();
    assert_eq!(ws.items["tab-spec"].membership.order, ws.items["tab-mail"].membership.order);
    replay(&mut ws, |ws| ws.move_item("split-1", "today-work", 1, false).unwrap());
    assert_eq!(ids(&ws, "today-work"), ["tab-mail", "split-1", "tab-spec"]);
}
#[test]
fn deleting_a_folder_in_a_tied_run_archives_tabs_without_rekeying_siblings() {
    let mut ws = workspace();
    for id in ["a", "b", "c", "d"] { ws.create_folder(id, id, "pin-home", ws.children("pin-home").len(), &[]).unwrap(); }
    ws.move_item("tab-spec", "b", 0, false).unwrap(); ws.move_item("tab-mail", "b", 1, false).unwrap();
    let order = ws.items["a"].membership.order.clone();
    for id in ["b", "c"] { ws.items.get_mut(id).unwrap().membership.order = order.clone(); }
    let next = ws.items["d"].clone(); let prior = ws.items["a"].clone();
    replay(&mut ws, |ws| ws.delete_folder("b").unwrap());
    assert_eq!(ws.outline("pin-home").iter().map(|(_, i)| i.id.as_str()).collect::<Vec<_>>(), ["a", "c", "d"]);
    for id in ["tab-spec", "tab-mail"] { assert_eq!(ws.items[id].lifecycle, Lifecycle::Archived); }
    assert_eq!(ws.items["d"], next); assert_eq!(ws.items["a"], prior);
    assert_eq!(ws.items["c"].membership.order, ws.items["a"].membership.order);
}
#[test]
fn reorder_retains_previous_parent_and_same_place_move_is_empty() {
    let mut ws = workspace(); ws.move_item("tab-spec", "pin-home", 0, false).unwrap(); ws.move_item("tab-mail", "pin-home", 1, false).unwrap();
    let previous = ws.items["tab-spec"].membership.previous_parent.clone();
    replay(&mut ws, |ws| ws.move_item("tab-spec", "pin-home", 1, false).unwrap());
    assert_eq!(ws.items["tab-spec"].membership.previous_parent, previous);
    let before = ws.clone(); assert!(ws.move_item("tab-spec", "pin-home", 1, false).unwrap().is_empty()); assert_eq!(ws, before);
}
#[test]
fn selecting_a_hidden_tab_expands_ancestors_locally_and_replays() {
    let mut ws = workspace(); ws.create_folder("outer", "Outer", "pin-work", 0, &[]).unwrap(); ws.move_item("folder-docs", "outer", 0, false).unwrap();
    ws.select_item("one", "tab-spec").unwrap(); ws.set_folder_collapsed("outer", true).unwrap(); ws.set_folder_collapsed("folder-docs", true).unwrap();
    let folder = ws.items["folder-docs"].clone(); let outer = ws.items["outer"].clone();
    let ops = replay(&mut ws, |ws| ws.select_item_at("one", "tab-spec", 100).unwrap());
    assert!(ws.is_selectable("tab-spec")); assert_eq!(ws.selected("one"), Some("tab-spec"));
    assert!(!ws.folder_collapsed["outer"] && !ws.folder_collapsed["folder-docs"]);
    assert_eq!(ws.items["folder-docs"], folder); assert_eq!(ws.items["outer"], outer);
    assert_eq!(ops.iter().filter(|op| matches!(op, Op::Put(Record::FolderState { .. }))).count(), 2);
}
#[test]
fn cross_profile_moves_and_wraps_are_atomic_errors() {
    let mut ws = arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json")).unwrap();
    let mut home = ws.items["tab-mail"].clone(); home.id = "home-tab".into(); home.membership.parent = Some("pin-home".into()); ws.apply(&Op::Put(Record::Item(home)));
    let before = ws.clone();
    for (id, target) in [("tab-spec", "pin-home"), ("tab-spec", "today-home"), ("home-tab", "fav-default"), ("folder-docs", "pin-home"), ("split-1", "pin-home")] {
        assert!(ws.move_item(id, target, 0, false).is_err()); assert_eq!(ws, before);
    }
    assert!(ws.create_folder("new", "New", "pin-home", 0, &["tab-spec".into()]).is_err()); assert_eq!(ws, before);
}
#[test]
fn unpinning_an_idle_tab_or_split_starts_a_fresh_today_period() {
    const H: u64 = 3_600_000;
    for id in ["tab-spec", "tab-mail", "split-1"] {
        let mut ws = workspace(); ws.stamp_selection(id, 1_000); let changed = ws.items[id].lifecycle_changed_at;
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64;
        let ops = replay(&mut ws, |ws| ws.move_item(id, "today-home", 0, false).unwrap());
        let tabs: Vec<_> = if id == "split-1" { vec!["tab-a", "tab-b"] } else { vec![id] };
        for tab in &tabs { assert!(ws.last_selected[*tab] >= now); }
        assert_eq!(ws.items[id].lifecycle_changed_at, changed);
        assert!(ops.iter().any(|op| matches!(op, Op::Put(Record::LastSelected { .. }))));
        ws.auto_archive(now + 1).unwrap(); for tab in tabs { assert_eq!(ws.items[tab].lifecycle, Lifecycle::Open); }
        assert!(now > 1_000 + 12 * H + 1);
    }
}

#[test]
fn unpin_uses_the_supplied_time_and_today_reorders_preserve_it() {
    const H: u64 = 3_600_000;
    for id in ["tab-spec", "tab-mail", "split-1"] {
        let mut ws = workspace(); ws.stamp_selection(id, 1_000);
        let now = 1_000 + 12 * H + 1;
        replay(&mut ws, |ws| ws.move_item_at(id, "today-home", 0, false, now).unwrap());
        let tabs = if id == "split-1" { vec!["tab-a", "tab-b"] } else { vec![id] };
        for tab in &tabs { assert_eq!(ws.last_selected[*tab], now); }
        ws.auto_archive(now + 1).unwrap(); for tab in &tabs { assert_eq!(ws.items[*tab].lifecycle, Lifecycle::Open); }
        ws.move_item_at(id, "today-work", 0, false, now + 100).unwrap();
        for tab in &tabs { assert_eq!(ws.last_selected[*tab], now); }
        ws.auto_archive(now + 12 * H).unwrap(); for tab in &tabs { assert_eq!(ws.items[*tab].lifecycle, Lifecycle::Open); }
        ws.auto_archive(now + 12 * H + 1).unwrap(); for tab in &tabs { assert_eq!(ws.items[*tab].lifecycle, Lifecycle::Archived); }
    }
}

#[test]
fn a_tied_suffix_rekeys_only_that_run_and_keeps_membership_history() {
    let mut ws = workspace();
    for id in ["a", "b", "c", "d"] { ws.create_folder(id, id, "pin-home", ws.children("pin-home").len(), &[]).unwrap(); }
    let key = ws.items["a"].membership.order.clone();
    for id in ["b", "c"] { ws.items.get_mut(id).unwrap().membership.order = key.clone(); }
    let before = ws.clone();
    let ops = replay(&mut ws, |ws| ws.move_item("tab-mail", "pin-home", 1, false).unwrap());
    assert_eq!(ids(&ws, "pin-home"), ["a", "tab-mail", "b", "c", "d"]);
    assert_eq!(ws.items["a"], before.items["a"]); assert_eq!(ws.items["d"], before.items["d"]);
    assert_eq!(ops.len(), 3);
    for id in ["b", "c"] {
        let mut expected = before.items[id].clone(); expected.membership.order = ws.items[id].membership.order.clone();
        assert_eq!(ws.items[id], expected);
    }
}
