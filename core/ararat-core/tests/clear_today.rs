use std::collections::HashSet;

use ararat_core::import::arc_sidebar;
use ararat_core::model::{Item, ItemKind, Lifecycle, Membership, Op, Record, WindowState, Workspace};

fn add(ws: &mut Workspace, id: &str, parent: &str, order: &str, kind: ItemKind) {
    ws.items.insert(id.into(), Item {
        id: id.into(), membership: Membership { parent: Some(parent.into()), order: order.into(), hlc: Default::default(), previous_parent: None },
        title: None, kind, lifecycle: Lifecycle::Open, lifecycle_changed_at: 0,
    });
}

fn workspace() -> Workspace {
    let mut ws = arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json"), None, None, None, None).unwrap().0;
    // today-work is empty in the fixture; add a loaded and an unloaded tab and select the latter.
    add(&mut ws, "a", "today-work", "a0", ItemKind::Tab { url: "https://a.example".into(), saved_title: None });
    add(&mut ws, "b", "today-work", "b0", ItemKind::Tab { url: "https://b.example".into(), saved_title: None });
    ws.items.get_mut("b").unwrap().lifecycle = Lifecycle::Unloaded;
    ws.windows.insert("one".into(), WindowState {
        id: "one".into(), shown_space: Some("space-work".into()), selected: Some("b".into()),
        history: vec!["b".into()], space_history: vec![], changed_at: 0,
    });
    ws
}

fn archived(ops: &[Op]) -> Vec<&str> {
    ops.iter().filter_map(|op| match op {
        Op::Put(Record::Item(item)) if item.lifecycle == Lifecycle::Archived => Some(item.id.as_str()),
        _ => None,
    }).collect()
}

#[test]
fn clearing_today_archives_every_row_in_one_batch_and_keeps_the_other_lists() {
    let mut ws = workspace();
    let pins: Vec<_> = ws.outline("pin-work").into_iter().map(|(_, item)| (item.id.clone(), item.lifecycle)).collect();
    let favourite = ws.items["tab-mail"].clone();
    let (ops, _) = ws.clear_today("space-work").unwrap();
    for id in ["a", "b"] {
        assert_eq!(ws.items[id].lifecycle, Lifecycle::Archived, "{id}");
    }
    // One action: every archived row carries the same instant and all of them ride the one
    // batch the caller writes as a single transaction (the undo unit).
    let stamps: HashSet<u64> = ["a", "b"].iter().map(|id| ws.items[*id].lifecycle_changed_at).collect();
    assert_eq!(stamps.len(), 1);
    let mut batch = archived(&ops);
    batch.sort();
    assert_eq!(batch, ["a", "b"]);
    // Pins and the profile's favourites keep their tabs.
    for (id, lifecycle) in pins {
        assert_eq!(ws.items[&id].lifecycle, lifecycle, "{id}");
    }
    assert_eq!(ws.items["tab-mail"], favourite);
    // The window leaves the rows that went to the Archive.
    assert!(ws.selected("one").is_none_or(|id| !["a", "b"].contains(&id)));
    ws.check_tree().unwrap();
}

#[test]
fn clearing_today_replays_on_a_peer_and_a_second_clear_writes_nothing() {
    let base = workspace();
    let mut ws = base.clone();
    let (ops, _) = ws.clear_today("space-work").unwrap();
    let mut peer = base;
    for op in &ops { peer.apply(op); }
    assert_eq!(peer, ws);
    let before = ws.clone();
    assert!(ws.clear_today("space-work").unwrap().0.is_empty());
    assert_eq!(ws, before);
    assert!(ws.clear_today("missing").is_err());
    assert_eq!(ws, before);
}

#[test]
fn clearing_today_archives_a_splits_members_once() {
    let mut ws = workspace();
    ws.move_item("split-1", "today-work", 0, false).unwrap();
    let (ops, _) = ws.clear_today("space-work").unwrap();
    for id in ["split-1", "tab-a", "tab-b"] {
        assert_eq!(ws.items[id].lifecycle, Lifecycle::Archived, "{id}");
    }
    let mut batch = archived(&ops);
    batch.sort();
    assert_eq!(batch, ["a", "b", "split-1", "tab-a", "tab-b"]);
}

#[test]
fn undo_keeps_order_folder_and_split_and_skips_changed_rows() {
    let mut ws = workspace();
    add(&mut ws, "folder", "today-work", "c0", ItemKind::Folder);
    add(&mut ws, "nested", "folder", "a0", ItemKind::Tab { url: "https://nested.example".into(), saved_title: None });
    ws.move_item("split-1", "today-work", 0, false).unwrap();
    let before: Vec<_> = ["a", "b", "nested", "split-1", "tab-a", "tab-b"].iter()
        .map(|id| ((*id).to_string(), ws.items[*id].membership.clone())).collect();
    let (_, batch) = ws.clear_today("space-work").unwrap();
    ws.restore_item("one", "a").unwrap();
    let restored = ws.items["a"].clone();
    ws.undo_clear_today("one", &batch, Some("b")).unwrap();
    assert_eq!(ws.items["a"], restored);
    for (id, membership) in before.into_iter().filter(|(id, _)| id != "a") {
        assert_eq!(ws.items[&id].membership, membership, "{id}");
        assert_eq!(ws.items[&id].lifecycle, Lifecycle::Unloaded, "{id}");
    }
    assert_eq!(ws.selected("one"), Some("b"));
    ws.check_tree().unwrap();
}

#[test]
fn undo_of_second_clear_does_not_restore_the_first_batch() {
    let mut ws = workspace();
    let (_, first) = ws.clear_today("space-work").unwrap();
    add(&mut ws, "later", "today-work", "z0", ItemKind::Tab { url: "https://later.example".into(), saved_title: None });
    let (_, second) = ws.clear_today("space-work").unwrap();
    ws.undo_clear_today("one", &second, None).unwrap();
    assert_eq!(ws.items["later"].lifecycle, Lifecycle::Unloaded);
    assert_eq!(ws.items["a"].lifecycle, Lifecycle::Archived);
    assert_ne!(first.changed_at, second.changed_at);
}

#[test]
fn undo_replays_and_is_idempotent_with_a_selected_split_member() {
    let mut ws = workspace();
    ws.move_item("split-1", "today-work", 0, false).unwrap();
    ws.select_item("one", "tab-b").unwrap();
    let (_, batch) = ws.clear_today("space-work").unwrap();
    let mut peer = ws.clone();
    let ops = ws.undo_clear_today("one", &batch, Some("tab-b")).unwrap();
    for op in &ops { peer.apply(op); }
    assert_eq!(peer, ws);
    assert_eq!(ws.selected("one"), Some("tab-b"));
    assert!(ws.undo_clear_today("one", &batch, Some("tab-b")).unwrap().is_empty());
}

#[test]
fn undo_skips_split_members_when_the_split_changed() {
    let mut ws = workspace();
    ws.move_item("split-1", "today-work", 0, false).unwrap();
    let (_, batch) = ws.clear_today("space-work").unwrap();
    ws.items.get_mut("split-1").unwrap().title = Some("changed".into());
    ws.undo_clear_today("one", &batch, Some("tab-b")).unwrap();
    for id in ["split-1", "tab-a", "tab-b"] { assert_eq!(ws.items[id].lifecycle, Lifecycle::Archived); }
    assert_ne!(ws.selected("one"), Some("tab-b"));
}
