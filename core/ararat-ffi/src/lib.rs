// Snapshots cross the boundary instead of the model types, so Swift cannot come to depend on
// the core's internal representation.

use ararat_core::import;
use ararat_core::model::{Item, ItemKind, Lifecycle, Space, Workspace};
use ararat_core::storage::{Store, StoreError};
use std::path::Path;
use std::sync::{Arc, Mutex};

uniffi::setup_scaffolding!();

#[derive(Debug, uniffi::Error)]
pub enum CoreError {
    Import { message: String },
    Store { message: String },
    Edit { message: String },
}

impl std::fmt::Display for CoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CoreError::Import { message } => write!(f, "import failed: {message}"),
            CoreError::Store { message } => write!(f, "store failed: {message}"),
            CoreError::Edit { message } => write!(f, "edit failed: {message}"),
        }
    }
}

impl std::error::Error for CoreError {}

impl From<StoreError> for CoreError {
    fn from(error: StoreError) -> Self {
        Self::Store { message: error.0 }
    }
}

impl From<ararat_core::edit::EditError> for CoreError {
    fn from(error: ararat_core::edit::EditError) -> Self {
        Self::Edit { message: error.0 }
    }
}

#[derive(uniffi::Object)]
pub struct WorkspaceStore {
    store: Store,
    workspace: Mutex<Workspace>,
}

#[uniffi::export]
impl WorkspaceStore {
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>, CoreError> {
        let (store, workspace) = Store::open(Path::new(&path))?;
        Ok(Arc::new(Self { store, workspace: Mutex::new(workspace) }))
    }

    pub fn auto_archive(&self, window_id: String, now: u64) -> Result<Option<WorkspaceSnapshot>, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.auto_archive(now)?;
        if ops.is_empty() { return Ok(None); }
        self.store.write(ops);
        self.store.flush()?;
        Ok(Some(snapshot(workspace.clone(), &window_id)))
    }

    pub fn set_archive_after(&self, window_id: String, space_id: String, value: ArchiveAfter) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let profile = workspace.spaces.iter().find(|s| s.id == space_id)
            .ok_or_else(|| CoreError::Edit { message: format!("unknown space {space_id}") })?.profile.clone();
        let ops = workspace.set_archive_after(profile, value.into());
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn snapshot(&self, window_id: String) -> WorkspaceSnapshot {
        let workspace = self.workspace.lock().unwrap().clone();
        snapshot(workspace, &window_id)
    }

    pub fn import_arc_sidebar(&self, window_id: String, json: String) -> Result<WorkspaceSnapshot, CoreError> {
        let mut imported = import::arc_sidebar(&json).map_err(|e| CoreError::Import { message: e.0 })?;
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis() as u64;
        let ids: Vec<_> = imported.items.keys().cloned().collect();
        for id in ids { imported.stamp_selection(&id, now); }
        let mut workspace = self.workspace.lock().unwrap();
        let ops = imported.to_ops();
        for op in &ops {
            workspace.apply(op);
        }
        self.store.write(ops);
        let view = workspace.clone();
        drop(workspace);
        self.store.flush()?;
        Ok(snapshot(view, &window_id))
    }

    pub fn select_item(&self, window_id: String, id: String) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.select_item(&window_id, &id)?;
        self.store.write(ops);
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn show_space(&self, window_id: String, space_id: String) -> Result<(), CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.show_space(&window_id, &space_id)?;
        self.store.write(ops);
        Ok(())
    }

    pub fn close_item(&self, window_id: String, id: String) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.close_item(&id)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn archive_item(&self, window_id: String, id: String) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.archive_item(&id)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn restore_item(&self, window_id: String, id: String) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.restore_item(&window_id, &id)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn create_space(&self, window_id: String, name: String, space_id: String) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.create_space(&window_id, &name, &space_id)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn rename_space(&self, window_id: String, space_id: String, name: String) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.rename_space(&space_id, &name)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn set_space_icon(&self, window_id: String, space_id: String, icon: Option<String>) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_space_icon(&space_id, icon)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn set_space_look(&self, window_id: String, space_id: String, look: Option<Look>) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_space_look(&space_id, look.map(Into::into))?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn move_space(&self, window_id: String, space_id: String, index: u32) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.move_space(&space_id, index as usize)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn delete_space(&self, window_id: String, space_id: String) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.delete_space(&space_id)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn delete_archive_item(&self, window_id: String, id: String) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.delete_archive_item(&id)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn flush(&self) -> Result<(), CoreError> {
        self.store.flush().map_err(Into::into)
    }

    pub fn last_error(&self) -> Option<String> {
        self.store.last_error()
    }
}

#[derive(Debug, PartialEq, uniffi::Enum)]
pub enum RowKind {
    Tab,
    Folder,
    Split,
}

