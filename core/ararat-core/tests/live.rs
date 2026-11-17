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
        lifecycle_changed_at: 0, archive: None,
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
        tabs: tabs.iter().map(|item| LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: live.live_tab(item).expect("mapped"), item: Some((*item).into()) }).collect(),
        active: active.map(|item| live.live_tab(item).expect("mapped")),
    }
}

fn strip_empty(window: &str) -> Strip {
    Strip { window: window.into(), tabs: vec![], active: None }
}

#[test]
fn private_single_tab_adoption_selects_it_when_the_strip_has_no_active_tab() {
    for initial_snapshot in [true, false] {
        let mut ws = Workspace::private(Default::default());
        let mut live = Live::new();
        if !initial_snapshot {
            live.apply(&mut ws, Transaction { off_the_record: true, epoch: 1, rev: 0, cause: Cause::Engine, strips: vec![] });
        }
        let tab = LiveTab { off_the_record: true, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "live".into(), item: None };
        let (_, result) = live.apply(&mut ws, Transaction { off_the_record: true, epoch: 1, rev: if initial_snapshot { 0 } else { 1 }, cause: Cause::Chrome,
            strips: vec![Strip { window: "private-window".into(), tabs: vec![tab], active: None }] });
        assert!(result.applied);
        assert_eq!(result.adopted.len(), 1);
        assert_eq!(ws.selected("private-window"), Some(result.adopted[0].1.as_str()));
        assert!(ws.last_selected.is_empty());
        assert!(ws.windows["private-window"].history.is_empty());
    }
}

#[test]
fn regular_single_tab_adoption_without_active_does_not_select() {
    let mut ws = workspace();
    let mut live = Live::new();
    let tab = LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "live".into(), item: None };
    let (_, result) = live.apply(&mut ws, snapshot_tx(vec![Strip { window: "one".into(), tabs: vec![tab], active: None }]));
    assert!(result.applied);
    assert_eq!(result.adopted.len(), 1);
    assert_eq!(ws.selected("one"), None);
}

#[test]
fn private_mapped_tab_alone_or_with_a_new_tab_does_not_select() {
    let mut ws = Workspace::private(Default::default());
    let mut live = Live::new();
    let tab = |id: &str, item: Option<String>| LiveTab { off_the_record: true, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: id.into(), item };
    let (_, initial) = live.apply(&mut ws, Transaction { off_the_record: true, epoch: 1, rev: 0, cause: Cause::Chrome,
        strips: vec![Strip { window: "w".into(), tabs: vec![tab("a", None), tab("b", None)], active: None }] });
    assert!(initial.applied);
    let mapped = initial.adopted.iter().find(|(live, _)| live == "a").unwrap().1.clone();
    let (_, alone) = live.apply(&mut ws, Transaction { off_the_record: true, epoch: 1, rev: 1, cause: Cause::Engine,
        strips: vec![Strip { window: "w".into(), tabs: vec![tab("a", Some(mapped.clone()))], active: None }] });
    assert!(alone.applied);
    assert!(alone.adopted.is_empty());
    assert_eq!(ws.selected("w"), None);
    let (_, mixed) = live.apply(&mut ws, Transaction { off_the_record: true, epoch: 1, rev: 2, cause: Cause::Chrome,
        strips: vec![Strip { window: "w".into(), tabs: vec![tab("a", Some(mapped)), tab("c", None)], active: None }] });
    assert!(mixed.applied);
    assert_eq!(mixed.adopted.len(), 1);
    assert_eq!(ws.selected("w"), None);
}

#[test]
fn adoption_without_an_active_tab_does_not_guess_among_multiple_tabs_or_replace_a_selection() {
    let tab = |id: &str| LiveTab { off_the_record: true, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: id.into(), item: None };
    let mut ws = Workspace::private(Default::default());
    let mut live = Live::new();
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: true, epoch: 1, rev: 0, cause: Cause::Chrome,
        strips: vec![Strip { window: "w".into(), tabs: vec![tab("a"), tab("b")], active: None }] });
    assert!(outcome.applied);
    assert_eq!(ws.selected("w"), None);
    ws.create_tab("w", "about:blank").unwrap();
    let selected = ws.selected("w").unwrap().to_string();
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: true, epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![Strip { window: "w".into(), tabs: vec![tab("c")], active: None }] });
    assert!(outcome.applied);
    assert_eq!(ws.selected("w"), Some(selected.as_str()));
}

#[test]
fn remote_selection_survives_detach_until_explicit_local_activation() {
    let mut ws = workspace();
    let mut live = Live::new();
    for item in ["a", "b"] {
        let (_, command) = live.open(&mut ws, item, "u").unwrap();
        live.command_sent(&command);
    }
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a", "b"], Some("a"))]));
    let mut moved = strip(&live, &["a"], Some("a"));
    moved.window = "two".into();
    let (_, result) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![strip(&live, &["b"], Some("b")), moved] });
    assert!(result.applied);
    assert_eq!(ws.selected("one"), Some("a"));
    let command = live.activate(&ws, "b").unwrap();
    live.command_sent(&command);
    assert!(live.selection_intent(&command.id, "one"));
    let (_, result) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 2, cause: Cause::Command(command.id),
        strips: vec![strip(&live, &["b"], Some("b"))] });
    assert!(result.applied);
    assert_eq!(ws.selected("one"), Some("b"));
}

#[test]
fn split_open_completion_selects_only_the_new_active_pane() {
    for foreground in [false, true] {
        let mut ws = workspace();
        let mut live = Live::new();
        for item in ["a", "b"] {
            let (_, command) = live.open(&mut ws, item, "u").unwrap();
            live.command_sent(&command);
        }
        live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a", "b"], Some("a"))]));
        let (_, change) = ws.add_split_pane("a", ararat_core::model::SplitSide::Right).unwrap();
        let pane = change.pane.as_str();
        let (_, open) = live.open(&mut ws, pane, "chrome://newtab/").unwrap();
        live.command_sent(&open);

        let mut remote = strip(&live, &["a"], Some("a"));
        remote.window = "two".into();
        let (_, moved) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 1,
            cause: Cause::Chrome, strips: vec![strip(&live, &["b"], Some("b")), remote] });
        assert!(moved.applied);
        assert_eq!(live.live_window("a").as_deref(), Some("two"));
        assert_eq!(ws.selected("one"), Some("a"));

        let active = if foreground { pane } else { "b" };
        let (_, opened) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 2,
            cause: Cause::Command(open.id), strips: vec![strip(&live, &["b", pane], Some(active))] });
        assert!(opened.applied);
        let selected = if foreground { pane } else { "a" };
        assert_eq!(ws.selected("one"), Some(selected), "foreground={foreground}");
        assert_eq!(live.live_window(pane).as_deref(), Some("one"));

        let (_, metadata) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 3,
            cause: Cause::Engine, strips: vec![strip(&live, &["b", pane], Some(active))] });
        assert!(metadata.applied);
        assert_eq!(ws.selected("one"), Some(selected));

        let (_, sibling) = live.open(&mut ws, "c", "u").unwrap();
        live.command_sent(&sibling);
        let (_, background) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 4,
            cause: Cause::Command(sibling.id), strips: vec![strip(&live, &["b", pane, "c"], Some(active))] });
        assert!(background.applied);
        assert_eq!(ws.selected("one"), Some(selected));
    }
}

