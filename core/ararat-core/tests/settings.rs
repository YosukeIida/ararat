use ararat_core::model::{Kind, Op, Record, Settings, SpaceScrollDirection, Workspace};

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
        matches!(op, Op::Put(Record::Settings(Settings { new_tab_row_shown: false, .. })))));
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

// U27c: one sideways scroll direction for every device, Natural by default (D3).
#[test]
fn a_fresh_workspace_scrolls_naturally_and_stores_no_record_for_it() {
    assert_eq!(Workspace::default().settings.space_scroll_direction, SpaceScrollDirection::Natural);
    assert!(!Workspace::default().to_ops().iter().any(|op| matches!(op, Op::Put(Record::Settings(_)))));
}

#[test]
fn reversing_the_scroll_direction_writes_one_synced_record_and_a_reset_deletes_it() {
    let mut ws = Workspace::default();
    let ops = ws.set_space_scroll_direction(SpaceScrollDirection::Reversed);
    assert!(matches!(&ops[..], [Op::Put(Record::Settings(settings))]
        if settings.space_scroll_direction == SpaceScrollDirection::Reversed));
    assert_eq!(ws.settings.space_scroll_direction, SpaceScrollDirection::Reversed);
    // The record reads back: a peer that applies it and a store that replays it agree.
    let mut peer = Workspace::default();
    for op in &ops { peer.apply(op); }
    assert_eq!(peer, ws);
    assert!(ws.to_ops().iter().any(|op| matches!(op,
        Op::Put(Record::Settings(Settings { space_scroll_direction: SpaceScrollDirection::Reversed, .. })))));
    // The same value again writes nothing.
    let before = ws.clone();
    assert!(ws.set_space_scroll_direction(SpaceScrollDirection::Reversed).is_empty());
    assert_eq!(ws, before);
    // Back to Natural: a tombstone, and the New Tab row's own value rides in the same record.
    let reset = ws.set_space_scroll_direction(SpaceScrollDirection::Natural);
    assert!(matches!(&reset[..], [Op::Delete(Kind::Settings, id)] if id == "workspace"));
    assert_eq!(ws.settings, Settings::default());
    let mut peer = peer;
    for op in &reset { peer.apply(op); }
    assert_eq!(peer, ws);
}

#[test]
fn the_two_settings_share_one_synced_record() {
    let mut ws = Workspace::default();
    ws.set_new_tab_row_shown(false);
    ws.set_space_scroll_direction(SpaceScrollDirection::Reversed);
    let ops = ws.to_ops();
    let records = ops.iter().filter(|op| matches!(op, Op::Put(Record::Settings(_)))).count();
    assert_eq!(records, 1);
    // Turning the New Tab row back on keeps the reversed direction in the record.
    let ops = ws.set_new_tab_row_shown(true);
    assert!(matches!(&ops[..], [Op::Put(Record::Settings(settings))]
        if settings.new_tab_row_shown && settings.space_scroll_direction == SpaceScrollDirection::Reversed));
}

// A value the core does not know is refused when the record is parsed, so a future device's
// direction never reads as one of today's two.
#[test]
fn an_unknown_scroll_direction_is_refused() {
    let parsed = Record::parse(Kind::Settings, "workspace", r#"{"space_scroll_direction":"Sideways"}"#);
    assert!(parsed.is_err());
    let parsed = Record::parse(Kind::Settings, "workspace", r#"{"space_scroll_direction":"Reversed"}"#);
    assert!(matches!(parsed, Ok(Record::Settings(Settings { space_scroll_direction: SpaceScrollDirection::Reversed, .. }))));
}
