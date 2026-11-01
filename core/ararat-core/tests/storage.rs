use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};

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

// Why not replay local selection: it is deliberately absent from the sync journal.
fn assert_journal_matches_records(path: &PathBuf) {
    let conn = Connection::open(path).unwrap();
    let mut records = BTreeMap::new();
    let mut stmt = conn.prepare("SELECT kind, id, body FROM records WHERE kind != 'window'").unwrap();
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
fn steady_writes_still_commit_within_the_batch_window() {
    let path = fresh_db("steady");
    let (store, _) = Store::open(&path).unwrap();
    let ops = imported().to_ops();
    let start = Instant::now();
    let mut committed_while_writing = false;
    while start.elapsed() < BATCH_WINDOW * 3 {
        store.write(ops.clone());
        std::thread::sleep(Duration::from_millis(5));
        if start.elapsed() > BATCH_WINDOW + Duration::from_millis(500) && count(&path) > 0 {
            committed_while_writing = true;
            break;
        }
    }
    assert!(committed_while_writing);
}

#[test]
fn a_failed_commit_is_retried_without_a_flush() {
    let path = fresh_db("retry");
    let (store, _) = Store::open(&path).unwrap();
    let blocker = Connection::open(&path).unwrap();
    blocker.execute_batch("BEGIN IMMEDIATE").unwrap();
    store.write(imported().to_ops());
    std::thread::sleep(BATCH_WINDOW + Duration::from_millis(500));
    assert!(store.last_error().is_some());
    assert_eq!(count(&path), 0);

    blocker.execute_batch("ROLLBACK").unwrap();
    // The first retry is due one BATCH_WINDOW after the failure, the next two after that.
    std::thread::sleep(BATCH_WINDOW * 3 + Duration::from_millis(500));
    assert!(count(&path) > 0);
    assert_eq!(store.last_error(), None);
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
const CHURN_DB: &str = "ARARAT_CHURN_DB";

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

// Runs as a no-op in the normal test run; `kills_during_a_stream_of_commits_leave_journal_and_records_agreeing`
// starts it and kills it at varying times while large batches are being committed.
#[test]
fn churn_child() {
    let Ok(path) = std::env::var(CHURN_DB) else { return };
    let (store, _) = Store::open(PathBuf::from(path).as_path()).unwrap();
    let mut ws = imported();
    for round in 0.. {
        let ops: Vec<Op> = ws.items.values().cloned().map(|mut item| {
            item.title = Some(format!("round {round}"));
            Op::Put(Record::Item(item))
        }).collect();
        for op in &ops {
            ws.apply(op);
        }
        for _ in 0..50 {
            store.write(ops.clone());
        }
        store.flush().unwrap();
        if round == 0 {
            println!("ready");
        }
    }
}

// Why not a hook that aborts between the record writes and COMMIT: it would put test-only code in
// the writer. This is stress coverage: kills after the first commit, while large commits follow one
// another, usually land inside one, but no run is guaranteed to.
#[test]
fn kills_during_a_stream_of_commits_leave_journal_and_records_agreeing() {
    let path = fresh_db("churn");
    for delay in [3, 11, 23, 37, 53, 71] {
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args(["churn_child", "--exact", "--nocapture"])
            .env(CHURN_DB, &path)
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let mut out = std::io::BufReader::new(child.stdout.take().unwrap());
        let mut line = String::new();
        while !line.contains("ready") {
            line.clear();
            assert!(std::io::BufRead::read_line(&mut out, &mut line).unwrap() > 0, "child ended early");
        }
        std::thread::sleep(Duration::from_millis(delay));
        child.kill().unwrap();
        child.wait().unwrap();
        Store::open(&path).unwrap();
        assert!(count(&path) > 0);
        assert_journal_matches_records(&path);
    }
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

#[test]
fn selection_is_local_and_persists_in_existing_records() {
    let path = fresh_db("local-selection");
    let (store, _) = Store::open(&path).unwrap();
    let mut ws = imported(); store.write(ws.to_ops()); store.flush().unwrap();
    let conn = Connection::open(&path).unwrap();
    let journal_count = || conn.query_row("SELECT count(*) FROM journal", [], |r| r.get::<_, i64>(0)).unwrap();
    let before = journal_count();
    for id in ["tab-spec", "tab-a", "split-1"] { store.write(ws.select_item("test", id).unwrap()); }
    store.flush().unwrap();
    assert_eq!(journal_count(), before);
    assert_eq!(conn.query_row("SELECT count(*) FROM journal WHERE kind = 'window'", [], |r| r.get::<_, i64>(0)).unwrap(), 0);
    drop(store);
    assert_eq!(Store::open(&path).unwrap().1.selected("test"), Some("split-1"));
}

#[test]
fn old_item_errors_name_the_record_and_explain_the_lifecycle_format() {
    let path = fresh_db("old-lifecycle");
    drop(Store::open(&path).unwrap());
    let mut item = serde_json::to_value(&imported().items["tab-spec"]).unwrap();
    item.as_object_mut().unwrap().remove("lifecycle");
    item.as_object_mut().unwrap().remove("collapsed");
    Connection::open(&path).unwrap().execute("INSERT INTO records (kind, id, body) VALUES ('item', 'tab-spec', ?1)", [item.to_string()]).unwrap();
    let error = Store::open(&path).err().unwrap().0;
    assert!(error.contains("record item/tab-spec"), "{error}");
    assert!(error.contains("this database predates lifecycle; delete it or re-import"), "{error}");
}
