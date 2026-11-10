use ararat_core::{import::arc_sidebar, model::{Kind, Lifecycle, Op, Record, Workspace}, storage::Store};
fn workspace() -> Workspace {
    let mut ws = arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json"), None, None, None, None).unwrap().0;
    ws.spaces[1].profile = ararat_core::model::Profile::Default;
    ws
}
fn children(ws: &Workspace, parent: &str) -> Vec<String> { ws.children(parent).iter().map(|i| i.id.clone()).collect() }
fn edit(ws: &mut Workspace, f: impl FnOnce(&mut Workspace) -> Vec<Op>) -> Vec<Op> {
    let mut replay = ws.clone(); let ops = f(ws);
    for op in &ops { replay.apply(op); }
    assert_eq!(*ws, replay); ws.check_tree().unwrap(); ops
}
fn refused(ws: &mut Workspace, f: impl FnOnce(&mut Workspace) -> Result<Vec<Op>, ararat_core::edit::EditError>) {
    let before = ws.clone(); assert!(f(ws).is_err()); assert_eq!(*ws, before);
}
#[test]
fn creates_favorites_once_and_moves_tabs_back() {
    let mut ws = workspace();
    let profile = ws.spaces[0].profile.clone();
    let old = ws.favorites.remove(&profile).unwrap();
    ws.items.remove(&old);
    for item in ws.items.values_mut().filter(|item| item.membership.parent.as_deref() == Some(&old)) {
        item.membership.parent = Some("today-work".into());
    }
    let ops = edit(&mut ws, |ws| ws.ensure_favorites("space-work", "new-favorites").unwrap());
    assert_eq!(ops.len(), 2);
    assert!(ws.ensure_favorites("space-work", "another").unwrap().is_empty());
    ws.move_item("tab-spec", "new-favorites", 0, false).unwrap();
    ws.move_item("tab-spec", "pin-work", 0, false).unwrap();
    assert_eq!(ws.items["tab-spec"].membership.parent.as_deref(), Some("pin-work"));
}
#[test]
fn moves_pin_unpin_favorite_cross_space_and_reorder_at_both_ends() {
    let mut ws = workspace(); ws.select_item_at("window", "tab-spec", 42).unwrap();
    let windows = ws.windows.clone(); let changed_at = ws.items["tab-spec"].lifecycle_changed_at;
    for (parent, index) in [("today-work", 0), ("pin-work", 2), ("pin-work", 0), ("fav-default", 1), ("fav-default", 0), ("today-home", 0), ("pin-home", 0), ("folder-docs", 0)] {
        let old_parent = ws.items["tab-spec"].membership.parent.clone();
        let previous = ws.items["tab-spec"].membership.previous_parent.clone();
        edit(&mut ws, |ws| ws.move_item("tab-spec", parent, index, false).unwrap());
        assert_eq!(ws.items["tab-spec"].membership.parent.as_deref(), Some(parent));
        assert_eq!(ws.items["tab-spec"].membership.previous_parent, if old_parent.as_deref() == Some(parent) { previous } else { old_parent });
        assert_eq!(children(&ws, parent)[index], "tab-spec"); assert_eq!(ws.items["tab-spec"].lifecycle_changed_at, changed_at);
        assert_eq!(ws.windows, windows);
    }
    ws.items.get_mut("tab-mail").unwrap().lifecycle = Lifecycle::Unloaded;
    ws.move_item("tab-mail", "today-home", 0, false).unwrap(); assert_eq!(ws.items["tab-mail"].lifecycle, Lifecycle::Unloaded);
}
#[test]
fn folders_move_with_subtrees_and_splits_move_as_one_even_from_a_member() {
    let mut ws = workspace(); ws.create_folder("outer", "Outer", "pin-home", 0, &[]).unwrap();
    let child = ws.items["tab-spec"].clone();
    edit(&mut ws, |ws| ws.move_item("folder-docs", "outer", 0, false).unwrap()); assert_eq!(ws.items["tab-spec"], child);
    edit(&mut ws, |ws| ws.move_item("tab-spec", "pin-work", 0, false).unwrap()); ws.move_item("tab-spec", "folder-docs", 0, false).unwrap();
    edit(&mut ws, |ws| ws.move_item("folder-docs", "pin-work", 1, false).unwrap());
    ws.select_item("window", "tab-a").unwrap(); let members = [ws.items["tab-a"].clone(), ws.items["tab-b"].clone()];
    edit(&mut ws, |ws| ws.move_item("tab-a", "today-home", 0, false).unwrap());
    assert_eq!(children(&ws, "today-home"), ["split-1"]); assert_eq!([ws.items["tab-a"].clone(), ws.items["tab-b"].clone()], members);
    assert_eq!(ws.selected("window"), Some("tab-a")); edit(&mut ws, |ws| ws.move_item("split-1", "pin-work", 0, false).unwrap());
}
#[test]
fn rejected_moves_and_folder_edits_are_atomic() {
    let mut ws = workspace(); ws.create_folder("inner", "Inner", "folder-docs", 1, &[]).unwrap();
    for (id, parent, index) in [("folder-docs", "inner", 0), ("folder-docs", "folder-docs", 0), ("folder-docs", "today-work", 0), ("folder-docs", "fav-default", 0), ("split-1", "fav-default", 0), ("tab-a", "fav-default", 0), ("tab-mail", "tab-spec", 0), ("pin-work", "pin-home", 0), ("tab-mail", "missing", 0), ("missing", "pin-home", 0), ("tab-mail", "pin-home", 1), ("tab-mail", "split-1", 0)] { refused(&mut ws, |ws| ws.move_item(id, parent, index, false)); }
    for lifecycle in [Lifecycle::Closed, Lifecycle::Archived] { ws.items.get_mut("tab-mail").unwrap().lifecycle = lifecycle; refused(&mut ws, |ws| ws.move_item("tab-mail", "pin-home", 0, false)); }
    for parent in ["today-work", "fav-default", "missing", "tab-spec"] { refused(&mut ws, |ws| ws.create_folder("new", "New", parent, 0, &[])); }
    refused(&mut ws, |ws| ws.create_folder("folder-docs", "New", "pin-home", 0, &[])); refused(&mut ws, |ws| ws.create_folder("new", " \n", "pin-home", 0, &[]));
    refused(&mut ws, |ws| ws.rename_folder("folder-docs", " \n")); refused(&mut ws, |ws| ws.rename_folder("tab-a", "No"));
    refused(&mut ws, |ws| ws.rename_tab("folder-docs", "No")); refused(&mut ws, |ws| ws.delete_folder("tab-a")); refused(&mut ws, |ws| ws.set_folder_collapsed("tab-a", true));
}
#[test]
fn creates_wraps_and_renames_folders_at_any_depth_in_order() {
    let mut ws = workspace(); edit(&mut ws, |ws| ws.create_folder("outer", " Outer ", "pin-work", 1, &[]).unwrap()); assert_eq!(ws.items["outer"].display_title(), "Outer");
    edit(&mut ws, |ws| ws.create_folder("wrap", "Wrapped", "pin-work", 0, &["split-1".into(), "folder-docs".into()]).unwrap()); assert_eq!(children(&ws, "wrap"), ["folder-docs", "split-1"]);
    ws.move_item("wrap", "outer", 0, false).unwrap(); edit(&mut ws, |ws| ws.rename_folder("wrap", " Renamed ").unwrap()); assert_eq!(ws.items["wrap"].display_title(), "Renamed");
    assert_eq!(children(&ws, "wrap"), ["folder-docs", "split-1"]);
}
#[test]
fn rename_custom_title_and_clear_to_page_title() {
    let mut ws = workspace(); edit(&mut ws, |ws| ws.rename_tab("tab-spec", " Custom ").unwrap()); assert_eq!(ws.items["tab-spec"].display_title(), "Custom");
    for title in ["", " \n\u{3000}"] { ws.rename_tab("tab-spec", "Again").unwrap(); edit(&mut ws, |ws| ws.rename_tab("tab-spec", title).unwrap()); assert_eq!(ws.items["tab-spec"].display_title(), "Spec"); }
}
#[test]
fn all_edits_persist_and_journal_replays_only_synced_state() {
    let path = std::env::temp_dir().join(format!("ararat-item-moves-{}.sqlite", std::process::id())); assert!(!path.exists());
    let (store, _) = Store::open(&path).unwrap(); let mut ws = workspace(); store.write(ws.to_ops()); let base_count = ws.to_ops().len();
    let mut ops = ws.create_folder("new", "New", "pin-work", 0, &[]).unwrap(); ops.extend(ws.move_item("tab-mail", "new", 0, false).unwrap()); ops.extend(ws.rename_tab("tab-mail", "Renamed").unwrap()); ops.extend(ws.rename_folder("new", "Folder").unwrap()); ops.extend(ws.set_folder_collapsed("new", true).unwrap()); ops.extend(ws.delete_folder("folder-docs").unwrap());
    let edits_count = ops.iter().filter(|op| !matches!(op, Op::Put(Record::FolderState { .. } | Record::HistoryPurge { .. } | Record::HistoryProfile { .. }))).count(); store.write(ops); store.flush().unwrap(); drop(store);
    let (store, reopened) = Store::open(&path).unwrap(); assert_eq!(reopened, ws); drop(store);
    let conn = rusqlite::Connection::open(&path).unwrap();
    let rows: Vec<(String, String, Option<String>)> = conn.prepare("SELECT kind,id,body FROM journal ORDER BY seq").unwrap().query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap().map(Result::unwrap).collect(); assert_eq!(rows.len(), base_count + edits_count);
    let mut synced = Workspace::default(); for (kind, id, body) in rows { let kind = Kind::parse(&kind).unwrap(); assert!(!matches!(kind, Kind::Window | Kind::LastSelected | Kind::FolderState)); synced.apply(&match body { Some(body) => Op::Put(Record::parse(kind, &id, &body).unwrap()), None => Op::Delete(kind, id) }); }
    ws.folder_collapsed.clear(); ws.history_purges.clear(); ws.history_profiles.clear(); assert_eq!(synced, ws); drop(conn);
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
}
#[test]
fn legacy_collapsed_field_is_ignored_and_never_written_back() {
    let item = workspace().items["folder-docs"].clone(); let mut value = serde_json::to_value(&item).unwrap(); value["collapsed"] = true.into();
    let record = Record::parse(Kind::Item, &item.id, &value.to_string()).unwrap(); let mut ws = Workspace::default(); ws.apply(&Op::Put(record.clone())); assert!(ws.folder_collapsed.is_empty()); assert!(serde_json::from_str::<serde_json::Value>(&record.body()).unwrap().get("collapsed").is_none());
}

