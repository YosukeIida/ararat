// Format from Cra's notes on Arc 1.168–1.170; it read the owner's Arc 1.171 file without error.
// Unmodelled kinds (easel, arcDocument, tabGroup) are skipped rather than rejected, so one
// easel does not fail a whole import.

use std::collections::HashMap;

use serde_json::Value;

use crate::model::{Appearance, Hlc, Id, Item, ItemKind, Look, LookColor, Membership, Orientation, Profile, Space, Workspace};
use crate::order::key_between;

#[derive(Debug, PartialEq, Eq)]
pub struct ImportError(pub String);

#[derive(Debug, Default, PartialEq, Eq)]
pub struct ImportReport {
    pub unknown_space_looks: usize,
}

type Result<T> = std::result::Result<T, ImportError>;

pub fn arc_sidebar(json: &str) -> Result<Workspace> {
    arc_sidebar_with_report(json).map(|(workspace, _)| workspace)
}

pub fn arc_sidebar_with_report(json: &str) -> Result<(Workspace, ImportReport)> {
    let root: Value = serde_json::from_str(json).map_err(|e| ImportError(e.to_string()))?;
    let container = root["sidebar"]["containers"]
        .as_array()
        .and_then(|cs| cs.iter().find(|c| c.get("spaces").is_some()))
        .ok_or_else(|| err("sidebar.containers has no container with spaces"))?;

    let mut spaces = Vec::new();
    let mut report = ImportReport::default();
    for (id, obj) in pairs(&container["spaces"])? {
        let order = key_between(spaces.last().map(|s: &Space| s.order.as_str()), None);
        let space = space(id, obj, order)?;
        if !obj["customInfo"]["windowTheme"].is_null() && space.look.is_none() { report.unknown_space_looks += 1; }
        spaces.push(space);
    }

    let mut favorites = HashMap::new();
    for (key, value) in optional_flat_pairs(&container["topAppsContainerIDs"])? {
        let id = value.as_str().ok_or_else(|| err("topAppsContainerIDs: id is not a string"))?;
        favorites.insert(profile(key), id.to_string());
    }

    let raw = pairs(&container["items"])?;
    let orders = order_keys(&raw);
    let mut items = HashMap::new();
    for (id, obj) in &raw {
        let order = orders.get(id.as_str()).cloned().unwrap_or_else(|| key_between(None, None));
        if let Some(item) = item(id.clone(), obj, order)? {
            items.insert(item.id.clone(), item);
        }
    }

    for space in &spaces {
        for id in [&space.pinned, &space.today] {
            if !matches!(items.get(id), Some(Item { kind: ItemKind::Container, .. })) {
                return Err(err(&format!("space {} refers to {id}, which is not a container", space.id)));
            }
        }
    }
    let mut workspace = Workspace { spaces, favorites, items, windows: HashMap::new(), archive_after: HashMap::new(), last_selected: HashMap::new() };
    // Arc's file is not trusted to be a tree; a cycle would make every later walk loop.
    workspace.repair_tree();
    workspace.check_tree().map_err(|e| err(&format!("sidebar is not a tree after repair: {e}")))?;
    Ok((workspace, report))
}

fn space(id: String, obj: &Value, order: String) -> Result<Space> {
    let ids = obj["containerIDs"].as_array().ok_or_else(|| err("space without containerIDs"))?;
    let container_id = |name: &str| {
        ids.chunks(2)
            .find(|pair| pair[0] == name)
            .and_then(|pair| pair.get(1)?.as_str())
            .map(str::to_string)
            .ok_or_else(|| err(&format!("space {id} has no {name} container")))
    };
    Ok(Space {
        pinned: container_id("pinned")?,
        today: container_id("unpinned")?,
        title: obj["title"].as_str().unwrap_or_default().to_string(),
        profile: profile(&obj["profile"]),
        icon: obj["customInfo"]["iconType"]
            .as_object()
            .and_then(|icon| icon.values().next()?.as_str())
            .map(str::to_string),
        look: arc_look(&obj["customInfo"]["windowTheme"]),
        id,
        order,
    })
}

// Why not use Arc's derived palettes: the editable colours live in the background style.
// Schema/mapping adapted from mantrakp04/ardia, apps/browser/src/state/import/arcTheme.ts (GPL-3.0).
fn arc_look(theme: &Value) -> Option<Look> {
    let forced = theme["windowAppearance"]["single"]["_0"].as_str().or_else(|| {
        let based = &theme["windowAppearance"]["appearanceBased"];
        (based["light"] == based["dark"]).then(|| based["light"].as_str()).flatten()
    });
    let based = &theme["background"]["appearanceBased"];
    let background = if !theme["background"]["single"]["_0"].is_null() { &theme["background"]["single"]["_0"] }
        else if forced == Some("dark") && !based["dark"].is_null() { &based["dark"] }
        else if !based["light"].is_null() { &based["light"] } else { &based["dark"] };
    let kind = &background["style"]["color"]["_0"];
    let (config, basic, raw_colors): (&Value, bool, Vec<&Value>) = if let Some(config) = kind.get("blendedGradient").and_then(|v| v.get("_0")) {
        let colors: Vec<_> = config["baseColors"].as_array()?.iter().take(3).collect();
        (config, false, colors)
    } else if let Some(config) = kind.get("blendedSingleColor").and_then(|v| v.get("_0")) {
        (config, false, vec![&config["color"]])
    } else if let Some(config) = kind.get("basicColor").and_then(|v| v.get("_0")) {
        (config, true, vec![&config["color"]])
    } else { return None };
    let colors = raw_colors.into_iter().map(arc_color).collect::<Option<Vec<_>>>()?;
    let modifiers = &config["modifiers"];
    let appearance = match forced {
        Some("light") => Appearance::Light,
        Some("dark") => Appearance::Dark,
        _ => Appearance::Auto,
    };
    let look = Look { colors, opacity: if basic { 1.0 } else { (0.19 + 0.55 * modifiers["intensityFactor"].as_f64().unwrap_or(1.0)).clamp(0.0, 1.0) },
        grain: if basic { 0.0 } else { modifiers["noiseFactor"].as_f64().unwrap_or(0.0).clamp(0.0, 1.0) }, glass: false, appearance };
    look.is_valid().then_some(look)
}

