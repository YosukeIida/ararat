use ararat_core::{import::arc_sidebar, model::{ArchiveAfter, ItemKind, Lifecycle, Workspace}, storage::Store};

fn workspace() -> Workspace {
    let mut ws = arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json")).unwrap();
    for id in ["tab-a", "tab-b"] { ws.items.get_mut(id).unwrap().membership.parent = Some("today-work".into()); }
    for id in ["tab-a", "tab-b", "tab-spec"] { ws.last_selected.insert(id.into(), 0); }
    ws
}

#[test]
fn threshold_is_strict_and_all_four_options_are_profile_scoped() {
    for (option, hours) in [(ArchiveAfter::Hours12, 12), (ArchiveAfter::Hours24, 24), (ArchiveAfter::Days7, 168), (ArchiveAfter::Days30, 720)] {
        assert_eq!(option.millis(), hours * 3_600_000);
        for delta in [-1i64, 0, 1] {
            let mut ws = workspace();
            let profile = ws.spaces.iter().find(|s| s.id == "space-work").unwrap().profile.clone();
            ws.set_archive_after(profile, option);
            ws.last_selected.insert("tab-a".into(), 100);
            ws.auto_archive(((100 + option.millis()) as i64).saturating_add(delta) as u64).unwrap();
            assert_eq!(ws.items["tab-a"].lifecycle == Lifecycle::Archived, delta > 0);
        }
    }
    assert_eq!(ArchiveAfter::default(), ArchiveAfter::Hours12);
}

#[test]
fn pinned_favorite_closed_archived_and_other_windows_selection_are_exempt() {
    let mut ws = workspace();
    ws.select_item_at("other", "tab-a", 10).unwrap();
    ws.items.get_mut("tab-b").unwrap().lifecycle = Lifecycle::Closed;
    let mut archived = ws.items["tab-b"].clone(); archived.id = "archived".into(); archived.lifecycle = Lifecycle::Archived;
    ws.items.insert(archived.id.clone(), archived);
    let before = ws.clone();
    ws.auto_archive(ArchiveAfter::Hours12.millis() + 100).unwrap();
    for id in ["tab-a", "tab-b", "archived", "tab-spec", "tab-mail"] { assert_eq!(ws.items[id], before.items[id]); }
}

#[test]
fn folders_and_split_members_expire_individually_and_selected_splits_protect_members() {
    let mut ws = workspace();
    ws.items.get_mut("tab-a").unwrap().membership.parent = Some("split-1".into());
    ws.items.get_mut("tab-b").unwrap().membership.parent = Some("split-1".into());
    ws.items.get_mut("split-1").unwrap().membership.parent = Some("folder-docs".into());
    ws.items.get_mut("folder-docs").unwrap().membership.parent = Some("today-work".into());
    ws.last_selected.insert("tab-spec".into(), 100_000_000);
    ws.select_item_at("other", "split-1", 50).unwrap();
    assert_eq!(ws.last_selected.get("tab-a").copied(), Some(50));
    assert_eq!(ws.last_selected.get("tab-b").copied(), Some(50));
    ws.auto_archive(ArchiveAfter::Hours12.millis() + 100).unwrap();
    assert_eq!(ws.items["tab-a"].lifecycle, Lifecycle::Open);
    ws.windows.clear();
    let ops = ws.auto_archive(ArchiveAfter::Hours12.millis() + 100).unwrap();
    assert!(!ops.is_empty());
    for id in ["tab-a", "tab-b", "split-1"] { assert_eq!(ws.items[id].lifecycle, Lifecycle::Archived); }
    assert_eq!(ws.items["folder-docs"].lifecycle, Lifecycle::Open);
    assert_eq!(ws.items["tab-spec"].lifecycle, Lifecycle::Open);
}

