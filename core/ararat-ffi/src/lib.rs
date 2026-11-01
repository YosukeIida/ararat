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

    pub fn snapshot(&self, window_id: String) -> WorkspaceSnapshot {
        let workspace = self.workspace.lock().unwrap().clone();
        snapshot(workspace, &window_id)
    }

    pub fn import_arc_sidebar(&self, window_id: String, json: String) -> Result<WorkspaceSnapshot, CoreError> {
        let imported = import::arc_sidebar(&json).map_err(|e| CoreError::Import { message: e.0 })?;
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
}

#[derive(Debug, PartialEq, uniffi::Record)]
pub struct SpaceSnapshot {
    pub id: String,
    pub title: String,
    pub icon: Option<String>,
    pub favorites: Vec<Row>,
    pub pinned: Vec<Row>,
    pub today: Vec<Row>,
}

#[derive(Debug, PartialEq, uniffi::Record)]
pub struct WorkspaceSnapshot {
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
    WorkspaceSnapshot { selected_id: view.selected(window_id).filter(|id| view.is_selectable(id) && view.items[*id].lifecycle == Lifecycle::Open).map(str::to_string), spaces: view.spaces.iter().map(|s| space(&view, s)).collect() }
}

fn space(ws: &Workspace, s: &Space) -> SpaceSnapshot {
    let rows = |container: Option<&String>| {
        container.map_or_else(Vec::new, |c| {
            ws.outline(c).into_iter().filter_map(|(depth, item)| row(depth, item)).collect()
        })
    };
    SpaceSnapshot {
        id: s.id.clone(),
        title: s.title.clone(),
        icon: s.icon.clone(),
        favorites: rows(ws.favorites.get(&s.profile)),
        pinned: rows(Some(&s.pinned)),
        today: rows(Some(&s.today)),
    }
}

fn row(depth: usize, item: &Item) -> Option<Row> {
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
