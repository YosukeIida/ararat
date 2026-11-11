use ararat_core::import::arc_sidebar;
use ararat_core::model::{Op, Record, Workspace};

fn workspace() -> Workspace {
    arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json"), None, None, None, None).unwrap().0
}

// The visible rows of a container as (depth, id), the way the sidebar draws them.
fn rows(ws: &Workspace, container: &str, current: Option<&str>) -> Vec<(usize, String)> {
    ws.outline_keeping(container, current).into_iter().map(|(depth, item)| (depth, item.id.clone())).collect()
}

fn ids(ws: &Workspace, container: &str, current: Option<&str>) -> Vec<String> {
    rows(ws, container, current).into_iter().map(|(_, id)| id).collect()
}

#[test]
fn the_section_record_rides_with_the_space_and_replays_on_a_peer() {
    let base = workspace();
    let mut ws = base.clone();
    assert!(!ws.is_section_collapsed("space-work"));
    let ops = ws.set_section_collapsed("space-work", true).unwrap();
    assert!(matches!(&ops[..], [Op::Put(Record::SectionState { space, collapsed: true })] if space == "space-work"));
    assert!(ws.is_section_collapsed("space-work"));
    // The record is part of the workspace's records, so a sync carries it with the space.
    assert!(ws.to_ops().iter().any(|op|
        matches!(op, Op::Put(Record::SectionState { space, collapsed: true }) if space == "space-work")));
    let mut peer = base.clone();
    for op in &ops { peer.apply(op); }
    assert_eq!(peer, ws);
    let expand = ws.set_section_collapsed("space-work", false).unwrap();
    for op in &expand { peer.apply(op); }
    assert!(!peer.is_section_collapsed("space-work"));
    assert_eq!(peer, ws);
    // The record names a space the workspace has; an unknown id writes nothing.
    assert!(ws.set_section_collapsed("missing", true).is_err());
    assert!(!ws.is_section_collapsed("missing"));
}

#[test]
fn a_collapsed_folder_keeps_only_the_current_rows_path() {
    let mut ws = workspace();
    // folder-docs holds tab-spec; split-1 (with tab-a and tab-b) sits beside it.
    ws.set_folder_collapsed("folder-docs", true).unwrap();
    assert_eq!(ids(&ws, "pin-work", None), ["folder-docs", "split-1", "tab-a", "tab-b"]);
    assert_eq!(rows(&ws, "pin-work", Some("tab-spec")),
        [(0, "folder-docs".to_string()), (1, "tab-spec".to_string()), (0, "split-1".to_string()),
         (1, "tab-a".to_string()), (1, "tab-b".to_string())]);
    // A current row in another list keeps nothing: the folder behaves as before.
    assert_eq!(ids(&ws, "pin-work", Some("tab-mail")), ["folder-docs", "split-1", "tab-a", "tab-b"]);
    // Today is its own container and stays empty; a pinned current row keeps nothing there.
    assert!(rows(&ws, "today-work", Some("tab-spec")).is_empty());
}

#[test]
fn a_collapsed_pinned_section_keeps_the_current_pin_visible() {
    let mut ws = workspace();
    ws.set_section_collapsed("space-work", true).unwrap();
    assert!(ws.outline_keeping("pin-work", None).is_empty());
    assert_eq!(ids(&ws, "pin-work", Some("split-1")), ["split-1", "tab-a", "tab-b"]);
    // The folder holding the current tab keeps its own closed state: the path stays, the
    // folder's other children do not.
    ws.set_folder_collapsed("folder-docs", true).unwrap();
    assert_eq!(ids(&ws, "pin-work", Some("tab-spec")), ["folder-docs", "tab-spec"]);
    // Favourites and the other space's pinned list are other containers.
    assert_eq!(ids(&ws, "fav-default", None), ["tab-mail"]);
    assert!(ws.outline_keeping("pin-home", Some("tab-spec")).is_empty());
}
