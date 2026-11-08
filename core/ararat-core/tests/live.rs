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
        tabs: tabs.iter().map(|item| LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: live.live_tab(item).expect("mapped"), item: Some((*item).into()) }).collect(),
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
fn a_hidden_page_snapshot_keeps_empty_space_selection_and_live_membership() {
    let mut ws = workspace();
    let mut live = Live::new();
    let (_, open) = live.open(&mut ws, "a", "https://a.example").unwrap();
    live.command_sent(&open);
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a"], Some("a"))]));
    ws.create_space("one", "Empty", "empty").unwrap();
    let before = ws.clone();
    for (rev, cause) in [(1, Cause::Engine), (2, Cause::Chrome)] {
        let (_, outcome) = live.apply(&mut ws, Transaction {
            epoch: 1, rev, cause, strips: vec![strip(&live, &["a"], None)],
        });
        assert!(outcome.applied);
        assert_eq!(ws.selected("one"), None);
        assert_eq!(ws.windows["one"], before.windows["one"]);
        assert_eq!(live.live_tab("a").as_deref(), Some(open.id.as_str()));
    }
}

#[test]
fn reconciliation_selects_the_shown_browsers_active_tab() {
    let mut ws = workspace();
    let mut live = Live::new();
    for item in ["a", "b"] {
        let (_, command) = live.open(&mut ws, item, "u").unwrap();
        live.command_sent(&command);
    }
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a", "b"], Some("a"))]));
    ws.last_selected.insert("a".into(), 1);
    ws.last_selected.insert("b".into(), 2);
    let switch_ops = ws.show_space("one", "space-work").unwrap();
    let before = ws.clone();
    let (ops, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![strip(&live, &["a", "b"], Some("b"))],
    });
    assert!(outcome.applied);
    assert_eq!(ws.selected("one"), Some("b"));
    assert!(ops.iter().any(|op| matches!(op, Op::Put(Record::Window(_)))));
    assert!(ops.iter().any(|op| matches!(op, Op::Put(Record::LastSelected { item, .. }) if item == "a")));
    assert!(ops.iter().any(|op| matches!(op, Op::Put(Record::LastSelected { item, .. }) if item == "b")));
    assert_ne!(ws.windows["one"].history, before.windows["one"].history);
    assert_eq!(switch_ops.iter().chain(&ops).filter(|op| matches!(op, Op::Put(Record::Window(_)))).count(), 2);
    assert_eq!(switch_ops.len() + ops.len(), 4);
    assert!(switch_ops.iter().chain(&ops).all(|op| matches!(op,
        Op::Put(Record::Window(_)) | Op::Put(Record::LastSelected { .. }))));
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
        tabs: vec![LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "engine-a".into(), item: Some("a".into()) }],
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
            tabs: vec![LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "engine-a".into(), item: Some("a".into()) }],
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
    let (ops, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Command(command.id.clone()),
        strips: vec![strip_empty("one")],
    });
    assert!(outcome.applied);
    assert!(!ops.is_empty());
    assert_eq!(live.live_tab("a"), None);
    assert_eq!(live.item_for(&command.id), None);
    assert_eq!(ws.items["a"].lifecycle, Lifecycle::Unloaded);
    assert!(live.open(&mut ws, "a", "u").is_ok());
    let (_, duplicate) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 2, cause: Cause::Command(command.id), strips: vec![],
    });
    assert!(!duplicate.applied);
}

#[test]
fn rejected_open_can_be_cancelled_and_unloaded() {
    let mut ws = workspace();
    let mut live = Live::new();
    live.apply(&mut ws, snapshot_tx(vec![]));
    let (_, command) = live.open(&mut ws, "a", "u").unwrap();
    live.command_sent(&command);
    let lifecycle = ws.items["a"].lifecycle.clone();
    assert!(!live.cancel(&mut ws, "unknown").0);
    assert_eq!(live.live_tab("a").as_deref(), Some(command.id.as_str()));
    assert_eq!(live.item_for(&command.id).as_deref(), Some("a"));
    assert_eq!(ws.items["a"].lifecycle, lifecycle);
    let (cancelled, ops) = live.cancel(&mut ws, &command.id);
    assert!(cancelled);
    assert!(!ops.is_empty());
    assert!(!live.cancel(&mut ws, &command.id).0);
    assert_eq!(live.live_tab("a"), None);
    assert_eq!(live.item_for(&command.id), None);
    assert_eq!(ws.items["a"].lifecycle, Lifecycle::Unloaded);
    assert!(live.open(&mut ws, "a", "u").is_ok());
}

