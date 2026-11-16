use ararat_core::key_bindings::{commands, KeyCombination};
use ararat_core::model::{Kind, Op, Record, Workspace};
use ararat_core::storage::Store;
use rusqlite::Connection;

fn command(key: &str) -> KeyCombination {
    KeyCombination { key: key.into(), command: true, control: false, option: false, shift: false }
}

#[test]
fn defaults_cover_existing_shortcuts_and_pin_tab_without_storing_defaults() {
    let ws = Workspace::default();
    let expected = [("settings", ","), ("quit", "q"), ("close_tab", "w"), ("new_tab", "t"), ("edit_url", "l"), ("toggle_sidebar", "s"), ("pin_tab", "d")];
    for (id, key) in expected { assert_eq!(ws.key_binding(id).unwrap(), Some(command(key))); }
    let mut library = command("l"); library.shift = true;
    assert_eq!(ws.key_binding("toggle_library").unwrap(), Some(library));
    for n in 1..=9 {
        let mut key = command(&n.to_string()); key.command = false; key.control = true;
        assert_eq!(ws.key_binding(&format!("show_space_{n}")).unwrap(), Some(key));
    }
    assert_eq!(ws.key_binding("reset_sidebar_width").unwrap(), None);
    let mut force_reload = command("r"); force_reload.shift = true;
    assert_eq!(ws.key_binding("force_reload").unwrap(), Some(force_reload));
    let mut cycle = command("\t"); cycle.command = false; cycle.control = true;
    assert_eq!(ws.key_binding("cycle_tabs_next").unwrap(), Some(cycle.clone()));
    cycle.shift = true;
    assert_eq!(ws.key_binding("cycle_tabs_previous").unwrap(), Some(cycle));
    for (id, key) in [("focus_next_pane", "\u{f703}"), ("focus_previous_pane", "\u{f702}")] {
        let mut expected = command(key); expected.option = true;
        assert_eq!(ws.key_binding(id).unwrap(), Some(expected));
    }
    // P5d: Arc's Add Split View is ⇧⌃= (arc-dia-components.md records the menu's keys).
    let mut add_split_view = command("="); add_split_view.command = false; add_split_view.control = true; add_split_view.shift = true;
    assert_eq!(ws.key_binding("add_split_view").unwrap(), Some(add_split_view));
    // The binding names the app; the harness keeps its own title for its own app menu.
    assert_eq!(commands().into_iter().find(|command| command.id == "quit").unwrap().title, "Quit Ararat");
    assert_eq!(commands().len(), 40);
    for id in ["copy_link", "duplicate", "new_folder", "rename", "delete_folder", "clear_cache_site", "clear_cookies_site"].into_iter().map(String::from)
        .chain((1..=9).map(|n| format!("move_to_space_{n}"))) {
        assert_eq!(ws.key_binding(&id).unwrap(), None);
    }
    assert!(ws.to_ops().is_empty());
}

#[test]
fn clear_site_commands_are_named_unbound_and_survive_the_snapshot() {
    let mut ws = Workspace::default();
    for (id, title) in [("clear_cache_site", "Clear Cache"), ("clear_cookies_site", "Clear Cookies")] {
        let row = commands().into_iter().find(|command| command.id == id).unwrap();
        assert_eq!(row.title, title);
        assert_eq!(row.default_key, None);
        assert_eq!(ws.key_binding(id).unwrap(), None);
    }

    // Recording takes nothing from another row and leaves no conflict.
    let before: Vec<_> = ws.key_bindings().into_iter().filter(|binding| binding.key.is_some()).map(|binding| binding.command.id).collect();
    ws.set_key_binding("clear_cache_site", Some(command("k"))).unwrap();
    let table = ws.key_bindings();
    let cache = table.iter().find(|binding| binding.command.id == "clear_cache_site").unwrap();
    assert_eq!(cache.key, Some(command("k")));
    assert!(!cache.conflicting);
    assert_eq!(table.iter().filter(|binding| binding.conflicting).count(), 0);
    let after: Vec<_> = table.into_iter().filter(|binding| binding.key.is_some() && binding.command.id != "clear_cache_site").map(|binding| binding.command.id).collect();
    assert_eq!(after, before);

    // Recorded keys ride the snapshot like any other override.
    ws.set_key_binding("clear_cookies_site", Some(command("j"))).unwrap();
    let mut replayed = Workspace::default();
    for op in ws.to_ops() {
        if let Op::Put(record) = op {
            replayed.apply(&Op::Put(Record::parse(record.kind(), &record.id(), &record.body()).unwrap()));
        }
    }
    assert_eq!(replayed.key_binding("clear_cache_site").unwrap(), Some(command("k")));
    assert_eq!(replayed.key_binding("clear_cookies_site").unwrap(), Some(command("j")));
    // Reset returns both to no key without touching the table.
    replayed.reset_all_key_bindings();
    assert_eq!(replayed, Workspace::default());
}

