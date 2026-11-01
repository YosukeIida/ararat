use ararat_core::import::arc_sidebar;
use ararat_core::model::{Item, ItemKind, Lifecycle, Membership, Orientation, WindowState, Workspace};
use ararat_core::storage::Store;

fn set_selection(ws: &mut Workspace, id: &str) {
    ws.windows.insert("test".into(), WindowState { id: "test".into(), shown_space: ws.spaces.first().map(|space| space.id.clone()), selected: Some(id.into()), history: vec![] });
}

fn workspace() -> Workspace {
    let mut ws = arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json")).unwrap();
    for (id, order) in [("a", "a"), ("b", "b"), ("c", "c")] {
        add(&mut ws, id, "today-work", order, ItemKind::Tab { url: format!("https://{id}.example"), saved_title: None });
    }
    set_selection(&mut ws, "b");
    ws
}

fn add(ws: &mut Workspace, id: &str, parent: &str, order: &str, kind: ItemKind) {
    ws.items.insert(id.into(), Item {
        id: id.into(), membership: Membership { parent: Some(parent.into()), order: order.into(), hlc: Default::default(), previous_parent: None },
        title: None, kind, lifecycle: Lifecycle::Open, lifecycle_changed_at: 0, collapsed: false,
    });
}

#[test]
fn selected_middle_uses_next_visible_tab_below() {
    let mut ws = workspace();
    let mut replay = ws.clone();
    let ops = ws.close_item("b").unwrap();
    assert_eq!(ops.len(), 2);
    for op in &ops { replay.apply(op); }
    assert_eq!(replay, ws);
    assert_eq!(ws.selected("test"), Some("c"));
    assert_eq!(ws.items["b"].lifecycle, Lifecycle::Closed);
    assert!(!ws.outline("today-work").iter().any(|(_, i)| i.id == "b"));
}

#[test]
fn selected_last_uses_visible_tab_above() {
    let mut ws = workspace(); set_selection(&mut ws, "c");
    ws.close_item("c").unwrap();
    assert_eq!(ws.selected("test"), Some("b"));
}

#[test]
fn selected_only_tab_clears_selection() {
    let mut ws = workspace(); ws.items.remove("a"); ws.items.remove("c");
    ws.close_item("b").unwrap();
    assert_eq!(ws.selected("test"), None);
}

#[test]
fn successor_skips_tabs_inside_collapsed_folders() {
    let mut ws = workspace();
    add(&mut ws, "folder", "today-work", "ba", ItemKind::Folder);
    ws.items.get_mut("folder").unwrap().collapsed = true;
    ws.items.get_mut("c").unwrap().membership.parent = Some("folder".into());
    ws.close_item("b").unwrap();
    assert_eq!(ws.selected("test"), Some("a"));
}

#[test]
fn successor_skips_unloaded_tabs() {
    let mut ws = workspace(); ws.items.get_mut("c").unwrap().lifecycle = Lifecycle::Unloaded;
    ws.close_item("b").unwrap();
    assert_eq!(ws.selected("test"), Some("a"));
}

#[test]
fn successor_selects_a_split_as_a_group() {
    let mut ws = workspace();
    add(&mut ws, "split", "today-work", "ba", ItemKind::Split { orientation: Orientation::Horizontal, width_factors: vec![] });
    ws.items.get_mut("c").unwrap().membership.parent = Some("split".into());
    ws.close_item("b").unwrap();
    assert_eq!(ws.selected("test"), Some("split"));
}

#[test]
fn closing_an_unselected_tab_keeps_selection() {
    let mut ws = workspace();
    assert_eq!(ws.close_item("a").unwrap().len(), 1);
    assert_eq!(ws.selected("test"), Some("b"));
}

#[test]
fn rejected_closes_do_not_change_the_workspace() {
    let mut ws = workspace();
    for id in ["missing", "folder-docs", "today-work"] {
        let before = ws.clone();
        assert!(ws.close_item(id).is_err()); assert_eq!(ws, before);
    }
    ws.close_item("b").unwrap();
    let before = ws.clone();
    assert!(ws.close_item("b").is_err()); assert_eq!(ws, before);
}

#[test]
fn lifecycle_and_successor_persist_together_across_reopening() {
    let path = std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("close-lifecycle.sqlite");
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
    let mut ws = workspace();
    let (store, _) = Store::open(&path).unwrap(); store.write(ws.to_ops()); store.flush().unwrap();
    store.write(ws.close_item("b").unwrap()); store.flush().unwrap(); drop(store);
    let (_, reopened) = Store::open(&path).unwrap();
    assert_eq!(reopened, ws); assert_eq!(reopened.items["b"].lifecycle, Lifecycle::Closed);
    assert_eq!(reopened.selected("test"), Some("c"));
}

