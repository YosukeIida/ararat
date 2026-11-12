use std::path::{Path, PathBuf};
use std::sync::Arc;

use ararat_core::{import, storage::Store};
use ararat_ffi::{CoreError, LiveCause, LiveStrip, LiveTab, LiveTransaction, Profile, RowKind, SplitFactor, SplitPaneKind, WorkspaceStore, import_arc_sidebar};
use rusqlite::Connection;

const FIXTURE: &str = include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json");

#[test]
fn favorites_container_survives_reopen() {
    let path = fresh_db("new-favorites").display().to_string();
    let store = WorkspaceStore::open(path.clone()).unwrap();
    store.create_space("window".into(), "Work".into(), "work".into()).unwrap();
    let snapshot = store.ensure_favorites("window".into(), "work".into(), "favorites".into()).unwrap();
    assert_eq!(snapshot.spaces[0].favorites_id.as_deref(), Some("favorites"));
    drop(store);
    assert_eq!(WorkspaceStore::open(path).unwrap().snapshot("window".into()).spaces[0].favorites_id.as_deref(), Some("favorites"));
}

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
    let imported = store.import_arc_sidebar("test".into(), FIXTURE.into(), None, None, None, None).unwrap().snapshot;
    let mut preview = import_arc_sidebar(FIXTURE.into(), None, None, None, None).unwrap().snapshot;
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
    store.import_arc_sidebar("test".into(), FIXTURE.into(), None, None, None, None).unwrap().snapshot;
    let merged = store.import_arc_sidebar("test".into(), FIXTURE.replace("tab-a", "tab-new"), None, None, None, None).unwrap().snapshot;
    let rows = &merged.spaces[0].pinned;
    assert!(rows.iter().any(|r| r.id == "tab-a"));
    assert!(rows.iter().any(|r| r.id == "tab-new"));
    drop(store);
    assert_eq!(WorkspaceStore::open(path).unwrap().snapshot("test".into()), merged);
}

#[test]
fn a_stored_cycle_is_repaired_only_in_the_snapshot() {
    let path = fresh_db("cycle");
    let mut workspace = import::arc_sidebar(FIXTURE, None, None, None, None).unwrap().0;
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
        let imported = scope.spawn(move || writer.import_arc_sidebar("test".into(), FIXTURE.into(), None, None, None, None).unwrap().snapshot);
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
    assert!(matches!(store.import_arc_sidebar("test".into(), "invalid".into(), None, None, None, None), Err(CoreError::Import { .. })));
    assert!(store.snapshot("test".into()).spaces.is_empty());
    let path = fresh_db("busy");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let blocker = Connection::open(&path).unwrap();
    blocker.execute_batch("BEGIN IMMEDIATE").unwrap();
    assert!(matches!(store.import_arc_sidebar("test".into(), FIXTURE.into(), None, None, None, None), Err(CoreError::Store { .. })));
    assert!(store.last_error().is_some());
    blocker.execute_batch("ROLLBACK").unwrap();
    store.flush().unwrap();
    assert_eq!(store.last_error(), None);
}

#[test]
fn empty_purge_query_does_not_flush_unrelated_pending_changes() {
    let path = fresh_db("empty-purge-no-flush");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("test".into(), FIXTURE.into(), None, None, None, None).unwrap();
    let blocker = Connection::open(&path).unwrap();
    blocker.execute_batch("BEGIN IMMEDIATE").unwrap();
    store.select_item("test".into(), "tab-a".into()).unwrap();
    assert!(store.pending_history_purges().unwrap().is_empty());
    assert!(matches!(store.flush(), Err(CoreError::Store { .. })));
    blocker.execute_batch("ROLLBACK").unwrap();
    store.flush().unwrap();
}

#[test]
fn set_tab_url_flushes_and_reports_a_write_error() {
    let path = fresh_db("set-url");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("test".into(), FIXTURE.into(), None, None, None, None).unwrap();
    let blocker = Connection::open(&path).unwrap();
    blocker.execute_batch("BEGIN IMMEDIATE").unwrap();
    // Every other content edit flushes; the edit's write error must reach the caller too.
    let result = store.set_tab_url("test".into(), "tab-a".into(), "https://example.org/b".into());
    assert!(matches!(result, Err(CoreError::Store { .. })));
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
    store.import_arc_sidebar("test".into(), today_fixture(), None, None, None, None).unwrap().snapshot;
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
    let original = store.import_arc_sidebar("test".into(), today_fixture(), None, None, None, None).unwrap().snapshot;
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
    store.import_arc_sidebar("test".into(), today_fixture(), None, None, None, None).unwrap().snapshot;
    store.select_item("test".into(), "tab-a".into()).unwrap();
    store.flush().unwrap();
    let blocker = Connection::open(&path).unwrap();
    blocker.execute_batch("BEGIN IMMEDIATE").unwrap();
    assert!(matches!(store.close_item("test".into(), "tab-a".into()), Err(CoreError::Store { .. })));
    assert_eq!(store.snapshot("test".into()).selected_id.as_deref(), Some("tab-b"));
    let (_, before_retry) = Store::open(&path).unwrap();
    assert_eq!(before_retry.items["tab-a"].lifecycle, ararat_core::model::Lifecycle::Open);
    assert_eq!(before_retry.selected("test"), Some("tab-a"));
    assert!(before_retry.history_purges.is_empty());
    blocker.execute_batch("ROLLBACK").unwrap();
    store.flush().unwrap();
    assert!(store.pending_history_purges().unwrap().iter().any(|purge| purge.item == "tab-a"));
    let expected = store.snapshot("test".into()); drop(store);
    assert_eq!(WorkspaceStore::open(path.display().to_string()).unwrap().snapshot("test".into()), expected);
}

