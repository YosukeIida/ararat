use ararat_core::{import::arc_sidebar, model::{ItemKind, Kind, Lifecycle, Op, Record, Workspace}, storage::Store};
fn workspace() -> Workspace { arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json")).unwrap() }
fn synced(ws: &Workspace) -> Workspace {
    let mut result = Workspace::default();
    for op in ws.to_ops().into_iter().filter(|op| matches!(op, Op::Put(r) if !matches!(r.kind(), Kind::Window | Kind::LastSelected | Kind::FolderState))) { result.apply(&op); }
    result
}
#[test]
fn empty_folder_and_nested_empty_folders_are_removed_with_local_state() {
    let mut ws = workspace(); ws.create_folder("empty", "Empty", "pin-work", 0, &[]).unwrap(); ws.create_folder("nested", "Nested", "empty", 0, &[]).unwrap();
    for id in ["empty", "nested"] { ws.set_folder_collapsed(id, true).unwrap(); }
    let mut replay = ws.clone(); let ops = ws.delete_folder("empty").unwrap();
    for op in &ops { replay.apply(op); } assert_eq!(replay, ws);
    for id in ["empty", "nested"] { assert!(!ws.items.contains_key(id)); assert!(!ws.folder_collapsed.contains_key(id)); }
    assert!(!ops.iter().any(|op| matches!(op, Op::Put(Record::Item(_))))); ws.check_tree().unwrap();
}
#[test]
fn deleting_nested_tabs_and_splits_archives_active_items_and_preserves_inactive_times() {
    let mut ws = workspace();
    ws.create_folder("outer", "Outer", "pin-work", 0, &[]).unwrap();
    ws.move_item("folder-docs", "outer", 0).unwrap(); ws.move_item("split-1", "folder-docs", 1).unwrap();
    let mut archived = ws.items["tab-spec"].clone(); archived.id = "already-archived".into(); archived.lifecycle = Lifecycle::Archived; archived.lifecycle_changed_at = 17; ws.apply(&Op::Put(Record::Item(archived)));
    let mut closed = ws.items["tab-spec"].clone(); closed.id = "already-closed".into(); closed.lifecycle = Lifecycle::Closed; closed.lifecycle_changed_at = 19; ws.apply(&Op::Put(Record::Item(closed)));
    ws.items.get_mut("tab-b").unwrap().lifecycle = Lifecycle::Unloaded;
    for id in ["outer", "folder-docs"] { ws.set_folder_collapsed(id, true).unwrap(); }
    let archive_before: Vec<_> = ws.archive().iter().map(|i| i.id.clone()).collect();
    let mut replay = ws.clone(); let ops = ws.delete_folder("outer").unwrap();
    for op in &ops { replay.apply(op); } assert_eq!(replay, ws);
    for id in ["outer", "folder-docs"] { assert!(!ws.items.contains_key(id)); assert!(!ws.folder_collapsed.contains_key(id)); }
    let time = ws.items["tab-spec"].lifecycle_changed_at; assert!(time > 19);
    for id in ["tab-spec", "split-1", "tab-a", "tab-b"] { assert_eq!(ws.items[id].lifecycle, Lifecycle::Archived); assert_eq!(ws.items[id].lifecycle_changed_at, time); }
    for (id, lifecycle, time) in [("already-archived", Lifecycle::Archived, 17), ("already-closed", Lifecycle::Closed, 19)] { assert_eq!(ws.items[id].lifecycle, lifecycle); assert_eq!(ws.items[id].lifecycle_changed_at, time); }
    assert_eq!(ws.archive().iter().filter(|i| archive_before.contains(&i.id)).map(|i| i.id.clone()).collect::<Vec<_>>(), archive_before);
    for id in ["tab-spec", "split-1", "already-archived", "already-closed"] {
        assert_eq!(ws.items[id].membership.parent.as_deref(), Some("pin-work"));
        assert_eq!(ws.items[id].membership.previous_parent.as_deref(), Some("folder-docs"));
    }
    for id in ["tab-a", "tab-b"] { assert_eq!(ws.items[id].membership.parent.as_deref(), Some("split-1")); }
    assert!(ws.outline("pin-work").is_empty()); ws.check_tree().unwrap();
    ws.restore_item("one", "tab-spec").unwrap(); assert_eq!(ws.items["tab-spec"].membership.parent.as_deref(), Some("today-work")); assert_eq!(ws.children("today-work")[0].id, "tab-spec");
}
#[test]
fn deleting_a_selected_folder_tab_uses_the_archive_successor_and_history() {
    let mut ws = workspace();
    ws.select_item_at("one", "tab-mail", 10).unwrap(); ws.select_item_at("one", "tab-spec", 20).unwrap();
    let mut expected = ws.clone(); expected.archive_item("tab-spec").unwrap();
    ws.delete_folder("folder-docs").unwrap();
    assert_eq!(ws.selected("one"), expected.selected("one")); assert_eq!(ws.windows, expected.windows);
    assert_eq!(ws.selected("one"), Some("tab-mail")); assert!(!ws.windows["one"].history.iter().any(|id| id == "tab-spec"));
}
#[test]
fn deletion_and_restore_persist_and_the_journal_replays_the_synced_state() {
    let path = std::env::temp_dir().join(format!("ararat-folder-delete-{}.sqlite", std::process::id())); assert!(!path.exists());
    let mut ws = workspace(); ws.move_item("split-1", "folder-docs", 1).unwrap(); ws.set_folder_collapsed("folder-docs", true).unwrap();
    let (store, _) = Store::open(&path).unwrap(); store.write(ws.to_ops()); store.flush().unwrap();
    let mut copy = ws.clone(); let ops = ws.delete_folder("folder-docs").unwrap(); for op in &ops { copy.apply(op); } assert_eq!(copy, ws);
    store.write(ops); store.flush().unwrap(); assert_eq!(Store::open(&path).unwrap().1, ws);
    let conn = rusqlite::Connection::open(&path).unwrap(); let mut replay = Workspace::default();
    let rows: Vec<(String, String, Option<String>)> = conn.prepare("SELECT kind,id,body FROM journal ORDER BY seq").unwrap().query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap().map(Result::unwrap).collect();
    for (kind, id, body) in rows { let kind = Kind::parse(&kind).unwrap(); replay.apply(&match body { Some(body) => Op::Put(Record::parse(kind, &id, &body).unwrap()), None => Op::Delete(kind, id) }); }
    assert_eq!(replay, synced(&ws)); assert!(!replay.items.values().any(|i| matches!(i.kind, ItemKind::Folder)));
    store.write(ws.restore_item("one", "tab-a").unwrap()); store.flush().unwrap(); assert_eq!(Store::open(&path).unwrap().1, ws);
    assert_eq!(ws.items["tab-a"].membership.parent.as_deref(), Some("today-work")); drop(conn); drop(store);
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
}

#[test]
fn inactive_only_folders_are_removed_without_rearchiving_their_tabs() {
    let mut ws = workspace(); ws.archive_item("tab-spec").unwrap();
    ws.set_folder_collapsed("folder-docs", true).unwrap(); let tab = ws.items["tab-spec"].clone();
    let ops = ws.delete_folder("folder-docs").unwrap();
    assert!(!ws.items.contains_key("folder-docs")); assert!(!ws.folder_collapsed.contains_key("folder-docs"));
    assert_eq!(ws.items["tab-spec"].lifecycle, tab.lifecycle); assert_eq!(ws.items["tab-spec"].lifecycle_changed_at, tab.lifecycle_changed_at);
    assert_eq!(ws.items["tab-spec"].membership.parent.as_deref(), Some("pin-work"));
    assert!(!ops.iter().any(|op| matches!(op, Op::Put(Record::Window(_) | Record::LastSelected { .. })))); ws.check_tree().unwrap();
}
