use ararat_core::{import::arc_sidebar, model::{Lifecycle, Op, Record}, storage::Store};

fn workspace() -> ararat_core::model::Workspace {
    let mut ws = arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json")).unwrap();
    for id in ["tab-a", "tab-b"] { ws.items.get_mut(id).unwrap().membership.parent = Some("today-work".into()); }
    ws
}

#[test]
fn archive_lists_only_closed_and_archived_tabs_newest_first() {
    let mut ws = workspace();
    ws.close_item("tab-a").unwrap();
    let first = ws.items["tab-a"].lifecycle_changed_at;
    let ops = ws.close_item("tab-b").unwrap();
    assert!(ws.items["tab-b"].lifecycle_changed_at > first);
    assert!(ops.iter().any(|op| matches!(op, Op::Put(Record::Item(item)) if item.lifecycle_changed_at > first)));
    ws.items.get_mut("tab-a").unwrap().lifecycle = Lifecycle::Archived;
    ws.close_item("tab-mail").unwrap();
    assert_eq!(ws.archive().iter().map(|item| item.id.as_str()).collect::<Vec<_>>(), ["tab-b", "tab-a"]);
}

#[test]
fn restoring_reopens_at_the_top_of_its_today_and_persists_synced_and_local_changes_together() {
    let mut ws = workspace();
    ws.select_item("one", "tab-b").unwrap();
    ws.close_item("tab-a").unwrap();
    let closed_at = ws.items["tab-a"].lifecycle_changed_at;
    ws.show_space("one", "space-home").unwrap();
    let path = std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("archive-restore.sqlite");
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
    let (store, _) = Store::open(&path).unwrap(); store.write(ws.to_ops()); store.flush().unwrap();
    let conn = rusqlite::Connection::open(&path).unwrap();
    let count = || conn.query_row("SELECT count(*) FROM journal", [], |row| row.get::<_, i64>(0)).unwrap();
    let before = count();
    let ops = ws.restore_item("one", "tab-a").unwrap();
    assert_eq!(ops.len(), 2);
    assert_eq!(ws.items["tab-a"].lifecycle, Lifecycle::Open);
    assert!(ws.items["tab-a"].lifecycle_changed_at > closed_at);
    assert_eq!(ws.outline("today-work")[0].1.id, "tab-a");
    assert_eq!(ws.selected("one"), Some("tab-a"));
    assert_eq!(ws.windows["one"].history[0], "tab-a");
    assert_eq!(ws.shown_space("one"), Some("space-work"));
    assert!(ws.archive().is_empty());
    store.write(ops); store.flush().unwrap();
    assert_eq!(count(), before + 1);
    drop(store);
    assert_eq!(Store::open(&path).unwrap().1, ws);
    assert!(ws.restore_item("one", "tab-a").is_err());
}

#[test]
fn restore_uses_the_shown_space_when_the_original_space_is_gone() {
    let mut ws = workspace();
    ws.close_item("tab-a").unwrap();
    ws.show_space("one", "space-home").unwrap();
    ws.spaces.retain(|space| space.id != "space-work");
    ws.restore_item("one", "tab-a").unwrap();
    assert_eq!(ws.items["tab-a"].membership.parent.as_deref(), Some("today-home"));
    assert_eq!(ws.selected("one"), Some("tab-a"));
    assert_eq!(ws.shown_space("one"), Some("space-home"));
}

#[test]
fn old_database_versions_are_rejected_without_a_migration() {
    let path = std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("archive-old-version.sqlite");
    let _ = std::fs::remove_file(&path);
    let conn = rusqlite::Connection::open(&path).unwrap();
    conn.execute_batch("CREATE TABLE records (kind TEXT, id TEXT, body TEXT)").unwrap();
    drop(conn);
    assert!(Store::open(&path).err().unwrap().0.contains("unsupported database version"));
}
