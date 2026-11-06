// The live-tab coordinator (architecture 5.1/5.2). Each test names what it checks; P2,
// P3, P4, P5, P7 and P8 are review 1's probe cases.

use ararat_core::live::{Cause, CommandKind, Live, LiveTab, Strip, Transaction};
use ararat_core::model::{Item, ItemKind, Lifecycle, Membership, Op, Record, Workspace};
use ararat_core::storage::Store;

fn tab(ws: &mut Workspace, id: &str, parent: &str, url: &str) {
    ws.items.insert(id.into(), Item {
        id: id.into(),
        membership: Membership { parent: Some(parent.into()), order: id.into(), hlc: Default::default(), previous_parent: None },
        title: None,
        kind: ItemKind::Tab { url: url.into(), saved_title: None },
        lifecycle: Lifecycle::Open,
        lifecycle_changed_at: 0,
    });
}

// One space (space-work: pin-work / today-work) and four tabs; no windows yet, so the
// shown space falls back to space-work.
fn workspace() -> Workspace {
    let mut ws = Workspace::default();
    for op in ws.create_space("one", "Work", "space-work").unwrap() { ws.apply(&op); }
    tab(&mut ws, "a", "space-work:today", "https://a.example");
    tab(&mut ws, "b", "space-work:today", "https://b.example");
    tab(&mut ws, "c", "space-work:today", "https://c.example");
    tab(&mut ws, "pinned", "space-work:pinned", "https://pinned.example");
    ws
}

fn strip(live: &Live, tabs: &[&str], active: Option<&str>) -> Strip {
    Strip {
        window: "one".into(),
        tabs: tabs.iter().map(|item| LiveTab { live_id: live.live_tab(item).expect("mapped"), item: Some((*item).into()) }).collect(),
        active: active.map(|item| live.live_tab(item).expect("mapped")),
    }
}

fn strip_empty(window: &str) -> Strip {
    Strip { window: window.into(), tabs: vec![], active: None }
}

#[test]
fn replaying_the_same_active_strip_preserves_workspace_rows() {
    let mut ws = workspace();
    let mut live = Live::new();
    let (_, command) = live.open(&mut ws, "a", "u").unwrap();
    live.command_sent(&command);
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a"], Some("a"))]));
    let before = ws.clone();
    let (ops, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![strip(&live, &["a"], Some("a"))],
    });
    assert!(outcome.applied);
    assert!(ops.is_empty());
    assert_eq!(ws, before);
}

#[test]
fn leaving_a_tab_after_thirteen_hours_keeps_it_out_of_the_next_archive_tick() {
    let mut ws = workspace();
    let mut live = Live::new();
    for item in ["a", "b"] {
        let (_, command) = live.open(&mut ws, item, "u").unwrap();
        live.command_sent(&command);
    }
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a", "b"], Some("a"))]));
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64;
    ws.last_selected.insert("a".into(), now - 13 * 3_600_000);
    let (ops, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![strip(&live, &["a", "b"], Some("b"))],
    });
    assert!(outcome.applied);
    let left_at = ws.last_selected["a"];
    assert!(left_at >= now);
    assert_eq!(ops.iter().filter(|op| matches!(op, Op::Put(Record::LastSelected { item, .. }) if item == "a")).count(), 1);
    ws.auto_archive(left_at + 60_000).unwrap();
    assert_eq!(ws.items["a"].lifecycle, Lifecycle::Open);
}

#[test]
fn background_open_and_reorder_do_not_restamp_the_active_tab() {
    let mut ws = workspace();
    let mut live = Live::new();
    let (_, first) = live.open(&mut ws, "a", "u").unwrap();
    live.command_sent(&first);
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a"], Some("a"))]));
    ws.last_selected.insert("a".into(), 100);
    let (_, second) = live.open(&mut ws, "b", "u").unwrap();
    live.command_sent(&second);
    let (opened, _) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Command(second.id),
        strips: vec![strip(&live, &["a", "b"], Some("a"))],
    });
    let (reordered, _) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 2, cause: Cause::Chrome,
        strips: vec![strip(&live, &["b", "a"], Some("a"))],
    });
    assert_eq!(ws.last_selected["a"], 100);
    assert!(!opened.iter().chain(&reordered).any(|op| matches!(op, Op::Put(Record::LastSelected { item, .. }) if item == "a")));
}

#[test]
fn a_selection_recorded_before_the_strip_stamps_the_outgoing_tab_only_once() {
    let mut ws = workspace();
    let mut live = Live::new();
    for item in ["a", "b"] {
        let (_, command) = live.open(&mut ws, item, "u").unwrap();
        live.command_sent(&command);
    }
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a", "b"], Some("a"))]));
    let selection = ws.select_item_at("one", "b", 123).unwrap();
    assert_eq!(ws.last_selected["a"], 123);
    assert_eq!(selection.iter().filter(|op| matches!(op, Op::Put(Record::LastSelected { item, .. }) if item == "a")).count(), 1);
    let before = ws.clone();
    let (ops, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![strip(&live, &["a", "b"], Some("b"))],
    });
    assert!(outcome.applied);
    assert!(ops.is_empty());
    assert_eq!(ws, before);
}