#[test]
fn cancelling_a_pending_activation_keeps_the_live_tab_and_rejects_a_late_completion() {
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
    assert!(live.cancel(&mut ws, &activate.id).0);
    assert!(!live.cancel(&mut ws, &activate.id).0);
    assert_eq!(live.live_tab("a").as_deref(), Some(open.id.as_str()));
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 2, cause: Cause::Command(activate.id),
        strips: vec![strip(&live, &["a"], Some("a"))],
    });
    assert!(!outcome.applied);
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
                LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "live-a".into(), item: Some("a".into()) },
                LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "live-c".into(), item: Some("c".into()) },
                LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "live-pinned".into(), item: Some("pinned".into()) },
                LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "live-new".into(), item: None },
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
                LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: reused.clone(), item: Some("b".into()) },
                LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: live.live_tab("b").unwrap(), item: Some("b".into()) },
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
                LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: live.live_tab("a").unwrap(), item: Some("a".into()) },
                LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "live-new".into(), item: None },
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
    assert!(ws.last_selected.contains_key(&adopted));
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
fn background_adoption_does_not_enter_selection_history() {
    let mut ws = workspace();
    let mut live = Live::new();
    live.apply(&mut ws, snapshot_tx(vec![Strip {
        window: "one".into(),
        tabs: vec![LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "La".into(), item: Some("a".into()) }],
        active: Some("La".into()),
    }]));
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![
                LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "La".into(), item: Some("a".into()) },
                LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "new".into(), item: None },
            ],
            active: Some("La".into()),
        }],
    });
    let adopted = &outcome.adopted[0].1;
    assert_eq!(ws.selected("one"), Some("a"));
    assert!(!ws.last_selected.contains_key(adopted));
    assert!(!ws.windows["one"].history.contains(adopted));
}

#[test]
fn background_adoption_in_a_snapshot_has_no_selection_history() {
    let mut ws = workspace();
    let mut live = Live::new();
    let (_, outcome) = live.apply(&mut ws, snapshot_tx(vec![Strip {
        window: "one".into(),
        tabs: vec![
            LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "La".into(), item: Some("a".into()) },
            LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "new".into(), item: None },
        ],
        active: Some("La".into()),
    }]));
    let adopted = &outcome.adopted[0].1;
    assert_eq!(ws.selected("one"), Some("a"));
    assert!(!ws.last_selected.contains_key(adopted));
    assert!(!ws.windows["one"].history.contains(adopted));
}

#[test]
fn adopted_tab_metadata_tracks_navigation_and_preserves_custom_title() {
    let mut ws = workspace();
    let mut live = Live::new();
    let (_, outcome) = live.apply(&mut ws, snapshot_tx(vec![Strip {
        window: "one".into(),
        tabs: vec![LiveTab { profile: Default::default(),
            live_id: "new".into(), item: None, opener: None, navigated: false,
            url: Some("https://first.example/".into()), title: Some("First".into()),
        }],
        active: Some("new".into()),
    }]));
    let id = outcome.adopted[0].1.clone();
    assert_eq!(ws.items[&id].display_title(), "First");
    assert!(matches!(&ws.items[&id].kind, ItemKind::Tab { url, .. } if url == "https://first.example/"));
    ws.rename_tab(&id, "Custom").unwrap();
    live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Engine,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![LiveTab { profile: Default::default(),
                live_id: "new".into(), item: Some(id.clone()), opener: None, navigated: true,
                url: Some("https://second.example/".into()), title: Some("Second".into()),
            }],
            active: Some("new".into()),
        }],
    });
    assert_eq!(ws.items[&id].display_title(), "Custom");
    assert!(matches!(&ws.items[&id].kind, ItemKind::Tab { url, saved_title: Some(title) } if url == "https://second.example/" && title == "Second"));
    ws.set_tab_url(&id, "https://pending.example/").unwrap();
    live.apply(&mut ws, Transaction {
        epoch: 1, rev: 2, cause: Cause::Engine,
        strips: vec![Strip { window: "one".into(), tabs: vec![LiveTab { profile: Default::default(),
            live_id: "new".into(), item: Some(id.clone()), opener: None, navigated: false,
            url: Some("https://second.example/".into()), title: Some("Stale".into()),
        }], active: Some("new".into()) }],
    });
    assert!(matches!(&ws.items[&id].kind, ItemKind::Tab { url, saved_title: Some(title) } if url == "https://pending.example/" && title == "Second"));
}

