//! The fixture is synthetic, built from Cra's notes on Arc's format; field names still need
//! checking against a real `StorableSidebar.json` before the importer ships.

use ararat_core::import::arc_sidebar;
use ararat_core::model::{ItemKind, Orientation, Profile};

const FIXTURE: &str = include_str!("fixtures/arc-sidebar-synthetic.json");

#[test]
fn imports_spaces_with_their_containers_and_profiles() {
    let ws = arc_sidebar(FIXTURE).unwrap();
    let titles: Vec<_> = ws.spaces.iter().map(|s| s.title.as_str()).collect();
    assert_eq!(titles, ["Work", "Home"]);
    assert_eq!(ws.spaces[0].pinned, "pin-work");
    assert_eq!(ws.spaces[0].today, "today-work");
    assert_eq!(ws.spaces[0].icon.as_deref(), Some("💼"));
    assert_eq!(ws.spaces[1].profile, Profile::Named("Profile 1".into()));
    assert_eq!(ws.favorites[&Profile::Default], "fav-default");
}

#[test]
fn keeps_tree_order_renames_and_splits() {
    let ws = arc_sidebar(FIXTURE).unwrap();
    let pinned: Vec<_> = ws.children("pin-work").iter().map(|i| i.id.as_str()).collect();
    assert_eq!(pinned, ["folder-docs", "split-1"]);

    let spec = &ws.items["tab-spec"];
    assert_eq!(spec.title.as_deref(), Some("Spec (renamed)"));
    assert!(matches!(&spec.kind, ItemKind::Tab { url, .. } if url == "https://docs.example.com/spec"));

    let ItemKind::Split { orientation, width_factors } = &ws.items["split-1"].kind else {
        panic!("split-1 is not a split");
    };
    assert_eq!(*orientation, Orientation::Horizontal);
    assert_eq!(width_factors, &[("tab-a".to_string(), 0.3), ("tab-b".to_string(), 0.7)]);
}

#[test]
fn skips_unmodelled_kinds_and_rejects_broken_input() {
    let ws = arc_sidebar(FIXTURE).unwrap();
    assert!(!ws.items.contains_key("easel-1"));
    assert!(arc_sidebar("{}").is_err());
    assert!(arc_sidebar(r#"{"sidebar":{"containers":[{"spaces":["a"]}]}}"#).is_err());
}
