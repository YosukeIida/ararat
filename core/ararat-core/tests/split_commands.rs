use ararat_core::edit::{EditError, SplitChange};
use ararat_core::model::{ItemKind, Kind, Lifecycle, Op, Orientation, SplitSide, Workspace};
use ararat_core::{import::arc_sidebar, storage::Store};

fn workspace() -> Workspace {
    let mut ws = arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json"), None, None, None, None).unwrap().0;
    ws.spaces[1].profile = ararat_core::model::Profile::Default;
    ws
}

fn children(ws: &Workspace, parent: &str) -> Vec<String> {
    ws.children(parent).iter().map(|item| item.id.clone()).collect()
}

// Every op is judged twice: applied to a clone of the state before it and compared (what the
// journal's replay answers), and on a tree that still passes its checks.
fn replayed(ws: &mut Workspace, run: impl FnOnce(&mut Workspace) -> Result<Vec<Op>, EditError>) -> Vec<Op> {
    let mut replay = ws.clone();
    let ops = run(ws).unwrap();
    for op in &ops { replay.apply(op); }
    assert_eq!(*ws, replay);
    ws.check_tree().unwrap();
    ops
}

fn replayed_split(ws: &mut Workspace, run: impl FnOnce(&mut Workspace) -> Result<(Vec<Op>, SplitChange), EditError>) -> (Vec<Op>, SplitChange) {
    let mut replay = ws.clone();
    let (ops, change) = run(ws).unwrap();
    for op in &ops { replay.apply(op); }
    assert_eq!(*ws, replay);
    ws.check_tree().unwrap();
    (ops, change)
}

fn refused(ws: &mut Workspace, run: impl FnOnce(&mut Workspace) -> Result<Vec<Op>, EditError>) {
    let before = ws.clone();
    assert!(run(ws).is_err());
    assert_eq!(*ws, before);
}

fn refused_split(ws: &mut Workspace, run: impl FnOnce(&mut Workspace) -> Result<(Vec<Op>, SplitChange), EditError>) {
    let before = ws.clone();
    assert!(run(ws).is_err());
    assert_eq!(*ws, before);
}

// Three Today tabs, with the first two split and the third left after the split row:
// [third, split(first, next, second)].
fn today_split(ws: &mut Workspace) -> (String, String, String, String, String) {
    for url in ["https://one.example/", "https://two.example/", "https://three.example/"] {
        ws.create_tab("window", url).unwrap();
    }
    let today = children(ws, "today-work");
    let (third, second, first) = (today[0].clone(), today[1].clone(), today[2].clone());
    let split = replayed_split(ws, |ws| ws.make_split(&second, &first, SplitSide::Right)).1.split;
    let next = replayed_split(ws, |ws| ws.add_split_pane(&first, SplitSide::Right)).1.pane;
    (first, next, second, third, split)
}

#[test]
fn moving_and_converting_panes_keeps_selection_and_replays() {
    let mut ws = workspace();
    ws.select_item("window", "tab-a").unwrap();
    replayed(&mut ws, |ws| ws.move_pane("tab-a", true));
    assert_eq!(children(&ws, "split-1"), ["tab-b", "tab-a"]);
    assert_eq!(ws.selected("window"), Some("tab-a"));
    refused(&mut ws, |ws| ws.move_pane("tab-a", true));
    replayed(&mut ws, |ws| ws.convert_split("split-1"));
    assert!(matches!(ws.items["split-1"].kind, ItemKind::Split { orientation: Orientation::Vertical, .. }));
    assert_eq!(ws.selected("window"), Some("tab-a"));
}

