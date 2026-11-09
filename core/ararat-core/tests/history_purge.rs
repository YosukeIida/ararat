use ararat_core::{import::arc_sidebar, live::{Cause, Live, Strip, Transaction}, model::{Lifecycle, Profile}, storage::Store};

#[test]
fn lifecycle_purges_are_local_and_durable_but_empty_epoch_is_not_a_delete() {
    let path = std::env::temp_dir().join(format!("ararat-purge-{}.sqlite", std::process::id()));
    assert!(!path.exists());
    let mut ws = arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json"), None, None, None, None).unwrap().0;
    let (store, _) = Store::open(&path).unwrap();
    store.write(ws.to_ops());
    store.flush().unwrap();
    let (ops, _) = Live::new().apply(&mut ws, Transaction {
        epoch: 1, rev: 0, cause: Cause::Engine,
        strips: vec![Strip { window: "one".into(), tabs: vec![], active: None }],
    });
    assert!(ws.history_purges.is_empty());
    store.write(ops);
    store.write(ws.archive_item("tab-spec").unwrap());
    store.flush().unwrap();
    let loaded = Store::open(&path).unwrap().1;
    assert_eq!(loaded.items["tab-spec"].lifecycle, Lifecycle::Archived);
    assert_eq!(loaded.history_purges.values().collect::<Vec<_>>(), vec![&(Profile::Default, "tab-spec".into(), loaded.items["tab-spec"].lifecycle_changed_at)]);
    let purge_at = loaded.items["tab-spec"].lifecycle_changed_at;
    ws.restore_item("one", "tab-spec").unwrap();
    assert!(ws.items["tab-spec"].lifecycle_changed_at > purge_at);
    let conn = rusqlite::Connection::open(&path).unwrap();
    let count: u32 = conn.query_row("SELECT count(*) FROM journal WHERE kind = 'history_purge'", [], |row| row.get(0)).unwrap();
    assert_eq!(count, 0);
    drop(conn);
    drop(store);
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
}

#[test]
fn deleting_a_space_records_its_unloaded_tabs_with_the_old_profile() {
    let mut ws = arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json"), None, None, None, None).unwrap().0;
    ws.show_space("one", "space-home").unwrap();
    let ops = ws.create_tab("one", "https://named.example/").unwrap();
    for op in ops { ws.apply(&op); }
    let id = ws.selected("one").unwrap().to_string();
    ws.items.get_mut(&id).unwrap().lifecycle = Lifecycle::Unloaded;
    ws.delete_space("space-home").unwrap();
    assert!(ws.history_purges.values().any(|(profile, item, _)| *profile == Profile::Named("Profile 1".into()) && item == &id));
    assert_eq!(ws.items[&id].lifecycle, Lifecycle::Archived);
    ws.history_purges.clear();
    let archived_at = ws.items[&id].lifecycle_changed_at;
    ws.delete_archive_item(&id).unwrap();
    assert!(ws.history_purges.values().any(|(profile, item, changed_at)| *profile == Profile::Named("Profile 1".into()) && item == &id && *changed_at > archived_at));
    assert!(!ws.history_profiles.contains_key(&id));
}

#[test]
fn deleting_a_folder_queues_each_tab_including_unloaded_split_members() {
    let mut ws = arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json"), None, None, None, None).unwrap().0;
    ws.move_item("split-1", "folder-docs", 1, false).unwrap();
    ws.items.get_mut("tab-b").unwrap().lifecycle = Lifecycle::Unloaded;
    ws.delete_folder("folder-docs").unwrap();
    let mut items: Vec<_> = ws.history_purges.values().map(|(profile, item, _)| {
        assert_eq!(*profile, Profile::Default);
        item.as_str()
    }).collect();
    items.sort();
    assert_eq!(items, ["tab-a", "tab-b", "tab-spec"]);
}