#[test]
fn local_times_replay_and_reopen_without_changing_synced_records() {
    let mut ws = workspace();
    let before = ws.clone();
    let mut ops = ws.select_item_at("one", "tab-a", 123).unwrap();
    ops.extend(ws.select_item_at("one", "tab-b", 456).unwrap());
    let profile = ws.spaces[0].profile.clone();
    ops.extend(ws.set_archive_after(profile.clone(), ArchiveAfter::Hours24));
    ops.extend(ws.auto_archive(ArchiveAfter::Hours24.millis() + 1000).unwrap());
    let mut replay = before;
    for op in &ops { replay.apply(op); }
    assert_eq!(replay, ws);
    let dir = std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("auto-archive.sqlite");
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", dir.display())); }
    let (store, _) = Store::open(&dir).unwrap();
    store.write(ws.to_ops()); store.flush().unwrap(); drop(store);
    let (_, loaded) = Store::open(&dir).unwrap();
    assert_eq!(loaded, ws);
    assert_eq!(loaded.archive_after[&profile], ArchiveAfter::Hours24);
    assert_eq!(loaded.last_selected.get("tab-b").copied(), Some(456));
    assert!(loaded.archive().iter().all(|i| matches!(i.kind, ItemKind::Tab { .. })));
}

#[test]
fn spaces_share_profile_thresholds_but_other_profiles_keep_the_default() {
    let mut ws = workspace();
    let work = ws.spaces.iter().find(|s| s.id == "space-work").unwrap().profile.clone();
    ws.items.get_mut("tab-spec").unwrap().membership.parent = Some("today-home".into());
    ws.set_archive_after(work, ArchiveAfter::Days30);
    ws.auto_archive(ArchiveAfter::Hours12.millis() + 1).unwrap();
    assert_eq!(ws.items["tab-a"].lifecycle, Lifecycle::Open);
    assert_eq!(ws.items["tab-spec"].lifecycle, Lifecycle::Archived);
    let shared = ws.spaces[0].profile.clone();
    ws.spaces[1].profile = shared;
    ws.items.get_mut("tab-spec").unwrap().lifecycle = Lifecycle::Open;
    ws.auto_archive(ArchiveAfter::Hours24.millis()).unwrap();
    assert_eq!(ws.items["tab-spec"].lifecycle, Lifecycle::Open);
}

#[test]
fn same_timestamp_avoids_duplicate_local_writes_and_close_stamps_the_successor() {
    let mut ws = workspace();
    ws.select_item_at("one", "tab-a", 100).unwrap();
    let repeated = ws.select_item_at("one", "tab-a", 100).unwrap();
    assert!(!repeated.iter().any(|op| matches!(op, ararat_core::model::Op::Put(ararat_core::model::Record::LastSelected { .. }))));
    ws.select_item_at("one", "tab-b", 101).unwrap();
    ws.close_item("tab-b").unwrap();
    assert_eq!(ws.selected("one"), Some("tab-a"));
    assert!(ws.last_selected.get("tab-a").copied().unwrap() > 100);
    ws.windows.clear();
    ws.last_selected.insert("tab-a".into(), u64::MAX);
    ws.auto_archive(1).unwrap();
    assert_eq!(ws.items["tab-a"].lifecycle, Lifecycle::Open);
}

#[test]
fn collapsed_today_folders_and_unloaded_members_expire_without_archiving_fresh_split_members() {
    let mut ws = workspace();
    for id in ["tab-a", "tab-b"] { ws.items.get_mut(id).unwrap().membership.parent = Some("split-1".into()); }
    ws.items.get_mut("split-1").unwrap().membership.parent = Some("folder-docs".into());
    ws.items.get_mut("folder-docs").unwrap().membership.parent = Some("today-work".into());
    ws.items.get_mut("folder-docs").unwrap().collapsed = true;
    ws.items.get_mut("tab-a").unwrap().lifecycle = Lifecycle::Unloaded;
    ws.last_selected.insert("tab-b".into(), ArchiveAfter::Hours12.millis());
    ws.auto_archive(ArchiveAfter::Hours12.millis() + 1).unwrap();
    assert_eq!(ws.items["tab-a"].lifecycle, Lifecycle::Archived);
    assert_eq!(ws.items["tab-b"].lifecycle, Lifecycle::Open);
    assert_eq!(ws.items["split-1"].lifecycle, Lifecycle::Open);
}