#[test]
fn adding_a_pane_either_side_joins_the_split_and_opens_the_new_tab_page() {
    let mut ws = workspace();
    ws.select_item("window", "tab-b").unwrap();
    let windows = ws.windows.clone();
    let (_, left) = replayed_split(&mut ws, |ws| ws.add_split_pane("tab-b", SplitSide::Left));
    assert_eq!(left.split, "split-1");
    assert_eq!(children(&ws, "split-1"), ["tab-a".to_string(), left.pane.clone(), "tab-b".to_string()]);
    let pane = &ws.items[&left.pane];
    assert!(matches!(pane.kind, ItemKind::Tab { ref url, .. } if url == "chrome://newtab/"));
    assert_eq!(pane.lifecycle, Lifecycle::Open);
    assert_eq!(pane.membership.parent.as_deref(), Some("split-1"));
    // The selection and the window record stay where they were: the caller focuses the new pane.
    assert_eq!(ws.windows, windows);
    let (_, right) = replayed_split(&mut ws, |ws| ws.add_split_pane("tab-a", SplitSide::Right));
    assert_eq!(children(&ws, "split-1")[1], right.pane);
    // Empty width factors put the new pane at the mean weight, and every factor still sums to one.
    let factors = ws.split_factors("split-1").unwrap();
    assert_eq!(factors.len(), 4);
    assert!((factors.iter().map(|(_, factor)| factor).sum::<f64>() - 1.0).abs() < 1e-9);
    // The split row itself joins at the end the side names.
    let (_, end) = replayed_split(&mut ws, |ws| ws.add_split_pane("split-1", SplitSide::Right));
    assert_eq!(children(&ws, "split-1").last().unwrap(), &end.pane);
    let (_, start) = replayed_split(&mut ws, |ws| ws.add_split_pane("split-1", SplitSide::Left));
    assert_eq!(children(&ws, "split-1")[0], start.pane);
}

#[test]
fn adding_a_split_to_a_lone_row_wraps_it_in_place() {
    let mut ws = workspace();
    for url in ["https://first.example/", "https://second.example/"] { ws.create_tab("window", url).unwrap(); }
    let today = children(&ws, "today-work");
    let (second, first) = (today[0].clone(), today[1].clone());
    let first_order = ws.items[&first].membership.order.clone();
    let second_order = ws.items[&second].membership.order.clone();
    let (_, change) = replayed_split(&mut ws, |ws| ws.add_split_pane(&first, SplitSide::Right));
    // The split takes the row's place in the list and keeps its order key.
    assert_eq!(children(&ws, "today-work"), [second.clone(), change.split.clone()]);
    assert_eq!(ws.items[&change.split].membership.order, first_order);
    assert_eq!(children(&ws, &change.split), [first.clone(), change.pane.clone()]);
    assert_eq!(ws.items[&first].membership.parent.as_deref(), Some(change.split.as_str()));
    assert_eq!(ws.items[&change.split].membership.parent.as_deref(), Some("today-work"));
    // Left puts the new pane first, and the wrapped row keeps its place in the list.
    let (_, left) = replayed_split(&mut ws, |ws| ws.add_split_pane(&second, SplitSide::Left));
    assert_eq!(children(&ws, &left.split), [left.pane.clone(), second.clone()]);
    assert_eq!(children(&ws, "today-work")[0], left.split.clone());
    assert_eq!(ws.items[&left.split].membership.order, second_order);
}

#[test]
fn separating_a_pane_makes_a_today_row_after_the_split_and_one_pane_splits_become_the_tab() {
    let mut ws = workspace();
    let (first, next, second, third, split) = today_split(&mut ws);
    assert_eq!(children(&ws, "today-work"), [third.clone(), split.clone()]);
    assert_eq!(children(&ws, &split), [first.clone(), next.clone(), second.clone()]);
    ws.select_item("window", &split).unwrap();
    // The window's row is the focused pane — the most recent of the split's members — as everywhere
    // else; the split row itself is never a window's selection.
    assert_eq!(ws.selected("window"), Some(second.as_str()));
    // The pane becomes its own row right after the split row, and the split keeps two panes.
    replayed(&mut ws, |ws| ws.separate_pane(&second));
    assert_eq!(children(&ws, "today-work"), [third.clone(), split.clone(), second.clone()]);
    assert_eq!(children(&ws, &split), [first.clone(), next.clone()]);
    assert_eq!(ws.items[&second].membership.parent.as_deref(), Some("today-work"));
    assert_eq!(ws.selected("window"), Some(second.as_str()));
    // The second separate leaves one pane, which becomes the tab in the split's place; the
    // window stays on the row it was on.
    let split_order = ws.items[&split].membership.order.clone();
    replayed(&mut ws, |ws| ws.separate_pane(&first));
    assert_eq!(children(&ws, "today-work"), [third, next.clone(), first.clone(), second.clone()]);
    assert!(!ws.items.contains_key(&split));
    assert_eq!(ws.selected("window"), Some(second.as_str()));
    assert_eq!(ws.items[&next].lifecycle, Lifecycle::Open);
    assert!(ws.windows.values().all(|window| !window.history.contains(&split)));
    assert_eq!(ws.items[&next].membership.parent.as_deref(), Some("today-work"));
    assert_eq!(ws.items[&next].membership.order, split_order);
}

