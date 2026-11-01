use std::path::{Path, PathBuf};
use std::sync::Arc;

use ararat_core::{import, storage::Store};
use ararat_ffi::{CoreError, WorkspaceStore, import_arc_sidebar};
use rusqlite::Connection;

const FIXTURE: &str = include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json");

fn fresh_db(name: &str) -> PathBuf {
    let path = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(format!("ffi-{name}.sqlite"));
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
    path
}

fn records(path: &Path) -> Vec<(String, String, String)> {
    let conn = Connection::open(path).unwrap();
    let mut stmt = conn.prepare("SELECT kind, id, body FROM records ORDER BY kind, id").unwrap();
    stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap().map(Result::unwrap).collect()
}

#[test]
fn import_close_and_reopen_preserves_the_snapshot() {
    let path = fresh_db("reopen").display().to_string();
    let store = WorkspaceStore::open(path.clone()).unwrap();
    assert!(store.snapshot("test".into()).spaces.is_empty());
    let imported = store.import_arc_sidebar("test".into(), FIXTURE.into()).unwrap();
    assert_eq!(imported, import_arc_sidebar(FIXTURE.into()).unwrap());
    assert_eq!(store.last_error(), None);
    drop(store);
    assert_eq!(WorkspaceStore::open(path).unwrap().snapshot("test".into()), imported);
}

#[test]
fn a_second_import_merges_records_and_matches_reopening() {
    let path = fresh_db("merge").display().to_string();
    let store = WorkspaceStore::open(path.clone()).unwrap();
    store.import_arc_sidebar("test".into(), FIXTURE.into()).unwrap();
    let merged = store.import_arc_sidebar("test".into(), FIXTURE.replace("tab-a", "tab-new")).unwrap();
    let rows = &merged.spaces[0].pinned;
    assert!(rows.iter().any(|r| r.id == "tab-a"));
    assert!(rows.iter().any(|r| r.id == "tab-new"));
    drop(store);
    assert_eq!(WorkspaceStore::open(path).unwrap().snapshot("test".into()), merged);
}

#[test]
fn a_stored_cycle_is_repaired_only_in_the_snapshot() {
    let path = fresh_db("cycle");
    let mut workspace = import::arc_sidebar(FIXTURE).unwrap();
    workspace.items.get_mut("folder-docs").unwrap().membership.parent = Some("tab-spec".into());
    assert!(workspace.check_tree().is_err());
    let (store, _) = Store::open(&path).unwrap();
    store.write(workspace.to_ops());
    store.flush().unwrap();
    drop(store);
    let before = records(&path);
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let snapshot = store.snapshot("test".into());
    assert!(snapshot.spaces.iter().flat_map(|s| s.pinned.iter().chain(&s.today)).any(|r| r.id == "tab-spec"));
    assert_eq!(store.snapshot("test".into()), snapshot);
    store.flush().unwrap();
    drop(store);
    assert_eq!(records(&path), before);
    assert_eq!(Store::open(&path).unwrap().1, workspace);
}

#[test]
fn the_store_can_be_shared_between_two_threads() {
    let store = WorkspaceStore::open(fresh_db("threads").display().to_string()).unwrap();
    std::thread::scope(|scope| {
        let writer = Arc::clone(&store);
        let reader = Arc::clone(&store);
        let imported = scope.spawn(move || writer.import_arc_sidebar("test".into(), FIXTURE.into()).unwrap());
        let read = scope.spawn(move || {
            reader.snapshot("test".into());
            reader.flush().unwrap();
            assert_eq!(reader.last_error(), None);
        });
        read.join().unwrap();
        assert_eq!(imported.join().unwrap(), store.snapshot("test".into()));
    });
}

