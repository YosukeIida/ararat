use std::collections::HashMap;

use serde::{Deserialize, Serialize};

pub type Id = String;

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Profile {
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
    pub collapsed: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WindowState {
    pub id: Id,
    pub shown_space: Option<Id>,
    pub selected: Option<Id>,
    pub history: Vec<Id>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Workspace {
    pub archive_after: HashMap<Profile, ArchiveAfter>,
    pub last_selected: HashMap<Id, u64>,
    pub windows: HashMap<Id, WindowState>,
    pub spaces: Vec<Space>,
    pub favorites: HashMap<Profile, Id>,
    pub items: HashMap<Id, Item>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Space,
    Item,
    Favorites,
    Window,
    ArchiveAfter,
    LastSelected,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Space => "space",
            Kind::Item => "item",
            Kind::Favorites => "favorites",
            Kind::Window => "window",
            Kind::ArchiveAfter => "archive_after",
            Kind::LastSelected => "last_selected",
        }
    }

    pub fn parse(s: &str) -> Option<Kind> {
        [Kind::Space, Kind::Item, Kind::Favorites, Kind::Window, Kind::ArchiveAfter, Kind::LastSelected].into_iter().find(|k| k.as_str() == s)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Record {
    ArchiveAfter { profile: Profile, value: ArchiveAfter },
    LastSelected { item: Id, at: u64 },
    Space(Space),
    Item(Item),
    Window(WindowState),
    Favorites { profile: Profile, container: Id },
}

impl Record {
    pub fn kind(&self) -> Kind {
        match self {
            Record::ArchiveAfter { .. } => Kind::ArchiveAfter,
            Record::LastSelected { .. } => Kind::LastSelected,
            Record::Space(_) => Kind::Space,
            Record::Window(_) => Kind::Window,
            Record::Item(_) => Kind::Item,
            Record::Favorites { .. } => Kind::Favorites,
        }
    }

    pub fn id(&self) -> Id {
        match self {
            Record::ArchiveAfter { profile, .. } => profile_id(profile),
            Record::LastSelected { item, .. } => item.clone(),
            Record::Space(s) => s.id.clone(),
            Record::Window(window) => window.id.clone(),
            Record::Item(i) => i.id.clone(),
            Record::Favorites { profile, .. } => profile_id(profile),
        }
    }

    pub fn body(&self) -> String {
        match self {
            Record::ArchiveAfter { value, .. } => serde_json::to_string(value),
            Record::LastSelected { at, .. } => serde_json::to_string(at),
            Record::Space(s) => serde_json::to_string(s),
            Record::Window(window) => serde_json::to_string(window),
            Record::Item(i) => serde_json::to_string(i),
            Record::Favorites { container, .. } => serde_json::to_string(container),
        }
        .expect("model types serialise")
    }

    pub fn parse(kind: Kind, id: &str, body: &str) -> serde_json::Result<Record> {
        Ok(match kind {
            Kind::LastSelected => Record::LastSelected { item: id.into(), at: serde_json::from_str(body)? },
            Kind::ArchiveAfter => Record::ArchiveAfter { profile: serde_json::from_str(id)?, value: serde_json::from_str(body)? },
            Kind::Space => Record::Space(serde_json::from_str(body)?),
            Kind::Window => Record::Window(serde_json::from_str(body)?),
            Kind::Item => Record::Item(serde_json::from_str(body)?),
            Kind::Favorites => Record::Favorites {
                profile: serde_json::from_str(id)?,
                container: serde_json::from_str(body)?,
            },
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

    pub(crate) fn outline_entries(&self, container: &str) -> Vec<(usize, &Item, bool)> {
        let mut rows = Vec::new();
        let mut stack: Vec<_> = self.children(container).into_iter().rev().map(|i| (0, i, true)).collect();
        while let Some((depth, item, parent_visible)) = stack.pop() {
            let visible = parent_visible && matches!(item.lifecycle, Lifecycle::Open | Lifecycle::Unloaded)
                && (!matches!(item.kind, ItemKind::Split { .. }) || self.has_open_tab(&item.id));
            rows.push((depth, item, visible));
            stack.extend(self.children(&item.id).into_iter().rev()
                .map(|c| (depth + 1, c, visible && !item.collapsed)));
        }
        rows
    }

    fn has_open_tab(&self, parent: &str) -> bool {
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
            Op::Put(Record::LastSelected { item, at }) => { self.last_selected.insert(item.clone(), *at); },
            Op::Delete(Kind::LastSelected, id) => { self.last_selected.remove(id); },
            Op::Put(Record::ArchiveAfter { profile, value }) => { self.archive_after.insert(profile.clone(), *value); },
            Op::Delete(Kind::ArchiveAfter, id) => self.archive_after.retain(|p, _| &profile_id(p) != id),
            Op::Put(Record::Window(window)) => { self.windows.insert(window.id.clone(), window.clone()); },
            Op::Delete(Kind::Window, id) => { self.windows.remove(id); },
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
        }
    }

    pub fn to_ops(&self) -> Vec<Op> {
        let spaces = self.spaces.iter().map(|s| Record::Space(s.clone()));
        let favorites = self
            .favorites
            .iter()
            .map(|(p, c)| Record::Favorites { profile: p.clone(), container: c.clone() });
        let items = self.items.values().map(|i| Record::Item(i.clone()));
        spaces.chain(favorites).chain(items).chain(self.archive_after.iter().map(|(p, v)| Record::ArchiveAfter { profile: p.clone(), value: *v })).chain(self.last_selected.iter().map(|(item, at)| Record::LastSelected { item: item.clone(), at: *at })).chain(self.windows.values().cloned().map(Record::Window))
            .map(Op::Put).collect()
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
