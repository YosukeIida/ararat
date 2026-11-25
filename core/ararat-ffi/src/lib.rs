// Snapshots cross the boundary instead of the model types, so Swift cannot come to depend on
// the core's internal representation.

use ararat_core::import;
use ararat_core::model::{Id, Item, ItemKind, Lifecycle, Space, Workspace};
use ararat_core::storage::{Store, StoreError};
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex};

uniffi::setup_scaffolding!();

#[uniffi::export]
pub fn command_bar_pasted_text(text: String) -> String {
    ararat_core::command_bar::pasted_text(&text)
}

#[derive(Debug, uniffi::Error)]
pub enum CoreError {
    Import { message: String },
    Store { message: String },
    Edit { message: String },
    Live { message: String },
}

impl std::fmt::Display for CoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CoreError::Import { message } => write!(f, "import failed: {message}"),
            CoreError::Store { message } => write!(f, "store failed: {message}"),
            CoreError::Edit { message } => write!(f, "edit failed: {message}"),
            CoreError::Live { message } => write!(f, "live failed: {message}"),
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

impl From<ararat_core::live::LiveError> for CoreError {
    fn from(error: ararat_core::live::LiveError) -> Self {
        Self::Live { message: error.0 }
    }
}

#[derive(uniffi::Object)]
pub struct WorkspaceStore {
    store: Store,
    workspace: Mutex<Workspace>,
    live: Mutex<ararat_core::live::Live>,
    private: bool,
}

impl WorkspaceStore {
    fn admit(&self, restricted: bool) -> Result<(), CoreError> {
        if self.private && restricted { Err(CoreError::Edit { message: "operation unavailable in a private workspace".into() }) } else { Ok(()) }
    }

    // The private workspace keeps its rows in one Today list (no pins, folders or favourites),
    // so a pane op is admitted only for a row that lives there; a foreign item is refused with
    // the same error rather than reaching the core.
    fn admit_today(&self, workspace: &Workspace, id: &str) -> Result<(), CoreError> {
        if self.private && !workspace.is_in_today(id) { self.admit(true)?; }
        Ok(())
    }
}

#[uniffi::export]
impl WorkspaceStore {
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>, CoreError> {
        let (store, workspace) = Store::open(Path::new(&path))?;
        Ok(Arc::new(Self { store, workspace: Mutex::new(workspace), live: Mutex::new(ararat_core::live::Live::new()), private: false }))
    }

    #[uniffi::constructor]
    pub fn open_private(profile: Profile) -> Arc<Self> {
        Arc::new(Self { store: Store::private(), workspace: Mutex::new(Workspace::private(profile.into())), live: Mutex::new(ararat_core::live::Live::new()), private: true })
    }

    pub fn key_bindings(&self) -> Vec<KeyBinding> {
        key_bindings(&self.workspace.lock().unwrap())
    }

