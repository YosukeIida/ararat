// The live-tab coordinator (architecture 5.1/5.2): the core owns the map from workspace
// item to live tab and applies the engine's transactions. Chrome's TabStripModel stays
// the one writer of which WebContents exist and which is active — the coordinator only
// reads them from the transactions and answers with commands.

use std::collections::{HashMap, HashSet};

use crate::model::{Id, Item, ItemKind, Lifecycle, Membership, Op, Profile, Record, Workspace};

/// A command the engine must carry out. The fresh id doubles as the live tab's id in the
/// map, so an opened tab comes to life under the id the command already carries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Command {
    pub id: Id,
    pub kind: CommandKind,
    pub item: Id,
    pub url: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommandKind { Open, Activate, Close }

/// Why a transaction happened. One value per transaction, so a transaction that mixed
/// causes cannot be built — and none of the core's parse paths can produce one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Cause {
    /// The engine's reply to the command with this id.
    Command(Id),
    /// The engine reported state on its own call (metadata, profile switch, window close);
    /// within an epoch it never changes the selection.
    Engine,
    /// Chrome changed something on its own (user gesture, extension).
    Chrome,
}

/// One live tab as the engine reports it: the engine-side id and the workspace item id
/// its per-tab session data carries, if any.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LiveTab {
    pub off_the_record: bool,
    pub profile: Profile,
    pub live_id: Id,
    pub item: Option<Id>,
    pub opener: Option<Id>,
    pub navigated: bool,
    pub url: Option<String>,
    pub title: Option<String>,
}

/// The live tabs of one window, with the active tab.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Strip {
    pub window: Id,
    pub tabs: Vec<LiveTab>,
    pub active: Option<Id>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Transaction {
    pub off_the_record: bool,
    pub epoch: u64,
    pub rev: u64,
    pub cause: Cause,
    pub strips: Vec<Strip>,
}

/// What one apply did. `applied` is false for a transaction that was stale, from an old
/// epoch, whose completion named no command in flight, or that would break the map's
/// uniqueness — it is dropped and counted, and its rev is consumed.
#[derive(Debug, Default, PartialEq)]
pub struct ApplyOutcome {
    pub error: Option<LiveError>,
    pub applied: bool,
    /// Commands the apply produced: closes for engine tabs whose item is closed,
    /// archived or deleted, and activates for the successor a Chrome-caused close left
    /// for the core's rule to choose.
    pub commands: Vec<Command>,
    /// Live tabs the apply adopted, beside the items it created for them — the engine
    /// stores the item id in the tab's session data (§5.2).
    pub adopted: Vec<(Id, Id)>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LiveError(pub String);

impl From<crate::edit::EditError> for LiveError {
    fn from(error: crate::edit::EditError) -> Self {
        LiveError(error.0)
    }
}

#[derive(Debug, Default)]
pub struct Live {
    map: HashMap<Id, Id>,
    reverse: HashMap<Id, Id>,
    windows: HashMap<Id, Id>,
    pending: HashMap<Id, (CommandKind, Id)>,
    selection_intents: HashMap<Id, Id>,
    epoch: Option<u64>,
    last_rev: u64,
    dropped: u64,
}

impl Live {
    fn selection_allowed(workspace: &Workspace, map: &HashMap<Id, Id>, windows: &HashMap<Id, Id>, window: &str, explicit: bool) -> bool {
        explicit || !workspace.selected(window).and_then(|item| map.get(item))
            .and_then(|live| windows.get(live)).is_some_and(|owner| owner != window)
    }
    pub fn new() -> Self {
        Self::default()
    }

    pub fn live_tab(&self, item: &str) -> Option<Id> {
        self.map.get(item).cloned()
    }

    pub fn live_window(&self, item: &str) -> Option<Id> {
        self.map.get(item).and_then(|live| self.windows.get(live)).cloned()
    }

    pub fn item_for(&self, live_id: &str) -> Option<Id> {
        self.reverse.get(live_id).cloned()
    }

    /// Stale, repeated, old-epoch, unmatched-completion and conflicting transactions,
    /// counted.
    pub fn dropped(&self) -> u64 {
        self.dropped
    }

    // Command ids avoid the item namespace; item ids use create_tab's bare hex form.
    fn fresh_command_id(&self, workspace: &Workspace) -> Id {
        loop {
            use std::hash::BuildHasher;
            let random = std::collections::hash_map::RandomState::new();
            let id = format!("cmd-{:016x}{:016x}", random.hash_one(0u8), random.hash_one(1u8));
            if !workspace.items.contains_key(&id)
                && !self.map.contains_key(&id) && !self.reverse.contains_key(&id)
                && !self.pending.contains_key(&id) {
                break id;
            }
        }
    }