#[test]
fn reporting_a_selected_unloaded_tab_as_live_marks_it_open() {
    let mut ws = workspace();
    let mut live = Live::new();
    let (_, command) = live.open(&mut ws, "a", "u").unwrap();
    live.command_sent(&command);
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a"], Some("a"))]));
    ws.items.get_mut("a").unwrap().lifecycle = Lifecycle::Unloaded;
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![strip(&live, &["a"], Some("a"))],
    });
    assert!(outcome.applied);
    assert_eq!(ws.items["a"].lifecycle, Lifecycle::Open);
}

#[test]
fn snapshot_close_for_archived_tab_accepts_its_completion() {
    let mut ws = workspace();
    ws.items.get_mut("a").unwrap().lifecycle = Lifecycle::Archived;
    let mut live = Live::new();
    let (_, snapshot) = live.apply(&mut ws, snapshot_tx(vec![Strip {
        window: "one".into(),
        tabs: vec![LiveTab { live_id: "engine-a".into(), item: Some("a".into()) }],
        active: None,
    }]));
    assert!(snapshot.applied);
    assert_eq!(snapshot.commands.len(), 1);
    assert_eq!(snapshot.commands[0].kind, CommandKind::Close);
    let (_, completion) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Command(snapshot.commands[0].id.clone()),
        strips: vec![strip_empty("one")],
    });
    assert!(completion.applied);
}

#[test]
fn within_epoch_close_for_archived_tab_accepts_its_completion() {
    let mut ws = workspace();
    let mut live = Live::new();
    live.apply(&mut ws, snapshot_tx(vec![]));
    ws.items.get_mut("a").unwrap().lifecycle = Lifecycle::Archived;
    let (_, changed) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Engine,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![LiveTab { live_id: "engine-a".into(), item: Some("a".into()) }],
            active: None,
        }],
    });
    assert_eq!(changed.commands.len(), 1);
    assert_eq!(changed.commands[0].kind, CommandKind::Close);
    let (_, completion) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 2, cause: Cause::Command(changed.commands[0].id.clone()),
        strips: vec![strip_empty("one")],
    });
    assert!(completion.applied);
}

#[test]
fn completed_open_and_close_allow_reopening() {
    let mut ws = workspace();
    let mut live = Live::new();
    live.apply(&mut ws, snapshot_tx(vec![]));
    let (_, open) = live.open(&mut ws, "pinned", "u").unwrap();
    live.command_sent(&open);
    let (_, opened) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Command(open.id.clone()),
        strips: vec![strip(&live, &["pinned"], Some("pinned"))],
    });
    assert!(opened.applied);
    let (_, close) = live.close(&mut ws, "pinned").unwrap();
    live.command_sent(&close);
    let (_, closed) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 2, cause: Cause::Command(close.id),
        strips: vec![strip_empty("one")],
    });
    assert!(closed.applied);
    assert!(live.open(&mut ws, "pinned", "u").is_ok());
}

#[test]
fn failed_open_clears_its_mapping_and_can_be_retried() {
    let mut ws = workspace();
    let mut live = Live::new();
    live.apply(&mut ws, snapshot_tx(vec![]));
    let (_, command) = live.open(&mut ws, "a", "u").unwrap();
    live.command_sent(&command);
    let lifecycle = ws.items["a"].lifecycle.clone();
    let (ops, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Command(command.id.clone()),
        strips: vec![strip_empty("one")],
    });
    assert!(outcome.applied);
    assert!(ops.is_empty());
    assert_eq!(live.live_tab("a"), None);
    assert_eq!(live.item_for(&command.id), None);
    assert_eq!(ws.items["a"].lifecycle, lifecycle);
    assert!(live.open(&mut ws, "a", "u").is_ok());
    let (_, duplicate) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 2, cause: Cause::Command(command.id), strips: vec![],
    });
    assert!(!duplicate.applied);
}

#[test]
fn rejected_open_can_be_cancelled_without_changing_lifecycle() {
    let mut ws = workspace();
    let mut live = Live::new();
    live.apply(&mut ws, snapshot_tx(vec![]));
    let (_, command) = live.open(&mut ws, "a", "u").unwrap();
    live.command_sent(&command);
    let lifecycle = ws.items["a"].lifecycle.clone();
    assert!(!live.cancel("unknown"));
    assert_eq!(live.live_tab("a").as_deref(), Some(command.id.as_str()));
    assert_eq!(live.item_for(&command.id).as_deref(), Some("a"));
    assert_eq!(ws.items["a"].lifecycle, lifecycle);
    assert!(live.cancel(&command.id));
    assert!(!live.cancel(&command.id));
    assert_eq!(live.live_tab("a"), None);
    assert_eq!(live.item_for(&command.id), None);
    assert_eq!(ws.items["a"].lifecycle, lifecycle);
    assert!(live.open(&mut ws, "a", "u").is_ok());
}

