// Format of Arc 1.168–1.170; the importer read the owner's Arc 1.171 file without error.
// Unmodelled kinds (easel, arcDocument, tabGroup) are skipped rather than rejected, so one
// easel does not fail a whole import.

use std::collections::{HashMap, HashSet};

use serde_json::Value;

use crate::model::{Appearance, Hlc, Id, Item, ItemKind, Lifecycle, Look, LookColor, Membership, Orientation, Profile, Space, Workspace};
use crate::order::key_between;
use crate::routing::{Destination, MatchStyle, Rule, Routing, SpaceTarget, UrlCondition};

#[derive(Debug, PartialEq, Eq)]
pub struct ImportError(pub String);

#[derive(Debug, Default, PartialEq, Eq)]
pub struct ImportReport {
    pub missing_link_routing: bool,
    pub link_routing_error: Option<String>,
    // The counters are the routing import's (LinkRoutingReport, spelled the same way): one
    // counter per reason a rule was dropped, so the counters describe imported rules.
    pub imported_rules: usize,
    pub skipped_profile_destinations: usize,
    pub skipped_unknown_destinations: usize,
    pub skipped_unknown_styles: usize,
    pub malformed_rules: usize,
    pub unknown_space_looks: usize,
    pub skipped_favourites_by_profile: HashMap<String, usize>,
    pub missing_key_bindings: bool,
    pub key_bindings_error: Option<String>,
    pub skipped_key_bindings: usize,
    pub missing_windows: bool,
    pub windows_error: Option<String>,
    pub differing_folder_states: usize,
    pub skipped_dates: usize,
    pub peeked_folders: usize,
    pub unknown_window_ids: usize,
    pub malformed_window_entries: usize,
    // What the import itself produced, counted from the imported workspace before it is written:
    // the done screen shows these, never the store's totals, because a store may already hold
    // spaces from before the import (records are only ever put, never deleted, model.rs).
    pub spaces: usize,
    pub pinned_tabs: usize,
    pub folders: usize,
    pub favourite_tabs: usize,
    pub spaces_with_look: usize,
}

type Result<T> = std::result::Result<T, ImportError>;

pub fn arc_sidebar(json: &str, windows_json: Option<&str>, key_bindings_json: Option<&str>, link_routing_json: Option<&str>, owner: Option<Profile>) -> Result<(Workspace, ImportReport)> {
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
    for space in &spaces {
        let id = space.favorites.as_ref().unwrap();
        if items.contains_key(id) || spaces.iter().any(|space| &space.id == id) {
            return Err(err(&format!("favourites root ID {id} is already in use")));
        }
        items.insert(id.clone(), Item::container(id.clone(), 0));
    }
    let mut source_roots = HashSet::new();
    let mut skipped_roots = Vec::new();
    for (profile, source) in favorites {
        if !source_roots.insert(source.clone())
            || spaces.iter().any(|space| space.owns_root(&source))
            || items.get(&source).is_some_and(|item| !matches!(item.kind, ItemKind::Container))
        {
            return Err(err(&format!("invalid Arc favourites root {source}")));
        }
        let Some(target) = spaces.iter().find(|space| space.profile == profile)
            .and_then(|space| space.favorites.as_ref()) else {
                skipped_roots.push((profile, source));
                continue;
            };
        for item in items.values_mut().filter(|item| item.membership.parent.as_ref() == Some(&source)) {
            if !matches!(item.kind, ItemKind::Tab { .. }) {
                return Err(err(&format!("Arc favourite {} is not a tab", item.id)));
            }
            item.membership.parent = Some(target.clone());
        }
        items.remove(&source);
    }
    if !skipped_roots.is_empty() {
        let mut children = HashMap::<Id, Vec<Id>>::new();
        for item in items.values().filter(|item| !matches!(item.kind, ItemKind::Container)) {
            if let Some(parent) = &item.membership.parent {
                children.entry(parent.clone()).or_default().push(item.id.clone());
            }
        }
        for (profile, root) in skipped_roots {
            let mut pending = vec![root];
            let mut count = 0;
            while let Some(id) = pending.pop() {
                if items.remove(&id).is_some_and(|item| matches!(item.kind, ItemKind::Tab { .. })) {
                    count += 1;
                }
                pending.extend(children.remove(&id).into_iter().flatten());
            }
            if count > 0 {
                let name = match profile { Profile::Default => "Default".into(), Profile::Named(name) => name };
                *report.skipped_favourites_by_profile.entry(name).or_default() += count;
            }
        }
    }
    let mut workspace = Workspace { spaces, items, ..Workspace::default() };
    // Arc's file is not trusted to be a tree; a cycle would make every later walk loop.
    workspace.repair_tree();
    workspace.check_tree().map_err(|e| err(&format!("sidebar is not a tree after repair: {e}")))?;
    match windows_json {
        None => report.missing_windows = true,
        Some(json) => {
            if let Err(error) = window_state(json, &mut workspace, &mut report) {
                report.windows_error = Some(error.0);
            }
        }
    }
    match key_bindings_json {
        None => report.missing_key_bindings = true,
        Some(json) => match arc_key_bindings(json) {
            Ok(count) => report.skipped_key_bindings = count,
            Err(error) => report.key_bindings_error = Some(error.0),
        },
    }
    // The routing reads the spaces this import is about to produce: only destinations naming
    // one of them, in the profile that owns them, can open, and a Little-window destination
    // belongs to the routing file's owner — the profile the caller vouches for, and with no
    // owner named, the first space's (the file is profile-relative the way the sidebar is,
    // and the pane can change either). An unknown owner checks existence only: an owner it
    // cannot say cannot decide what is another profile's. The routing rides `to_ops()` with
    // the sidebar's records (a sidebar override never deletes: rules the workspace already
    // had stay), and an unreadable file never blocks the sidebar, as key_bindings_error
    // does not.
    let spaces: Vec<(Id, Profile)> = workspace.spaces.iter().map(|space| (space.id.clone(), space.profile.clone())).collect();
    match link_routing_json {
        None => report.missing_link_routing = true,
        Some(json) => match arc_link_routing(json, owner, &spaces) {
            Ok((routing, counters)) => {
                report.imported_rules = counters.imported_rules;
                report.skipped_profile_destinations = counters.skipped_profile_destinations;
                report.skipped_unknown_destinations = counters.skipped_unknown_destinations;
                report.skipped_unknown_styles = counters.skipped_unknown_styles;
                report.malformed_rules = counters.malformed_rules;
                install_routing(&mut workspace, routing);
            }
            Err(error) => report.link_routing_error = Some(error.0),
        },
    }
    count_import(&workspace, &mut report);
    Ok((workspace, report))
}

