// Why not store local window state separately: lifecycle and selection must commit together,
// while only synced records enter the journal (architecture 5.2).

use std::path::Path;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use rusqlite::{Connection, TransactionBehavior, params};

use crate::model::{Kind, Op, Record, Workspace};

pub const BATCH_WINDOW: Duration = Duration::from_secs(1);
const MAX_BACKOFF: Duration = Duration::from_secs(30);
const BUSY_TIMEOUT: Duration = Duration::from_millis(200);

// Why not one column per field: kinds written by a newer version must survive an older one
// untouched (architecture 8.3), and an opaque body table keeps rows it cannot read.
// shortcut: the journal is never trimmed; trim it once the sync client acknowledges uploads (phase 8).
const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS records (
    kind TEXT NOT NULL,
    id TEXT NOT NULL,
    body TEXT NOT NULL,
    PRIMARY KEY (kind, id)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS journal (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,
    id TEXT NOT NULL,
    body TEXT
);
";

#[derive(Debug, PartialEq, Eq)]
pub struct StoreError(pub String);

impl From<rusqlite::Error> for StoreError {
    fn from(e: rusqlite::Error) -> Self {
        StoreError(e.to_string())
    }
}

impl From<serde_json::Error> for StoreError {
    fn from(e: serde_json::Error) -> Self {
        StoreError(e.to_string())
    }
}

impl From<std::io::Error> for StoreError {
    fn from(e: std::io::Error) -> Self {
        StoreError(e.to_string())
    }
}

enum Msg {
    Write(Vec<Op>),
    Flush(Sender<Result<(), StoreError>>),
}

pub struct Store {
    tx: Option<Sender<Msg>>,
    error: Arc<Mutex<Option<String>>>,
    writer: Option<JoinHandle<()>>,
}

impl Store {
    pub fn open(path: &Path) -> Result<(Store, Workspace), StoreError> {
        let conn = Connection::open(path)?;
        let version: i64 = conn.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        let existing: bool = conn.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name = 'records')", [], |row| row.get(0))?;
        if version != 1 && (version != 0 || existing) { return Err(StoreError("unsupported database version; use a new database".into())); }
        let mode: String = conn.query_row("PRAGMA journal_mode = WAL", [], |r| r.get(0))?;
        if mode != "wal" {
            return Err(StoreError(format!("journal_mode is {mode}, not wal")));
        }
        // FULL rather than NORMAL: it also survives power loss, at one fsync per batch.
        conn.execute_batch("PRAGMA synchronous = FULL;")?;
        conn.execute_batch(SCHEMA)?;
        if version == 0 { conn.pragma_update(None, "user_version", 1)?; }
        conn.busy_timeout(BUSY_TIMEOUT)?;
        let workspace = load(&conn)?;

        let (tx, rx) = mpsc::channel();
        let error = Arc::new(Mutex::new(None));
        let writer = {
            let error = error.clone();
            thread::Builder::new().name("ararat-storage".into()).spawn(move || run(conn, rx, &error))?
        };
        Ok((Store { tx: Some(tx), error, writer: Some(writer) }, workspace))
    }

    // Returns at once; the ops are committed within BATCH_WINDOW, or retried until they are.
    pub fn write(&self, ops: Vec<Op>) {
        self.send(Msg::Write(ops));
    }

    // On failure the batch stays queued for the next retry; nothing is dropped.
    pub fn flush(&self) -> Result<(), StoreError> {
        let (ack, done) = mpsc::channel();
        self.send(Msg::Flush(ack));
        done.recv().expect("storage writer stopped")
    }

    // The last failed commit, cleared by the next successful one. The adapter shows it to the user.
    pub fn last_error(&self) -> Option<String> {
        self.error.lock().unwrap().clone()
    }

    fn send(&self, msg: Msg) {
        self.tx.as_ref().unwrap().send(msg).expect("storage writer stopped");
    }
}

// The quit path calls flush() and reports its error first: drop makes one last attempt and
// cannot tell anyone if it fails.
impl Drop for Store {
    fn drop(&mut self) {
        drop(self.tx.take());
        if let Some(writer) = self.writer.take() {
            let _ = writer.join();
        }
    }
}