#[test]
fn cancelling_a_pending_activation_leaves_it_in_flight() {
    let mut ws = workspace();
    let mut live = Live::new();
    live.apply(&mut ws, snapshot_tx(vec![]));
    let (_, open) = live.open(&mut ws, "a", "u").unwrap();
    live.command_sent(&open);
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Command(open.id.clone()),
        strips: vec![strip(&live, &["a"], Some("a"))],
    });
    assert!(outcome.applied);
    let activate = live.activate(&ws, "a").unwrap();
    live.command_sent(&activate);
    assert!(!live.cancel(&activate.id));
    assert_eq!(live.live_tab("a").as_deref(), Some(open.id.as_str()));
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 2, cause: Cause::Command(activate.id),
        strips: vec![strip(&live, &["a"], Some("a"))],
    });
    assert!(outcome.applied);
}

#[test]
fn archiving_a_live_tab_returns_a_close_and_keeps_the_row_archived() {
    let mut ws = workspace();
    let mut live = Live::new();
    live.apply(&mut ws, snapshot_tx(vec![]));
    let (_, open) = live.open(&mut ws, "a", "u").unwrap();
    live.command_sent(&open);
    let (_, close) = live.archive(&mut ws, "a").unwrap();
    assert_eq!(close.kind, CommandKind::Close);
    assert_eq!(ws.items["a"].lifecycle, Lifecycle::Archived);
    assert_eq!(live.live_tab("a"), None);
}

fn snapshot_tx(strips: Vec<Strip>) -> Transaction {
    Transaction { epoch: 1, rev: 0, cause: Cause::Engine, strips }
}

#[test]
fn open_issues_one_command_and_the_map_lands_when_the_command_is_sent() {
    let mut ws = workspace();
    let mut live = Live::new();
    let (ops, command) = live.open(&mut ws, "a", "https://a.example/").unwrap();
    // a is already open, so the command alone changes nothing in the workspace, and the
    // map waits for the flush to succeed (the FFI registers it then).
    assert!(ops.is_empty());
    assert_eq!(command.kind, CommandKind::Open);
    assert_eq!(command.item, "a");
    assert_eq!(command.url.as_deref(), Some("https://a.example/"));
    assert_eq!(live.live_tab("a"), None);
    live.command_sent(&command);
    assert_eq!(live.live_tab("a").as_deref(), Some(command.id.as_str()));
    assert_eq!(live.item_for(&command.id).as_deref(), Some("a"));
    // A second open of the same row is refused: the map holds at most one live tab per
    // item, and one may already be in flight.
    assert!(live.open(&mut ws, "a", "https://a.example/").is_err());
}

#[test]
fn open_marks_an_unloaded_row_open_in_the_same_transaction() {
    let mut ws = workspace();
    ws.items.get_mut("a").unwrap().lifecycle = Lifecycle::Unloaded;
    let mut live = Live::new();
    let (ops, command) = live.open(&mut ws, "a", "https://a.example/").unwrap();
    assert_eq!(command.kind, CommandKind::Open);
    assert_eq!(ops.len(), 1);
    for op in &ops { ws.apply(op); }
    assert_eq!(ws.items["a"].lifecycle, Lifecycle::Open);
    // The flip is one storage transaction beside the command: a reopened store reads it.
    let path = std::env::temp_dir().join(format!("ararat-live-open-{}.sqlite", std::process::id()));
    let _ = std::fs::remove_file(&path);
    let (store, _) = Store::open(&path).unwrap();
    store.write(ops);
    store.flush().unwrap();
    drop(store);
    let (store, loaded) = Store::open(&path).unwrap();
    assert_eq!(loaded.items["a"].lifecycle, Lifecycle::Open);
    drop(store);
    drop(loaded);
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
}

#[test]
fn chrome_activation_updates_the_windows_selection() {
    let mut ws = workspace();
    let mut live = Live::new();
    let (_, command_a) = live.open(&mut ws, "a", "u").unwrap();
    let (_, command_b) = live.open(&mut ws, "b", "u").unwrap();
    live.command_sent(&command_a);
    live.command_sent(&command_b);
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a", "b"], None)]));
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![strip(&live, &["a", "b"], Some("b"))],
    });
    assert!(outcome.applied);
    assert_eq!(ws.selected("one"), Some("b"));
    assert!(ws.windows["one"].history.contains(&"b".to_string()));
}