/// The five totals the import produced: spaces, every tab under a pinned container (splits and
/// folders included), those folders, the distinct favourite tabs
/// and the spaces whose look imported. Routes are `imported_rules`, the routing import's counter.
fn count_import(workspace: &Workspace, report: &mut ImportReport) {
    fn walk(workspace: &Workspace, container: &str, tabs: &mut usize, folders: &mut usize) {
        for child in workspace.children(container) {
            match child.kind {
                ItemKind::Tab { .. } => *tabs += 1,
                ItemKind::Folder => {
                    *folders += 1;
                    walk(workspace, &child.id, tabs, folders);
                }
                ItemKind::Split { .. } => walk(workspace, &child.id, tabs, folders),
                ItemKind::Container => {}
            }
        }
    }
    report.spaces = workspace.spaces.len();
    for space in &workspace.spaces {
        walk(workspace, &space.pinned, &mut report.pinned_tabs, &mut report.folders);
        if space.look.is_some() { report.spaces_with_look += 1; }
    }
    let mut favourites = HashSet::new();
    for container in workspace.spaces.iter().filter_map(|space| space.favorites.as_deref()) {
        for child in workspace.children(container) {
            if matches!(child.kind, ItemKind::Tab { .. }) { favourites.insert(child.id.clone()); }
        }
    }
    report.favourite_tabs = favourites.len();
}

// An imported routing installs in file order (the matching reads by key, ties fall back to the
// id, so chained keys reproduce the file order); same-id entries overwrite their row, the way
// an import that repeats itself stays idempotent.
fn install_routing(workspace: &mut Workspace, routing: Routing) {
    let mut previous: Option<String> = None;
    for rule in routing.rules {
        let order = key_between(previous.as_deref(), None);
        previous = Some(order.clone());
        workspace.routing_rules.insert(rule.id.clone(), crate::routing::StoredRule { order, rule });
    }
    workspace.routing_default = routing.default;
}

fn arc_key_bindings(json: &str) -> Result<usize> {
    let root: Value = serde_json::from_str(json).map_err(|e| err(&e.to_string()))?;
    if root["version"].as_u64() != Some(1) { return Err(err("unsupported key bindings version")); }
    let overrides = root["userOverrides"].as_array().ok_or_else(|| err("userOverrides must be an array"))?;
    Ok(overrides.len())
}