#[test]
fn split_open_completion_outside_the_shown_space_preserves_a_remote_selection() {
    let mut ws = workspace();
    let mut live = Live::new();
    for item in ["a", "b"] {
        let (_, command) = live.open(&mut ws, item, "u").unwrap();
        live.command_sent(&command);
    }
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a", "b"], Some("a"))]));
    let (_, change) = ws.add_split_pane("a", ararat_core::model::SplitSide::Right).unwrap();
    let pane = change.pane.as_str();
    let (_, open) = live.open(&mut ws, pane, "chrome://newtab/").unwrap();
    live.command_sent(&open);

    ws.create_space("one", "Other", "other").unwrap();
    ws.items.get_mut("b").unwrap().membership.parent = Some("other:today".into());
    ws.select_item("one", "b").unwrap();
    let mut remote = strip(&live, &["b"], Some("b"));
    remote.window = "two".into();
    let (_, moved) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 1,
        cause: Cause::Chrome, strips: vec![strip(&live, &["a"], Some("a")), remote] });
    assert!(moved.applied);
    assert_eq!(ws.shown_space("one"), Some("other"));
    assert_eq!(ws.selected("one"), Some("b"));
    assert_eq!(live.live_window("b").as_deref(), Some("two"));

    let (_, opened) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 2,
        cause: Cause::Command(open.id), strips: vec![strip(&live, &["a", pane], Some(pane))] });
    assert!(opened.applied);
    assert_eq!(live.live_window(pane).as_deref(), Some("one"));
    assert_eq!(ws.shown_space("one"), Some("other"));
    assert_eq!(ws.selected("one"), Some("b"));
}

#[test]
fn split_open_completion_cannot_take_selection_back_after_an_explicit_activation() {
    let mut ws = workspace();
    let mut live = Live::new();
    for item in ["a", "b"] {
        let (_, command) = live.open(&mut ws, item, "u").unwrap();
        live.command_sent(&command);
    }
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a", "b"], Some("a"))]));
    let (_, change) = ws.add_split_pane("a", ararat_core::model::SplitSide::Right).unwrap();
    let pane = change.pane.as_str();
    let (_, open) = live.open(&mut ws, pane, "chrome://newtab/").unwrap();
    live.command_sent(&open);
    let mut remote = strip(&live, &["a"], Some("a"));
    remote.window = "two".into();
    let (_, moved) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 1,
        cause: Cause::Chrome, strips: vec![strip(&live, &["b"], Some("b")), remote] });
    assert!(moved.applied);
    assert_eq!(ws.selected("one"), Some("a"));
    assert_eq!(live.live_window("a").as_deref(), Some("two"));

    let activate = live.activate(&ws, "b").unwrap();
    live.command_sent(&activate);
    assert!(live.selection_intent(&activate.id, "one"));
    let completion = Transaction { off_the_record: false, epoch: 1, rev: 2,
        cause: Cause::Command(open.id), strips: vec![strip(&live, &["b", pane], Some(pane))] };
    let (_, opened) = live.apply(&mut ws, completion.clone());
    assert!(opened.applied);
    assert_eq!(ws.selected("one"), Some(pane));
    let (_, activated) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 3,
        cause: Cause::Command(activate.id), strips: vec![strip(&live, &["b", pane], Some("b"))] });
    assert!(activated.applied);
    assert_eq!(ws.selected("one"), Some("b"));

    let (_, replayed) = live.apply(&mut ws, completion);
    assert!(!replayed.applied);
    assert_eq!(ws.selected("one"), Some("b"));
}

#[test]
fn a_remote_selection_does_not_reactivate_an_off_space_strip() {
    let mut ws = workspace();
    ws.create_space("one", "Other", "other").unwrap();
    ws.items.get_mut("b").unwrap().membership.parent = Some("other:today".into());
    ws.show_space("one", "space-work").unwrap();
    let mut live = Live::new();
    for item in ["a", "b"] {
        let (_, command) = live.open(&mut ws, item, "u").unwrap();
        live.command_sent(&command);
    }
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a", "b"], Some("a"))]));
    let mut moved = strip(&live, &["a"], Some("a"));
    moved.window = "two".into();
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![strip(&live, &["b"], Some("b")), moved] });
    assert!(outcome.applied);
    assert!(outcome.commands.is_empty());
    assert_eq!(ws.selected("one"), Some("a"));
}

#[test]
fn an_explicit_activation_cannot_restore_a_space_the_window_left() {
    let mut ws = workspace();
    ws.create_space("one", "Other", "other").unwrap();
    ws.items.get_mut("b").unwrap().membership.parent = Some("other:today".into());
    ws.show_space("one", "space-work").unwrap();
    let mut live = Live::new();
    for item in ["a", "b"] {
        let (_, command) = live.open(&mut ws, item, "u").unwrap();
        live.command_sent(&command);
    }
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a", "b"], Some("a"))]));
    let command = live.activate(&ws, "a").unwrap();
    live.command_sent(&command);
    assert!(live.selection_intent(&command.id, "one"));
    ws.show_space("one", "other").unwrap();
    ws.select_item("one", "b").unwrap();
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 1, cause: Cause::Command(command.id),
        strips: vec![strip(&live, &["a", "b"], Some("a"))] });
    assert!(outcome.applied);
    assert_eq!(ws.selected("one"), Some("b"));
    assert_eq!(outcome.commands.len(), 1);
    assert_eq!(outcome.commands[0].item, "b");
}

#[test]
fn newer_selection_intent_rejects_a_late_completion() {
    let mut ws = workspace();
    let mut live = Live::new();
    for item in ["a", "b", "c"] {
        let (_, command) = live.open(&mut ws, item, "u").unwrap();
        live.command_sent(&command);
    }
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a", "b", "c"], Some("a"))]));
    let old = live.activate(&ws, "b").unwrap();
    live.command_sent(&old);
    assert!(live.selection_intent(&old.id, "one"));
    let new = live.activate(&ws, "c").unwrap();
    live.command_sent(&new);
    assert!(live.selection_intent(&new.id, "one"));
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 1, cause: Cause::Command(new.id),
        strips: vec![strip(&live, &["a", "b", "c"], Some("c"))] });
    assert!(outcome.applied);
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 2, cause: Cause::Command(old.id),
        strips: vec![strip(&live, &["a", "b", "c"], Some("b"))] });
    assert!(!outcome.applied);
    assert_eq!(ws.selected("one"), Some("c"));
}

#[test]
fn replaying_the_same_active_strip_preserves_workspace_rows() {
    let mut ws = workspace();
    let mut live = Live::new();
    let (_, command) = live.open(&mut ws, "a", "u").unwrap();
    live.command_sent(&command);
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a"], Some("a"))]));
    let before = ws.clone();
    let (ops, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![strip(&live, &["a"], Some("a"))],
    });
    assert!(outcome.applied);
    assert!(ops.is_empty());
    assert_eq!(ws, before);
}