#[test]
fn invalid_keys_and_unknown_commands_leave_the_workspace_untouched() {
    let mut ws = Workspace::default();
    let mut unmodified = command("x"); unmodified.command = false;
    let mut screenshot = command("4"); screenshot.shift = true;
    for key in [unmodified, command("q"), command("H"), screenshot, command(""), command("ab"), command("\0")] {
        assert!(ws.set_key_binding("close_tab", Some(key)).is_err());
        assert_eq!(ws, Workspace::default());
    }
    assert!(ws.set_key_binding("unknown", None).is_err());
    assert!(ws.reset_key_binding("unknown").is_err());
}

#[test]
fn conflict_clears_previous_owner_and_reset_takes_back_the_default() {
    let mut ws = Workspace::default();
    ws.set_key_binding("close_tab", Some(command("S"))).unwrap();
    assert_eq!(ws.key_binding("toggle_sidebar").unwrap(), None);
    assert_eq!(ws.key_binding("close_tab").unwrap(), Some(command("s")));
    ws.reset_key_binding("toggle_sidebar").unwrap();
    assert_eq!(ws.key_binding("close_tab").unwrap(), None);
    assert_eq!(ws.key_binding("toggle_sidebar").unwrap(), Some(command("s")));
    assert!(!ws.key_binding_overrides.contains_key("toggle_sidebar"));
    ws.reset_key_binding("close_tab").unwrap();
    assert!(ws.key_binding_overrides.is_empty());
    assert!(ws.reset_key_binding("close_tab").unwrap().is_empty());
    assert!(ws.set_key_binding("close_tab", Some(command("w"))).unwrap().is_empty());
    ws.set_key_binding("pin_tab", None).unwrap();
    ws.set_key_binding("settings", Some(command("x"))).unwrap();
    assert_eq!(ws.reset_all_key_bindings().len(), 2);
    assert_eq!(ws, Workspace::default());
}

#[test]
fn overrides_clear_and_reset_round_trip_through_store_and_journal() {
    let path = std::env::temp_dir().join(format!("ararat-key-bindings-{}.sqlite", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
    let (store, mut ws) = Store::open(&path).unwrap();
    store.write(ws.set_key_binding("close_tab", Some(command("s"))).unwrap());
    store.flush().unwrap();
    let (_, loaded) = Store::open(&path).unwrap();
    assert_eq!(loaded, ws);
    assert_eq!(loaded.key_binding_overrides.len(), 2);
    let overridden = ws.clone();
    store.write(ws.reset_key_binding("close_tab").unwrap());
    store.write(ws.reset_all_key_bindings());
    store.flush().unwrap();
    let (_, loaded) = Store::open(&path).unwrap();
    assert_eq!(loaded, Workspace::default());
    let conn = Connection::open(&path).unwrap();
    let mut replayed = Workspace::default();
    let mut saw_clear = false;
    let mut saw_reset = false;
    let mut stmt = conn.prepare("SELECT kind, id, body FROM journal ORDER BY seq").unwrap();
    for (index, row) in stmt.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, Option<String>>(2)?))).unwrap().enumerate() {
        let (kind, id, body) = row.unwrap();
        assert_eq!(Kind::parse(&kind), Some(Kind::KeyBinding));
        let op = match body {
            Some(body) => { saw_clear |= body == "null"; Op::Put(Record::parse(Kind::KeyBinding, &id, &body).unwrap()) },
            None => { saw_reset = true; Op::Delete(Kind::KeyBinding, id) },
        };
        replayed.apply(&op);
        if index == 1 { assert_eq!(replayed, overridden); }
    }
    assert!(saw_clear && saw_reset);
    assert_eq!(replayed, ws);
    drop(stmt); drop(conn); drop(store);
    for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
}

#[test]
fn option_control_and_unicode_keys_are_preserved_in_exported_records() {
    let mut ws = Workspace::default();
    for (id, key) in [
        ("settings", KeyCombination { key: "é".into(), command: false, control: false, option: true, shift: true }),
        ("close_tab", KeyCombination { key: "\u{f700}".into(), command: false, control: true, option: false, shift: false }),
    ] {
        ws.set_key_binding(id, Some(key.clone())).unwrap();
        assert_eq!(ws.key_binding(id).unwrap(), Some(key));
    }
    let mut replayed = Workspace::default();
    for op in ws.to_ops() {
        if let Op::Put(record) = op {
            replayed.apply(&Op::Put(Record::parse(record.kind(), &record.id(), &record.body()).unwrap()));
        }
    }
    assert_eq!(replayed, ws);
}