fn window_state(json: &str, workspace: &mut Workspace, report: &mut ImportReport) -> Result<()> {
    let root: Value = serde_json::from_str(json).map_err(|e| err(&e.to_string()))?;
    let windows = root["windows"].as_array().filter(|w| !w.is_empty() && w.iter().all(Value::is_object))
        .ok_or_else(|| err("windows must be a nonempty array of objects"))?;
    let mut expanded = Vec::new();
    for (index, window) in windows.iter().enumerate() {
        let mut open = std::collections::HashSet::new();
        let mut seen = std::collections::HashSet::new();
        let mut peeked = std::collections::HashSet::new();
        for (id, state) in window_pairs(&window["expandedItems"], report) {
            let Some(item) = workspace.items.get(&id) else { report.unknown_window_ids += usize::from(index == 0); continue; };
            if !matches!(item.kind, ItemKind::Folder) { report.malformed_window_entries += 1; continue; }
            if !seen.insert(id.clone()) { report.malformed_window_entries += 1; }
            open.remove(&id);
            peeked.remove(&id);
            let Some(state) = state.as_object().filter(|state| state.len() == 1) else {
                report.malformed_window_entries += 1; continue;
            };
            if let Some(payload) = state.get("expanded") {
                if !payload.is_object() { report.malformed_window_entries += 1; }
                open.insert(id);
            } else if let Some(payload) = state.get("peeked") {
                if !payload.is_object() { report.malformed_window_entries += 1; }
                peeked.insert(id);
            } else { report.malformed_window_entries += 1; }
        }
        if index == 0 { report.peeked_folders = peeked.len(); }
        expanded.push(open);
    }
    for item in workspace.items.values().filter(|item| matches!(item.kind, ItemKind::Folder)) {
        let open = expanded[0].contains(&item.id);
        workspace.folder_collapsed.insert(item.id.clone(), !open);
        report.differing_folder_states += usize::from(expanded.iter().skip(1).any(|ids| ids.contains(&item.id) != open));
    }
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default().as_millis() as u64;
    for (id, date) in window_pairs(&windows[0]["itemLastActiveDates"], report) {
        let Some(item) = workspace.items.get(&id) else { report.unknown_window_ids += 1; continue; };
        if !matches!(item.kind, ItemKind::Tab { .. }) { report.skipped_dates += 1; continue; }
        match arc_date(date, now) {
            Some(at) => { workspace.last_selected.insert(id, at); }
            None => report.skipped_dates += 1,
        }
    }
    Ok(())
}

fn window_pairs<'a>(value: &'a Value, report: &mut ImportReport) -> Vec<(Id, &'a Value)> {
    let Some(list) = value.as_array() else { report.malformed_window_entries += 1; return Vec::new(); };
    report.malformed_window_entries += list.len() % 2;
    list.chunks_exact(2).filter_map(|pair| {
        let Some(id) = pair[0].as_str() else { report.malformed_window_entries += 1; return None; };
        Some((id.to_string(), &pair[1]))
    }).collect()
}