#[test]
fn engine_metadata_does_not_replace_a_space_switch_selection() {
    let mut ws = workspace();
    let mut live = Live::new();
    for item in ["a", "b"] {
        let (_, command) = live.open(&mut ws, item, "u").unwrap();
        live.command_sent(&command);
    }
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a", "b"], Some("a"))]));
    ws.create_space("one", "Other", "other").unwrap();
    tab(&mut ws, "c2", "other:today", "https://c.example");
    ws.select_item("one", "c2").unwrap();
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 1, cause: Cause::Engine,
        strips: vec![strip(&live, &["a", "b"], Some("a"))],
    });
    assert!(outcome.applied);
    assert_eq!(ws.selected("one"), Some("c2"));
    assert!(live.live_tab("a").is_some());
    // The Chrome half depends on the shown space being "other" (create_space showed it and
    // select_item leaves the shown space alone).
    assert_eq!(ws.shown_space("one"), Some("other"));
    // A Chrome activation records only from the space the window shows, so the activation
    // this fixture reports is a tab of "other" (d2), not one of the space just left.
    tab(&mut ws, "d2", "other:today", "https://d.example");
    let (_, command) = live.open(&mut ws, "d2", "u").unwrap();
    live.command_sent(&command);
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 2, cause: Cause::Chrome,
        strips: vec![strip(&live, &["a", "b", "d2"], Some("d2"))],
    });
    assert!(outcome.applied);
    assert_eq!(ws.selected("one"), Some("d2"));
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
        let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
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
    let (ops, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
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
    let (ops, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
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
    let (opened, _) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 1, cause: Cause::Command(second.id),
        strips: vec![strip(&live, &["a", "b"], Some("a"))],
    });
    let (reordered, _) = live.apply(&mut ws, Transaction { off_the_record: false,
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
    let (ops, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
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
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
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
        tabs: vec![LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "engine-a".into(), item: Some("a".into()) }],
        active: None,
    }]));
    assert!(snapshot.applied);
    assert_eq!(snapshot.commands.len(), 1);
    assert_eq!(snapshot.commands[0].kind, CommandKind::Close);
    let (_, completion) = live.apply(&mut ws, Transaction { off_the_record: false,
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
    let (_, changed) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 1, cause: Cause::Engine,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "engine-a".into(), item: Some("a".into()) }],
            active: None,
        }],
    });
    assert_eq!(changed.commands.len(), 1);
    assert_eq!(changed.commands[0].kind, CommandKind::Close);
    let (_, completion) = live.apply(&mut ws, Transaction { off_the_record: false,
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
    let (_, opened) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 1, cause: Cause::Command(open.id.clone()),
        strips: vec![strip(&live, &["pinned"], Some("pinned"))],
    });
    assert!(opened.applied);
    let (_, close) = live.close(&mut ws, "pinned").unwrap();
    live.command_sent(&close);
    let (_, closed) = live.apply(&mut ws, Transaction { off_the_record: false,
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
    let (ops, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 1, cause: Cause::Command(command.id.clone()),
        strips: vec![strip_empty("one")],
    });
    assert!(outcome.applied);
    assert!(!ops.is_empty());
    assert_eq!(live.live_tab("a"), None);
    assert_eq!(live.item_for(&command.id), None);
    assert_eq!(ws.items["a"].lifecycle, Lifecycle::Unloaded);
    assert!(live.open(&mut ws, "a", "u").is_ok());
    let (_, duplicate) = live.apply(&mut ws, Transaction { off_the_record: false,
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
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 1, cause: Cause::Command(open.id.clone()),
        strips: vec![strip(&live, &["a"], Some("a"))],
    });
    assert!(outcome.applied);
    let activate = live.activate(&ws, "a").unwrap();
    live.command_sent(&activate);
    assert!(live.cancel(&mut ws, &activate.id).0);
    assert!(!live.cancel(&mut ws, &activate.id).0);
    assert_eq!(live.live_tab("a").as_deref(), Some(open.id.as_str()));
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
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

#[test]
fn refused_close_restores_placement_selection_history_and_the_same_live_tab() {
    for (item, archive) in [("b", false), ("b", true), ("pinned", false), ("pinned", true), ("nested", false)] {
        let mut ws = workspace();
        ws.create_folder("folder", "Folder", "space-work:pinned", 0, &[]).unwrap();
        tab(&mut ws, "nested", "folder", "https://nested.example/");
        let mut live = Live::new();
        let tabs = ["a", item].into_iter().map(|id| LiveTab {
            off_the_record: false, profile: Default::default(), live_id: format!("live-{id}"),
            item: Some(id.into()), opener: None, navigated: false, url: None, title: None,
        }).collect();
        live.apply(&mut ws, snapshot_tx(vec![Strip { window: "one".into(), tabs, active: Some(format!("live-{item}")) }]));
        let before = ws.clone();
        let (_, command) = if archive { live.archive(&mut ws, item) } else { live.close(&mut ws, item) }.unwrap();
        assert_eq!(live.live_tab(item), None);
        assert!(ws.history_purges.keys().all(|id| live.pending_close_purge(id)));
        let (cancelled, ops) = live.cancel_close(&mut ws, &command.id);
        assert!(cancelled);
        assert!(!ops.is_empty());
        assert_eq!(ws, before);
        assert_eq!(live.live_tab(item), Some(format!("live-{item}")));
        assert_eq!(live.item_for(&format!("live-{item}")), Some(item.into()));
        assert_eq!(live.live_window(item).as_deref(), Some("one"));
        assert!(!live.pending_close_purge("unknown"));
        assert_eq!(live.cancel_close(&mut ws, &command.id), (false, vec![]));
        assert_eq!(live.cancel_close(&mut ws, "unknown"), (false, vec![]));
        let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 1,
            cause: Cause::Engine, strips: vec![strip(&live, &["a", item], Some(item))] });
        assert!(outcome.applied);
        let (_, later) = live.close(&mut ws, item).unwrap();
        assert!(live.settle_close(&later.id));
        assert_eq!(live.cancel_close(&mut ws, &later.id), (false, vec![]));
        assert_eq!(live.live_tab(item), None);
    }
}

#[test]
fn refused_close_keeps_a_later_edit_and_an_unrelated_row() {
    let mut ws = workspace();
    let mut live = Live::new();
    live.apply(&mut ws, snapshot_tx(vec![Strip { window: "one".into(), tabs: vec![LiveTab {
        off_the_record: false, profile: Default::default(), live_id: "live".into(), item: Some("a".into()),
        opener: None, navigated: false, url: None, title: None,
    }], active: Some("live".into()) }]));
    let (_, close) = live.close(&mut ws, "a").unwrap();
    ws.items.get_mut("c").unwrap().title = Some("new title".into());
    ws.set_new_tab_row_shown(false);
    assert!(live.cancel_close(&mut ws, &close.id).0);
    assert_eq!(ws.items["c"].title.as_deref(), Some("new title"));
    assert!(!ws.settings.new_tab_row_shown);
}

