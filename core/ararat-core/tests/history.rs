use ararat_core::import::arc_sidebar;
use ararat_core::model::{Item, ItemKind, Lifecycle, Membership, Op, Record, Workspace};

fn workspace() -> Workspace {
    let mut ws = arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json"), None, None, None, None).unwrap().0;
    for i in 0..61 {
        let id = format!("y{i}");
        ws.items.insert(id.clone(), Item {
            id: id.clone(), membership: Membership { parent: Some("today-work".into()), order: format!("{i:03}"), hlc: Default::default(), previous_parent: None },
            title: None, kind: ItemKind::Tab { url: format!("https://{id}.example"), saved_title: None }, lifecycle: Lifecycle::Open, lifecycle_changed_at: 0, archive: None,
        });
    }
    ws
}

#[test]
fn arc_sequence_a_returns_to_y4_after_closing_y2() {
    let mut ws = workspace();
    for id in ["y4", "y2"] { ws.select_item("one", id).unwrap(); }
    ws.close_item("y2").unwrap();
    assert_eq!(ws.selected("one"), Some("y4"));
}

#[test]
fn arc_sequence_b_walks_y3_y1_and_the_tab_before_y1() {
    let mut ws = workspace();
    for id in ["y0", "y1", "y3", "y4"] { ws.select_item("one", id).unwrap(); }
    for (closed, expected) in [("y4", "y3"), ("y3", "y1"), ("y1", "y0")] {
        ws.close_item(closed).unwrap();
        assert_eq!(ws.selected("one"), Some(expected));
    }
}

#[test]
fn history_is_per_window_unique_and_bounded_to_fifty() {
    let mut ws = workspace();
    for i in 0..61 { ws.select_item("one", &format!("y{i}")).unwrap(); }
    ws.select_item("two", "y0").unwrap();
    ws.select_item("one", "y40").unwrap();
    assert_eq!(ws.windows["one"].history.len(), 50);
    assert_eq!(ws.windows["one"].history[0], "y40");
    assert_eq!(ws.windows["one"].history.iter().filter(|id| *id == "y40").count(), 1);
    assert_eq!(ws.windows["two"].history, ["y0"]);
    assert_eq!(ws.selected("two"), Some("y0"));
}

#[test]
fn successor_skips_collapsed_unloaded_and_closed_history_entries() {
    let mut ws = workspace();
    for id in ["y0", "y1", "y2", "y3", "y4"] { ws.select_item("one", id).unwrap(); }
    let mut folder = ws.items["folder-docs"].clone();
    folder.id = "hidden-folder".into(); folder.membership.parent = Some("today-work".into()); ws.folder_collapsed.insert(folder.id.clone(), true);
    ws.items.insert(folder.id.clone(), folder);
    ws.items.get_mut("y1").unwrap().membership.parent = Some("hidden-folder".into());
    ws.items.get_mut("y2").unwrap().lifecycle = Lifecycle::Unloaded;
    ws.items.get_mut("y3").unwrap().lifecycle = Lifecycle::Closed;
    ws.close_item("y4").unwrap();
    assert_eq!(ws.selected("one"), Some("y0"));
}

#[test]
fn fallback_with_no_history_uses_below_then_above() {
    let mut ws = workspace();
    ws.windows.insert("one".into(), ararat_core::model::WindowState { id: "one".into(), shown_space: Some("space-work".into()), selected: Some("y30".into()), history: vec![], space_history: vec![], frame: None, sidebar_width: None, sidebar_hidden: false, changed_at: 0 });
    ws.close_item("y30").unwrap();
    assert_eq!(ws.selected("one"), Some("y31"));
    ws.windows.get_mut("one").unwrap().history.clear();
    ws.windows.get_mut("one").unwrap().selected = Some("y60".into());
    ws.close_item("y60").unwrap();
    assert_eq!(ws.selected("one"), Some("y59"));
}

#[test]
fn pinned_and_favorite_unload_then_reselect_reopens_in_the_same_batch() {
    for id in ["tab-spec", "tab-mail"] {
        let mut ws = workspace();
        ws.select_item_at("one", "y4", 100).unwrap(); ws.select_item_at("one", id, 101).unwrap();
        let ops = ws.close_item(id).unwrap();
        assert_eq!(ops.len(), 3);
        assert!(ws.history_purges.is_empty());
        assert_eq!(ws.items[id].lifecycle, Lifecycle::Unloaded);
        assert!(ws.is_selectable(id));
        assert_eq!(ws.selected("one"), Some("y4"));
        let mut replay = ws.clone();
        let reopened = ws.select_item("one", id).unwrap();
        assert!(reopened.iter().any(|op| matches!(op, Op::Put(Record::LastSelected { item, .. }) if item == "y4")));
        for op in &reopened { replay.apply(op); }
        assert_eq!(replay, ws);
        assert_eq!(ws.items[id].lifecycle, Lifecycle::Open);
        assert_eq!(ws.selected("one"), Some(id));
    }
}