    fn fresh_item_id(workspace: &Workspace) -> Id {
        loop {
            use std::hash::BuildHasher;
            let random = std::collections::hash_map::RandomState::new();
            let id = format!("{:016x}{:016x}", random.hash_one(0u8), random.hash_one(1u8));
            if !workspace.items.contains_key(&id) { break id; }
        }
    }

    /// One Activate for a row the window keeps, in flight with the transaction that asked for
    /// it: both the close successor and an off-space strip's re-assertion answer with this.
    fn reactivate(&self, workspace: &Workspace, pending: &mut HashMap<Id, (CommandKind, Id)>, item: &str) -> Command {
        let command = Command {
            id: self.fresh_command_id(workspace), kind: CommandKind::Activate,
            item: item.into(), url: None,
        };
        pending.insert(command.id.clone(), (CommandKind::Activate, command.item.clone()));
        command
    }

    /// Opens a live tab for a workspace row: the flip rides the returned ops, and the
    /// command comes back. The map and the in-flight marker land in `command_sent` —
    /// after the caller's flush succeeded, so a failed flush leaves no engine-facing
    /// entry for a command that was never sent.
    pub fn open(&mut self, workspace: &mut Workspace, item: &str, url: &str) -> Result<(Vec<Op>, Command), LiveError> {
        let tab = workspace.items.get(item).filter(|i| matches!(i.kind, ItemKind::Tab { .. }))
            .ok_or_else(|| LiveError(format!("item {item} is not a tab")))?;
        if !matches!(tab.lifecycle, Lifecycle::Open | Lifecycle::Unloaded) {
            return Err(LiveError(format!("item {item} is not open or unloaded")));
        }
        if self.map.contains_key(item)
            || self.pending.values().any(|(kind, open_item)| *kind == CommandKind::Open && open_item == item) {
            return Err(LiveError(format!("item {item} already has a live tab")));
        }
        let ops = workspace.flip_active(item, workspace.lifecycle_time());
        Ok((ops, Command {
            id: self.fresh_command_id(workspace), kind: CommandKind::Open,
            item: item.into(), url: Some(url.into()),
        }))
    }

    /// Registers a command whose flush succeeded: the open's map entry and the in-flight
    /// marker for every kind land here, so a failed flush leaves nothing behind.
    pub fn command_sent(&mut self, command: &Command) {
        match command.kind {
            CommandKind::Open => {
                self.map.insert(command.item.clone(), command.id.clone());
                self.reverse.insert(command.id.clone(), command.item.clone());
            }
            // The close's map removal already ran at close time, where it matched the
            // in-memory lifecycle change.
            CommandKind::Close => {}
            CommandKind::Activate => {}
        }
        self.pending.insert(command.id.clone(), (command.kind, command.item.clone()));
    }

    pub fn selection_intent(&mut self, command_id: &str, window: &str) -> bool {
        if !self.pending.get(command_id).is_some_and(|(kind, _)| *kind == CommandKind::Activate) { return false; }
        let superseded: Vec<_> = self.selection_intents.iter().filter(|(id, owner)| owner.as_str() == window && id.as_str() != command_id)
            .map(|(id, _)| id.clone()).collect();
        for id in superseded {
            self.selection_intents.remove(&id);
            self.pending.remove(&id);
        }
        self.selection_intents.insert(command_id.into(), window.into());
        true
    }

    pub fn cancel(&mut self, workspace: &mut Workspace, command_id: &str) -> (bool, Vec<Op>) {
        self.selection_intents.remove(command_id);
        if self.pending.get(command_id).is_some_and(|(kind, _)| *kind == CommandKind::Activate) {
            self.pending.remove(command_id);
            return (true, Vec::new());
        }
        let mut ops = Vec::new();
        let cancelled = Self::cancel_open(workspace, command_id, &mut self.map, &mut self.reverse,
                          &mut self.windows, &mut self.pending, &mut ops);
        (cancelled, ops)
    }

    pub fn settle_close(&mut self, command_id: &str) -> bool {
        if self.pending.get(command_id).is_some_and(|(kind, _)| *kind == CommandKind::Close) {
            self.pending.remove(command_id);
            true
        } else { false }
    }