#[test]
fn store_failures_cross_the_ffi_boundary() {
    let store = WorkspaceStore::open(fresh_db("errors").display().to_string()).unwrap();
    assert!(matches!(store.import_arc_sidebar("test".into(), "invalid".into()), Err(CoreError::Import { .. })));
    assert!(store.snapshot("test".into()).spaces.is_empty());
    let path = fresh_db("busy");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let blocker = Connection::open(&path).unwrap();
    blocker.execute_batch("BEGIN IMMEDIATE").unwrap();
    assert!(matches!(store.import_arc_sidebar("test".into(), FIXTURE.into()), Err(CoreError::Store { .. })));
    assert!(store.last_error().is_some());
    blocker.execute_batch("ROLLBACK").unwrap();
    store.flush().unwrap();
    assert_eq!(store.last_error(), None);
}

fn today_fixture() -> String {
    FIXTURE.replace("\"parentID\": \"split-1\"", "\"parentID\": \"today-work\"")
        .replace("\"childrenIds\": [\"tab-a\", \"tab-b\"]", "\"childrenIds\": []")
        .replace("\"childrenIds\": [\"easel-1\"]", "\"childrenIds\": [\"tab-a\", \"tab-b\", \"easel-1\"]")
}

#[test]
fn closing_a_today_tab_persists_lifecycle_and_successor_before_returning() {
    let path = fresh_db("close-today");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("test".into(), today_fixture()).unwrap();
    store.select_item("test".into(), "tab-a".into()).unwrap();
    let closed = store.close_item("test".into(), "tab-a".into()).unwrap();
    assert_eq!(closed.selected_id.as_deref(), Some("tab-b"));
    assert!(!closed.spaces[0].today.iter().any(|r| r.id == "tab-a"));
    let (_, disk) = Store::open(&path).unwrap();
    assert_eq!(disk.items["tab-a"].lifecycle, ararat_core::model::Lifecycle::Closed);
    assert_eq!(disk.selected("test"), Some("tab-b"));
    let conn = Connection::open(&path).unwrap();
    assert_eq!(conn.query_row("SELECT count(*) FROM journal WHERE kind = 'window'", [], |r| r.get::<_, i64>(0)).unwrap(), 0);
    let body: String = conn.query_row("SELECT body FROM journal WHERE kind = 'item' AND id = 'tab-a' ORDER BY seq DESC LIMIT 1", [], |r| r.get(0)).unwrap();
    assert!(body.contains("Closed"));
    drop(store);
    assert_eq!(WorkspaceStore::open(path.display().to_string()).unwrap().snapshot("test".into()), closed);
}

#[test]
fn invalid_closes_write_neither_records_nor_journal() {
    let path = fresh_db("invalid-close");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let original = store.import_arc_sidebar("test".into(), today_fixture()).unwrap();
    let before = records(&path);
    let journal_count = || Connection::open(&path).unwrap().query_row("SELECT count(*) FROM journal", [], |r| r.get::<_, i64>(0)).unwrap();
    let count = journal_count();
    for id in ["unknown", "folder-docs"] {
        assert!(matches!(store.close_item("test".into(), id.into()), Err(CoreError::Edit { .. })));
        store.flush().unwrap();
        assert_eq!(store.snapshot("test".into()), original);
        assert_eq!(records(&path), before);
        assert_eq!(journal_count(), count);
    }
}

#[test]
fn a_failed_close_flush_keeps_the_edit_for_retry() {
    let path = fresh_db("close-busy");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("test".into(), today_fixture()).unwrap();
    store.select_item("test".into(), "tab-a".into()).unwrap();
    store.flush().unwrap();
    let blocker = Connection::open(&path).unwrap();
    blocker.execute_batch("BEGIN IMMEDIATE").unwrap();
    assert!(matches!(store.close_item("test".into(), "tab-a".into()), Err(CoreError::Store { .. })));
    assert_eq!(store.snapshot("test".into()).selected_id.as_deref(), Some("tab-b"));
    let (_, before_retry) = Store::open(&path).unwrap();
    assert_eq!(before_retry.items["tab-a"].lifecycle, ararat_core::model::Lifecycle::Open);
    assert_eq!(before_retry.selected("test"), Some("tab-a"));
    blocker.execute_batch("ROLLBACK").unwrap();
    store.flush().unwrap();
    let expected = store.snapshot("test".into()); drop(store);
    assert_eq!(WorkspaceStore::open(path.display().to_string()).unwrap().snapshot("test".into()), expected);
}