#[test]
fn history_stays_local_and_reopens_with_lifecycle_changes() {
    let path = std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("mru-local.sqlite");
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
    let mut ws = workspace();
    let (store, _) = ararat_core::storage::Store::open(&path).unwrap(); store.write(ws.to_ops()); store.flush().unwrap();
    let conn = rusqlite::Connection::open(&path).unwrap();
    let count = || conn.query_row("SELECT count(*) FROM journal", [], |r| r.get::<_, i64>(0)).unwrap();
    let before = count();
    for id in ["y4", "y2", "tab-mail"] { store.write(ws.select_item_at("one", id, 100).unwrap()); }
    store.write(ws.select_item_at("two", "y1", 100).unwrap()); store.flush().unwrap();
    assert_eq!(count(), before);
    store.write(ws.close_item("tab-mail").unwrap()); store.flush().unwrap();
    assert_eq!(count(), before + 1);
    assert_eq!(conn.query_row("SELECT count(*) FROM journal WHERE kind = 'window'", [], |r| r.get::<_, i64>(0)).unwrap(), 0);
    drop(store);
    let (_, mut restored) = ararat_core::storage::Store::open(&path).unwrap();
    assert_eq!(restored, ws);
    restored.close_item("y2").unwrap();
    assert_eq!(restored.selected("one"), Some("y4"));
    assert_eq!(restored.selected("two"), Some("y1"));
}

#[test]
fn closing_a_tab_selected_in_two_windows_uses_each_windows_history() {
    let mut ws = workspace();
    for id in ["y1", "y4"] { ws.select_item("one", id).unwrap(); }
    for id in ["y2", "y4"] { ws.select_item("two", id).unwrap(); }
    ws.close_item("y4").unwrap();
    assert_eq!(ws.selected("one"), Some("y1"));
    assert_eq!(ws.selected("two"), Some("y2"));
}

#[test]
fn unloading_the_last_loaded_split_member_unloads_its_group() {
    let mut ws = workspace();
    ws.select_item("one", "y4").unwrap(); ws.select_item("one", "split-1").unwrap();
    ws.close_item("tab-a").unwrap();
    assert_eq!(ws.items["split-1"].lifecycle, Lifecycle::Open);
    assert_eq!(ws.selected("one"), Some("tab-b"));
    ws.close_item("tab-b").unwrap();
    assert_eq!(ws.items["split-1"].lifecycle, Lifecycle::Unloaded);
    assert_eq!(ws.selected("one"), Some("y4"));
    ws.select_item("one", "tab-b").unwrap();
    assert_eq!(ws.items["split-1"].lifecycle, Lifecycle::Open);
    assert_eq!(ws.items["tab-a"].lifecycle, Lifecycle::Open);
    ws.select_item("one", "split-1").unwrap();
    assert_eq!(ws.items["tab-a"].lifecycle, Lifecycle::Open);
}

#[test]
fn a_recent_split_member_is_selected_after_another_tab_closes() {
    let mut ws = workspace();
    ws.select_item("one", "tab-a").unwrap(); ws.select_item("one", "y4").unwrap();
    ws.close_item("y4").unwrap();
    assert_eq!(ws.selected("one"), Some("tab-a"));
}

#[test]
fn selected_today_member_keeps_its_surviving_split_before_older_history() {
    let mut ws = workspace();
    ws.items.get_mut("split-1").unwrap().membership.parent = Some("today-work".into());
    ws.select_item("one", "y4").unwrap(); ws.select_item("one", "tab-a").unwrap();
    ws.close_item("tab-a").unwrap();
    assert_eq!(ws.items["tab-a"].lifecycle, Lifecycle::Closed);
    assert_eq!(ws.items["split-1"].lifecycle, Lifecycle::Open);
    assert_eq!(ws.selected("one"), Some("tab-b"));
}

#[test]
fn selected_pinned_member_keeps_its_surviving_split_before_older_history() {
    let mut ws = workspace();
    ws.select_item("one", "y4").unwrap(); ws.select_item("one", "tab-a").unwrap();
    ws.close_item("tab-a").unwrap();
    assert_eq!(ws.items["tab-a"].lifecycle, Lifecycle::Unloaded);
    assert_eq!(ws.items["split-1"].lifecycle, Lifecycle::Open);
    assert_eq!(ws.selected("one"), Some("tab-b"));
}