#[test]
fn wraps_multiple_parents_in_pinned_then_today_outline_order() {
    let mut ws = workspace(); ws.move_item("tab-mail", "today-work", 0, false).unwrap();
    edit(&mut ws, |ws| ws.create_folder("wrap", "Wrap", "pin-work", 1, &["tab-mail".into(), "tab-b".into(), "tab-spec".into(), "tab-a".into()]).unwrap());
    assert_eq!(children(&ws, "wrap"), ["tab-spec", "split-1", "tab-mail"]);
    assert_eq!(ws.items["tab-a"].membership.parent.as_deref(), Some("split-1"));
}
#[test]
fn refuses_wraps_across_spaces_favorites_and_overlapping_subtrees() {
    let mut ws = workspace(); ws.move_item("tab-spec", "pin-home", 0, false).unwrap();
    for selection in [vec!["tab-spec".into()], vec!["tab-mail".into()], vec!["split-1".into(), "tab-a".into(), "folder-docs".into(), "tab-spec".into()]] {
        refused(&mut ws, |ws| ws.create_folder("new", "New", "pin-work", 0, &selection));
    }
    ws.move_item("tab-spec", "folder-docs", 0, false).unwrap();
    refused(&mut ws, |ws| ws.create_folder("new", "New", "pin-work", 0, &["folder-docs".into(), "tab-spec".into()]));
    refused(&mut ws, |ws| ws.create_folder("new", "New", "folder-docs", 0, &["folder-docs".into()]));
    ws.create_folder("inner", "Inner", "folder-docs", 0, &[]).unwrap();
    refused(&mut ws, |ws| ws.create_folder("new", "New", "inner", 0, &["folder-docs".into()]));
}

