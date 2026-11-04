use ararat_core::{import::arc_sidebar, model::{Appearance, Kind, Lifecycle, Look, LookColor, Op, Record, Workspace}, storage::Store};

fn workspace() -> Workspace { arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json"), None, None, None).unwrap().0 }
fn look() -> Look { Look { colors: vec![LookColor { red: 0.1, green: 0.2, blue: 0.3, x: 0.4, y: 0.5 }], opacity: 0.6, grain: 0.7, glass: true, appearance: Appearance::Dark } }
fn replay(ws: &mut Workspace, edit: impl FnOnce(&mut Workspace) -> Vec<Op>) {
    let mut copy = ws.clone();
    let ops = edit(ws);
    for op in &ops { copy.apply(op); }
    assert_eq!(*ws, copy);
}

#[test]
fn name_icon_look_and_order_edits_replay_and_persist() {
    let mut ws = workspace();
    replay(&mut ws, |ws| ws.rename_space("space-work", "  Renamed \n").unwrap());
    assert_eq!(ws.spaces[0].title, "Renamed");
    for icon in [Some("👩🏽‍💻".into()), Some("🇯🇵".into()), Some("1️⃣".into()), None] {
        replay(&mut ws, |ws| ws.set_space_icon("space-work", icon.clone()).unwrap());
        assert_eq!(ws.spaces[0].icon, icon);
    }
    replay(&mut ws, |ws| ws.set_space_look("space-work", Some(look())).unwrap());
    replay(&mut ws, |ws| ws.move_space("space-home", 0).unwrap());
    assert_eq!(ws.spaces[0].id, "space-home");
    assert!(ws.spaces[0].order < ws.spaces[1].order);
    ws.create_space("one", "Third", "third").unwrap();
    for index in [0, 1, 2, 1] {
        replay(&mut ws, |ws| ws.move_space("space-work", index).unwrap());
        assert_eq!(ws.spaces[index].id, "space-work");
        assert!(ws.spaces.windows(2).all(|pair| pair[0].order < pair[1].order));
    }
    let path = std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("space-look.sqlite");
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
    let (store, _) = Store::open(&path).unwrap(); store.write(ws.to_ops()); store.flush().unwrap(); drop(store);
    let (store, mut reopened) = Store::open(&path).unwrap(); assert_eq!(reopened, ws);
    let ops = reopened.set_space_look("space-work", None).unwrap();
    store.write(ops); store.flush().unwrap(); drop(store);
    assert_eq!(Store::open(&path).unwrap().1, reopened);
}

#[test]
fn rejected_edits_leave_the_whole_workspace_unchanged() {
    let mut ws = workspace(); let before = ws.clone();
    for name in ["", " \n", "\u{3000}"] { assert!(ws.rename_space("space-work", name).is_err()); assert_eq!(ws, before); }
    for icon in ["", " ", "two words", "\n", &"🦀".repeat(17)] {
        assert!(ws.set_space_icon("space-work", Some(icon.into())).is_err()); assert_eq!(ws, before);
    }
    for count in [0, 4] {
        let mut invalid = look(); invalid.colors = vec![invalid.colors[0].clone(); count];
        assert!(ws.set_space_look("space-work", Some(invalid)).is_err()); assert_eq!(ws, before);
    }
    for value in [-0.1, 1.1, f64::NAN, f64::INFINITY] {
        for field in 0..7 {
            let mut invalid = look(); let c = &mut invalid.colors[0];
            *match field { 0 => &mut c.red, 1 => &mut c.green, 2 => &mut c.blue, 3 => &mut c.x, 4 => &mut c.y, 5 => &mut invalid.opacity, _ => &mut invalid.grain } = value;
            assert!(ws.set_space_look("space-work", Some(invalid)).is_err()); assert_eq!(ws, before);
        }
    }
    assert!(ws.move_space("space-work", 2).is_err());
    assert!(ws.rename_space("missing", "Name").is_err());
    assert!(ws.set_space_icon("missing", None).is_err());
    assert!(ws.set_space_look("missing", None).is_err());
    assert!(ws.move_space("missing", 0).is_err());
    assert!(ws.delete_space("missing").is_err());
    assert_eq!(ws, before);
}

#[test]
fn deleting_archives_subtrees_preserves_parents_and_favorites_and_switches_every_window() {
    let mut ws = workspace();
    ws.items.get_mut("tab-b").unwrap().membership.parent = Some("today-work".into());
    ws.items.get_mut("tab-a").unwrap().lifecycle = Lifecycle::Unloaded;
    for window in ["one", "two"] { ws.show_space(window, "space-work").unwrap(); ws.select_item(window, "tab-spec").unwrap(); }
    ws.show_space("other", "space-home").unwrap();
    let before = ws.clone();
    replay(&mut ws, |ws| ws.delete_space("space-work").unwrap());
    for window in ["one", "two", "other"] { assert_eq!(ws.shown_space(window), Some("space-home")); }
    for window in ["one", "two"] { assert_eq!(ws.selected(window), None); assert!(ws.windows[window].history.is_empty()); }
    for id in ["folder-docs", "tab-spec", "split-1", "tab-a", "tab-b"] {
        assert_eq!(ws.items[id].lifecycle, Lifecycle::Archived);
        assert_eq!(ws.items[id].membership, before.items[id].membership);
    }
    assert_eq!(ws.items["tab-mail"], before.items["tab-mail"]);
    assert_eq!(ws.favorites, before.favorites);
    ws.check_tree().unwrap();
    assert_eq!(ws.archive().len(), 3);
    replay(&mut ws, |ws| ws.restore_item("one", "tab-spec").unwrap());
    assert_eq!(ws.items["tab-spec"].membership.parent.as_deref(), Some("today-home"));
    let last = ws.clone(); assert!(ws.delete_space("space-home").is_err()); assert_eq!(ws, last);
}

#[test]
fn deleting_the_last_in_order_shows_the_previous_space() {
    let mut ws = workspace(); ws.show_space("one", "space-home").unwrap();
    ws.delete_space("space-home").unwrap(); assert_eq!(ws.shown_space("one"), Some("space-work"));
}

#[test]
fn old_space_rows_without_look_load_using_serde_default() {
    let path = std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("old-space-look.sqlite");
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
    let (store, _) = Store::open(&path).unwrap(); store.write(workspace().to_ops()); store.flush().unwrap(); drop(store);
    let conn = rusqlite::Connection::open(&path).unwrap();
    conn.execute("UPDATE records SET body=json_remove(body, '$.look') WHERE kind='space'", []).unwrap(); drop(conn);
    let (_, ws) = Store::open(&path).unwrap(); assert!(ws.spaces.iter().all(|s| s.look.is_none()));
    for space in ws.spaces { assert!(matches!(Record::parse(Kind::Space, &space.id, &Record::Space(space.clone()).body()).unwrap(), Record::Space(_))); }
}

#[test]
fn deleting_preserves_closed_and_archived_lifecycles_and_their_original_times() {
    let mut ws = workspace();
    ws.archive_item("tab-spec").unwrap();
    ws.items.get_mut("tab-a").unwrap().lifecycle = Lifecycle::Closed;
    ws.items.get_mut("tab-a").unwrap().lifecycle_changed_at = 7;
    let archived = ws.items["tab-spec"].clone(); let closed = ws.items["tab-a"].clone();
    ws.delete_space("space-work").unwrap();
    assert_eq!(ws.items["tab-spec"], archived);
    assert_eq!(ws.items["tab-a"], closed);
}

#[test]
fn concurrent_item_puts_into_deleted_roots_repair_into_the_first_surviving_today() {
    for root in ["pin-work", "today-work"] {
        let base = workspace();
        let mut deleting = base.clone(); let deletes = deleting.delete_space("space-work").unwrap();
        let mut moved = base.items["tab-mail"].clone();
        moved.membership.previous_parent = None; moved.membership.parent = Some(root.into());
        let put = Op::Put(Record::Item(moved));
        for delete_first in [true, false] {
            let mut replica = base.clone();
            let ops = if delete_first { deletes.iter().chain(std::iter::once(&put)).collect::<Vec<_>>() }
                else { std::iter::once(&put).chain(deletes.iter()).collect() };
            for op in ops { replica.apply(op); }
            replica.repair_tree(); replica.check_tree().unwrap();
            assert_eq!(replica.items["tab-mail"].membership.parent.as_deref(), Some("today-home"));
            assert_eq!(replica.items["tab-mail"].lifecycle, Lifecycle::Open);
            assert!(replica.outline("today-home").iter().any(|(_, item)| item.id == "tab-mail"));
            assert!(replica.repair_tree().is_empty());
        }
    }
}

#[test]
fn orphaned_live_folders_keep_their_children_in_both_id_orders() {
    for (folder_id, child_id) in [("zz-folder", "aa-child"), ("aa-folder", "zz-child")] {
        for lifecycle in [Lifecycle::Open, Lifecycle::Unloaded, Lifecycle::Archived] {
            let mut ws = workspace();
            ws.delete_space("space-work").unwrap();
            let mut folder = ws.items["folder-docs"].clone();
            folder.id = folder_id.into();
            folder.lifecycle = lifecycle.clone();
            folder.membership.parent = Some("today-work".into());
            let mut child = ws.items["tab-spec"].clone();
            child.id = child_id.into();
            child.lifecycle = Lifecycle::Open;
            child.membership.parent = Some(folder_id.into());
            for item in [folder, child] { ws.apply(&Op::Put(Record::Item(item))); }
            ws.repair_tree();
            ws.check_tree().unwrap();
            if lifecycle == Lifecycle::Archived {
                assert_eq!(ws.items[child_id].membership.parent.as_deref(), Some("today-home"));
            } else {
                assert_eq!(ws.items[folder_id].membership.parent.as_deref(), Some("today-home"));
                assert_eq!(ws.items[child_id].membership.parent.as_deref(), Some(folder_id));
                assert!(ws.outline("today-home").iter().any(|(depth, item)| *depth == 1 && item.id == child_id));
            }
            assert!(ws.repair_tree().is_empty());
        }
    }
}

#[test]
fn deletion_then_local_rename_or_reorder_is_rejected_without_resurrection() {
    for edit in [0, 1] {
        let mut ws = workspace(); ws.delete_space("space-work").unwrap(); let deleted = ws.clone();
        let result = if edit == 0 { ws.rename_space("space-work", "Late rename") } else { ws.move_space("space-work", 0) };
        assert!(result.is_err()); assert_eq!(ws, deleted);
    }
}

#[test]
fn space_record_replay_is_deterministic_for_rename_delete_and_reorder_pairs() {
    let base = workspace();
    let mut renaming = base.clone(); let rename = renaming.rename_space("space-work", "Renamed").unwrap();
    let mut moving = base.clone(); let reorder = moving.move_space("space-work", 1).unwrap();
    let mut deleting = base.clone(); let delete = deleting.delete_space("space-work").unwrap();
    let mut moving_again = base.clone(); let reorder_again = moving_again.move_space("space-work", 0).unwrap();
    for (a, b) in [(&rename, &delete), (&reorder, &delete), (&reorder, &reorder_again)] {
        for (first, last) in [(a, b), (b, a)] {
            let mut replicas = [base.clone(), base.clone()];
            for replica in &mut replicas {
                for op in first.iter().chain(last) { replica.apply(op); }
                replica.repair_tree();
            }
            assert_eq!(replicas[0], replicas[1]);
            let last_space = last.iter().rev().find_map(|op| match op { Op::Put(Record::Space(s)) => Some(Some(s)), Op::Delete(Kind::Space, _) => Some(None), _ => None }).unwrap();
            match last_space {
                Some(space) => assert_eq!(replicas[0].spaces.iter().find(|s| s.id == space.id), Some(space)),
                None => assert!(!replicas[0].spaces.iter().any(|s| s.id == "space-work")),
            }
        }
    }
}

#[test]
fn equal_reorder_keys_use_the_id_tie_breaker_on_every_replica() {
    let base = workspace();
    let puts: Vec<_> = base.spaces.iter().cloned().map(|mut space| { space.order = "V".into(); Op::Put(Record::Space(space)) }).collect();
    let mut replicas = [base.clone(), base];
    for op in &puts { replicas[0].apply(op); }
    for op in puts.iter().rev() { replicas[1].apply(op); }
    assert_eq!(replicas[0], replicas[1]);
    assert_eq!(replicas[0].spaces.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), ["space-home", "space-work"]);
}
