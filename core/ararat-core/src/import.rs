// Format from Cra's notes on Arc 1.168–1.170; it read the owner's Arc 1.171 file without error.
// Unmodelled kinds (easel, arcDocument, tabGroup) are skipped rather than rejected, so one
// easel does not fail a whole import.

use std::collections::HashMap;

use serde_json::Value;

use crate::model::{Hlc, Id, Item, ItemKind, Membership, Orientation, Profile, Space, Workspace};
use crate::order::key_between;

#[derive(Debug, PartialEq, Eq)]
pub struct ImportError(pub String);

type Result<T> = std::result::Result<T, ImportError>;

pub fn arc_sidebar(json: &str) -> Result<Workspace> {
    let root: Value = serde_json::from_str(json).map_err(|e| ImportError(e.to_string()))?;
    let container = root["sidebar"]["containers"]
        .as_array()
        .and_then(|cs| cs.iter().find(|c| c.get("spaces").is_some()))
        .ok_or_else(|| err("sidebar.containers has no container with spaces"))?;

    let mut spaces = Vec::new();
    for (id, obj) in pairs(&container["spaces"])? {
        let order = key_between(spaces.last().map(|s: &Space| s.order.as_str()), None);
        spaces.push(space(id, obj, order)?);
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
    let mut workspace = Workspace { spaces, favorites, items, selected: None };
    // Arc's file is not trusted to be a tree; a cycle would make every later walk loop.
    workspace.repair_tree();
    workspace.check_tree().map_err(|e| err(&format!("sidebar is not a tree after repair: {e}")))?;
    Ok(workspace)
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
        id,
        order,
    })
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
        lifecycle: crate::model::Lifecycle::Open,
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
