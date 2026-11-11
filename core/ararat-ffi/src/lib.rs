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
}

#[uniffi::export]
impl WorkspaceStore {
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>, CoreError> {
        let (store, workspace) = Store::open(Path::new(&path))?;
        Ok(Arc::new(Self { store, workspace: Mutex::new(workspace), live: Mutex::new(ararat_core::live::Live::new()) }))
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

    pub fn split_layout(&self, item_id: String) -> Option<SplitPane> {
        let mut workspace = self.workspace.lock().unwrap().clone();
        workspace.repair_tree();
        let id = workspace.outermost_split(&item_id)?;
        split_pane(&workspace, &id, 1.0)
    }

    pub fn set_split_factors(&self, split_id: String, factors: Vec<SplitFactor>) -> Result<(), CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_split_factors(&split_id, factors.into_iter().map(|f| (f.id, f.factor)).collect())?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(())
    }

    pub fn import_arc_sidebar(&self, window_id: String, json: String, windows_json: Option<String>, key_bindings_json: Option<String>, link_routing_json: Option<String>, owner_profile: Option<Profile>) -> Result<ImportResult, CoreError> {
        let (mut imported, report) = import::arc_sidebar(&json, windows_json.as_deref(), key_bindings_json.as_deref(), link_routing_json.as_deref(), owner_profile.map(Into::into)).map_err(|e| CoreError::Import { message: e.0 })?;
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

    // The pane's "Deleted space" menus read the core's one answer, not a Swift-side compare.
    pub fn deleted_space_destinations(&self) -> Vec<DeletedDestination> {
        self.workspace.lock().unwrap().deleted_space_destinations().into_iter()
            .map(|lost| DeletedDestination { rule_id: lost.rule_id, space_id: lost.space_id })
            .collect()
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

    pub fn show_space_selecting(&self, window_id: String, space_id: String) -> Result<WorkspaceSnapshot, CoreError> {
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
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.close_window(&window_id, quitting);
        self.store.write(ops);
        self.store.flush()?;
        Ok(())
    }

    pub fn kept_windows(&self) -> Vec<KeptWindow> {
        let workspace = self.workspace.lock().unwrap();
        workspace.kept_windows().into_iter()
            .map(|window| KeptWindow { id: window.id, changed_at: window.changed_at }).collect()
    }

    pub fn pending_history_purges(&self) -> Result<Vec<HistoryPurge>, CoreError> {
        let workspace = self.workspace.lock().unwrap();
        if workspace.history_purges.is_empty() { return Ok(Vec::new()); }
        self.store.flush()?;
        let mut purges: Vec<_> = workspace.history_purges.iter().map(|(id, (profile, item, changed_at))|
            HistoryPurge { id: id.clone(), profile: profile.clone().into(), item: item.clone(), changed_at: *changed_at }).collect();
        purges.sort_by(|a, b| a.id.cmp(&b.id));
        Ok(purges)
    }

    pub fn history_admission(&self, item: String) -> HistoryAdmission {
        let workspace = self.workspace.lock().unwrap();
        let stamp = workspace.items.get(&item).map_or(0, |i| i.lifecycle_changed_at);
        let purges = workspace.history_purges.iter().filter(|(_, (_, id, _))| id == &item)
            .map(|(id, (profile, item, changed_at))| HistoryPurge { id: id.clone(), profile: profile.clone().into(), item: item.clone(), changed_at: *changed_at }).collect();
        HistoryAdmission { stamp, purges }
    }

    pub fn acknowledge_history_purge(&self, id: String) -> Result<(), CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        if !workspace.history_purges.contains_key(&id) { return Ok(()); }
        let op = ararat_core::model::Op::Delete(ararat_core::model::Kind::HistoryPurge, id);
        self.store.write(vec![op.clone()]);
        self.store.flush()?;
        workspace.apply(&op);
        Ok(())
    }

    pub fn restoration_candidate(&self, window_id: String) -> Option<RestorationCandidate> {
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
        if current.membership.parent.is_some() || !(current.id == space.today || current.id == space.pinned
            || workspace.favorites.get(&space.profile) == Some(&current.id)) { return None; }
        Some(RestorationCandidate { id: item.id.clone(), url: url.clone(), space: space.id.clone(), profile: space.profile.clone().into() })
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

    pub fn ensure_favorites(&self, window_id: String, space_id: String, container_id: String) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.ensure_favorites(&space_id, &container_id)?;
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

    pub fn set_section_collapsed(&self, window_id: String, space_id: String, collapsed: bool) -> Result<WorkspaceSnapshot, CoreError> {
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
    pub fn clear_today(&self, window_id: String, space_id: String) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.clear_today(&space_id)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(snapshot(workspace.clone(), &window_id))
    }

    pub fn settings(&self) -> WorkspaceSettings {
        self.workspace.lock().unwrap().settings.clone().into()
    }

    pub fn set_new_tab_row_shown(&self, window_id: String, shown: bool) -> Result<WorkspaceSnapshot, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let ops = workspace.set_new_tab_row_shown(shown);
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

    // The live-tab coordinator (architecture 5.1/5.2). The commands and the transaction
    // application return the workspace ops they produced; the store writes each batch as
    // one transaction, and the lifecycle change of a close is flushed before the command
    // is handed to the engine. The open's map entry and its in-flight marker land only
    // after that flush succeeded.
    pub fn live_open(&self, item: String, url: String) -> Result<LiveCommand, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let mut live = self.live.lock().unwrap();
        let (ops, command) = live.open(&mut workspace, &item, &url)?;
        self.store.write(ops);
        self.store.flush()?;
        live.command_sent(&command);
        Ok(command.into())
    }

    pub fn live_activate(&self, item: String) -> Result<LiveCommand, CoreError> {
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

    pub fn live_close(&self, item: String) -> Result<LiveCommand, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let mut live = self.live.lock().unwrap();
        let (ops, command) = live.close(&mut workspace, &item)?;
        self.store.write(ops);
        self.store.flush()?;
        live.command_sent(&command);
        Ok(command.into())
    }

    pub fn live_close_split(&self, item: String) -> Result<Vec<LiveCloseTarget>, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let mut live = self.live.lock().unwrap();
        let (ops, commands) = live.close_split(&mut workspace, &item)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(commands.into_iter().map(|(live_id, command)| LiveCloseTarget { live_id, command: command.into() }).collect())
    }