#[derive(Debug, PartialEq, uniffi::Record)]
pub struct Row {
    pub id: String,
    pub title: String,
    pub url: Option<String>,
    pub depth: u32,
    pub kind: RowKind,
    pub unloaded: bool,
    pub last_selected_at: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum Appearance { Auto, Light, Dark }

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LookColor {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Look {
    pub colors: Vec<LookColor>,
    pub opacity: f64,
    pub grain: f64,
    pub glass: bool,
    pub appearance: Appearance,
}

impl From<ararat_core::model::Look> for Look {
    fn from(look: ararat_core::model::Look) -> Self {
        Self { colors: look.colors.into_iter().map(|c| LookColor { red: c.red, green: c.green, blue: c.blue, x: c.x, y: c.y }).collect(),
            opacity: look.opacity, grain: look.grain, glass: look.glass,
            appearance: match look.appearance {
                ararat_core::model::Appearance::Auto => Appearance::Auto,
                ararat_core::model::Appearance::Light => Appearance::Light,
                ararat_core::model::Appearance::Dark => Appearance::Dark,
            },
        }
    }
}

impl From<Look> for ararat_core::model::Look {
    fn from(look: Look) -> Self {
        Self { colors: look.colors.into_iter().map(|c| ararat_core::model::LookColor { red: c.red, green: c.green, blue: c.blue, x: c.x, y: c.y }).collect(),
            opacity: look.opacity, grain: look.grain, glass: look.glass,
            appearance: match look.appearance {
                Appearance::Auto => ararat_core::model::Appearance::Auto,
                Appearance::Light => ararat_core::model::Appearance::Light,
                Appearance::Dark => ararat_core::model::Appearance::Dark,
            },
        }
    }
}

#[derive(Debug, PartialEq, uniffi::Record)]
pub struct SpaceSnapshot {
    pub archive_after: ArchiveAfter,
    pub profile_name: String,
    pub id: String,
    pub title: String,
    pub icon: Option<String>,
    pub look: Option<Look>,
    pub favorites: Vec<Row>,
    pub pinned: Vec<Row>,
    pub today: Vec<Row>,
}

#[derive(Debug, PartialEq, uniffi::Record)]
pub struct ArchiveEntry {
    pub id: String,
    pub title: String,
    pub url: String,
    pub lifecycle_changed_at: u64,
}

#[derive(Debug, PartialEq, uniffi::Record)]
pub struct WorkspaceSnapshot {
    pub archive: Vec<ArchiveEntry>,
    pub shown_space_id: Option<String>,
    pub selected_id: Option<String>,
    pub spaces: Vec<SpaceSnapshot>,
}

#[uniffi::export]
pub fn import_arc_sidebar(json: String) -> Result<WorkspaceSnapshot, CoreError> {
    let ws = import::arc_sidebar(&json).map_err(|e| CoreError::Import { message: e.0 })?;
    Ok(snapshot(ws, ""))
}

fn snapshot(mut view: Workspace, window_id: &str) -> WorkspaceSnapshot {
    view.repair_tree();
    let archive = view.archive().into_iter().filter_map(|item| match &item.kind {
        ItemKind::Tab { url, .. } => Some(ArchiveEntry { id: item.id.clone(), title: item.display_title().into(), url: url.clone(), lifecycle_changed_at: item.lifecycle_changed_at }),
        _ => None,
    }).collect();
    WorkspaceSnapshot { archive, shown_space_id: view.shown_space(window_id).map(str::to_string), selected_id: view.selected(window_id).filter(|id| view.is_selectable(id) && view.items[*id].lifecycle == Lifecycle::Open).map(str::to_string), spaces: view.spaces.iter().map(|s| space(&view, s)).collect() }
}

fn space(ws: &Workspace, s: &Space) -> SpaceSnapshot {
    let rows = |container: Option<&String>| {
        container.map_or_else(Vec::new, |c| {
            ws.outline(c).into_iter().filter_map(|(depth, item)| row(ws, depth, item)).collect()
        })
    };
    SpaceSnapshot {
        archive_after: ws.archive_after.get(&s.profile).copied().unwrap_or_default().into(),
        profile_name: match &s.profile { ararat_core::model::Profile::Default => "Default".into(), ararat_core::model::Profile::Named(name) => name.clone() },
        id: s.id.clone(),
        title: s.title.clone(),
        icon: s.icon.clone(),
        look: s.look.clone().map(Into::into),
        favorites: rows(ws.favorites.get(&s.profile)),
        pinned: rows(Some(&s.pinned)),
        today: rows(Some(&s.today)),
    }
}

fn row(ws: &Workspace, depth: usize, item: &Item) -> Option<Row> {
    let (kind, url) = match &item.kind {
        ItemKind::Tab { url, .. } => (RowKind::Tab, Some(url.clone())),
        ItemKind::Folder => (RowKind::Folder, None),
        ItemKind::Split { .. } => (RowKind::Split, None),
        ItemKind::Container => return None,
    };
    Some(Row {
        id: item.id.clone(),
        title: item.display_title().to_string(),
        url,
        depth: depth as u32,
        kind,
        unloaded: item.lifecycle == Lifecycle::Unloaded,
        last_selected_at: ws.last_selected.get(&item.id).copied(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_cyclic_arc_file_still_gives_a_snapshot() {
        let json = include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json")
            .replace(r#""id": "pin-work", "parentID": null"#, r#""id": "pin-work", "parentID": "tab-spec""#);
        assert!(json.contains(r#""id": "pin-work", "parentID": "tab-spec""#));
        let snapshot = import_arc_sidebar(json).unwrap();
        assert!(!snapshot.spaces.is_empty());
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ArchiveAfter { Hours12, Hours24, Days7, Days30 }
impl From<ararat_core::model::ArchiveAfter> for ArchiveAfter {
    fn from(value: ararat_core::model::ArchiveAfter) -> Self {
        use ararat_core::model::ArchiveAfter as Core;
        match value { Core::Hours12 => Self::Hours12, Core::Hours24 => Self::Hours24, Core::Days7 => Self::Days7, Core::Days30 => Self::Days30 }
    }
}
impl From<ArchiveAfter> for ararat_core::model::ArchiveAfter {
    fn from(value: ArchiveAfter) -> Self {
        match value { ArchiveAfter::Hours12 => Self::Hours12, ArchiveAfter::Hours24 => Self::Hours24, ArchiveAfter::Days7 => Self::Days7, ArchiveAfter::Days30 => Self::Days30 }
    }
}