#[test]
fn today_pinned_and_favorites_reorder_between_multiple_neighbors() {
    for parent in ["today-work", "pin-home", "fav-default"] {
        let mut ws = workspace();
        ws.move_item("tab-mail", parent, 0, false).unwrap(); ws.move_item("tab-spec", parent, 1, false).unwrap();
        let mut extra = ws.items["tab-mail"].clone(); extra.id = "extra".into();
        extra.membership.order = ararat_core::order::key_between(ws.children(parent).last().map(|i| i.membership.order.as_str()), None);
        ws.apply(&Op::Put(Record::Item(extra)));
        for index in [0, 2, 1] {
            edit(&mut ws, |ws| ws.move_item("tab-spec", parent, index, false).unwrap());
            assert_eq!(children(&ws, parent)[index], "tab-spec");
            let children = ws.children(parent); assert!(children.windows(2).all(|p| p[0].membership.order < p[1].membership.order));
        }
    }
}
#[test]
fn restore_expands_only_local_folder_state_and_keeps_synced_peer_fold_state_separate() {
    let mut ws = workspace(); ws.archive_item("tab-spec").unwrap(); ws.set_folder_collapsed("folder-docs", true).unwrap();
    let mut peer = ws.clone(); peer.folder_collapsed.clear();
    let before = ws.items["folder-docs"].clone();
    let ops = edit(&mut ws, |ws| ws.restore_item("one", "tab-spec").unwrap());
    assert_eq!(ws.items["folder-docs"], before); assert_eq!(ws.folder_collapsed["folder-docs"], false);
    assert!(ops.iter().any(|op| matches!(op, Op::Put(Record::FolderState { item, collapsed: false }) if item == "folder-docs")));
    for op in ops.iter().filter(|op| matches!(op, Op::Put(r) if !matches!(r.kind(), Kind::Window | Kind::LastSelected | Kind::FolderState))) { peer.apply(op); }
    assert!(peer.folder_collapsed.is_empty());
}


