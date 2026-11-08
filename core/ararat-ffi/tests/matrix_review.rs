use ararat_ffi::*;

#[test]
fn mixed_profile_matrix_keeps_exact_command_lives_and_rejects_invalid_readiness() {
    let path = std::env::temp_dir().join(format!("matrix-review-{}.sqlite", std::process::id()));
    assert!(!path.exists());
    let store = WorkspaceStore::open(path.to_string_lossy().into_owned()).unwrap();
    let w = "matrix-review".to_string();
    store.import_arc_sidebar(w.clone(), include_str!("matrix-seed.json").into(), None, None, None, None).unwrap();
    let mut targets = vec![];
    for space in ["default", "named"] {
        store.show_space(w.clone(), space.into()).unwrap();
        let item = store.create_tab(w.clone(), "about:blank".into()).unwrap().selected_id.unwrap();
        targets.push((space.to_string(), item));
    }
    store.show_space(w.clone(), "default".into()).unwrap();
    for n in 3..=9 {
        let space = format!("matrix-{n}");
        store.create_space(w.clone(), space.clone(), space.clone()).unwrap();
        let item = store.create_tab(w.clone(), format!("about:blank?matrix={n}")).unwrap().selected_id.unwrap();
        targets.push((space, item));
    }
    let apply = |epoch, rev, cause, tabs, active| store.live_apply(LiveTransaction {
        epoch, rev, cause, strips: vec![LiveStrip { window: w.clone(), tabs, active }]
    }).unwrap();
    assert!(apply(1, 0, LiveCause::Engine, vec![], None).applied);
    let mut tabs = vec![];
    for (i, (space, item)) in targets.iter().enumerate() {
        assert_eq!(store.show_space_selecting(w.clone(), space.clone()).unwrap().selected_id, None);
        assert_eq!(store.show_space_selecting_tab(w.clone(), space.clone(), item.clone()).unwrap().selected_id.as_ref(), Some(item));
        let cmd = store.live_open(item.clone(), "about:blank".into()).unwrap();
        assert!(cmd.id.starts_with("cmd-"));
        assert_eq!(store.live_tab(item.clone()), Some(cmd.id.clone()));
        assert_eq!(store.item_for_live(cmd.id.clone()), Some(item.clone()));
        assert!(!tabs.iter().any(|t: &LiveTab| t.live_id == cmd.id));
        let profile = if i == 1 { Profile::Named("Profile 1".into()) } else { Profile::Default };
        assert_eq!(store.item_profile(item.clone()), Some(profile.clone()));
        tabs.push(LiveTab { profile, live_id: cmd.id.clone(), item: Some(item.clone()), opener: None,
            navigated: false, url: None, title: None });
        assert!(apply(1, i as u64 + 1, LiveCause::Command(cmd.id.clone()), tabs.clone(), Some(cmd.id.clone())).applied);
        assert_eq!(store.live_tab(item.clone()), Some(cmd.id));
    }
    assert_eq!(tabs.len(), 9);
    for (space, item) in &targets {
        assert_eq!(store.show_space_selecting(w.clone(), space.clone()).unwrap().selected_id.as_ref(), Some(item));
        let live = store.live_tab(item.clone()).unwrap();
        assert!(tabs.iter().any(|t| t.item.as_ref() == Some(item) && t.live_id == live));
        assert_eq!(store.item_for_live(live), Some(item.clone()));
    }
    let (space, item) = &targets[0];
    let before = store.snapshot(w.clone());
    let mut bad = tabs.clone(); bad[1].profile = Profile::Default;
    assert!(!apply(1, 10, LiveCause::Engine, bad, None).applied);
    assert_eq!(store.snapshot(w.clone()), before);
    let activate = store.live_activate(item.clone()).unwrap();
    assert!(store.live_cancel(activate.id.clone()));
    assert!(!apply(1, 11, LiveCause::Command(activate.id), tabs.clone(), tabs.first().map(|t| t.live_id.clone())).applied);
    let missing = tabs.remove(0);
    assert!(apply(1, 12, LiveCause::Engine, tabs.clone(), None).applied);
    assert_eq!(store.live_tab(item.clone()), None);
    assert_eq!(store.item_for_live(missing.live_id), None);
    let snapshot = store.show_space_selecting(w.clone(), space.clone()).unwrap();
    assert_eq!(snapshot.selected_id.as_ref(), Some(item));
    assert!(!snapshot.spaces.iter().find(|s| &s.id == space).unwrap().today[0].unloaded);
    assert!(apply(2, 0, LiveCause::Engine, vec![], None).applied);
    for (space, item) in &targets {
        assert_eq!(store.live_tab(item.clone()), None);
        assert_eq!(store.show_space_selecting(w.clone(), space.clone()).unwrap().selected_id, None);
    }
    store.create_space(w.clone(), "Empty".into(), "empty".into()).unwrap();
    let empty = store.show_space_selecting(w.clone(), "empty".into()).unwrap();
    assert_eq!(empty.shown_space_id.as_deref(), Some("empty"));
    assert_eq!(empty.selected_id, None);
    let before = store.snapshot(w.clone());
    assert!(store.show_space_selecting_tab(w.clone(), "empty".into(), item.clone()).is_err());
    assert_eq!(store.snapshot(w.clone()), before);
}