#[test]
fn separating_from_a_pinned_split_lands_at_the_top_of_today() {
    let mut ws = workspace();
    ws.create_tab("window", "https://today.example/").unwrap();
    let today = children(&ws, "today-work");
    replayed(&mut ws, |ws| ws.separate_pane("tab-a"));
    // Today is the row list the pane moves to: the top of it, since the split is pinned, and the
    // split left with one pane became tab-b in the place the split held.
    assert_eq!(children(&ws, "today-work"), ["tab-a".to_string(), today[0].clone()]);
    assert_eq!(children(&ws, "pin-work"), ["folder-docs", "tab-b"]);
    assert!(!ws.items.contains_key("split-1"));
}

#[test]
fn drag_to_split_joins_the_shown_pane_split_beside_the_pane_without_nesting() {
    let mut ws = workspace();
    let (first, next, second, third, split) = today_split(&mut ws);
    assert_eq!(children(&ws, "today-work"), [third.clone(), split.clone()]);
    // A fourth Today row dragged onto the left half of a pane of that split: it joins the same
    // split beside the pane (design S1), with no split inside a split.
    ws.create_tab("window", "https://fourth.example/").unwrap();
    let fourth = ws.selected("window").unwrap().to_string();
    let (_, change) = replayed_split(&mut ws, |ws| ws.make_split(&fourth, &second, SplitSide::Left));
    assert_eq!(change.split, split);
    assert_eq!(children(&ws, &split), [first.clone(), next.clone(), fourth.clone(), second.clone()]);
    assert_eq!(ws.items[&fourth].membership.parent.as_deref(), Some(split.as_str()));
    assert!(children(&ws, &split).iter().all(|child| matches!(ws.items[child].kind, ItemKind::Tab { .. })));
    assert_eq!(children(&ws, "today-work"), [third.clone(), split.clone()]);
    // Two panes of one split re-order in place and no split appears either.
    let (_, again) = replayed_split(&mut ws, |ws| ws.make_split(&fourth, &second, SplitSide::Right));
    assert_eq!(again.split, split);
    assert_eq!(children(&ws, &split), [first, next, second, fourth]);
    assert_eq!(children(&ws, "today-work"), [third, split.clone()]);
    // The Today list holds the one split the drag made: nothing nested appeared.
    let today_splits = children(&ws, "today-work").iter()
        .filter(|id| matches!(ws.items[*id].kind, ItemKind::Split { .. })).count();
    assert_eq!(today_splits, 1);
}

#[test]
fn drag_to_split_wraps_a_lone_shown_row_and_refuses_other_rows_of_the_profile() {
    let mut ws = workspace();
    for url in ["https://one.example/", "https://two.example/"] { ws.create_tab("window", url).unwrap(); }
    let today = children(&ws, "today-work");
    let (second, first) = (today[0].clone(), today[1].clone());
    let first_order = ws.items[&first].membership.order.clone();
    let (_, change) = replayed_split(&mut ws, |ws| ws.make_split(&second, &first, SplitSide::Left));
    assert_eq!(children(&ws, "today-work"), [change.split.clone()]);
    assert_eq!(children(&ws, &change.split), [second.clone(), first.clone()]);
    assert_eq!(ws.items[&change.split].membership.order, first_order);
    assert_eq!(ws.items[&change.split].membership.parent.as_deref(), Some("today-work"));
    // A row of another list (favourites) is not a split partner, and a refusal changes nothing.
    refused_split(&mut ws, |ws| ws.make_split("tab-mail", &second, SplitSide::Left));
}