fn snapshot_tx(strips: Vec<Strip>) -> Transaction {
    Transaction { off_the_record: false, epoch: 1, rev: 0, cause: Cause::Engine, strips }
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
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![strip(&live, &["a", "b"], Some("b"))],
    });
    assert!(outcome.applied);
    assert_eq!(ws.selected("one"), Some("b"));
    assert!(ws.windows["one"].history.contains(&"b".to_string()));
}

#[test]
fn a_late_activation_from_the_space_the_window_left_keeps_the_shown_selection() {
    let mut ws = workspace();
    ws.create_space("one", "Other", "other").unwrap();
    tab(&mut ws, "d", "other:today", "https://d.example");
    ws.show_space("one", "space-work").unwrap();
    let mut live = Live::new();
    for item in ["a", "d"] {
        let (_, command) = live.open(&mut ws, item, "u").unwrap();
        live.command_sent(&command);
    }
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a", "d"], Some("a"))]));
    assert_eq!(ws.selected("one"), Some("a"));
    // The user selects a in the space the window shows; its activation is still in flight.
    let late = live.activate(&ws, "a").unwrap();
    live.command_sent(&late);
    // The user then shows the other space, where d is activated and its reply lands.
    ws.show_space("one", "other").unwrap();
    let shown = live.activate(&ws, "d").unwrap();
    live.command_sent(&shown);
    live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 1, cause: Cause::Command(shown.id.clone()),
        strips: vec![strip(&live, &["a", "d"], Some("d"))],
    });
    assert_eq!(ws.selected("one"), Some("d"));
    // The late activation of a completes with a as the active tab, but a is in the space the
    // window left: the strip keeps its mapping and must not take the selection back.
    let (ops, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 2, cause: Cause::Command(late.id.clone()),
        strips: vec![strip(&live, &["a", "d"], Some("a"))],
    });
    assert!(outcome.applied);
    assert_eq!(ws.selected("one"), Some("d"));
    assert_eq!(ws.windows["one"].history.first().map(String::as_str), Some("d"));
    assert!(live.live_tab("a").is_some());
    assert!(live.item_for(&late.id).is_none());
    assert!(!ops.iter().any(|op| matches!(op, Op::Put(Record::Window(_)))));
    // Chrome stays on a, and the page follows Chrome, so the core answers with one Activate
    // for the row the window keeps — the close successor's shape. The command names the tab,
    // not the window; its strip is the one that reported the off-space active tab.
    assert_eq!(outcome.commands.len(), 1);
    let reassert = outcome.commands[0].clone();
    assert_eq!(reassert.kind, CommandKind::Activate);
    assert_eq!(reassert.item, "d");
    assert!(reassert.url.is_none());
    assert!(reassert.id.starts_with("cmd-"));
    assert!(live.item_for(&reassert.id).is_none());
    // While that Activate is in flight, another Chrome strip that still names a must not mint
    // a second one: the in-flight entry covers it as well as this transaction's.
    let (_, second) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 3, cause: Cause::Chrome,
        strips: vec![strip(&live, &["a", "d"], Some("a"))],
    });
    assert!(second.commands.is_empty());
    assert_eq!(ws.selected("one"), Some("d"));
    // The reply names d: its strip passes the guard, the selection is already d, so it records
    // nothing and asks for no further command. The exchange ends here.
    let (reply_ops, reply) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 4, cause: Cause::Command(reassert.id.clone()),
        strips: vec![strip(&live, &["a", "d"], Some("d"))],
    });
    assert!(reply.applied);
    assert!(reply.commands.is_empty());
    assert!(reply_ops.is_empty());
    assert_eq!(ws.selected("one"), Some("d"));
    // A Chrome-caused strip is answered the same way. A selection cancels that Activate, and
    // the cancel clears the in-flight entry, so the next strip asks again instead of finding a
    // stale one.
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 5, cause: Cause::Chrome,
        strips: vec![strip(&live, &["a", "d"], Some("a"))],
    });
    assert_eq!(ws.selected("one"), Some("d"));
    assert_eq!(outcome.commands.len(), 1);
    assert_eq!(outcome.commands[0].kind, CommandKind::Activate);
    assert_eq!(outcome.commands[0].item, "d");
    let (cancelled, cancel_ops) = live.cancel(&mut ws, &outcome.commands[0].id);
    assert!(cancelled);
    assert!(cancel_ops.is_empty());
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 6, cause: Cause::Chrome,
        strips: vec![strip(&live, &["a", "d"], Some("a"))],
    });
    assert_eq!(outcome.commands.len(), 1);
    assert_eq!(outcome.commands[0].item, "d");
    // The shown space's own active tab records once the window shows that space again, and
    // the strip asks for nothing.
    ws.show_space("one", "space-work").unwrap();
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 7, cause: Cause::Chrome,
        strips: vec![strip(&live, &["a", "d"], Some("a"))],
    });
    assert_eq!(ws.selected("one"), Some("a"));
    assert!(outcome.commands.is_empty());
    // A selection the window does not show is not re-activated: both tabs are outside the
    // shown space there, so the core asserts nothing and the next strip of the shown space
    // records instead. Applying that strip does not loop either.
    ws.show_space("one", "other").unwrap();
    let (_, b) = live.open(&mut ws, "b", "u").unwrap();
    live.command_sent(&b);
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 8, cause: Cause::Chrome,
        strips: vec![strip(&live, &["a", "b", "d"], Some("b"))],
    });
    assert_eq!(ws.selected("one"), Some("a"));
    assert!(outcome.commands.is_empty());
}

