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

    pub fn import_arc_sidebar(&self, window_id: String, json: String, windows_json: Option<String>) -> Result<ImportResult, CoreError> {
        let (mut imported, report) = import::arc_sidebar(&json, windows_json.as_deref()).map_err(|e| CoreError::Import { message: e.0 })?;
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis() as u64;
        for item in imported.items.values().filter(|item| matches!(item.kind, ItemKind::Tab { .. })) {
            imported.last_selected.entry(item.id.clone()).or_insert(now);
        }
        let mut workspace = self.workspace.lock().unwrap();
        let ops = imported.to_ops();
        for op in &ops {
            workspace.apply(op);
        }
        self.store.write(ops);
        let view = workspace.clone();
        drop(workspace);
        self.store.flush()?;
        Ok(ImportResult { snapshot: snapshot(view, &window_id), report: report.into() })
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

    pub fn move_item(&self, window_id: String, id: String, container: String, index: u32, open_folder: bool) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.move_item(&id, &container, index as usize, open_folder)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn create_folder(&self, window_id: String, id: String, name: String, container: String, index: u32, wrapping: Vec<String>) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.create_folder(&id, &name, &container, index as usize, &wrapping)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn rename_folder(&self, window_id: String, id: String, name: String) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.rename_folder(&id, &name)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn delete_folder(&self, window_id: String, id: String) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.delete_folder(&id)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn rename_tab(&self, window_id: String, id: String, title: String) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.rename_tab(&id, &title)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn set_folder_collapsed(&self, window_id: String, id: String, collapsed: bool) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_folder_collapsed(&id, collapsed)?;
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
    pub folder_has_tabs: bool,
    pub parent_id: String,
    pub sibling_index: u32,
    pub collapsed: bool,
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
    pub pinned_count: u32,
    pub today_count: u32,
    pub profile_key: String,
    pub pinned_id: String,
    pub today_id: String,
    pub favorites_id: Option<String>,
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

#[derive(Debug, PartialEq, uniffi::Record)]
pub struct ImportReport {
    pub unknown_space_looks: u64,
    pub missing_windows: bool,
    pub windows_error: Option<String>,
    pub differing_folder_states: u64,
    pub skipped_dates: u64,
    pub peeked_folders: u64,
    pub unknown_window_ids: u64,
    pub malformed_window_entries: u64,
}

impl From<import::ImportReport> for ImportReport {
    fn from(report: import::ImportReport) -> Self {
        Self { unknown_space_looks: report.unknown_space_looks as u64, missing_windows: report.missing_windows,
            windows_error: report.windows_error, differing_folder_states: report.differing_folder_states as u64,
            skipped_dates: report.skipped_dates as u64, peeked_folders: report.peeked_folders as u64,
            unknown_window_ids: report.unknown_window_ids as u64, malformed_window_entries: report.malformed_window_entries as u64 }
    }
}

#[derive(Debug, PartialEq, uniffi::Record)]
pub struct ImportResult {
    pub snapshot: WorkspaceSnapshot,
    pub report: ImportReport,
}

#[uniffi::export]
pub fn import_arc_sidebar(json: String, windows_json: Option<String>) -> Result<ImportResult, CoreError> {
    let (ws, report) = import::arc_sidebar(&json, windows_json.as_deref()).map_err(|e| CoreError::Import { message: e.0 })?;
    Ok(ImportResult { snapshot: snapshot(ws, ""), report: report.into() })
}

fn snapshot(mut view: Workspace, window_id: &str) -> WorkspaceSnapshot {
    view.repair_tree();
    let archive = view.archive().into_iter().filter_map(|item| match &item.kind {
        ItemKind::Tab { url, .. } => Some(ArchiveEntry { id: item.id.clone(), title: item.display_title().into(), url: url.clone(), lifecycle_changed_at: item.lifecycle_changed_at }),
        _ => None,
    }).collect();
    WorkspaceSnapshot { archive, shown_space_id: view.shown_space(window_id).map(str::to_string), selected_id: view.selected(window_id).filter(|id| view.items.get(*id).is_some_and(|item| item.lifecycle == Lifecycle::Open && matches!(item.kind, ItemKind::Tab { .. } | ItemKind::Split { .. }))).map(str::to_string), spaces: view.spaces.iter().map(|s| space(&view, s)).collect() }
}

fn space(ws: &Workspace, s: &Space) -> SpaceSnapshot {
    let rows = |container: Option<&String>| {
        container.map_or_else(Vec::new, |c| {
            ws.outline(c).into_iter().filter_map(|(depth, item)| row(ws, depth, item)).collect()
        })
    };
    SpaceSnapshot {
        pinned_count: ws.children(&s.pinned).into_iter().filter(|i| matches!(i.lifecycle, Lifecycle::Open | Lifecycle::Unloaded)).count() as u32,
        today_count: ws.children(&s.today).into_iter().filter(|i| matches!(i.lifecycle, Lifecycle::Open | Lifecycle::Unloaded)).count() as u32,
        profile_key: format!("{:?}", s.profile),
        pinned_id: s.pinned.clone(),
        today_id: s.today.clone(),
        favorites_id: ws.favorites.get(&s.profile).cloned(),
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
    let mut children = if kind == RowKind::Folder { ws.children(&item.id) } else { Vec::new() };
    let mut folder_has_tabs = false;
    while let Some(child) = children.pop() {
        if !matches!(child.lifecycle, Lifecycle::Open | Lifecycle::Unloaded) { continue; }
        if matches!(child.kind, ItemKind::Tab { .. }) { folder_has_tabs = true; break; }
        children.extend(ws.children(&child.id));
    }
    Some(Row {
        folder_has_tabs,
        parent_id: item.membership.parent.clone().unwrap_or_default(),
        sibling_index: item.membership.parent.as_deref().map_or(0, |p| ws.children(p).into_iter()
            .filter(|i| matches!(i.lifecycle, Lifecycle::Open | Lifecycle::Unloaded))
            .position(|i| i.id == item.id).unwrap_or(0)) as u32,
        collapsed: ws.folder_collapsed.get(&item.id).copied().unwrap_or(false),
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
    fn drag_snapshot_exposes_membership_roots_indices_profiles_and_fold_state() {
        let mut ws = import::arc_sidebar(include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), None).unwrap().0;
        ws.set_folder_collapsed("folder-docs", true).unwrap();
        let snapshot = snapshot(ws, "drag");
        let space = &snapshot.spaces[0];
        assert_eq!(space.pinned_id, "pin-work");
        assert_eq!(space.today_id, "today-work");
        assert_eq!(space.favorites_id.as_deref(), Some("fav-default"));
        assert_eq!(space.pinned_count, 2);
        assert_ne!(space.profile_key, snapshot.spaces[1].profile_key);
        let folder = space.pinned.iter().find(|r| r.id == "folder-docs").unwrap();
        assert_eq!(folder.parent_id, "pin-work");
        assert_eq!(folder.sibling_index, 0);
        assert!(folder.collapsed);
        assert!(folder.folder_has_tabs);
        assert!(!space.pinned.iter().any(|r| r.id == "tab-spec"));
        let split = space.pinned.iter().find(|r| r.id == "split-1").unwrap();
        assert_eq!(split.sibling_index, 1);
    }

    #[test]
    fn item_edits_snapshot_titles_and_keep_selection_when_hidden_or_moved_to_another_space() {
        let mut ws = import::arc_sidebar(include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), None).unwrap().0;
        ws.spaces[1].profile = ararat_core::model::Profile::Default;
        ws.select_item("one", "tab-spec").unwrap();
        ws.rename_tab("tab-spec", "Custom").unwrap();
        let view = snapshot(ws.clone(), "one");
        assert_eq!(view.spaces[0].pinned.iter().find(|r| r.id == "tab-spec").unwrap().title, "Custom");
        ws.rename_tab("tab-spec", " ").unwrap();
        assert_eq!(snapshot(ws.clone(), "one").spaces[0].pinned.iter().find(|r| r.id == "tab-spec").unwrap().title, "Spec");
        ws.set_folder_collapsed("folder-docs", true).unwrap();
        assert_eq!(snapshot(ws.clone(), "one").selected_id.as_deref(), Some("tab-spec"));
        ws.move_item("folder-docs", "pin-home", 0, false).unwrap();
        let view = snapshot(ws, "one");
        assert_eq!(view.shown_space_id.as_deref(), Some("space-work"));
        assert_eq!(view.selected_id.as_deref(), Some("tab-spec"));
    }

    #[test]
    fn a_cyclic_arc_file_still_gives_a_snapshot() {
        let json = include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json")
            .replace(r#""id": "pin-work", "parentID": null"#, r#""id": "pin-work", "parentID": "tab-spec""#);
        assert!(json.contains(r#""id": "pin-work", "parentID": "tab-spec""#));
        let snapshot = import_arc_sidebar(json, None).unwrap().snapshot;
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
