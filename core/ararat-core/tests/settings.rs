use ararat_core::model::{Kind, Op, Record, Settings, Workspace};

#[test]
fn a_fresh_workspace_shows_the_new_tab_row_and_stores_no_record_for_it() {
    assert!(Workspace::default().settings.new_tab_row_shown);
    assert_eq!(Workspace::default().settings, Settings::default());
    assert!(!Workspace::default().to_ops().iter().any(|op| matches!(op, Op::Put(Record::Settings(_)))));
}

#[test]
fn turning_the_new_tab_row_off_writes_one_synced_record_and_a_reset_deletes_it() {
    let mut ws = Workspace::default();
    let ops = ws.set_new_tab_row_shown(false);
    assert!(matches!(&ops[..], [Op::Put(Record::Settings(settings))] if !settings.new_tab_row_shown));
    assert!(!ws.settings.new_tab_row_shown);
    let mut peer = Workspace::default();
    for op in &ops { peer.apply(op); }
    assert_eq!(peer, ws);
    // The change is a workspace record, so a sync carries it.
    assert!(ws.to_ops().iter().any(|op|
        matches!(op, Op::Put(Record::Settings(Settings { new_tab_row_shown: false })))));
    // Setting the value it already holds writes nothing.
    let before = ws.clone();
    assert!(ws.set_new_tab_row_shown(false).is_empty());
    assert_eq!(ws, before);
    // Back to the built-in value: a tombstone, not a row restating the default.
    let reset = ws.set_new_tab_row_shown(true);
    assert!(matches!(&reset[..], [Op::Delete(Kind::Settings, id)] if id == "workspace"));
    assert_eq!(ws.settings, Settings::default());
    assert!(!ws.to_ops().iter().any(|op| matches!(op, Op::Put(Record::Settings(_)))));
    let mut peer = peer;
    for op in &reset { peer.apply(op); }
    assert_eq!(peer, ws);
}