#[test]
fn a_split_that_goes_leaves_its_inactive_panes_in_the_list_and_the_tree_whole() {
    // Review 1 M1: a closed or archived pane keeps its record; when the split is replaced by its
    // last active pane, the inactive one must not keep pointing at a deleted split.
    let mut ws = workspace();
    let (first, next, _, _, split) = today_split(&mut ws);
    replayed(&mut ws, |ws| ws.close_item(&next));
    assert_eq!(ws.items[&next].lifecycle, Lifecycle::Closed);
    replayed(&mut ws, |ws| ws.separate_pane(&first));
    assert!(!ws.items.contains_key(&split));
    assert_eq!(ws.items[&next].membership.parent.as_deref(), Some("today-work"));
    assert_eq!(ws.items[&next].lifecycle, Lifecycle::Closed);
    ws.check_tree().unwrap();
    replayed(&mut ws, |ws| ws.create_tab("window", "https://after-separate.example/"));

    // Dragged out: the pane leaves the split and the split left with one pane (and an archived
    // sibling) becomes that pane's row.
    let mut ws = workspace();
    let (first, next, second, third, split) = today_split(&mut ws);
    replayed(&mut ws, |ws| ws.archive_item(&second));
    let (_, change) = replayed_split(&mut ws, |ws| ws.make_split(&first, &third, SplitSide::Right));
    assert!(!ws.items.contains_key(&split));
    // The wrapped split took the lone row's place, with the moved pane after it, and the
    // archived sibling joined Today rather than the split that went.
    assert_eq!(children(&ws, &change.split), [third.clone(), first.clone()]);
    assert_eq!(ws.items[&second].membership.parent.as_deref(), Some("today-work"));
    assert_eq!(ws.items[&second].lifecycle, Lifecycle::Archived);
    assert_eq!(ws.items[&next].membership.parent.as_deref(), Some("today-work"));
    ws.check_tree().unwrap();
    replayed(&mut ws, |ws| ws.create_tab("window", "https://after-drag.example/"));

    // Moved to another space: the member leaves the split and the archived pane is re-homed.
    let mut ws = workspace();
    let (first, next, second, _, split) = today_split(&mut ws);
    replayed(&mut ws, |ws| ws.archive_item(&second));
    replayed(&mut ws, |ws| ws.move_item(&first, "today-home", 0, false));
    assert!(!ws.items.contains_key(&split));
    assert_eq!(children(&ws, "today-home"), [first.clone()]);
    assert_eq!(ws.items[&second].membership.parent.as_deref(), Some("today-work"));
    assert_eq!(ws.items[&next].membership.parent.as_deref(), Some("today-work"));
    ws.check_tree().unwrap();
    replayed(&mut ws, |ws| ws.create_tab("window", "https://after-move.example/"));
}

#[test]
fn a_pane_move_keys_only_the_moved_pane_and_leaves_the_other_members_alone() {
    let mut ws = workspace();
    // A third member, inactive: a closed pane stays in the split, hidden.
    let pane = replayed_split(&mut ws, |ws| ws.add_split_pane("tab-a", SplitSide::Right)).1.pane;
    ws.items.get_mut(&pane).unwrap().lifecycle = Lifecycle::Closed;
    let before_a = ws.items["tab-a"].membership.order.clone();
    let before_b = ws.items["tab-b"].membership.order.clone();
    let ops = replayed(&mut ws, |ws| ws.move_pane("tab-a", true));
    // One write for the moved pane: the neighbour and the inactive pane keep their records.
    assert_eq!(ops.len(), 1);
    assert_eq!(children(&ws, "split-1"), [pane.clone(), "tab-b".to_string(), "tab-a".to_string()]);
    assert_ne!(ws.items["tab-a"].membership.order, before_a);
    assert_eq!(ws.items["tab-b"].membership.order, before_b);
    assert_ne!(ws.items[&pane].membership.order, "");
    let keys: Vec<_> = ws.children("split-1").iter().map(|item| item.membership.order.clone()).collect();
    assert!(keys.windows(2).all(|pair| pair[0] < pair[1]), "no two members share a key: {keys:?}");
    ws.check_tree().unwrap();
}