#[test]
fn title_report_does_not_change_a_rows_url_without_a_navigation() {
    let mut ws = workspace();
    let mut live = Live::new();
    live.apply(&mut ws, snapshot_tx(vec![Strip {
        window: "one".into(),
        tabs: vec![LiveTab { profile: Default::default(),
            live_id: "La".into(), item: Some("a".into()), opener: None, navigated: false,
            url: Some("about:blank".into()), title: Some("Page".into()),
        }],
        active: Some("La".into()),
    }]));
    assert!(matches!(&ws.items["a"].kind, ItemKind::Tab { url, saved_title: None } if url == "https://a.example"));
}

#[test]
fn an_empty_url_is_filled_from_a_previously_committed_entry() {
    let mut ws = workspace();
    if let ItemKind::Tab { url, .. } = &mut ws.items.get_mut("a").unwrap().kind { url.clear(); }
    let mut live = Live::new();
    live.apply(&mut ws, snapshot_tx(vec![Strip {
        window: "one".into(),
        tabs: vec![LiveTab { profile: Default::default(),
            live_id: "La".into(), item: Some("a".into()), opener: None, navigated: false,
            url: Some("https://committed.example/".into()), title: Some("Page".into()),
        }],
        active: Some("La".into()),
    }]));
    assert!(matches!(&ws.items["a"].kind, ItemKind::Tab { url, .. } if url == "https://committed.example/"));
}

#[test]
fn pinned_navigation_keeps_the_saved_url_and_title() {
    let mut ws = workspace();
    if let ItemKind::Tab { saved_title, .. } = &mut ws.items.get_mut("pinned").unwrap().kind {
        *saved_title = Some("Inbox".into());
    }
    let mut live = Live::new();
    live.apply(&mut ws, snapshot_tx(vec![Strip {
        window: "one".into(),
        tabs: vec![LiveTab { profile: Default::default(),
            live_id: "Lp".into(), item: Some("pinned".into()), opener: None, navigated: true,
            url: Some("https://pinned.example/message".into()), title: Some("Message".into()),
        }],
        active: Some("Lp".into()),
    }]));
    assert!(matches!(&ws.items["pinned"].kind, ItemKind::Tab { url, saved_title: Some(title) } if url == "https://pinned.example" && title == "Inbox"));
}

#[test]
fn closing_a_window_removes_its_record_but_quit_keeps_it() {
    let mut ws = workspace();
    ws.show_space("one", "space-work").unwrap();
    ws.show_space("two", "space-work").unwrap();
    assert!(ws.close_window("one", true).is_empty());
    assert!(ws.windows.contains_key("one"));
    let ops = ws.close_window("two", false);
    assert!(matches!(&ops[..], [Op::Delete(ararat_core::model::Kind::Window, id)] if id == "two"));
    assert!(!ws.windows.contains_key("two"));
    assert!(ws.windows.contains_key("one"));
}