fn arc_color(color: &Value) -> Option<LookColor> {
    let red = color["red"].as_f64()?.clamp(0.0, 1.0);
    let green = color["green"].as_f64()?.clamp(0.0, 1.0);
    let blue = color["blue"].as_f64()?.clamp(0.0, 1.0);
    let max = red.max(green).max(blue);
    let min = red.min(green).min(blue);
    let delta = max - min;
    let hue = if delta == 0.0 { 0.0 } else if max == red { ((green - blue) / delta).rem_euclid(6.0) }
        else if max == green { (blue - red) / delta + 2.0 } else { (red - green) / delta + 4.0 } / 6.0;
    Some(LookColor { red, green, blue,
        x: color["position"]["x"].as_f64().unwrap_or(hue).clamp(0.0, 1.0),
        y: color["position"]["y"].as_f64().unwrap_or(1.0 - (max + min) / 2.0).clamp(0.0, 1.0) })
}

fn item(id: String, obj: &Value, order: String) -> Result<Option<Item>> {
    let data = obj["data"].as_object().ok_or_else(|| err(&format!("item {id} has no data")))?;
    let Some((case, body)) = data.iter().next() else {
        return Err(err(&format!("item {id} has empty data")));
    };
    let kind = match case.as_str() {
        "tab" => ItemKind::Tab {
            url: body["savedURL"].as_str().unwrap_or_default().to_string(),
            saved_title: body["savedTitle"].as_str().map(str::to_string),
        },
        "list" => ItemKind::Folder,
        "itemContainer" => ItemKind::Container,
        "splitView" => ItemKind::Split {
            orientation: match body["layoutOrientation"].as_str() {
                Some("vertical") => Orientation::Vertical,
                _ => Orientation::Horizontal,
            },
            width_factors: optional_flat_pairs(&body["itemWidthFactors"])?
                .into_iter()
                .filter_map(|(k, v)| Some((k.as_str()?.to_string(), v.as_f64()?)))
                .collect(),
        },
        _ => return Ok(None),
    };
    Ok(Some(Item {
        membership: Membership {
            parent: obj["parentID"].as_str().map(str::to_string),
            order,
            hlc: Hlc::default(),
            previous_parent: None,
        },
        title: obj["title"].as_str().map(str::to_string),
        kind,
        lifecycle: crate::model::Lifecycle::Open, lifecycle_changed_at: 0,
        collapsed: false,
        id,
    }))
}

fn order_keys<'a>(items: &'a [(Id, &Value)]) -> HashMap<&'a str, String> {
    let mut keys = HashMap::new();
    for (_, obj) in items {
        let mut prev: Option<String> = None;
        for child in obj["childrenIds"].as_array().into_iter().flatten().filter_map(Value::as_str) {
            let key = key_between(prev.as_deref(), None);
            prev = Some(key.clone());
            keys.insert(child, key);
        }
    }
    keys
}

fn profile(value: &Value) -> Profile {
    match value.as_object().and_then(|o| o.iter().next()) {
        Some((case, _)) if case == "default" => Profile::Default,
        Some((_, body)) => Profile::Named(
            first_string(body).unwrap_or_else(|| body.to_string()),
        ),
        None => Profile::Default,
    }
}

fn first_string(value: &Value) -> Option<String> {
    match value {
        Value::String(s) => Some(s.clone()),
        Value::Object(map) => map.values().find_map(first_string),
        _ => None,
    }
}

fn pairs(value: &Value) -> Result<Vec<(Id, &Value)>> {
    flat_pairs(value)?
        .into_iter()
        .map(|(k, v)| {
            let id = k.as_str().ok_or_else(|| err("list key is not a string id"))?;
            Ok((id.to_string(), v))
        })
        .collect()
}

fn optional_flat_pairs(value: &Value) -> Result<Vec<(&Value, &Value)>> {
    if value.is_null() { Ok(Vec::new()) } else { flat_pairs(value) }
}

fn flat_pairs(value: &Value) -> Result<Vec<(&Value, &Value)>> {
    let list = value.as_array().ok_or_else(|| err("expected a flat list"))?;
    if list.len() % 2 != 0 {
        return Err(err("flat list has an odd length"));
    }
    Ok(list.chunks(2).map(|pair| (&pair[0], &pair[1])).collect())
}

fn err(message: &str) -> ImportError {
    ImportError(message.to_string())
}
