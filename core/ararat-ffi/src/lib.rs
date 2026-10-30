// Snapshots cross the boundary instead of the model types, so Swift cannot come to depend on
// the core's internal representation.

use ararat_core::import;
use ararat_core::model::{Item, ItemKind, Space, Workspace};

uniffi::setup_scaffolding!();

#[derive(Debug, uniffi::Error)]
pub enum CoreError {
    Import { message: String },
}

impl std::fmt::Display for CoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CoreError::Import { message } => write!(f, "import failed: {message}"),
        }
    }
}

impl std::error::Error for CoreError {}

#[derive(uniffi::Enum)]
pub enum RowKind {
    Tab,
    Folder,
    Split,
}

#[derive(uniffi::Record)]
pub struct Row {
    pub id: String,
    pub title: String,
    pub url: Option<String>,
    pub depth: u32,
    pub kind: RowKind,
}

#[derive(uniffi::Record)]
pub struct SpaceSnapshot {
    pub id: String,
    pub title: String,
    pub icon: Option<String>,
    pub favorites: Vec<Row>,
    pub pinned: Vec<Row>,
    pub today: Vec<Row>,
}

#[derive(uniffi::Record)]
pub struct WorkspaceSnapshot {
    pub spaces: Vec<SpaceSnapshot>,
}

#[uniffi::export]
pub fn import_arc_sidebar(json: String) -> Result<WorkspaceSnapshot, CoreError> {
    let ws = import::arc_sidebar(&json).map_err(|e| CoreError::Import { message: e.0 })?;
    Ok(snapshot(&ws))
}

fn snapshot(ws: &Workspace) -> WorkspaceSnapshot {
    WorkspaceSnapshot { spaces: ws.spaces.iter().map(|s| space(ws, s)).collect() }
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
    })
}