fn split_workspace() -> Workspace {
    let mut ws = workspace();
    add(&mut ws, "split", "today-work", "b", ItemKind::Split { orientation: Orientation::Horizontal, width_factors: vec![] });
    for id in ["b", "c"] { ws.items.get_mut(id).unwrap().membership.parent = Some("split".into()); }
    add(&mut ws, "d", "today-work", "d", ItemKind::Tab { url: "https://d.example".into(), saved_title: None });
    set_selection(&mut ws, "split");
    ws
}

#[test]
fn closing_a_selected_split_closes_all_members_and_selects_past_it() {
    let mut ws = split_workspace();
    let mut replay = ws.clone();
    let ops = ws.close_item("split").unwrap();
    assert_eq!(ops.len(), 4);
    for op in &ops { replay.apply(op); }
    assert_eq!(replay, ws);
    for id in ["split", "b", "c"] { assert_eq!(ws.items[id].lifecycle, Lifecycle::Closed); }
    assert_eq!(ws.selected("test"), Some("d"));
    assert_eq!(ws.outline("today-work").iter().map(|(_, i)| i.id.as_str()).collect::<Vec<_>>(), ["a", "d"]);
}

#[test]
fn members_closed_in_either_order_close_the_empty_split_and_persist() {
    for (index, order) in [["b", "c"], ["c", "b"]].into_iter().enumerate() {
        let mut ws = split_workspace();
        let path = std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(format!("close-split-order-{index}.sqlite"));
        for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
        let (store, _) = Store::open(&path).unwrap(); store.write(ws.to_ops());
        store.write(ws.close_item(order[0]).unwrap());
        assert_eq!(ws.items["split"].lifecycle, Lifecycle::Open);
        assert_eq!(ws.selected("test"), Some("split"));
        store.write(ws.close_item(order[1]).unwrap()); store.flush().unwrap(); drop(store);
        assert_eq!(ws.items["split"].lifecycle, Lifecycle::Closed);
        assert_eq!(ws.selected("test"), Some("d"));
        let (_, reopened) = Store::open(&path).unwrap();
        assert_eq!(reopened, ws);
        assert!(!reopened.outline("today-work").iter().any(|(_, item)| item.id == "split"));
    }
}

#[test]
fn closing_a_split_containing_the_selected_member_selects_past_the_group() {
    let mut ws = split_workspace(); set_selection(&mut ws, "b");
    ws.close_item("split").unwrap();
    assert_eq!(ws.selected("test"), Some("d"));
}

#[test]
fn closing_the_only_split_clears_selection() {
    let mut ws = split_workspace(); ws.items.remove("a"); ws.items.remove("d");
    ws.close_item("split").unwrap();
    assert_eq!(ws.selected("test"), None);
    assert!(ws.outline("today-work").is_empty());
}

#[test]
fn selection_rejects_folders_hidden_tabs_and_empty_splits() {
    let mut ws = split_workspace();
    for id in ["folder-docs", "pin-work", "unknown"] {
        let before = ws.clone(); assert!(ws.select_item("test", id).is_err()); assert_eq!(ws, before);
    }
    ws.items.get_mut("folder-docs").unwrap().collapsed = true;
    let before = ws.clone(); assert!(ws.select_item("test", "tab-spec").is_err()); assert_eq!(ws, before);
    ws.items.get_mut("b").unwrap().lifecycle = Lifecycle::Closed;
    ws.items.get_mut("c").unwrap().lifecycle = Lifecycle::Archived;
    let before = ws.clone(); assert!(ws.select_item("test", "split").is_err()); assert_eq!(ws, before);
    assert!(!ws.outline("today-work").iter().any(|(_, item)| item.id == "split"));
}

#[test]
fn a_split_with_an_unloaded_member_stays_open_until_that_member_closes() {
    let mut ws = split_workspace(); ws.items.get_mut("c").unwrap().lifecycle = Lifecycle::Unloaded;
    ws.close_item("b").unwrap();
    assert_eq!(ws.items["split"].lifecycle, Lifecycle::Open);
    ws.close_item("c").unwrap();
    assert_eq!(ws.items["split"].lifecycle, Lifecycle::Closed);
    assert_eq!(ws.selected("test"), Some("d"));
}