    fn cancel_open(
        workspace: &mut Workspace,
        command_id: &str,
        map: &mut HashMap<Id, Id>,
        reverse: &mut HashMap<Id, Id>,
        windows: &mut HashMap<Id, Id>,
        pending: &mut HashMap<Id, (CommandKind, Id)>,
        ops: &mut Vec<Op>,
    ) -> bool {
        let Some((CommandKind::Open, item)) = pending.get(command_id).cloned() else {
            return false;
        };
        pending.remove(command_id);
        if map.get(&item).is_some_and(|live| live == command_id) {
            map.remove(&item);
        }
        if reverse.get(command_id) == Some(&item) {
            reverse.remove(command_id);
        }
        windows.remove(command_id);
        if !map.contains_key(&item)
            && !pending.values().any(|(kind, id)| *kind == CommandKind::Open && id == &item) {
            if let Some(tab) = workspace.items.get_mut(&item).filter(|tab|
                matches!(tab.kind, ItemKind::Tab { .. }) && tab.lifecycle == Lifecycle::Open) {
                tab.lifecycle = Lifecycle::Unloaded;
                ops.push(Op::Put(Record::Item(tab.clone())));
            }
        }
        true
    }

    /// Activates a live tab. The selection is recorded when the engine's transaction
    /// confirms it, not here: the strips are the one report of which tab is active.
    pub fn activate(&mut self, workspace: &Workspace, item: &str) -> Result<Command, LiveError> {
        self.map.get(item).ok_or_else(|| LiveError(format!("item {item} has no live tab")))?;
        Ok(Command { id: self.fresh_command_id(workspace), kind: CommandKind::Activate, item: item.into(), url: None })
    }

    /// Closes a live tab. The lifecycle change rides the ⌘W rule's own ops — a Today tab
    /// closes, a pinned or favorite row unloads and keeps its place, and the successor is
    /// selected by the selection history — and is committed before the command is
    /// returned (§5.2).
    pub fn close(&mut self, workspace: &mut Workspace, item: &str) -> Result<(Vec<Op>, Command), LiveError> {
        self.finish(workspace, item, false)
    }

    pub fn close_split(&mut self, workspace: &mut Workspace, split: &str) -> Result<(Vec<Op>, Vec<(Id, Command)>), LiveError> {
        workspace.check_tree().map_err(LiveError)?;
        if !workspace.items.get(split).is_some_and(|item| matches!(item.kind, ItemKind::Split { .. })) {
            return Err(LiveError(format!("item {split} is not a split")));
        }
        let mut stack = vec![split.to_string()];
        let mut items = Vec::new();
        while let Some(id) = stack.pop() {
            for child in workspace.children(&id) {
                if matches!(child.kind, ItemKind::Tab { .. }) {
                    if let Some(live) = self.map.get(&child.id) { items.push((child.id.clone(), live.clone())); }
                } else { stack.push(child.id.clone()); }
            }
        }
        let ops = workspace.close_item(split)?;
        let mut commands = Vec::new();
        for (item, live) in items {
            self.pending.retain(|_, (kind, pending)| !(*kind == CommandKind::Activate && pending == &item));
            self.map.remove(&item);
            self.reverse.remove(&live);
            self.windows.remove(&live);
            let command = Command { id: self.fresh_command_id(workspace), kind: CommandKind::Close, item: item.clone(), url: None };
            self.pending.insert(command.id.clone(), (CommandKind::Close, item));
            commands.push((live, command));
        }
        self.selection_intents.retain(|id, _| self.pending.contains_key(id));
        Ok((ops, commands))
    }

    pub fn archive(&mut self, workspace: &mut Workspace, item: &str) -> Result<(Vec<Op>, Command), LiveError> {
        self.finish(workspace, item, true)
    }

    /// Clear Today (U25b D6) and, in the same step, register a Close for every mapped live row
    /// it archives — the way `close_split` does — so the engine's replies name commands that
    /// are in flight (apply drops a reply whose command is not pending). The caller closes the
    /// returned live tabs with the commands' ids.
    pub fn clear_today(&mut self, workspace: &mut Workspace, space: &str) -> Result<(Vec<Op>, Vec<(Id, Command)>, crate::edit::ClearTodayBatch), LiveError> {
        workspace.check_tree().map_err(LiveError)?;
        let today = workspace.spaces.iter().find(|entry| entry.id == space).map(|entry| entry.today.clone())
            .ok_or_else(|| LiveError(format!("unknown space {space}")))?;
        // The rows the clear will archive, before their lifecycle changes: every mapped tab in
        // Today, including the members of a split row.
        let items: Vec<Id> = workspace.outline_entries(&today).into_iter()
            .map(|(_, item, _)| item.id.clone())
            .filter(|id| matches!(workspace.items[id].kind, ItemKind::Tab { .. }) && self.map.contains_key(id))
            .collect();
        let (ops, batch) = workspace.clear_today(space).map_err(|error| LiveError(error.0))?;
        let targets = self.close_targets(workspace, items);
        Ok((ops, targets, batch))
    }

