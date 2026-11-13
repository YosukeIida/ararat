use ararat_core::model::{Kind, LittleWindowDevice, LittleWindowHotKey, LittleWindowOpenIn, Op, Record, Settings, SpaceScrollDirection, Workspace};

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

// U27d: the Tooltips switch (D4) is the same synced settings record, on by default.
#[test]
fn tooltips_start_on_and_turning_them_off_writes_one_synced_record() {
    assert!(Workspace::default().settings.tooltips_shown);
    assert!(!Workspace::default().to_ops().iter().any(|op| matches!(op, Op::Put(Record::Settings(_)))));
    let mut ws = Workspace::default();
    let ops = ws.set_tooltips_shown(false);
    assert!(matches!(&ops[..], [Op::Put(Record::Settings(settings))] if !settings.tooltips_shown));
    assert!(!ws.settings.tooltips_shown);
    // The record reads back: a peer that applies it and a store that replays it agree.
    let mut peer = Workspace::default();
    for op in &ops { peer.apply(op); }
    assert_eq!(peer, ws);
    assert!(ws.to_ops().iter().any(|op|
        matches!(op, Op::Put(Record::Settings(Settings { tooltips_shown: false, .. })))));
    // The same value again writes nothing; the New Tab row and the direction stay untouched.
    let before = ws.clone();
    assert!(ws.set_tooltips_shown(false).is_empty());
    assert_eq!(ws, before);
    assert!(ws.settings.new_tab_row_shown && ws.settings.space_scroll_direction == SpaceScrollDirection::Natural);
    // Back to the built-in value: a tombstone, not a row restating the default.
    let reset = ws.set_tooltips_shown(true);
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
fn the_three_settings_share_one_synced_record() {
    let mut ws = Workspace::default();
    ws.set_new_tab_row_shown(false);
    ws.set_space_scroll_direction(SpaceScrollDirection::Reversed);
    ws.set_tooltips_shown(false);
    let ops = ws.to_ops();
    let records = ops.iter().filter(|op| matches!(op, Op::Put(Record::Settings(_)))).count();
    assert_eq!(records, 1);
    // Turning the New Tab row back on keeps the reversed direction and the hidden tooltips.
    let ops = ws.set_new_tab_row_shown(true);
    assert!(matches!(&ops[..], [Op::Put(Record::Settings(settings))]
        if settings.new_tab_row_shown && settings.space_scroll_direction == SpaceScrollDirection::Reversed
            && !settings.tooltips_shown));
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

// U27i D8/D9: the Little Window's Open-in destination and close-after are the same synced
// record as the switches above; the frame, "Remember its size and place" and the global
// shortcut stay on the device.
#[test]
fn the_little_window_pair_is_synced_and_starts_at_most_recent_and_close() {
    assert_eq!(Workspace::default().settings.little_window_open_in, LittleWindowOpenIn::MostRecent);
    assert!(Workspace::default().settings.little_window_close_after);
    let mut ws = Workspace::default();
    let ops = ws.set_little_window_open_in(LittleWindowOpenIn::Space("work".into()));
    assert!(matches!(&ops[..], [Op::Put(Record::Settings(settings))]
        if settings.little_window_open_in == LittleWindowOpenIn::Space("work".into())));
    let mut peer = Workspace::default();
    for op in &ops { peer.apply(op); }
    assert_eq!(peer, ws);
    // The same value again writes nothing; the other Little Window switch stays untouched.
    let before = ws.clone();
    assert!(ws.set_little_window_open_in(LittleWindowOpenIn::Space("work".into())).is_empty());
    assert_eq!(ws, before);
    assert!(ws.settings.little_window_close_after);
    let ops = ws.set_little_window_close_after(false);
    assert!(matches!(&ops[..], [Op::Put(Record::Settings(settings))]
        if !settings.little_window_close_after
            && settings.little_window_open_in == LittleWindowOpenIn::Space("work".into())));
    // Back to both built-in values: one tombstone, not a row restating the defaults.
    let reset = ws.set_little_window_open_in(LittleWindowOpenIn::MostRecent);
    assert!(matches!(&reset[..], [Op::Put(Record::Settings(_))]));
    let reset = ws.set_little_window_close_after(true);
    assert!(matches!(&reset[..], [Op::Delete(Kind::Settings, id)] if id == "workspace"));
    assert_eq!(ws.settings, Settings::default());
}

#[test]
fn the_little_window_device_record_starts_at_remember_and_command_option_n_and_stays_off_the_synced_kinds() {
    let ws = Workspace::default();
    assert!(ws.little_window_device.remember_frame);
    assert_eq!(ws.little_window_device.hot_key, Some(LittleWindowHotKey::default_shortcut()));
    assert!(!ws.to_ops().iter().any(|op| matches!(op, Op::Put(Record::LittleWindowDevice(_)))));
    let mut ws = Workspace::default();
    let ops = ws.set_little_window_remember_frame(false);
    assert!(matches!(&ops[..], [Op::Put(Record::LittleWindowDevice(device))]
        if !device.remember_frame && device.hot_key == Some(LittleWindowHotKey::default_shortcut())));
    let mut peer = Workspace::default();
    for op in &ops { peer.apply(op); }
    assert_eq!(peer, ws);
    // The user's own "no global shortcut" is a stored None, not the absence of a record.
    let ops = ws.set_little_window_hot_key(None);
    assert!(matches!(&ops[..], [Op::Put(Record::LittleWindowDevice(device))]
        if device.hot_key.is_none() && !device.remember_frame));
    // Back to the built-in state: a tombstone, which reads as the defaults again.
    ws.set_little_window_remember_frame(true);
    let reset = ws.set_little_window_hot_key(Some(LittleWindowHotKey::default_shortcut()));
    assert!(matches!(&reset[..], [Op::Delete(Kind::LittleWindowDevice, id)] if id == "workspace"));
    assert_eq!(ws.little_window_device, LittleWindowDevice::default());
    let mut peer = peer;
    for op in &reset { peer.apply(op); }
    assert_eq!(peer, ws);
}

// A record from a device that stored only the remember switch still reads the default shortcut
// through serde's defaults, and an unknown destination value is refused like the direction.
#[test]
fn older_device_records_and_future_destinations_parse_by_the_field_rules() {
    let parsed = Record::parse(Kind::LittleWindowDevice, "workspace", r#"{"remember_frame":false}"#);
    assert!(matches!(parsed, Ok(Record::LittleWindowDevice(LittleWindowDevice { remember_frame: false, hot_key: Some(_) }))));
    let parsed = Record::parse(Kind::Settings, "workspace", r#"{"little_window_open_in":"Elsewhere"}"#);
    assert!(parsed.is_err());
    let parsed = Record::parse(Kind::Settings, "workspace", r#"{"little_window_open_in":{"Space":"work"},"little_window_close_after":false}"#);
    assert!(matches!(parsed, Ok(Record::Settings(Settings {
        little_window_open_in: LittleWindowOpenIn::Space(ref id), little_window_close_after: false, .. })) if id == "work"));
}
