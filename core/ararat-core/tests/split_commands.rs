use ararat_core::{import::arc_sidebar, model::{ItemKind, Orientation}};

#[test]
fn moving_and_converting_panes_keeps_selection_and_replays() {
    let (mut ws, _) = arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json"), None, None, None, None).unwrap();
    ws.select_item("window", "tab-a").unwrap();
    let mut replay = ws.clone();
    let ops = ws.move_pane("tab-a", true).unwrap();
    for op in &ops { replay.apply(op); }
    assert_eq!(ws, replay);
    assert_eq!(ws.children("split-1").iter().map(|item| item.id.as_str()).collect::<Vec<_>>(), ["tab-b", "tab-a"]);
    assert_eq!(ws.selected("window"), Some("tab-a"));
    let before = ws.clone();
    assert!(ws.move_pane("tab-a", true).is_err());
    assert_eq!(ws, before);
    ws.convert_split("split-1").unwrap();
    assert!(matches!(ws.items["split-1"].kind, ItemKind::Split { orientation: Orientation::Vertical, .. }));
    assert_eq!(ws.selected("window"), Some("tab-a"));
    ws.check_tree().unwrap();
}