    pub fn auto_archive(&mut self, workspace: &mut Workspace, now: u64) -> Result<(Vec<Op>, Vec<(Id, Command)>), LiveError> {
        if workspace.is_private() { return Ok((Vec::new(), Vec::new())); }
        let ops = workspace.auto_archive(now)?;
        let targets = self.close_archived(workspace, &ops);
        Ok((ops, targets))
    }

    pub fn delete_space(&mut self, workspace: &mut Workspace, space: &str) -> Result<(Vec<Op>, Vec<(Id, Command)>), LiveError> {
        if workspace.is_private() { return Err(LiveError("operation unavailable in a private workspace".into())); }
        let ops = workspace.delete_space(space)?;
        let targets = self.close_archived(workspace, &ops);
        Ok((ops, targets))
    }

    fn close_archived(&mut self, workspace: &Workspace, ops: &[Op]) -> Vec<(Id, Command)> {
        let items = ops.iter().filter_map(|op| match op {
            Op::Put(Record::Item(item)) if item.lifecycle == Lifecycle::Archived && matches!(item.kind, ItemKind::Tab { .. }) => Some(item.id.clone()),
            _ => None,
        }).collect();
        self.close_targets(workspace, items)
    }

    fn close_targets(&mut self, workspace: &Workspace, items: Vec<Id>) -> Vec<(Id, Command)> {
        let mut targets = Vec::new();
        for item in items {
            let Some(live) = self.map.remove(&item) else { continue };
            self.reverse.remove(&live);
            self.windows.remove(&live);
            // A row that leaves the map cannot answer an Activate any more.
            self.pending.retain(|_, (kind, pending)| !(*kind == CommandKind::Activate && pending == &item));
            let command = Command { id: self.fresh_command_id(workspace), kind: CommandKind::Close, item: item.clone(), url: None };
            self.pending.insert(command.id.clone(), (CommandKind::Close, item));
            targets.push((live, command));
        }
        self.selection_intents.retain(|id, _| self.pending.contains_key(id));
        targets
    }

    fn finish(&mut self, workspace: &mut Workspace, item: &str, archive: bool) -> Result<(Vec<Op>, Command), LiveError> {
        let live = self.map.get(item).cloned().ok_or_else(|| LiveError(format!("item {item} has no live tab")))?;
        let ops = if archive { workspace.archive_item(item)? } else { workspace.close_item(item)? };
        self.map.remove(item);
        self.reverse.remove(&live);
        self.windows.remove(&live);
        let command = Command {
            id: self.fresh_command_id(workspace), kind: CommandKind::Close,
            item: item.into(), url: None,
        };
        self.pending.insert(command.id.clone(), (CommandKind::Close, item.into()));
        Ok((ops, command))
    }

