//! The fixture is synthetic, built from the notes on Arc's format. The importer has also read
//! the owner's real `StorableSidebar.json` (Arc 1.171) without error.

use ararat_core::import::arc_sidebar;
use ararat_core::model::{ItemKind, Orientation, Profile};

const FIXTURE: &str = include_str!("fixtures/arc-sidebar-synthetic.json");

#[test]
fn the_report_counts_only_what_the_import_produced() {
    let (_, report) = arc_sidebar(FIXTURE, None, None, None, None).unwrap();
    assert_eq!(report.spaces, 2);
    // Pinned: Work holds folder-docs (tab-spec) and split-1 (tab-a, tab-b).
    assert_eq!(report.pinned_tabs, 3);
    assert_eq!(report.folders, 1);
    assert_eq!(report.favourite_tabs, 1);
    // Both spaces carry an importable look (Work's basic colour, Home's gradient).
    assert_eq!(report.spaces_with_look, 2);
    assert_eq!(report.imported_rules, 0);
}

#[test]
fn imports_spaces_with_their_containers_and_profiles() {
    let ws = arc_sidebar(FIXTURE, None, None, None, None).unwrap().0;
    let titles: Vec<_> = ws.spaces.iter().map(|s| s.title.as_str()).collect();
    assert_eq!(titles, ["Work", "Home"]);
    assert_eq!(ws.spaces[0].pinned, "pin-work");
    assert_eq!(ws.spaces[0].today, "today-work");
    assert_eq!(ws.spaces[0].icon.as_deref(), Some("💼"));
    assert_eq!(ws.spaces[1].profile, Profile::Named("Profile 1".into()));
    assert_eq!(ws.spaces[0].favorites.as_deref(), Some("space-work:favorites"));
    assert_eq!(ws.spaces[1].favorites.as_deref(), Some("space-home:favorites"));
    assert_eq!(ws.children("space-work:favorites")[0].id, "tab-mail");
    assert!(ws.children("space-home:favorites").is_empty());
    assert!(!ws.items.contains_key("fav-default"));
}

#[test]
fn arc_favorite_goes_to_the_first_space_of_its_profile_in_file_order() {
    let json = fixture_with(|c| {
        let spaces = c["spaces"].as_array_mut().unwrap();
        spaces[3]["profile"] = spaces[1]["profile"].clone();
        spaces.rotate_left(2);
        let items = c["items"].as_array_mut().unwrap();
        let favorite = items.iter().position(|value| value == "tab-mail").unwrap();
        let source = items.iter().position(|value| value == "fav-default").unwrap();
        let mut second = items[favorite + 1].clone();
        second["id"] = "a-second-favorite".into();
        items[source + 1]["childrenIds"] = serde_json::json!(["tab-mail", "a-second-favorite"]);
        items.extend(["a-second-favorite".into(), second]);
    });
    let (workspace, report) = arc_sidebar(&json, None, None, None, None).unwrap();
    assert_eq!(workspace.spaces[0].id, "space-home");
    let favorites: Vec<_> = workspace.children("space-home:favorites").into_iter().map(|item| item.id.as_str()).collect();
    assert_eq!(favorites, ["tab-mail", "a-second-favorite"]);
    assert!(workspace.children("space-work:favorites").is_empty());
    assert_eq!(report.favourite_tabs, 2);
}

#[test]
fn arc_favourites_without_a_matching_space_are_skipped_and_reported_by_profile() {
    let json = fixture_with(|c| {
        c["topAppsContainerIDs"][0] = serde_json::json!({"custom": {"_0": {"directoryBasename": "Missing Profile"}}});
    });
    let (workspace, report) = arc_sidebar(&json, None, None, None, None).unwrap();
    assert_eq!(report.spaces, 2);
    assert_eq!(report.pinned_tabs, 3);
    assert_eq!(report.favourite_tabs, 0);
    assert_eq!(report.skipped_favourites_by_profile, [("Missing Profile".into(), 1)].into());
    assert!(!workspace.items.contains_key("tab-mail"));
    assert!(!workspace.items.contains_key("fav-default"));
    workspace.check_tree().unwrap();
}

