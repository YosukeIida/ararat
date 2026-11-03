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
    let mut preview = import_arc_sidebar(FIXTURE.into()).unwrap();
    for space in &mut preview.spaces {
        let actual = imported.spaces.iter().find(|s| s.id == space.id).unwrap();
        for row in space.favorites.iter_mut().chain(&mut space.pinned).chain(&mut space.today) {
            row.last_selected_at = actual.favorites.iter().chain(&actual.pinned).chain(&actual.today).find(|r| r.id == row.id).unwrap().last_selected_at;
        }
    }
    assert_eq!(imported, preview);
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
fn selecting_rows_persists_time_and_history_locally() {
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
fn folders_are_rejected_and_selecting_hidden_tabs_persists_local_expansion() {
    let path = fresh_db("hidden-selection");
    let mut ws = import::arc_sidebar(FIXTURE).unwrap();
    ws.folder_collapsed.insert("folder-docs".into(), true);
    let (store, _) = Store::open(&path).unwrap(); store.write(ws.to_ops()); store.flush().unwrap(); drop(store);
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let before = records(&path);
    for id in ["folder-docs", "unknown"] { assert!(store.select_item("test".into(), id.into()).is_err()); }
    store.flush().unwrap();
    assert_eq!(records(&path), before);
    assert_eq!(store.snapshot("test".into()).selected_id, None);
    store.select_item("test".into(), "tab-spec".into()).unwrap(); store.flush().unwrap();
    let (disk, reopened) = Store::open(&path).unwrap();
    assert!(!reopened.folder_collapsed["folder-docs"]);
    assert_eq!(reopened.selected("test"), Some("tab-spec")); drop(disk);
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

#[test]
fn archive_and_restore_cross_the_boundary_and_persist() {
    let path = fresh_db("archive-restore");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("test".into(), today_fixture()).unwrap();
    store.close_item("test".into(), "tab-a".into()).unwrap();
    let closed = store.close_item("test".into(), "tab-b".into()).unwrap();
    assert_eq!(closed.archive.iter().map(|row| row.id.as_str()).collect::<Vec<_>>(), ["tab-b", "tab-a"]);
    store.show_space("test".into(), "space-home".into()).unwrap();
    let restored = store.restore_item("test".into(), "tab-a".into()).unwrap();
    assert_eq!(restored.selected_id.as_deref(), Some("tab-a"));
    assert_eq!(restored.shown_space_id.as_deref(), Some("space-work"));
    assert_eq!(restored.spaces[0].today[0].id, "tab-a");
    assert_eq!(restored.archive.len(), 1);
    drop(store);
    assert_eq!(WorkspaceStore::open(path.display().to_string()).unwrap().snapshot("test".into()), restored);
}

#[test]
fn creating_a_space_persists_the_snapshot_and_journals_one_complete_change() {
    let path = fresh_db("create-space");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("test".into(), FIXTURE.into()).unwrap();
    store.show_space("test".into(), "space-home".into()).unwrap();
    store.flush().unwrap();
    let conn = Connection::open(&path).unwrap();
    let before: i64 = conn.query_row("SELECT count(*) FROM journal", [], |row| row.get(0)).unwrap();
    let created = store.create_space("test".into(), "  Project Notes  ".into(), "created-space".into()).unwrap();
    assert_eq!(created.spaces.len(), 3);
    assert_eq!(created.spaces[2].title, "Project Notes");
    assert_eq!(created.spaces[2].profile_name, created.spaces[1].profile_name);
    assert!(created.spaces[2].today.is_empty() && created.spaces[2].pinned.is_empty());
    assert_eq!(created.shown_space_id.as_deref(), Some("created-space"));
    assert_eq!(created.selected_id, None);
    assert_eq!(conn.query_row("SELECT count(*) FROM journal", [], |row| row.get::<_, i64>(0)).unwrap(), before + 3);
    drop(store);
    assert_eq!(WorkspaceStore::open(path.display().to_string()).unwrap().snapshot("test".into()), created);
}

#[test]
fn rejected_space_names_write_no_records_or_journal() {
    let path = fresh_db("reject-space");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("test".into(), FIXTURE.into()).unwrap();
    let before = records(&path);
    let conn = Connection::open(&path).unwrap();
    let count = || conn.query_row("SELECT count(*) FROM journal", [], |row| row.get::<_, i64>(0)).unwrap();
    let journal = count();
    for name in ["", " \t\n", "\u{3000}"] {
        assert!(store.create_space("test".into(), name.into(), "new-space".into()).is_err());
        store.flush().unwrap();
        assert_eq!(records(&path), before);
        assert_eq!(count(), journal);
    }
}

#[test]
fn deleting_an_archive_entry_removes_only_its_record_and_persists_the_tombstone() {
    let path = fresh_db("archive-delete");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("test".into(), today_fixture()).unwrap();
    for id in ["tab-a", "tab-b"] { store.close_item("test".into(), id.into()).unwrap(); }
    let before = records(&path);
    let conn = Connection::open(&path).unwrap();
    let count = || conn.query_row("SELECT count(*) FROM journal", [], |row| row.get::<_, i64>(0)).unwrap();
    let journal = count();
    let remaining = store.delete_archive_item("test".into(), "tab-a".into()).unwrap();
    assert_eq!(remaining.archive.iter().map(|entry| entry.id.as_str()).collect::<Vec<_>>(), ["tab-b"]);
    assert!(remaining.archive[0].lifecycle_changed_at > 0);
    assert_eq!(records(&path), before.into_iter().filter(|(kind, id, _)| !matches!(kind.as_str(), "item" | "last_selected") || id != "tab-a").collect::<Vec<_>>());
    assert_eq!(count(), journal + 1);
    assert_eq!(conn.query_row("SELECT count(*) FROM journal WHERE id='tab-a' AND body IS NULL", [], |row| row.get::<_, i64>(0)).unwrap(), 1);
    let after = records(&path);
    for id in ["missing", "tab-a", "tab-mail", "folder-docs"] {
        assert!(store.delete_archive_item("test".into(), id.into()).is_err());
        store.flush().unwrap();
        assert_eq!(records(&path), after);
        assert_eq!(count(), journal + 1);
    }
    drop(store);
    assert_eq!(WorkspaceStore::open(path.display().to_string()).unwrap().snapshot("test".into()), remaining);
}

#[test]
fn archive_pinned_tab_survives_reopen() {
    let path = fresh_db("archive-pin").display().to_string();
    let store = WorkspaceStore::open(path.clone()).unwrap();
    store.import_arc_sidebar("test".into(), FIXTURE.into()).unwrap();
    store.select_item("test".into(), "tab-spec".into()).unwrap();
    let archived = store.archive_item("test".into(), "tab-spec".into()).unwrap();
    assert!(!archived.spaces[0].pinned.iter().any(|row| row.id == "tab-spec"));
    assert!(archived.archive.iter().any(|row| row.id == "tab-spec"));
    drop(store);
    assert_eq!(WorkspaceStore::open(path).unwrap().snapshot("test".into()), archived);
}

#[test]
fn folder_archive_restore_keeps_order_and_survives_reopen() {
    let path = fresh_db("folder-restore");
    let mut ws = import::arc_sidebar(FIXTURE).unwrap();
    ws.items.get_mut("tab-a").unwrap().membership.parent = Some("folder-docs".into());
    ws.items.get_mut("tab-a").unwrap().membership.order = "A".into();
    ws.items.get_mut("tab-spec").unwrap().membership.order = "B".into();
    let (disk, _) = Store::open(&path).unwrap(); disk.write(ws.to_ops()); disk.flush().unwrap(); drop(disk);
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.archive_item("test".into(), "tab-a".into()).unwrap();
    drop(store);
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let snapshot = store.restore_item("test".into(), "tab-a".into()).unwrap();
    let rows = &snapshot.spaces[0].pinned;
    let index = rows.iter().position(|row| row.id == "tab-a").unwrap();
    assert_eq!(rows[index - 1].id, "folder-docs");
    assert_eq!(rows[index + 1].id, "tab-spec");
    assert_eq!(rows[index].depth, 1);
    drop(store);
    assert_eq!(WorkspaceStore::open(path.display().to_string()).unwrap().snapshot("test".into()), snapshot);
}

#[test]
fn folder_restore_fallbacks_and_missing_neighbours_cross_the_boundary() {
    for situation in ["deleted", "archived", "neighbours gone", "collapsed"] {
        let path = fresh_db(&format!("folder-restore-{situation}"));
        let mut ws = import::arc_sidebar(FIXTURE).unwrap();
        ws.items.get_mut("tab-a").unwrap().membership.parent = Some("folder-docs".into());
        ws.archive_item("tab-a").unwrap();
        match situation {
            "deleted" => { ws.items.remove("folder-docs"); }
            "archived" => ws.items.get_mut("folder-docs").unwrap().lifecycle = ararat_core::model::Lifecycle::Archived,
            "collapsed" => { ws.folder_collapsed.insert("folder-docs".into(), true); },
            _ => { ws.items.remove("tab-spec"); ws.items.remove("tab-b"); }
        }
        let (disk, _) = Store::open(&path).unwrap(); disk.write(ws.to_ops()); disk.flush().unwrap(); drop(disk);
        let store = WorkspaceStore::open(path.display().to_string()).unwrap();
        let snapshot = store.restore_item("test".into(), "tab-a".into()).unwrap();
        assert_eq!(snapshot.selected_id.as_deref(), Some("tab-a"));
        if ["deleted", "archived"].contains(&situation) { assert_eq!(snapshot.spaces[0].today[0].id, "tab-a"); }
        else { assert_eq!(snapshot.spaces[0].pinned.iter().find(|row| row.id == "tab-a").unwrap().depth, 1); }
        drop(store);
        let (disk, reopened) = Store::open(&path).unwrap();
        assert_eq!(reopened.items["tab-a"].membership.parent.as_deref(), Some(if ["deleted", "archived"].contains(&situation) { "today-work" } else { "folder-docs" }));
        if situation == "collapsed" { assert!(!reopened.folder_collapsed["folder-docs"]); }
        drop(disk);
        assert_eq!(WorkspaceStore::open(path.display().to_string()).unwrap().snapshot("test".into()), snapshot);
    }
}

#[test]
fn space_edits_flush_complete_records_and_local_window_changes() {
    use ararat_ffi::{Appearance, Look, LookColor};
    let path = fresh_db("space-look-edits");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("one".into(), FIXTURE.into()).unwrap();
    let view = store.rename_space("one".into(), "space-work".into(), "  Research  ".into()).unwrap();
    assert_eq!(view.spaces[0].title, "Research");
    let view = store.set_space_icon("one".into(), "space-work".into(), Some("👩🏽‍💻".into())).unwrap();
    assert_eq!(view.spaces[0].icon.as_deref(), Some("👩🏽‍💻"));
    let look = Look { colors: vec![LookColor { red: 0.1, green: 0.2, blue: 0.3, x: 0.4, y: 0.5 }], opacity: 0.6, grain: 0.7, glass: true, appearance: Appearance::Dark };
    let view = store.set_space_look("one".into(), "space-work".into(), Some(look.clone())).unwrap();
    assert_eq!(view.spaces[0].look.as_ref(), Some(&look));
    let (_, disk) = Store::open(&path).unwrap(); assert_eq!(disk.spaces[0].look.as_ref().unwrap().opacity, 0.6);
    let conn = Connection::open(&path).unwrap();
    let body: String = conn.query_row("SELECT body FROM journal WHERE kind='space' AND id='space-work' ORDER BY seq DESC LIMIT 1", [], |r| r.get(0)).unwrap();
    let ararat_core::model::Record::Space(record) = ararat_core::model::Record::parse(ararat_core::model::Kind::Space, "space-work", &body).unwrap() else { panic!("expected space") };
    assert!(record.look.unwrap().glass);
    store.set_space_icon("one".into(), "space-work".into(), None).unwrap();
    store.set_space_look("one".into(), "space-work".into(), None).unwrap();
    let view = store.move_space("one".into(), "space-home".into(), 0).unwrap(); assert_eq!(view.spaces[0].id, "space-home");
    for window in ["one", "two"] { store.show_space(window.into(), "space-work".into()).unwrap(); store.select_item(window.into(), "tab-spec".into()).unwrap(); }
    let deleted = store.delete_space("one".into(), "space-work".into()).unwrap();
    assert_eq!(deleted.shown_space_id.as_deref(), Some("space-home")); assert_eq!(deleted.selected_id, None); assert_eq!(deleted.archive.len(), 3);
    assert_eq!(store.snapshot("two".into()).shown_space_id.as_deref(), Some("space-home"));
    let (_, disk) = Store::open(&path).unwrap(); disk.check_tree().unwrap();
    assert_eq!(disk.items["folder-docs"].lifecycle, ararat_core::model::Lifecycle::Archived);
    assert_eq!(conn.query_row("SELECT count(*) FROM journal WHERE kind='space' AND id='space-work' AND body IS NULL", [], |r| r.get::<_, i64>(0)).unwrap(), 1);
    let restored = store.restore_item("one".into(), "tab-spec".into()).unwrap();
    assert_eq!(restored.spaces[0].today[0].id, "tab-spec");
    drop(store); assert_eq!(WorkspaceStore::open(path.display().to_string()).unwrap().snapshot("one".into()), restored);
}

#[test]
fn rejected_space_edits_write_neither_records_nor_journal() {
    let path = fresh_db("space-edit-rejections");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let original = store.import_arc_sidebar("one".into(), FIXTURE.into()).unwrap();
    let before = records(&path);
    let conn = Connection::open(&path).unwrap();
    let count = || conn.query_row("SELECT count(*) FROM journal", [], |r| r.get::<_, i64>(0)).unwrap(); let journal = count();
    assert!(store.rename_space("one".into(), "space-work".into(), " \n".into()).is_err());
    assert!(store.set_space_icon("one".into(), "space-work".into(), Some(" ".into())).is_err());
    assert!(store.set_space_look("one".into(), "space-work".into(), Some(ararat_ffi::Look { colors: vec![], opacity: 0.0, grain: 0.0, glass: false, appearance: ararat_ffi::Appearance::Auto })).is_err());
    assert!(store.move_space("one".into(), "space-work".into(), 2).is_err());
    assert!(store.delete_space("one".into(), "missing".into()).is_err());
    store.flush().unwrap(); assert_eq!(records(&path), before); assert_eq!(count(), journal); assert_eq!(store.snapshot("one".into()), original);
    store.delete_space("one".into(), "space-home".into()).unwrap(); let before = records(&path); let journal = count();
    assert!(store.delete_space("one".into(), "space-work".into()).is_err());
    store.flush().unwrap(); assert_eq!(records(&path), before); assert_eq!(count(), journal);
}

#[test]
fn snapshot_repairs_live_items_in_deleted_space_roots_without_writing_the_view_back() {
    for root in ["pin-work", "today-work"] {
        let path = fresh_db(&format!("space-delete-concurrent-{root}"));
        let mut ws = import::arc_sidebar(FIXTURE).unwrap(); ws.delete_space("space-work").unwrap();
        ws.items.get_mut("tab-mail").unwrap().membership.parent = Some(root.into());
        let (store, _) = Store::open(&path).unwrap(); store.write(ws.to_ops()); store.flush().unwrap(); drop(store);
        let before = records(&path);
        let store = WorkspaceStore::open(path.display().to_string()).unwrap(); let view = store.snapshot("one".into());
        assert!(view.spaces[0].today.iter().any(|row| row.id == "tab-mail"));
        store.flush().unwrap(); drop(store); assert_eq!(records(&path), before);
        assert_eq!(Store::open(&path).unwrap().1.items["tab-mail"].membership.parent.as_deref(), Some(root));
    }
}

#[test]
fn profile_archive_options_times_and_auto_archive_persist_across_ffi_reopen() {
    use ararat_ffi::ArchiveAfter;
    let path = fresh_db("auto-archive");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let imported = store.import_arc_sidebar("test".into(), today_fixture()).unwrap();
    let row = imported.spaces[0].today.iter().find(|r| r.id == "tab-a").unwrap();
    let started = row.last_selected_at.unwrap();
    for value in [ArchiveAfter::Hours12, ArchiveAfter::Hours24, ArchiveAfter::Days7, ArchiveAfter::Days30] {
        let snapshot = store.set_archive_after("test".into(), "space-work".into(), value).unwrap();
        assert_eq!(snapshot.spaces[0].archive_after, value);
    }
    store.set_archive_after("test".into(), "space-work".into(), ArchiveAfter::Hours12).unwrap();
    let archived = store.auto_archive("test".into(), started + 12 * 3_600_000 + 1).unwrap().unwrap();
    assert!(archived.archive.iter().any(|i| i.id == "tab-a"));
    assert!(!archived.spaces[0].today.iter().any(|i| i.id == "tab-a"));
    store.flush().unwrap(); drop(store);
    let reopened = WorkspaceStore::open(path.display().to_string()).unwrap();
    assert_eq!(reopened.snapshot("test".into()), archived);
}

#[test]
fn idle_auto_archive_returns_none_without_publishing_or_writing() {
    let path = fresh_db("auto-archive-idle");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let imported = store.import_arc_sidebar("test".into(), today_fixture()).unwrap();
    let now = imported.spaces[0].today.iter().find(|r| r.id == "tab-a").unwrap().last_selected_at.unwrap();
    let before = records(&path);
    assert_eq!(store.auto_archive("test".into(), now).unwrap(), None);
    assert_eq!(records(&path), before);
}

#[test]
fn item_edit_calls_flush_synced_changes_and_local_folder_state_before_returning() {
    let path = fresh_db("item-edits");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("one".into(), include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json").replace(r#""profile": { "custom": { "_0": { "directoryBasename": "Profile 1" } } }"#, r#""profile": { "default": true }"#)).unwrap();
    store.select_item("one".into(), "tab-spec".into()).unwrap();
    store.create_folder("one".into(), "new".into(), "New".into(), "pin-home".into(), 0, vec![]).unwrap();
    store.move_item("one".into(), "tab-spec".into(), "new".into(), 0).unwrap();
    let renamed = store.rename_tab("one".into(), "tab-spec".into(), "Custom".into()).unwrap();
    assert_eq!(renamed.spaces[1].pinned.iter().find(|r| r.id == "tab-spec").unwrap().title, "Custom");
    store.rename_folder("one".into(), "new".into(), "Folder".into()).unwrap();
    let before = records(&path);
    let folded = store.set_folder_collapsed("one".into(), "new".into(), true).unwrap();
    assert_eq!(folded.selected_id.as_deref(), Some("tab-spec"));
    assert_eq!(folded.shown_space_id.as_deref(), Some("space-work"));
    assert!(!folded.spaces[1].pinned.iter().any(|r| r.id == "tab-spec"));
    assert_eq!(Store::open(&path).unwrap().1.folder_collapsed["new"], true);
    assert_eq!(records(&path).iter().filter(|(kind, _, _)| kind != "folder_state").count(), before.len());
    let after = store.delete_folder("one".into(), "new".into()).unwrap();
    assert!(after.spaces[1].pinned.is_empty());
    assert!(after.archive.iter().any(|item| item.id == "tab-spec" && item.title == "Custom"));
    assert_eq!(WorkspaceStore::open(path.display().to_string()).unwrap().snapshot("one".into()), after);
}

#[test]
fn a_same_position_move_writes_no_records_or_journal_rows() {
    let path = fresh_db("noop-item-move"); let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("one".into(), FIXTURE.into()).unwrap();
    let before = records(&path);
    let conn = Connection::open(&path).unwrap();
    let count = || conn.query_row("SELECT count(*) FROM journal", [], |r| r.get::<_, i64>(0)).unwrap();
    let journal = count(); let view = store.snapshot("one".into());
    assert_eq!(store.move_item("one".into(), "split-1".into(), "pin-work".into(), 1).unwrap(), view);
    assert_eq!(records(&path), before); assert_eq!(count(), journal);
}

#[test]
fn unpin_refreshes_local_usage_in_the_same_persisted_edit() {
    let path = fresh_db("unpin-usage");
    let mut ws = import::arc_sidebar(FIXTURE).unwrap(); ws.stamp_selection("tab-spec", 1_000);
    let (disk, _) = Store::open(&path).unwrap(); disk.write(ws.to_ops()); disk.flush().unwrap(); drop(disk);
    let conn = Connection::open(&path).unwrap();
    let count = || conn.query_row("SELECT count(*) FROM journal", [], |r| r.get::<_, i64>(0)).unwrap();
    let journal = count();
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64;
    store.move_item("one".into(), "tab-spec".into(), "today-work".into(), 0).unwrap();
    let (disk, reopened) = Store::open(&path).unwrap();
    assert!(reopened.last_selected["tab-spec"] >= now); assert_eq!(count(), journal + 1); drop(disk);
    store.auto_archive("one".into(), now + 1).unwrap();
    let (disk, reopened) = Store::open(&path).unwrap();
    assert_eq!(reopened.items["tab-spec"].lifecycle, ararat_core::model::Lifecycle::Open); drop(disk);
}