fn load(conn: &Connection) -> Result<Workspace, StoreError> {
    let mut workspace = Workspace::default();
    let mut stmt = conn.prepare("SELECT kind, id, body FROM records")?;
    let mut rows = stmt.query([])?;
    while let Some(row) = rows.next()? {
        let (kind, id, body): (String, String, String) = (row.get(0)?, row.get(1)?, row.get(2)?);
        let Some(kind) = Kind::parse(&kind) else { continue };
        let record = Record::parse(kind, &id, &body).map_err(|error| {
            let predates_lifecycle = kind == Kind::Item && serde_json::from_str::<serde_json::Value>(&body)
                .is_ok_and(|value| value.is_object() && value.get("lifecycle").is_none());
            let cause = if predates_lifecycle {
                "this database predates lifecycle; delete it or re-import".to_string()
            } else { error.to_string() };
            StoreError(format!("record {}/{id}: {cause}", kind.as_str()))
        })?;
        workspace.apply(&Op::Put(record));
    }
    Ok(workspace)
}

// The deadline counts from the first unflushed op and later writes do not move it, so steady
// editing still commits every BATCH_WINDOW.
fn run(mut conn: Connection, rx: Receiver<Msg>, error: &Mutex<Option<String>>) {
    let mut pending = Vec::new();
    let mut due: Option<Instant> = None;
    let mut backoff = BATCH_WINDOW;
    loop {
        let msg = match due {
            None => rx.recv().map_err(|_| RecvTimeoutError::Disconnected),
            // Checked before receiving: with writes still queued, recv_timeout would keep
            // returning them and the commit would never come due.
            Some(due) if Instant::now() >= due => Err(RecvTimeoutError::Timeout),
            Some(due) => rx.recv_timeout(due.saturating_duration_since(Instant::now())),
        };
        let result = match msg {
            Ok(Msg::Write(ops)) => {
                pending.extend(ops);
                due.get_or_insert_with(|| Instant::now() + BATCH_WINDOW);
                continue;
            }
            Ok(Msg::Flush(ack)) => {
                let result = commit(&mut conn, &mut pending, error);
                let ok = result.is_ok();
                let _ = ack.send(result);
                ok
            }
            Err(RecvTimeoutError::Timeout) => commit(&mut conn, &mut pending, error).is_ok(),
            Err(RecvTimeoutError::Disconnected) => {
                let _ = commit(&mut conn, &mut pending, error);
                return;
            }
        };
        if result {
            due = None;
            backoff = BATCH_WINDOW;
        } else {
            due = Some(Instant::now() + backoff);
            backoff = (backoff * 2).min(MAX_BACKOFF);
        }
    }
}

fn commit(conn: &mut Connection, pending: &mut Vec<Op>, error: &Mutex<Option<String>>) -> Result<(), StoreError> {
    if pending.is_empty() {
        return Ok(());
    }
    let result = write_batch(conn, pending);
    *error.lock().unwrap() = result.as_ref().err().map(|e| e.0.clone());
    if result.is_ok() {
        pending.clear();
    }
    result
}

fn write_batch(conn: &mut Connection, ops: &[Op]) -> Result<(), StoreError> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    {
        let mut put = tx.prepare_cached("INSERT OR REPLACE INTO records (kind, id, body) VALUES (?1, ?2, ?3)")?;
        let mut delete = tx.prepare_cached("DELETE FROM records WHERE kind = ?1 AND id = ?2")?;
        let mut journal = tx.prepare_cached("INSERT INTO journal (kind, id, body) VALUES (?1, ?2, ?3)")?;
        for op in ops {
            let (kind, id, body) = match op {
                Op::Put(record) => (record.kind(), record.id(), Some(record.body())),
                Op::Delete(kind, id) => (*kind, id.clone(), None),
            };
            match &body {
                Some(body) => put.execute(params![kind.as_str(), id, body])?,
                None => delete.execute(params![kind.as_str(), id])?,
            };
            if !matches!(kind, Kind::Window | Kind::LastSelected | Kind::FolderState | Kind::SectionState | Kind::HistoryPurge | Kind::HistoryProfile) {
                journal.execute(params![kind.as_str(), id, body])?;
            }
        }
    }
    tx.commit()?;
    Ok(())
}