#[test]
fn old_zero_time_store_gets_full_first_idle_period() {
    let mut ws = workspace();
    ws.last_selected.clear();
    let path = std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("auto-archive-upgrade.sqlite");
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
    let (store, _) = Store::open(&path).unwrap();
    store.write(ws.to_ops()); store.flush().unwrap(); drop(store);
    let (store, mut old) = Store::open(&path).unwrap();
    let now = 1_800_000_000_000;
    store.write(old.auto_archive(now).unwrap()); store.flush().unwrap();
    let (_, reopened) = Store::open(&path).unwrap();
    for id in ["tab-a", "tab-b"] { assert_eq!(reopened.last_selected.get(id), Some(&now)); }
    for id in ["tab-a", "tab-b"] { assert_eq!(old.items[id].lifecycle, Lifecycle::Open); }
    old.auto_archive(now + ArchiveAfter::Hours12.millis()).unwrap();
    for id in ["tab-a", "tab-b"] { assert_eq!(old.items[id].lifecycle, Lifecycle::Open); }
    old.auto_archive(now + ArchiveAfter::Hours12.millis() + 1).unwrap();
    for id in ["tab-a", "tab-b"] { assert_eq!(old.items[id].lifecycle, Lifecycle::Archived); }
}

#[test]
fn open_tab_selection_does_not_journal_item_usage() {
    let path = std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("auto-archive-local-usage.sqlite");
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
    let (store, _) = Store::open(&path).unwrap();
    let mut ws = workspace();
    store.write(ws.to_ops()); store.flush().unwrap();
    let conn = rusqlite::Connection::open(&path).unwrap();
    let count = || conn.query_row("SELECT count(*) FROM journal", [], |r| r.get::<_, i64>(0)).unwrap();
    let before = count();
    store.write(ws.select_item_at("one", "tab-a", 100).unwrap()); store.flush().unwrap();
    assert_eq!(count(), before);
}

#[test]
fn journal_replay_excludes_usage_and_starts_a_new_local_idle_period() {
    use ararat_core::model::{Kind, Op, Record};
    let path = std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("auto-archive-replay.sqlite");
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
    let (store, _) = Store::open(&path).unwrap();
    let mut ws = workspace();
    store.write(ws.to_ops());
    store.write(ws.select_item_at("one", "tab-a", 100).unwrap());
    let profile = ws.spaces[0].profile.clone();
    store.write(ws.set_archive_after(profile, ArchiveAfter::Days7));
    store.write(ws.auto_archive(1_800_000_000_000).unwrap()); store.flush().unwrap();
    let conn = rusqlite::Connection::open(&path).unwrap();
    assert_eq!(conn.query_row("SELECT count(*) FROM journal WHERE kind IN ('window', 'last_selected')", [], |r| r.get::<_, i64>(0)).unwrap(), 0);
    let mut stmt = conn.prepare("SELECT kind, id, body FROM journal ORDER BY seq").unwrap();
    let mut replay = Workspace::default();
    for row in stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, Option<String>>(2)?))).unwrap() {
        let (kind, id, body) = row.unwrap();
        let kind = Kind::parse(&kind).unwrap();
        let op = match body { Some(body) => Op::Put(Record::parse(kind, &id, &body).unwrap()), None => Op::Delete(kind, id) };
        replay.apply(&op);
    }
    assert_eq!(replay.items, ws.items);
    assert_eq!(replay.spaces, ws.spaces);
    assert_eq!(replay.favorites, ws.favorites);
    assert_eq!(replay.archive_after, ws.archive_after);
    assert!(replay.last_selected.is_empty());
    replay.auto_archive(1_800_000_000_000).unwrap();
    assert_eq!(replay.items["tab-a"].lifecycle, Lifecycle::Open);
    assert_eq!(replay.items["tab-b"].lifecycle, Lifecycle::Archived);
    drop(store);
    let (_, reopened) = Store::open(&path).unwrap();
    assert_eq!(reopened.last_selected["tab-a"], 100);
    assert!(serde_json::to_value(&reopened.items["tab-a"]).unwrap().get("last_selected_at").is_none());
}

#[test]
fn invalid_tree_leaves_auto_archive_workspace_unchanged() {
    let mut ws = workspace();
    ws.items.get_mut("tab-a").unwrap().membership.parent = Some("tab-a".into());
    let before = ws.clone();
    assert!(ws.auto_archive(1_800_000_000_000).is_err());
    assert_eq!(ws, before);
}
