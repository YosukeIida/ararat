// Snapshots cross the boundary instead of the model types, so Swift cannot come to depend on
// the core's internal representation.

use ararat_core::import;
use ararat_core::model::{Id, Item, ItemKind, Lifecycle, Space, Workspace};
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

    pub fn key_bindings(&self) -> Vec<KeyBinding> {
        key_bindings(&self.workspace.lock().unwrap())
    }

    pub fn set_key_binding(&self, command: String, key: Option<KeyCombination>) -> Result<Vec<KeyBinding>, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_key_binding(&command, key.map(Into::into))?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(key_bindings(&workspace))
    }

    pub fn reset_key_binding(&self, command: String) -> Result<Vec<KeyBinding>, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.reset_key_binding(&command)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(key_bindings(&workspace))
    }

    pub fn reset_all_key_bindings(&self) -> Result<Vec<KeyBinding>, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.reset_all_key_bindings();
        self.store.write(ops);
        self.store.flush()?;
        Ok(key_bindings(&workspace))
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

    pub fn import_arc_sidebar(&self, window_id: String, json: String, windows_json: Option<String>, key_bindings_json: Option<String>, link_routing_json: Option<String>) -> Result<ImportResult, CoreError> {
        let (mut imported, report) = import::arc_sidebar(&json, windows_json.as_deref(), key_bindings_json.as_deref(), link_routing_json.as_deref()).map_err(|e| CoreError::Import { message: e.0 })?;
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis() as u64;
        for item in imported.items.values().filter(|item| matches!(item.kind, ItemKind::Tab { .. })) {
            imported.last_selected.entry(item.id.clone()).or_insert(now);
        }
        let mut workspace = self.workspace.lock().unwrap();
        // The routing rides the same batch through to_ops(): an import without the sibling
        // file keeps the workspace's default routing state (it emits no routing records), so
        // the Air Traffic Control rules survive.
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

    // Air Traffic Control (unit 29 part A). The routing is read as its own snapshot type, so
    // no full workspace snapshot is needed and the pane can render the rules in order.
    pub fn routing(&self) -> Routing {
        self.workspace.lock().unwrap().routing().into()
    }

    pub fn route(&self, url: String) -> RoutingDecision {
        let workspace = self.workspace.lock().unwrap();
        let routing = workspace.routing();
        // rule_for and route share the matcher, so the two answers cannot disagree. The
        // space ids the workspace has now ride along: a destination naming a deleted space
        // is answered as the most recent space, the stale id never reaches a window (unit
        // 29b, round 2).
        let spaces: Vec<Id> = workspace.spaces.iter().map(|space| space.id.clone()).collect();
        let rule_id = routing.rule_for(&url).map(|rule| rule.id.clone());
        RoutingDecision { rule_id, destination: routing.route(&url, &spaces).into() }
    }

    pub fn add_rule(&self, window_id: String, rule: Rule) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.add_rule(rule.into())?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn edit_rule(&self, window_id: String, rule: Rule) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.edit_rule(rule.into())?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn delete_rule(&self, window_id: String, id: String) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.delete_rule(&id)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn move_rule(&self, window_id: String, id: String, index: u32) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.move_rule(&id, index as usize)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn set_default_destination(&self, window_id: String, destination: Destination) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_default_destination(destination.into())?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
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

    pub fn duplicate_item(&self, window_id: String, id: String) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.duplicate_item(&id)?;
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
    pub profile: Profile,
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
    pub missing_link_routing: bool,
    pub link_routing_error: Option<String>,
    // The Air Traffic Control counters, spelled the same way the free-function import's
    // LinkRoutingReport does.
    pub imported_rules: u64,
    pub skipped_profile_destinations: u64,
    pub skipped_unknown_destinations: u64,
    pub skipped_unknown_styles: u64,
    pub malformed_rules: u64,
    pub missing_key_bindings: bool,
    pub key_bindings_error: Option<String>,
    pub skipped_key_bindings: u64,
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
        Self { missing_link_routing: report.missing_link_routing, link_routing_error: report.link_routing_error,
            imported_rules: report.imported_rules as u64, skipped_profile_destinations: report.skipped_profile_destinations as u64,
            skipped_unknown_destinations: report.skipped_unknown_destinations as u64, skipped_unknown_styles: report.skipped_unknown_styles as u64,
            malformed_rules: report.malformed_rules as u64,
            missing_key_bindings: report.missing_key_bindings, key_bindings_error: report.key_bindings_error, skipped_key_bindings: report.skipped_key_bindings as u64, unknown_space_looks: report.unknown_space_looks as u64, missing_windows: report.missing_windows,
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

// Air Traffic Control routing (unit 29). Snapshots cross the boundary instead of the core's
// types, so Swift cannot come to depend on the core's internal representation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MatchStyle { Contains, Equals }

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum Profile { Default, Named(String) }

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SpaceTarget { MostRecent, Space(String) }

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum Destination {
    Space(SpaceTarget),
    LittleWindow(Profile),
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct UrlCondition {
    pub style: MatchStyle,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Rule {
    pub id: String,
    pub conditions: Vec<UrlCondition>,
    pub destination: Destination,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Routing {
    pub rules: Vec<Rule>,
    pub default: Destination,
}

// Which rule (or the default) a URL takes: rule_id is None when the default took it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct RoutingDecision {
    pub rule_id: Option<String>,
    pub destination: Destination,
}

#[derive(Debug, PartialEq, uniffi::Record)]
pub struct LinkRoutingReport {
    pub imported_rules: u64,
    pub skipped_profile_destinations: u64,
    pub skipped_unknown_destinations: u64,
    pub skipped_unknown_styles: u64,
    pub malformed_rules: u64,
}

impl From<import::LinkRoutingReport> for LinkRoutingReport {
    fn from(report: import::LinkRoutingReport) -> Self {
        Self { imported_rules: report.imported_rules as u64,
            skipped_profile_destinations: report.skipped_profile_destinations as u64,
            skipped_unknown_destinations: report.skipped_unknown_destinations as u64,
            skipped_unknown_styles: report.skipped_unknown_styles as u64,
            malformed_rules: report.malformed_rules as u64 }
    }
}

#[derive(Debug, PartialEq, uniffi::Record)]
pub struct LinkRoutingImport {
    pub routing: Routing,
    pub report: LinkRoutingReport,
}

impl From<ararat_core::routing::MatchStyle> for MatchStyle {
    fn from(style: ararat_core::routing::MatchStyle) -> Self {
        match style { ararat_core::routing::MatchStyle::Contains => Self::Contains, ararat_core::routing::MatchStyle::Equals => Self::Equals }
    }
}
impl From<MatchStyle> for ararat_core::routing::MatchStyle {
    fn from(style: MatchStyle) -> Self {
        match style { MatchStyle::Contains => Self::Contains, MatchStyle::Equals => Self::Equals }
    }
}

impl From<ararat_core::model::Profile> for Profile {
    fn from(profile: ararat_core::model::Profile) -> Self {
        match profile { ararat_core::model::Profile::Default => Self::Default, ararat_core::model::Profile::Named(name) => Self::Named(name) }
    }
}
impl From<Profile> for ararat_core::model::Profile {
    fn from(profile: Profile) -> Self {
        match profile { Profile::Default => Self::Default, Profile::Named(name) => Self::Named(name) }
    }
}

impl From<ararat_core::routing::SpaceTarget> for SpaceTarget {
    fn from(target: ararat_core::routing::SpaceTarget) -> Self {
        match target { ararat_core::routing::SpaceTarget::MostRecent => Self::MostRecent, ararat_core::routing::SpaceTarget::Space(id) => Self::Space(id) }
    }
}
impl From<SpaceTarget> for ararat_core::routing::SpaceTarget {
    fn from(target: SpaceTarget) -> Self {
        match target { SpaceTarget::MostRecent => Self::MostRecent, SpaceTarget::Space(id) => Self::Space(id) }
    }
}

impl From<ararat_core::routing::Destination> for Destination {
    fn from(destination: ararat_core::routing::Destination) -> Self {
        match destination {
            ararat_core::routing::Destination::Space(target) => Self::Space(target.into()),
            ararat_core::routing::Destination::LittleWindow(profile) => Self::LittleWindow(profile.into()),
        }
    }
}
impl From<Destination> for ararat_core::routing::Destination {
    fn from(destination: Destination) -> Self {
        match destination {
            Destination::Space(target) => Self::Space(target.into()),
            Destination::LittleWindow(profile) => Self::LittleWindow(profile.into()),
        }
    }
}

impl From<ararat_core::routing::UrlCondition> for UrlCondition {
    fn from(condition: ararat_core::routing::UrlCondition) -> Self {
        Self { style: condition.style.into(), text: condition.text }
    }
}
impl From<UrlCondition> for ararat_core::routing::UrlCondition {
    fn from(condition: UrlCondition) -> Self {
        Self { style: condition.style.into(), text: condition.text }
    }
}

impl From<ararat_core::routing::Rule> for Rule {
    fn from(rule: ararat_core::routing::Rule) -> Self {
        Self { id: rule.id, conditions: rule.conditions.into_iter().map(Into::into).collect(), destination: rule.destination.into() }
    }
}
impl From<Rule> for ararat_core::routing::Rule {
    fn from(rule: Rule) -> Self {
        Self { id: rule.id, conditions: rule.conditions.into_iter().map(Into::into).collect(), destination: rule.destination.into() }
    }
}

impl From<ararat_core::routing::Routing> for Routing {
    fn from(routing: ararat_core::routing::Routing) -> Self {
        Self { rules: routing.rules.into_iter().map(Into::into).collect(), default: routing.default.into() }
    }
}
impl From<Routing> for ararat_core::routing::Routing {
    fn from(routing: Routing) -> Self {
        Self { rules: routing.rules.into_iter().map(Into::into).collect(), default: routing.default.into() }
    }
}

#[uniffi::export]
pub fn import_arc_sidebar(json: String, windows_json: Option<String>, key_bindings_json: Option<String>, link_routing_json: Option<String>) -> Result<ImportResult, CoreError> {
    let (ws, report) = import::arc_sidebar(&json, windows_json.as_deref(), key_bindings_json.as_deref(), link_routing_json.as_deref()).map_err(|e| CoreError::Import { message: e.0 })?;
    Ok(ImportResult { snapshot: snapshot(ws, ""), report: report.into() })
}

// Arc's StorableLinkRouting.json on its own, for the pane and tests; the sibling import
// (import_arc_sidebar) calls the core function directly. `spaces` is the set of space ids the
// sidebar import produced: only destinations naming a known space can open.
#[uniffi::export]
pub fn arc_link_routing(json: String, profile: Option<Profile>, spaces: Vec<String>) -> Result<LinkRoutingImport, CoreError> {
    let known: std::collections::HashSet<String> = spaces.into_iter().collect();
    let (routing, report) = import::arc_link_routing(&json,
        profile.map_or(ararat_core::model::Profile::Default, Into::into), &known)
        .map_err(|e| CoreError::Import { message: e.0 })?;
    Ok(LinkRoutingImport { routing: routing.into(), report: report.into() })
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
        profile: s.profile.clone().into(),
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
    fn routing_ops_flush_and_read_back() {
        let path = std::env::temp_dir().join(format!("ararat-ffi-routing-{}.sqlite", std::process::id()));
        assert!(!path.exists());
        let store = WorkspaceStore::open(path.to_string_lossy().into_owned()).unwrap();
        let window: String = "one".into();
        // A rule may only name a space the workspace has, so the space is created first.
        store.create_space(window.clone(), "Work".into(), "space-work".into()).unwrap();
        // Add a rule, move it, edit it, change the default, then delete it.
        store.add_rule(window.clone(), Rule {
            id: "meet".into(),
            conditions: vec![UrlCondition { style: MatchStyle::Contains, text: "meet.google.com".into() }],
            destination: Destination::Space(SpaceTarget::Space("space-work".into())),
        }).unwrap();
        store.add_rule(window.clone(), Rule {
            id: "docs".into(),
            conditions: vec![UrlCondition { style: MatchStyle::Contains, text: "docs.example.com".into() }],
            destination: Destination::Space(SpaceTarget::MostRecent),
        }).unwrap();
        let moved = store.move_rule(window.clone(), "docs".into(), 0).unwrap();
        let _ = moved;
        store.edit_rule(window.clone(), Rule {
            id: "meet".into(),
            conditions: vec![UrlCondition { style: MatchStyle::Equals, text: "https://meet.google.com/".to_string() }],
            destination: Destination::LittleWindow(Profile::Default),
        }).unwrap();
        store.set_default_destination(window.clone(), Destination::Space(SpaceTarget::MostRecent)).unwrap();
        let routing = store.routing();
        assert_eq!(routing.rules.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), ["docs", "meet"]);
        assert_eq!(routing.default, Destination::Space(SpaceTarget::MostRecent));
        store.delete_rule(window.clone(), "meet".into()).unwrap();
        let routing = store.routing();
        assert_eq!(routing.rules.len(), 1);
        // The ops are on disk, not only in memory.
        drop(store);
        let store = WorkspaceStore::open(path.to_string_lossy().into_owned()).unwrap();
        let routing = store.routing();
        assert_eq!(routing.rules.len(), 1);
        assert_eq!(routing.default, Destination::Space(SpaceTarget::MostRecent));
        drop(store);
        for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
    }

    #[test]
    fn route_url_equals_routing_route() {
        let path = std::env::temp_dir().join(format!("ararat-ffi-route-{}.sqlite", std::process::id()));
        assert!(!path.exists());
        let store = WorkspaceStore::open(path.to_string_lossy().into_owned()).unwrap();
        let window: String = "one".into();
        // A rule may only name a space the workspace has, so the space is created first; the
        // second space keeps the first deletable (the last space cannot be deleted).
        store.create_space(window.clone(), "Work".into(), "space-work".into()).unwrap();
        store.create_space(window.clone(), "Home".into(), "space-home".into()).unwrap();
        store.add_rule(window.clone(), Rule {
            id: "meet".into(),
            conditions: vec![UrlCondition { style: MatchStyle::Contains, text: "meet.google.com".into() }],
            destination: Destination::Space(SpaceTarget::Space("space-work".into())),
        }).unwrap();
        store.add_rule(window.clone(), Rule {
            id: "empty".into(),
            conditions: vec![UrlCondition { style: MatchStyle::Contains, text: "  ".into() }],
            destination: Destination::LittleWindow(Profile::Named("Profile 1".into())),
        }).unwrap();
        // What the FFI answers must be what Routing::route answers for the same records, over
        // the spaces the store has (the two created ones).
        let core = ararat_core::routing::Routing::from(store.routing());
        let spaces = ["space-work".into(), "space-home".into()];
        for url in ["https://www.meet.google.com/abc", "https://docs.example.com/", "https://meet.google.com/?q=1"] {
            let decision = store.route(url.into());
            assert_eq!(&decision.destination, &Destination::from(core.route(url, &spaces)), "{url}");
            assert_eq!(
                decision.destination == core.default.clone().into(),
                core.rule_for(url).is_none(),
                "{url}");
        }
        // The empty rule never matches, so meet.google.com takes the meet rule.
        let decision = store.route("https://meet.google.com/x".into());
        assert_eq!(decision.rule_id.as_deref(), Some("meet"));
        assert_eq!(decision.destination, Destination::Space(SpaceTarget::Space("space-work".into())));
        // No rule matched: rule_id is none and the default took it.
        let decision = store.route("https://nothing.example.org".into());
        assert_eq!(decision.rule_id, None);
        assert_eq!(decision.destination, Destination::from(core.default.clone()));
        // A rule whose space is deleted still matches, and its link goes to the most recent
        // space (unit 29b, round 2): the FFI route answer names a rule, not the stale id.
        store.delete_space(window.clone(), "space-work".into()).unwrap();
        let decision = store.route("https://www.meet.google.com/x".into());
        assert_eq!(decision.rule_id.as_deref(), Some("meet"));
        assert_eq!(decision.destination, Destination::Space(SpaceTarget::MostRecent));
        let core = ararat_core::routing::Routing::from(store.routing());
        // The workspace's remaining space is space-home: every destination on these urls
        // names a space it no longer has, and the two answers agree on the most-recent
        // rewrite.
        for url in ["https://www.meet.google.com/abc", "https://docs.example.com/"] {
            let decision = store.route(url.into());
            assert_eq!(&decision.destination, &Destination::from(core.route(url, &["space-home".into()])), "{url}");
        }
        drop(store);
        for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
    }

    #[test]
    fn a_sidebar_import_leaves_the_routing_alone() {
        let path = std::env::temp_dir().join(format!("ararat-ffi-routing-import-{}.sqlite", std::process::id()));
        assert!(!path.exists());
        let store = WorkspaceStore::open(path.to_string_lossy().into_owned()).unwrap();
        store.add_rule("one".into(), Rule {
            id: "meet".into(),
            conditions: vec![UrlCondition { style: MatchStyle::Contains, text: "meet.google.com".to_string() }],
            destination: Destination::Space(SpaceTarget::MostRecent),
        }).unwrap();
        store.import_arc_sidebar("one".into(), include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json").into(), None, None, None).unwrap();
        // The rules survive an Arc import that carried no link-routing file.
        let routing = store.routing();
        assert_eq!(routing.rules.len(), 1);
        drop(store);
        let store = WorkspaceStore::open(path.to_string_lossy().into_owned()).unwrap();
        assert_eq!(store.routing().rules.len(), 1);
        drop(store);
        for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
    }

    #[test]
    fn arc_link_routing_ffi_maps_version_and_counters() {
        let json = r#"{"version":1,"rules":[{"id":"meet","sourceComponents":[{"id":"m","componentType":{"urlMatch":{"_0":{"contains":{}},"_1":"meet.google.com"}}}],"destination":{"space":{"_0":{"mostRecent":{}}}}},{"id":"profiled","sourceComponents":[{"id":"p","componentType":{"urlMatch":{"_0":{"contains":{}},"_1":"profile.example.com"}}}],"destination":{"littleArc":{"_0":{"profile":{"_0":"Profile 1"}}}}}],"defaultDestination":{"littleArc":{"_0":{"mostRecent":{}}}}}"#;
        let imported = arc_link_routing(json.into(), None, vec![]).unwrap();
        assert_eq!(imported.routing.rules.len(), 1);
        assert_eq!(imported.routing.rules[0].conditions[0].style, MatchStyle::Contains);
        assert_eq!(imported.report.imported_rules, 1);
        assert_eq!(imported.report.skipped_profile_destinations, 1);
        let error = arc_link_routing(r#"{"version":9,"rules":[]}"#.into(), Some(Profile::Default), vec![]).unwrap_err();
        assert!(error.to_string().contains("version 9 is not supported"), "{error}");
    }

    // Part B: the routing sibling joins the sidebar import's own store batch (its records, its
    // counters in the report), so a reopen reads the File's rules without a second flush.
    #[test]
    fn a_routing_file_imports_beside_the_sidebar_into_the_store_batch() {
        let path = std::env::temp_dir().join(format!("ararat-ffi-routing-sibling-{}.sqlite", std::process::id()));
        assert!(!path.exists());
        let store = WorkspaceStore::open(path.to_string_lossy().into_owned()).unwrap();
        let result = store.import_arc_sidebar("one".into(),
            include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json").into(), None, None,
            Some(include_str!("../../ararat-core/tests/fixtures/link-routing-synthetic.json").into())).unwrap();
        let report = result.report;
        assert!(!report.missing_link_routing);
        assert_eq!(report.link_routing_error, None);
        assert_eq!(report.imported_rules, 4);
        assert_eq!(report.skipped_profile_destinations, 1);
        assert_eq!(report.skipped_unknown_destinations, 1);
        assert_eq!(report.skipped_unknown_styles, 1);
        assert_eq!(report.malformed_rules, 1);
        let routing = store.routing();
        assert_eq!(routing.rules.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), ["meet", "github-prs", "docs-little", "double-condition"]);
        // The default equals the built-in one on this fixture, so no default record was written.
        assert_eq!(routing.default, Destination::LittleWindow(Profile::Default));
        // A second import of the same file overwrites its own rows and changes nothing else.
        store.import_arc_sidebar("one".into(),
            include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json").into(), None, None,
            Some(include_str!("../../ararat-core/tests/fixtures/link-routing-synthetic.json").into())).unwrap();
        assert_eq!(store.routing(), routing);
        // The rules reached the journal: one row per rule, all in the import's one batch.
        drop(store);
        let store = WorkspaceStore::open(path.to_string_lossy().into_owned()).unwrap();
        assert_eq!(store.routing(), routing);
        drop(store);
        let conn = rusqlite::Connection::open(&path).unwrap();
        let rules: i64 = conn.query_row("SELECT count(*) FROM journal WHERE kind = 'routing_rule'", [], |r| r.get(0)).unwrap();
        let defaults: i64 = conn.query_row("SELECT count(*) FROM journal WHERE kind = 'routing_default'", [], |r| r.get(0)).unwrap();
        assert_eq!(rules, 8); // 4 rules × 2 imports
        assert_eq!(defaults, 0);
        for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
    }

    // Part B: an unreadable routing sibling never blocks the sidebar (as key_bindings_error
    // does not); the report notes it and the saved routing is untouched.
    #[test]
    fn a_broken_routing_file_imports_the_sidebar_and_sets_the_report_field() {
        let path = std::env::temp_dir().join(format!("ararat-ffi-routing-broken-{}.sqlite", std::process::id()));
        assert!(!path.exists());
        let store = WorkspaceStore::open(path.to_string_lossy().into_owned()).unwrap();
        store.add_rule("one".into(), Rule {
            id: "saved".into(),
            conditions: vec![UrlCondition { style: MatchStyle::Contains, text: "saved.example.com".into() }],
            destination: Destination::Space(SpaceTarget::MostRecent),
        }).unwrap();
        let result = store.import_arc_sidebar("one".into(),
            include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json").into(), None, None,
            Some("{\"version\":1,\"rules\":}".into())).unwrap();
        assert_eq!(result.snapshot.spaces.len(), 2);
        assert!(result.report.link_routing_error.is_some());
        assert!(!result.report.missing_link_routing);
        assert_eq!(result.report.imported_rules, 0);
        let routing = store.routing();
        assert_eq!(routing.rules.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), ["saved"]);
        drop(store);
        let store = WorkspaceStore::open(path.to_string_lossy().into_owned()).unwrap();
        assert_eq!(store.routing().rules.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), ["saved"]);
        drop(store);
        for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
    }

    #[test]
    fn duplicate_flushes_and_returns_the_copy_in_snapshot() {
        let path = std::env::temp_dir().join(format!("ararat-ffi-duplicate-{}.sqlite", std::process::id()));
        assert!(!path.exists());
        let store = WorkspaceStore::open(path.to_string_lossy().into_owned()).unwrap();
        store.import_arc_sidebar("one".into(), include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json").into(), None, None, None).unwrap();
        let snapshot = store.duplicate_item("one".into(), "folder-docs".into()).unwrap();
        let rows: Vec<_> = snapshot.spaces[0].pinned.iter().filter(|row| row.depth == 0).collect();
        let position = rows.iter().position(|row| row.id == "folder-docs").unwrap();
        let copy = rows[position + 1].id.clone();
        assert_ne!(copy, "folder-docs");
        assert_eq!(rows[position + 1].kind, RowKind::Folder);
        let (_, loaded) = Store::open(&path).unwrap();
        assert!(loaded.items.contains_key(&copy));
        drop(store);
        for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
    }

    #[test]
    fn drag_snapshot_exposes_membership_roots_indices_profiles_and_fold_state() {
        let mut ws = import::arc_sidebar(include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), None, None, None).unwrap().0;
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
        let mut ws = import::arc_sidebar(include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), None, None, None).unwrap().0;
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
        let snapshot = import_arc_sidebar(json, None, None, None).unwrap().snapshot;
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
        use ararat_core::model::ArchiveAfter as Core;
        match value { ArchiveAfter::Hours12 => Core::Hours12, ArchiveAfter::Hours24 => Core::Hours24, ArchiveAfter::Days7 => Core::Days7, ArchiveAfter::Days30 => Core::Days30 }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
/// `key` is the character without Shift ("4" for ⇧⌘4, "l" for ⇧⌘L); modifiers are explicit.
pub struct KeyCombination {
    pub key: String,
    pub command: bool,
    pub control: bool,
    pub option: bool,
    pub shift: bool,
}

impl From<KeyCombination> for ararat_core::key_bindings::KeyCombination {
    fn from(key: KeyCombination) -> Self {
        Self { key: key.key, command: key.command, control: key.control, option: key.option, shift: key.shift }
    }
}

impl From<ararat_core::key_bindings::KeyCombination> for KeyCombination {
    fn from(key: ararat_core::key_bindings::KeyCombination) -> Self {
        Self { key: key.key, command: key.command, control: key.control, option: key.option, shift: key.shift }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct KeyBinding {
    pub command: String,
    pub title: String,
    pub menu: String,
    pub description: String,
    pub default_key: Option<KeyCombination>,
    pub key: Option<KeyCombination>,
    pub customized: bool,
    pub conflicting: bool,
    pub assigned_key: Option<KeyCombination>,
}

fn key_bindings(workspace: &Workspace) -> Vec<KeyBinding> {
    workspace.key_bindings().into_iter().map(|binding| {
        let command = binding.command;
        let assigned_key = workspace.key_binding_overrides.get(&command.id).cloned()
            .unwrap_or_else(|| command.default_key.clone()).map(Into::into);
        KeyBinding { customized: workspace.key_binding_overrides.contains_key(&command.id),
            key: binding.key.map(Into::into), conflicting: binding.conflicting, assigned_key,
            command: command.id, title: command.title, menu: command.menu, description: command.description,
            default_key: command.default_key.map(Into::into) }
    }).collect()
}

#[uniffi::export]
pub fn default_key_bindings() -> Vec<KeyBinding> {
    key_bindings(&Workspace::default())
}

#[derive(uniffi::Object)]
pub struct CommandBarSession {
    index: ararat_core::command_bar::Index,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum SuggestionTarget {
    Tab { id: String, space_id: Option<String> },
    Archive { id: String },
    OpenUrl { url: String },
    Search { url: String },
    Command { id: String },
    Space { id: String },
    Folder { id: String, space_id: String },
    MoveToSpace { id: String },
    MoveToFolder { id: String, space_id: String },
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Suggestion {
    pub title: String,
    pub subtitle: String,
    pub url: Option<String>,
    pub key: Option<KeyCombination>,
    pub target: SuggestionTarget,
    pub score: f64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CommandBarResult {
    pub rows: Vec<Suggestion>,
    pub inline_completion: Option<String>,
}

#[uniffi::export]
impl CommandBarSession {
    pub fn query(&self, text: String) -> CommandBarResult {
        use ararat_core::command_bar::Target;
        let result = self.index.query(&text);
        CommandBarResult {
            inline_completion: result.inline_completion,
            rows: result.rows.into_iter().map(|s| Suggestion {
                title: s.title, subtitle: s.subtitle, url: s.url, key: s.key.map(Into::into), score: s.score,
                target: match s.target {
                    Target::Tab { id, space_id } => SuggestionTarget::Tab { id, space_id },
                    Target::Archive { id } => SuggestionTarget::Archive { id },
                    Target::OpenUrl { url } => SuggestionTarget::OpenUrl { url },
                    Target::Search { url } => SuggestionTarget::Search { url },
                    Target::Command { id } => SuggestionTarget::Command { id },
                    Target::Space { id } => SuggestionTarget::Space { id },
                    Target::Folder { id, space_id } => SuggestionTarget::Folder { id, space_id },
                    Target::MoveToSpace { id } => SuggestionTarget::MoveToSpace { id },
                    Target::MoveToFolder { id, space_id } => SuggestionTarget::MoveToFolder { id, space_id },
                },
            }).collect(),
        }
    }
}

#[uniffi::export]
impl WorkspaceStore {
    pub fn command_bar_session(&self, window_id: String) -> Arc<CommandBarSession> {
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis() as u64;
        let mut workspace = self.workspace.lock().unwrap().clone();
        workspace.repair_tree();
        Arc::new(CommandBarSession { index: ararat_core::command_bar::Index::new(&workspace, &window_id, now) })
    }

    pub fn create_tab(&self, window_id: String, url: String) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.create_tab(&window_id, &url)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn set_tab_url(&self, window_id: String, id: String, url: String) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_tab_url(&id, &url)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }
}