#[test]
fn chrome_close_of_the_active_tab_activates_the_successor_the_core_chooses() {
    let mut ws = workspace();
    let mut live = Live::new();
    for item in ["a", "b", "c"] {
        let (_, command) = live.open(&mut ws, item, "u").unwrap();
        live.command_sent(&command);
    }
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a", "b", "c"], Some("b"))]));
    // Chrome's own switches fill the selection history: c, then b.
    live.apply(&mut ws, Transaction { epoch: 1, rev: 1, cause: Cause::Chrome, strips: vec![strip(&live, &["a", "b", "c"], Some("c"))] });
    assert_eq!(ws.selected("one"), Some("c"));
    live.apply(&mut ws, Transaction { epoch: 1, rev: 2, cause: Cause::Chrome, strips: vec![strip(&live, &["a", "b", "c"], Some("b"))] });
    assert_eq!(ws.selected("one"), Some("b"));
    // Chrome closes b and moves to a; the history says c was selected before b, so the
    // coordinator returns an activate for c instead of trusting a.
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 3, cause: Cause::Chrome,
        strips: vec![strip(&live, &["a", "c"], Some("a"))],
    });
    assert!(outcome.applied);
    assert_eq!(outcome.commands.len(), 1);
    assert_eq!(outcome.commands[0].kind, CommandKind::Activate);
    assert_eq!(outcome.commands[0].item, "c");
    assert_eq!(ws.selected("one"), Some("c"));
    assert_eq!(ws.items["b"].lifecycle, Lifecycle::Closed);
    assert!(live.live_tab("b").is_none());
}

#[test]
fn a_chrome_close_of_a_background_tab_returns_no_activate() {
    let mut ws = workspace();
    let mut live = Live::new();
    for item in ["a", "b", "c"] {
        let (_, command) = live.open(&mut ws, item, "u").unwrap();
        live.command_sent(&command);
    }
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a", "b", "c"], Some("a"))]));
    // c is closed while a stays active: the selection did not change, so no activate is
    // returned and the window's active tab is recorded as before.
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![strip(&live, &["a", "b"], Some("a"))],
    });
    assert!(outcome.applied);
    assert!(outcome.commands.is_empty());
    assert_eq!(ws.selected("one"), Some("a"));
    assert_eq!(ws.items["c"].lifecycle, Lifecycle::Closed);
}

#[test]
fn a_stale_rev_or_old_epoch_is_dropped_and_counted() {
    let mut ws = workspace();
    let mut live = Live::new();
    let (_, command_a) = live.open(&mut ws, "a", "u").unwrap();
    live.command_sent(&command_a);
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a"], None)]));
    // a repeated rev is dropped
    let (_, outcome) = live.apply(&mut ws, Transaction { epoch: 1, rev: 0, cause: Cause::Chrome, strips: vec![strip(&live, &["a"], None)] });
    assert!(!outcome.applied);
    // rev 1 applies, rev 1 again is dropped
    let (_, outcome) = live.apply(&mut ws, Transaction { epoch: 1, rev: 1, cause: Cause::Chrome, strips: vec![strip(&live, &["a"], None)] });
    assert!(outcome.applied);
    let (_, outcome) = live.apply(&mut ws, Transaction { epoch: 1, rev: 1, cause: Cause::Chrome, strips: vec![strip(&live, &["a"], None)] });
    assert!(!outcome.applied);
    // a new epoch that does not arrive as a full snapshot is dropped
    let (_, outcome) = live.apply(&mut ws, Transaction { epoch: 2, rev: 7, cause: Cause::Chrome, strips: vec![strip(&live, &["a"], None)] });
    assert!(!outcome.applied);
    // the snapshot for the new epoch lands, and the old epoch is dropped after it
    let (_, outcome) = live.apply(&mut ws, Transaction { epoch: 2, rev: 0, cause: Cause::Chrome, strips: vec![] });
    assert!(outcome.applied);
    let (_, outcome) = live.apply(&mut ws, Transaction { epoch: 1, rev: 9, cause: Cause::Chrome, strips: vec![] });
    assert!(!outcome.applied);
    assert_eq!(live.dropped(), 4);
}

#[test]
fn a_completion_from_an_old_epoch_is_dropped_and_the_current_one_applies() {
    let mut ws = workspace();
    let mut live = Live::new();
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &[], None)]));
    let (_, command) = live.open(&mut ws, "a", "https://a.example/").unwrap();
    live.command_sent(&command);
    // The engine restarts; the snapshot for the new epoch carries no live tabs.
    live.apply(&mut ws, Transaction { epoch: 2, rev: 0, cause: Cause::Engine, strips: vec![] });
    // The completion still carries the epoch it was issued in: dropped.
    let (_, outcome) = live.apply(&mut ws, Transaction { epoch: 1, rev: 0, cause: Cause::Command(command.id.clone()), strips: vec![] });
    assert!(!outcome.applied);
    assert_eq!(live.dropped(), 1);
    // The map is gone with the epoch: the item is open in the workspace and unmapped, and
    // the next snapshot reconciles it (an open row missing in the engine becomes unloaded).
    assert!(live.live_tab("a").is_none());
}