    pub fn set_key_binding(&self, command: String, key: Option<KeyCombination>) -> Result<Vec<KeyBinding>, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_key_binding(&command, key.map(Into::into))?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(key_bindings(&workspace))
    }

    pub fn reset_key_binding(&self, command: String) -> Result<Vec<KeyBinding>, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.reset_key_binding(&command)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(key_bindings(&workspace))
    }

    pub fn reset_all_key_bindings(&self) -> Result<Vec<KeyBinding>, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.reset_all_key_bindings();
        self.store.write(ops);
        self.store.flush()?;
        Ok(key_bindings(&workspace))
    }

    pub fn set_archive_after(&self, window_id: String, space_id: String, value: ArchiveAfter) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
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

    pub fn folder_drag_rows(&self, window_id: String, folder_id: String) -> Vec<Row> {
        let mut workspace = self.workspace.lock().unwrap().clone();
        workspace.repair_tree();
        if !workspace.items.get(&folder_id).is_some_and(|item| matches!(item.kind, ItemKind::Folder)) {
            return Vec::new();
        }
        rows(&workspace, &folder_id, workspace.selected(&window_id))
    }

    pub fn selected_item(&self, window_id: String) -> Option<String> {
        self.workspace.lock().unwrap().selected(&window_id).map(str::to_owned)
    }

    pub fn split_layout(&self, item_id: String) -> Option<SplitPane> {
        let mut workspace = self.workspace.lock().unwrap().clone();
        workspace.repair_tree();
        let id = workspace.outermost_split(&item_id)?;
        split_pane(&workspace, &id, 1.0)
    }

    pub fn set_split_factors(&self, split_id: String, factors: Vec<SplitFactor>) -> Result<(), CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_split_factors(&split_id, factors.into_iter().map(|f| (f.id, f.factor)).collect())?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(())
    }

    pub fn move_pane(&self, window_id: String, item_id: String, forward: bool) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        self.admit_today(&workspace, &item_id)?;
        let ops = workspace.move_pane(&item_id, forward)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn convert_split(&self, window_id: String, split_id: String) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        self.admit_today(&workspace, &split_id)?;
        let ops = workspace.convert_split(&split_id)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    // U25d: Add Left/Right Split. The new pane opens the New Tab page; the caller selects it
    // (its id comes back with the snapshot) and the engine opens it beside its siblings.
    pub fn add_split_pane(&self, window_id: String, item_id: String, side: SplitSide) -> Result<SplitChange, CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        self.admit_today(&workspace, &item_id)?;
        let (ops, change) = workspace.add_split_pane(&item_id, side.into())?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(SplitChange { snapshot: snapshot(workspace.clone(), &window_id), split: change.split, pane: change.pane })
    }

    // U25d: Separate Tab from Split. The pane becomes its own Today row right after the split
    // row, and a split left with one pane becomes that tab, in this one transaction.
    pub fn separate_pane(&self, window_id: String, item_id: String) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        self.admit_today(&workspace, &item_id)?;
        let ops = workspace.separate_pane(&item_id)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    // U25d: drag-to-split. The dragged row takes the dropped side of the shown row.
    pub fn make_split(&self, window_id: String, dragged_id: String, target_id: String, side: SplitSide) -> Result<SplitChange, CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        self.admit_today(&workspace, &dragged_id)?;
        self.admit_today(&workspace, &target_id)?;
        let (ops, change) = workspace.make_split(&dragged_id, &target_id, side.into())?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(SplitChange { snapshot: snapshot(workspace.clone(), &window_id), split: change.split, pane: change.pane })
    }

    pub fn import_arc_sidebar(&self, window_id: String, json: String, windows_json: Option<String>, key_bindings_json: Option<String>, link_routing_json: Option<String>, owner_profile: Option<Profile>) -> Result<ImportResult, CoreError> {
        self.admit(true)?;
        let (mut imported, report) = import::arc_sidebar(&json, windows_json.as_deref(), key_bindings_json.as_deref(), link_routing_json.as_deref(), owner_profile.map(Into::into)).map_err(|e| CoreError::Import { message: e.0 })?;
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis() as u64;
        let mut workspace = self.workspace.lock().unwrap();
        let live = self.live.lock().unwrap();
        for item in imported.items.values_mut().filter(|item| matches!(item.kind, ItemKind::Tab { .. })) {
            imported.last_selected.entry(item.id.clone()).or_insert(now);
            if let Some(current) = workspace.items.get(&item.id).filter(|current| current.lifecycle == Lifecycle::Open)
                && live.live_tab(&item.id).is_some()
            {
                item.lifecycle = Lifecycle::Open;
                item.lifecycle_changed_at = current.lifecycle_changed_at;
            }
        }
        drop(live);
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

    // Routing crosses as its own snapshot type, not a full workspace snapshot: the pane only
    // renders the rules in order.
    pub fn routing(&self) -> Routing {
        self.workspace.lock().unwrap().routing().into()
    }

    pub fn route(&self, url: String) -> RoutingDecision {
        let workspace = self.workspace.lock().unwrap();
        let routing = workspace.routing();
        // rule_for and route share the matcher, so the two answers cannot disagree. The
        // space view the workspace has now rides along: a destination naming a space the
        // rule's profile no longer has is answered the way Routing::route spells out (the
        // profile's own spaces first), and the stale id never reaches a window.
        let spaces = workspace.routing_spaces();
        let rule_id = routing.rule_for(&url).map(|rule| rule.id.clone());
        RoutingDecision { rule_id, destination: routing.route(&url, &spaces).into() }
    }

    pub fn most_recent_space(&self) -> Option<String> {
        self.workspace.lock().unwrap().routing_spaces().recency.first().cloned()
    }

    // The pane's "Deleted space" menus read the core's one answer, not a Swift-side compare.
    pub fn deleted_space_destinations(&self) -> Vec<DeletedDestination> {
        self.workspace.lock().unwrap().deleted_space_destinations().into_iter()
            .map(|lost| DeletedDestination { rule_id: lost.rule_id, space_id: lost.space_id })
            .collect()
    }

    pub fn add_rule(&self, window_id: String, rule: Rule) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.add_rule(rule.into())?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn edit_rule(&self, window_id: String, rule: Rule) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.edit_rule(rule.into())?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn delete_rule(&self, window_id: String, id: String) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.delete_rule(&id)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn move_rule(&self, window_id: String, id: String, index: u32) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.move_rule(&id, index as usize)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn set_default_destination(&self, window_id: String, destination: Destination) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_default_destination(destination.into())?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn select_item(&self, window_id: String, id: String) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.select_item(&window_id, &id)?;
        self.store.write(ops);
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn show_space(&self, window_id: String, space_id: String) -> Result<(), CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.show_space(&window_id, &space_id)?;
        self.store.write(ops);
        Ok(())
    }

    pub fn show_space_selecting(&self, window_id: String, space_id: String) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        let mut next = workspace.clone();
        let mut ops = next.show_space(&window_id, &space_id)?;
        let view = selection_view(&next, &window_id);
        let rows: Vec<_> = view.spaces.iter().find(|space| space.id == space_id)
            .into_iter().flat_map(|space| space.today.iter().chain(&space.pinned).chain(&space.favorites))
            .filter(|row| row.url.is_some() || (row.kind == RowKind::Split && next.outline(&row.id).iter().any(|(_, item)| {
                matches!(item.lifecycle, Lifecycle::Open | Lifecycle::Unloaded) && matches!(item.kind, ItemKind::Tab { .. })
            }))).collect();
        let selected = view.selected_id.as_ref().filter(|id| rows.iter().any(|row| &row.id == *id))
            .or_else(|| next.windows.get(&window_id).and_then(|state| state.history.iter().find(|id| rows.iter().any(|row| &row.id == *id))))
            .or_else(|| rows.first().map(|row| &row.id)).cloned();
        match selected {
            // A row already recorded as selected still has to be selected again when the
            // engine left it Unloaded: record_active is what flips it to Open (loads it).
            Some(id) if next.selected(&window_id) != Some(id.as_str())
                || !next.items.get(&id).is_some_and(|item| item.lifecycle == Lifecycle::Open)
                || next.outermost_split(&id).is_some() => ops.extend(next.select_item(&window_id, &id)?),
            None => ops.extend(next.clear_selection(&window_id)),
            _ => {}
        }
        self.store.write(ops);
        *workspace = next;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn show_space_selecting_tab(&self, window_id: String, space_id: String, item_id: String) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        let mut next = workspace.clone();
        let mut ops = next.show_space(&window_id, &space_id)?;
        let view = selection_view(&next, &window_id);
        let valid = view.spaces.iter().find(|space| space.id == space_id)
            .is_some_and(|space| space.today.iter().chain(&space.pinned).chain(&space.favorites)
                .any(|row| row.id == item_id && row.kind == RowKind::Tab && row.url.is_some()));
        if !valid { return Err(CoreError::Edit { message: "Tab is not visible in the requested space".into() }); }
        ops.extend(next.select_item(&window_id, &item_id)?);
        self.store.write(ops);
        *workspace = next;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn recent_space_for_profile(&self, window_id: String, profile: Profile) -> Option<String> {
        self.workspace.lock().unwrap().recent_space_for_profile(&window_id, &profile.into()).map(str::to_owned)
    }

    pub fn item_profile(&self, item_id: String) -> Option<Profile> {
        self.workspace.lock().unwrap().item_profile(&item_id).cloned().map(Into::into)
    }

    pub fn close_window(&self, window_id: String, quitting: bool) -> Result<(), CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.close_window(&window_id, quitting);
        self.store.write(ops);
        self.store.flush()?;
        Ok(())
    }

    pub fn set_window_presentation(&self, window_id: String, presentation: WindowPresentation) -> Result<(), CoreError> {
        self.admit(false)?;
        if self.private { return Ok(()); }
        let mut workspace = self.workspace.lock().unwrap();
        let width = presentation.sidebar_width.ok_or_else(|| CoreError::Edit { message: "missing sidebar width".into() })?;
        let ops = workspace.set_window_presentation(&window_id, presentation.frame.map(Into::into), width, presentation.sidebar_hidden)?;
        self.store.write(ops);
        Ok(())
    }

    pub fn kept_windows(&self) -> Vec<KeptWindow> {
        let workspace = self.workspace.lock().unwrap();
        workspace.kept_windows().into_iter().filter(|_| !self.private)
            .map(|window| KeptWindow { shown_space: workspace.shown_space(&window.id).map(str::to_owned),
                                       id: window.id, changed_at: window.changed_at,
                                       presentation: WindowPresentation { frame: window.frame.map(Into::into), sidebar_width: window.sidebar_width, sidebar_hidden: window.sidebar_hidden } }).collect()
    }

    // P5b: When Ararat opens is Open a new window, so the launch throws the kept records away as
    // closing each window did; nothing piles up for a later restore.
    pub fn discard_kept_windows(&self) -> Result<(), CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.discard_kept_windows();
        self.store.write(ops);
        self.store.flush().map_err(Into::into)
    }

    pub fn pending_history_purges(&self) -> Result<Vec<HistoryPurge>, CoreError> {
        let workspace = self.workspace.lock().unwrap();
        if workspace.history_purges.is_empty() { return Ok(Vec::new()); }
        self.store.flush()?;
        let live = self.live.lock().unwrap();
        let mut purges: Vec<_> = workspace.history_purges.iter().filter(|(id, _)| !live.pending_close_purge(id)).map(|(id, (profile, item, changed_at))|
            HistoryPurge { id: id.clone(), profile: profile.clone().into(), item: item.clone(), changed_at: *changed_at }).collect();
        purges.sort_by(|a, b| a.id.cmp(&b.id));
        Ok(purges)
    }

    pub fn history_admission(&self, item: String) -> HistoryAdmission {
        let workspace = self.workspace.lock().unwrap();
        let stamp = workspace.items.get(&item).map_or(0, |i| i.lifecycle_changed_at);
        let live = self.live.lock().unwrap();
        let purges = workspace.history_purges.iter().filter(|(purge, (_, id, _))| id == &item && !live.pending_close_purge(purge))
            .map(|(id, (profile, item, changed_at))| HistoryPurge { id: id.clone(), profile: profile.clone().into(), item: item.clone(), changed_at: *changed_at }).collect();
        HistoryAdmission { stamp, purges }
    }

    pub fn acknowledge_history_purge(&self, id: String) -> Result<(), CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        if !workspace.history_purges.contains_key(&id) { return Ok(()); }
        let op = ararat_core::model::Op::Delete(ararat_core::model::Kind::HistoryPurge, id);
        self.store.write(vec![op.clone()]);
        self.store.flush()?;
        workspace.apply(&op);
        Ok(())
    }

    pub fn restoration_candidate(&self, window_id: String) -> Option<RestorationCandidate> {
        if self.private { return None; }
        let workspace = self.workspace.lock().unwrap();
        let state = workspace.windows.get(&window_id)?;
        let space = workspace.spaces.iter().find(|space| Some(space.id.as_str()) == workspace.shown_space(&window_id))?;
        let item = workspace.items.get(state.selected.as_ref()?)?;
        let ItemKind::Tab { url, .. } = &item.kind else { return None };
        if !matches!(item.lifecycle, Lifecycle::Open | Lifecycle::Unloaded) || url.is_empty() { return None; }
        let mut current = item;
        for _ in 0..workspace.items.len() {
            let Some(parent) = current.membership.parent.as_ref() else { break };
            current = workspace.items.get(parent)?;
            if !matches!(current.lifecycle, Lifecycle::Open | Lifecycle::Unloaded)
                || matches!(current.kind, ItemKind::Tab { .. }) { return None; }
        }
        if current.membership.parent.is_some() || !space.owns_root(&current.id) { return None; }
        Some(RestorationCandidate { id: item.id.clone(), url: url.clone(), space: space.id.clone(), profile: space.profile.clone().into() })
    }

    pub fn close_item(&self, window_id: String, id: String) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.close_item(&id)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn archive_item(&self, window_id: String, id: String) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.archive_item(&id)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn clear_archive(&self, window_id: String) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let profile = workspace.shown_space(&window_id).and_then(|id| workspace.spaces.iter().find(|space| space.id == id))
            .map(|space| space.profile.clone()).ok_or_else(|| CoreError::Edit { message: "no shown profile".into() })?;
        let ops = workspace.clear_archive(&profile)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn archive_little_window(&self, window_id: String, profile: String, url: String, title: String) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let profile = if profile.is_empty() || profile == "Default" { ararat_core::model::Profile::Default } else { ararat_core::model::Profile::Named(profile) };
        let ops = workspace.archive_little_window(&window_id, &profile, &url, &title)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn restore_item(&self, window_id: String, id: String) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.restore_item(&window_id, &id)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn create_space(&self, window_id: String, name: String, space_id: String) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.create_space(&window_id, &name, &space_id)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn rename_space(&self, window_id: String, space_id: String, name: String) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.rename_space(&space_id, &name)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn set_space_icon(&self, window_id: String, space_id: String, icon: Option<String>) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_space_icon(&space_id, icon)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn set_space_look(&self, window_id: String, space_id: String, look: Option<Look>) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_space_look(&space_id, look.map(Into::into))?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn move_space(&self, window_id: String, space_id: String, index: u32) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.move_space(&space_id, index as usize)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn delete_archive_item(&self, window_id: String, id: String) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.delete_archive_item(&id)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn move_item(&self, window_id: String, id: String, container: String, index: u32, open_folder: bool) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        if self.private && (open_folder || workspace.spaces.first().is_none_or(|space| space.today != container)) { self.admit(true)?; }
        let ops = workspace.move_item(&id, &container, index as usize, open_folder)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn duplicate_item(&self, window_id: String, id: String) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.duplicate_item(&id)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn create_folder(&self, window_id: String, id: String, name: String, container: String, index: u32, wrapping: Vec<String>) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.create_folder(&id, &name, &container, index as usize, &wrapping)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn rename_folder(&self, window_id: String, id: String, name: String) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.rename_folder(&id, &name)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn delete_folder(&self, window_id: String, id: String) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.delete_folder(&id)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn rename_tab(&self, window_id: String, id: String, title: String) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.rename_tab(&id, &title)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn set_folder_collapsed(&self, window_id: String, id: String, collapsed: bool) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_folder_collapsed(&id, collapsed)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn set_section_collapsed(&self, window_id: String, space_id: String, collapsed: bool) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_section_collapsed(&space_id, collapsed)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    // Read on its own rather than in SpaceSnapshot: the record is per space and the
    // snapshot's Swift initialisers are written positionally all over the app's tests.
    pub fn section_collapsed(&self, space_id: String) -> bool {
        self.workspace.lock().unwrap().is_section_collapsed(&space_id)
    }

    // D6: one batch, one store write, so the caller's undo reverses the whole clear.
    pub fn clear_today(&self, window_id: String, space_id: String) -> Result<ClearTodayResult, CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        let selected = workspace.selected(&window_id).map(str::to_owned);
        let (ops, batch) = workspace.clear_today(&space_id)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(ClearTodayResult { snapshot: snapshot(workspace.clone(), &window_id),
            batch: (!self.private).then(|| std::sync::Arc::new(ClearTodayUndo { batch, selected })) })
    }

    pub fn settings(&self) -> WorkspaceSettings {
        self.workspace.lock().unwrap().settings.clone().into()
    }

    pub fn set_new_tab_row_shown(&self, window_id: String, shown: bool) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_new_tab_row_shown(shown);
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    // U27c: the Spaces pane's scroll direction. The same synced record as the New Tab row
    // switch, so the pane writes it once and every window reads it back from the workspace.
    pub fn set_space_scroll_direction(&self, window_id: String, direction: SpaceScrollDirection) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_space_scroll_direction(direction.into());
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    // U27d: the Appearance pane's Tooltips switch (D4). The same synced settings record as the
    // New Tab row switch, so the pane writes it once and every window reads it back.
    pub fn set_tooltips_shown(&self, window_id: String, shown: bool) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_tooltips_shown(shown);
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn flush(&self) -> Result<(), CoreError> {
        self.store.flush().map_err(Into::into)
    }

    // U27h D8: the Little Window's frame, per device. A nil frame forgets it.
    pub fn little_window_frame(&self) -> Option<LittleWindowFrame> {
        self.workspace.lock().unwrap().little_window_frame.map(Into::into)
    }

    pub fn set_little_window_frame(&self, frame: Option<LittleWindowFrame>) -> Result<(), CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_little_window_frame(frame.map(Into::into));
        self.store.write(ops);
        self.store.flush().map_err(Into::into)
    }

    // U27i D8/D9: the Little Window's Open-in destination and close-after ride the synced
    // settings record; the frame, "Remember its size and place" and the global shortcut stay on
    // the device.
    pub fn set_little_window_open_in(&self, window_id: String, open_in: LittleWindowOpenIn) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_little_window_open_in(open_in.into());
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn set_little_window_close_after(&self, window_id: String, close_after: bool) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_little_window_close_after(close_after);
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    // U27k: the Appearance pane's Theme (D5). The same synced settings record as the switches
    // above, so every device reads the chosen theme back from the workspace.
    pub fn set_theme(&self, window_id: String, theme: Theme) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_theme(theme.into());
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    // U27w W1: the Websites pane's seven defaults, the same synced settings record. The pane
    // writes one kind at a time as the whole record; the app pushes the record into Chromium. A
    // value the kind cannot take as a default is refused here (the record's parse refuses it too),
    // so Chromium never keeps a different default from the one the pane shows.
    pub fn set_site_defaults(&self, window_id: String, defaults: SiteDefaults) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let defaults: ararat_core::model::SiteDefaults = defaults.into();
        if let Some((kind, value)) = defaults.invalid() {
            return Err(CoreError::Edit { message: format!("{kind} cannot take {value} as a default") });
        }
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_site_defaults(defaults);
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    // U27p P2/P3: the Privacy pane's cookies, GPC and history retention, the same synced
    // settings record as the switches above. The app pushes the record into Chromium on every
    // change and at every window start.
    pub fn set_privacy(&self, window_id: String, privacy: PrivacySettings) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_privacy(privacy.into());
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    // P5b: the General pane's When Ararat opens, the same synced settings record. The app reads
    // it at the launch site before the first window adopts a kept Window record or starts a fresh
    // one; the core itself restores nothing yet (P5c).
    pub fn set_startup(&self, window_id: String, startup: StartupBehavior) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_startup(startup.into());
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn set_warn_before_quitting(&self, window_id: String, warn: bool) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_warn_before_quitting(warn);
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    // P5b: the General pane's download folder and ask-each-file switch, a device record (F3: the
    // folder is a path of this Mac, so it is not in the synced Settings and never enters the sync
    // journal). The app pushes it into Chromium's prefs at the launch's first window and after
    // every write; a folder the engine cannot use (a relative path) is refused here.
    pub fn download_device(&self) -> DownloadDevice {
        self.workspace.lock().unwrap().download_device.clone().into()
    }

    pub fn set_download_device(&self, device: DownloadDevice) -> Result<(), CoreError> {
        self.admit(true)?;
        let device: ararat_core::model::DownloadDevice = device.into();
        if let Some(reason) = device.invalid() {
            return Err(CoreError::Edit { message: reason.to_string() });
        }
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_download_device(device);
        self.store.write(ops);
        self.store.flush().map_err(Into::into)
    }

    pub fn little_window_device(&self) -> LittleWindowDevice {
        self.workspace.lock().unwrap().little_window_device.clone().into()
    }

    pub fn set_little_window_remember_frame(&self, remember: bool) -> Result<(), CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_little_window_remember_frame(remember);
        self.store.write(ops);
        self.store.flush().map_err(Into::into)
    }

    pub fn set_little_window_hot_key(&self, key: Option<LittleWindowHotKey>) -> Result<(), CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_little_window_hot_key(key.map(Into::into));
        self.store.write(ops);
        self.store.flush().map_err(Into::into)
    }

    pub fn last_error(&self) -> Option<String> {
        self.store.last_error()
    }

    // The live-tab coordinator (architecture 5.1/5.2). The commands and the transaction
    // application return the workspace ops they produced; the store writes each batch as
    // one transaction, and the lifecycle change of a close is flushed before the command
    // is handed to the engine. The open's map entry and its in-flight marker land only
    // after that flush succeeded.
    pub fn live_open(&self, item: String, url: String) -> Result<LiveCommand, CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        let mut live = self.live.lock().unwrap();
        let (ops, command) = live.open(&mut workspace, &item, &url)?;
        self.store.write(ops);
        self.store.flush()?;
        live.command_sent(&command);
        Ok(command.into())
    }

    pub fn live_activate(&self, item: String) -> Result<LiveCommand, CoreError> {
        self.admit(false)?;
        let workspace = self.workspace.lock().unwrap();
        let mut live = self.live.lock().unwrap();
        let command = live.activate(&workspace, &item)?;
        live.command_sent(&command);
        Ok(command.into())
    }

    pub fn live_selection_intent(&self, command_id: String, window_id: String) -> bool {
        self.live.lock().unwrap().selection_intent(&command_id, &window_id)
    }

    pub fn live_cancel(&self, command_id: String) -> bool {
        let mut workspace = self.workspace.lock().unwrap();
        let (cancelled, ops) = self.live.lock().unwrap().cancel(&mut workspace, &command_id);
        self.store.write(ops);
        cancelled
    }

    pub fn live_settle_close(&self, command_id: String) -> bool {
        self.live.lock().unwrap().settle_close(&command_id)
    }

    pub fn live_cancel_close(&self, command_id: String) -> Result<bool, CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        let (cancelled, ops) = self.live.lock().unwrap().cancel_close(&mut workspace, &command_id);
        self.store.write(ops);
        self.store.flush()?;
        Ok(cancelled)
    }

    pub fn live_close(&self, item: String) -> Result<LiveCommand, CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        let mut live = self.live.lock().unwrap();
        let (ops, command) = live.close(&mut workspace, &item)?;
        self.store.write(ops);
        self.store.flush()?;
        live.command_sent(&command);
        Ok(command.into())
    }

    pub fn live_close_split(&self, item: String) -> Result<Vec<LiveCloseTarget>, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let mut live = self.live.lock().unwrap();
        let (ops, commands) = live.close_split(&mut workspace, &item)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(commands.into_iter().map(|(live_id, command)| LiveCloseTarget { live_id, command: command.into() }).collect())
    }

    pub fn live_archive_split(&self, item: String) -> Result<Vec<LiveCloseTarget>, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let mut live = self.live.lock().unwrap();
        let (ops, commands) = live.archive_split(&mut workspace, &item)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(commands.into_iter().map(|(live_id, command)| LiveCloseTarget { live_id, command: command.into() }).collect())
    }

    pub fn live_archive(&self, item: String) -> Result<LiveCommand, CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        let mut live = self.live.lock().unwrap();
        let (ops, command) = live.archive(&mut workspace, &item)?;
        self.store.write(ops);
        self.store.flush()?;
        live.command_sent(&command);
        Ok(command.into())
    }

    pub fn live_auto_archive(&self, window_id: String, now: u64) -> Result<Option<LiveBatch>, CoreError> {
        if self.private { return Ok(None); }
        let mut workspace = self.workspace.lock().unwrap();
        let (ops, targets) = self.live.lock().unwrap().auto_archive(&mut workspace, now)?;
        if ops.is_empty() { return Ok(None); }
        self.store.write(ops);
        self.store.flush()?;
        Ok(Some(LiveBatch {
            snapshot: snapshot(workspace.clone(), &window_id),
            targets: targets.into_iter().map(|(live_id, command)| LiveCloseTarget { live_id, command: command.into() }).collect(),
        }))
    }

    pub fn live_delete_space(&self, window_id: String, space_id: String) -> Result<LiveBatch, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let (ops, targets) = self.live.lock().unwrap().delete_space(&mut workspace, &space_id)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(LiveBatch {
            snapshot: snapshot(workspace.clone(), &window_id),
            targets: targets.into_iter().map(|(live_id, command)| LiveCloseTarget { live_id, command: command.into() }).collect(),
        })
    }

    // Clear Today in one batch, with a Close command in flight for every mapped live row it
    // archives, so the engine's replies match commands (U25b D6).
    pub fn live_clear_today(&self, window_id: String, space_id: String) -> Result<LiveClearToday, CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        let mut live = self.live.lock().unwrap();
        let selected = workspace.selected(&window_id).map(str::to_owned);
        let (ops, targets, batch) = live.clear_today(&mut workspace, &space_id)?;
        let has_items = if self.private { !ops.is_empty() } else { !batch.items.is_empty() };
        self.store.write(ops);
        self.store.flush()?;
        Ok(LiveClearToday {
            snapshot: snapshot(workspace.clone(), &window_id),
            has_items,
            batch: (!self.private).then(|| std::sync::Arc::new(ClearTodayUndo { batch, selected })),
            targets: targets.into_iter()
                .map(|(live_id, command)| LiveCloseTarget { live_id, command: command.into() }).collect(),
        })
    }

    pub fn undo_clear_today(&self, window_id: String, undo: std::sync::Arc<ClearTodayUndo>) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(true)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.undo_clear_today(&window_id, &undo.batch, undo.selected.as_deref())?;
        let restored_selection = undo.selected.as_ref().filter(|id| ops.iter().any(|op| matches!(op, ararat_core::model::Op::Put(ararat_core::model::Record::Item(item)) if &item.id == *id && item.lifecycle == Lifecycle::Unloaded))).cloned();
        self.store.write(ops);
        self.store.flush()?;
        let mut result = snapshot(workspace.clone(), &window_id);
        if restored_selection.is_some() { result.selected_id = restored_selection; }
        Ok(result)
    }

    pub fn live_apply(&self, transaction: LiveTransaction) -> Result<LiveApplyOutcome, CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        let mut live = self.live.lock().unwrap();
        let (ops, outcome) = live.apply(&mut workspace, transaction.into());
        if let Some(error) = &outcome.error { return Err(error.clone().into()); }
        self.store.write(ops);
        let mut outcome: LiveApplyOutcome = outcome.into();
        outcome.persistence_error = self.store.flush().err().map(|error| error.0);
        Ok(outcome)
    }

    pub fn live_tab(&self, item: String) -> Option<String> {
        self.live.lock().unwrap().live_tab(&item)
    }

    pub fn live_window(&self, item: String) -> Option<String> {
        self.live.lock().unwrap().live_window(&item)
    }

    pub fn item_for_live(&self, live_id: String) -> Option<String> {
        self.live.lock().unwrap().item_for(&live_id)
    }

    pub fn live_dropped(&self) -> u64 {
        self.live.lock().unwrap().dropped()
    }
}

