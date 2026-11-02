//! The fixture is synthetic, built from Cra's notes on Arc's format. The importer has also read
//! the owner's real `StorableSidebar.json` (Arc 1.171) without error.

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

fn fixture_with(edit: impl FnOnce(&mut serde_json::Value)) -> String {
    let mut root: serde_json::Value = serde_json::from_str(FIXTURE).unwrap();
    edit(&mut root["sidebar"]["containers"][1]);
    root.to_string()
}

#[test]
fn rejects_missing_or_mistyped_required_lists() {
    assert!(arc_sidebar(r#"{"sidebar":{"containers":[{"spaces":null}]}}"#).is_err());
    let no_items = fixture_with(|c| {
        c.as_object_mut().unwrap().remove("items");
    });
    assert!(arc_sidebar(&no_items).is_err());
}

#[test]
fn rejects_a_space_whose_containers_are_not_containers() {
    let json = fixture_with(|c| {
        let spaces = c["spaces"].as_array_mut().unwrap();
        spaces[1]["containerIDs"][1] = "folder-docs".into();
    });
    assert!(arc_sidebar(&json).is_err());
}

#[test]
fn repairs_a_cycle_in_the_imported_tree() {
    let json = fixture_with(|c| {
        let items = c["items"].as_array_mut().unwrap();
        let folder = items.iter().position(|v| v == "folder-docs").unwrap() + 1;
        items[folder]["parentID"] = "tab-spec".into();
    });
    let ws = arc_sidebar(&json).unwrap();
    assert_eq!(ws.check_tree(), Ok(()));
}

#[test]
fn maps_synthetic_single_gradient_and_handle_positions() {
    use ararat_core::model::Appearance;
    let (ws, report) = ararat_core::import::arc_sidebar_with_report(FIXTURE).unwrap();
    assert_eq!(report.unknown_space_looks, 0);
    let single = ws.spaces[0].look.as_ref().unwrap();
    assert_eq!(single.colors.len(), 1);
    assert_eq!((single.colors[0].red, single.colors[0].green, single.colors[0].blue), (0.8, 0.2, 0.4));
    assert_eq!((single.colors[0].x, single.colors[0].y), (0.7, 0.3));
    assert!((single.opacity - 0.465).abs() < 1e-12);
    assert_eq!(single.grain, 0.3); assert!(!single.glass); assert_eq!(single.appearance, Appearance::Light);
    let gradient = ws.spaces[1].look.as_ref().unwrap();
    assert_eq!(gradient.colors.len(), 2);
    assert_eq!(gradient.colors.iter().map(|c| c.x).collect::<Vec<_>>(), [0.0, 2.0/3.0]);
    assert!(gradient.colors.iter().all(|c| c.y == 0.5));
    assert!((gradient.opacity - 0.63).abs() < 1e-12);
    assert_eq!(gradient.grain, 0.45); assert_eq!(gradient.appearance, Appearance::Auto);
}

#[test]
fn clamps_imported_values_and_counts_unknown_or_malformed_shapes() {
    for (intensity, expected) in [(-9.0, 0.0), (9.0, 1.0), (0.0, 0.19), (1.0, 0.74)] {
        let json = fixture_with(|c| {
            let shape = &mut c["spaces"][1]["customInfo"]["windowTheme"]["background"]["single"]["_0"]["style"]["color"]["_0"]["blendedSingleColor"]["_0"];
            shape["modifiers"]["intensityFactor"] = intensity.into(); shape["modifiers"]["noiseFactor"] = 4.into();
            shape["color"]["red"] = (-1).into(); shape["color"]["blue"] = 2.into();
        });
        let ws = arc_sidebar(&json).unwrap(); let look = ws.spaces[0].look.as_ref().unwrap();
        assert!((look.opacity - expected).abs() < 1e-12); assert_eq!(look.grain, 1.0);
        assert_eq!((look.colors[0].red, look.colors[0].blue), (0.0, 1.0));
    }
    for shape in [serde_json::json!({"futureShape":{"_0":{}}}), serde_json::json!({"blendedSingleColor":{"_0":{"color":{}}}})] {
        let json = fixture_with(|c| c["spaces"][1]["customInfo"]["windowTheme"]["background"]["single"]["_0"]["style"]["color"]["_0"] = shape);
        let (ws, report) = ararat_core::import::arc_sidebar_with_report(&json).unwrap();
        assert_eq!(ws.spaces[0].look, None); assert_eq!(report.unknown_space_looks, 1);
    }
}

#[test]
fn appearance_selection_basic_color_and_optional_overlay() {
    use ararat_core::model::Appearance;
    let mut root: serde_json::Value = serde_json::from_str(FIXTURE).unwrap();
    let theme = &mut root["sidebar"]["containers"][1]["spaces"][3]["customInfo"]["windowTheme"];
    theme["windowAppearance"] = serde_json::json!({"single":{"_0":"dark"}});
    theme["background"]["appearanceBased"]["dark"] = serde_json::json!({"style":{"color":{"_0":{"basicColor":{"_0":{"color":{"red":0.2,"green":0.2,"blue":0.2}}}}}}});
    let ws = arc_sidebar(&root.to_string()).unwrap(); let look = ws.spaces[1].look.as_ref().unwrap();
    assert_eq!(look.appearance, Appearance::Dark); assert_eq!(look.opacity, 1.0); assert_eq!(look.grain, 0.0);
    assert_eq!((look.colors[0].x, look.colors[0].y), (0.0, 0.8));
    for (overlays, count) in [(serde_json::json!([]), 2), (serde_json::json!([{"red":0,"green":1,"blue":0}]), 2)] {
        let json = fixture_with(|c| c["spaces"][3]["customInfo"]["windowTheme"]["background"]["appearanceBased"]["light"]["style"]["color"]["_0"]["blendedGradient"]["_0"]["overlayColors"] = overlays);
        assert_eq!(arc_sidebar(&json).unwrap().spaces[1].look.as_ref().unwrap().colors.len(), count);
    }
    let json = fixture_with(|c| { c["spaces"][1]["customInfo"].as_object_mut().unwrap().remove("windowTheme"); });
    let (ws, report) = ararat_core::import::arc_sidebar_with_report(&json).unwrap();
    assert_eq!(ws.spaces[0].look, None); assert_eq!(report.unknown_space_looks, 0);
    let json = fixture_with(|c| {
        let theme = &mut c["spaces"][1]["customInfo"]["windowTheme"];
        theme["windowAppearance"] = serde_json::json!({"appearanceBased":{"light":"light","dark":"dark"}});
        theme["background"]["single"]["_0"]["style"]["color"]["_0"]["blendedSingleColor"]["_0"]["translucencyStyle"] = "dark".into();
    });
    assert_eq!(arc_sidebar(&json).unwrap().spaces[0].look.as_ref().unwrap().appearance, Appearance::Auto);
}

#[test]
fn missing_window_appearance_defaults_to_auto_instead_of_translucency_style() {
    let json = fixture_with(|c| {
        let theme = &mut c["spaces"][1]["customInfo"]["windowTheme"];
        theme.as_object_mut().unwrap().remove("windowAppearance");
        theme["background"]["single"]["_0"]["style"]["color"]["_0"]["blendedSingleColor"]["_0"]["translucencyStyle"] = "dark".into();
    });
    assert_eq!(arc_sidebar(&json).unwrap().spaces[0].look.as_ref().unwrap().appearance, ararat_core::model::Appearance::Auto);
}

#[test]
fn gradient_keeps_three_explicit_base_colors_without_derived_overlay_colors() {
    let json = fixture_with(|c| {
        let gradient = &mut c["spaces"][3]["customInfo"]["windowTheme"]["background"]["appearanceBased"]["light"]["style"]["color"]["_0"]["blendedGradient"]["_0"];
        gradient["baseColors"].as_array_mut().unwrap().push(serde_json::json!({"red":0.25,"green":0.5,"blue":0.75}));
    });
    let ws = arc_sidebar(&json).unwrap(); let colors = &ws.spaces[1].look.as_ref().unwrap().colors;
    assert_eq!(colors.len(), 3); assert_eq!((colors[2].red, colors[2].green, colors[2].blue), (0.25, 0.5, 0.75));
}