#[test]
fn a_restart_snapshot_reconciles_the_architecture_five_two_cases() {
    let mut ws = workspace();
    let mut live = Live::new();
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &[], None)]));
    // a: open and in the engine (stays); b: open but missing from the engine (unloaded);
    // c: closed, and the engine still runs a tab for it (close command, never adopted);
    // pinned: open and in the engine; plus one engine tab with no item at all (adopted
    // into Today of the shown space).
    ws.items.get_mut("c").unwrap().lifecycle = Lifecycle::Closed;
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 2, rev: 0, cause: Cause::Engine,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![
                LiveTab { live_id: "live-a".into(), item: Some("a".into()) },
                LiveTab { live_id: "live-c".into(), item: Some("c".into()) },
                LiveTab { live_id: "live-pinned".into(), item: Some("pinned".into()) },
                LiveTab { live_id: "live-new".into(), item: None },
            ],
            active: Some("live-a".into()),
        }],
    });
    assert!(outcome.applied);
    // a stays mapped and open.
    assert_eq!(live.live_tab("a").as_deref(), Some("live-a"));
    assert_eq!(ws.items["a"].lifecycle, Lifecycle::Open);
    // b was open and is missing from the engine: unloaded.
    assert_eq!(ws.items["b"].lifecycle, Lifecycle::Unloaded);
    // c is closed in the workspace: its engine tab comes back as a close command.
    assert_eq!(outcome.commands.len(), 1);
    assert_eq!(outcome.commands[0].kind, CommandKind::Close);
    assert_eq!(outcome.commands[0].item, "c");
    assert!(live.live_tab("c").is_none() && live.item_for("live-c").is_none());
    // the itemless engine tab is adopted into Today of the shown space, in the same
    // transaction, reported as the pair the engine needs for the tab's session data, and
    // mapped.
    let (live_id, adopted) = outcome.adopted.first().expect("adopted pair").clone();
    assert_eq!(live_id, "live-new");
    let item = &ws.items[adopted.as_str()];
    assert!(matches!(item.kind, ItemKind::Tab { .. }));
    assert_eq!(item.lifecycle, Lifecycle::Open);
    assert_eq!(item.membership.parent.as_deref(), Some("space-work:today"));
    assert_eq!(live.live_tab(&adopted).as_deref(), Some("live-new"));
    assert_eq!(live.item_for("live-new").as_deref(), Some(adopted.as_str()));
    // pinned stays mapped and open.
    assert_eq!(live.live_tab("pinned").as_deref(), Some("live-pinned"));
    // the map is one to one.
    assert_eq!(live.live_tab("b"), None);
}

#[test]
fn close_of_a_pinned_item_unloads_keeps_the_row_and_persists() {
    let mut ws = workspace();
    let mut live = Live::new();
    let (_, open_command) = live.open(&mut ws, "pinned", "https://pinned.example").unwrap();
    live.command_sent(&open_command);
    let (ops, command) = live.close(&mut ws, "pinned").unwrap();
    for op in &ops { ws.apply(op); }
    assert_eq!(open_command.kind, CommandKind::Open);
    assert_eq!(command.kind, CommandKind::Close);
    assert_eq!(command.item, "pinned");
    // the ⌘W rule: a pinned row unloads and keeps its place.
    assert_eq!(ws.items["pinned"].lifecycle, Lifecycle::Unloaded);
    assert!(ws.outline("space-work:pinned").iter().any(|(_, item)| item.id == "pinned"));
    assert!(live.live_tab("pinned").is_none());
    // The lifecycle change rode one storage transaction with the command: a reopened
    // store reads it.
    let path = std::env::temp_dir().join(format!("ararat-live-close-{}.sqlite", std::process::id()));
    let _ = std::fs::remove_file(&path);
    let (store, _) = Store::open(&path).unwrap();
    store.write(ops);
    store.flush().unwrap();
    drop(store);
    let (store, loaded) = Store::open(&path).unwrap();
    assert_eq!(loaded.items["pinned"].lifecycle, Lifecycle::Unloaded);
    assert!(loaded.outline("space-work:pinned").iter().any(|(_, item)| item.id == "pinned"));
    drop(store);
    drop(loaded);
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
}

#[test]
fn a_transaction_that_reuses_a_live_id_is_dropped_and_the_map_stays_unique() {
    let mut ws = workspace();
    let mut live = Live::new();
    let (_, command_a) = live.open(&mut ws, "a", "u").unwrap();
    live.command_sent(&command_a);
    let (_, command_b) = live.open(&mut ws, "b", "u").unwrap();
    live.command_sent(&command_b);
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a", "b"], None)]));
    // live(a) now claims item b, which is already live under its own tab: the transaction
    // is dropped whole and the map stays one to one.
    let reused = live.live_tab("a").unwrap();
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![
                LiveTab { live_id: reused.clone(), item: Some("b".into()) },
                LiveTab { live_id: live.live_tab("b").unwrap(), item: Some("b".into()) },
            ],
            active: None,
        }],
    });
    assert!(!outcome.applied);
    assert_eq!(live.dropped(), 1);
    assert_eq!(live.live_tab("a").as_deref(), Some(reused.as_str()));
    assert_eq!(live.item_for(&reused).as_deref(), Some("a"));
    assert!(live.live_tab("b").is_some());
}