#[test]
fn a_swallowed_activation_does_not_silence_the_reopened_row() {
    let mut ws = workspace();
    ws.create_space("one", "Other", "other").unwrap();
    tab(&mut ws, "d", "other:today", "https://d.example");
    ws.show_space("one", "space-work").unwrap();
    let mut live = Live::new();
    for item in ["a", "d"] {
        let (_, command) = live.open(&mut ws, item, "u").unwrap();
        live.command_sent(&command);
    }
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a", "d"], Some("a"))]));
    // The window shows other with d selected; an off-space strip asks for d once.
    ws.show_space("one", "other").unwrap();
    ws.select_item("one", "d").unwrap();
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![strip(&live, &["a", "d"], Some("a"))],
    });
    assert_eq!(outcome.commands.len(), 1);
    assert_eq!(outcome.commands[0].item, "d");
    let dropped = outcome.commands[0].id.clone();
    // The engine swallows it and reports a strip without d: the tab leaves the map, and its
    // in-flight Activate must leave with it.
    let act_a = live.activate(&ws, "a").unwrap();
    live.command_sent(&act_a);
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 2, cause: Cause::Command(act_a.id.clone()),
        strips: vec![strip(&live, &["a"], Some("a"))],
    });
    assert!(outcome.commands.is_empty());
    assert!(live.live_tab("d").is_none());
    // The row is opened again; an off-space strip must be free to ask for it again.
    let (_, reopened) = live.open(&mut ws, "d", "u").unwrap();
    live.command_sent(&reopened);
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 3, cause: Cause::Chrome,
        strips: vec![strip(&live, &["a", "d"], Some("a"))],
    });
    assert_eq!(ws.selected("one"), Some("d"));
    assert_eq!(outcome.commands.len(), 1);
    assert_eq!(outcome.commands[0].kind, CommandKind::Activate);
    assert_eq!(outcome.commands[0].item, "d");
    // A reply for the dropped id names no command in flight: the transaction is dropped whole.
    let before = ws.clone();
    let (ops, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 4, cause: Cause::Command(dropped),
        strips: vec![strip(&live, &["a", "d"], Some("d"))],
    });
    assert!(!outcome.applied);
    assert!(ops.is_empty());
    assert_eq!(ws, before);
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
    live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 1, cause: Cause::Chrome, strips: vec![strip(&live, &["a", "b", "c"], Some("c"))] });
    assert_eq!(ws.selected("one"), Some("c"));
    live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 2, cause: Cause::Chrome, strips: vec![strip(&live, &["a", "b", "c"], Some("b"))] });
    assert_eq!(ws.selected("one"), Some("b"));
    // Chrome closes b and moves to a; the history says c was selected before b, so the
    // coordinator returns an activate for c instead of trusting a.
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
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
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
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
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 0, cause: Cause::Chrome, strips: vec![strip(&live, &["a"], None)] });
    assert!(!outcome.applied);
    // rev 1 applies, rev 1 again is dropped
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 1, cause: Cause::Chrome, strips: vec![strip(&live, &["a"], None)] });
    assert!(outcome.applied);
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 1, cause: Cause::Chrome, strips: vec![strip(&live, &["a"], None)] });
    assert!(!outcome.applied);
    // a new epoch that does not arrive as a full snapshot is dropped
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 2, rev: 7, cause: Cause::Chrome, strips: vec![strip(&live, &["a"], None)] });
    assert!(!outcome.applied);
    // the snapshot for the new epoch lands, and the old epoch is dropped after it
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 2, rev: 0, cause: Cause::Chrome, strips: vec![] });
    assert!(outcome.applied);
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 9, cause: Cause::Chrome, strips: vec![] });
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
    live.apply(&mut ws, Transaction { off_the_record: false, epoch: 2, rev: 0, cause: Cause::Engine, strips: vec![] });
    // The completion still carries the epoch it was issued in: dropped.
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 0, cause: Cause::Command(command.id.clone()), strips: vec![] });
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
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 2, rev: 0, cause: Cause::Engine,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![
                LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "live-a".into(), item: Some("a".into()) },
                LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "live-c".into(), item: Some("c".into()) },
                LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "live-pinned".into(), item: Some("pinned".into()) },
                LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "live-new".into(), item: None },
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
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![
                LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: reused.clone(), item: Some("b".into()) },
                LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: live.live_tab("b").unwrap(), item: Some("b".into()) },
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
    let (ops, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![
                LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: live.live_tab("a").unwrap(), item: Some("a".into()) },
                LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "live-new".into(), item: None },
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
        tabs: vec![LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "La".into(), item: Some("a".into()) }],
        active: Some("La".into()),
    }]));
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![
                LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "La".into(), item: Some("a".into()) },
                LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "new".into(), item: None },
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
            LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "La".into(), item: Some("a".into()) },
            LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "new".into(), item: None },
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
        tabs: vec![LiveTab { off_the_record: false, profile: Default::default(),
            live_id: "new".into(), item: None, opener: None, navigated: false,
            url: Some("https://first.example/".into()), title: Some("First".into()),
        }],
        active: Some("new".into()),
    }]));
    let id = outcome.adopted[0].1.clone();
    assert_eq!(ws.items[&id].display_title(), "First");
    assert!(matches!(&ws.items[&id].kind, ItemKind::Tab { url, .. } if url == "https://first.example/"));
    ws.rename_tab(&id, "Custom").unwrap();
    live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 1, cause: Cause::Engine,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![LiveTab { off_the_record: false, profile: Default::default(),
                live_id: "new".into(), item: Some(id.clone()), opener: None, navigated: true,
                url: Some("https://second.example/".into()), title: Some("Second".into()),
            }],
            active: Some("new".into()),
        }],
    });
    assert_eq!(ws.items[&id].display_title(), "Custom");
    assert!(matches!(&ws.items[&id].kind, ItemKind::Tab { url, saved_title: Some(title) } if url == "https://second.example/" && title == "Second"));
    ws.set_tab_url(&id, "https://pending.example/").unwrap();
    live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 2, cause: Cause::Engine,
        strips: vec![Strip { window: "one".into(), tabs: vec![LiveTab { off_the_record: false, profile: Default::default(),
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
        tabs: vec![LiveTab { off_the_record: false, profile: Default::default(),
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
        tabs: vec![LiveTab { off_the_record: false, profile: Default::default(),
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
        tabs: vec![LiveTab { off_the_record: false, profile: Default::default(),
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

// P5b (review 1 F6): a launch that opens a new window throws every kept record away, as a user's
// close does one at a time, so nothing piles up across launches and a later Restore has no window
// to bring back. Only Window records go: the spaces and their items stay.
#[test]
fn a_new_window_launch_discards_every_kept_window_record() {
    let mut ws = workspace();
    ws.windows.get_mut("one").unwrap().changed_at = 0;
    ws.show_space("older", "space-work").unwrap();
    ws.windows.get_mut("older").unwrap().changed_at = 100;
    ws.show_space("newer", "space-work").unwrap();
    ws.windows.get_mut("newer").unwrap().changed_at = 200;
    let spaces = ws.spaces.iter().map(|s| s.id.clone()).collect::<Vec<_>>();
    let items = ws.items.len();
    assert_eq!(ws.kept_windows().len(), 3);

    let ops = ws.discard_kept_windows();
    assert_eq!(ops.len(), 3);
    assert!(ops.iter().all(|op| matches!(op, Op::Delete(ararat_core::model::Kind::Window, _))));
    assert!(ws.kept_windows().is_empty());
    assert!(ws.windows.is_empty());
    assert_eq!(ws.spaces.iter().map(|s| s.id.clone()).collect::<Vec<_>>(), spaces);
    assert_eq!(ws.items.len(), items);
    // A peer that applies the batch agrees, and a second call writes nothing.
    let mut peer = ws.clone();
    for op in &ops { peer.apply(op); }
    assert_eq!(peer, ws);
    assert!(ws.discard_kept_windows().is_empty());
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
    live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 0, cause: Cause::Engine,
        strips: vec![
            Strip { window: "one".into(), tabs: vec![LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "L1".into(), item: Some("a".into()) }], active: Some("L1".into()) },
            Strip { window: "two".into(), tabs: vec![LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "L2".into(), item: Some("home".into()) }], active: None },
        ],
    });
    // Window two's shown space is space-home: the itemless tab there adopts into
    // space-home:today, not into window one's Today.
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![
            Strip { window: "one".into(), tabs: vec![LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "L1".into(), item: Some("a".into()) }], active: Some("L1".into()) },
            Strip { window: "two".into(), tabs: vec![LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "L2".into(), item: Some("home".into()) }, LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "L3".into(), item: None }], active: Some("L3".into()) },
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
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![
                LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: live.live_tab("a").unwrap(), item: Some("a".into()) },
                LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: live.live_tab("b").unwrap(), item: Some("a".into()) },
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
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![strip(&live, &["a", "b", "c"], None)],
    });
    assert!(!outcome.applied);
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
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
    live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 0, cause: Cause::Engine,
        strips: vec![
            Strip { window: "one".into(), tabs: vec![LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "La".into(), item: Some("a".into()) }, LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "Lb".into(), item: Some("b".into()) }], active: Some("La".into()) },
            Strip { window: "two".into(), tabs: vec![LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "Lc".into(), item: Some("home".into()) }], active: Some("Lc".into()) },
        ],
    });
    // The transaction names only window two: window one's tabs stay open and mapped.
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![Strip { window: "two".into(), tabs: vec![LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "Lc".into(), item: Some("home".into()) }], active: Some("Lc".into()) }],
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
    live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 0, cause: Cause::Engine,
        strips: vec![
            Strip { window: "one".into(), tabs: vec![LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "La".into(), item: Some("a".into()) }, LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "Lb".into(), item: Some("b".into()) }], active: Some("La".into()) },
            Strip { window: "two".into(), tabs: vec![LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "Lc".into(), item: Some("home".into()) }], active: Some("Lc".into()) },
        ],
    });
    // Window two closed: its strip arrives empty, and its tab is gone for the core's
    // rules (Chrome caused it, so the ⌘W rule closes the row).
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![
            Strip { window: "one".into(), tabs: vec![LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "La".into(), item: Some("a".into()) }, LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "Lb".into(), item: Some("b".into()) }], active: Some("La".into()) },
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
    live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 0, cause: Cause::Engine,
        strips: vec![Strip { window: "one".into(), tabs: vec![LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None,
            live_id: "La".into(), item: Some("a".into()),
        }], active: Some("La".into()) }],
    });
    let (ops, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
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
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 0, cause: Cause::Engine,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![
                LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "Lp".into(), item: Some("pinned".into()) },
                LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "La".into(), item: Some("a".into()) },
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
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 0, cause: Cause::Engine,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "Lb".into(), item: Some("b".into()) }],
            active: Some("Lb".into()),
        }],
    });
    assert!(outcome.applied);
    let (_, command_a) = live.open(&mut ws, "a", "u").unwrap();
    live.command_sent(&command_a);
    assert_eq!(ws.items["a"].lifecycle, Lifecycle::Open);
    // The engine has not created the tab yet: Chrome's transaction still names only b.
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "Lb".into(), item: Some("b".into()) }],
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
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 2, cause: Cause::Command(command_a.id.clone()),
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![
                LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "Lb".into(), item: Some("b".into()) },
                LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: command_a.id.clone(), item: Some("a".into()) },
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
    let (tx_ops, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 1, cause: Cause::Chrome,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: open_command.id.clone(), item: Some("pinned".into()) }],
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
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 2, cause: Cause::Engine,
        strips: vec![strip(&live, &[], None)],
    });
    assert!(outcome.applied);
    assert!(live.live_tab("pinned").is_none());
    assert_eq!(ws.items["pinned"].lifecycle, Lifecycle::Unloaded);
}