    pub fn live_archive(&self, item: String) -> Result<LiveCommand, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let mut live = self.live.lock().unwrap();
        let (ops, command) = live.archive(&mut workspace, &item)?;
        self.store.write(ops);
        self.store.flush()?;
        live.command_sent(&command);
        Ok(command.into())
    }

    // Clear Today in one batch, with a Close command in flight for every mapped live row it
    // archives, so the engine's replies match commands (U25b D6).
    pub fn live_clear_today(&self, window_id: String, space_id: String) -> Result<LiveClearToday, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let mut live = self.live.lock().unwrap();
        let (ops, targets) = live.clear_today(&mut workspace, &space_id)?;
        self.store.write(ops);
        self.store.flush()?;
        Ok(LiveClearToday {
            snapshot: snapshot(workspace.clone(), &window_id),
            targets: targets.into_iter()
                .map(|(live_id, command)| LiveCloseTarget { live_id, command: command.into() }).collect(),
        })
    }

    pub fn live_apply(&self, transaction: LiveTransaction) -> Result<LiveApplyOutcome, CoreError> {
        let mut workspace = self.workspace.lock().unwrap();
        let mut live = self.live.lock().unwrap();
        let (ops, outcome) = live.apply(&mut workspace, transaction.into());
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
}

impl From<ararat_core::model::Settings> for WorkspaceSettings {
    fn from(settings: ararat_core::model::Settings) -> Self {
        Self { new_tab_row_shown: settings.new_tab_row_shown }
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

#[derive(Debug, PartialEq, uniffi::Record)]
pub struct KeptWindow {
    pub id: String,
    pub changed_at: u64,
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
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LiveCloseTarget {
    pub live_id: String,
    pub command: LiveCommand,
}

// Clear Today: the batch's snapshot, with the live tabs whose pages the caller closes (each
// beside a Close command the core has in flight).
#[derive(Debug, PartialEq, uniffi::Record)]
pub struct LiveClearToday {
    pub snapshot: WorkspaceSnapshot,
    pub targets: Vec<LiveCloseTarget>,
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
        Self { profile: tab.profile.into(), live_id: tab.live_id, item: tab.item, opener: tab.opener, navigated: tab.navigated, url: tab.url, title: tab.title }
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
// is an automatic one and still skips a closed folder's tabs (is_open_visible reads the
// folder state).
fn selection_view(workspace: &Workspace, window_id: &str) -> WorkspaceSnapshot {
    let mut view = workspace.clone();
    view.section_collapsed.clear();
    view.folder_collapsed.clear();
    snapshot(view, window_id)
}

fn snapshot(mut view: Workspace, window_id: &str) -> WorkspaceSnapshot {
    view.repair_tree();
    let archive = view.archive().into_iter().filter_map(|item| match &item.kind {
        ItemKind::Tab { url, .. } => Some(ArchiveEntry { id: item.id.clone(), title: item.display_title().into(), url: url.clone(), lifecycle_changed_at: item.lifecycle_changed_at }),
        _ => None,
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
        favorites_id: ws.favorites.get(&s.profile).cloned(),
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
        favorites: ws.favorites.get(&s.profile).map_or_else(Vec::new, |container| rows(ws, container, None)),
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
        store.live_apply(LiveTransaction { epoch: 1, rev: 0, cause: LiveCause::Engine,
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
        store.live_apply(LiveTransaction { epoch: 1, rev: 1, cause: LiveCause::Command(command.id), strips: vec![] }).unwrap();
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
            let profile = workspace.spaces.iter().find(|s| s.id == "space-home").unwrap().profile.clone();
            let today = workspace.spaces.iter().find(|s| s.id == "space-home").unwrap().today.clone();
            let mut favorites = workspace.items[&today].clone();
            favorites.id = "test-favorites".into();
            workspace.items.insert(favorites.id.clone(), favorites);
            workspace.favorites.insert(profile, "test-favorites".into());
            workspace.items.get_mut(&id).unwrap().membership.parent = Some("test-favorites".into());
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
        store.delete_space(window.clone(), "space-work".into()).unwrap();
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
        let outcome = store.live_apply(LiveTransaction {
            epoch: 1, rev: 0, cause: LiveCause::Engine,
            strips: vec![LiveStrip { window: "one".into(), tabs: vec![LiveTab { profile: Profile::Default, opener: None, navigated: false, url: None, title: None, live_id: live_id.clone(), item: Some("tab-mail".into()) }], active: Some(live_id.clone()) }],
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
        let outcome = store.live_apply(LiveTransaction {
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
        Arc::new(CommandBarSession { index: ararat_core::command_bar::Index::new(&workspace, &window_id, now).private_window(private_window) })
    }

    /// The shown space's most recently selected tabs, newest first, for the ⌃Tab switcher
    /// (U23 D4, D8): the same list an empty command bar shows.
    pub fn recent_tabs(&self, window_id: String, limit: u32) -> Vec<Suggestion> {
        let mut workspace = self.workspace.lock().unwrap().clone();
        workspace.repair_tree();
        ararat_core::command_bar::recent_tabs(&workspace, &window_id, limit as usize).into_iter().map(|s| Suggestion {
            title: s.title, subtitle: s.subtitle, url: s.url, key: s.key.map(Into::into), score: s.score,
            target: s.target.into(),
        }).collect()
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
