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
    let ops = ws.clear_today("space-work").unwrap();
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
    let ops = ws.clear_today("space-work").unwrap();
    let mut peer = base;
    for op in &ops { peer.apply(op); }
    assert_eq!(peer, ws);
    let before = ws.clone();
    assert!(ws.clear_today("space-work").unwrap().is_empty());
    assert_eq!(ws, before);
    assert!(ws.clear_today("missing").is_err());
    assert_eq!(ws, before);
}

#[test]
fn clearing_today_archives_a_splits_members_once() {
    let mut ws = workspace();
    ws.move_item("split-1", "today-work", 0, false).unwrap();
    let ops = ws.clear_today("space-work").unwrap();
    for id in ["split-1", "tab-a", "tab-b"] {
        assert_eq!(ws.items[id].lifecycle, Lifecycle::Archived, "{id}");
    }
    let mut batch = archived(&ops);
    batch.sort();
    assert_eq!(batch, ["a", "b", "split-1", "tab-a", "tab-b"]);
}