#[test]
fn a_snapshot_rejects_duplicate_live_ids() {
    let mut ws = workspace();
    let mut live = Live::new();
    let before = ws.clone();
    let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false,
        epoch: 1, rev: 0, cause: Cause::Engine,
        strips: vec![Strip {
            window: "one".into(),
            tabs: vec![
                LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "L1".into(), item: Some("a".into()) },
                LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "L1".into(), item: Some("b".into()) },
            ],
            active: Some("L1".into()),
        }],
    });
    assert!(!outcome.applied);
    assert_eq!(ws, before);
    assert_eq!(live.live_tab("a"), None);
    assert_eq!(live.live_tab("b"), None);
    assert_eq!(live.item_for("L1"), None);
    let (_, outcome) = live.apply(&mut ws, snapshot_tx(vec![strip_empty("one")]));
    assert!(outcome.applied);
    assert_eq!(ws.items["a"].lifecycle, Lifecycle::Unloaded);
}

#[test]
fn paired_strips_move_ownership_and_reject_duplicate_claims() {
    let mut ws = workspace();
    let mut live = Live::new();
    let tab = LiveTab { off_the_record: false, profile: Default::default(), opener: None, navigated: false, url: None, title: None, live_id: "L1".into(), item: Some("a".into()) };
    let source = Strip { window: "one".into(), tabs: vec![tab.clone()], active: None };
    let destination = Strip { window: "two".into(), tabs: vec![], active: None };
    assert!(live.apply(&mut ws, snapshot_tx(vec![source.clone(), destination])).1.applied);
    assert_eq!(live.live_window("a").as_deref(), Some("one"));
    let target = Strip { window: "two".into(), tabs: vec![tab], active: None };
    let before = ws.clone();
    assert!(!live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 1, cause: Cause::Chrome, strips: vec![source, target.clone()] }).1.applied);
    assert_eq!(ws, before);
    assert_eq!(live.live_window("a").as_deref(), Some("one"));
    assert!(live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 2, cause: Cause::Chrome, strips: vec![strip_empty("one"), target] }).1.applied);
    assert_eq!(live.live_window("a").as_deref(), Some("two"));
    assert_eq!(ws.items["a"].lifecycle, Lifecycle::Open);
    assert!(ws.history_purges.is_empty());
    assert!(!live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 3, cause: Cause::Engine, strips: vec![strip_empty("one"), strip_empty("one")] }).1.applied);
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
        Strip { window: "one".into(), tabs: vec![LiveTab { off_the_record: false, profile: Profile::Named("Profile 1".into()), live_id: "first".into(), item: None, opener: None, navigated: false, url: None, title: None }], active: None },
        Strip { window: "two".into(), tabs: vec![LiveTab { off_the_record: false, profile: Profile::Named("Profile 1".into()), live_id: "second".into(), item: None, opener: None, navigated: false, url: None, title: None }], active: None },
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
        tabs: vec![LiveTab { off_the_record: false, profile: Profile::Named("Profile 1".into()), live_id: "foreign".into(), item: Some("a".into()), opener: None, navigated: false, url: None, title: None }],
    }]));
    assert!(!outcome.applied);
    assert!(ops.is_empty());
    assert_eq!(ws, before);
}