#[test]
fn closing_walks_history_then_falls_back_only_in_the_shown_space() {
    let mut ws = workspace();
    ws.items.get_mut("y0").unwrap().membership.parent = Some("today-home".into());
    for id in ["y0", "y1", "y2"] { ws.select_item("one", id).unwrap(); }
    ws.close_item("y2").unwrap();
    assert_eq!(ws.selected("one"), Some("y1"));
    ws.close_item("y1").unwrap();
    assert_eq!(ws.selected("one"), Some("y3"));
    assert_eq!(ws.items["y0"].lifecycle, Lifecycle::Open);
}

#[test]
fn pinned_and_favorite_unloads_skip_history_from_another_space() {
    for (id, expected) in [("tab-spec", Some("tab-a")), ("tab-mail", None)] {
        let mut ws = workspace();
        ws.items.get_mut("y0").unwrap().membership.parent = Some("today-home".into());
        ws.select_item("one", "y0").unwrap(); ws.select_item("one", id).unwrap();
        ws.close_item(id).unwrap();
        assert_eq!(ws.items[id].lifecycle, Lifecycle::Unloaded);
        assert_eq!(ws.selected("one"), expected);
    }
}

#[test]
fn shared_favorite_unload_uses_each_windows_shown_space() {
    let mut ws = workspace();
    ws.spaces[1].profile = ws.spaces[0].profile.clone();
    ws.items.get_mut("y0").unwrap().membership.parent = Some("today-home".into());
    for window in ["one", "two"] {
        for id in ["y0", "y1", "tab-mail"] { ws.select_item(window, id).unwrap(); }
    }
    ws.show_space("two", "space-home").unwrap();
    ws.close_item("tab-mail").unwrap();
    assert_eq!(ws.selected("one"), Some("y1"));
    assert_eq!(ws.selected("two"), Some("y0"));
    assert_eq!(ws.windows["one"].shown_space.as_deref(), Some("space-work"));
    assert_eq!(ws.windows["two"].shown_space.as_deref(), Some("space-home"));
}

#[test]
fn a_profile_favorite_is_a_candidate_in_each_space_of_that_profile() {
    let mut ws = workspace();
    ws.spaces[1].profile = ws.spaces[0].profile.clone();
    ws.items.get_mut("y0").unwrap().membership.parent = Some("today-home".into());
    ws.show_space("one", "space-home").unwrap();
    for id in ["tab-mail", "y0"] { ws.select_item("one", id).unwrap(); }
    ws.close_item("y0").unwrap();
    assert_eq!(ws.selected("one"), Some("tab-mail"));
}

#[test]
fn consecutive_pinned_closes_never_ping_pong() {
    let mut ws = workspace();
    for id in ["y0", "y1"] { ws.items.get_mut(id).unwrap().membership.parent = Some("pin-work".into()); }
    for id in ["y2", "y0", "y1"] { ws.select_item("one", id).unwrap(); }
    ws.close_item("y1").unwrap();
    assert_eq!(ws.selected("one"), Some("y0"));
    ws.close_item("y0").unwrap();
    assert_eq!(ws.selected("one"), Some("y2"));
    assert_eq!(ws.items["y0"].lifecycle, Lifecycle::Unloaded);
    assert_eq!(ws.items["y1"].lifecycle, Lifecycle::Unloaded);
}

#[test]
fn archive_pin_removes_open_and_unloaded_pins_and_replays() {
    for unloaded in [false, true] {
        let mut ws = workspace();
        ws.select_item("one", "y0").unwrap();
        ws.select_item("one", "tab-spec").unwrap();
        if unloaded { ws.close_item("tab-spec").unwrap(); }
        let mut replay = ws.clone();
        let ops = ws.archive_item("tab-spec").unwrap();
        for op in &ops { replay.apply(op); }
        assert_eq!(ws, replay);
        assert_eq!(ws.items["tab-spec"].lifecycle, Lifecycle::Archived);
        assert_eq!(ws.selected("one"), Some("y0"));
        assert!(!ws.outline("pin-work").iter().any(|(_, item)| item.id == "tab-spec"));
        let before = ws.clone();
        for id in ["missing", "folder-docs", "tab-spec"] {
            assert!(ws.archive_item(id).is_err());
            assert_eq!(ws, before);
        }
    }
}