    /// Applies one engine transaction and returns the workspace ops (lifecycle, adopted
    /// rows, selection) as one storage batch, beside the commands the transaction calls
    /// for. The workspace and the maps commit only when the transaction is accepted: a
    /// dropped one leaves both exactly as they were.
    pub fn apply(&mut self, workspace: &mut Workspace, transaction: Transaction) -> (Vec<Op>, ApplyOutcome) {
        let mut outcome = ApplyOutcome::default();
        if transaction.off_the_record != workspace.is_private() || transaction.strips.iter().flat_map(|strip| &strip.tabs).any(|tab| tab.off_the_record != transaction.off_the_record) {
            outcome.error = Some(LiveError("transaction privacy mismatch".into()));
            return (Vec::new(), outcome);
        }
        if workspace.is_private() && transaction.strips.iter().flat_map(|strip| &strip.tabs).any(|tab| workspace.spaces.first().is_none_or(|space| space.profile != tab.profile)) {
            outcome.error = Some(LiveError("private profile mismatch".into()));
            return (Vec::new(), outcome);
        }
        match self.epoch {
            Some(current) if transaction.epoch < current => { self.dropped += 1; return (Vec::new(), outcome); }
            Some(current) if transaction.epoch == current => {
                if transaction.rev <= self.last_rev { self.dropped += 1; return (Vec::new(), outcome); }
            }
            // A new epoch must arrive as a full snapshot.
            _ if transaction.rev != 0 => { self.dropped += 1; return (Vec::new(), outcome); }
            _ => {},
        }
        // A completion must name a command that is still in flight.
        if let Cause::Command(id) = &transaction.cause {
            if !self.pending.contains_key(id) {
                self.dropped += 1;
                return (Vec::new(), outcome);
            }
        }
        let is_new_epoch = self.epoch != Some(transaction.epoch);
        if !is_new_epoch { self.last_rev = transaction.rev; }

        let mut windows = HashSet::new();
        let mut lives = HashSet::new();
        let mut items = HashSet::new();
        if transaction.strips.iter().any(|strip| {
            !windows.insert(&strip.window) || strip.tabs.iter().any(|tab| {
                !lives.insert(&tab.live_id) || tab.item.as_ref().is_some_and(|item| !items.insert(item))
            })
        }) || transaction.strips.iter().flat_map(|strip| &strip.tabs).any(|tab| {
            tab.item.as_deref().and_then(|id| workspace.item_profile(id))
                .is_some_and(|profile| profile != &tab.profile)
        }) {
            self.dropped += 1;
            outcome.applied = false;
            return (Vec::new(), outcome);
        }
        self.epoch = Some(transaction.epoch);
        self.last_rev = transaction.rev;
        outcome.applied = true;

        // Validate and compute on clones; the workspace and the maps commit only when the
        // transaction is accepted (the way auto_archive commits) — a dropped one leaves
        // both exactly as they were.
        let mut next = workspace.clone();
        let mut next_map = self.map.clone();
        let mut next_reverse = self.reverse.clone();
        let mut next_windows = self.windows.clone();
        let mut next_pending = self.pending.clone();
        let mut next_intents = self.selection_intents.clone();
        let mut ops = Vec::new();

        if is_new_epoch {
            // A new epoch clears the commands in flight, and the map is rebuilt from the
            // snapshot, not merged.
            next_pending.clear();
            next_intents.clear();
            next_map.clear();
            next_reverse.clear();
            next_windows.clear();
            // §5.2: the workspace is the authority; the snapshot is the engine's tab set.
            // Engine tabs whose item is closed, archived or deleted come back as close
            // commands and are never adopted; tabs with no item are adopted into Today of
            // the strip's shown space in this transaction; workspace-open rows the engine
            // lacks become unloaded.
            let mut seen: HashSet<Id> = HashSet::new();
            let mut claimed_lives: HashSet<Id> = HashSet::new();
            let mut close_seen: HashSet<Id> = HashSet::new();
            let mut adopted_for: HashMap<Id, Id> = HashMap::new();
            for strip in &transaction.strips {
                for tab in &strip.tabs {
                    match &tab.item {
                        Some(item) => match next.items.get(item) {
                            Some(existing) if matches!(existing.kind, ItemKind::Tab { .. })
                                && matches!(existing.lifecycle, Lifecycle::Open | Lifecycle::Unloaded)
                                && !claimed_lives.contains(&tab.live_id) && !seen.contains(item) => {
                                seen.insert(item.clone());
                                claimed_lives.insert(tab.live_id.clone());
                                // The engine owns which tabs exist: a row it reports live
                                // is open from here on.
                                if existing.lifecycle == Lifecycle::Unloaded {
                                    let mut changed = existing.clone();
                                    changed.lifecycle = Lifecycle::Open;
                                    changed.lifecycle_changed_at = next.lifecycle_time();
                                    ops.push(Op::Put(Record::Item(changed)));
                                }
                            }
                            _ => {
                                if close_seen.insert(item.clone()) {
                                    let command = Command {
                                        id: self.fresh_command_id(&next), kind: CommandKind::Close,
                                        item: item.clone(), url: None,
                                    };
                                    next_pending.insert(command.id.clone(), (command.kind, command.item.clone()));
                                    outcome.commands.push(command);
                                }
                            }
                        }
                        None => {
                            if claimed_lives.contains(&tab.live_id) { continue; }
                            if let Some((mut adopt_ops, id)) = Self::adopt(&mut next, &strip.window, &tab.profile, strip.active.is_none() && strip.tabs.len() == 1) {
                                ops.append(&mut adopt_ops);
                                outcome.adopted.push((tab.live_id.clone(), id.clone()));
                                adopted_for.insert(tab.live_id.clone(), id.clone());
                                seen.insert(id);
                                claimed_lives.insert(tab.live_id.clone());
                            }
                        }
                    }
                }
            }
            // The map is rebuilt from the snapshot claims, not merged: the epoch changed.
            for strip in &transaction.strips {
                for tab in &strip.tabs {
                    // An adopted tab's strip carries no item; the item the adoption wrote
                    // for it is what the map now names.
                    let item = tab.item.as_ref().or_else(|| adopted_for.get(&tab.live_id));
                    if let Some(item) = item {
                        if seen.contains(item) && !next_map.contains_key(item) && !next_reverse.contains_key(&tab.live_id) {
                            next_map.insert(item.clone(), tab.live_id.clone());
                            next_reverse.insert(tab.live_id.clone(), item.clone());
                            next_windows.insert(tab.live_id.clone(), strip.window.clone());
                        }
                    }
                }
            }
            for item in &next.items.values().cloned().collect::<Vec<_>>() {
                if matches!(item.kind, ItemKind::Tab { .. }) && matches!(item.lifecycle, Lifecycle::Open)
                    && !seen.contains(&item.id) {
                    let mut changed = item.clone();
                    changed.lifecycle = Lifecycle::Unloaded;
                    changed.lifecycle_changed_at = next.lifecycle_time();
                    ops.push(Op::Put(Record::Item(changed)));
                }
            }
            for op in &ops { next.apply(op); }
            Self::update_metadata(&mut next, &transaction.strips, &next_reverse, &mut ops);
            // The strips' active tab is Chrome's report of the selection; recorded for the
            // mapped rows of each window.
            for strip in &transaction.strips {
                if let Some(active) = &strip.active {
                    if let Some(item) = next_reverse.get(active).cloned() {
                        if Self::selection_allowed(&next, &next_map, &next_windows, &strip.window, false) {
                          if let Ok(mut selection_ops) = next.record_active(&strip.window, &item, next.lifecycle_time()) {
                            ops.append(&mut selection_ops);
                          }
                        }
                    }
                }
            }
            outcome.adopted.retain(|(live, _)| next_reverse.contains_key(live));
            // Commit the reconcile in one step, like the within-epoch path does.
            *workspace = next;
            self.map = next_map;
            self.reverse = next_reverse;
            self.windows = next_windows;
            self.pending = next_pending;
            self.selection_intents = next_intents;
            return (ops, outcome);
        }

        // Windows the transaction carries: the gone pass is limited to them, so a
        // transaction naming one window leaves the other windows' tabs alone. A closed
        // window arrives as an empty strip.
        let carried: HashSet<&Id> = transaction.strips.iter().map(|strip| &strip.window).collect();
        let reported: HashSet<&Id> = transaction.strips.iter()
            .flat_map(|strip| strip.tabs.iter().map(|tab| &tab.live_id)).collect();
        let intent = if let Cause::Command(id) = &transaction.cause {
            next_intents.remove(id).and_then(|window| self.pending.get(id).map(|(_, item)| (window, item.clone())))
        } else { None };
        if let Cause::Command(id) = &transaction.cause {
            if !reported.contains(id) && next_pending.get(id).is_some_and(|(kind, _)| *kind == CommandKind::Open) {
                Self::cancel_open(&mut next, id, &mut next_map, &mut next_reverse,
                                  &mut next_windows, &mut next_pending, &mut ops);
            } else {
                next_pending.remove(id);
            }
        }
        let claimed_items: HashSet<&Id> = transaction.strips.iter()
            .flat_map(|strip| strip.tabs.iter().filter_map(|tab| tab.item.as_ref())).collect();
        let pending_opens: HashSet<&Id> = self.pending.iter()
            .filter(|(_, (kind, _))| *kind == CommandKind::Open).map(|(_, (_, item))| item).collect();
        let pending_closes: HashSet<&Id> = self.pending.iter()
            .filter(|(_, (kind, _))| *kind == CommandKind::Close).map(|(_, (_, item))| item).collect();

        // A mapped live tab the strips no longer carry leaves the map for every cause;
        // a Chrome-caused one also closes its row with the ⌘W rule — whose ops select
        // the successor by the selection history — and returns an activate for that
        // successor instead of trusting Chrome's next active tab.
        let mut gone: Vec<(Id, Id)> = self.reverse.iter()
            .filter(|(live, item)| !reported.contains(*live) && !claimed_items.contains(*item)
                && !pending_opens.contains(*item)
                && next_windows.get(*live).is_some_and(|window| carried.contains(window)))
            .map(|(live, item)| (live.clone(), item.clone())).collect();
        gone.sort();
        let mut changed_windows: HashSet<Id> = HashSet::new();
        for (live, item) in gone {
            let window = next_windows.get(&live).cloned();
            next_map.remove(&item);
            next_reverse.remove(&live);
            next_windows.remove(&live);
            // A row that left the map cannot answer an Activate any more, and the engine may
            // swallow one without replying (no contents, or a tab closed in between). Drop the
            // in-flight ones for the row, so a reopened row is not silenced by a stale entry.
            next_pending.retain(|_, (kind, pending)| !(*kind == CommandKind::Activate && pending == &item));
            if transaction.cause == Cause::Chrome {
                if let Some(window) = window {
                    let before = next.selected(&window).map(str::to_string);
                    if let Ok(mut close_ops) = next.close_item(&item) {
                        ops.append(&mut close_ops);
                        let after = next.selected(&window).map(str::to_string);
                        if after != before {
                            // The closed tab was the active one: the rule's successor is
                            // the answer, and Chrome's next active tab is not recorded
                            // for this window.
                            changed_windows.insert(window.clone());
                            if let Some(successor) = after {
                                outcome.commands.push(self.reactivate(&next, &mut next_pending, &successor));
                            }
                        }
                    }
                }
            }
        }

        // The strips' mappings join the map; one live tab per item and one item per live
        // tab, so a transaction that would double-map is dropped whole (its rev stays
        // consumed). A tab whose item has a pending close is left alone — no re-map, no
        // re-selection, no second close. A tab with no item is adopted in this
        // transaction, the same way the snapshot adopts it.
        for strip in &transaction.strips {
            for tab in &strip.tabs {
                let Some(item) = &tab.item else {
                    if next_reverse.contains_key(&tab.live_id) { continue; }
                    if let Some((mut adopt_ops, id)) = Self::adopt(&mut next, &strip.window, &tab.profile, strip.active.is_none() && strip.tabs.len() == 1) {
                        ops.append(&mut adopt_ops);
                        next_map.insert(id.clone(), tab.live_id.clone());
                        next_reverse.insert(tab.live_id.clone(), id.clone());
                        next_windows.insert(tab.live_id.clone(), strip.window.clone());
                        outcome.adopted.push((tab.live_id.clone(), id));
                    }
                    continue;
                };
                // A pending close is in flight for the item: no re-map, no re-selection,
                // no second close until the engine's completion lands.
                if pending_closes.contains(item) { continue; }
                match next.items.get(item) {
                    Some(existing) if matches!(existing.kind, ItemKind::Tab { .. })
                        && matches!(existing.lifecycle, Lifecycle::Open | Lifecycle::Unloaded) => {}
                    _ => {
                        if !outcome.commands.iter().any(|c| c.kind == CommandKind::Close && c.item == *item) {
                            let command = Command {
                                id: self.fresh_command_id(&next), kind: CommandKind::Close,
                                item: item.clone(), url: None,
                            };
                            next_pending.insert(command.id.clone(), (command.kind, command.item.clone()));
                            outcome.commands.push(command);
                        }
                        continue;
                    }
                }
                if next_reverse.get(&tab.live_id).is_some_and(|current| current != item)
                    || next_map.get(item).is_some_and(|current| current != &tab.live_id) {
                    self.dropped += 1;
                    return (Vec::new(), ApplyOutcome::default());
                }
                let previous = next_map.insert(item.clone(), tab.live_id.clone());
                if let Some(previous) = previous {
                    next_reverse.remove(&previous);
                    next_windows.remove(&previous);
                }
                let previous_item = next_reverse.insert(tab.live_id.clone(), item.clone());
                if let Some(previous_item) = previous_item {
                    next_map.remove(&previous_item);
                }
                next_windows.insert(tab.live_id.clone(), strip.window.clone());
            }
        }
        for strip in &transaction.strips {
            if matches!(transaction.cause, Cause::Engine) || changed_windows.contains(&strip.window) { continue; }
            if let Some(active) = &strip.active {
                if let Some(item) = next_reverse.get(active).cloned() {
                    let explicit = intent.as_ref().is_some_and(|(window, target)| window == &strip.window && target == &item);
                    if !Self::selection_allowed(&next, &next_map, &next_windows, &strip.window, explicit) { continue; }
                    // A strip can arrive after the window showed another space: a selection
                    // made before the switch completes late, and its active tab belongs to
                    // the space the window no longer shows. Recording it would select a row
                    // outside the shown space, leaving the page empty; the strip's other
                    // effects (map, metadata) stand.
                    let shown_space = next.shown_space(&strip.window).map(str::to_string);
                    let in_shown_space = shown_space.as_deref()
                        .is_none_or(|space| next.is_in_space(&item, space));
                    if !in_shown_space {
                        // Chrome's active tab would otherwise stay on the space the window
                        // left, and the page follows Chrome, so the sidebar would name one
                        // row while the other space's page showed. The answer is the close
                        // successor's re-activation of the row the window keeps: the reply
                        // names a tab of the shown space, its strip passes this guard and
                        // records nothing new, so the exchange ends there. Only a selection
                        // the window shows is re-activated; one outside it is left for the
                        // next strip of its own space to record. A strip that still names the
                        // off-space tab while the Activate is in flight finds the in-flight
                        // entry and asks for nothing, so a run of Chrome strips does not mint
                        // one command each.
                        if let Some(selected) = next.selected(&strip.window).map(str::to_string)
                            && shown_space.as_deref().is_some_and(|space| next.is_in_space(&selected, space))
                            && selected != item && next_map.contains_key(&selected)
                            && !outcome.commands.iter().any(|command| {
                                command.kind == CommandKind::Activate && command.item == selected
                            })
                            && !next_pending.values().any(|(kind, pending_item)| {
                                *kind == CommandKind::Activate && pending_item == &selected
                            }) {
                            outcome.commands.push(self.reactivate(&next, &mut next_pending, &selected));
                        }
                        continue;
                    }
                    if next.selected(&strip.window) != Some(item.as_str())
                        || next.items.get(&item).is_some_and(|item| item.lifecycle == Lifecycle::Unloaded) {
                        if let Ok(mut selection_ops) = next.record_active(&strip.window, &item, next.lifecycle_time()) {
                            ops.append(&mut selection_ops);
                        }
                    }
                }
            }
        }

        Self::update_metadata(&mut next, &transaction.strips, &next_reverse, &mut ops);
        next_intents.retain(|id, _| next_pending.contains_key(id));

        // Commit: the workspace and the maps take the accepted transaction in one step.
        *workspace = next;
        self.map = next_map;
        self.reverse = next_reverse;
        self.windows = next_windows;
        self.pending = next_pending;
        self.selection_intents = next_intents;
        (ops, outcome)
    }