// U25b D6: Clear archives Today's rows in one batch and, in the same step, puts a Close in
// flight for every mapped live row, so the engine's replies are accepted (an unknown command
// is dropped whole) and the map forgets them. Two rows are loaded, one is unloaded.
#[test]
fn clearing_today_puts_a_close_in_flight_for_each_live_row() {
    let mut ws = workspace();
    let mut live = Live::new();
    for item in ["a", "b"] {
        let (_, command) = live.open(&mut ws, item, "https://example.test/").unwrap();
        live.command_sent(&command);
    }
    live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a", "b"], Some("a"))]));
    {
        let item = ws.items.get_mut("c").unwrap();
        item.lifecycle = Lifecycle::Unloaded;
        item.lifecycle_changed_at = 1;
    }
    let (ops, targets, _) = live.clear_today(&mut ws, "space-work").unwrap();
    assert_eq!(targets.len(), 2);
    assert_eq!(targets.iter().map(|(_, command)| command.item.as_str()).collect::<Vec<_>>(), ["a", "b"]);
    // One batch archives the loaded and the unloaded row alike.
    let archived: Vec<_> = ops.iter().filter_map(|op| match op {
        Op::Put(Record::Item(item)) if item.lifecycle == Lifecycle::Archived => Some(item.id.as_str()),
        _ => None,
    }).collect();
    assert_eq!(archived, ["a", "b", "c"]);
    for item in ["a", "b", "c"] { assert_eq!(ws.items[item].lifecycle, Lifecycle::Archived, "{item}"); }
    // The snapshot apply unloads rows the engine lacks; a pin is never archived by Clear.
    assert_ne!(ws.items["pinned"].lifecycle, Lifecycle::Archived);
    // The engine answers each close with the command's id: the replies name commands in
    // flight, so they are applied and the map lets the rows go.
    let (_, first) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 1, cause: Cause::Command(targets[0].1.id.clone()),
        strips: vec![strip_empty("one")] });
    assert!(first.applied);
    let (_, second) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 2, cause: Cause::Command(targets[1].1.id.clone()),
        strips: vec![strip_empty("one")] });
    assert!(second.applied);
    for item in ["a", "b"] { assert_eq!(live.live_tab(item), None, "{item}"); }
}

#[test]
fn live_auto_archive_keeps_thresholds_and_protected_rows_and_closes_only_loaded_rows() {
    use ararat_core::model::ArchiveAfter;
    for option in [ArchiveAfter::Hours12, ArchiveAfter::Hours24, ArchiveAfter::Days7, ArchiveAfter::Days30] {
        let mut ws = workspace();
        let mut live = Live::new();
        ws.ensure_favorites("space-work", "favorites").unwrap();
        tab(&mut ws, "favorite", "favorites", "https://favorite.test/");
        tab(&mut ws, "unloaded", "space-work:today", "https://unloaded.test/");
        ws.items.get_mut("unloaded").unwrap().lifecycle = Lifecycle::Unloaded;
        for item in ["a", "b", "c", "pinned", "favorite"] {
            let (_, command) = live.open(&mut ws, item, "https://example.test/").unwrap();
            live.command_sent(&command);
        }
        live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a", "b", "c", "pinned", "favorite"], Some("b"))]));
        ws.select_item_at("other", "c", 0).unwrap();
        for item in ["a", "b", "c", "unloaded", "pinned", "favorite"] { ws.last_selected.insert(item.into(), 0); }
        ws.set_archive_after(Default::default(), option);
        assert!(live.auto_archive(&mut ws, option.millis()).unwrap().0.is_empty());
        let activation = live.activate(&ws, "a").unwrap();
        live.command_sent(&activation);
        live.selection_intent(&activation.id, "one");
        let (_, targets) = live.auto_archive(&mut ws, option.millis() + 1).unwrap();
        assert_eq!(targets.len(), 1);
        assert_eq!(targets[0].1.item, "a");
        for item in ["a", "unloaded"] { assert_eq!(ws.items[item].lifecycle, Lifecycle::Archived); }
        for item in ["b", "c", "pinned", "favorite"] { assert_ne!(ws.items[item].lifecycle, Lifecycle::Archived); }
        assert!(live.live_tab("a").is_none());
        assert!(!live.selection_intent(&activation.id, "one"));
        let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 1, cause: Cause::Command(targets[0].1.id.clone()),
            strips: vec![strip(&live, &["b", "c", "pinned", "favorite"], Some("b"))] });
        assert!(outcome.applied);
    }
}

#[test]
fn live_delete_space_closes_its_loaded_rows_and_preserves_profile_favorites_and_last_space() {
    let mut ws = workspace();
    ws.create_space("two", "Home", "space-home").unwrap();
    ws.show_space("one", "space-work").unwrap();
    ws.ensure_favorites("space-work", "favorites").unwrap();
    tab(&mut ws, "favorite", "favorites", "https://favorite.test/");
    let mut live = Live::new();
    for item in ["a", "pinned", "favorite"] {
        let (_, command) = live.open(&mut ws, item, "https://example.test/").unwrap();
        live.command_sent(&command);
    }
    let (_, targets) = live.delete_space(&mut ws, "space-work").unwrap();
    let mut items: Vec<_> = targets.iter().map(|(_, command)| command.item.as_str()).collect();
    items.sort();
    assert_eq!(items, ["a", "pinned"]);
    assert_eq!(ws.shown_space("one"), Some("space-home"));
    assert!(live.live_tab("favorite").is_some());
    assert_eq!(ws.items["favorite"].lifecycle, Lifecycle::Open);
    for item in ["a", "b", "c", "pinned"] { assert_eq!(ws.items[item].lifecycle, Lifecycle::Archived); }
    let before = ws.clone();
    assert!(live.delete_space(&mut ws, "space-home").is_err());
    assert_eq!(ws, before);
    for (_, command) in targets { assert!(live.settle_close(&command.id)); }
}

#[test]
fn private_live_batches_do_not_auto_archive_or_delete_spaces() {
    let mut ws = Workspace::private(Default::default());
    let mut live = Live::new();
    let before = ws.clone();
    assert!(live.auto_archive(&mut ws, u64::MAX).unwrap().0.is_empty());
    assert!(live.delete_space(&mut ws, "private").is_err());
    assert_eq!(ws, before);
}