#[test]
fn queries_answer_both_directions_and_missing_names() {
    let mut ws = workspace();
    let mut live = Live::new();
    assert_eq!(live.live_tab("a"), None);
    assert_eq!(live.item_for("live-a"), None);
    let (_, command) = live.open(&mut ws, "a", "u").unwrap();
    live.command_sent(&command);
    assert_eq!(live.live_tab("a"), Some(command.id.clone()));
    assert_eq!(live.item_for(&command.id), Some("a".into()));
}

#[test]
fn an_itemless_tab_inside_the_epoch_is_adopted_in_that_transaction() {
    let mut ws = workspace();
    let mut live = Live::new();
    let (_, command_a) = live.open(&mut ws, "a", "u").unwrap();
    live.command_sent(&command_a);
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a"], None)]));
    // Chrome opened a tab on its own (⌘-click, window.open): the strips carry it with no
    // item, and the adoption happens in this transaction.
    let (ops, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![
                LiveTab { live_id: live.live_tab("a").unwrap(), item: Some("a".into()) },
                LiveTab { live_id: "live-new".into(), item: None },
            ],
            active: Some("live-new".into()),
        }],
    });
    assert!(outcome.applied);
    // Reported as the pair the engine needs for the tab's session data.
    let (live_id, adopted) = outcome.adopted.first().expect("adopted pair").clone();
    assert_eq!(live_id, "live-new");
    // The row is an open tab under the shown space's Today, mapped both ways, selected.
    let item = &ws.items[adopted.as_str()];
    assert!(matches!(item.kind, ItemKind::Tab { .. }));
    assert_eq!(item.lifecycle, Lifecycle::Open);
    assert_eq!(item.membership.parent.as_deref(), Some("space-work:today"));
    assert_eq!(live.live_tab(&adopted).as_deref(), Some("live-new"));
    assert_eq!(live.item_for("live-new").as_deref(), Some(adopted.as_str()));
    assert_eq!(ws.selected("one"), Some(adopted.as_str()));
    // The ops are one storage transaction: a reopened store reads the adopted row.
    let path = std::env::temp_dir().join(format!("ararat-live-adopt-{}.sqlite", std::process::id()));
    let _ = std::fs::remove_file(&path);
    let (store, _) = Store::open(&path).unwrap();
    store.write(ops);
    store.flush().unwrap();
    drop(store);
    let (store, loaded) = Store::open(&path).unwrap();
    assert!(matches!(loaded.items[adopted.as_str()].kind, ItemKind::Tab { .. }));
    drop(store);
    drop(loaded);
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
}

#[test]
fn an_itemless_tab_adopts_into_its_own_windows_shown_space() {
    let mut ws = workspace();
    for op in ws.create_space("two", "Home", "space-home").unwrap() { ws.apply(&op); }
    tab(&mut ws, "home", "space-home:today", "https://home.example");
    let mut live = Live::new();
    live.apply(&mut ws, Transaction {
        epoch: 1, rev: 0, cause: Cause::Engine,
        strips: vec![
            Strip { window: "one".into(), tabs: vec![LiveTab { live_id: "L1".into(), item: Some("a".into()) }], active: Some("L1".into()) },
            Strip { window: "two".into(), tabs: vec![LiveTab { live_id: "L2".into(), item: Some("home".into()) }], active: None },
        ],
    });
    // Window two's shown space is space-home: the itemless tab there adopts into
    // space-home:today, not into window one's Today.
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![
            Strip { window: "one".into(), tabs: vec![LiveTab { live_id: "L1".into(), item: Some("a".into()) }], active: Some("L1".into()) },
            Strip { window: "two".into(), tabs: vec![LiveTab { live_id: "L2".into(), item: Some("home".into()) }, LiveTab { live_id: "L3".into(), item: None }], active: Some("L3".into()) },
        ],
    });
    assert!(outcome.applied);
    let (live_id, adopted) = outcome.adopted.first().expect("adopted pair").clone();
    assert_eq!(live_id, "L3");
    assert_eq!(ws.items[adopted.as_str()].membership.parent.as_deref(), Some("space-home:today"));
    assert_eq!(live.item_for("L3").as_deref(), Some(adopted.as_str()));
}