#[test]
fn live_apply_delivers_adoption_when_flush_fails_and_storage_retries() {
    let path = fresh_db("live-busy");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("test".into(), today_fixture(), None, None, None, None).unwrap();
    let blocker = Connection::open(&path).unwrap();
    blocker.execute_batch("BEGIN IMMEDIATE").unwrap();
    let transaction = LiveTransaction { off_the_record: false, epoch:  1, rev: 0, cause: LiveCause::Chrome,
        strips: vec![LiveStrip { window: "test".into(), active: Some("live-new".into()), tabs: vec![LiveTab { off_the_record: false,
            profile: Profile::Default, live_id: "live-new".into(), item: None, opener: None, navigated: true,
            url: Some("https://example.com/".into()), title: None,
        }] }] };
    let outcome = store.live_apply(transaction.clone()).unwrap();
    assert!(outcome.applied);
    assert!(outcome.persistence_error.is_some());
    assert_eq!(outcome.adopted.len(), 1);
    let adopted = outcome.adopted[0].item.clone();
    assert!(!store.live_apply(transaction).unwrap().applied);
    blocker.execute_batch("ROLLBACK").unwrap();
    store.flush().unwrap();
    let (_, disk) = Store::open(&path).unwrap();
    assert!(disk.items.contains_key(&adopted));
}

fn split_today_fixture() -> String {
    FIXTURE.replace("\"childrenIds\": [\"folder-docs\", \"split-1\"]", "\"childrenIds\": [\"folder-docs\"]")
        .replace("\"id\": \"split-1\", \"parentID\": \"pin-work\"", "\"id\": \"split-1\", \"parentID\": \"today-work\"")
        .replace("\"childrenIds\": [\"easel-1\"]", "\"childrenIds\": [\"split-1\", \"easel-1\"]")
}

#[test]
fn a_surviving_split_with_an_unloaded_member_stays_selected_and_can_be_closed() {
    let path = fresh_db("surviving-split");
    let mut ws = import::arc_sidebar(&split_today_fixture(), None, None, None, None).unwrap().0;
    ws.select_item("test", "tab-spec").unwrap();
    ws.select_item("test", "tab-a").unwrap();
    ws.items.get_mut("tab-b").unwrap().lifecycle = ararat_core::model::Lifecycle::Unloaded;
    let (disk, _) = Store::open(&path).unwrap();
    disk.write(ws.to_ops()); disk.flush().unwrap(); drop(disk);
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    assert_eq!(store.close_item("test".into(), "tab-a".into()).unwrap().selected_id.as_deref(), Some("tab-b"));
    let reopened = WorkspaceStore::open(path.display().to_string()).unwrap();
    assert_eq!(reopened.snapshot("test".into()).selected_id.as_deref(), Some("tab-b"));
    drop(reopened);
    assert_eq!(store.close_item("test".into(), "split-1".into()).unwrap().selected_id.as_deref(), Some("tab-spec"));
}

#[test]
fn split_layout_projects_nested_panes_and_persists_factors() {
    use ararat_core::model::{ItemKind, Orientation};
    let path = fresh_db("split-layout");
    let mut ws = import::arc_sidebar(&split_today_fixture(), None, None, None, None).unwrap().0;
    let mut nested = ws.items["tab-a"].clone();
    nested.id = "nested".into();
    nested.kind = ItemKind::Split { orientation: Orientation::Vertical, width_factors: vec![] };
    ws.items.get_mut("tab-a").unwrap().membership.parent = Some("nested".into());
    ws.items.insert(nested.id.clone(), nested);
    let (disk, _) = Store::open(&path).unwrap();
    disk.write(ws.to_ops()); disk.flush().unwrap(); drop(disk);
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let layout = store.split_layout("tab-a".into()).unwrap();
    assert_eq!(layout.kind, SplitPaneKind::SplitHorizontal);
    let nested = layout.children.iter().find(|pane| pane.id == "nested").unwrap();
    assert_eq!(nested.kind, SplitPaneKind::SplitVertical);
    assert_eq!(nested.children[0].id, "tab-a");
    let factors = layout.children.iter().map(|pane| SplitFactor { id: pane.id.clone(), factor: if pane.id == "nested" { 3.0 } else { 1.0 } }).collect();
    store.set_split_factors("split-1".into(), factors).unwrap();
    drop(store);
    let layout = WorkspaceStore::open(path.display().to_string()).unwrap().split_layout("tab-b".into()).unwrap();
    assert_eq!(layout.children.iter().find(|pane| pane.id == "nested").unwrap().factor, 0.75);
}

#[test]
fn space_switch_reopens_a_split_with_only_unloaded_members() {
    let path = fresh_db("unloaded-split-switch");
    let mut ws = import::arc_sidebar(&split_today_fixture(), None, None, None, None).unwrap().0;
    for id in ["tab-a", "tab-b"] { ws.items.get_mut(id).unwrap().lifecycle = ararat_core::model::Lifecycle::Unloaded; }
    let (disk, _) = Store::open(&path).unwrap();
    disk.write(ws.to_ops()); disk.flush().unwrap(); drop(disk);
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let selected = store.show_space_selecting("test".into(), "space-work".into()).unwrap();
    assert_eq!(selected.selected_id.as_deref(), Some("tab-a"));
    assert!(!selected.spaces[0].today.iter().find(|row| row.id == "tab-b").unwrap().unloaded);
}

#[test]
fn space_switch_reopens_unloaded_siblings_of_the_selected_member() {
    let path = fresh_db("unloaded-split-sibling");
    let mut ws = import::arc_sidebar(&split_today_fixture(), None, None, None, None).unwrap().0;
    ws.select_item("test", "tab-a").unwrap();
    ws.items.get_mut("tab-b").unwrap().lifecycle = ararat_core::model::Lifecycle::Unloaded;
    let (disk, _) = Store::open(&path).unwrap();
    disk.write(ws.to_ops()); disk.flush().unwrap(); drop(disk);
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let selected = store.show_space_selecting("test".into(), "space-work".into()).unwrap();
    assert_eq!(selected.selected_id.as_deref(), Some("tab-a"));
    assert!(!selected.spaces[0].today.iter().find(|row| row.id == "tab-b").unwrap().unloaded);
}

#[test]
fn restoration_candidate_keeps_the_selected_split_member() {
    let path = fresh_db("restore-split-member");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("test".into(), split_today_fixture(), None, None, None, None).unwrap();
    store.select_item("test".into(), "tab-b".into()).unwrap();
    store.flush().unwrap();
    drop(store);
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    assert_eq!(store.restoration_candidate("test".into()).unwrap().id, "tab-b");
}