#[test]
fn separating_a_pane_of_an_imported_nested_split_lands_after_the_row_that_holds_it() {
    // A nested split as an Arc import can carry (U25d makes none): separate_pane of an inner pane
    // must land right after the row the sidebar draws, not after the inner split's id.
    let mut ws = workspace();
    let mut inner = ws.items["split-1"].clone();
    inner.id = "inner".into();
    inner.membership.parent = Some("split-1".into());
    inner.membership.order = ararat_core::order::key_between(Some(&ws.items["tab-a"].membership.order),
                                                       Some(&ws.items["tab-b"].membership.order));
    ws.items.insert("inner".into(), inner);
    ws.items.get_mut("tab-b").unwrap().membership.parent = Some("inner".into());
    ws.items.get_mut("tab-b").unwrap().membership.order = ararat_core::order::key_between(None, None);
    ws.items.get_mut("tab-b").unwrap().lifecycle = Lifecycle::Open;
    ws.create_tab("window", "https://today.example/").unwrap();
    replayed(&mut ws, |ws| ws.separate_pane("tab-b"));
    // Today is where a pinned split's pane goes, at the top; the row that held the split is pinned.
    assert_eq!(children(&ws, "today-work")[0], "tab-b");
    assert_eq!(children(&ws, "pin-work"), ["folder-docs", "split-1"]);
    assert_eq!(children(&ws, "split-1"), ["tab-a"]);
    assert!(!ws.items.contains_key("inner"));
    ws.check_tree().unwrap();
}

#[test]
fn a_refused_cross_space_move_changes_nothing() {
    let mut ws = workspace();
    // The index is judged after the member would leave its split: the refused move leaves the
    // split whole (review 1, S3).
    refused(&mut ws, |ws| ws.move_item("tab-a", "today-home", 99, false));
    assert_eq!(children(&ws, "split-1"), ["tab-a", "tab-b"]);
    assert_eq!(children(&ws, "today-home"), Vec::<String>::new());
    refused(&mut ws, |ws| ws.move_item("tab-a", "missing", 0, false));
    assert_eq!(children(&ws, "split-1"), ["tab-a", "tab-b"]);
    // A lone Today row is not touched by the rule either.
    ws.create_tab("window", "https://solo.example/").unwrap();
    let solo = ws.selected("window").unwrap().to_string();
    refused(&mut ws, |ws| ws.move_item(&solo, "today-home", 99, false));
    assert_eq!(ws.items[&solo].membership.parent.as_deref(), Some("today-work"));
}

#[test]
fn a_split_member_moved_to_another_space_leaves_the_split() {
    let mut ws = workspace();
    ws.select_item("window", "tab-a").unwrap();
    let windows = ws.windows.clone();
    let ops = replayed(&mut ws, |ws| ws.move_item("tab-a", "today-home", 0, false));
    // The tab is a top-level Today row of the other space; the split it left became tab-b's tab
    // in the place the split held, and the window keeps the row it was on.
    assert_eq!(children(&ws, "today-home"), ["tab-a"]);
    assert_eq!(children(&ws, "pin-work"), ["folder-docs", "tab-b"]);
    assert!(!ws.items.contains_key("split-1"));
    assert_eq!(ws.items["tab-a"].membership.parent.as_deref(), Some("today-home"));
    assert_eq!(ws.selected("window"), Some("tab-a"));
    assert_eq!(ws.windows, windows);
    assert!(ops.iter().any(|op| matches!(op, Op::Delete(Kind::Item, id) if id == "split-1")));
    // Within the space the split still moves as one row, even when a member names it.
    let mut ws = workspace();
    replayed(&mut ws, |ws| ws.move_item("tab-a", "today-work", 0, false));
    assert_eq!(children(&ws, "today-work"), ["split-1"]);
    assert_eq!(children(&ws, "pin-work"), ["folder-docs"]);
    // A member carried into the same space's favourites leaves the split the same way.
    let mut ws = workspace();
    replayed(&mut ws, |ws| ws.move_item("tab-b", "space-work:favorites", 1, false));
    assert_eq!(children(&ws, "space-work:favorites"), ["tab-mail", "tab-b"]);
    assert_eq!(children(&ws, "pin-work"), ["folder-docs", "tab-a"]);
}