#[test]
fn keeps_tree_order_renames_and_splits() {
    let ws = arc_sidebar(FIXTURE, None, None, None, None).unwrap().0;
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
    let ws = arc_sidebar(FIXTURE, None, None, None, None).unwrap().0;
    assert!(!ws.items.contains_key("easel-1"));
    assert!(arc_sidebar("{}", None, None, None, None).is_err());
    assert!(arc_sidebar(r#"{"sidebar":{"containers":[{"spaces":["a"]}]}}"#, None, None, None, None).is_err());
}

fn fixture_with(edit: impl FnOnce(&mut serde_json::Value)) -> String {
    let mut root: serde_json::Value = serde_json::from_str(FIXTURE).unwrap();
    edit(&mut root["sidebar"]["containers"][1]);
    root.to_string()
}

#[test]
fn rejects_missing_or_mistyped_required_lists() {
    assert!(arc_sidebar(r#"{"sidebar":{"containers":[{"spaces":null}]}}"#, None, None, None, None).is_err());
    let no_items = fixture_with(|c| {
        c.as_object_mut().unwrap().remove("items");
    });
    assert!(arc_sidebar(&no_items, None, None, None, None).is_err());
}

#[test]
fn rejects_a_space_whose_containers_are_not_containers() {
    let json = fixture_with(|c| {
        let spaces = c["spaces"].as_array_mut().unwrap();
        spaces[1]["containerIDs"][1] = "folder-docs".into();
    });
    assert!(arc_sidebar(&json, None, None, None, None).is_err());
}

#[test]
fn repairs_a_cycle_in_the_imported_tree() {
    let json = fixture_with(|c| {
        let items = c["items"].as_array_mut().unwrap();
        let folder = items.iter().position(|v| v == "folder-docs").unwrap() + 1;
        items[folder]["parentID"] = "tab-spec".into();
    });
    let ws = arc_sidebar(&json, None, None, None, None).unwrap().0;
    assert_eq!(ws.check_tree(), Ok(()));
}

#[test]
fn maps_synthetic_single_gradient_and_handle_positions() {
    use ararat_core::model::Appearance;
    let (ws, report) = ararat_core::import::arc_sidebar(FIXTURE, None, None, None, None).unwrap();
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
        let ws = arc_sidebar(&json, None, None, None, None).unwrap().0; let look = ws.spaces[0].look.as_ref().unwrap();
        assert!((look.opacity - expected).abs() < 1e-12); assert_eq!(look.grain, 1.0);
        assert_eq!((look.colors[0].red, look.colors[0].blue), (0.0, 1.0));
    }
    for shape in [serde_json::json!({"futureShape":{"_0":{}}}), serde_json::json!({"blendedSingleColor":{"_0":{"color":{}}}})] {
        let json = fixture_with(|c| c["spaces"][1]["customInfo"]["windowTheme"]["background"]["single"]["_0"]["style"]["color"]["_0"] = shape);
        let (ws, report) = ararat_core::import::arc_sidebar(&json, None, None, None, None).unwrap();
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
    let ws = arc_sidebar(&root.to_string(), None, None, None, None).unwrap().0; let look = ws.spaces[1].look.as_ref().unwrap();
    assert_eq!(look.appearance, Appearance::Dark); assert_eq!(look.opacity, 1.0); assert_eq!(look.grain, 0.0);
    assert_eq!((look.colors[0].x, look.colors[0].y), (0.0, 0.8));
    for (overlays, count) in [(serde_json::json!([]), 2), (serde_json::json!([{"red":0,"green":1,"blue":0}]), 2)] {
        let json = fixture_with(|c| c["spaces"][3]["customInfo"]["windowTheme"]["background"]["appearanceBased"]["light"]["style"]["color"]["_0"]["blendedGradient"]["_0"]["overlayColors"] = overlays);
        assert_eq!(arc_sidebar(&json, None, None, None, None).unwrap().0.spaces[1].look.as_ref().unwrap().colors.len(), count);
    }
    let json = fixture_with(|c| { c["spaces"][1]["customInfo"].as_object_mut().unwrap().remove("windowTheme"); });
    let (ws, report) = ararat_core::import::arc_sidebar(&json, None, None, None, None).unwrap();
    assert_eq!(ws.spaces[0].look, None); assert_eq!(report.unknown_space_looks, 0);
    let json = fixture_with(|c| {
        let theme = &mut c["spaces"][1]["customInfo"]["windowTheme"];
        theme["windowAppearance"] = serde_json::json!({"appearanceBased":{"light":"light","dark":"dark"}});
        theme["background"]["single"]["_0"]["style"]["color"]["_0"]["blendedSingleColor"]["_0"]["translucencyStyle"] = "dark".into();
    });
    assert_eq!(arc_sidebar(&json, None, None, None, None).unwrap().0.spaces[0].look.as_ref().unwrap().appearance, Appearance::Auto);
}

#[test]
fn missing_window_appearance_defaults_to_auto_instead_of_translucency_style() {
    let json = fixture_with(|c| {
        let theme = &mut c["spaces"][1]["customInfo"]["windowTheme"];
        theme.as_object_mut().unwrap().remove("windowAppearance");
        theme["background"]["single"]["_0"]["style"]["color"]["_0"]["blendedSingleColor"]["_0"]["translucencyStyle"] = "dark".into();
    });
    assert_eq!(arc_sidebar(&json, None, None, None, None).unwrap().0.spaces[0].look.as_ref().unwrap().appearance, ararat_core::model::Appearance::Auto);
}

#[test]
fn gradient_keeps_three_explicit_base_colors_without_derived_overlay_colors() {
    let json = fixture_with(|c| {
        let gradient = &mut c["spaces"][3]["customInfo"]["windowTheme"]["background"]["appearanceBased"]["light"]["style"]["color"]["_0"]["blendedGradient"]["_0"];
        gradient["baseColors"].as_array_mut().unwrap().push(serde_json::json!({"red":0.25,"green":0.5,"blue":0.75}));
    });
    let ws = arc_sidebar(&json, None, None, None, None).unwrap().0; let colors = &ws.spaces[1].look.as_ref().unwrap().colors;
    assert_eq!(colors.len(), 3); assert_eq!((colors[2].red, colors[2].green, colors[2].blue), (0.25, 0.5, 0.75));
}

const WINDOWS: &str = include_str!("fixtures/StorableWindows.json");

#[test]
fn window_counters_only_describe_the_selected_window() {
    let json = serde_json::json!({"windows":[
        {"expandedItems":[],"itemLastActiveDates":[]},
        {"expandedItems":["folder-docs",{"peeked":{}},"unknown",{"expanded":{}}]}
    ]}).to_string();
    let (_, report) = ararat_core::import::arc_sidebar(FIXTURE, Some(&json), None, None, None).unwrap();
    assert_eq!(report.peeked_folders, 0);
    assert_eq!(report.unknown_window_ids, 0);
}

#[test]
fn duplicate_folder_pairs_are_malformed_and_the_last_state_wins() {
    for (states, collapsed) in [(serde_json::json!([{"expanded":{}},{"peeked":{}}]), true),
        (serde_json::json!([{"peeked":{}},{"expanded":{}}]), false)] {
        let json = serde_json::json!({"windows":[{"expandedItems":[
            "folder-docs",states[0],"folder-docs",states[1]],"itemLastActiveDates":[]}]}).to_string();
        let (ws, report) = ararat_core::import::arc_sidebar(FIXTURE, Some(&json), None, None, None).unwrap();
        assert_eq!(ws.folder_collapsed["folder-docs"], collapsed);
        assert_eq!(report.malformed_window_entries, 1);
        assert_eq!(report.peeked_folders, usize::from(collapsed));
    }
}

#[test]
fn expansion_keys_preserve_state_when_payloads_change() {
    for (state, collapsed, malformed, peeked) in [
        (serde_json::json!({"expanded":{"future":1}}), false, 0, 0),
        (serde_json::json!({"expanded":true}), false, 1, 0),
        (serde_json::json!({"peeked":{"future":1}}), true, 0, 1),
        (serde_json::json!({"peeked":true}), true, 1, 1),
    ] {
        let json = serde_json::json!({"windows":[{"expandedItems":["folder-docs",state],"itemLastActiveDates":[]}]}).to_string();
        let (ws, report) = ararat_core::import::arc_sidebar(FIXTURE, Some(&json), None, None, None).unwrap();
        assert_eq!(ws.folder_collapsed["folder-docs"], collapsed);
        assert_eq!(report.malformed_window_entries, malformed);
        assert_eq!(report.peeked_folders, peeked);
    }
}

#[test]
fn last_selected_dates_only_seed_tabs() {
    let json = serde_json::json!({"windows":[{"expandedItems":[],"itemLastActiveDates":[
        "folder-docs",0.0,"split-1",0.0,"pin-work",0.0,"tab-a",0.0]}]}).to_string();
    let (ws, report) = ararat_core::import::arc_sidebar(FIXTURE, Some(&json), None, None, None).unwrap();
    assert_eq!(ws.last_selected.len(), 1);
    assert_eq!(ws.last_selected["tab-a"], 978_307_200_000);
    assert_eq!(report.skipped_dates, 3);
}

#[test]
fn first_window_seeds_local_state_and_auto_archive_uses_imported_dates() {
    use ararat_core::{import::arc_sidebar, model::Lifecycle};
    let json = fixture_with(|c| {
        let items = c["items"].as_array_mut().unwrap();
        for id in ["tab-a", "tab-b", "tab-spec"] {
            let index = items.iter().position(|v| v == id).unwrap() + 1;
            items[index]["parentID"] = "today-work".into();
        }
    });
    let (mut ws, report) = arc_sidebar(&json, Some(WINDOWS), None, None, None).unwrap();
    assert_eq!(ws.folder_collapsed["folder-docs"], true);
    assert_eq!(report.differing_folder_states, 1);
    assert!(!report.missing_windows);
    assert_eq!(report.windows_error, None);
    assert_eq!(report.peeked_folders, 1);
    assert_eq!(report.unknown_window_ids, 2);
    assert_eq!(report.malformed_window_entries, 1);
    assert_eq!(report.skipped_dates, 1);
    assert_eq!(ws.last_selected["tab-a"], 1_678_307_200_000);
    assert_eq!(ws.last_selected["tab-b"], 1_678_393_599_500);
    assert!(!ws.last_selected.contains_key("easel-1"));
    ws.auto_archive(1_678_393_600_000).unwrap();
    assert_eq!(ws.items["tab-a"].lifecycle, Lifecycle::Archived);
    assert_eq!(ws.items["tab-b"].lifecycle, Lifecycle::Open);
    assert_eq!(ws.items["tab-spec"].lifecycle, Lifecycle::Open);
    assert_eq!(ws.last_selected["tab-spec"], 1_678_393_600_000);
    let mut windows: serde_json::Value = serde_json::from_str(WINDOWS).unwrap();
    windows["windows"].as_array_mut().unwrap().reverse();
    let (ws, report) = arc_sidebar(FIXTURE, Some(&windows.to_string()), None, None, None).unwrap();
    assert_eq!(ws.folder_collapsed["folder-docs"], false);
    assert_eq!(report.differing_folder_states, 1);
    assert_eq!(ws.last_selected["tab-a"], 1_678_393_600_000);
}

#[test]
fn missing_or_malformed_windows_preserve_sidebar_and_report_the_reason() {
    use ararat_core::import::arc_sidebar;
    let (expected, report) = arc_sidebar(FIXTURE, None, None, None, None).unwrap();
    assert!(report.missing_windows);
    for malformed in ["{", "{}", r#"{"windows":[]}"#, r#"{"windows":[1]}"#] {
        let (actual, report) = arc_sidebar(FIXTURE, Some(malformed), None, None, None).unwrap();
        assert_eq!(actual, expected);
        assert!(!report.missing_windows);
        assert!(report.windows_error.is_some());
    }
}

#[test]
fn reference_date_epoch_fractional_seconds_and_invalid_or_future_dates() {
    use ararat_core::import::arc_sidebar;
    let json = serde_json::json!({"windows":[{"expandedItems":[],
        "itemLastActiveDates":["tab-a", 0.0, "tab-b", 0.125]}]}).to_string();
    let (ws, report) = arc_sidebar(FIXTURE, Some(&json), None, None, None).unwrap();
    assert_eq!(ws.last_selected["tab-a"], 978_307_200_000);
    assert_eq!(ws.last_selected["tab-b"], 978_307_200_125);
    assert_eq!(report.skipped_dates, 0);
    assert_eq!(report.differing_folder_states, 0);
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64;
    let recent = now - 1_000;
    let json = serde_json::json!({"windows":[{"expandedItems":[],
        "itemLastActiveDates":["tab-a", recent as f64 / 1_000.0 - 978_307_200.0]}]}).to_string();
    let (ws, report) = arc_sidebar(FIXTURE, Some(&json), None, None, None).unwrap();
    assert!(ws.last_selected["tab-a"].abs_diff(recent) <= 1);
    assert_eq!(report.skipped_dates, 0);
    let json = serde_json::json!({"windows":[{"expandedItems":[],"itemLastActiveDates":[
        "tab-a", 1e30, "tab-b", "invalid", "tab-spec", 1e300
    ]}]}).to_string();
    let (ws, report) = arc_sidebar(FIXTURE, Some(&json), None, None, None).unwrap();
    assert!(ws.last_selected.is_empty());
    assert_eq!(report.skipped_dates, 3);
}

#[test]
fn malformed_pairs_are_counted_and_skipped_without_discarding_valid_state() {
    use ararat_core::import::arc_sidebar;
    let json = serde_json::json!({"windows":[{
        "expandedItems":[false, {}, "folder-docs", {"expanded":{}}, "trailing"],
        "itemLastActiveDates":[42, 1.0, "tab-a", 0.0, "tab-b", null, "trailing"]
    }]}).to_string();
    let (ws, report) = arc_sidebar(FIXTURE, Some(&json), None, None, None).unwrap();
    assert_eq!(ws.folder_collapsed["folder-docs"], false);
    assert_eq!(ws.last_selected["tab-a"], 978_307_200_000);
    assert_eq!(report.malformed_window_entries, 4);
    assert_eq!(report.skipped_dates, 1);
    assert_eq!(report.windows_error, None);
    for state in [serde_json::json!({"future":{}}), serde_json::json!({"expanded":{},"peeked":{}})] {
        let json = serde_json::json!({"windows":[{"expandedItems":["folder-docs",state],"itemLastActiveDates":[]}]}).to_string();
        let (ws, report) = arc_sidebar(FIXTURE, Some(&json), None, None, None).unwrap();
        assert_eq!(ws.folder_collapsed["folder-docs"], true);
        assert_eq!(report.malformed_window_entries, 1);
    }
    let json = serde_json::json!({"windows":[{"expandedItems":{},"itemLastActiveDates":{}}]}).to_string();
    let (_, report) = arc_sidebar(FIXTURE, Some(&json), None, None, None).unwrap();
    assert_eq!(report.malformed_window_entries, 2);
}

#[test]
fn imported_window_state_reopens_locally_without_entering_the_journal() {
    use ararat_core::{import::arc_sidebar, storage::Store};
    let path = std::env::temp_dir().join(format!("import-windows-{}-{}.sqlite", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
    let (ws, _) = arc_sidebar(FIXTURE, Some(WINDOWS), None, None, None).unwrap();
    let (store, _) = Store::open(&path).unwrap();
    store.write(ws.to_ops());
    store.flush().unwrap();
    drop(store);
    let (_store, reopened) = Store::open(&path).unwrap();
    assert_eq!(reopened, ws);
    let conn = rusqlite::Connection::open(path).unwrap();
    let count: i64 = conn.query_row("SELECT count(*) FROM journal WHERE kind IN ('folder_state', 'last_selected')", [], |row| row.get(0)).unwrap();
    assert_eq!(count, 0);
}

#[test]
fn key_bindings_empty_and_unknown_overrides_never_change_the_workspace() {
    let expected = arc_sidebar(FIXTURE, None, None, None, None).unwrap().0;
    for (json, count) in [(r#"{"version":1,"userOverrides":[]}"#, 0),
        (r#"{"version":1,"userOverrides":[{"unknown":"shape"},null,"opaque"]}"#, 3)] {
        let (ws, report) = arc_sidebar(FIXTURE, None, Some(json), None, None).unwrap();
        assert_eq!(ws, expected);
        assert!(!report.missing_key_bindings);
        assert_eq!(report.key_bindings_error, None);
        assert_eq!(report.skipped_key_bindings, count);
    }
}

#[test]
fn missing_or_malformed_key_bindings_do_not_fail_the_sidebar_import() {
    let (expected, missing) = arc_sidebar(FIXTURE, None, None, None, None).unwrap();
    assert!(missing.missing_key_bindings);
    for json in ["�", "{}", r#"{"version":1,"userOverrides":{}}"#, r#"{"version":2,"userOverrides":[]}"#] {
        let (ws, report) = arc_sidebar(FIXTURE, None, Some(json), None, None).unwrap();
        assert_eq!(ws, expected);
        assert!(!report.missing_key_bindings);
        assert!(report.key_bindings_error.is_some());
        assert_eq!(report.skipped_key_bindings, 0);
    }
}

#[test]
fn key_bindings_version_error_precedes_override_shape_error() {
    for json in [r#"{"version":2,"userOverrides":{}}"#, r#"{"userOverrides":{}}"#] {
        let (_, report) = arc_sidebar(FIXTURE, None, Some(json), None, None).unwrap();
        assert_eq!(report.key_bindings_error.as_deref(), Some("unsupported key bindings version"));
    }
}