fn split_today_fixture() -> String {
    FIXTURE.replace("\"childrenIds\": [\"folder-docs\", \"split-1\"]", "\"childrenIds\": [\"folder-docs\"]")
        .replace("\"id\": \"split-1\", \"parentID\": \"pin-work\"", "\"id\": \"split-1\", \"parentID\": \"today-work\"")
        .replace("\"childrenIds\": [\"easel-1\"]", "\"childrenIds\": [\"split-1\", \"easel-1\"]")
}

#[test]
fn a_surviving_split_with_an_unloaded_member_stays_selected_and_can_be_closed() {
    let path = fresh_db("surviving-split");
    let mut ws = import::arc_sidebar(&split_today_fixture()).unwrap();
    ws.select_item("test", "tab-spec").unwrap();
    ws.select_item("test", "tab-a").unwrap();
    ws.items.get_mut("tab-b").unwrap().lifecycle = ararat_core::model::Lifecycle::Unloaded;
    let (disk, _) = Store::open(&path).unwrap();
    disk.write(ws.to_ops()); disk.flush().unwrap(); drop(disk);
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    assert_eq!(store.close_item("test".into(), "tab-a".into()).unwrap().selected_id.as_deref(), Some("split-1"));
    assert_eq!(store.close_item("test".into(), "split-1".into()).unwrap().selected_id.as_deref(), Some("tab-spec"));
}

#[test]
fn split_close_and_both_member_orders_leave_no_empty_selection_after_reopen() {
    for (index, order) in [vec!["split-1"], vec!["tab-a", "tab-b"], vec!["tab-b", "tab-a"]].into_iter().enumerate() {
        let path = fresh_db(&format!("split-close-{index}"));
        let store = WorkspaceStore::open(path.display().to_string()).unwrap();
        store.import_arc_sidebar("test".into(), split_today_fixture()).unwrap();
        store.select_item("test".into(), "split-1".into()).unwrap();
        for id in order { store.close_item("test".into(), id.into()).unwrap(); }
        let closed = store.snapshot("test".into());
        assert!(closed.spaces[0].today.is_empty());
        assert_eq!(closed.selected_id, None);
        let (_, disk) = Store::open(&path).unwrap();
        for id in ["split-1", "tab-a", "tab-b"] { assert_eq!(disk.items[id].lifecycle, ararat_core::model::Lifecycle::Closed); }
        let conn = Connection::open(&path).unwrap();
        assert_eq!(conn.query_row("SELECT count(*) FROM journal WHERE kind = 'window'", [], |r| r.get::<_, i64>(0)).unwrap(), 0);
        assert_eq!(conn.query_row("SELECT count(*) FROM journal WHERE body LIKE '%Closed%'", [], |r| r.get::<_, i64>(0)).unwrap(), 3);
        drop(store);
        assert_eq!(WorkspaceStore::open(path.display().to_string()).unwrap().snapshot("test".into()), closed);
    }
}

#[test]
fn selecting_rows_persists_locally_without_adding_sync_entries() {
    let path = fresh_db("local-clicks");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("test".into(), split_today_fixture()).unwrap();
    let conn = Connection::open(&path).unwrap();
    let count = || conn.query_row("SELECT count(*) FROM journal", [], |r| r.get::<_, i64>(0)).unwrap();
    let before = count();
    for id in ["tab-spec", "tab-mail", "split-1"] { store.select_item("test".into(), id.into()).unwrap(); }
    store.flush().unwrap();
    assert_eq!(count(), before);
    let expected = store.snapshot("test".into()); drop(store);
    assert_eq!(WorkspaceStore::open(path.display().to_string()).unwrap().snapshot("test".into()), expected);
}

