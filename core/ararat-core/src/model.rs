use std::collections::HashMap;

use serde::{Deserialize, Serialize};

pub type Id = String;

#[derive(Debug, Default, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Profile {
    #[default]
    Default,
    Named(String),
}

// Spaces carry an order key for the same reason items do: a stored space list would be a second
// copy of the order that sync could merge into duplicates.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Space {
    pub id: Id,
    pub order: String,
    pub title: String,
    pub profile: Profile,
    pub icon: Option<String>,
    #[serde(default)]
    pub look: Option<Look>,
    pub pinned: Id,
    pub today: Id,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Appearance { Auto, Light, Dark }

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LookColor {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Look {
    pub colors: Vec<LookColor>,
    pub opacity: f64,
    pub grain: f64,
    pub glass: bool,
    pub appearance: Appearance,
}

impl Look {
    pub fn is_valid(&self) -> bool {
        (1..=3).contains(&self.colors.len()) && self.colors.iter().all(|c|
            [c.red, c.green, c.blue, c.x, c.y].into_iter().all(|v| (0.0..=1.0).contains(&v)))
            && [self.opacity, self.grain].into_iter().all(|v| (0.0..=1.0).contains(&v))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Orientation {
    Horizontal,
    Vertical,
}

// Which side of the focused pane a new pane joins (Add Left/Right Split), and which side the
// dragged row takes when a drop on a page half makes the split. Left and right are the row's
// order: a split is horizontal here (Move Left/Right is the axis's menu title).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SplitSide {
    Left,
    Right,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ItemKind {
    Container,
    Tab { url: String, saved_title: Option<String> },
    Folder,
    Split { orientation: Orientation, width_factors: Vec<(Id, f64)> },
}

// Child lists are not stored: two independently merged child lists can put one item in two
// places, or in none (architecture 6.1).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Membership {
    pub parent: Option<Id>,
    pub order: String,
    pub hlc: Hlc,
    // Where the last move took the item from; tree repair undoes a losing move with it.
    pub previous_parent: Option<Id>,
}

// shortcut: `node` is a free string and nothing advances the clock yet; phase 8 gives each
// device an id and ticks the clock on every local write.
#[derive(Debug, Clone, Default, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct Hlc {
    pub millis: u64,
    pub counter: u32,
    pub node: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Lifecycle {
    Open,
    Unloaded,
    Closed,
    Archived,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Item {
    pub id: Id,
    pub membership: Membership,
    pub title: Option<String>,
    pub kind: ItemKind,
    pub lifecycle: Lifecycle,
    pub lifecycle_changed_at: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WindowState {
    pub id: Id,
    pub shown_space: Option<Id>,
    pub selected: Option<Id>,
    pub history: Vec<Id>,
    #[serde(default)]
    pub space_history: Vec<Id>,
    // Why the field: the kept-records query orders launch and reopen adoption by it, so
    // every write of the record stamps its instant (shown-space change, selection,
    // creation). `default` reads records stored before the field existed.
    #[serde(default)]
    pub changed_at: u64,
    #[serde(default)]
    pub frame: Option<LittleWindowFrame>,
    #[serde(default)]
    pub sidebar_width: Option<f64>,
    #[serde(default)]
    pub sidebar_hidden: bool,
    #[serde(default)]
    pub sidebar_floating: bool,
}

/// The Little Window's frame on this device (U27h D8). The Open-in default and close-after
/// are synced settings; the frame is per device, like a `Window` record, so it is stored in
/// its own kind and kept out of the sync journal.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct LittleWindowFrame {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// U27i D8/O3: the Little Window's global shortcut on this device. Carbon registers a virtual
/// key code, so the record keeps the code the registrar uses beside the combination its keycaps
/// show. It stays on the device: a shortcut registered on one Mac must not make another Mac's
/// registration fail.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LittleWindowHotKey {
    pub key_code: u16,
    pub combination: crate::key_bindings::KeyCombination,
}

impl LittleWindowHotKey {
    /// ⌥⌘N, the board's default (key code 45 is N on the ANSI layout).
    pub fn default_shortcut() -> Self {
        Self { key_code: 45, combination: crate::key_bindings::KeyCombination {
            key: "n".into(), command: true, control: false, option: true, shift: false } }
    }
}

/// U27i D8: the Little Window's per-device switches, stored beside its frame and kept out of
/// the sync journal. `None` for the shortcut is the user's own "no global shortcut"; no record
/// at all is the built-in state (remember on, ⌥⌘N). Unlike the pre-existing `Settings` record,
/// this kind is new in this unit and always written whole, so it carries no serde defaults.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LittleWindowDevice {
    pub remember_frame: bool,
    pub hot_key: Option<LittleWindowHotKey>,
}

impl Default for LittleWindowDevice {
    fn default() -> Self {
        Self { remember_frame: true, hot_key: Some(LittleWindowHotKey::default_shortcut()) }
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Workspace {
    pub(crate) off_the_record: bool,
    pub key_binding_overrides: HashMap<String, Option<crate::key_bindings::KeyCombination>>,
    pub folder_collapsed: HashMap<Id, bool>,
    // The pinned section's collapsed state is per space but stays on the device, like
    // FolderState: collapsing on one Mac does not collapse another. The core reads it to
    // keep the current pin's row visible (outline_keeping) the way it does for a collapsed
    // folder.
    pub section_collapsed: HashMap<Id, bool>,
    // The workspace's own preferences (D5), one record that syncs.
    pub settings: Settings,
    pub archive_after: HashMap<Profile, ArchiveAfter>,
    pub last_selected: HashMap<Id, u64>,
    pub windows: HashMap<Id, WindowState>,
    // The Little Window's remembered frame, per device (U27h D8).
    pub little_window_frame: Option<LittleWindowFrame>,
    // The Little Window's per-device switches (U27i D8): whether this Mac remembers the frame
    // and which global shortcut it registers.
    pub little_window_device: LittleWindowDevice,
    pub history_purges: HashMap<Id, (Profile, Id, u64)>,
    pub history_profiles: HashMap<Id, Profile>,
    pub spaces: Vec<Space>,
    pub favorites: HashMap<Profile, Id>,
    pub items: HashMap<Id, Item>,
    // Where links from other apps go, synced with the workspace (architecture 8.4): one record
    // per rule (topic.8.3 merges per record), and the default destination when it differs from
    // the built-in one.
    pub routing_rules: HashMap<Id, crate::routing::StoredRule>,
    pub routing_default: crate::routing::Destination,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    KeyBinding,
    Space,
    Item,
    Favorites,
    Window,
    LittleWindow,
    LittleWindowDevice,
    ArchiveAfter,
    LastSelected,
    FolderState,
    SectionState,
    Settings,
    RoutingRule,
    RoutingDefault,
    HistoryPurge,
    HistoryProfile,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::KeyBinding => "key_binding",
            Kind::Space => "space",
            Kind::Item => "item",
            Kind::Favorites => "favorites",
            Kind::Window => "window",
            Kind::LittleWindow => "little_window",
            Kind::LittleWindowDevice => "little_window_device",
            Kind::ArchiveAfter => "archive_after",
            Kind::LastSelected => "last_selected",
            Kind::FolderState => "folder_state",
            Kind::SectionState => "section_state",
            Kind::Settings => "settings",
            Kind::RoutingRule => "routing_rule",
            Kind::RoutingDefault => "routing_default",
            Kind::HistoryPurge => "history_purge",
            Kind::HistoryProfile => "history_profile",
        }
    }

    pub fn parse(s: &str) -> Option<Kind> {
        [Kind::KeyBinding, Kind::Space, Kind::Item, Kind::Favorites, Kind::Window, Kind::LittleWindow, Kind::LittleWindowDevice, Kind::ArchiveAfter, Kind::LastSelected, Kind::FolderState, Kind::SectionState, Kind::Settings, Kind::RoutingRule, Kind::RoutingDefault, Kind::HistoryPurge, Kind::HistoryProfile].into_iter().find(|k| k.as_str() == s)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Record {
    KeyBinding { command: String, key: Option<crate::key_bindings::KeyCombination> },
    FolderState { item: Id, collapsed: bool },
    SectionState { space: Id, collapsed: bool },
    Settings(Settings),
    ArchiveAfter { profile: Profile, value: ArchiveAfter },
    LastSelected { item: Id, at: u64 },
    Space(Space),
    Item(Item),
    Window(WindowState),
    LittleWindow(LittleWindowFrame),
    LittleWindowDevice(LittleWindowDevice),
    Favorites { profile: Profile, container: Id },
    RoutingRule { order: String, rule: crate::routing::Rule },
    RoutingDefault { destination: crate::routing::Destination },
    HistoryPurge { id: Id, profile: Profile, item: Id, changed_at: u64 },
    HistoryProfile { item: Id, profile: Profile },
}

impl Record {
    pub fn kind(&self) -> Kind {
        match self {
            Record::KeyBinding { .. } => Kind::KeyBinding,
            Record::ArchiveAfter { .. } => Kind::ArchiveAfter,
            Record::LastSelected { .. } => Kind::LastSelected,
            Record::FolderState { .. } => Kind::FolderState,
            Record::SectionState { .. } => Kind::SectionState,
            Record::Settings(_) => Kind::Settings,
            Record::Space(_) => Kind::Space,
            Record::Window(_) => Kind::Window,
            Record::LittleWindow(_) => Kind::LittleWindow,
            Record::LittleWindowDevice(_) => Kind::LittleWindowDevice,
            Record::Item(_) => Kind::Item,
            Record::Favorites { .. } => Kind::Favorites,
            Record::RoutingRule { .. } => Kind::RoutingRule,
            Record::RoutingDefault { .. } => Kind::RoutingDefault,
            Record::HistoryPurge { .. } => Kind::HistoryPurge,
            Record::HistoryProfile { .. } => Kind::HistoryProfile,
        }
    }

    pub fn id(&self) -> Id {
        match self {
            Record::KeyBinding { command, .. } => command.clone(),
            Record::ArchiveAfter { profile, .. } => profile_id(profile),
            Record::LastSelected { item, .. } => item.clone(),
            Record::FolderState { item, .. } => item.clone(),
            Record::SectionState { space, .. } => space.clone(),
            Record::Settings(_) => "workspace".into(),
            Record::Space(s) => s.id.clone(),
            Record::Window(window) => window.id.clone(),
            Record::LittleWindow(_) => "workspace".into(),
            Record::LittleWindowDevice(_) => "workspace".into(),
            Record::Item(i) => i.id.clone(),
            Record::Favorites { profile, .. } => profile_id(profile),
            Record::RoutingRule { rule, .. } => rule.id.clone(),
            Record::RoutingDefault { .. } => "workspace".into(),
            Record::HistoryPurge { id, .. } => id.clone(),
            Record::HistoryProfile { item, .. } => item.clone(),
        }
    }

    pub fn body(&self) -> String {
        match self {
            Record::KeyBinding { key, .. } => serde_json::to_string(key),
            Record::ArchiveAfter { value, .. } => serde_json::to_string(value),
            Record::LastSelected { at, .. } => serde_json::to_string(at),
            Record::FolderState { collapsed, .. } => serde_json::to_string(collapsed),
            Record::SectionState { collapsed, .. } => serde_json::to_string(collapsed),
            Record::Settings(settings) => serde_json::to_string(settings),
            Record::Space(s) => serde_json::to_string(s),
            Record::Window(window) => serde_json::to_string(window),
            Record::LittleWindow(frame) => serde_json::to_string(frame),
            Record::LittleWindowDevice(device) => serde_json::to_string(device),
            Record::Item(i) => serde_json::to_string(i),
            Record::Favorites { container, .. } => serde_json::to_string(container),
            Record::RoutingRule { order, rule } => serde_json::to_string(&crate::routing::StoredRuleBody {
                order: order.clone(), conditions: rule.conditions.clone(), destination: rule.destination.clone(),
                profile: rule.profile.clone() }),
            Record::RoutingDefault { destination } => serde_json::to_string(destination),
            Record::HistoryPurge { profile, item, changed_at, .. } => serde_json::to_string(&(profile, item, changed_at)),
            Record::HistoryProfile { profile, .. } => serde_json::to_string(profile),
        }
        .expect("model types serialise")
    }

    pub fn parse(kind: Kind, id: &str, body: &str) -> serde_json::Result<Record> {
        Ok(match kind {
            Kind::KeyBinding => Record::KeyBinding { command: id.into(), key: serde_json::from_str(body)? },
            Kind::FolderState => Record::FolderState { item: id.into(), collapsed: serde_json::from_str(body)? },
            Kind::SectionState => Record::SectionState { space: id.into(), collapsed: serde_json::from_str(body)? },
            Kind::Settings => Record::Settings(serde_json::from_str(body)?),
            Kind::LastSelected => Record::LastSelected { item: id.into(), at: serde_json::from_str(body)? },
            Kind::ArchiveAfter => Record::ArchiveAfter { profile: serde_json::from_str(id)?, value: serde_json::from_str(body)? },
            Kind::Space => Record::Space(serde_json::from_str(body)?),
            Kind::Window => Record::Window(serde_json::from_str(body)?),
            Kind::LittleWindow => Record::LittleWindow(serde_json::from_str(body)?),
            Kind::LittleWindowDevice => Record::LittleWindowDevice(serde_json::from_str(body)?),
            Kind::Item => Record::Item(serde_json::from_str(body)?),
            Kind::Favorites => Record::Favorites {
                profile: serde_json::from_str(id)?,
                container: serde_json::from_str(body)?,
            },
            Kind::RoutingRule => {
                let stored: crate::routing::StoredRuleBody = serde_json::from_str(body)?;
                Record::RoutingRule {
                    order: stored.order,
                    rule: crate::routing::Rule {
                        id: id.into(), conditions: stored.conditions, destination: stored.destination,
                        profile: stored.profile,
                    },
                }
            }
            Kind::RoutingDefault => Record::RoutingDefault { destination: serde_json::from_str(body)? },
            Kind::HistoryPurge => {
                let (profile, item, changed_at) = serde_json::from_str(body)?;
                Record::HistoryPurge { id: id.into(), profile, item, changed_at }
            },
            Kind::HistoryProfile => Record::HistoryProfile { item: id.into(), profile: serde_json::from_str(body)? },
        })
    }
}

pub fn profile_id(profile: &Profile) -> Id {
    serde_json::to_string(profile).expect("profiles serialise")
}

// One change type for memory and disk, so the stored workspace cannot drift from the live one.
#[derive(Debug, Clone, PartialEq)]
pub enum Op {
    Put(Record),
    Delete(Kind, Id),
}

impl Workspace {
    pub fn is_private(&self) -> bool { self.off_the_record }

    pub fn private(profile: Profile) -> Self {
        let mut workspace = Self::default();
        workspace.create_space("", "Private", "private").expect("private space");
        workspace.windows.clear();
        workspace.spaces[0].profile = profile;
        workspace.off_the_record = true;
        workspace
    }

    // Ties fall back to the id, not to map order, so every device derives the same list.
    pub fn children(&self, parent: &str) -> Vec<&Item> {
        let mut children: Vec<_> = self
            .items
            .values()
            .filter(|item| item.membership.parent.as_deref() == Some(parent))
            .collect();
        children.sort_by(|a, b| {
            (&a.membership.order, &a.id).cmp(&(&b.membership.order, &b.id))
        });
        children
    }

    pub fn outline(&self, container: &str) -> Vec<(usize, &Item)> {
        self.outline_entries(container).into_iter().filter(|(_, _, visible)| *visible)
            .map(|(depth, item, _)| (depth, item)).collect()
    }

    // The rows a sidebar draws for a container, with the window's current row kept in view:
    // a collapsed folder and a collapsed pinned section both hold their children back, but
    // the row the window is on stays (the one holder rule, D1). A row kept only by that path
    // holds its own children back too, so an open folder on the path shows the pin it holds
    // and nothing else; a split shows all its members, since the current row may be one of
    // them. Editing reads outline_entries instead — a collapse is a display state and never
    // hides an item from an edit.
    pub fn outline_keeping(&self, container: &str, current: Option<&str>) -> Vec<(usize, &Item)> {
        self.outline_entries_keeping(container, current).into_iter().filter(|(_, _, visible)| *visible)
            .map(|(depth, item, _)| (depth, item)).collect()
    }

    fn outline_entries_keeping(&self, container: &str, current: Option<&str>) -> Vec<(usize, &Item, bool)> {
        let keep = self.holder_path(container, current);
        let section_hidden = self.section_hidden(container);
        let mut rows = Vec::new();
        let mut stack: Vec<_> = self.children(container).into_iter().rev()
            .map(|item| (0, item, !section_hidden || keep.contains(&item.id), section_hidden)).collect();
        while let Some((depth, item, parent_visible, held)) = stack.pop() {
            let visible = parent_visible && matches!(item.lifecycle, Lifecycle::Open | Lifecycle::Unloaded)
                && (!matches!(item.kind, ItemKind::Split { .. }) || self.has_open_tab(&item.id));
            rows.push((depth, item, visible));
            let collapsed = self.folder_collapsed.get(&item.id).copied().unwrap_or(false);
            let held = held && !matches!(item.kind, ItemKind::Split { .. });
            let children_held = collapsed || held;
            stack.extend(self.children(&item.id).into_iter().rev()
                .map(|child| (depth + 1, child, visible && (!children_held || keep.contains(&child.id)), children_held)));
        }
        rows
    }

    // The ids from the current row up to the container it sits in; empty when the row is in
    // another list, so only its own path survives a collapsed holder.
    fn holder_path(&self, container: &str, current: Option<&str>) -> std::collections::HashSet<Id> {
        let mut path = std::collections::HashSet::new();
        let mut id = current;
        for _ in 0..self.items.len() {
            let Some(item) = id.and_then(|id| self.items.get(id)) else { return std::collections::HashSet::new() };
            if item.membership.parent.as_deref() == Some(container) {
                path.insert(item.id.clone());
                return path;
            }
            if item.membership.parent.is_none() { return std::collections::HashSet::new(); }
            path.insert(item.id.clone());
            id = item.membership.parent.as_deref();
        }
        std::collections::HashSet::new()
    }

    // A space's pinned section, keyed by the space the record names; favourites have none.
    fn section_hidden(&self, container: &str) -> bool {
        self.spaces.iter().find(|space| space.pinned == container)
            .is_some_and(|space| self.section_collapsed.get(&space.id).copied().unwrap_or(false))
    }

    pub(crate) fn outline_entries(&self, container: &str) -> Vec<(usize, &Item, bool)> {
        let mut rows = Vec::new();
        let mut stack: Vec<_> = self.children(container).into_iter().rev().map(|i| (0, i, true)).collect();
        while let Some((depth, item, parent_visible)) = stack.pop() {
            let visible = parent_visible && matches!(item.lifecycle, Lifecycle::Open | Lifecycle::Unloaded)
                && (!matches!(item.kind, ItemKind::Split { .. }) || self.has_open_tab(&item.id));
            rows.push((depth, item, visible));
            stack.extend(self.children(&item.id).into_iter().rev()
                .map(|c| (depth + 1, c, visible && !self.folder_collapsed.get(&item.id).copied().unwrap_or(false))));
        }
        rows
    }

    pub(crate) fn has_open_tab(&self, parent: &str) -> bool {
        let mut stack = self.children(parent);
        while let Some(item) = stack.pop() {
            if !matches!(item.lifecycle, Lifecycle::Open | Lifecycle::Unloaded) { continue }
            if matches!(item.kind, ItemKind::Tab { .. }) { return true }
            stack.extend(self.children(&item.id));
        }
        false
    }

    pub fn apply(&mut self, op: &Op) {
        match op {
            Op::Put(Record::KeyBinding { command, key }) => { self.key_binding_overrides.insert(command.clone(), key.clone()); },
            Op::Delete(Kind::KeyBinding, id) => { self.key_binding_overrides.remove(id); },
            Op::Put(Record::FolderState { item, collapsed }) => { self.folder_collapsed.insert(item.clone(), *collapsed); },
            Op::Delete(Kind::FolderState, id) => { self.folder_collapsed.remove(id); },
            Op::Put(Record::SectionState { space, collapsed }) => { self.section_collapsed.insert(space.clone(), *collapsed); },
            Op::Delete(Kind::SectionState, id) => { self.section_collapsed.remove(id); },
            Op::Put(Record::Settings(settings)) => { self.settings = settings.clone(); },
            // Like the routing default: a tombstone resets the workspace to the built-in
            // value, so a synced reset is a delete rather than a row restating the default.
            Op::Delete(Kind::Settings, _) => { self.settings = Settings::default(); },
            Op::Put(Record::LastSelected { item, at }) => { self.last_selected.insert(item.clone(), *at); },
            Op::Delete(Kind::LastSelected, id) => { self.last_selected.remove(id); },
            Op::Put(Record::ArchiveAfter { profile, value }) => { self.archive_after.insert(profile.clone(), *value); },
            Op::Delete(Kind::ArchiveAfter, id) => self.archive_after.retain(|p, _| &profile_id(p) != id),
            Op::Put(Record::Window(window)) => { let mut window = window.clone(); if self.is_private() { window.history.clear(); window.space_history.clear(); } self.windows.insert(window.id.clone(), window); },
            Op::Delete(Kind::Window, id) => { self.windows.remove(id); },
            Op::Put(Record::LittleWindow(frame)) => { self.little_window_frame = Some(*frame); },
            Op::Delete(Kind::LittleWindow, _) => { self.little_window_frame = None; },
            Op::Put(Record::LittleWindowDevice(device)) => { self.little_window_device = device.clone(); },
            Op::Delete(Kind::LittleWindowDevice, _) => { self.little_window_device = LittleWindowDevice::default(); },
            Op::Put(Record::Space(space)) => {
                self.spaces.retain(|s| s.id != space.id);
                self.spaces.push(space.clone());
                self.spaces.sort_by(|a, b| (&a.order, &a.id).cmp(&(&b.order, &b.id)));
            }
            Op::Put(Record::Item(item)) => {
                self.items.insert(item.id.clone(), item.clone());
            }
            Op::Put(Record::Favorites { profile, container }) => {
                self.favorites.insert(profile.clone(), container.clone());
            }
            Op::Delete(Kind::Space, id) => self.spaces.retain(|s| &s.id != id),
            Op::Delete(Kind::Item, id) => {
                self.items.remove(id);
            }
            Op::Delete(Kind::Favorites, id) => self.favorites.retain(|p, _| &profile_id(p) != id),
            Op::Put(Record::RoutingRule { order, rule }) => {
                self.routing_rules.insert(rule.id.clone(), crate::routing::StoredRule { order: order.clone(), rule: rule.clone() });
            },
            Op::Delete(Kind::RoutingRule, id) => { self.routing_rules.remove(id); },
            Op::Put(Record::RoutingDefault { destination }) => { self.routing_default = destination.clone(); },
            // Default records changed since the last sync: a tombstone resets ours to the
            // built-in default the same way rule deletes remove their rule.
            Op::Delete(Kind::RoutingDefault, _) => { self.routing_default = crate::routing::Destination::default(); },
            Op::Put(Record::HistoryPurge { id, profile, item, changed_at }) => { self.history_purges.insert(id.clone(), (profile.clone(), item.clone(), *changed_at)); },
            Op::Delete(Kind::HistoryPurge, id) => { self.history_purges.remove(id); },
            Op::Put(Record::HistoryProfile { item, profile }) => { self.history_profiles.insert(item.clone(), profile.clone()); },
            Op::Delete(Kind::HistoryProfile, id) => { self.history_profiles.remove(id); },
        }
    }

    pub fn to_ops(&self) -> Vec<Op> {
        let spaces = self.spaces.iter().map(|s| Record::Space(s.clone()));
        let favorites = self
            .favorites
            .iter()
            .map(|(p, c)| Record::Favorites { profile: p.clone(), container: c.clone() });
        let items = self.items.values().map(|i| Record::Item(i.clone()));
        let rules = self.routing_rules.values().map(|s| Record::RoutingRule { order: s.order.clone(), rule: s.rule.clone() });
        // The built-in default is derived, never stored: records carry a change from it only
        // (Workspace::default().to_ops() stays empty).
        let default = (self.routing_default != crate::routing::Destination::default())
            .then(|| Record::RoutingDefault { destination: self.routing_default.clone() });
        let purges = self.history_purges.iter().map(|(id, (profile, item, changed_at))| Record::HistoryPurge { id: id.clone(), profile: profile.clone(), item: item.clone(), changed_at: *changed_at });
        let history_profiles = self.history_profiles.iter().map(|(item, profile)| Record::HistoryProfile { item: item.clone(), profile: profile.clone() });
        spaces.chain(favorites).chain(items).chain(self.key_binding_overrides.iter().map(|(command, key)| Record::KeyBinding { command: command.clone(), key: key.clone() })).chain(self.folder_collapsed.iter().map(|(item, collapsed)| Record::FolderState { item: item.clone(), collapsed: *collapsed })).chain(self.section_collapsed.iter().map(|(space, collapsed)| Record::SectionState { space: space.clone(), collapsed: *collapsed })).chain((self.settings != Settings::default()).then(|| Record::Settings(self.settings.clone()))).chain(self.archive_after.iter().map(|(p, v)| Record::ArchiveAfter { profile: p.clone(), value: *v })).chain(self.last_selected.iter().map(|(item, at)| Record::LastSelected { item: item.clone(), at: *at })).chain(self.windows.values().cloned().map(Record::Window)).chain(self.little_window_frame.map(Record::LittleWindow)).chain((self.little_window_device != LittleWindowDevice::default()).then(|| Record::LittleWindowDevice(self.little_window_device.clone()))).chain(rules).chain(default.into_iter()).chain(purges).chain(history_profiles)
            .map(Op::Put).collect()
    }

    // Rules in the order matching reads them: by order key, ties by id, the same derived order
    // children() gives items, so the same records give every device the same rule order.
    pub fn routing(&self) -> crate::routing::Routing {
        let mut rules: Vec<&crate::routing::StoredRule> = self.routing_rules.values().collect();
        rules.sort_by(|a, b| (&a.order, &a.rule.id).cmp(&(&b.order, &b.rule.id)));
        crate::routing::Routing {
            rules: rules.into_iter().map(|s| s.rule.clone()).collect(),
            default: self.routing_default.clone(),
        }
    }

    // Recency reads the device's own selection record, never a synced time: derived from
    // the same records, every device reads the same order without the times moving.
    pub fn routing_spaces(&self) -> crate::routing::Spaces {
        use crate::routing::Spaces;
        let mut newest: HashMap<&Id, u64> = HashMap::new();
        for (id, at) in &self.last_selected {
            if let Some(space) = self.space_of(id) {
                let rank = newest.entry(&space.id).or_insert(0);
                *rank = (*rank).max(*at);
            }
        }
        let mut ranked: Vec<&Space> = self.spaces.iter().collect();
        ranked.sort_by_key(|space| std::cmp::Reverse(newest.get(&space.id).copied()));
        Spaces {
            entries: self.spaces.iter().map(|s| (s.id.clone(), s.profile.clone())).collect(),
            recency: ranked.into_iter().map(|s| s.id.clone()).collect(),
        }
    }

    // Favorites are excluded: they belong to a profile, so no space of their own; the chain
    // has no cycle the tree checks do not surface.
    fn space_of(&self, id: &str) -> Option<&Space> {
        let (root, _) = self.list_for(id)?;
        self.spaces.iter().find(|space| &space.pinned == root || &space.today == root)
    }

    // The pane's "Deleted space" menus read the core's one answer, not a Swift-side compare.
    pub fn deleted_space_destinations(&self) -> Vec<crate::routing::DeletedDestination> {
        let mut gone = Vec::new();
        for rule in self.routing().rules {
            if let crate::routing::Destination::Space(crate::routing::SpaceTarget::Space(ref id)) = rule.destination {
                if !self.spaces.iter().any(|s| &s.id == id) {
                    gone.push(crate::routing::DeletedDestination { rule_id: Some(rule.id.clone()), space_id: id.clone() });
                }
            }
        }
        if let crate::routing::Destination::Space(crate::routing::SpaceTarget::Space(ref id)) = self.routing_default {
            if !self.spaces.iter().any(|s| &s.id == id) {
                gone.push(crate::routing::DeletedDestination { rule_id: None, space_id: id.clone() });
            }
        }
        gone
    }
}

impl Item {
    pub fn display_title(&self) -> &str {
        if let Some(title) = &self.title {
            return title;
        }
        match &self.kind {
            ItemKind::Tab { saved_title: Some(t), .. } => t,
            ItemKind::Tab { url, .. } => url,
            _ => "",
        }
    }
}

// Arc's four choices and default: https://resources.arc.net/hc/en-us/articles/19228855311127
// Option list: https://browserinc.notion.site/Archive-2813ff2c5e5f4ba8a71f07c39a4892f0
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum ArchiveAfter { #[default] Hours12, Hours24, Days7, Days30 }
impl ArchiveAfter {
    pub fn millis(self) -> u64 { (match self { Self::Hours12 => 12, Self::Hours24 => 24, Self::Days7 => 168, Self::Days30 => 720 }) * 3_600_000 }
}

// The sideways scroll that pages spaces (D3, architecture §7): Natural is Arc's behaviour as
// built (the wheel cancels the system's natural-scrolling inversion, a trackpad gesture keeps
// its sign); Reversed turns the final paging direction around for every device. It is one
// setting, not one per input device.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum SpaceScrollDirection { #[default] Natural, Reversed }

// The window's theme (U27k, D5): System follows the Mac's appearance, Light and Dark force one
// for every window. A space's Look still colours only the sidebar; a Look whose mode is Auto
// follows the appearance this setting resolves to.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum Theme { #[default] System, Light, Dark }

// U27w W1: the seven per-permission defaults, one value each. Ask, Allow and Block are
// Chromium's three uniform values. Which of them a kind takes as a *default* differs, so
// `SiteDefaults::invalid` enforces the per-kind set at parse and at the FFI write: pop-ups and
// sound take no Ask (`content_settings_registry.cc:138,265` in Chromium 157) and the camera and
// microphone take no Allow as a default (`content_settings_info.cc:50-55`), while their site
// exceptions still do.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum SitePermissionValue { #[default] Ask, Allow, Block }

impl std::fmt::Display for SitePermissionValue {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self { Self::Ask => "Ask", Self::Allow => "Allow", Self::Block => "Block" })
    }
}

// U27w W1: the Websites pane's defaults, one synced record. The names follow the pane's board
// order; the built-in values are the board's (Ask everywhere, pop-ups Block, sound Allow).
// Chromium's own default prefs are written from this record, never read back as a second source.
// A value a kind cannot take as a default is refused when the record is parsed and when the FFI
// writes it, so the pane and Chromium never disagree (no compatibility path).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SiteDefaults {
    pub camera: SitePermissionValue,
    pub microphone: SitePermissionValue,
    pub location: SitePermissionValue,
    pub notifications: SitePermissionValue,
    pub popups: SitePermissionValue,
    pub automatic_downloads: SitePermissionValue,
    pub sound: SitePermissionValue,
}

impl SiteDefaults {
    /// The seven kinds with the values Chromium accepts as a *default* for each: Camera and
    /// Microphone Ask/Block (Allow is refused for a media default), Pop-up windows and Sound
    /// Allow/Block (no Ask), and the other three all three.
    pub fn entries(&self) -> [(&'static str, SitePermissionValue); 7] {
        [("camera", self.camera), ("microphone", self.microphone), ("location", self.location),
            ("notifications", self.notifications), ("popups", self.popups),
            ("automatic_downloads", self.automatic_downloads), ("sound", self.sound)]
    }

    /// The first kind whose stored value Chromium would refuse as a default, with the value.
    pub fn invalid(&self) -> Option<(&'static str, SitePermissionValue)> {
        for (kind, value) in self.entries() {
            let accepted = match kind {
                "camera" | "microphone" => matches!(value, SitePermissionValue::Ask | SitePermissionValue::Block),
                "popups" | "sound" => matches!(value, SitePermissionValue::Allow | SitePermissionValue::Block),
                _ => true,
            };
            if !accepted { return Some((kind, value)); }
        }
        None
    }
}

impl Default for SiteDefaults {
    fn default() -> Self {
        Self { camera: SitePermissionValue::Ask, microphone: SitePermissionValue::Ask,
            location: SitePermissionValue::Ask, notifications: SitePermissionValue::Ask,
            popups: SitePermissionValue::Block, automatic_downloads: SitePermissionValue::Ask,
            sound: SitePermissionValue::Allow }
    }
}

impl<'de> Deserialize<'de> for SiteDefaults {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where D: serde::Deserializer<'de> {
        #[derive(Deserialize)]
        #[serde(default)]
        struct Fields {
            camera: SitePermissionValue,
            microphone: SitePermissionValue,
            location: SitePermissionValue,
            notifications: SitePermissionValue,
            popups: SitePermissionValue,
            automatic_downloads: SitePermissionValue,
            sound: SitePermissionValue,
        }
        impl Default for Fields {
            fn default() -> Self {
                let value = SiteDefaults::default();
                Self { camera: value.camera, microphone: value.microphone, location: value.location,
                    notifications: value.notifications, popups: value.popups,
                    automatic_downloads: value.automatic_downloads, sound: value.sound }
            }
        }
        let fields = Fields::deserialize(deserializer)?;
        let settings = SiteDefaults { camera: fields.camera, microphone: fields.microphone,
            location: fields.location, notifications: fields.notifications, popups: fields.popups,
            automatic_downloads: fields.automatic_downloads, sound: fields.sound };
        if let Some((kind, value)) = settings.invalid() {
            return Err(serde::de::Error::custom(format!("{kind} cannot take {value} as a default")));
        }
        Ok(settings)
    }
}

// U27p P2: the Privacy pane's third-party cookie choice. Block writes Chromium's cookie-controls
// pref (CookieControlsMode::kBlockThirdParty); Allow writes kOff, which behaves as
// kIncognitoOnly since June 2025 (third-party cookies only in private windows).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum ThirdPartyCookies { #[default] Block, Allow }

// U27p P3: how long browsing history is kept. The engine's history expiry reads the workspace
// record instead of Chromium's fixed 90 days; Forever keeps every visit.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum HistoryRetention { Week, Month, ThreeMonths, #[default] Year, Forever }


// U27p P2/P3: the Privacy pane's one synced record — the third-party cookie choice, the Global
// Privacy Control signal and the history retention. The board's built-in values are Block, on and
// One year. One record, so a second Mac blocks, asks and keeps history the same way.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct PrivacySettings {
    pub third_party_cookies: ThirdPartyCookies,
    pub global_privacy_control: bool,
    pub history_retention: HistoryRetention,
}

impl Default for PrivacySettings {
    fn default() -> Self {
        Self { third_party_cookies: ThirdPartyCookies::Block, global_privacy_control: true,
            history_retention: HistoryRetention::Year }
    }
}

// The workspace's own preferences, one synced record (D5). The built-in value is derived
// rather than stored: to_ops writes a record only for a change from it, so a workspace that
// never touched a setting emits nothing and a reset is a delete (like the routing default).
// U27d's Tooltips switch (D4) rides here too, on by default, so it travels with the workspace
// the way the New Tab row does. U27i's Little Window pair (D8) rides here as well: the Open-in
// destination and close-after are workspace preferences, while the frame and the global
// shortcut stay on the device (LittleWindowDevice). U27k's Theme is synced on purpose, so a
// second Mac shows the same theme. U27w's seven site defaults (W1) ride here too: one record,
// so a second Mac asks, allows and blocks the same seven kinds. U27p's privacy record (P2, P3)
// rides here as well: the cookie choice, the GPC signal and the history retention travel with
// the workspace.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub new_tab_row_shown: bool,
    pub space_scroll_direction: SpaceScrollDirection,
    pub tooltips_shown: bool,
    pub little_window_open_in: LittleWindowOpenIn,
    pub little_window_close_after: bool,
    pub theme: Theme,
    pub site_defaults: SiteDefaults,
    /// U27p: the Privacy pane's cookies, GPC and history retention.
    pub privacy: PrivacySettings,
}

impl Default for Settings {
    fn default() -> Self {
        Self { new_tab_row_shown: true, space_scroll_direction: SpaceScrollDirection::Natural, tooltips_shown: true,
            little_window_open_in: LittleWindowOpenIn::MostRecent, little_window_close_after: true, theme: Theme::System,
            site_defaults: SiteDefaults::default(), privacy: PrivacySettings::default() }
    }
}

/// U27i D9: where the Little Window's "Open in" button sends the page: the most recent space of
/// the window's own profile, or one space by name. A named space of another profile, or one that
/// has since been deleted, reads as the most recent space when the Little Window applies it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum LittleWindowOpenIn {
    #[default]
    MostRecent,
    Space(Id),
}

