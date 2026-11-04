use ararat_core::{import::arc_sidebar, model::{ItemKind, Profile}, storage::Store};

fn workspace() -> ararat_core::model::Workspace {
    arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json"), None, None).unwrap().0
}

#[test]
fn creating_appends_a_trimmed_space_in_the_current_profile_and_commits_its_roots_and_shown_space() {
    let mut ws = workspace();
    ws.show_space("one", "space-home").unwrap();
    let profile = ws.spaces[1].profile.clone();
    let last_order = ws.spaces.last().unwrap().order.clone();
    let path = std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("create-space.sqlite");
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
    let (store, _) = Store::open(&path).unwrap(); store.write(ws.to_ops()); store.flush().unwrap();
    let conn = rusqlite::Connection::open(&path).unwrap();
    let before: i64 = conn.query_row("SELECT count(*) FROM journal", [], |row| row.get(0)).unwrap();
    let ops = ws.create_space("one", "  Project Notes \n", "new-space").unwrap();
    assert_eq!(ops.len(), 4);
    let space = ws.spaces.last().unwrap();
    assert_eq!(space.id, "new-space");
    assert_eq!(space.title, "Project Notes");
    assert_eq!(space.profile, profile);
    assert!(space.order > last_order);
    for root in [&space.pinned, &space.today] {
        assert!(matches!(ws.items[root].kind, ItemKind::Container));
        assert_eq!(ws.items[root].membership.parent, None);
        assert!(ws.outline(root).is_empty());
    }
    assert_eq!(ws.shown_space("one"), Some("new-space"));
    assert_eq!(ws.selected("one"), None);
    ws.check_tree().unwrap();
    store.write(ops); store.flush().unwrap();
    assert_eq!(conn.query_row("SELECT count(*) FROM journal", [], |row| row.get::<_, i64>(0)).unwrap(), before + 3);
    drop(store);
    assert_eq!(Store::open(&path).unwrap().1, ws);
}

#[test]
fn blank_names_and_colliding_ids_do_not_change_the_workspace() {
    let mut ws = workspace();
    let before = ws.clone();
    for name in ["", " \t\n", "\u{3000}"] {
        assert!(ws.create_space("one", name, "new-space").is_err());
        assert_eq!(ws, before);
    }
    for id in ["", "space-work", "tab-a"] {
        assert!(ws.create_space("one", "Name", id).is_err());
        assert_eq!(ws, before);
    }
}

#[test]
fn creating_the_first_space_uses_the_default_profile() {
    let mut ws = ararat_core::model::Workspace::default();
    ws.create_space("one", "First", "first-space").unwrap();
    assert_eq!(ws.spaces[0].profile, Profile::Default);
    assert_eq!(ws.shown_space("one"), Some("first-space"));
    ws.check_tree().unwrap();
}