fn arc_date(value: &Value, now: u64) -> Option<u64> {
    let millis = (value.as_f64()? + 978_307_200.0) * 1_000.0;
    (millis.is_finite() && millis >= 0.0 && millis <= now as f64 && millis < u64::MAX as f64)
        .then_some(millis as u64)
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
        favorites: Some(Space::favorites_id(&id)),
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
    let lifecycle = if matches!(kind, ItemKind::Tab { .. }) { Lifecycle::Unloaded } else { Lifecycle::Open };
    Ok(Some(Item {
        membership: Membership {
            parent: obj["parentID"].as_str().map(str::to_string),
            order,
            hlc: Hlc::default(),
            previous_parent: None,
        },
        title: obj["title"].as_str().map(str::to_string),
        kind,
        lifecycle, lifecycle_changed_at: 0, archive: None,
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

// Arc's StorableLinkRouting.json routes links from other apps (a link is checked against the
// routes in order, the first match decides, the rest go to the default).
// Only two shapes refuse the whole file, like the sidebar import: an unreadable version and a
// `rules` key that is neither an array nor absent. Everything else is per rule: an unknown
// style, an unknown or profile destination, a malformed entry or a repeated id drops that one
// rule and is counted, the way unmodelled kinds are counted there.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct LinkRoutingReport {
    pub imported_rules: usize,
    pub skipped_profile_destinations: usize,
    pub skipped_unknown_destinations: usize,
    pub skipped_unknown_styles: usize,
    pub malformed_rules: usize,
}

// `owner` is the profile the caller vouches owns this routing file: the rules and Little
// windows it produces belong to it, and a space destination must name a space that profile
// carries — a space of another profile is skipped like an unknown one. With no owner named,
// the first space's profile stands in and existence alone decides; every rule is then
// stamped with the profile of the space its destination names (the first space's for Most
// Recent and Little window rules), so no written rule carries a destination that route()
// would refuse.
pub fn arc_link_routing(json: &str, owner: Option<Profile>, spaces: &[(Id, Profile)]) -> Result<(Routing, LinkRoutingReport)> {
    let root: Value = serde_json::from_str(json).map_err(|e| ImportError(e.to_string()))?;
    // The version gates the whole mapping: shapes may change under a new version, so refuse
    // rather than mis-read; a missing version is not 1 either.
    let version = &root["version"];
    if version.is_null() { return Err(err("StorableLinkRouting has no version")); }
    let Some(major) = version.as_i64() else {
        return Err(ImportError(format!("StorableLinkRouting version {version} is not supported")));
    };
    if major != 1 {
        return Err(ImportError(format!("StorableLinkRouting version {major} is not supported")));
    }

    let profile = owner.clone()
        .or_else(|| spaces.first().map(|(_, profile)| profile.clone()))
        .unwrap_or(Profile::Default);
    let known: HashMap<Id, Profile> = spaces.iter().map(|(id, profile)| (id.clone(), profile.clone())).collect();

    let mut report = LinkRoutingReport::default();
    let mut rules = Vec::new();
    let mut seen_ids = HashSet::new();
    let none: Vec<Value> = Vec::new();
    let entries = match root["rules"].as_array() {
        Some(entries) => entries,
        None if root["rules"].is_null() => &none,
        None => return Err(err("rules is not an array")),
    };
    'entry: for entry in entries {
        let Some(obj) = entry.as_object() else { report.malformed_rules += 1; continue };
        // Rules have Arc's string ids; a rule always has an id, so one without is unreadable.
        let Some(id) = obj.get("id").and_then(Value::as_str) else { report.malformed_rules += 1; continue };
        // A repeated id would make edit and delete ambiguous, so the first entry wins and the
        // rest are counted like other unreadable rules.
        if !seen_ids.insert(id.to_string()) { report.malformed_rules += 1; continue 'entry; }
        let Some(components) = obj["sourceComponents"].as_array() else {
            report.malformed_rules += 1; continue;
        };
        let mut conditions = Vec::new();
        for component in components {
            match url_condition(component) {
                Ok(condition) => conditions.push(condition),
                // The reason a rule is dropped is counted once for the rule, so counters add
                // up to the rules the import produced.
                Err(Skip::UnknownStyle) => { report.skipped_unknown_styles += 1; continue 'entry; }
                Err(Skip::Malformed) => { report.malformed_rules += 1; continue 'entry; }
            }
        }
        match arc_destination(&obj["destination"], &profile, &known, owner.is_some()) {
            DestinationOr::Keep(destination) => {
                // A written rule must carry no destination route() would refuse: with an
                // owner the space kept already rides in it, and with none the space's own
                // profile has to stand in — keeping the first space's for a cross-profile
                // space would send the link away from the space the file named.
                let stamped = match &destination {
                    Destination::Space(SpaceTarget::Space(id)) =>
                        known.get(id).cloned().unwrap_or_else(|| profile.clone()),
                    _ => profile.clone(),
                };
                rules.push(Rule { id: id.into(), conditions, destination, profile: stamped });
                report.imported_rules += 1;
            }
            // A rule with no destination has nowhere to route.
            DestinationOr::Absent | DestinationOr::SkipUnknown => report.skipped_unknown_destinations += 1,
            DestinationOr::SkipProfile => report.skipped_profile_destinations += 1,
        }
    }

    let mut routing = Routing { rules, default: Routing::default().default };
    match arc_destination(&root["defaultDestination"], &profile, &known, owner.is_some()) {
        DestinationOr::Keep(destination) => routing.default = destination,
        // The file has no default destination: keep ours, and count only what it cannot read.
        DestinationOr::Absent => {},
        DestinationOr::SkipUnknown => report.skipped_unknown_destinations += 1,
        DestinationOr::SkipProfile => report.skipped_profile_destinations += 1,
    }
    Ok((routing, report))
}

enum Skip { UnknownStyle, Malformed }

// One sourceComponent: `componentType.urlMatch` is `{_0: {contains: {}} | {matches: {}}, _1: text}`.
// Arc's editor offers only these two styles.
fn url_condition(component: &Value) -> std::result::Result<UrlCondition, Skip> {
    let Some(url_match) = component["componentType"]["urlMatch"].as_object() else {
        return Err(Skip::Malformed);
    };
    let Some(style) = url_match.get("_0") else { return Err(Skip::Malformed); };
    let Some(style) = style.as_object() else { return Err(Skip::Malformed); };
    let style = if style.contains_key("matches") { MatchStyle::Equals }
        else if style.contains_key("contains") { MatchStyle::Contains }
        else { return Err(Skip::UnknownStyle) };
    let Some(text) = url_match.get("_1").and_then(Value::as_str) else {
        return Err(Skip::Malformed);
    };
    let mut condition = UrlCondition { style, text: text.to_string() };
    condition.strip_controls();
    Ok(condition)
}

enum DestinationOr { Keep(Destination), SkipProfile, SkipUnknown, Absent }

// A ProfileDestination sits in the `_0` slot of a space/littleArc destination: `{"mostRecent": {}}`,
// `{"profile": ...}` (skipped+counted), or a space id, which may be the string itself or a
// string anywhere inside (fixture assumption; a space id is recognised by its id anywhere inside
// `space`).
enum Target { MostRecent, Space(Id), Profile, Unknown }

// A ProfileDestination sits in the `_0` slot of a space/littleArc destination: `{"mostRecent": {}}`,
// `{"profile": ...}` (skipped+counted), or a space id. The id is taken from `space` as its one
// string — the string itself, or one nested inside — and `arc_link_routing` then requires it to
// be exactly a sidebar space id; the fixture assumption is the same `_0` slot the owner's file
// carries for most-recent.
fn destination_target(value: Option<&Value>) -> Target {
    let Some(value) = value else { return Target::Unknown };
    if let Some(id) = value.as_str() { return Target::Space(id.into()); }
    let Some(obj) = value.as_object() else { return Target::Unknown };
    if obj.contains_key("profile") { return Target::Profile; }
    if let Some(space) = obj.get("space") {
        let Some(id) = first_string(space) else { return Target::Unknown };
        return Target::Space(id);
    }
    if obj.contains_key("mostRecent") { return Target::MostRecent; }
    Target::Unknown
}

// A LinkDestination is `space(ProfileDestination)` or `littleArc(ProfileDestination)`.
// The profile case cannot be imported: count it and leave the rule out.
// `spaces` carries the profile each usable id rides in; `profiled` is whether the file's
// owner is known — without one, only existence decides.
fn arc_destination(value: &Value, profile: &Profile, spaces: &HashMap<Id, Profile>, profiled: bool) -> DestinationOr {
    if value.is_null() { return DestinationOr::Absent; } // No default in the file at all.
    let Some(map) = value.as_object() else { return DestinationOr::SkipUnknown };
    if let Some(body) = map.get("littleArc") {
        // littleArc ignores the inner target: a Little Arc given a space still opened with
        // "Open in <most recent space>", so everything except a
        // profile destination becomes the import's profile in the Little window.
        return match destination_target(body.get("_0")) {
            Target::Profile => DestinationOr::SkipProfile,
            Target::Unknown => DestinationOr::SkipUnknown,
            _ => DestinationOr::Keep(Destination::LittleWindow(profile.clone())),
        };
    }
    if let Some(body) = map.get("space") {
        return match destination_target(body.get("_0")) {
            Target::MostRecent => DestinationOr::Keep(Destination::Space(SpaceTarget::MostRecent)),
            // A rule can only open a space the workspace has in the profile its rules ride
            // in, so an id that is not one of the sidebar's spaces — or one of them in
            // another profile — is skipped and counted instead of routing into nothing.
            Target::Space(id) => match spaces.get(&id) {
                Some(space_profile) if !profiled || space_profile == profile =>
                    DestinationOr::Keep(Destination::Space(SpaceTarget::Space(id))),
                _ => DestinationOr::SkipUnknown,
            },
            Target::Profile => DestinationOr::SkipProfile,
            Target::Unknown => DestinationOr::SkipUnknown,
        };
    }
    DestinationOr::SkipUnknown
}

#[cfg(test)]
mod tests {
    use super::arc_date;
    use serde_json::json;

    #[test]
    fn date_bounds_are_inclusive_and_future_milliseconds_are_rejected() {
        let now = 978_307_201_000;
        assert_eq!(arc_date(&json!(0.0), now), Some(978_307_200_000));
        assert_eq!(arc_date(&json!(1.0), now), Some(now));
        assert_eq!(arc_date(&json!(1.001), now), None);
    }
}
