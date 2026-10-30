use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

use ararat_core::import::arc_sidebar;
use ararat_core::model::{Kind, Op, Record, Workspace};
use ararat_core::storage::{BATCH_WINDOW, Store};
use rusqlite::Connection;

const FIXTURE: &str = include_str!("fixtures/arc-sidebar-synthetic.json");

fn fresh_db(name: &str) -> PathBuf {
    let path = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(format!("{name}.sqlite"));
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
    path
}

fn imported() -> Workspace {
    arc_sidebar(FIXTURE).unwrap()
}

fn count(path: &PathBuf) -> i64 {
    let conn = Connection::open(path).unwrap();
    conn.query_row("SELECT count(*) FROM records", [], |r| r.get(0)).unwrap()
}

// The property crash safety rests on: replaying the journal from empty gives the records table.
fn assert_journal_matches_records(path: &PathBuf) {
    let conn = Connection::open(path).unwrap();
    let mut records = BTreeMap::new();
    let mut stmt = conn.prepare("SELECT kind, id, body FROM records").unwrap();
    let mut rows = stmt.query([]).unwrap();
    while let Some(r) = rows.next().unwrap() {
        records.insert((r.get::<_, String>(0).unwrap(), r.get::<_, String>(1).unwrap()), r.get::<_, String>(2).unwrap());
    }
    let mut replayed = BTreeMap::new();
    let mut stmt = conn.prepare("SELECT kind, id, body FROM journal ORDER BY seq").unwrap();
    let mut rows = stmt.query([]).unwrap();
    while let Some(r) = rows.next().unwrap() {
        let key = (r.get::<_, String>(0).unwrap(), r.get::<_, String>(1).unwrap());
        match r.get::<_, Option<String>>(2).unwrap() {
            Some(body) => replayed.insert(key, body),
            None => replayed.remove(&key),
        };
    }
    assert_eq!(records, replayed);
}

#[test]
fn reopening_restores_the_imported_workspace() {
    let path = fresh_db("round-trip");
    let ws = imported();
    {
        let (store, empty) = Store::open(&path).unwrap();
        assert_eq!(empty, Workspace::default());
        store.write(ws.to_ops());
        store.flush().unwrap();
    }
    let (_store, reopened) = Store::open(&path).unwrap();
    assert_eq!(reopened, ws);
    assert_journal_matches_records(&path);
}

#[test]
fn moves_and_deletes_reach_disk_as_in_memory() {
    let path = fresh_db("moves");
    let mut ws = imported();
    let (store, _) = Store::open(&path).unwrap();
    store.write(ws.to_ops());

    let mut spec = ws.items["tab-spec"].clone();
    spec.membership.parent = Some("today-work".into());
    let edits = vec![Op::Put(Record::Item(spec)), Op::Delete(Kind::Item, "tab-a".into())];
    for op in &edits {
        ws.apply(op);
    }
    store.write(edits);
    store.flush().unwrap();
    drop(store);

    let (_store, reopened) = Store::open(&path).unwrap();
    assert_eq!(reopened, ws);
    assert!(!reopened.items.contains_key("tab-a"));
    assert_journal_matches_records(&path);
}

#[test]
fn writes_commit_within_the_batch_window_without_a_flush() {
    let path = fresh_db("window");
    let (store, _) = Store::open(&path).unwrap();
    store.write(imported().to_ops());
    assert_eq!(count(&path), 0);
    std::thread::sleep(BATCH_WINDOW + Duration::from_millis(500));
    assert!(count(&path) > 0);
}

#[test]
fn a_failed_commit_keeps_the_batch_and_reports_it() {
    let path = fresh_db("busy");
    let (store, _) = Store::open(&path).unwrap();
    let blocker = Connection::open(&path).unwrap();
    blocker.execute_batch("BEGIN IMMEDIATE").unwrap();

    store.write(imported().to_ops());
    assert!(store.flush().is_err());
    assert!(store.last_error().is_some());

    blocker.execute_batch("ROLLBACK").unwrap();
    store.flush().unwrap();
    assert_eq!(store.last_error(), None);
    drop(store);
    assert_eq!(Store::open(&path).unwrap().1, imported());
}

#[test]
fn rows_of_unknown_kinds_survive() {
    let path = fresh_db("unknown");
    drop(Store::open(&path).unwrap());
    Connection::open(&path)
        .unwrap()
        .execute("INSERT INTO records (kind, id, body) VALUES ('from-the-future', 'x', '{}')", [])
        .unwrap();
    let (store, ws) = Store::open(&path).unwrap();
    assert_eq!(ws, Workspace::default());
    store.write(imported().to_ops());
    store.flush().unwrap();
    let conn = Connection::open(&path).unwrap();
    let kept: i64 = conn
        .query_row("SELECT count(*) FROM records WHERE kind = 'from-the-future'", [], |r| r.get(0))
        .unwrap();
    assert_eq!(kept, 1);
}

const CRASH_DB: &str = "ARARAT_CRASH_DB";

// Runs as a no-op in the normal test run; `killed_process_keeps_every_flushed_batch` starts it
// in a child process that aborts with a batch still unflushed.
#[test]
fn crash_child() {
    let Ok(path) = std::env::var(CRASH_DB) else { return };
    let (store, _) = Store::open(PathBuf::from(path).as_path()).unwrap();
    store.write(imported().to_ops());
    store.flush().unwrap();
    store.write(vec![Op::Delete(Kind::Item, "tab-spec".into())]);
    std::process::abort();
}

#[test]
fn killed_process_keeps_every_flushed_batch() {
    let path = fresh_db("crash");
    let status = Command::new(std::env::current_exe().unwrap())
        .args(["crash_child", "--exact", "--nocapture"])
        .env(CRASH_DB, &path)
        .status()
        .unwrap();
    assert!(!status.success(), "the child should have aborted");

    let (_store, reopened) = Store::open(&path).unwrap();
    assert_eq!(reopened, imported());
    assert_journal_matches_records(&path);
}