#[test]
fn taking_an_override_clears_it_and_reset_does_not_reassign_it_back() {
    let mut ws = Workspace::default();
    ws.set_key_binding("close_tab", Some(command("x"))).unwrap();
    ws.set_key_binding("pin_tab", Some(command("x"))).unwrap();
    assert_eq!(ws.key_binding("close_tab").unwrap(), None);
    assert_eq!(ws.key_binding("pin_tab").unwrap(), Some(command("x")));
    ws.reset_key_binding("pin_tab").unwrap();
    assert_eq!(ws.key_binding("pin_tab").unwrap(), Some(command("d")));
    assert_eq!(ws.key_binding("close_tab").unwrap(), None);
    ws.reset_key_binding("close_tab").unwrap();
    assert!(ws.to_ops().is_empty());
}

#[test]
fn merged_assignments_have_one_deterministic_holder_without_changing_records() {
    let mut device_a = Workspace::default();
    let mut device_b = Workspace::default();
    let a = device_a.set_key_binding("close_tab", Some(command("x"))).unwrap();
    let b = device_b.set_key_binding("pin_tab", Some(command("x"))).unwrap();
    for ops in [a.iter().chain(&b), b.iter().chain(&a)] {
        let mut merged = Workspace::default();
        for op in ops { merged.apply(op); }
        let before = merged.clone();
        assert_eq!(merged.key_binding("close_tab").unwrap(), Some(command("x")));
        assert_eq!(merged.key_binding("pin_tab").unwrap(), None);
        assert_eq!(commands().iter().filter(|c| merged.key_binding(&c.id).unwrap() == Some(command("x"))).count(), 1);
        let table = merged.key_bindings();
        assert!(!table.iter().find(|row| row.command.id == "close_tab").unwrap().conflicting);
        assert!(table.iter().find(|row| row.command.id == "pin_tab").unwrap().conflicting);
        assert_eq!(table.iter().filter(|row| row.conflicting).count(), 1);
        assert_eq!(merged, before);
        merged.set_key_binding("settings", Some(command("x"))).unwrap();
        assert_eq!(merged.key_binding("close_tab").unwrap(), None);
        assert_eq!(merged.key_binding("pin_tab").unwrap(), None);
        merged.set_key_binding("settings", None).unwrap();
        assert_eq!(merged.key_binding("pin_tab").unwrap(), None);
    }
}

#[test]
fn shifted_screenshots_and_fixed_system_keys_are_refused() {
    let mut ws = Workspace::default();
    for value in ["3", "4", "5", "#", "$", "%"] {
        let mut key = command(value); key.shift = true;
        assert!(ws.set_key_binding("close_tab", Some(key)).is_err(), "accepted screenshot {value}");
    }
    let mut force_quit = command("\u{1b}"); force_quit.option = true;
    let mut lock_screen = command("q"); lock_screen.control = true;
    for key in [command("\t"), command(" "), command("`"), force_quit, lock_screen] {
        assert!(ws.set_key_binding("close_tab", Some(key)).is_err());
    }
    assert_eq!(ws, Workspace::default());
    let mut library = command("L"); library.shift = true;
    ws.set_key_binding("toggle_library", Some(library)).unwrap();
    let mut expected = command("l"); expected.shift = true;
    assert_eq!(ws.key_binding("toggle_library").unwrap(), Some(expected));
    assert!(ws.key_binding_overrides.is_empty());
}

#[test]
fn quit_default_can_be_recorded_after_clear_or_override() {
    let mut ws = Workspace::default();
    assert!(ws.set_key_binding("quit", Some(command("q"))).unwrap().is_empty());
    for key in [None, Some(command("x"))] {
        ws.set_key_binding("quit", key).unwrap();
        ws.set_key_binding("quit", Some(command("Q"))).unwrap();
        assert_eq!(ws.key_binding("quit").unwrap(), Some(command("q")));
        assert!(ws.key_binding_overrides.is_empty());
    }
    assert!(ws.set_key_binding("close_tab", Some(command("q"))).is_err());
}

#[test]
fn merged_loser_revives_when_the_winner_clears_moves_or_resets() {
    let mut a = Workspace::default();
    let mut b = Workspace::default();
    let ops = a.set_key_binding("close_tab", Some(command("x"))).unwrap();
    let other = b.set_key_binding("pin_tab", Some(command("x"))).unwrap();
    for action in 0..3 {
        let mut merged = Workspace::default();
        for op in ops.iter().chain(&other) { merged.apply(op); }
        match action {
            0 => { merged.set_key_binding("close_tab", None).unwrap(); },
            1 => { merged.set_key_binding("close_tab", Some(command("y"))).unwrap(); },
            _ => { merged.reset_key_binding("close_tab").unwrap(); },
        }
        let before = merged.clone();
        assert_eq!(merged.key_binding("pin_tab").unwrap(), Some(command("x")));
        assert!(!merged.key_bindings().iter().find(|row| row.command.id == "pin_tab").unwrap().conflicting);
        assert_eq!(merged, before);
    }
}

#[test]
fn reverse_app_and_window_switching_keys_are_reserved() {
    for value in ["\t", "`"] {
        let mut key = command(value); key.shift = true;
        assert!(Workspace::default().set_key_binding("close_tab", Some(key)).is_err());
    }
}