#[derive(Debug, PartialEq, uniffi::Enum)]
pub enum RowKind {
    Tab,
    Folder,
    Split,
    // The 24 pt line an open, empty folder shows at its child indent; not an item, so no
    // core call ever names one (its id is derived from the folder's).
    NoTabs,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum SplitPaneKind { Tab, SplitHorizontal, SplitVertical, Placeholder }

/// Which side of the focused pane a new pane joins, and which side a dragged row takes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SplitSide { Left, Right }

impl From<SplitSide> for ararat_core::model::SplitSide {
    fn from(side: SplitSide) -> Self {
        match side { SplitSide::Left => Self::Left, SplitSide::Right => Self::Right }
    }
}

/// A split op's snapshot, with the split it touched and the pane it added (or moved in).
#[derive(Debug, PartialEq, uniffi::Record)]
pub struct SplitChange {
    pub snapshot: WorkspaceSnapshot,
    pub split: String,
    pub pane: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SplitFactor { pub id: String, pub factor: f64 }

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SplitPane {
    pub id: String,
    pub factor: f64,
    pub kind: SplitPaneKind,
    pub unloaded: bool,
    pub url: Option<String>,
    pub children: Vec<SplitPane>,
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

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct HistoryPurge {
    pub id: String,
    pub profile: Profile,
    pub item: String,
    pub changed_at: u64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct HistoryAdmission {
    pub stamp: u64,
    pub purges: Vec<HistoryPurge>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct RestorationCandidate {
    pub id: String,
    pub url: String,
    pub space: String,
    pub profile: Profile,
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

// SwiftUI has a `Settings` scene, so the boundary type is named for the workspace it holds.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct WorkspaceSettings {
    pub new_tab_row_shown: bool,
    pub space_scroll_direction: SpaceScrollDirection,
    pub tooltips_shown: bool,
    pub little_window_open_in: LittleWindowOpenIn,
    pub little_window_close_after: bool,
    pub theme: Theme,
    pub site_defaults: SiteDefaults,
    /// U27p: the Privacy pane's cookies, GPC and history retention.
    pub privacy: PrivacySettings,
    /// P5b: what the first window of a launch does.
    pub startup: StartupBehavior,
    pub warn_before_quitting: bool,
}
impl From<ararat_core::model::Settings> for WorkspaceSettings {
    fn from(settings: ararat_core::model::Settings) -> Self {
        Self { new_tab_row_shown: settings.new_tab_row_shown,
            space_scroll_direction: settings.space_scroll_direction.into(),
            tooltips_shown: settings.tooltips_shown,
            little_window_open_in: settings.little_window_open_in.into(),
            little_window_close_after: settings.little_window_close_after,
            theme: settings.theme.into(),
            site_defaults: settings.site_defaults.into(),
            privacy: settings.privacy.into(),
            startup: settings.startup.into(), warn_before_quitting: settings.warn_before_quitting }
    }
}

/// U27w W1: one Chromium permission's default: Ask, Allow or Block. Pop-ups and sound only take
/// Allow or Block; the pane offers the two for those kinds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SitePermissionValue { Ask, Allow, Block }
impl From<ararat_core::model::SitePermissionValue> for SitePermissionValue {
    fn from(value: ararat_core::model::SitePermissionValue) -> Self {
        use ararat_core::model::SitePermissionValue as Core;
        match value { Core::Ask => Self::Ask, Core::Allow => Self::Allow, Core::Block => Self::Block }
    }
}
impl From<SitePermissionValue> for ararat_core::model::SitePermissionValue {
    fn from(value: SitePermissionValue) -> Self {
        use ararat_core::model::SitePermissionValue as Core;
        match value { SitePermissionValue::Ask => Core::Ask, SitePermissionValue::Allow => Core::Allow, SitePermissionValue::Block => Core::Block }
    }
}

/// U27w W1: the Websites pane's seven defaults, one synced settings record in the board's order.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SiteDefaults {
    pub camera: SitePermissionValue,
    pub microphone: SitePermissionValue,
    pub location: SitePermissionValue,
    pub notifications: SitePermissionValue,
    pub popups: SitePermissionValue,
    pub automatic_downloads: SitePermissionValue,
    pub sound: SitePermissionValue,
}
impl From<ararat_core::model::SiteDefaults> for SiteDefaults {
    fn from(value: ararat_core::model::SiteDefaults) -> Self {
        Self { camera: value.camera.into(), microphone: value.microphone.into(), location: value.location.into(),
            notifications: value.notifications.into(), popups: value.popups.into(),
            automatic_downloads: value.automatic_downloads.into(), sound: value.sound.into() }
    }
}
impl From<SiteDefaults> for ararat_core::model::SiteDefaults {
    fn from(value: SiteDefaults) -> Self {
        Self { camera: value.camera.into(), microphone: value.microphone.into(), location: value.location.into(),
            notifications: value.notifications.into(), popups: value.popups.into(),
            automatic_downloads: value.automatic_downloads.into(), sound: value.sound.into() }
    }
}

/// U27p P2: the Privacy pane's third-party cookie choice. Block writes Chromium's cookie-controls
/// pref; Allow writes its off mode, which allows third-party cookies outside private windows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ThirdPartyCookies { Block, Allow }
impl From<ararat_core::model::ThirdPartyCookies> for ThirdPartyCookies {
    fn from(value: ararat_core::model::ThirdPartyCookies) -> Self {
        use ararat_core::model::ThirdPartyCookies as Core;
        match value { Core::Block => Self::Block, Core::Allow => Self::Allow }
    }
}
impl From<ThirdPartyCookies> for ararat_core::model::ThirdPartyCookies {
    fn from(value: ThirdPartyCookies) -> Self {
        use ararat_core::model::ThirdPartyCookies as Core;
        match value { ThirdPartyCookies::Block => Core::Block, ThirdPartyCookies::Allow => Core::Allow }
    }
}

/// U27p P3: how long browsing history is kept, the board's five choices. `Forever` keeps every
/// visit; the engine's expiry reads the rest as days.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum HistoryRetention { Week, Month, ThreeMonths, Year, Forever }
impl From<ararat_core::model::HistoryRetention> for HistoryRetention {
    fn from(value: ararat_core::model::HistoryRetention) -> Self {
        use ararat_core::model::HistoryRetention as Core;
        match value {
            Core::Week => Self::Week, Core::Month => Self::Month, Core::ThreeMonths => Self::ThreeMonths,
            Core::Year => Self::Year, Core::Forever => Self::Forever,
        }
    }
}
impl From<HistoryRetention> for ararat_core::model::HistoryRetention {
    fn from(value: HistoryRetention) -> Self {
        use ararat_core::model::HistoryRetention as Core;
        match value {
            HistoryRetention::Week => Core::Week, HistoryRetention::Month => Core::Month,
            HistoryRetention::ThreeMonths => Core::ThreeMonths, HistoryRetention::Year => Core::Year,
            HistoryRetention::Forever => Core::Forever,
        }
    }
}

/// U27p P2/P3: the Privacy pane's one synced record: the cookie choice, the Global Privacy
/// Control signal and the history retention.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PrivacySettings {
    pub third_party_cookies: ThirdPartyCookies,
    pub global_privacy_control: bool,
    pub history_retention: HistoryRetention,
}
impl From<ararat_core::model::PrivacySettings> for PrivacySettings {
    fn from(value: ararat_core::model::PrivacySettings) -> Self {
        Self { third_party_cookies: value.third_party_cookies.into(),
            global_privacy_control: value.global_privacy_control,
            history_retention: value.history_retention.into() }
    }
}
impl From<PrivacySettings> for ararat_core::model::PrivacySettings {
    fn from(value: PrivacySettings) -> Self {
        Self { third_party_cookies: value.third_party_cookies.into(),
            global_privacy_control: value.global_privacy_control,
            history_retention: value.history_retention.into() }
    }
}

/// U27i D9: the Little Window's Open-in destination, the profile's most recent space or one
/// space by name (the pane lists the spaces a Little Window of that profile can reach).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum LittleWindowOpenIn { MostRecent, Space(String) }
impl From<ararat_core::model::LittleWindowOpenIn> for LittleWindowOpenIn {
    fn from(value: ararat_core::model::LittleWindowOpenIn) -> Self {
        match value {
            ararat_core::model::LittleWindowOpenIn::MostRecent => Self::MostRecent,
            ararat_core::model::LittleWindowOpenIn::Space(id) => Self::Space(id),
        }
    }
}
impl From<LittleWindowOpenIn> for ararat_core::model::LittleWindowOpenIn {
    fn from(value: LittleWindowOpenIn) -> Self {
        match value {
            LittleWindowOpenIn::MostRecent => Self::MostRecent,
            LittleWindowOpenIn::Space(id) => Self::Space(id),
        }
    }
}

/// The Spaces pane's Natural / Reversed choice (D3). Natural keeps today's behaviour: the wheel
/// cancels the system's natural-scrolling inversion and a trackpad gesture keeps its sign.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SpaceScrollDirection { Natural, Reversed }
impl From<ararat_core::model::SpaceScrollDirection> for SpaceScrollDirection {
    fn from(value: ararat_core::model::SpaceScrollDirection) -> Self {
        use ararat_core::model::SpaceScrollDirection as Core;
        match value { Core::Natural => Self::Natural, Core::Reversed => Self::Reversed }
    }
}
impl From<SpaceScrollDirection> for ararat_core::model::SpaceScrollDirection {
    fn from(value: SpaceScrollDirection) -> Self {
        use ararat_core::model::SpaceScrollDirection as Core;
        match value { SpaceScrollDirection::Natural => Core::Natural, SpaceScrollDirection::Reversed => Core::Reversed }
    }
}

/// U27k: the Appearance pane's Theme (D5). System follows the Mac, Light and Dark force one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Theme { System, Light, Dark }
impl From<ararat_core::model::Theme> for Theme {
    fn from(value: ararat_core::model::Theme) -> Self {
        use ararat_core::model::Theme as Core;
        match value { Core::System => Self::System, Core::Light => Self::Light, Core::Dark => Self::Dark }
    }
}
impl From<Theme> for ararat_core::model::Theme {
    fn from(value: Theme) -> Self {
        use ararat_core::model::Theme as Core;
        match value { Theme::System => Core::System, Theme::Light => Core::Light, Theme::Dark => Core::Dark }
    }
}

/// P5b: what launching Ararat does with the kept windows. RestoreWindows is the behaviour before
/// the setting and the pane's default; NewWindow starts one fresh window on the most recent space.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum StartupBehavior { RestoreWindows, NewWindow }
impl From<ararat_core::model::StartupBehavior> for StartupBehavior {
    fn from(value: ararat_core::model::StartupBehavior) -> Self {
        use ararat_core::model::StartupBehavior as Core;
        match value { Core::RestoreWindows => Self::RestoreWindows, Core::NewWindow => Self::NewWindow }
    }
}
impl From<StartupBehavior> for ararat_core::model::StartupBehavior {
    fn from(value: StartupBehavior) -> Self {
        use ararat_core::model::StartupBehavior as Core;
        match value { StartupBehavior::RestoreWindows => Core::RestoreWindows, StartupBehavior::NewWindow => Core::NewWindow }
    }
}

/// P5b: Settings › General's downloads rows as the pane reads and writes them: the folder Chromium
/// saves to (empty is Chromium's own Downloads default) and whether it asks where to save each
/// file. A device record in the core (DownloadDevice), so the folder of this Mac never enters the
/// sync journal.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct DownloadDevice {
    pub directory: String,
    pub ask_where_to_save: bool,
}
impl From<ararat_core::model::DownloadDevice> for DownloadDevice {
    fn from(value: ararat_core::model::DownloadDevice) -> Self {
        Self { directory: value.directory, ask_where_to_save: value.ask_where_to_save }
    }
}
impl From<DownloadDevice> for ararat_core::model::DownloadDevice {
    fn from(value: DownloadDevice) -> Self {
        Self { directory: value.directory, ask_where_to_save: value.ask_where_to_save }
    }
}

// U27h D8: the Little Window's frame on this device.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct LittleWindowFrame {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl From<ararat_core::model::LittleWindowFrame> for LittleWindowFrame {
    fn from(frame: ararat_core::model::LittleWindowFrame) -> Self {
        Self { x: frame.x, y: frame.y, width: frame.width, height: frame.height }
    }
}

impl From<LittleWindowFrame> for ararat_core::model::LittleWindowFrame {
    fn from(frame: LittleWindowFrame) -> Self {
        Self { x: frame.x, y: frame.y, width: frame.width, height: frame.height }
    }
}

// U27i D8/O3: the Little Window's global shortcut on this device, flattened so the record needs
// no nested boundary type. `key_code` is the Carbon virtual key code the registrar registers;
// the rest is the combination its keycaps show.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LittleWindowHotKey {
    pub key_code: u16,
    pub key: String,
    pub command: bool,
    pub control: bool,
    pub option: bool,
    pub shift: bool,
}