#[test]
fn pane_ops_refuse_rows_outside_a_split_and_rows_of_other_lists() {
    let mut ws = workspace();
    refused(&mut ws, |ws| ws.separate_pane("tab-spec"));
    refused(&mut ws, |ws| ws.separate_pane("folder-docs"));
    refused(&mut ws, |ws| ws.separate_pane("missing"));
    refused_split(&mut ws, |ws| ws.add_split_pane("folder-docs", SplitSide::Left));
    refused_split(&mut ws, |ws| ws.add_split_pane("missing", SplitSide::Right));
    refused_split(&mut ws, |ws| ws.make_split("tab-spec", "tab-spec", SplitSide::Left));
    refused_split(&mut ws, |ws| ws.make_split("tab-a", "tab-mail", SplitSide::Left));
    refused_split(&mut ws, |ws| ws.make_split("split-1", "tab-a", SplitSide::Left));
    refused_split(&mut ws, |ws| ws.make_split("split-1", "tab-mail", SplitSide::Left));
    refused_split(&mut ws, |ws| ws.make_split("folder-docs", "tab-a", SplitSide::Left));
    for lifecycle in [Lifecycle::Closed, Lifecycle::Archived] {
        ws.items.get_mut("tab-b").unwrap().lifecycle = lifecycle;
        refused_split(&mut ws, |ws| ws.add_split_pane("tab-b", SplitSide::Left));
        refused(&mut ws, |ws| ws.separate_pane("tab-b"));
        refused(&mut ws, |ws| ws.convert_split("tab-b"));
        ws.items.get_mut("tab-b").unwrap().lifecycle = Lifecycle::Open;
    }
    // A refusal at the far end of a cross-space member move leaves the split whole.
    refused(&mut ws, |ws| ws.move_item("tab-a", "missing", 0, false));
    assert_eq!(children(&ws, "split-1"), ["tab-a", "tab-b"]);
}

#[test]
fn pane_ops_reach_the_journal_and_a_reopen_matches_in_memory() {
    let path = std::env::temp_dir().join(format!("ararat-split-commands-{}.sqlite", std::process::id()));
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
    let (store, _) = Store::open(&path).unwrap();
    let mut ws = workspace();
    store.write(ws.to_ops());
    store.flush().unwrap();
    let conn = rusqlite::Connection::open(&path).unwrap();
    fn write_batch(store: &Store, conn: &rusqlite::Connection, ops: Vec<Op>) {
        let count = |conn: &rusqlite::Connection| -> i64 {
            conn.query_row("SELECT count(*) FROM journal", [], |row| row.get(0)).unwrap()
        };
        let before = count(conn);
        let size = ops.len() as i64;
        store.write(ops);
        store.flush().unwrap();
        // One batch per op, and every row of it journaled in that batch.
        assert_eq!(count(conn) - before, size);
    }
    let (ops, change) = replayed_split(&mut ws, |ws| ws.add_split_pane("tab-a", SplitSide::Left));
    assert_eq!(change.split, "split-1");
    write_batch(&store, &conn, ops);
    write_batch(&store, &conn, replayed(&mut ws, |ws| ws.separate_pane(&change.pane)));
    write_batch(&store, &conn, replayed(&mut ws, |ws| ws.convert_split("split-1")));
    for url in ["https://one.example/", "https://two.example/"] {
        // New tabs carry device-only rows (the window and its recency), so this batch is written
        // whole rather than counted against the journal like a pane op.
        store.write(ws.create_tab("window", url).unwrap());
        store.flush().unwrap();
    }
    let today = children(&ws, "today-work");
    let (dragged, target) = (today[0].clone(), today[1].clone());
    write_batch(&store, &conn, replayed_split(&mut ws, |ws| ws.make_split(&dragged, &target, SplitSide::Right)).0);
    drop(conn);
    drop(store);
    let (store, reopened) = Store::open(&path).unwrap();
    assert_eq!(reopened, ws);
    drop(store);
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
}