#[test]
fn a_dropped_transaction_leaves_the_workspace_and_the_map_alone() {
    let mut ws = workspace();
    let mut live = Live::new();
    let (_, command_a) = live.open(&mut ws, "a", "u").unwrap();
    live.command_sent(&command_a);
    let (_, command_b) = live.open(&mut ws, "b", "u").unwrap();
    live.command_sent(&command_b);
    let (_, command_c) = live.open(&mut ws, "c", "u").unwrap();
    live.command_sent(&command_c);
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a", "b", "c"], Some("b"))]));
    // The transaction drops Lc and has Lb claim item a: dropped whole, and the workspace
    // and the map are exactly as they were.
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![
                LiveTab { live_id: live.live_tab("a").unwrap(), item: Some("a".into()) },
                LiveTab { live_id: live.live_tab("b").unwrap(), item: Some("a".into()) },
            ],
            active: None,
        }],
    });
    assert!(!outcome.applied);
    assert!(live.live_tab("c").as_deref() == Some(command_c.id.as_str()));
    assert_eq!(ws.items["c"].lifecycle, Lifecycle::Open);
    assert_eq!(live.live_tab("a").as_deref(), Some(command_a.id.as_str()));
    // The dropped transaction consumed its rev (design): a retry with the same rev is
    // dropped too, and the next rev applies.
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![strip(&live, &["a", "b", "c"], None)],
    });
    assert!(!outcome.applied);
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 2, cause: Cause::Chrome,
        strips: vec![strip(&live, &["a", "b", "c"], None)],
    });
    assert!(outcome.applied);
}

#[test]
fn a_transaction_naming_one_window_leaves_the_other_windows_tabs_alone() {
    let mut ws = workspace();
    for op in ws.create_space("two", "Home", "space-home").unwrap() { ws.apply(&op); }
    tab(&mut ws, "home", "space-home:today", "https://home.example");
    let mut live = Live::new();
    live.apply(&mut ws, Transaction {
        epoch: 1, rev: 0, cause: Cause::Engine,
        strips: vec![
            Strip { window: "one".into(), tabs: vec![LiveTab { live_id: "La".into(), item: Some("a".into()) }, LiveTab { live_id: "Lb".into(), item: Some("b".into()) }], active: Some("La".into()) },
            Strip { window: "two".into(), tabs: vec![LiveTab { live_id: "Lc".into(), item: Some("home".into()) }], active: Some("Lc".into()) },
        ],
    });
    // The transaction names only window two: window one's tabs stay open and mapped.
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![Strip { window: "two".into(), tabs: vec![LiveTab { live_id: "Lc".into(), item: Some("home".into()) }], active: Some("Lc".into()) }],
    });
    assert!(outcome.applied);
    assert_eq!(ws.items["a"].lifecycle, Lifecycle::Open);
    assert_eq!(ws.items["b"].lifecycle, Lifecycle::Open);
    assert_eq!(live.live_tab("a").as_deref(), Some("La"));
    assert_eq!(live.live_tab("b").as_deref(), Some("Lb"));
}

#[test]
fn a_closed_window_arrives_as_an_empty_strip() {
    let mut ws = workspace();
    for op in ws.create_space("two", "Home", "space-home").unwrap() { ws.apply(&op); }
    tab(&mut ws, "home", "space-home:today", "https://home.example");
    let mut live = Live::new();
    live.apply(&mut ws, Transaction {
        epoch: 1, rev: 0, cause: Cause::Engine,
        strips: vec![
            Strip { window: "one".into(), tabs: vec![LiveTab { live_id: "La".into(), item: Some("a".into()) }, LiveTab { live_id: "Lb".into(), item: Some("b".into()) }], active: Some("La".into()) },
            Strip { window: "two".into(), tabs: vec![LiveTab { live_id: "Lc".into(), item: Some("home".into()) }], active: Some("Lc".into()) },
        ],
    });
    // Window two closed: its strip arrives empty, and its tab is gone for the core's
    // rules (Chrome caused it, so the ⌘W rule closes the row).
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![
            Strip { window: "one".into(), tabs: vec![LiveTab { live_id: "La".into(), item: Some("a".into()) }, LiveTab { live_id: "Lb".into(), item: Some("b".into()) }], active: Some("La".into()) },
            Strip { window: "two".into(), tabs: vec![], active: None },
        ],
    });
    assert!(outcome.applied);
    assert_eq!(ws.items["home"].lifecycle, Lifecycle::Closed);
    assert!(live.live_tab("home").is_none());
    assert_eq!(live.live_tab("a").as_deref(), Some("La"));
}

#[test]
fn closing_a_window_keeps_rows_and_allows_the_selected_tab_to_reopen() {
    let mut ws = workspace();
    let mut live = Live::new();
    live.apply(&mut ws, Transaction {
        epoch: 1, rev: 0, cause: Cause::Engine,
        strips: vec![Strip { window: "one".into(), tabs: vec![LiveTab {
            live_id: "La".into(), item: Some("a".into()),
        }], active: Some("La".into()) }],
    });
    let (ops, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Engine,
        strips: vec![Strip { window: "one".into(), tabs: vec![], active: None }],
    });
    assert!(outcome.applied);
    assert!(ops.is_empty());
    assert_eq!(ws.items["a"].lifecycle, Lifecycle::Open);
    assert!(live.live_tab("a").is_none());
    let (_, command) = live.open(&mut ws, "a", "https://a.example/").unwrap();
    assert_eq!(command.kind, CommandKind::Open);
}