#[test]
fn quitting_after_a_space_switch_launches_on_the_switched_space() {
    let mut ws = workspace();
    ws.show_space("one", "space-work").unwrap();
    // The user closes the window; the record goes, and the reopened window arrives with a
    // fresh id. Its record is created the way reopen writes the old shown space back.
    assert!(matches!(&ws.close_window("one", false)[..], [Op::Delete(ararat_core::model::Kind::Window, id)] if id == "one"));
    assert!(ws.kept_windows().is_empty());
    ws.show_space("reopened", "space-work").unwrap();
    // An older kept record from a previous session stays; the newest-first order is what
    // launch reads, and the switch below must supply the stamp that outranks it.
    ws.show_space("previous", "space-work").unwrap();
    // The user creates a new space and switches the reopened window to it. The creation
    // rides another window's record so the decisive write on "reopened" is the switch.
    for op in ws.create_space("previous", "Home", "space-home").unwrap() { ws.apply(&op); }
    ws.windows.get_mut("reopened").unwrap().changed_at = 50;
    ws.windows.get_mut("previous").unwrap().changed_at = 100;
    ws.show_space("reopened", "space-home").unwrap();
    // Quit keeps every record; the next launch adopts the newest kept one.
    assert!(ws.close_window("reopened", true).is_empty());
    assert!(ws.close_window("previous", true).is_empty());
    let kept = ws.kept_windows();
    assert_eq!(kept.iter().map(|w| w.id.as_str()).collect::<Vec<_>>(), ["reopened", "previous"]);
    assert_eq!(kept[0].shown_space.as_deref(), Some("space-home"));
}

#[test]
fn launch_at_two_kept_window_records_takes_the_newer_and_keeps_the_older() {
    let mut ws = workspace();
    // The fixture's create_space wrote a record for window "one" with a wall-clock stamp;
    // clamp it below both test records so the order the test names stays deterministic.
    ws.windows.get_mut("one").unwrap().changed_at = 0;
    ws.show_space("older", "space-work").unwrap();
    ws.windows.get_mut("older").unwrap().changed_at = 100;
    ws.show_space("newer", "space-work").unwrap();
    ws.windows.get_mut("newer").unwrap().changed_at = 200;
    let kept = ws.kept_windows();
    assert_eq!((kept[0].id.as_str(), kept[1].id.as_str()), ("newer", "older"));
    assert_eq!(kept[0].changed_at, 200);
    // The launch adopts the first record; the other one stays for phase 5.
    assert!(ws.windows.contains_key("older"));
}

#[test]
fn a_user_close_removes_the_id_from_the_kept_records() {
    let mut ws = workspace();
    ws.show_space("one", "space-work").unwrap();
    assert_eq!(ws.kept_windows().first().map(|w| w.id.as_str()), Some("one"));
    ws.close_window("one", false);
    assert!(ws.kept_windows().is_empty());
    // The id is gone; no launch or reopen can adopt it back, so no id is ever reused.
}