#[test]
fn closing_a_live_split_returns_close_commands_for_all_members() {
    let path = fresh_db("close-live-split");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("test".into(), split_today_fixture(), None, None, None, None).unwrap();
    store.select_item("test".into(), "split-1".into()).unwrap();
    let a = store.live_open("tab-a".into(), "https://a.example.com".into()).unwrap();
    let b = store.live_open("tab-b".into(), "https://b.example.com".into()).unwrap();
    let targets = store.live_close_split("split-1".into()).unwrap();
    assert_eq!(targets.len(), 2);
    assert!(targets.iter().any(|target| target.live_id == a.id && target.command.item == "tab-a"));
    assert!(targets.iter().any(|target| target.live_id == b.id && target.command.item == "tab-b"));
    assert!(store.snapshot("test".into()).spaces[0].today.iter().all(|row| row.id != "split-1"));
    drop(store);
    assert!(WorkspaceStore::open(path.display().to_string()).unwrap().snapshot("test".into()).spaces[0].today.iter().all(|row| row.id != "split-1"));
}

#[test]
fn split_close_and_both_member_orders_leave_no_empty_selection_after_reopen() {
    for (index, order) in [vec!["split-1"], vec!["tab-a", "tab-b"], vec!["tab-b", "tab-a"]].into_iter().enumerate() {
        let path = fresh_db(&format!("split-close-{index}"));
        let store = WorkspaceStore::open(path.display().to_string()).unwrap();
        store.import_arc_sidebar("test".into(), split_today_fixture(), None, None, None, None).unwrap().snapshot;
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
    store.import_arc_sidebar("test".into(), split_today_fixture(), None, None, None, None).unwrap().snapshot;
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
    let mut ws = import::arc_sidebar(FIXTURE, None, None, None, None).unwrap().0;
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
    store.import_arc_sidebar("one".into(), today_fixture(), None, None, None, None).unwrap().snapshot;
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
    let mut ws = import::arc_sidebar(&today_fixture(), None, None, None, None).unwrap().0;
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
    store.import_arc_sidebar("test".into(), today_fixture(), None, None, None, None).unwrap().snapshot;
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
    store.import_arc_sidebar("test".into(), FIXTURE.into(), None, None, None, None).unwrap().snapshot;
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
    store.import_arc_sidebar("test".into(), FIXTURE.into(), None, None, None, None).unwrap().snapshot;
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
    store.import_arc_sidebar("test".into(), today_fixture(), None, None, None, None).unwrap().snapshot;
    for id in ["tab-a", "tab-b"] { store.close_item("test".into(), id.into()).unwrap(); }
    let before = records(&path);
    let conn = Connection::open(&path).unwrap();
    let count = || conn.query_row("SELECT count(*) FROM journal", [], |row| row.get::<_, i64>(0)).unwrap();
    let journal = count();
    let remaining = store.delete_archive_item("test".into(), "tab-a".into()).unwrap();
    assert_eq!(remaining.archive.iter().map(|entry| entry.id.as_str()).collect::<Vec<_>>(), ["tab-b"]);
    assert!(remaining.archive[0].lifecycle_changed_at > 0);
    let synced = |rows: Vec<(String, String, String)>| rows.into_iter().filter(|(kind, _, _)| !matches!(kind.as_str(), "history_purge" | "history_profile")).collect::<Vec<_>>();
    assert_eq!(synced(records(&path)), synced(before.into_iter().filter(|(kind, id, _)| !matches!(kind.as_str(), "item" | "last_selected") || id != "tab-a").collect()));
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
    store.import_arc_sidebar("test".into(), FIXTURE.into(), None, None, None, None).unwrap().snapshot;
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
    let mut ws = import::arc_sidebar(FIXTURE, None, None, None, None).unwrap().0;
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
        let mut ws = import::arc_sidebar(FIXTURE, None, None, None, None).unwrap().0;
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
    store.import_arc_sidebar("one".into(), FIXTURE.into(), None, None, None, None).unwrap().snapshot;
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
    let original = store.import_arc_sidebar("one".into(), FIXTURE.into(), None, None, None, None).unwrap().snapshot;
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
        let mut ws = import::arc_sidebar(FIXTURE, None, None, None, None).unwrap().0; ws.delete_space("space-work").unwrap();
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
    let imported = store.import_arc_sidebar("test".into(), today_fixture(), None, None, None, None).unwrap().snapshot;
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
    let imported = store.import_arc_sidebar("test".into(), today_fixture(), None, None, None, None).unwrap().snapshot;
    let now = imported.spaces[0].today.iter().find(|r| r.id == "tab-a").unwrap().last_selected_at.unwrap();
    let before = records(&path);
    assert_eq!(store.auto_archive("test".into(), now).unwrap(), None);
    assert_eq!(records(&path), before);
}

#[test]
fn item_edit_calls_flush_synced_changes_and_local_folder_state_before_returning() {
    let path = fresh_db("item-edits");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("one".into(), include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json").replace(r#""profile": { "custom": { "_0": { "directoryBasename": "Profile 1" } } }"#, r#""profile": { "default": true }"#), None, None, None, None).unwrap().snapshot;
    store.select_item("one".into(), "tab-spec".into()).unwrap();
    store.create_folder("one".into(), "new".into(), "New".into(), "pin-home".into(), 0, vec![]).unwrap();
    store.move_item("one".into(), "tab-spec".into(), "new".into(), 0, false).unwrap();
    let renamed = store.rename_tab("one".into(), "tab-spec".into(), "Custom".into()).unwrap();
    assert_eq!(renamed.spaces[1].pinned.iter().find(|r| r.id == "tab-spec").unwrap().title, "Custom");
    store.rename_folder("one".into(), "new".into(), "Folder".into()).unwrap();
    let before = records(&path);
    let folded = store.set_folder_collapsed("one".into(), "new".into(), true).unwrap();
    assert_eq!(folded.selected_id.as_deref(), Some("tab-spec"));
    assert_eq!(folded.shown_space_id.as_deref(), Some("space-work"));
    // The collapsed folder keeps the selected tab's own row (the holder rule, U25b D1):
    // the folder and the path down to the current tab stay, nothing else does.
    assert!(folded.spaces[1].pinned.iter().any(|r| r.id == "new"));
    assert!(folded.spaces[1].pinned.iter().any(|r| r.id == "tab-spec"));
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
    store.import_arc_sidebar("one".into(), FIXTURE.into(), None, None, None, None).unwrap().snapshot;
    let before = records(&path);
    let conn = Connection::open(&path).unwrap();
    let count = || conn.query_row("SELECT count(*) FROM journal", [], |r| r.get::<_, i64>(0)).unwrap();
    let journal = count(); let view = store.snapshot("one".into());
    assert_eq!(store.move_item("one".into(), "split-1".into(), "pin-work".into(), 1, false).unwrap(), view);
    assert_eq!(records(&path), before); assert_eq!(count(), journal);
}

#[test]
fn unpin_refreshes_local_usage_in_the_same_persisted_edit() {
    let path = fresh_db("unpin-usage");
    let mut ws = import::arc_sidebar(FIXTURE, None, None, None, None).unwrap().0; ws.stamp_selection("tab-spec", 1_000);
    let (disk, _) = Store::open(&path).unwrap(); disk.write(ws.to_ops()); disk.flush().unwrap(); drop(disk);
    let conn = Connection::open(&path).unwrap();
    let count = || conn.query_row("SELECT count(*) FROM journal", [], |r| r.get::<_, i64>(0)).unwrap();
    let journal = count();
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64;
    store.move_item("one".into(), "tab-spec".into(), "today-work".into(), 0, false).unwrap();
    let (disk, reopened) = Store::open(&path).unwrap();
    assert!(reopened.last_selected["tab-spec"] >= now); assert_eq!(count(), journal + 1); drop(disk);
    store.auto_archive("one".into(), now + 1).unwrap();
    let (disk, reopened) = Store::open(&path).unwrap();
    assert_eq!(reopened.items["tab-spec"].lifecycle, ararat_core::model::Lifecycle::Open); drop(disk);
}

#[test]
fn folder_drop_opens_in_the_move_call_and_flushes_both_states() {
    let path = fresh_db("folder-drop");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("drag".into(), FIXTURE.into(), None, None, None, None).unwrap().snapshot;
    store.set_folder_collapsed("drag".into(), "folder-docs".into(), true).unwrap();
    let conn = Connection::open(&path).unwrap();
    let before: i64 = conn.query_row("SELECT max(seq) FROM journal", [], |r| r.get(0)).unwrap();
    let moved = store.move_item("drag".into(), "tab-mail".into(), "folder-docs".into(), 0, true).unwrap();
    assert!(moved.spaces[0].pinned.iter().any(|row| row.id == "tab-mail" && row.parent_id == "folder-docs"));
    assert!(!moved.spaces[0].pinned.iter().find(|row| row.id == "folder-docs").unwrap().collapsed);
    let ops: Vec<(String, String)> = conn.prepare("SELECT kind,id FROM journal WHERE seq > ?").unwrap()
        .query_map([before], |r| Ok((r.get(0)?, r.get(1)?))).unwrap().map(Result::unwrap).collect();
    assert_eq!(ops, [("item".into(), "tab-mail".into())]);
    let (_, reopened) = Store::open(&path).unwrap();
    assert_eq!(reopened.folder_collapsed.get("folder-docs"), Some(&false));
    assert_eq!(reopened.items["tab-mail"].membership.parent.as_deref(), Some("folder-docs"));
}

#[test]
fn window_import_reports_and_preserves_dates_and_local_state() {
    let windows = include_str!("../../ararat-core/tests/fixtures/StorableWindows.json");
    let preview = import_arc_sidebar(FIXTURE.into(), Some(windows.into()), None, None, None).unwrap();
    assert_eq!(preview.report.differing_folder_states, 1);
    assert_eq!(preview.report.skipped_dates, 1);
    let path = fresh_db("import-windows");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let imported = store.import_arc_sidebar("test".into(), FIXTURE.into(), Some(windows.into()), None, None, None).unwrap();
    assert_eq!(imported.report, preview.report);
    let rows = &imported.snapshot.spaces[0].pinned;
    assert!(rows.iter().find(|r| r.id == "folder-docs").unwrap().collapsed);
    assert_eq!(rows.iter().find(|r| r.id == "tab-a").unwrap().last_selected_at, Some(1_678_307_200_000));
    assert!(imported.snapshot.spaces[0].favorites.iter().find(|r| r.id == "tab-mail").unwrap().last_selected_at.is_some());
    drop(store);
    assert_eq!(WorkspaceStore::open(path.display().to_string()).unwrap().snapshot("test".into()), imported.snapshot);
    let conn = Connection::open(path).unwrap();
    let count: i64 = conn.query_row("SELECT count(*) FROM journal WHERE kind IN ('folder_state','last_selected')", [], |r| r.get(0)).unwrap();
    assert_eq!(count, 0);
    for windows in [None, Some("{".into())] {
        let imported = import_arc_sidebar(FIXTURE.into(), windows.clone(), None, None, None).unwrap();
        assert_eq!(imported.report.missing_windows, windows.is_none());
        assert_eq!(imported.report.windows_error.is_some(), windows.is_some());
        assert!(!imported.snapshot.spaces.is_empty());
        let store = WorkspaceStore::open(fresh_db(if windows.is_none() { "missing-windows" } else { "bad-windows" }).display().to_string()).unwrap();
        let stored = store.import_arc_sidebar("test".into(), FIXTURE.into(), windows, None, None, None).unwrap();
        assert_eq!(stored.report, imported.report);
        assert_eq!(stored.snapshot.spaces.len(), imported.snapshot.spaces.len());
    }
}

#[test]
fn key_bindings_ffi_reads_sets_clears_resets_and_reopens() {
    use ararat_ffi::KeyCombination;
    let path = fresh_db("key-bindings").display().to_string();
    let store = WorkspaceStore::open(path.clone()).unwrap();
    let defaults = store.key_bindings();
    assert_eq!(defaults, ararat_ffi::default_key_bindings());
    assert_eq!(defaults.len(), 35);
    let binding = |rows: Vec<ararat_ffi::KeyBinding>, id: &str| rows.into_iter().find(|row| row.command == id).unwrap();
    let key = KeyCombination { key: "s".into(), command: true, control: false, option: false, shift: false };
    let changed = store.set_key_binding("close_tab".into(), Some(key.clone())).unwrap();
    assert_eq!(binding(changed.clone(), "close_tab").key, Some(key));
    assert!(binding(changed.clone(), "close_tab").customized);
    assert_eq!(binding(changed.clone(), "toggle_sidebar").key, None);
    assert!(binding(changed.clone(), "toggle_sidebar").customized);
    assert_eq!(WorkspaceStore::open(path.clone()).unwrap().key_bindings(), changed);
    assert!(matches!(store.set_key_binding("unknown".into(), None), Err(CoreError::Edit { .. })));
    let invalid = KeyCombination { key: "x".into(), command: false, control: false, option: false, shift: false };
    assert!(matches!(store.set_key_binding("close_tab".into(), Some(invalid)), Err(CoreError::Edit { .. })));
    assert_eq!(store.key_bindings(), changed);
    let cleared = store.set_key_binding("close_tab".into(), None).unwrap();
    assert_eq!(binding(cleared, "close_tab").key, None);
    let reset = store.reset_key_binding("close_tab".into()).unwrap();
    assert_eq!(binding(reset, "close_tab"), binding(defaults.clone(), "close_tab"));
    assert_eq!(store.reset_all_key_bindings().unwrap(), defaults);
    assert_eq!(WorkspaceStore::open(path).unwrap().key_bindings(), defaults);
}

#[test]
fn key_bindings_import_report_crosses_ffi_and_preserves_existing_overrides() {
    use ararat_ffi::KeyCombination;
    let path = fresh_db("key-bindings-import").display().to_string();
    let store = WorkspaceStore::open(path).unwrap();
    let changed = store.set_key_binding("close_tab".into(), Some(KeyCombination {
        key: "x".into(), command: true, control: false, option: false, shift: false,
    })).unwrap();
    for (json, count) in [(r#"{"version":1,"userOverrides":[]}"#, 0),
        (r#"{"version":1,"userOverrides":[{"opaque":true}]}"#, 1)] {
        let preview = import_arc_sidebar(FIXTURE.into(), None, Some(json.into()), None, None).unwrap();
        let imported = store.import_arc_sidebar("test".into(), FIXTURE.into(), None, Some(json.into()), None, None).unwrap();
        assert_eq!(preview.report, imported.report);
        assert_eq!(imported.report.skipped_key_bindings, count);
        assert!(!imported.report.missing_key_bindings);
        assert_eq!(imported.report.key_bindings_error, None);
        assert_eq!(store.key_bindings(), changed);
    }
    let imported = store.import_arc_sidebar("test".into(), FIXTURE.into(), None, Some("\u{fffd}".into()), None, None).unwrap();
    assert!(imported.report.key_bindings_error.is_some());
    assert_eq!(store.key_bindings(), changed);
}

#[test]
fn merged_key_binding_conflicts_cross_ffi_without_writes_and_can_be_taken_over() {
    use ararat_core::{key_bindings::KeyCombination, model::Workspace};
    let key = KeyCombination { key: "x".into(), command: true, control: false, option: false, shift: false };
    let a = Workspace::default().set_key_binding("close_tab", Some(key.clone())).unwrap();
    let b = Workspace::default().set_key_binding("pin_tab", Some(key)).unwrap();
    let mut tables = Vec::new();
    for (index, ops) in [a.iter().chain(&b), b.iter().chain(&a)].into_iter().enumerate() {
        let path = fresh_db(&format!("merged-keys-{index}"));
        let (disk, _) = Store::open(&path).unwrap();
        disk.write(ops.cloned().collect());
        disk.flush().unwrap();
        drop(disk);
        let before = records(&path);
        let journal_count = || Connection::open(&path).unwrap().query_row("SELECT count(*) FROM journal", [], |row| row.get::<_, i64>(0)).unwrap();
        let count = journal_count();
        let store = WorkspaceStore::open(path.display().to_string()).unwrap();
        let rows = store.key_bindings();
        let close = rows.iter().find(|row| row.command == "close_tab").unwrap();
        let pin = rows.iter().find(|row| row.command == "pin_tab").unwrap();
        assert_eq!(close.key.as_ref().unwrap().key, "x");
        assert!(!close.conflicting);
        assert_eq!(pin.key, None);
        assert_eq!(pin.assigned_key, close.key);
        assert_eq!(close.assigned_key, close.key);
        assert!(pin.conflicting && pin.customized);
        assert_eq!(records(&path), before);
        assert_eq!(journal_count(), count);
        tables.push(rows);
        let assigned = store.set_key_binding("settings".into(), Some(ararat_ffi::KeyCombination {
            key: "x".into(), command: true, control: false, option: false, shift: false,
        })).unwrap();
        assert!(assigned.iter().all(|row| !row.conflicting));
        let cleared = store.set_key_binding("settings".into(), None).unwrap();
        for id in ["close_tab", "pin_tab"] {
            let row = cleared.iter().find(|row| row.command == id).unwrap();
            assert_eq!(row.key, None);
            assert!(!row.conflicting);
        }
    }
    assert_eq!(tables[0], tables[1]);
}

// The snapshot carries each space's `Profile` itself, so Swift's pane reads the shown
// space's profile from the field and never maps the display name back: a named profile
// called "Default" is not the built-in one, though its display name is "Default".
#[test]
fn the_snapshot_carries_each_spaces_profile() {
    let snapshot = import_arc_sidebar(FIXTURE.into(), None, None, None, None).unwrap().snapshot;
    let work = snapshot.spaces.iter().find(|s| s.id == "space-work").unwrap();
    let home = snapshot.spaces.iter().find(|s| s.id == "space-home").unwrap();
    assert_eq!(work.profile, Profile::Default);
    assert_eq!(work.profile_name, "Default");
    assert_eq!(home.profile, Profile::Named("Profile 1".into()));
    assert_eq!(home.profile_name, "Profile 1");
    // The same space under a custom profile named "Default": the field keeps it named while
    // the display name collapses to "Default".
    let renamed = import_arc_sidebar(FIXTURE.replace("\"directoryBasename\": \"Profile 1\"", "\"directoryBasename\": \"Default\"").into(), None, None, None, None).unwrap().snapshot;
    let renamed_home = renamed.spaces.iter().find(|s| s.id == "space-home").unwrap();
    assert_eq!(renamed_home.profile, Profile::Named("Default".into()));
    assert_eq!(renamed_home.profile_name, "Default");
}

#[test]
fn command_bar_session_keeps_a_snapshot_and_can_be_dropped() {
    let store = WorkspaceStore::open(fresh_db("command-bar").display().to_string()).unwrap();
    store.import_arc_sidebar("test".into(), FIXTURE.into(), None, None, None, None).unwrap();
    let session = store.command_bar_session("test".into(), false);
    assert!(session.query("settings".into(), vec![]).rows.iter().any(|s| matches!(&s.target, ararat_ffi::SuggestionTarget::Command { id } if id == "settings")));
    store.set_key_binding("settings".into(), None).unwrap();
    assert!(session.query("settings".into(), vec![]).rows.iter().any(|s| matches!(&s.target, ararat_ffi::SuggestionTarget::Command { id } if id == "settings") && s.key.is_some()));
    drop(session);
    assert!(store.command_bar_session("test".into(), false).query("settings".into(), vec![]).rows.iter().any(|s| matches!(&s.target, ararat_ffi::SuggestionTarget::Command { id } if id == "settings") && s.key.is_none()));
}

#[test]
fn command_bar_query_takes_history_rows_and_the_store_creates_and_edits_tabs() {
    let store = WorkspaceStore::open(fresh_db("command-bar-actions").display().to_string()).unwrap();
    store.import_arc_sidebar("test".into(), FIXTURE.into(), None, None, None, None).unwrap();
    store.rename_tab("test".into(), "tab-a".into(), "GitHub".into()).unwrap();

    // The typed row leads (D1) and the workspace rows follow.
    let result = store.command_bar_session("test".into(), false).query("docs".into(), vec![]);
    assert!(matches!(result.rows[0].target, ararat_ffi::SuggestionTarget::Search { .. }), "the typed row is first");
    assert!(result.rows.iter().any(|s| matches!(&s.target, ararat_ffi::SuggestionTarget::Tab { id, .. } if id == "tab-spec")));
    assert!(!result.private_window);

    // History arrives from the engine per query (D5): the core scores it and the row says History.
    let history = vec![ararat_ffi::HistoryEntry {
        title: "Design tokens reference".into(),
        url: "https://docs.example.org/design/tokens".into(),
        last_visit: 0,
    }];
    let rows = store.command_bar_session("test".into(), false).query("design tokens".into(), history.clone()).rows;
    assert!(rows.iter().any(|s| matches!(&s.target, ararat_ffi::SuggestionTarget::History { url } if url == "https://docs.example.org/design/tokens") && s.subtitle == "History"));
    // A private window withholds them and marks the result so the bar can show its note (D7).
    let private = store.command_bar_session("test".into(), true).query("design tokens".into(), history);
    assert!(private.private_window);
    assert!(!private.rows.iter().any(|s| matches!(s.target, ararat_ffi::SuggestionTarget::History { .. })));

    // create_tab puts a selected tab in the shown space's Today; set_tab_url edits it.
    let before = store.snapshot("test".into());
    let shown = before.shown_space_id.clone().unwrap_or_else(|| before.spaces[0].id.clone());
    let created = store.create_tab("test".into(), "https://example.org/from-bar".into()).unwrap();
    let created_id = created.selected_id.clone().unwrap();
    let space = created.spaces.iter().find(|space| space.id == shown).unwrap();
    assert!(space.today.iter().any(|row| row.id == created_id && row.url.as_deref() == Some("https://example.org/from-bar")));
    let edited = store.set_tab_url("test".into(), created_id.clone(), "https://example.org/edited".into()).unwrap();
    let space = edited.spaces.iter().find(|space| space.id == shown).unwrap();
    assert!(space.today.iter().any(|row| row.id == created_id && row.url.as_deref() == Some("https://example.org/edited")));
    assert!(store.set_tab_url("test".into(), "folder-docs".into(), "https://example.org/".into()).is_err());
}

// U25b D1: the collapsed pinned section is a core record, and a collapsed holder (folder or
// section) keeps the current row's path visible in the snapshot.
#[test]
fn a_collapsed_pinned_section_survives_reopen_and_keeps_the_current_pin_visible() {
    let path = fresh_db("section");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let imported = store.import_arc_sidebar("one".into(), FIXTURE.into(), None, None, None, None).unwrap().snapshot;
    assert!(!store.section_collapsed("space-work".into()));
    store.select_item("one".into(), "tab-spec".into()).unwrap();
    let collapsed = store.set_section_collapsed("one".into(), "space-work".into(), true).unwrap();
    assert!(store.section_collapsed("space-work".into()));
    // The current tab is inside the pinned folder, so its path stays and nothing else does.
    let pinned: Vec<_> = collapsed.spaces[0].pinned.iter().map(|row| row.id.as_str()).collect();
    assert_eq!(pinned, ["folder-docs", "tab-spec"]);
    // Favourites and Today are other containers and draw the same rows as before.
    assert_eq!(collapsed.spaces[0].favorites, imported.spaces[0].favorites);
    assert_eq!(collapsed.spaces[0].today, imported.spaces[0].today);
    // The record is device-only like FolderState: it stays out of the journal, so a sync
    // does not carry it, while the records table brings it back on reopen.
    let conn = Connection::open(&path).unwrap();
    let journalled: i64 = conn.query_row("SELECT count(*) FROM journal WHERE kind = 'section_state'", [], |row| row.get(0)).unwrap();
    assert_eq!(journalled, 0);
    drop(conn);
    drop(store);
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    assert!(store.section_collapsed("space-work".into()));
    assert_eq!(store.snapshot("one".into()).spaces[0].pinned.iter().map(|row| row.id.as_str()).collect::<Vec<_>>(),
        ["folder-docs", "tab-spec"]);
    let expanded = store.set_section_collapsed("one".into(), "space-work".into(), false).unwrap();
    assert!(!store.section_collapsed("space-work".into()));
    assert_eq!(expanded.spaces[0].pinned.iter().map(|row| row.id.as_str()).collect::<Vec<_>>(),
        imported.spaces[0].pinned.iter().map(|row| row.id.as_str()).collect::<Vec<_>>());
    drop(store);
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
}

#[test]
fn an_open_empty_folder_emits_the_no_tabs_row_the_ui_draws() {
    let path = fresh_db("no-tabs");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("one".into(), FIXTURE.into(), None, None, None, None).unwrap();
    store.create_folder("one".into(), "empty".into(), "Empty".into(), "pin-work".into(), 1, vec![]).unwrap();
    let snapshot = store.snapshot("one".into());
    let pinned = &snapshot.spaces[0].pinned;
    let position = pinned.iter().position(|row| row.id == "empty").unwrap();
    let marker = &pinned[position + 1];
    assert_eq!(marker.kind, RowKind::NoTabs);
    assert_eq!(marker.parent_id, "empty");
    assert_eq!(marker.depth, pinned[position].depth + 1);
    assert_eq!(marker.title, "No tabs");
    assert_eq!(marker.url, None);
    // A folder that still holds a tab shows none.
    assert!(!pinned.iter().any(|row| row.kind == RowKind::NoTabs && row.parent_id == "folder-docs"));
    // A collapsed empty folder draws no marker either: its rows are closed.
    store.set_folder_collapsed("one".into(), "empty".into(), true).unwrap();
    assert!(!store.snapshot("one".into()).spaces[0].pinned.iter().any(|row| row.kind == RowKind::NoTabs));
    // Archive the folder's only tab and the marker comes back under the folder.
    store.set_folder_collapsed("one".into(), "empty".into(), false).unwrap();
    store.archive_item("one".into(), "tab-spec".into()).unwrap();
    let after = store.snapshot("one".into());
    let pinned = &after.spaces[0].pinned;
    let position = pinned.iter().position(|row| row.id == "folder-docs").unwrap();
    assert_eq!(pinned[position + 1].kind, RowKind::NoTabs);
    assert_eq!(pinned[position + 1].parent_id, "folder-docs");
    drop(store);
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
}

// U25b D6: Clear is one batch (one store write, all rows sharing an instant), archives the
// loaded and the unloaded rows of the shown space's Today, and leaves pins alone.
#[test]
fn clear_today_archives_every_today_row_at_once_and_keeps_pins() {
    let path = fresh_db("clear-today");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let imported = store.import_arc_sidebar("one".into(), FIXTURE.into(), None, None, None, None).unwrap().snapshot;
    assert!(imported.spaces[0].today.is_empty());
    let a = store.create_tab("one".into(), "https://a.example/".into()).unwrap().selected_id.unwrap();
    let b = store.create_tab("one".into(), "https://b.example/".into()).unwrap().selected_id.unwrap();
    let before = store.snapshot("one".into());
    assert_eq!(before.spaces[0].today.len(), 2);
    let cleared = store.clear_today("one".into(), "space-work".into()).unwrap().snapshot;
    assert!(cleared.spaces[0].today.is_empty());
    assert_eq!(cleared.spaces[0].pinned, before.spaces[0].pinned);
    assert_eq!(cleared.spaces[0].favorites, before.spaces[0].favorites);
    let archived: Vec<_> = cleared.archive.iter().filter(|entry| [a.as_str(), b.as_str()].contains(&entry.id.as_str())).collect();
    assert_eq!(archived.len(), 2);
    assert_eq!(archived[0].lifecycle_changed_at, archived[1].lifecycle_changed_at);
    assert!(cleared.selected_id.is_none());
    // The rows are on disk: a reopen reads the empty Today and the archive entries once.
    drop(store);
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let reopened = store.snapshot("one".into());
    assert!(reopened.spaces[0].today.is_empty());
    assert!(reopened.archive.iter().any(|entry| entry.id == a));
    assert!(reopened.archive.iter().any(|entry| entry.id == b));
    // Clearing an empty Today writes nothing and answers with the same snapshot.
    assert_eq!(store.clear_today("one".into(), "space-work".into()).unwrap().snapshot, reopened);
    assert!(store.clear_today("one".into(), "missing".into()).is_err());
    drop(store);
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
}

#[test]
fn live_clear_undo_persists_the_selected_split_member() {
    let path = fresh_db("undo-clear-split");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("one".into(), split_today_fixture(), None, None, None, None).unwrap();
    store.select_item("one".into(), "tab-b".into()).unwrap();
    let cleared = store.live_clear_today("one".into(), "space-work".into()).unwrap();
    let restored = store.undo_clear_today("one".into(), cleared.batch).unwrap();
    assert_eq!(restored.selected_id.as_deref(), Some("tab-b"));
    drop(store);
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let reopened = store.snapshot("one".into());
    assert_eq!(store.restoration_candidate("one".into()).unwrap().id, "tab-b");
    for id in ["split-1", "tab-a", "tab-b"] {
        assert!(reopened.spaces[0].today.iter().any(|row| row.id == id && row.unloaded), "{id}");
    }
    drop(store);
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
}

// U25b D5: the New Tab row switch is a synced workspace record, shown by default.
#[test]
fn the_new_tab_row_setting_reads_through_the_ffi_and_survives_reopen() {
    let path = fresh_db("settings");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    assert!(store.settings().new_tab_row_shown);
    assert!(!records(&path).iter().any(|(kind, _, _)| kind == "settings"));
    store.set_new_tab_row_shown("one".into(), false).unwrap();
    assert!(!store.settings().new_tab_row_shown);
    assert_eq!(records(&path).iter().filter(|(kind, _, _)| kind == "settings").count(), 1);
    drop(store);
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    assert!(!store.settings().new_tab_row_shown);
    store.set_new_tab_row_shown("one".into(), true).unwrap();
    assert!(store.settings().new_tab_row_shown);
    drop(store);
    // Back at the built-in value, no row restates it; both writes reached the synced journal.
    assert!(!records(&path).iter().any(|(kind, _, _)| kind == "settings"));
    let conn = Connection::open(&path).unwrap();
    let journalled: i64 = conn.query_row("SELECT count(*) FROM journal WHERE kind = 'settings'", [], |row| row.get(0)).unwrap();
    assert_eq!(journalled, 2);
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
}

// Design's review-1 decision 3: selection ignores the section's collapse, so the candidates
// are the space's rows as if the section were open; the holder rule then keeps the chosen
// pin visible.
#[test]
fn choosing_a_row_ignores_the_sections_collapse() {
    let path = fresh_db("section-selection");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    let imported = store.import_arc_sidebar("one".into(), FIXTURE.into(), None, None, None, None).unwrap().snapshot;
    assert_eq!(imported.spaces[0].today_count, 0);
    store.select_item("one".into(), "tab-mail".into()).unwrap();
    store.set_section_collapsed("one".into(), "space-work".into(), true).unwrap();
    // A link routed to a pin under the collapsed section selects it and the pin shows.
    let routed = store.show_space_selecting_tab("one".into(), "space-work".into(), "tab-spec".into()).unwrap();
    assert_eq!(routed.selected_id.as_deref(), Some("tab-spec"));
    assert_eq!(routed.spaces[0].pinned.iter().map(|row| row.id.as_str()).collect::<Vec<_>>(),
        ["folder-docs", "tab-spec"]);
    // Switching to the space with an empty Today keeps a selection instead of clearing it.
    store.show_space("one".into(), "space-home".into()).unwrap();
    let back = store.show_space_selecting("one".into(), "space-work".into()).unwrap();
    let selected = back.selected_id.expect("a pin stays selected");
    assert!(back.spaces[0].pinned.iter().any(|row| row.id == selected));
    drop(store);
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
}

// Review 1, 6b: the section record names the space, so deleting the space deletes it.
#[test]
fn deleting_a_space_removes_its_section_record() {
    let path = fresh_db("section-delete");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("one".into(), FIXTURE.into(), None, None, None, None).unwrap();
    store.set_section_collapsed("one".into(), "space-work".into(), true).unwrap();
    assert!(store.section_collapsed("space-work".into()));
    store.delete_space("one".into(), "space-work".into()).unwrap();
    assert!(!store.section_collapsed("space-work".into()));
    assert!(!records(&path).iter().any(|(kind, id, _)| kind == "section_state" && id == "space-work"));
    drop(store);
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    assert!(!store.section_collapsed("space-work".into()));
    assert!(!records(&path).iter().any(|(kind, _, _)| kind == "section_state"));
    drop(store);
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
}

// Design's review-1 decision 3 as review 2 read it: choosing a row ignores collapse, closed
// folders included.
#[test]
fn choosing_a_row_ignores_a_closed_folder() {
    let path = fresh_db("folder-selection");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("one".into(), FIXTURE.into(), None, None, None, None).unwrap();
    store.select_item("one".into(), "tab-mail".into()).unwrap();
    store.set_folder_collapsed("one".into(), "folder-docs".into(), true).unwrap();
    // A link routed to a pin inside the closed folder selects it. Selecting a hidden row
    // opens its ancestors (the existing rule), so the folder shows open with its pin.
    let routed = store.show_space_selecting_tab("one".into(), "space-work".into(), "tab-spec".into()).unwrap();
    assert_eq!(routed.selected_id.as_deref(), Some("tab-spec"));
    let folder = routed.spaces[0].pinned.iter().find(|row| row.id == "folder-docs").unwrap();
    assert!(!folder.collapsed);
    assert!(routed.spaces[0].pinned.iter().any(|row| row.id == "tab-spec"));
    // A space switch keeps a last selection inside a closed folder without opening it: the
    // pin's row is there while its folder is still collapsed, so only the path shows it.
    store.set_folder_collapsed("one".into(), "folder-docs".into(), true).unwrap();
    store.show_space("one".into(), "space-home".into()).unwrap();
    let back = store.show_space_selecting("one".into(), "space-work".into()).unwrap();
    assert_eq!(back.selected_id.as_deref(), Some("tab-spec"));
    let pinned = &back.spaces[0].pinned;
    assert!(pinned.iter().find(|row| row.id == "folder-docs").unwrap().collapsed);
    assert!(pinned.iter().any(|row| row.id == "tab-spec"));
    drop(store);
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
}

#[test]
fn privacy_mismatch_is_an_error_before_any_state_or_revision_changes() {
    let path = fresh_db("privacy-contract");
    let store = WorkspaceStore::open(path.display().to_string()).unwrap();
    store.import_arc_sidebar("test".into(), today_fixture(), None, None, None, None).unwrap();
    let before = store.snapshot("test".into());
    let db = Connection::open(&path).unwrap();
    let journal_before: i64 = db.query_row("SELECT count(*) FROM journal", [], |row| row.get(0)).unwrap();
    let tab = LiveTab { off_the_record: true, profile: Profile::Default, live_id: "private".into(), item: None, opener: None, navigated: true, url: Some("https://private.example/".into()), title: None };
    let mut tx = LiveTransaction { off_the_record: false, epoch: 1, rev: 0, cause: LiveCause::Chrome, strips: vec![LiveStrip { window: "test".into(), tabs: vec![tab], active: Some("private".into()) }] };
    assert!(matches!(store.live_apply(tx.clone()), Err(CoreError::Live { .. })));
    tx.off_the_record = true;
    assert!(matches!(store.live_apply(tx.clone()), Err(CoreError::Live { .. })));
    assert_eq!(store.snapshot("test".into()), before);
    assert_eq!(db.query_row("SELECT count(*) FROM journal", [], |row| row.get::<_, i64>(0)).unwrap(), journal_before);
    tx.off_the_record = false;
    tx.strips[0].tabs[0].off_the_record = false;
    assert!(store.live_apply(tx).unwrap().applied);
    let expected = store.snapshot("test".into());
    drop(store);
    assert_eq!(WorkspaceStore::open(path.display().to_string()).unwrap().snapshot("test".into()), expected);
}