#[test]
fn a_snapshot_marks_an_unloaded_row_the_engine_carries_open() {
    let mut ws = workspace();
    ws.items.get_mut("pinned").unwrap().lifecycle = Lifecycle::Unloaded;
    let mut live = Live::new();
    // The engine reports the unloaded row as live: the row is open from here on, because
    // the engine owns which tabs exist.
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 0, cause: Cause::Engine,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![
                LiveTab { live_id: "Lp".into(), item: Some("pinned".into()) },
                LiveTab { live_id: "La".into(), item: Some("a".into()) },
            ],
            active: Some("Lp".into()),
        }],
    });
    assert!(outcome.applied);
    assert_eq!(ws.items["pinned"].lifecycle, Lifecycle::Open);
    assert_eq!(live.live_tab("pinned").as_deref(), Some("Lp"));
}

#[test]
fn a_chrome_transaction_before_an_open_completes_leaves_the_open_alone() {
    let mut ws = workspace();
    let mut live = Live::new();
    // The engine starts with only b live: the snapshot unloads a, and the open that
    // follows flips it back open.
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 0, cause: Cause::Engine,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![LiveTab { live_id: "Lb".into(), item: Some("b".into()) }],
            active: Some("Lb".into()),
        }],
    });
    assert!(outcome.applied);
    let (_, command_a) = live.open(&mut ws, "a", "u").unwrap();
    live.command_sent(&command_a);
    assert_eq!(ws.items["a"].lifecycle, Lifecycle::Open);
    // The engine has not created the tab yet: Chrome's transaction still names only b.
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![LiveTab { live_id: "Lb".into(), item: Some("b".into()) }],
            active: Some("Lb".into()),
        }],
    });
    assert!(outcome.applied);
    // The pending open is not read as a Chrome close: the row stays open and mapped,
    // and no command is returned.
    assert!(outcome.commands.is_empty());
    assert_eq!(ws.items["a"].lifecycle, Lifecycle::Open);
    assert_eq!(live.live_tab("a").as_deref(), Some(command_a.id.as_str()));
    // The open's completion carries the tab under the command's id and applies with no
    // close.
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 2, cause: Cause::Command(command_a.id.clone()),
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![
                LiveTab { live_id: "Lb".into(), item: Some("b".into()) },
                LiveTab { live_id: command_a.id.clone(), item: Some("a".into()) },
            ],
            active: Some(command_a.id.clone()),
        }],
    });
    assert!(outcome.applied);
    assert!(outcome.commands.is_empty());
    assert_eq!(ws.items["a"].lifecycle, Lifecycle::Open);
    assert_eq!(live.live_tab("a").as_deref(), Some(command_a.id.as_str()));
}

#[test]
fn a_chrome_transaction_before_a_close_completes_leaves_the_unload_alone() {
    let mut ws = workspace();
    let mut live = Live::new();
    let (_, open_command) = live.open(&mut ws, "pinned", "u").unwrap();
    live.command_sent(&open_command);
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["pinned"], Some("pinned"))]));
    let (close_ops, close_command) = live.close(&mut ws, "pinned").unwrap();
    for op in &close_ops { ws.apply(op); }
    assert_eq!(ws.items["pinned"].lifecycle, Lifecycle::Unloaded);
    assert!(live.live_tab("pinned").is_none());
    // The engine has not carried the close out yet: Chrome's strips still carry the tab
    // under the live id the open command carried. The pending close is not undone — no
    // re-map, no re-selection, no ops at all.
    let (tx_ops, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![LiveTab { live_id: open_command.id.clone(), item: Some("pinned".into()) }],
            active: Some(open_command.id.clone()),
        }],
    });
    assert!(outcome.applied);
    assert!(outcome.commands.is_empty());
    assert!(tx_ops.is_empty());
    assert_eq!(ws.items["pinned"].lifecycle, Lifecycle::Unloaded);
    assert!(live.live_tab("pinned").is_none());
    // The engine carries the close out: the transaction without the tab leaves the map
    // clean.
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 2, cause: Cause::Engine,
        strips: vec![strip(&live, &[], None)],
    });
    assert!(outcome.applied);
    assert!(live.live_tab("pinned").is_none());
    assert_eq!(ws.items["pinned"].lifecycle, Lifecycle::Unloaded);
}

#[test]
fn a_snapshot_keeps_the_map_one_to_one_by_live_id() {
    let mut ws = workspace();
    let mut live = Live::new();
    // One live id claimed for two items: a wins the claim, and the loser b is unloaded
    // instead of sharing the live tab.
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 0, cause: Cause::Engine,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![
                LiveTab { live_id: "L1".into(), item: Some("a".into()) },
                LiveTab { live_id: "L1".into(), item: Some("b".into()) },
            ],
            active: Some("L1".into()),
        }],
    });
    assert!(outcome.applied);
    assert_eq!(live.live_tab("a").as_deref(), Some("L1"));
    assert_eq!(live.live_tab("b"), None);
    assert_eq!(ws.items["b"].lifecycle, Lifecycle::Unloaded);
    assert_eq!(ws.items["a"].lifecycle, Lifecycle::Open);
    assert_eq!(live.item_for("L1").as_deref(), Some("a"));
}