#[test]
fn a_window_record_write_stamps_it_for_the_kept_query() {
    let mut ws = workspace();
    ws.show_space("one", "space-work").unwrap();
    assert!(ws.windows["one"].changed_at > 0);
    // A selection stamps the record with the operation's own instant.
    ws.select_item_at("one", "a", 5_000).unwrap();
    assert_eq!(ws.windows["one"].changed_at, 5_000);
    ws.show_space("one", "space-work").unwrap();
    assert!(ws.windows["one"].changed_at >= 5_000);
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
            Strip { window: "one".into(), tabs: vec![LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "L1".into(), item: Some("a".into()) }], active: Some("L1".into()) },
            Strip { window: "two".into(), tabs: vec![LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "L2".into(), item: Some("home".into()) }], active: None },
        ],
    });
    // Window two's shown space is space-home: the itemless tab there adopts into
    // space-home:today, not into window one's Today.
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![
            Strip { window: "one".into(), tabs: vec![LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "L1".into(), item: Some("a".into()) }], active: Some("L1".into()) },
            Strip { window: "two".into(), tabs: vec![LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "L2".into(), item: Some("home".into()) }, LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "L3".into(), item: None }], active: Some("L3".into()) },
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
                LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: live.live_tab("a").unwrap(), item: Some("a".into()) },
                LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: live.live_tab("b").unwrap(), item: Some("a".into()) },
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
            Strip { window: "one".into(), tabs: vec![LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "La".into(), item: Some("a".into()) }, LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "Lb".into(), item: Some("b".into()) }], active: Some("La".into()) },
            Strip { window: "two".into(), tabs: vec![LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "Lc".into(), item: Some("home".into()) }], active: Some("Lc".into()) },
        ],
    });
    // The transaction names only window two: window one's tabs stay open and mapped.
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![Strip { window: "two".into(), tabs: vec![LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "Lc".into(), item: Some("home".into()) }], active: Some("Lc".into()) }],
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
            Strip { window: "one".into(), tabs: vec![LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "La".into(), item: Some("a".into()) }, LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "Lb".into(), item: Some("b".into()) }], active: Some("La".into()) },
            Strip { window: "two".into(), tabs: vec![LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "Lc".into(), item: Some("home".into()) }], active: Some("Lc".into()) },
        ],
    });
    // Window two closed: its strip arrives empty, and its tab is gone for the core's
    // rules (Chrome caused it, so the ⌘W rule closes the row).
    let (_, outcome) = live.apply(&mut ws, Transaction {
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![
            Strip { window: "one".into(), tabs: vec![LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "La".into(), item: Some("a".into()) }, LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "Lb".into(), item: Some("b".into()) }], active: Some("La".into()) },
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
        strips: vec![Strip { window: "one".into(), tabs: vec![LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None,
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
                LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "Lp".into(), item: Some("pinned".into()) },
                LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "La".into(), item: Some("a".into()) },
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
            tabs: vec![LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "Lb".into(), item: Some("b".into()) }],
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
            tabs: vec![LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "Lb".into(), item: Some("b".into()) }],
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
                LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "Lb".into(), item: Some("b".into()) },
                LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: command_a.id.clone(), item: Some("a".into()) },
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
            tabs: vec![LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: open_command.id.clone(), item: Some("pinned".into()) }],
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
                LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "L1".into(), item: Some("a".into()) },
                LiveTab { profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "L1".into(), item: Some("b".into()) },
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


#[test]
fn adoption_uses_the_recent_space_for_the_tabs_profile_in_each_window() {
    use ararat_core::model::Profile;
    let mut ws = workspace();
    ws.create_space("one", "Other", "other").unwrap();
    ws.create_space("one", "Other newer", "other-new").unwrap();
    for space in &mut ws.spaces {
        if space.id.starts_with("other") { space.profile = Profile::Named("Profile 1".into()); }
    }
    ws.show_space("one", "other").unwrap();
    ws.show_space("two", "other-new").unwrap();
    ws.show_space("one", "space-work").unwrap();
    ws.show_space("two", "space-work").unwrap();
    let mut live = Live::new();
    let (_, outcome) = live.apply(&mut ws, snapshot_tx(vec![
        Strip { window: "one".into(), tabs: vec![LiveTab { profile: Profile::Named("Profile 1".into()), live_id: "first".into(), item: None, opener: None, navigated: false, url: None, title: None }], active: None },
        Strip { window: "two".into(), tabs: vec![LiveTab { profile: Profile::Named("Profile 1".into()), live_id: "second".into(), item: None, opener: None, navigated: false, url: None, title: None }], active: None },
    ]));
    let adopted = |id: &str| &outcome.adopted.iter().find(|(live, _)| live == id).unwrap().1;
    assert_eq!(ws.items[adopted("first")].membership.parent.as_deref(), Some("other:today"));
    assert_eq!(ws.items[adopted("second")].membership.parent.as_deref(), Some("other-new:today"));
    assert_eq!(ws.shown_space("one"), Some("space-work"));
}

#[test]
fn a_tab_claiming_an_item_from_another_profile_is_rejected_without_row_changes() {
    use ararat_core::model::Profile;
    let mut ws = workspace();
    let before = ws.clone();
    let mut live = Live::new();
    let (ops, outcome) = live.apply(&mut ws, snapshot_tx(vec![Strip {
        window: "one".into(), active: None,
        tabs: vec![LiveTab { profile: Profile::Named("Profile 1".into()), live_id: "foreign".into(), item: Some("a".into()), opener: None, navigated: false, url: None, title: None }],
    }]));
    assert!(!outcome.applied);
    assert!(ops.is_empty());
    assert_eq!(ws, before);
}