impl From<ararat_core::model::LittleWindowHotKey> for LittleWindowHotKey {
    fn from(value: ararat_core::model::LittleWindowHotKey) -> Self {
        Self { key_code: value.key_code, key: value.combination.key, command: value.combination.command,
            control: value.combination.control, option: value.combination.option, shift: value.combination.shift }
    }
}

impl From<LittleWindowHotKey> for ararat_core::model::LittleWindowHotKey {
    fn from(value: LittleWindowHotKey) -> Self {
        Self { key_code: value.key_code,
            combination: ararat_core::key_bindings::KeyCombination { key: value.key, command: value.command,
                control: value.control, option: value.option, shift: value.shift } }
    }
}

/// U27i D8: the Little Window's per-device switches. `hot_key` nil is the user's "no global
/// shortcut"; no record at all is the built-in state, which the store reports as the default.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LittleWindowDevice {
    pub remember_frame: bool,
    pub hot_key: Option<LittleWindowHotKey>,
}

impl From<ararat_core::model::LittleWindowDevice> for LittleWindowDevice {
    fn from(value: ararat_core::model::LittleWindowDevice) -> Self {
        Self { remember_frame: value.remember_frame, hot_key: value.hot_key.map(Into::into) }
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
    // U25b D1: the space.s pinned section, seeded with the space so every window shows the
    // same chevron without a second read.
    pub pinned_collapsed: bool,
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

#[derive(uniffi::Record)]
pub struct SwitcherThumbnailSpace {
    pub id: String,
    pub profile: String,
    pub items: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct WindowPresentation {
    pub frame: Option<LittleWindowFrame>,
    pub sidebar_width: Option<f64>,
    pub sidebar_hidden: bool,
}

#[derive(Debug, PartialEq, uniffi::Record)]
pub struct KeptWindow {
    pub id: String,
    pub changed_at: u64,
    pub presentation: WindowPresentation,
    /// P5b: where this record's window last was — the same space a launch that adopts it would
    /// show, so Open a new window opens there too (review 1 F9).
    pub shown_space: Option<String>,
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
    pub skipped_favourites_by_profile: HashMap<String, u64>,
    pub missing_windows: bool,
    pub windows_error: Option<String>,
    pub differing_folder_states: u64,
    pub skipped_dates: u64,
    pub peeked_folders: u64,
    pub unknown_window_ids: u64,
    pub malformed_window_entries: u64,
    // What the import produced, counted from the imported workspace (import.rs): the done screen
    // shows these rather than the store's totals.
    pub spaces: u64,
    pub pinned_tabs: u64,
    pub folders: u64,
    pub favourite_tabs: u64,
    pub spaces_with_look: u64,
}

impl From<import::ImportReport> for ImportReport {
    fn from(report: import::ImportReport) -> Self {
        Self { missing_link_routing: report.missing_link_routing, link_routing_error: report.link_routing_error,
            imported_rules: report.imported_rules as u64, skipped_profile_destinations: report.skipped_profile_destinations as u64,
            skipped_unknown_destinations: report.skipped_unknown_destinations as u64, skipped_unknown_styles: report.skipped_unknown_styles as u64,
            skipped_favourites_by_profile: report.skipped_favourites_by_profile.into_iter().map(|(name, count)| (name, count as u64)).collect(),
            malformed_rules: report.malformed_rules as u64,
            missing_key_bindings: report.missing_key_bindings, key_bindings_error: report.key_bindings_error, skipped_key_bindings: report.skipped_key_bindings as u64, unknown_space_looks: report.unknown_space_looks as u64, missing_windows: report.missing_windows,
            windows_error: report.windows_error, differing_folder_states: report.differing_folder_states as u64,
            skipped_dates: report.skipped_dates as u64, peeked_folders: report.peeked_folders as u64,
            unknown_window_ids: report.unknown_window_ids as u64, malformed_window_entries: report.malformed_window_entries as u64,
            spaces: report.spaces as u64, pinned_tabs: report.pinned_tabs as u64, folders: report.folders as u64,
            favourite_tabs: report.favourite_tabs as u64, spaces_with_look: report.spaces_with_look as u64 }
    }
}

#[derive(Debug, PartialEq, uniffi::Record)]
pub struct ImportResult {
    pub snapshot: WorkspaceSnapshot,
    pub report: ImportReport,
}

// Snapshots cross the FFI boundary instead of the core's types, so Swift cannot come to
// depend on the core's internal representation.
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
    pub profile: Profile,
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

// A destination whose space is gone: the rule beside it (None for the default) and the id
// the destination still names.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DeletedDestination {
    pub rule_id: Option<String>,
    pub space_id: String,
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
        Self { id: rule.id, conditions: rule.conditions.into_iter().map(Into::into).collect(), destination: rule.destination.into(), profile: rule.profile.into() }
    }
}
impl From<Rule> for ararat_core::routing::Rule {
    fn from(rule: Rule) -> Self {
        Self { id: rule.id, conditions: rule.conditions.into_iter().map(Into::into).collect(), destination: rule.destination.into(), profile: rule.profile.into() }
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LiveCommandKind { Open, Activate, Close }

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LiveCommand {
    pub id: String,
    pub kind: LiveCommandKind,
    pub item: String,
    pub url: Option<String>,
    pub target_window: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LiveCloseTarget {
    pub live_id: String,
    pub command: LiveCommand,
}

// Clear Today: the batch's snapshot, with the live tabs whose pages the caller closes (each
// beside a Close command the core has in flight).
#[derive(uniffi::Object)]
pub struct ClearTodayUndo {
    batch: ararat_core::edit::ClearTodayBatch,
    selected: Option<String>,
}

#[derive(uniffi::Record)]
pub struct ClearTodayResult {
    pub snapshot: WorkspaceSnapshot,
    pub batch: Option<std::sync::Arc<ClearTodayUndo>>,
}

#[derive(Debug, PartialEq, uniffi::Record)]
pub struct LiveBatch {
    pub snapshot: WorkspaceSnapshot,
    pub targets: Vec<LiveCloseTarget>,
}

#[derive(uniffi::Record)]
pub struct LiveClearToday {
    pub snapshot: WorkspaceSnapshot,
    pub targets: Vec<LiveCloseTarget>,
    pub batch: Option<std::sync::Arc<ClearTodayUndo>>,
    pub has_items: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum LiveCause {
    /// The engine's reply to the command with this id.
    Command(String),
    /// The engine changed something on its own call.
    Engine,
    /// Chrome changed something on its own.
    Chrome,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LiveTab {
    pub off_the_record: bool,
    pub profile: Profile,
    pub live_id: String,
    pub item: Option<String>,
    pub opener: Option<String>,
    pub navigated: bool,
    pub url: Option<String>,
    pub title: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LiveStrip {
    pub window: String,
    pub tabs: Vec<LiveTab>,
    pub active: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LiveTransaction {
    pub off_the_record: bool,
    pub epoch: u64,
    pub rev: u64,
    pub cause: LiveCause,
    pub strips: Vec<LiveStrip>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LiveAdoptedTab {
    pub live_id: String,
    pub item: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LiveApplyOutcome {
    /// False: the transaction was stale, from an old epoch, or conflicted with the map.
    pub applied: bool,
    /// Closes and activates the apply produced beside the workspace ops.
    pub commands: Vec<LiveCommand>,
    /// Live tabs the apply adopted, beside the items it created for them.
    pub adopted: Vec<LiveAdoptedTab>,
    pub persistence_error: Option<String>,
}

impl From<ararat_core::live::Command> for LiveCommand {
    fn from(command: ararat_core::live::Command) -> Self {
        Self {
            id: command.id,
            kind: match command.kind {
                ararat_core::live::CommandKind::Open => LiveCommandKind::Open,
                ararat_core::live::CommandKind::Activate => LiveCommandKind::Activate,
                ararat_core::live::CommandKind::Close => LiveCommandKind::Close,
            },
            item: command.item,
            url: command.url,
            target_window: command.target_window,
        }
    }
}

impl From<LiveCause> for ararat_core::live::Cause {
    fn from(cause: LiveCause) -> Self {
        match cause {
            LiveCause::Command(id) => ararat_core::live::Cause::Command(id),
            LiveCause::Engine => ararat_core::live::Cause::Engine,
            LiveCause::Chrome => ararat_core::live::Cause::Chrome,
        }
    }
}

impl From<LiveTab> for ararat_core::live::LiveTab {
    fn from(tab: LiveTab) -> Self {
        Self { off_the_record: tab.off_the_record, profile: tab.profile.into(), live_id: tab.live_id, item: tab.item, opener: tab.opener, navigated: tab.navigated, url: tab.url, title: tab.title }
    }
}

impl From<LiveStrip> for ararat_core::live::Strip {
    fn from(strip: LiveStrip) -> Self {
        Self {
            window: strip.window,
            tabs: strip.tabs.into_iter().map(Into::into).collect(),
            active: strip.active,
        }
    }
}

impl From<LiveTransaction> for ararat_core::live::Transaction {
    fn from(transaction: LiveTransaction) -> Self {
        Self {
            off_the_record: transaction.off_the_record,
            epoch: transaction.epoch,
            rev: transaction.rev,
            cause: transaction.cause.into(),
            strips: transaction.strips.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<ararat_core::live::ApplyOutcome> for LiveApplyOutcome {
    fn from(outcome: ararat_core::live::ApplyOutcome) -> Self {
        Self {
            applied: outcome.applied,
            commands: outcome.commands.into_iter().map(Into::into).collect(),
            adopted: outcome.adopted.into_iter()
                .map(|(live_id, item)| LiveAdoptedTab { live_id, item }).collect(),
            persistence_error: None,
        }
    }
}

#[uniffi::export]
pub fn import_arc_sidebar(json: String, windows_json: Option<String>, key_bindings_json: Option<String>, link_routing_json: Option<String>, owner_profile: Option<Profile>) -> Result<ImportResult, CoreError> {
    let (ws, report) = import::arc_sidebar(&json, windows_json.as_deref(), key_bindings_json.as_deref(), link_routing_json.as_deref(), owner_profile.map(Into::into)).map_err(|e| CoreError::Import { message: e.0 })?;
    Ok(ImportResult { snapshot: snapshot(ws, ""), report: report.into() })
}

// Arc's StorableLinkRouting.json on its own, for the pane and tests; the sibling import
// (import_arc_sidebar) calls the core function directly. `spaces` is the space set the
// sidebar import produced, each beside the profile it rides in: a destination is judged on
// both — only a known id of the owner's profile can open, and with no owner named, only the
// id being known does.
#[uniffi::export]
pub fn arc_link_routing(json: String, profile: Option<Profile>, spaces: Vec<SpaceProfile>) -> Result<LinkRoutingImport, CoreError> {
    let known = spaces.into_iter().map(|space| (space.id, space.profile.into())).collect::<Vec<(Id, ararat_core::model::Profile)>>();
    let (routing, report) = import::arc_link_routing(&json, profile.map(Into::into), &known)
        .map_err(|e| CoreError::Import { message: e.0 })?;
    Ok(LinkRoutingImport { routing: routing.into(), report: report.into() })
}

// A space the sidebar import produced, beside the profile the file carries for it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SpaceProfile {
    pub id: String,
    pub profile: Profile,
}

fn split_pane(ws: &Workspace, id: &str, factor: f64) -> Option<SplitPane> {
    let item = ws.items.get(id)?;
    let (kind, url) = match &item.kind {
        ItemKind::Tab { url, .. } => (SplitPaneKind::Tab, Some(url.clone())),
        ItemKind::Split { orientation: ararat_core::model::Orientation::Horizontal, .. } => (SplitPaneKind::SplitHorizontal, None),
        ItemKind::Split { orientation: ararat_core::model::Orientation::Vertical, .. } => (SplitPaneKind::SplitVertical, None),
        _ => (SplitPaneKind::Placeholder, None),
    };
    let children = ws.split_factors(id).unwrap_or_default().into_iter()
        .filter_map(|(child, factor)| split_pane(ws, &child, factor)).collect();
    Some(SplitPane { id: id.into(), factor, kind, unloaded: item.lifecycle == Lifecycle::Unloaded, url, children })
}

// Choosing a row ignores collapse (design's decision 3, read by review 2 as everything):
// the candidates are the space's rows as if nothing were folded — the pinned section's
// record and the folders' — and the holder rule keeps the chosen pin's path visible in the
// snapshot the caller gets back. Selection is the user's explicit pick; the close successor
// is an automatic one and still skips a closed folder's tabs (is_selectable reads the
// folder state).
fn selection_view(workspace: &Workspace, window_id: &str) -> WorkspaceSnapshot {
    let mut view = workspace.clone();
    view.section_collapsed.clear();
    view.folder_collapsed.clear();
    snapshot(view, window_id)
}

fn snapshot(mut view: Workspace, window_id: &str) -> WorkspaceSnapshot {
    view.repair_tree();
    let profile = view.shown_space(window_id).and_then(|id| view.spaces.iter().find(|space| space.id == id)).map(|space| &space.profile);
    let archive = view.archive().into_iter().filter(|item| view.archive_profile(&item.id) == profile).map(|item| {
        let members: Vec<_> = view.archived_members(&item.id).into_iter()
            .filter_map(|member| match &member.kind { ItemKind::Tab { url, .. } => Some((member.display_title(), url.as_str())), _ => None }).collect();
        let (title, url) = match &item.kind {
            ItemKind::Tab { url, .. } => (item.display_title().to_string(), url.clone()),
            _ => (members.iter().map(|(title, _)| *title).collect::<Vec<_>>().join(" / "), members.first().map(|(_, url)| url.to_string()).unwrap_or_default()),
        };
        ArchiveEntry { id: item.id.clone(), title, url, lifecycle_changed_at: item.lifecycle_changed_at }
    }).collect();
    // The window's current row, so a collapsed holder (folder or pinned section) keeps it
    // visible in this window's rows.
    let current = view.selected(window_id);
    WorkspaceSnapshot { archive, shown_space_id: view.shown_space(window_id).map(str::to_string), selected_id: view.selected(window_id).filter(|id| view.items.get(*id).is_some_and(|item| item.lifecycle == Lifecycle::Open && matches!(item.kind, ItemKind::Tab { .. } | ItemKind::Split { .. }))).map(str::to_string), spaces: view.spaces.iter().map(|s| space(&view, s, current)).collect() }
}

fn space(ws: &Workspace, s: &Space, current: Option<&str>) -> SpaceSnapshot {
    SpaceSnapshot {
        pinned_count: ws.children(&s.pinned).into_iter().filter(|i| matches!(i.lifecycle, Lifecycle::Open | Lifecycle::Unloaded)).count() as u32,
        today_count: ws.children(&s.today).into_iter().filter(|i| matches!(i.lifecycle, Lifecycle::Open | Lifecycle::Unloaded)).count() as u32,
        profile_key: format!("{:?}", s.profile),
        pinned_id: s.pinned.clone(),
        today_id: s.today.clone(),
        favorites_id: s.favorites.clone(),
        archive_after: ws.archive_after.get(&s.profile).copied().unwrap_or_default().into(),
        profile_name: match &s.profile { ararat_core::model::Profile::Default => "Default".into(), ararat_core::model::Profile::Named(name) => name.clone() },
        profile: s.profile.clone().into(),
        id: s.id.clone(),
        title: s.title.clone(),
        icon: s.icon.clone(),
        look: s.look.clone().map(Into::into),
        pinned_collapsed: ws.is_section_collapsed(&s.id),
        // The pinned list is the one container a collapse record governs, and the one that
        // keeps the current row visible when it is collapsed; Today holds no folders.
        favorites: s.favorites.as_ref().map_or_else(Vec::new, |container| rows(ws, container, None)),
        pinned: rows(ws, &s.pinned, current),
        today: rows(ws, &s.today, None),
    }
}

// One container's rows for the sidebar, with the "No tabs" marker an open, empty folder
// shows under itself (its 24 pt line is the UI's).
fn rows(ws: &Workspace, container: &str, current: Option<&str>) -> Vec<Row> {
    let entries = ws.outline_keeping(container, current);
    let mut rows: Vec<Row> = Vec::with_capacity(entries.len());
    for (index, (depth, item)) in entries.iter().enumerate() {
        let Some(row) = row(ws, *depth, item) else { continue };
        let marker = row.kind == RowKind::Folder && !row.collapsed && !row.folder_has_tabs
            && !entries.get(index + 1).is_some_and(|(next, _)| next > depth);
        let id = row.id.clone();
        rows.push(row);
        if marker {
            rows.push(Row {
                folder_has_tabs: false,
                parent_id: id.clone(),
                sibling_index: 0,
                collapsed: false,
                id: format!("{id}/no-tabs"),
                title: "No tabs".into(),
                url: None,
                depth: (*depth + 1) as u32,
                kind: RowKind::NoTabs,
                unloaded: false,
                last_selected_at: None,
            });
        }
    }
    rows
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
    fn private_transactions_validate_before_epoch_and_live_closes_remove_rows() {
        let store = WorkspaceStore::open_private(Profile::Default);
        let tab = |live: &str| LiveTab { off_the_record: true, profile: Profile::Default, live_id: live.into(), item: None, opener: None, navigated: true, url: Some(format!("https://{live}.example/")), title: None };
        let mut tx = LiveTransaction { off_the_record: false, epoch: 1, rev: 0, cause: LiveCause::Chrome, strips: vec![LiveStrip { window: "w".into(), tabs: vec![tab("one"), tab("two")], active: Some("one".into()) }] };
        assert!(matches!(store.live_apply(tx.clone()), Err(CoreError::Live { .. })));
        tx.off_the_record = true;
        tx.strips[0].tabs[0].profile = Profile::Named("other".into());
        assert!(matches!(store.live_apply(tx.clone()), Err(CoreError::Live { .. })));
        tx.strips[0].tabs[0].profile = Profile::Default;
        tx.rev = 1;
        assert!(!store.live_apply(tx.clone()).unwrap().applied);
        assert!(store.snapshot("w".into()).spaces[0].today.is_empty());
        tx.rev = 0;
        let applied = store.live_apply(tx).unwrap();
        assert!(applied.applied);
        assert_eq!(applied.adopted.len(), 2);
        let before = store.snapshot("w".into());
        assert!(store.live_auto_archive("w".into(), u64::MAX).unwrap().is_none());
        assert!(store.live_delete_space("w".into(), "private".into()).is_err());
        assert_eq!(store.snapshot("w".into()), before);
        let first = applied.adopted.iter().find(|tab| tab.live_id == "one").unwrap().item.clone();
        let second = applied.adopted.iter().find(|tab| tab.live_id == "two").unwrap().item.clone();
        store.live_close(first).unwrap();
        store.live_archive(second).unwrap();
        let after = store.snapshot("w".into());
        assert!(after.spaces[0].today.is_empty());
        assert!(after.archive.is_empty());
        assert!(store.pending_history_purges().unwrap().is_empty());
        assert!(store.workspace.lock().unwrap().last_selected.is_empty());
    }

    #[test]
    fn private_live_transactions_do_not_learn_or_create_history() {
        let store = WorkspaceStore::open_private(Profile::Default);
        let tab = |id: &str| LiveTab { off_the_record: true, profile: Profile::Default, live_id: id.into(), item: None, opener: None, navigated: true, url: Some(format!("https://{id}.example/")), title: None };
        let tx = LiveTransaction { off_the_record: true, epoch: 1, rev: 0, cause: LiveCause::Chrome, strips: vec![LiveStrip { window: "w".into(), tabs: vec![tab("first"), tab("second")], active: Some("first".into()) }] };
        let result = store.live_apply(tx).unwrap();
        assert_eq!(result.adopted.len(), 2);
        let workspace = store.workspace.lock().unwrap();
        assert!(workspace.last_selected.is_empty());
        assert!(workspace.windows.values().all(|window| window.history.is_empty()));
        drop(workspace);
        let suggestions = store.command_bar_session("w".into(), false).query("second".into(), vec![]);
        assert!(suggestions.private_window);
        assert!(suggestions.rows.iter().any(|row| matches!(row.target, SuggestionTarget::Tab { .. })));
        let clear = store.live_clear_today("w".into(), "private".into()).unwrap();
        assert_eq!(clear.targets.len(), 2);
        assert!(clear.has_items);
        assert!(clear.batch.is_none());
        assert!(clear.snapshot.archive.is_empty() && clear.snapshot.spaces[0].today.is_empty());
        assert!(store.pending_history_purges().unwrap().is_empty());
    }

    #[test]
    fn pane_ops_admit_only_the_private_today_and_refuse_foreign_items() {
        let store = WorkspaceStore::open_private(Profile::Default);
        let window: String = "w".into();
        // The rows the sidebar draws: a split is one row and its members are not rows of their own.
        fn rows(snapshot: &WorkspaceSnapshot) -> Vec<String> {
            let space = &snapshot.spaces[0];
            let all: Vec<&Row> = space.pinned.iter().chain(&space.today).collect();
            let splits: Vec<&str> = all.iter().filter(|row| row.kind == RowKind::Split).map(|row| row.id.as_str()).collect();
            all.iter().filter(|row| {
                let mut parent = row.parent_id.as_str();
                while let Some(ancestor) = all.iter().find(|other| other.id == parent) {
                    if splits.contains(&ancestor.id.as_str()) { return false; }
                    parent = ancestor.parent_id.as_str();
                }
                true
            }).map(|row| row.id.clone()).collect()
        }
        let first = store.create_tab(window.clone(), "https://one.example/".into()).unwrap().selected_id.unwrap();
        let second = store.create_tab(window.clone(), "https://two.example/".into()).unwrap().selected_id.unwrap();
        // A Today row: the private workspace's one list, so the pane ops are admitted.
        let added = store.add_split_pane(window.clone(), first.clone(), SplitSide::Left).unwrap();
        let split = added.split.clone();
        let pane = added.pane.clone();
        assert_ne!(pane, first);
        assert_eq!(rows(&added.snapshot), [second.clone(), split.clone()]);
        let next = store.add_split_pane(window.clone(), first.clone(), SplitSide::Right).unwrap().pane;
        // The pane becomes a row right after the split row and the split keeps two panes.
        assert_eq!(rows(&store.separate_pane(window.clone(), pane.clone()).unwrap()), [second.clone(), split.clone(), pane.clone()]);
        assert_eq!(rows(&store.convert_split(window.clone(), split.clone()).unwrap())[1], split);
        // Drag-to-split from two Today rows, and a refused drop leaves everything as it was.
        let made = store.make_split(window.clone(), second.clone(), pane.clone(), SplitSide::Left).unwrap();
        assert_ne!(made.split, split);
        assert_eq!(rows(&made.snapshot), [split.clone(), made.split.clone()]);
        let before = store.snapshot(window.clone());
        assert!(matches!(store.make_split(window.clone(), second.clone(), "tab-b".into(), SplitSide::Left), Err(CoreError::Edit { .. })));
        assert_eq!(store.snapshot(window.clone()), before);
        // The same rows in a pinned split are outside the private Today: every pane op refuses.
        {
            let mut workspace = store.workspace.lock().unwrap();
            let pinned = workspace.spaces[0].pinned.clone();
            let mut item = workspace.items[&split].clone();
            item.membership.parent = Some(pinned);
            workspace.items.insert(split.clone(), item);
        }
        let refused: Vec<CoreError> = vec![
            store.add_split_pane(window.clone(), first.clone(), SplitSide::Right).map(|_| ()).unwrap_err(),
            store.separate_pane(window.clone(), first.clone()).map(|_| ()).unwrap_err(),
            store.make_split(window.clone(), first.clone(), pane.clone(), SplitSide::Right).map(|_| ()).unwrap_err(),
            store.convert_split(window.clone(), split.clone()).map(|_| ()).unwrap_err(),
            store.move_pane(window.clone(), first.clone(), true).map(|_| ()).unwrap_err(),
        ];
        assert!(refused.iter().all(|error| matches!(error, CoreError::Edit { .. })), "{refused:?}");
        // Foreign items are refused the same way, and nothing was written.
        assert!(matches!(store.add_split_pane(window.clone(), "tab-a".into(), SplitSide::Left), Err(CoreError::Edit { .. })));
        assert!(matches!(store.separate_pane(window.clone(), "close-split-a".into()), Err(CoreError::Edit { .. })));
        assert!(matches!(store.convert_split(window.clone(), "tab-b".into()), Err(CoreError::Edit { .. })));
        assert_eq!(store.workspace.lock().unwrap().items.get("tab-a"), None);
        // Back in Today the same pane ops are admitted again.
        {
            let mut workspace = store.workspace.lock().unwrap();
            let today = workspace.spaces[0].today.clone();
            let mut item = workspace.items[&split].clone();
            item.membership.parent = Some(today);
            workspace.items.insert(split.clone(), item);
        }
        assert!(store.separate_pane(window.clone(), first.clone()).is_ok());
        // The split left with one pane became that pane's tab, so it is gone by now.
        assert!(!store.workspace.lock().unwrap().items.contains_key(&split));
        assert!(store.workspace.lock().unwrap().items.contains_key(&next));
    }

    #[test]
    fn transaction_conversion_preserves_privacy_flags() {
        let transaction = LiveTransaction { off_the_record: true, epoch: 1, rev: 0, cause: LiveCause::Engine, strips: vec![LiveStrip { window: "one".into(), tabs: vec![LiveTab { off_the_record: true, profile: Profile::Default, live_id: "live".into(), item: None, opener: None, navigated: false, url: None, title: None }], active: None }] };
        let core: ararat_core::live::Transaction = transaction.into();
        assert!(core.off_the_record);
        assert!(core.strips[0].tabs[0].off_the_record);
    }

    #[test]
    fn purge_acknowledgement_cannot_erase_a_later_obligation() {
        let path = std::env::temp_dir().join(format!("ararat-ffi-purge-{}.sqlite", std::process::id()));
        assert!(!path.exists());
        let store = WorkspaceStore::open(path.to_string_lossy().into_owned()).unwrap();
        store.create_space("one".into(), "Work".into(), "work".into()).unwrap();
        let item = store.create_tab("one".into(), "https://example.test/".into()).unwrap().selected_id.unwrap();
        store.archive_item("one".into(), item.clone()).unwrap();
        let first = store.pending_history_purges().unwrap().pop().unwrap();
        assert_eq!(first.item, item);
        let admission = store.history_admission(item.clone());
        assert_eq!(admission.purges, vec![first.clone()]);
        assert_eq!(admission.stamp, first.changed_at);
        store.restore_item("one".into(), item.clone()).unwrap();
        assert!(store.history_admission(item.clone()).stamp > first.changed_at);
        store.archive_item("one".into(), item.clone()).unwrap();
        assert_eq!(store.pending_history_purges().unwrap().len(), 2);
        store.acknowledge_history_purge(first.id.clone()).unwrap();
        let remaining = store.pending_history_purges().unwrap();
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].item, item);
        assert_ne!(remaining[0].id, first.id);
        drop(store);
        let reopened = WorkspaceStore::open(path.to_string_lossy().into_owned()).unwrap();
        assert_eq!(reopened.pending_history_purges().unwrap(), remaining);
        drop(reopened);
        for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
    }

    #[test]
    fn restoration_candidate_survives_empty_epoch_and_rejects_stale_items() {
        let path = std::env::temp_dir().join(format!("ararat-ffi-restore-candidate-{}.sqlite", std::process::id()));
        assert!(!path.exists());
        let store = WorkspaceStore::open(path.to_string_lossy().into_owned()).unwrap();
        store.import_arc_sidebar("one".into(), include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json").into(), None, None, None, None).unwrap();
        store.show_space("one".into(), "space-home".into()).unwrap();
        let id = store.create_tab("one".into(), "https://restore.example/".into()).unwrap().selected_id.unwrap();
        let candidate = store.restoration_candidate("one".into()).unwrap();
        assert_eq!(candidate.id, id);
        assert_eq!(candidate.profile, Profile::Named("Profile 1".into()));
        assert_eq!(store.restoration_candidate("missing".into()), None);
        store.live_apply(LiveTransaction { off_the_record: false, epoch: 1, rev: 0, cause: LiveCause::Engine,
            strips: vec![] }).unwrap();
        assert_eq!(store.snapshot("one".into()).selected_id, None);
        assert_eq!(store.restoration_candidate("one".into()), Some(candidate));
        store.select_item("one".into(), id.clone()).unwrap();
        let command = store.live_open(id.clone(), "https://restore.example/".into()).unwrap();
        assert_eq!(store.live_tab(id.clone()), Some(command.id.clone()));
        assert!(store.live_cancel(command.id.clone()));
        assert!(!store.live_cancel(command.id));
        assert_eq!(store.live_tab(id.clone()), None);
        assert_eq!(store.workspace.lock().unwrap().items[&id].lifecycle, Lifecycle::Unloaded);
        assert!(store.snapshot("one".into()).spaces.iter().flat_map(|space| &space.today).find(|row| row.id == id).unwrap().unloaded);
        store.select_item("one".into(), id.clone()).unwrap();
        let command = store.live_open(id.clone(), "https://restore.example/".into()).unwrap();
        store.live_apply(LiveTransaction { off_the_record: false, epoch: 1, rev: 1, cause: LiveCause::Command(command.id), strips: vec![] }).unwrap();
        assert_eq!(store.workspace.lock().unwrap().items[&id].lifecycle, Lifecycle::Unloaded);
        assert!(store.snapshot("one".into()).spaces.iter().flat_map(|space| &space.today).find(|row| row.id == id).unwrap().unloaded);
        {
            let mut workspace = store.workspace.lock().unwrap();
            workspace.items.get_mut(&id).unwrap().lifecycle = Lifecycle::Closed;
        }
        assert_eq!(store.restoration_candidate("one".into()), None);
        {
            let mut workspace = store.workspace.lock().unwrap();
            workspace.items.get_mut(&id).unwrap().lifecycle = Lifecycle::Unloaded;
            let mut folder = workspace.items[&id].clone();
            folder.id = "test-folder".into();
            folder.kind = ItemKind::Folder;
            folder.lifecycle = Lifecycle::Open;
            workspace.items.insert(folder.id.clone(), folder);
            workspace.items.get_mut(&id).unwrap().membership.parent = Some("test-folder".into());
        }
        assert!(store.restoration_candidate("one".into()).is_some());
        for lifecycle in [Lifecycle::Closed, Lifecycle::Archived] {
            store.workspace.lock().unwrap().items.get_mut("test-folder").unwrap().lifecycle = lifecycle;
            assert_eq!(store.restoration_candidate("one".into()), None);
        }
        {
            let mut workspace = store.workspace.lock().unwrap();
            let folder = workspace.items.get_mut("test-folder").unwrap();
            folder.lifecycle = Lifecycle::Open;
            folder.kind = ItemKind::Split { orientation: ararat_core::model::Orientation::Horizontal, width_factors: vec![] };
        }
        assert!(store.restoration_candidate("one".into()).is_some());
        {
            let mut workspace = store.workspace.lock().unwrap();
            workspace.spaces[1].profile = workspace.spaces[0].profile.clone();
            let favorites = workspace.spaces[1].favorites.clone().unwrap();
            workspace.items.get_mut(&id).unwrap().membership.parent = Some(favorites);
        }
        assert!(store.restoration_candidate("one".into()).is_some());
        store.show_space("one".into(), "space-work".into()).unwrap();
        store.workspace.lock().unwrap().windows.get_mut("one").unwrap().selected = Some(id.clone());
        assert_eq!(store.restoration_candidate("one".into()), None);
        store.show_space("one".into(), "space-home".into()).unwrap();
        store.workspace.lock().unwrap().windows.get_mut("one").unwrap().selected = Some(id.clone());
        {
            let mut workspace = store.workspace.lock().unwrap();
            workspace.items.get_mut(&id).unwrap().lifecycle = Lifecycle::Archived;
        }
        assert_eq!(store.restoration_candidate("one".into()), None);
        {
            let mut workspace = store.workspace.lock().unwrap();
            workspace.items.get_mut(&id).unwrap().lifecycle = Lifecycle::Unloaded;
            workspace.windows.get_mut("one").unwrap().selected = None;
        }
        assert_eq!(store.restoration_candidate("one".into()), None);
        {
            let mut workspace = store.workspace.lock().unwrap();
            workspace.windows.get_mut("one").unwrap().selected = Some("missing".into());
        }
        assert_eq!(store.restoration_candidate("one".into()), None);
        {
            let mut workspace = store.workspace.lock().unwrap();
            workspace.windows.get_mut("one").unwrap().selected = Some(id.clone());
            workspace.items.get_mut(&id).unwrap().kind = ItemKind::Split {
                orientation: ararat_core::model::Orientation::Horizontal, width_factors: vec![],
            };
        }
        assert_eq!(store.restoration_candidate("one".into()), None);
        drop(store);
        for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
    }

    #[test]
    fn showing_space_selects_each_windows_own_recent_tab() {
        let path = std::env::temp_dir().join(format!("ararat-ffi-space-selection-{}.sqlite", std::process::id()));
        assert!(!path.exists());
        let store = WorkspaceStore::open(path.to_string_lossy().into_owned()).unwrap();
        store.create_space("one".into(), "Work".into(), "work".into()).unwrap();
        let a = store.create_tab("one".into(), "https://a.example".into()).unwrap().selected_id.unwrap();
        let b = store.create_tab("one".into(), "https://b.example".into()).unwrap().selected_id.unwrap();
        store.show_space("two".into(), "work".into()).unwrap();
        store.select_item("two".into(), a.clone()).unwrap();
        store.create_space("one".into(), "Home".into(), "home".into()).unwrap();
        store.create_tab("one".into(), "https://home.example".into()).unwrap();
        store.show_space_selecting("two".into(), "home".into()).unwrap();
        assert_eq!(store.show_space_selecting("one".into(), "work".into()).unwrap().selected_id, Some(b));
        assert_eq!(store.show_space_selecting("two".into(), "work".into()).unwrap().selected_id, Some(a));
        store.create_space("one".into(), "Empty".into(), "empty".into()).unwrap();
        store.show_space_selecting("one".into(), "work".into()).unwrap();
        assert_eq!(store.show_space_selecting("one".into(), "empty".into()).unwrap().selected_id, None);
        drop(store);
        for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
    }

    #[test]
    fn showing_space_selects_split_member_and_allows_favorite() {
        let path = std::env::temp_dir().join(format!("ararat-ffi-space-groups-{}.sqlite", std::process::id()));
        assert!(!path.exists());
        let store = WorkspaceStore::open(path.to_string_lossy().into_owned()).unwrap();
        store.import_arc_sidebar("one".into(), include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json").into(), None, None, None, None).unwrap();
        store.show_space("one".into(), "space-work".into()).unwrap();
        store.select_item("one".into(), "split-1".into()).unwrap();
        store.show_space_selecting("one".into(), "space-home".into()).unwrap();
        assert_eq!(store.show_space_selecting("one".into(), "space-work".into()).unwrap().selected_id.as_deref(), Some("tab-a"));
        let before = store.snapshot("one".into());
        assert!(store.show_space_selecting_tab("one".into(), "space-work".into(), "missing-tab".into()).is_err());
        assert_eq!(store.snapshot("one".into()), before);
        assert_eq!(store.show_space_selecting_tab("one".into(), "space-work".into(), "tab-mail".into()).unwrap().selected_id.as_deref(), Some("tab-mail"));
        store.select_item("one".into(), "tab-mail".into()).unwrap();
        store.show_space_selecting("one".into(), "space-home".into()).unwrap();
        assert_eq!(store.show_space_selecting("one".into(), "space-work".into()).unwrap().selected_id.as_deref(), Some("tab-mail"));
        drop(store);
        for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
    }

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
            profile: Profile::Default,
        }).unwrap();
        store.add_rule(window.clone(), Rule {
            id: "docs".into(),
            conditions: vec![UrlCondition { style: MatchStyle::Contains, text: "docs.example.com".into() }],
            destination: Destination::Space(SpaceTarget::MostRecent),
            profile: Profile::Default,
        }).unwrap();
        let moved = store.move_rule(window.clone(), "docs".into(), 0).unwrap();
        let _ = moved;
        store.edit_rule(window.clone(), Rule {
            id: "meet".into(),
            conditions: vec![UrlCondition { style: MatchStyle::Equals, text: "https://meet.google.com/".to_string() }],
            destination: Destination::LittleWindow(Profile::Default),
            profile: Profile::Default,
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
        // second space keeps the first deletable (the last space cannot be deleted). Both
        // spaces ride in the default profile (no space is shown yet), as the rule does.
        store.create_space(window.clone(), "Work".into(), "space-work".into()).unwrap();
        store.create_space(window.clone(), "Home".into(), "space-home".into()).unwrap();
        store.add_rule(window.clone(), Rule {
            id: "meet".into(),
            conditions: vec![UrlCondition { style: MatchStyle::Contains, text: "meet.google.com".into() }],
            destination: Destination::Space(SpaceTarget::Space("space-work".into())),
            profile: Profile::Default,
        }).unwrap();
        store.add_rule(window.clone(), Rule {
            id: "empty".into(),
            conditions: vec![UrlCondition { style: MatchStyle::Contains, text: "  ".into() }],
            destination: Destination::LittleWindow(Profile::Default),
            profile: Profile::Default,
        }).unwrap();
        // What the FFI answers must be what Routing::route answers for the same records, over
        // the spaces the store has (the two created ones, no use recorded so far).
        let core = ararat_core::routing::Routing::from(store.routing());
        let spaces = ararat_core::routing::Spaces {
            entries: ["space-work", "space-home"].into_iter().map(|id| (id.into(), Profile::Default.into())).collect(),
            recency: ["space-work", "space-home"].into_iter().map(String::from).collect(),
        };
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
        // A rule whose space is deleted still matches, and its link answers the remaining
        // space of the rule's own profile, while the FFI answer still names the rule that
        // held the stale id.
        store.live_delete_space(window.clone(), "space-work".into()).unwrap();
        let decision = store.route("https://www.meet.google.com/x".into());
        assert_eq!(decision.rule_id.as_deref(), Some("meet"));
        assert_eq!(decision.destination, Destination::Space(SpaceTarget::Space("space-home".into())));
        let core = ararat_core::routing::Routing::from(store.routing());
        let spaces = ararat_core::routing::Spaces {
            entries: [("space-home", Profile::Default)].into_iter().map(|(id, p)| (id.into(), p.into())).collect(),
            recency: vec!["space-home".to_string()],
        };
        // The workspace's remaining space is space-home: every destination on these urls
        // names a space it no longer has, and the two answers agree on the profile's own
        // rewrite.
        for url in ["https://www.meet.google.com/abc", "https://docs.example.com/"] {
            let decision = store.route(url.into());
            assert_eq!(&decision.destination, &Destination::from(core.route(url, &spaces)), "{url}");
        }
        // The deleted destination is the one the deleted-space query names.
        assert_eq!(store.deleted_space_destinations(), vec![DeletedDestination {
            rule_id: Some("meet".into()), space_id: "space-work".into() }]);
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
            profile: Profile::Default,
        }).unwrap();
        store.import_arc_sidebar("one".into(), include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json").into(), None, None, None, None).unwrap();
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

    // The routing sibling joins the sidebar import's own store batch (its records, its
    // counters in the report), so a reopen reads the File's rules without a second flush.
    #[test]
    fn a_routing_file_imports_beside_the_sidebar_into_the_store_batch() {
        let path = std::env::temp_dir().join(format!("ararat-ffi-routing-sibling-{}.sqlite", std::process::id()));
        assert!(!path.exists());
        let store = WorkspaceStore::open(path.to_string_lossy().into_owned()).unwrap();
        let result = store.import_arc_sidebar("one".into(),
            include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json").into(), None, None,
            Some(include_str!("../../ararat-core/tests/fixtures/link-routing-synthetic.json").into()), None).unwrap();
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
            Some(include_str!("../../ararat-core/tests/fixtures/link-routing-synthetic.json").into()), None).unwrap();
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

    // An unreadable routing sibling never blocks the sidebar (as key_bindings_error
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
            profile: Profile::Default,
        }).unwrap();
        let result = store.import_arc_sidebar("one".into(),
            include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json").into(), None, None,
            Some("{\"version\":1,\"rules\":}".into()), None).unwrap();
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
        store.import_arc_sidebar("one".into(), include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json").into(), None, None, None, None).unwrap();
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

    // The live coordinator through the FFI: open and close hand back the commands with
    // fresh ids, the close's lifecycle change is flushed before the command is returned,
    // and a Chrome transaction's strips update the map and the window selection.
    #[test]
    fn item_profile_stays_with_the_item_when_the_window_changes_space() {
        let path = std::env::temp_dir().join(format!("ararat-ffi-item-profile-{}.sqlite", std::process::id()));
        assert!(!path.exists());
        let store = WorkspaceStore::open(path.to_string_lossy().into_owned()).unwrap();
        store.import_arc_sidebar("one".into(), include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json").into(), None, None, None, None).unwrap();
        store.show_space("one".into(), "space-home".into()).unwrap();
        let snapshot = store.create_tab("one".into(), "about:blank".into()).unwrap();
        let item = snapshot.selected_id.unwrap();
        store.show_space("one".into(), "space-work".into()).unwrap();
        assert_eq!(store.item_profile(item), Some(Profile::Named("Profile 1".into())));
        drop(store);
        for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
    }

    #[test]
    fn live_open_close_and_apply_commit_and_survive_a_reopen() {
        let path = std::env::temp_dir().join(format!("ararat-ffi-live-{}.sqlite", std::process::id()));
        assert!(!path.exists());
        let store = WorkspaceStore::open(path.to_string_lossy().into_owned()).unwrap();
        store.import_arc_sidebar("one".into(), include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json").into(), None, None, None, None).unwrap();
        let opened = store.live_open("tab-mail".into(), "https://mail.example.com/".into()).unwrap();
        assert_eq!(opened.kind, LiveCommandKind::Open);
        assert_eq!(opened.url.as_deref(), Some("https://mail.example.com/"));
        assert_eq!(store.live_tab("tab-mail".into()).as_deref(), Some(opened.id.as_str()));
        assert_eq!(store.item_for_live(opened.id.clone()).as_deref(), Some("tab-mail"));

        // Chrome's strips arrive with the tab live: the epoch's snapshot maps it, and a
        // Chrome activation moves the window selection.
        let live_id = opened.id.clone();
        let outcome = store.live_apply(LiveTransaction { off_the_record: false,
            epoch: 1, rev: 0, cause: LiveCause::Engine,
            strips: vec![LiveStrip { window: "one".into(), tabs: vec![LiveTab { off_the_record: false, profile: Profile::Default, opener: None, navigated: false, url: None, title: None, live_id: live_id.clone(), item: Some("tab-mail".into()) }], active: Some(live_id.clone()) }],
        }).unwrap();
        assert!(outcome.applied);
        let snapshot = store.snapshot("one".into());
        assert_eq!(snapshot.selected_id.as_deref(), Some("tab-mail"));

        // The close's lifecycle change is committed before the command is returned.
        let closed = store.live_close("tab-mail".into()).unwrap();
        assert_eq!(closed.kind, LiveCommandKind::Close);
        let snapshot = store.snapshot("one".into());
        let row = snapshot.spaces[0].favorites.iter().find(|row| row.id == "tab-mail").expect("row kept");
        assert!(row.unloaded);
        // A stale rev is dropped and counted on the live coordinator.
        let outcome = store.live_apply(LiveTransaction { off_the_record: false,
            epoch: 1, rev: 0, cause: LiveCause::Chrome, strips: vec![],
        }).unwrap();
        assert!(!outcome.applied);
        assert_eq!(store.live_dropped(), 1);
        // A reopened store reads the same bytes: the close rode one storage transaction,
        // and the reopened coordinator starts fresh.
        let store = WorkspaceStore::open(path.to_string_lossy().into_owned()).unwrap();
        let snapshot = store.snapshot("one".into());
        assert!(snapshot.spaces[0].favorites.iter().find(|row| row.id == "tab-mail").unwrap().unloaded);
        assert_eq!(store.live_dropped(), 0);
        drop(store);
        for suffix in ["", "-wal", "-shm"] { let _ = std::fs::remove_file(format!("{}{suffix}", path.display())); }
    }

    #[test]
    fn drag_snapshot_exposes_membership_roots_indices_profiles_and_fold_state() {
        let mut ws = import::arc_sidebar(include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), None, None, None, None).unwrap().0;
        ws.set_folder_collapsed("folder-docs", true).unwrap();
        let snapshot = snapshot(ws, "drag");
        let space = &snapshot.spaces[0];
        assert_eq!(space.pinned_id, "pin-work");
        assert_eq!(space.today_id, "today-work");
        assert_eq!(space.favorites_id.as_deref(), Some("space-work:favorites"));
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
        let mut ws = import::arc_sidebar(include_str!("../../ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), None, None, None, None).unwrap().0;
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
        let snapshot = import_arc_sidebar(json, None, None, None, None).unwrap().snapshot;
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
    OpenUrl { url: String },
    Search { url: String },
    Command { id: String },
    Space { id: String },
    Folder { id: String, space_id: String },
    MoveToSpace { id: String },
    MoveToFolder { id: String, space_id: String },
    History { url: String },
}

impl From<ararat_core::command_bar::Target> for SuggestionTarget {
    fn from(target: ararat_core::command_bar::Target) -> Self {
        use ararat_core::command_bar::Target;
        match target {
            Target::Tab { id, space_id } => Self::Tab { id, space_id },
            Target::OpenUrl { url } => Self::OpenUrl { url },
            Target::Search { url } => Self::Search { url },
            Target::Command { id } => Self::Command { id },
            Target::Space { id } => Self::Space { id },
            Target::Folder { id, space_id } => Self::Folder { id, space_id },
            Target::MoveToSpace { id } => Self::MoveToSpace { id },
            Target::MoveToFolder { id, space_id } => Self::MoveToFolder { id, space_id },
            Target::History { url } => Self::History { url },
        }
    }
}

/// One page from Chromium's `HistoryService`, passed in per query (U23 D5): the engine owns the
/// store, the core matches and scores. `last_visit` is milliseconds since the epoch, 0 if unknown.
#[derive(Debug, Clone, uniffi::Record)]
pub struct HistoryEntry {
    pub title: String,
    pub url: String,
    pub last_visit: u64,
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
    /// The window is private: no history rows, and the bar shows its note (U23 D7).
    pub private_window: bool,
}

#[uniffi::export]
impl CommandBarSession {
    pub fn search_url(&self, text: String) -> String {
        ararat_core::command_bar::search_url(&text)
    }

    pub fn query(&self, text: String, history: Vec<HistoryEntry>) -> CommandBarResult {
        let history: Vec<_> = history.into_iter().map(|entry| ararat_core::command_bar::HistoryEntry {
            title: entry.title, url: entry.url, last_visit: entry.last_visit,
        }).collect();
        let result = self.index.query(&text, &history);
        CommandBarResult {
            private_window: result.private_window,
            rows: result.rows.into_iter().map(|s| Suggestion {
                title: s.title, subtitle: s.subtitle, url: s.url, key: s.key.map(Into::into), score: s.score,
                target: s.target.into(),
            }).collect(),
        }
    }
}

#[uniffi::export]
impl WorkspaceStore {
    /// `private_window` withholds history rows and marks the result so the bar shows its note
    /// (U23 D7); the private window's own workspace is a later slice (5.3).
    pub fn command_bar_session(&self, window_id: String, private_window: bool) -> Arc<CommandBarSession> {
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis() as u64;
        let mut workspace = self.workspace.lock().unwrap().clone();
        workspace.repair_tree();
        Arc::new(CommandBarSession { index: ararat_core::command_bar::Index::new(&workspace, &window_id, now).private_window(private_window || self.private) })
    }

    /// The shown space's most recently selected tabs, newest first, for the ⌃Tab switcher
    /// (U23 D4, D8): the same list an empty command bar shows.
    pub fn recent_tabs(&self, window_id: String) -> Vec<Suggestion> {
        let mut workspace = self.workspace.lock().unwrap().clone();
        workspace.repair_tree();
        use ararat_core::command_bar::{recent_tabs, SWITCHER_LIMIT};
        recent_tabs(&workspace, &window_id, SWITCHER_LIMIT).into_iter().map(|s| Suggestion {
            title: s.title, subtitle: s.subtitle, url: s.url, key: s.key.map(Into::into), score: s.score,
            target: s.target.into(),
        }).collect()
    }

    pub fn switcher_thumbnail_spaces(&self, window_id: String) -> Vec<SwitcherThumbnailSpace> {
        use ararat_core::command_bar::switcher_thumbnail_items;
        let mut workspace = self.workspace.lock().unwrap().clone();
        workspace.repair_tree();
        workspace.spaces.iter().map(|space| SwitcherThumbnailSpace {
            id: space.id.clone(),
            profile: match &space.profile {
                ararat_core::model::Profile::Default => "Default".into(),
                ararat_core::model::Profile::Named(name) => name.clone(),
            },
            items: switcher_thumbnail_items(&workspace, &window_id, space),
        }).collect()
    }

    pub fn create_tab(&self, window_id: String, url: String) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.create_tab(&window_id, &url)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn set_tab_url(&self, window_id: String, id: String, url: String) -> Result<WorkspaceSnapshot, CoreError> {
        self.admit(false)?;
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_tab_url(&id, &url)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }
}