#[test]
fn bulk_close_stay_restores_only_the_refused_row_and_keeps_its_live_identity() {
    use ararat_core::model::{ArchiveAfter, SplitSide};
    for operation in ["split", "clear", "clear-split", "auto", "delete"] {
        for refused in ["a", "b"] {
            let mut ws = workspace();
            ws.create_space("two", "Home", "home").unwrap();
            ws.create_space("three", "Other", "other").unwrap();
            ws.show_space("one", "space-work").unwrap();
            let split = if operation == "split" || operation == "clear-split" {
                Some(ws.make_split("a", "b", SplitSide::Right).unwrap().1.split)
            } else { None };
            let mut live = Live::new();
            let tabs = ["a", "b", "pinned"].into_iter().map(|id| LiveTab {
                off_the_record: false, profile: Default::default(), live_id: format!("live-{id}"),
                item: Some(id.into()), opener: None, navigated: false, url: None, title: None,
            }).collect();
            live.apply(&mut ws, snapshot_tx(vec![Strip { window: "one".into(), tabs, active: Some(if operation == "auto" { "live-pinned" } else { "live-a" }.into()) }]));
            ws.last_selected.insert("a".into(), 0);
            ws.last_selected.insert("b".into(), 0);
            let history_profile = ws.history_profiles.get(refused).cloned();
            let targets = match operation {
                "split" => live.close_split(&mut ws, split.as_ref().unwrap()).unwrap().1,
                "clear" | "clear-split" => live.clear_today(&mut ws, "space-work").unwrap().1,
                "auto" => live.auto_archive(&mut ws, ArchiveAfter::Hours12.millis() + 1).unwrap().1,
                "delete" => live.delete_space(&mut ws, "space-work").unwrap().1,
                _ => unreachable!(),
            };
            let close = &targets.iter().find(|(_, command)| command.item == refused).unwrap().1;
            let accepted = if refused == "a" { "b" } else { "a" };
            let other = &targets.iter().find(|(_, command)| command.item == accepted).unwrap().1;
            assert!(live.settle_close(&other.id));
            let settled = ws.items[accepted].clone();
            if operation == "delete" { ws.show_space("one", "other").unwrap(); }
            let mut replay = ws.clone();
            let (cancelled, ops) = live.cancel_close(&mut ws, &close.id);
            for op in &ops { replay.apply(op); }
            assert!(cancelled, "{operation}");
            assert_eq!(ws, replay);
            ws.check_tree().unwrap();
            assert_eq!(ws.items[refused].lifecycle, Lifecycle::Open, "{operation}");
            assert_eq!(ws.items[accepted], settled, "{operation}");
            assert_eq!(live.live_tab(refused), Some(format!("live-{refused}")));
            assert_eq!(live.live_window(refused).as_deref(), Some("one"));
            assert_eq!(live.live_tab(accepted), None);
            assert!(ws.history_purges.values().all(|(_, item, _)| item != refused));
            assert_eq!(ws.history_profiles.get(refused), history_profile.as_ref());
            if operation != "auto" && refused == "a" { assert_eq!(ws.selected("one"), Some("a")); }
            if operation == "delete" {
                assert!(ws.spaces.iter().all(|space| space.id != "space-work"));
                assert_eq!(ws.items[refused].membership.parent.as_deref(), Some("other:today"));
            }
            let (_, outcome) = live.apply(&mut ws, Transaction { off_the_record: false, epoch: 1, rev: 1, cause: Cause::Engine,
                strips: vec![strip(&live, &[refused], Some(refused))] });
            assert!(outcome.applied);
            assert!(outcome.commands.iter().all(|command| command.kind != CommandKind::Close || command.item != refused));
        }
    }
}

#[test]
fn private_split_stay_restores_the_refused_pane_without_restoring_the_other() {
    use ararat_core::model::SplitSide;
    let mut ws = Workspace::private(Default::default());
    let a = ws.create_tab("one", "https://a.example").unwrap().iter().find_map(|op| match op {
        Op::Put(Record::Item(item)) if matches!(item.kind, ItemKind::Tab { .. }) => Some(item.id.clone()), _ => None,
    }).unwrap();
    let b = ws.create_tab("one", "https://b.example").unwrap().iter().find_map(|op| match op {
        Op::Put(Record::Item(item)) if matches!(item.kind, ItemKind::Tab { .. }) => Some(item.id.clone()), _ => None,
    }).unwrap();
    let split = ws.make_split(&a, &b, SplitSide::Right).unwrap().1.split;
    let mut live = Live::new();
    let tabs = [&a, &b].into_iter().map(|id| LiveTab {
        off_the_record: true, profile: Default::default(), live_id: format!("live-{id}"), item: Some(id.clone()),
        opener: None, navigated: false, url: None, title: None,
    }).collect();
    live.apply(&mut ws, Transaction { off_the_record: true, epoch: 1, rev: 0, cause: Cause::Engine,
        strips: vec![Strip { window: "one".into(), tabs, active: Some(format!("live-{a}")) }] });
    let (_, targets) = live.close_split(&mut ws, &split).unwrap();
    let command = &targets.iter().find(|(_, command)| command.item == a).unwrap().1;
    assert!(live.cancel_close(&mut ws, &command.id).0);
    assert_eq!(ws.items[&a].lifecycle, Lifecycle::Open);
    assert!(!ws.items.contains_key(&b));
    assert_eq!(live.live_tab(&a), Some(format!("live-{a}")));
    assert_eq!(ws.selected("one"), Some(a.as_str()));
    ws.check_tree().unwrap();
}

#[test]
fn archive_split_groups_live_members_and_restores_after_a_partial_refusal() {
    use ararat_core::model::SplitSide;
    for refused in [None, Some("a"), Some("b")] {
        let mut ws = workspace();
        let split = ws.make_split("a", "b", SplitSide::Right).unwrap().1.split;
        let members = ws.children(&split).iter().map(|item| item.id.clone()).collect::<Vec<_>>();
        let kind = ws.items[&split].kind.clone();
        let mut live = Live::new();
        for id in ["a", "b"] {
            let (_, command) = live.open(&mut ws, id, "https://example.test/").unwrap();
            live.command_sent(&command);
        }
        live.apply(&mut ws, snapshot_tx(vec![strip(&live, &["a", "b"], Some("a"))]));
        let (_, targets) = live.archive_split(&mut ws, &split).unwrap();
        assert_eq!(targets.len(), 2);
        assert!(ws.archive().iter().any(|item| item.id == split));
        assert!(!ws.archive().iter().any(|item| item.id == "a" || item.id == "b"));
        for (_, command) in &targets {
            if Some(command.item.as_str()) == refused {
                assert!(live.cancel_close(&mut ws, &command.id).0);
            } else {
                assert!(live.settle_close(&command.id));
            }
        }
        if let Some(refused) = refused {
            let accepted = if refused == "a" { "b" } else { "a" };
            assert_eq!(ws.items[&split].lifecycle, Lifecycle::Open);
            assert!(ws.items[&split].archive.is_none());
            assert_eq!(ws.items[refused].lifecycle, Lifecycle::Open);
            assert!(ws.items[refused].archive.is_none());
            assert_eq!(ws.items[accepted].lifecycle, Lifecycle::Archived);
            assert_eq!(ws.items[accepted].archive.as_ref().unwrap().group.as_deref(), Some(split.as_str()));
            assert!(ws.archive().iter().any(|item| item.id == accepted));
            assert!(!ws.archive().iter().any(|item| item.id == split));
            let (_, retried) = live.archive_split(&mut ws, &split).unwrap();
            assert_eq!(retried.len(), 1);
            assert_eq!(retried[0].1.item, refused);
            assert!(live.settle_close(&retried[0].1.id));
            assert!(ws.archive().iter().any(|item| item.id == split));
            assert!(!ws.archive().iter().any(|item| item.id == accepted));
        }
        ws.restore_item("one", &split).unwrap();
        assert_eq!(ws.items[&split].kind, kind);
        assert_eq!(ws.children(&split).iter().map(|item| item.id.clone()).collect::<Vec<_>>(), members);
        for id in [split.as_str(), "a", "b"] {
            assert_eq!(ws.items[id].lifecycle, Lifecycle::Open);
            assert!(ws.items[id].archive.is_none());
        }
        ws.check_tree().unwrap();
    }
}