#[test]
fn folders_and_hidden_tabs_are_rejected_without_writes() {
    let path = fresh_db("hidden-selection");
    let mut ws = import::arc_sidebar(FIXTURE).unwrap();
    ws.items.get_mut("folder-docs").unwrap().collapsed = true;
    let (store, _) = Store::open(&path).unwrap(); store.write(ws.to_ops()); store.flush().unwrap(); drop(store);
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let before = records(&path);
    for id in ["folder-docs", "tab-spec", "unknown"] { assert!(store.select_item("test".into(), id.into()).is_err()); }
    store.flush().unwrap();
    assert_eq!(records(&path), before);
    assert_eq!(store.snapshot("test".into()).selected_id, None);
}

#[test]
fn recent_selection_wins_and_unloading_is_visible_and_persistent() {
    let path = fresh_db("mru-unload");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("one".into(), today_fixture()).unwrap();
    store.select_item("one".into(), "tab-b".into()).unwrap();
    store.select_item("one".into(), "tab-a".into()).unwrap();
    let closed = store.close_item("one".into(), "tab-a".into()).unwrap();
    assert_eq!(closed.selected_id.as_deref(), Some("tab-b"));
    for id in ["tab-spec", "tab-mail"] {
        let previous = store.snapshot("one".into()).selected_id;
        store.select_item("one".into(), id.into()).unwrap();
        let unloaded = store.close_item("one".into(), id.into()).unwrap();
        assert_eq!(unloaded.selected_id, previous);
        assert!(unloaded.spaces.iter().flat_map(|s| s.favorites.iter().chain(&s.pinned)).any(|r| r.id == id && r.unloaded));
        let loaded = store.select_item("one".into(), id.into()).unwrap();
        assert!(loaded.spaces.iter().flat_map(|s| s.favorites.iter().chain(&s.pinned)).any(|r| r.id == id && !r.unloaded));
    }
    store.select_item("two".into(), "tab-b".into()).unwrap();
    store.flush().unwrap();
    let one = store.snapshot("one".into()); let two = store.snapshot("two".into());
    assert_eq!(one.selected_id.as_deref(), Some("tab-mail"));
    assert_eq!(two.selected_id.as_deref(), Some("tab-b"));
    drop(store);
    let reopened = WorkspaceStore::open(path.display().to_string()).unwrap();
    assert_eq!(reopened.snapshot("one".into()), one);
    assert_eq!(reopened.snapshot("two".into()), two);
    assert_eq!(Connection::open(&path).unwrap().query_row("SELECT count(*) FROM journal WHERE kind = 'window'", [], |r| r.get::<_, i64>(0)).unwrap(), 0);
}

#[test]
fn shown_space_is_local_persistent_and_limits_successors_after_reopen() {
    let path = fresh_db("shown-space");
    let mut ws = import::arc_sidebar(&today_fixture()).unwrap();
    for id in ["tab-a", "tab-b"] { ws.items.get_mut(id).unwrap().membership.parent = Some("today-home".into()); }
    let (disk, _) = Store::open(&path).unwrap(); disk.write(ws.to_ops()); disk.flush().unwrap(); drop(disk);
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let conn = Connection::open(&path).unwrap();
    let count = || conn.query_row("SELECT count(*) FROM journal", [], |r| r.get::<_, i64>(0)).unwrap();
    let before = count();
    store.select_item("test".into(), "tab-spec".into()).unwrap();
    store.show_space("test".into(), "space-home".into()).unwrap();
    for id in ["tab-a", "tab-b"] { store.select_item("test".into(), id.into()).unwrap(); }
    store.flush().unwrap();
    assert_eq!(count(), before);
    let saved = records(&path);
    assert!(store.show_space("test".into(), "missing".into()).is_err());
    store.flush().unwrap();
    assert_eq!(records(&path), saved);
    drop(store);
    let (_, restored) = Store::open(&path).unwrap();
    assert_eq!(restored.windows["test"].shown_space.as_deref(), Some("space-home"));
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    assert_eq!(store.close_item("test".into(), "tab-b".into()).unwrap().selected_id.as_deref(), Some("tab-a"));
    assert_eq!(store.close_item("test".into(), "tab-a".into()).unwrap().selected_id, None);
    assert_eq!(count(), before + 2);
}
