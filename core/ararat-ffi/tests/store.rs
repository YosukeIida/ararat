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
    assert!(store.snapshot().spaces.is_empty());
    let imported = store.import_arc_sidebar(FIXTURE.into()).unwrap();
    assert_eq!(imported, import_arc_sidebar(FIXTURE.into()).unwrap());
    assert_eq!(store.last_error(), None);
    drop(store);
    assert_eq!(WorkspaceStore::open(path).unwrap().snapshot(), imported);
}

#[test]
fn a_second_import_merges_records_and_matches_reopening() {
    let path = fresh_db("merge").display().to_string();
    let store = WorkspaceStore::open(path.clone()).unwrap();
    store.import_arc_sidebar(FIXTURE.into()).unwrap();
    let merged = store.import_arc_sidebar(FIXTURE.replace("tab-a", "tab-new")).unwrap();
    let rows = &merged.spaces[0].pinned;
    assert!(rows.iter().any(|r| r.id == "tab-a"));
    assert!(rows.iter().any(|r| r.id == "tab-new"));
    drop(store);
    assert_eq!(WorkspaceStore::open(path).unwrap().snapshot(), merged);
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
    let snapshot = store.snapshot();
    assert!(snapshot.spaces.iter().flat_map(|s| s.pinned.iter().chain(&s.today)).any(|r| r.id == "tab-spec"));
    assert_eq!(store.snapshot(), snapshot);
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
        let imported = scope.spawn(move || writer.import_arc_sidebar(FIXTURE.into()).unwrap());
        let read = scope.spawn(move || {
            reader.snapshot();
            reader.flush().unwrap();
            assert_eq!(reader.last_error(), None);
        });
        read.join().unwrap();
        assert_eq!(imported.join().unwrap(), store.snapshot());
    });
}

#[test]
fn store_failures_cross_the_ffi_boundary() {
    let store = WorkspaceStore::open(fresh_db("errors").display().to_string()).unwrap();
    assert!(matches!(store.import_arc_sidebar("invalid".into()), Err(CoreError::Import { .. })));
    assert!(store.snapshot().spaces.is_empty());
    let path = fresh_db("busy");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let blocker = Connection::open(&path).unwrap();
    blocker.execute_batch("BEGIN IMMEDIATE").unwrap();
    assert!(matches!(store.import_arc_sidebar(FIXTURE.into()), Err(CoreError::Store { .. })));
    assert!(store.last_error().is_some());
    blocker.execute_batch("ROLLBACK").unwrap();
    store.flush().unwrap();
    assert_eq!(store.last_error(), None);
}