#[test]
fn drop_moves_and_opens_folder_in_one_batch_with_only_move_in_journal() {
    let path = std::env::temp_dir().join(format!("ararat-drop-batch-{}.sqlite", std::process::id()));
    assert!(!path.exists());
    let (store, _) = Store::open(&path).unwrap();
    let mut ws = workspace();
    ws.set_folder_collapsed("folder-docs", true).unwrap();
    store.write(ws.to_ops());
    store.flush().unwrap();
    let conn = rusqlite::Connection::open(&path).unwrap();
    let before: i64 = conn.query_row("SELECT count(*) FROM journal", [], |r| r.get(0)).unwrap();
    let ops = edit(&mut ws, |ws| ws.move_item("tab-mail", "folder-docs", 0, true).unwrap());
    assert_eq!(ops.len(), 2);
    assert!(matches!(&ops[0], Op::Put(Record::Item(i)) if i.id == "tab-mail"));
    assert!(matches!(&ops[1], Op::Put(Record::FolderState { item, collapsed: false }) if item == "folder-docs"));
    assert_eq!(ws.folder_collapsed.get("folder-docs"), Some(&false));
    store.write(ops);
    store.flush().unwrap();
    let journal: Vec<(String, String)> = conn.prepare("SELECT kind,id FROM journal WHERE seq > ? ORDER BY seq").unwrap()
        .query_map([before], |r| Ok((r.get(0)?, r.get(1)?))).unwrap().map(Result::unwrap).collect();
    assert_eq!(journal, [("item".into(), "tab-mail".into())]);
    drop(store);
    let (store, reopened) = Store::open(&path).unwrap();
    assert_eq!(reopened, ws);
    drop(store);
    drop(conn);
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
}

#[test]
fn opening_a_noop_move_is_local_and_ordinary_moves_keep_folders_closed() {
    let mut ws = workspace();
    ws.set_folder_collapsed("folder-docs", true).unwrap();
    ws.move_item("tab-mail", "folder-docs", 0, false).unwrap();
    assert_eq!(ws.folder_collapsed.get("folder-docs"), Some(&true));
    let ops = edit(&mut ws, |ws| ws.move_item("tab-mail", "folder-docs", 0, true).unwrap());
    assert_eq!(ops.len(), 1);
    assert!(matches!(&ops[0], Op::Put(Record::FolderState { collapsed: false, .. })));
    assert!(ws.move_item("tab-mail", "folder-docs", 0, true).unwrap().is_empty());
    let before = ws.clone();
    assert!(ws.move_item("tab-mail", "folder-docs", 99, true).is_err());
    assert_eq!(ws, before);
}