    fn update_metadata(workspace: &mut Workspace, strips: &[Strip], reverse: &HashMap<Id, Id>, ops: &mut Vec<Op>) {
        for tab in strips.iter().flat_map(|strip| &strip.tabs) {
            let Some(id) = reverse.get(&tab.live_id) else { continue };
            if !workspace.list_for(id).is_some_and(|(_, today)| today) { continue; }
            let Some(mut item) = workspace.items.get(id).cloned() else { continue };
            let ItemKind::Tab { url, saved_title } = &mut item.kind else { continue };
            let mut changed = false;
            if let Some(next) = tab.url.as_ref().filter(|next| !next.is_empty()) {
                if (url.is_empty() || tab.navigated) && *url != *next { *url = next.clone(); changed = true; }
            }
            if let Some(next) = tab.title.as_ref().filter(|_| tab.url.as_ref() == Some(url)) {
                let next = (!next.is_empty()).then(|| next.clone());
                if *saved_title != next { *saved_title = next; changed = true; }
            }
            if changed {
                let op = Op::Put(Record::Item(item));
                workspace.apply(&op);
                ops.push(op);
            }
        }
    }

    /// Adopts an itemless engine tab: one open row at the end of the shown space's Today,
    /// membership in the same transaction (§5.2). The engine owns the tab's url until
    /// Chrome reports a navigation, so the core's copy stays empty.
    fn adopt(workspace: &mut Workspace, window: &str, profile: &Profile, sole_inactive: bool) -> Option<(Vec<Op>, Id)> {
        let space_id = workspace.recent_space_for_profile(window, profile)?.to_string();
        let today = workspace.spaces.iter().find(|space| space.id == space_id).map(|space| space.today.clone())?;
        let id = Self::fresh_item_id(workspace);
        let order = crate::order::key_between(
            workspace.children(&today).last().map(|item| item.membership.order.as_str()), None);
        let item = Item {
            id: id.clone(),
            membership: Membership { parent: Some(today), order, hlc: Default::default(), previous_parent: None },
            title: None,
            kind: ItemKind::Tab { url: String::new(), saved_title: None },
            lifecycle: Lifecycle::Open,
            lifecycle_changed_at: workspace.lifecycle_time(),
        };
        let op = Op::Put(Record::Item(item));
        workspace.apply(&op);
        let mut ops = vec![op];
        if workspace.is_private() && sole_inactive && workspace.selected(window).is_none() {
            if let Ok(selection) = workspace.record_active(window, &id, workspace.lifecycle_time()) {
                ops.extend(selection);
            }
        }
        Some((ops, id))
    }
}
