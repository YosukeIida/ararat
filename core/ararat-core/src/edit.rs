use std::collections::HashSet;

use crate::model::{Id, ItemKind, Kind, Lifecycle, Op, Profile, Record, WindowState, Workspace};

pub const HISTORY_LIMIT: usize = 50;

#[derive(Debug, PartialEq, Eq)]
pub struct EditError(pub String);

impl WindowState {
    pub(crate) fn select(&mut self, id: Option<Id>) {
        if let Some(id) = &id {
            self.history.retain(|entry| entry != id);
            self.history.insert(0, id.clone());
            self.history.truncate(HISTORY_LIMIT);
        }
        self.selected = id;
    }
}

impl Workspace {
    pub fn duplicate_item(&mut self, id: &str) -> Result<Vec<Op>, EditError> {
        self.check_tree().map_err(EditError)?;
        let original = self.movable_item(id)?;
        let list_root = self.list_for(&original.id).unwrap().0.to_string();
        let parent = original.membership.parent.as_deref().ok_or_else(|| EditError("item has no parent".into()))?;
        let siblings: Vec<_> = self.children(parent).into_iter()
            .filter(|item| matches!(item.lifecycle, Lifecycle::Open | Lifecycle::Unloaded)).collect();
        let index = siblings.iter().position(|item| item.id == original.id).unwrap() + 1;
        let (order, mut ops) = self.item_order(parent, index, &HashSet::new())?;
        let mut originals = vec![original.clone()];
        let mut index = 0;
        while index < originals.len() {
            originals.extend(self.children(&originals[index].id).into_iter()
                .filter(|item| matches!(item.lifecycle, Lifecycle::Open | Lifecycle::Unloaded)).cloned());
            index += 1;
        }
        let mut ids = std::collections::HashMap::new();
        // Why not Swift ids or uuid: Swift cannot know subtree size; randomized SipHash plus collision checks avoids a new dependency.
        for item in &originals {
            use std::hash::BuildHasher;
            let id = loop {
                let random = std::collections::hash_map::RandomState::new();
                let id = format!("{:016x}{:016x}", random.hash_one(0u8), random.hash_one(1u8));
                if !self.items.contains_key(&id) && !self.spaces.iter().any(|s| s.id == id)
                    && !ids.values().any(|value| value == &id) { break id; }
            };
            ids.insert(item.id.clone(), id);
        }
        let now = self.lifecycle_time();
        for mut item in originals {
            let old_id = item.id.clone();
            item.id = ids[&old_id].clone();
            if old_id == original.id { item.membership.order = order.clone(); }
            else { item.membership.parent = item.membership.parent.as_ref().map(|parent| ids[parent].clone()); }
            item.membership.previous_parent = (old_id == original.id).then(|| list_root.clone());
            item.membership.hlc = Default::default();
            item.lifecycle = Lifecycle::Unloaded;
            item.lifecycle_changed_at = now;
            match &mut item.kind {
                ItemKind::Tab { .. } => ops.push(Op::Put(Record::LastSelected { item: item.id.clone(), at: now })),
                ItemKind::Folder => ops.push(Op::Put(Record::FolderState {
                    item: item.id.clone(), collapsed: self.folder_collapsed.get(&old_id).copied().unwrap_or(false),
                })),
                ItemKind::Split { width_factors, .. } => {
                    *width_factors = width_factors.iter().filter_map(|(id, width)| ids.get(id).map(|id| (id.clone(), *width))).collect();
                }
                ItemKind::Container => unreachable!(),
            }
            ops.push(Op::Put(Record::Item(item)));
        }
        Ok(self.commit_edit(ops))
    }

    fn commit_edit(&mut self, ops: Vec<Op>) -> Vec<Op> {
        for op in &ops { self.apply(op); }
        ops
    }

    fn movable_item(&self, id: &str) -> Result<crate::model::Item, EditError> {
        let mut item = self.items.get(id).ok_or_else(|| EditError(format!("unknown item {id}")))?;
        if !matches!(item.lifecycle, Lifecycle::Open | Lifecycle::Unloaded)
            || matches!(item.kind, ItemKind::Container) || self.list_for(id).is_none() {
            return Err(EditError(format!("item {id} cannot move")));
        }
        let mut parent = item.membership.parent.as_deref();
        while let Some(ancestor) = parent.and_then(|id| self.items.get(id)) {
            if !matches!(ancestor.lifecycle, Lifecycle::Open | Lifecycle::Unloaded) {
                return Err(EditError("item has an inactive ancestor".into()));
            }
            if matches!(ancestor.kind, ItemKind::Split { .. }) { item = ancestor; }
            parent = ancestor.membership.parent.as_deref();
        }
        Ok(item.clone())
    }

    fn check_destination(&self, item: &crate::model::Item, container: &str) -> Result<(), EditError> {
        let target = self.items.get(container).ok_or_else(|| EditError(format!("unknown container {container}")))?;
        if !matches!(target.kind, ItemKind::Container | ItemKind::Folder)
            || !matches!(target.lifecycle, Lifecycle::Open | Lifecycle::Unloaded) {
            return Err(EditError("destination is not an open container or folder".into()));
        }
        let (root, today) = self.list_for(container).ok_or_else(|| EditError("destination has no active list".into()))?;
        if matches!(item.kind, ItemKind::Folder) && (today || !self.spaces.iter().any(|s| s.pinned == root)) {
            return Err(EditError("folders belong in pinned".into()));
        }
        if self.favorites.values().any(|id| id == root) && !matches!(item.kind, ItemKind::Tab { .. }) {
            return Err(EditError("favorites hold tabs only".into()));
        }
        let mut parent = Some(container);
        while let Some(ancestor) = parent.and_then(|id| self.items.get(id)) {
            if ancestor.id == item.id { return Err(EditError("cannot move an item into its subtree".into())); }
            if !matches!(ancestor.lifecycle, Lifecycle::Open | Lifecycle::Unloaded) {
                return Err(EditError("destination has an inactive ancestor".into()));
            }
            parent = ancestor.membership.parent.as_deref();
        }
        Ok(())
    }

    fn insertion_keys(others: &[&crate::model::Item], index: usize, count: usize) -> Result<(Vec<String>, Vec<Op>), EditError> {
        if index > others.len() { return Err(EditError("item index out of range".into())); }
        let mut before = index.checked_sub(1).and_then(|i| others.get(i)).map(|i| i.membership.order.clone());
        let mut after = others.get(index).map(|i| i.membership.order.clone());
        let mut ops = Vec::new();
        if count > 0 && before.as_ref().zip(after.as_ref()).is_some_and(|(a, b)| a == b) {
            let tied: Vec<_> = others[index..].iter().take_while(|i| Some(&i.membership.order) == before.as_ref()).collect();
            let next = others.get(index + tied.len()).map(|i| i.membership.order.as_str());
            let mut previous = before.clone();
            for (position, item) in tied.into_iter().enumerate() {
                let mut item = (**item).clone();
                item.membership.order = crate::order::key_between(previous.as_deref(), next);
                if position == 0 { after = Some(item.membership.order.clone()); }
                previous = Some(item.membership.order.clone());
                ops.push(Op::Put(Record::Item(item)));
            }
        }
        let mut keys = Vec::new();
        for _ in 0..count {
            let key = crate::order::key_between(before.as_deref(), after.as_deref());
            before = Some(key.clone());
            keys.push(key);
        }
        Ok((keys, ops))
    }

    fn item_order(&self, container: &str, index: usize, excluding: &HashSet<Id>) -> Result<(String, Vec<Op>), EditError> {
        let others: Vec<_> = self.children(container).into_iter()
            .filter(|item| !excluding.contains(&item.id) && matches!(item.lifecycle, Lifecycle::Open | Lifecycle::Unloaded)).collect();
        let (mut keys, ops) = Self::insertion_keys(&others, index, 1)?;
        Ok((keys.remove(0), ops))
    }

    pub fn item_profile(&self, id: &str) -> Option<&crate::model::Profile> {
        let (root, _) = self.list_for(id)?;
        self.spaces.iter().find(|s| s.pinned == root || s.today == root).map(|s| &s.profile)
            .or_else(|| self.favorites.iter().find(|(_, container)| container.as_str() == root).map(|(p, _)| p))
    }

    pub fn move_item(&mut self, id: &str, container: &str, index: usize, open_folder: bool) -> Result<Vec<Op>, EditError> {
        self.move_item_at(id, container, index, open_folder, self.lifecycle_time())
    }

    pub fn move_item_at(&mut self, id: &str, container: &str, index: usize, open_folder: bool, now: u64) -> Result<Vec<Op>, EditError> {
        self.check_tree().map_err(EditError)?;
        let mut item = self.movable_item(id)?;
        self.check_destination(&item, container)?;
        if self.item_profile(&item.id) != self.item_profile(container) {
            return Err(EditError("cannot move across profiles".into()));
        }
        let open_folder = open_folder && matches!(self.items[container].kind, ItemKind::Folder)
            && self.folder_collapsed.get(container).copied().unwrap_or(false);
        let same_parent = item.membership.parent.as_deref() == Some(container);
        if same_parent && self.children(container).into_iter().filter(|i| matches!(i.lifecycle, Lifecycle::Open | Lifecycle::Unloaded))
            .position(|i| i.id == item.id) == Some(index) {
            return if open_folder {
                self.set_folder_collapsed(container, false)
            } else { Ok(Vec::new()) };
        }
        let entering_today = !self.list_for(&item.id).is_some_and(|(_, today)| today)
            && self.list_for(container).is_some_and(|(_, today)| today);
        let (order, mut ops) = self.item_order(container, index, &HashSet::from([item.id.clone()]))?;
        item.membership.order = order;
        if !same_parent { item.membership.previous_parent = item.membership.parent.replace(container.into()); }
        let id = item.id.clone();
        ops.push(Op::Put(Record::Item(item)));
        for op in &ops { self.apply(op); }
        if entering_today { ops.extend(self.stamp_selection(&id, now)); }
        if open_folder {
            ops.extend(self.set_folder_collapsed(container, false)?);
        }
        Ok(ops)
    }

    pub fn create_folder(&mut self, id: &str, name: &str, container: &str, index: usize, wrapping: &[Id]) -> Result<Vec<Op>, EditError> {
        self.check_tree().map_err(EditError)?;
        let name = name.trim();
        if name.is_empty() || id.trim().is_empty() || self.items.contains_key(id) || self.spaces.iter().any(|s| s.id == id) {
            return Err(EditError("folder name or id is empty, or id already exists".into()));
        }
        let (root, _) = self.list_for(container).ok_or_else(|| EditError("destination has no active list".into()))?;
        let space = self.spaces.iter().find(|s| s.pinned == root)
            .ok_or_else(|| EditError("folders belong in pinned".into()))?;
        let mut selected = HashSet::new();
        for id in wrapping {
            let item = self.movable_item(id)?;
            if !self.list_for(&item.id).is_some_and(|(root, _)| root == space.pinned || root == space.today) {
                return Err(EditError("wrap selection must belong to the destination space, excluding favorites".into()));
            }
            selected.insert(item.id);
        }
        for id in selected.iter().map(String::as_str).chain(std::iter::once(container)) {
            let mut parent = self.items[id].membership.parent.as_deref();
            if id == container && selected.contains(id) { return Err(EditError("cannot wrap the destination".into())); }
            while let Some(ancestor) = parent.and_then(|id| self.items.get(id)) {
                if selected.contains(&ancestor.id) { return Err(EditError("wrap selection contains an ancestor".into())); }
                parent = ancestor.membership.parent.as_deref();
            }
        }
        let ordered: Vec<_> = [&space.pinned, &space.today].into_iter()
            .flat_map(|root| self.outline_entries(root)).filter(|(_, i, _)| selected.contains(&i.id))
            .map(|(_, i, _)| i.clone()).collect();
        let (order, mut ops) = self.item_order(container, index, &selected)?;
        let folder = crate::model::Item {
            id: id.into(), title: Some(name.into()), kind: ItemKind::Folder, lifecycle: Lifecycle::Open,
            lifecycle_changed_at: self.lifecycle_time(), membership: crate::model::Membership {
                parent: Some(container.into()), previous_parent: Some(root.into()), hlc: Default::default(),
                order,
            },
        };
        self.check_destination(&folder, container)?;
        ops.push(Op::Put(Record::Item(folder)));
        let mut previous = None;
        for mut item in ordered {
            item.membership.previous_parent = item.membership.parent.replace(id.into());
            item.membership.order = crate::order::key_between(previous.as_deref(), None);
            previous = Some(item.membership.order.clone());
            ops.push(Op::Put(Record::Item(item)));
        }
        Ok(self.commit_edit(ops))
    }

    pub fn rename_folder(&mut self, id: &str, name: &str) -> Result<Vec<Op>, EditError> {
        let name = name.trim();
        let mut item = self.items.get(id).filter(|i| matches!(i.kind, ItemKind::Folder)).cloned()
            .ok_or_else(|| EditError(format!("item {id} is not a folder")))?;
        if name.is_empty() { return Err(EditError("folder name is empty".into())); }
        item.title = Some(name.into());
        Ok(self.commit_edit(vec![Op::Put(Record::Item(item))]))
    }

    pub fn rename_tab(&mut self, id: &str, title: &str) -> Result<Vec<Op>, EditError> {
        let mut item = self.items.get(id).filter(|i| matches!(i.kind, ItemKind::Tab { .. })).cloned()
            .ok_or_else(|| EditError(format!("item {id} is not a tab")))?;
        item.title = (!title.trim().is_empty()).then(|| title.trim().into());
        Ok(self.commit_edit(vec![Op::Put(Record::Item(item))]))
    }

    // A new tab from the command bar: a tab at the top of the shown space's Today list, selected.
    // It is Open like a restored tab (the selection surfaces in snapshots); a browser runtime
    // loads its URL when the engine lands.
    pub fn create_tab(&mut self, window: &str, url: &str) -> Result<Vec<Op>, EditError> {
        self.check_tree().map_err(EditError)?;
        let space_id = self.shown_space(window).ok_or_else(|| EditError("no space to create a tab in".into()))?.to_owned();
        let today = self.spaces.iter().find(|space| space.id == space_id).map(|space| space.today.clone())
            .ok_or_else(|| EditError("no space to create a tab in".into()))?;
        let id = loop {
            use std::hash::BuildHasher;
            let random = std::collections::hash_map::RandomState::new();
            let id = format!("{:016x}{:016x}", random.hash_one(0u8), random.hash_one(1u8));
            if !self.items.contains_key(&id) && !self.spaces.iter().any(|space| space.id == id) { break id; }
        };
        let (order, mut ops) = self.item_order(&today, 0, &HashSet::new())?;
        let now = self.lifecycle_time();
        let item = crate::model::Item {
            id: id.clone(),
            membership: crate::model::Membership { parent: Some(today), previous_parent: None, hlc: Default::default(), order },
            title: None,
            kind: ItemKind::Tab { url: url.into(), saved_title: None },
            lifecycle: Lifecycle::Open,
            lifecycle_changed_at: now,
        };
        self.check_destination(&item, &item.membership.parent.as_ref().map(String::as_str).unwrap_or_default())?;
        ops.extend(self.stamp_outgoing(window, Some(&id), now));
        let mut state = self.window_state(window);
        state.shown_space = Some(space_id);
        state.select(Some(id.clone()));
        ops.push(Op::Put(Record::Item(item)));
        state.changed_at = now;
        ops.push(Op::Put(Record::Window(state)));
        for op in &ops { self.apply(op); }
        ops.extend(self.stamp_selection(&id, now));
        Ok(ops)
    }

    // The ⌘L commit: the current tab navigates to the edited URL.
    pub fn set_tab_url(&mut self, id: &str, url: &str) -> Result<Vec<Op>, EditError> {
        let mut item = self.items.get(id).filter(|i| matches!(i.kind, ItemKind::Tab { .. })
            && matches!(i.lifecycle, Lifecycle::Open | Lifecycle::Unloaded)).cloned()
            .ok_or_else(|| EditError(format!("item {id} is not an open tab")))?;
        match &mut item.kind { ItemKind::Tab { url: current, .. } => *current = url.into(), _ => unreachable!() }
        Ok(self.commit_edit(vec![Op::Put(Record::Item(item))]))
    }

    pub fn set_folder_collapsed(&mut self, id: &str, collapsed: bool) -> Result<Vec<Op>, EditError> {
        if !self.items.get(id).is_some_and(|i| matches!(i.kind, ItemKind::Folder)) {
            return Err(EditError(format!("item {id} is not a folder")));
        }
        Ok(self.commit_edit(vec![Op::Put(Record::FolderState { item: id.into(), collapsed })]))
    }

    pub fn delete_folder(&mut self, id: &str) -> Result<Vec<Op>, EditError> {
        self.check_tree().map_err(EditError)?;
        if !self.items.get(id).is_some_and(|item| matches!(item.kind, ItemKind::Folder)) {
            return Err(EditError(format!("item {id} is not a folder")));
        }
        let (root, _) = self.list_for(id).ok_or_else(|| EditError("folder has no space".into()))?;
        let pinned = self.spaces.iter().find(|space| space.pinned == root || space.today == root)
            .ok_or_else(|| EditError("folder has no space".into()))?.pinned.clone();
        let descendants: Vec<_> = self.outline_entries(id).into_iter().map(|(_, item, _)| item.id.clone()).collect();
        let folders: HashSet<_> = std::iter::once(id.to_string()).chain(descendants.iter()
            .filter(|id| matches!(self.items[*id].kind, ItemKind::Folder)).cloned()).collect();
        let mut next = self.clone();
        let changed_at = self.lifecycle_time();
        let mut ops = Vec::new();
        for id in &descendants {
            if matches!(next.items[id].kind, ItemKind::Tab { .. } | ItemKind::Split { .. })
                && matches!(next.items[id].lifecycle, Lifecycle::Open | Lifecycle::Unloaded) {
                ops.extend(next.finish_item(id, true, changed_at)?);
            }
        }
        let mut cleanup = Vec::new();
        for id in &descendants {
            let mut item = next.items[id].clone();
            if !folders.contains(id) && item.membership.parent.as_ref().is_some_and(|parent| folders.contains(parent)) {
                item.membership.previous_parent = item.membership.parent.replace(pinned.clone());
                cleanup.push(Op::Put(Record::Item(item)));
            }
        }
        for folder in descendants.iter().rev().map(String::as_str).chain(std::iter::once(id)).filter(|id| folders.contains(*id)) {
            cleanup.push(Op::Delete(crate::model::Kind::Item, folder.into()));
            if next.folder_collapsed.contains_key(folder) { cleanup.push(Op::Delete(crate::model::Kind::FolderState, folder.into())); }
        }
        ops.extend(next.commit_edit(cleanup));
        *self = next;
        Ok(ops)
    }

    fn edit_space(&mut self, id: &str, edit: impl FnOnce(&mut crate::model::Space)) -> Result<Vec<Op>, EditError> {
        let mut space = self.spaces.iter().find(|space| space.id == id).cloned()
            .ok_or_else(|| EditError(format!("unknown space {id}")))?;
        edit(&mut space);
        let ops = vec![Op::Put(Record::Space(space))];
        for op in &ops { self.apply(op); }
        Ok(ops)
    }

    pub fn rename_space(&mut self, id: &str, name: &str) -> Result<Vec<Op>, EditError> {
        let name = name.trim();
        if name.is_empty() { return Err(EditError("space name is empty".into())); }
        self.edit_space(id, |space| space.title = name.into())
    }

    pub fn set_space_icon(&mut self, id: &str, icon: Option<String>) -> Result<Vec<Op>, EditError> {
        if icon.as_ref().is_some_and(|icon| icon.trim().is_empty() || icon.len() > 64
            || icon.chars().any(|c| c.is_whitespace() || c.is_control())) {
            return Err(EditError("invalid space icon".into()));
        }
        self.edit_space(id, |space| space.icon = icon)
    }

    pub fn set_space_look(&mut self, id: &str, look: Option<crate::model::Look>) -> Result<Vec<Op>, EditError> {
        if look.as_ref().is_some_and(|look| !look.is_valid()) { return Err(EditError("invalid space look".into())); }
        self.edit_space(id, |space| space.look = look)
    }

    pub fn move_space(&mut self, id: &str, index: usize) -> Result<Vec<Op>, EditError> {
        if index >= self.spaces.len() { return Err(EditError("space index out of range".into())); }
        let others: Vec<_> = self.spaces.iter().filter(|space| space.id != id).collect();
        let order = crate::order::key_between(index.checked_sub(1).and_then(|i| others.get(i)).map(|s| s.order.as_str()), others.get(index).map(|s| s.order.as_str()));
        self.edit_space(id, |space| space.order = order)
    }

    pub fn delete_space(&mut self, id: &str) -> Result<Vec<Op>, EditError> {
        self.check_tree().map_err(EditError)?;
        let index = self.spaces.iter().position(|space| space.id == id)
            .ok_or_else(|| EditError(format!("unknown space {id}")))?;
        if self.spaces.len() == 1 { return Err(EditError("cannot delete the last space".into())); }
        let space = &self.spaces[index];
        let neighbour = &self.spaces[if index + 1 < self.spaces.len() { index + 1 } else { index - 1 }].id;
        let changing: HashSet<_> = [&space.pinned, &space.today].into_iter()
            .flat_map(|root| self.outline_entries(root).into_iter().map(|(_, item, _)| item.id.clone())).collect();
        let changed_at = self.lifecycle_time();
        let mut ids: Vec<_> = changing.iter().collect();
        ids.sort();
        let mut ops: Vec<_> = ids.into_iter().filter(|id| matches!(self.items[*id].lifecycle, Lifecycle::Open | Lifecycle::Unloaded)).map(|id| {
            let mut item = self.items[id].clone();
            item.lifecycle = Lifecycle::Archived;
            item.lifecycle_changed_at = changed_at;
            Op::Put(Record::Item(item))
        }).collect();
        ops.extend(self.history_purge_ops(&ops));
        let mut windows: Vec<_> = self.windows.values().cloned().collect();
        windows.sort_by(|a, b| a.id.cmp(&b.id));
        for mut state in windows {
            let before = state.clone();
            if self.shown_space(&state.id) == Some(id) { state.shown_space = Some(neighbour.clone()); }
            if state.selected.as_ref().is_some_and(|id| changing.contains(id)) { state.selected = None; }
            state.history.retain(|id| !changing.contains(id));
            if state != before {
                state.changed_at = changed_at;
                ops.push(Op::Put(Record::Window(state)));
            }
        }
        ops.push(Op::Delete(crate::model::Kind::Space, id.into()));
        for op in &ops { self.apply(op); }
        Ok(ops)
    }

    pub fn create_space(&mut self, window: &str, name: &str, id: &str) -> Result<Vec<Op>, EditError> {
        let name = name.trim();
        if name.is_empty() { return Err(EditError("space name is empty".into())); }
        let pinned = format!("{id}:pinned");
        let today = format!("{id}:today");
        if id.trim().is_empty() || [id, pinned.as_str(), today.as_str()].iter().any(|id| {
            self.items.contains_key(*id) || self.spaces.iter().any(|space| space.id == *id)
        }) { return Err(EditError("space id already exists or is empty".into())); }
        let profile = self.shown_space(window).and_then(|id| self.spaces.iter().find(|space| space.id == id))
            .map_or(crate::model::Profile::Default, |space| space.profile.clone());
        let space = crate::model::Space {
            id: id.into(), order: crate::order::key_between(self.spaces.last().map(|space| space.order.as_str()), None),
            title: name.into(), profile, icon: None, look: None, pinned: pinned.clone(), today: today.clone(),
        };
        let changed_at = self.lifecycle_time();
        let mut ops = self.stamp_outgoing(window, None, changed_at);
        let mut state = self.window_state(window);
        state.shown_space = Some(id.into());
        state.space_history.insert(0, id.into());
        state.select(None);
        ops.push(Op::Put(Record::Space(space)));
        for id in [pinned, today] {
            ops.push(Op::Put(Record::Item(crate::model::Item {
                id, membership: crate::model::Membership { parent: None, order: crate::order::key_between(None, None), hlc: Default::default(), previous_parent: None },
                title: None, kind: ItemKind::Container, lifecycle: Lifecycle::Open, lifecycle_changed_at: changed_at,
            })));
        }
        state.changed_at = changed_at;
        ops.push(Op::Put(Record::Window(state)));
        for op in &ops { self.apply(op); }
        Ok(ops)
    }

    fn window_state(&self, window: &str) -> WindowState {
        self.windows.get(window).cloned().unwrap_or_else(|| WindowState {
            id: window.into(), shown_space: self.spaces.first().map(|space| space.id.clone()), selected: None, history: Vec::new(), space_history: Vec::new(), changed_at: 0,
        })
    }

    pub fn show_space(&mut self, window: &str, space: &str) -> Result<Vec<Op>, EditError> {
        if !self.spaces.iter().any(|entry| entry.id == space) { return Err(EditError(format!("unknown space {space}"))); }
        let mut state = self.window_state(window);
        if let Some(previous) = &state.shown_space {
            if !state.space_history.contains(previous) {
                state.space_history.push(previous.clone());
            }
        }
        state.shown_space = Some(space.into());
        state.space_history.retain(|id| id != space);
        state.space_history.insert(0, space.into());
        state.changed_at = self.lifecycle_time();
        let ops = vec![Op::Put(Record::Window(state))];
        for op in &ops { self.apply(op); }
        Ok(ops)
    }

    pub fn close_window(&mut self, window: &str, quitting: bool) -> Vec<Op> {
        if quitting || !self.windows.contains_key(window) { return Vec::new(); }
        let op = Op::Delete(crate::model::Kind::Window, window.into());
        self.apply(&op);
        vec![op]
    }

    pub fn shown_space(&self, window: &str) -> Option<&str> {
        self.windows.get(window).and_then(|state| state.shown_space.as_deref())
            .filter(|id| self.spaces.iter().any(|space| space.id == *id))
            .or_else(|| self.spaces.first().map(|space| space.id.as_str()))
    }

    pub fn recent_space_for_profile(&self, window: &str, profile: &crate::model::Profile) -> Option<&str> {
        let matching = |id: &str| self.spaces.iter().any(|space| space.id == id && &space.profile == profile);
        self.shown_space(window).filter(|id| matching(id))
            .or_else(|| self.windows.get(window)?.space_history.iter().find(|id| matching(id)).map(String::as_str))
            .or_else(|| self.spaces.iter().find(|space| &space.profile == profile).map(|space| space.id.as_str()))
    }

    pub(crate) fn lifecycle_time(&self) -> u64 {
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis() as u64;
        now.max(self.items.values().map(|item| item.lifecycle_changed_at).max().unwrap_or(0).saturating_add(1))
    }

    pub fn archive(&self) -> Vec<&crate::model::Item> {
        let mut items: Vec<_> = self.items.values().filter(|item| matches!(item.kind, ItemKind::Tab { .. })
            && matches!(item.lifecycle, Lifecycle::Closed | Lifecycle::Archived)).collect();
        items.sort_by(|a, b| b.lifecycle_changed_at.cmp(&a.lifecycle_changed_at).then_with(|| a.id.cmp(&b.id)));
        items
    }

    // The kept Window records, newest first: launch and reopen adopt the first record
    // (design (c)), the others wait for phase 5. Ties break on the id for a stable order.
    pub fn kept_windows(&self) -> Vec<WindowState> {
        let mut windows: Vec<WindowState> = self.windows.values().cloned().collect();
        windows.sort_unstable_by(|a, b| b.changed_at.cmp(&a.changed_at).then_with(|| a.id.cmp(&b.id)));
        windows
    }

    pub fn delete_archive_item(&mut self, id: &str) -> Result<Vec<Op>, EditError> {
        if !self.items.get(id).is_some_and(|item| matches!(item.kind, ItemKind::Tab { .. })
            && matches!(item.lifecycle, Lifecycle::Closed | Lifecycle::Archived)) {
            return Err(EditError(format!("item {id} is not an archived tab")));
        }
        let mut ops = vec![Op::Delete(crate::model::Kind::Item, id.into())];
        ops.extend(self.history_purge_ops(&ops));
        if self.history_profiles.contains_key(id) || ops.iter().any(|op| matches!(op, Op::Put(Record::HistoryProfile { .. }))) {
            ops.push(Op::Delete(crate::model::Kind::HistoryProfile, id.into()));
        }
        if self.last_selected.contains_key(id) { ops.push(Op::Delete(crate::model::Kind::LastSelected, id.into())); }
        for op in &ops { self.apply(op); }
        Ok(ops)
    }

    pub fn restore_item(&mut self, window: &str, id: &str) -> Result<Vec<Op>, EditError> {
        let mut item = self.items.get(id).filter(|item| matches!(item.kind, ItemKind::Tab { .. })
            && matches!(item.lifecycle, Lifecycle::Closed | Lifecycle::Archived)).cloned()
            .ok_or_else(|| EditError(format!("item {id} is not an archived tab")))?;
        let root = self.list_for(id).map(|(root, _)| root);
        let space = self.spaces.iter().find(|space| root == Some(space.today.as_str()) || root == Some(space.pinned.as_str()))
            .or_else(|| self.shown_space(window).and_then(|id| self.spaces.iter().find(|space| space.id == id)))
            .ok_or_else(|| EditError("no space to restore into".into()))?;
        let folder = item.membership.parent.as_deref().and_then(|id| self.items.get(id))
            .filter(|parent| matches!(parent.kind, ItemKind::Folder) && matches!(parent.lifecycle, Lifecycle::Open | Lifecycle::Unloaded)
                && self.list_for(&parent.id).is_some());
        if let Some(folder) = folder {
            let neighbours: Vec<_> = self.children(&folder.id).into_iter().filter(|other| other.id != id).collect();
            let before = neighbours.iter().rfind(|other| other.membership.order < item.membership.order);
            let after = neighbours.iter().find(|other| other.membership.order >= item.membership.order);
            item.membership.order = crate::order::key_between(before.map(|other| other.membership.order.as_str()), after.map(|other| other.membership.order.as_str()));
        } else {
            item.membership.order = crate::order::key_between(None, self.children(&space.today).first().map(|item| item.membership.order.as_str()));
            item.membership.previous_parent = item.membership.parent.replace(space.today.clone());
        }
        item.lifecycle = Lifecycle::Open;
        item.lifecycle_changed_at = self.lifecycle_time();
        let space_id = space.id.clone();
        let mut ops = self.expand_ancestors(item.membership.parent.as_deref());
        ops.extend(self.stamp_outgoing(window, Some(id), item.lifecycle_changed_at));
        let mut state = self.window_state(window);
        state.shown_space = Some(space_id);
        state.select(Some(id.into()));
        state.changed_at = item.lifecycle_changed_at;
        ops.push(Op::Put(Record::Item(item)));
        ops.push(Op::Put(Record::Window(state)));
        for op in &ops { self.apply(op); }
        ops.extend(self.stamp_selection(id, self.items[id].lifecycle_changed_at));
        Ok(ops)
    }

    fn expand_ancestors<'a>(&'a self, mut parent: Option<&'a str>) -> Vec<Op> {
        let mut ops = Vec::new();
        for _ in 0..self.items.len() {
            let Some(ancestor) = parent.and_then(|id| self.items.get(id)) else { break };
            if self.folder_collapsed.get(&ancestor.id) == Some(&true) {
                ops.push(Op::Put(Record::FolderState { item: ancestor.id.clone(), collapsed: false }));
            }
            parent = ancestor.membership.parent.as_deref();
        }
        ops
    }

    pub fn selected(&self, window: &str) -> Option<&str> {
        self.windows.get(window).and_then(|state| state.selected.as_deref())
    }

    pub fn clear_selection(&mut self, window: &str) -> Vec<Op> {
        if self.selected(window).is_none() { return Vec::new(); }
        let now = self.lifecycle_time();
        let mut ops = self.stamp_outgoing(window, None, now);
        let mut state = self.window_state(window);
        state.select(None);
        state.changed_at = now;
        ops.push(Op::Put(Record::Window(state)));
        for op in &ops { self.apply(op); }
        ops
    }

    pub fn is_selectable(&self, id: &str) -> bool {
        let Some(item) = self.items.get(id) else { return false };
        matches!(item.kind, ItemKind::Tab { .. } | ItemKind::Split { .. }) && self.list_for(id).is_some_and(|(root, _)| {
            self.outline(root).iter().any(|(_, item)| item.id == id)
        })
    }

    pub fn is_open_visible(&self, id: &str) -> bool {
        self.items.get(id).is_some_and(|item| item.lifecycle == Lifecycle::Open) && self.is_selectable(id) && match self.items[id].kind {
            ItemKind::Split { .. } => self.outline(id).iter().any(|(_, item)| item.lifecycle == Lifecycle::Open && matches!(item.kind, ItemKind::Tab { .. })),
            _ => true,
        }
    }

    pub fn select_item(&mut self, window: &str, id: &str) -> Result<Vec<Op>, EditError> {
        self.select_item_at(window, id, self.lifecycle_time())
    }

    pub fn select_item_at(&mut self, window: &str, id: &str, now: u64) -> Result<Vec<Op>, EditError> {
        self.check_tree().map_err(EditError)?;
        let item = self.items.get(id).filter(|i| matches!(i.kind, ItemKind::Tab { .. } | ItemKind::Split { .. }))
            .ok_or_else(|| EditError(format!("item {id} cannot be selected")))?;
        self.movable_item(id)?;
        if matches!(item.kind, ItemKind::Split { .. }) && !self.has_open_tab(id) {
            return Err(EditError(format!("item {id} cannot be selected")));
        }
        let mut ops = self.expand_ancestors(item.membership.parent.as_deref());
        for op in &ops { self.apply(op); }
        ops.extend(self.record_active(window, id, now)?);
        Ok(ops)
    }

    // The load-side write the selection shares with the coordinator: an active row is
    // open, and so are its split members and the split ancestors it hangs in.
    pub(crate) fn flip_active(&mut self, id: &str, now: u64) -> Vec<Op> {
        let Some(item) = self.items.get(id) else { return Vec::new() };
        let mut loading = vec![item.clone()];
        if matches!(item.kind, ItemKind::Split { .. }) {
            loading.extend(self.outline_entries(id).into_iter().map(|(_, item, _)| item.clone()));
        }
        let mut parent = item.membership.parent.as_ref();
        while let Some(ancestor) = parent.and_then(|pid| self.items.get(pid)) {
            if matches!(ancestor.kind, ItemKind::Split { .. }) { loading.push(ancestor.clone()); }
            parent = ancestor.membership.parent.as_ref();
        }
        let mut ops = Vec::new();
        for mut item in loading {
            let before = item.clone();
            if item.lifecycle == Lifecycle::Unloaded {
                item.lifecycle = Lifecycle::Open;
                item.lifecycle_changed_at = now;
            }
            if item != before { ops.push(Op::Put(Record::Item(item))); }
        }
        for op in &ops { self.apply(op); }
        ops
    }

    // The one selection write: flip the row active, select it in the window and stamp the
    // selection history. No visibility checks here — Chrome's own activations are
    // recorded whatever the outline says.
    pub(crate) fn record_active(&mut self, window: &str, id: &str, now: u64) -> Result<Vec<Op>, EditError> {
        if !self.items.contains_key(id) {
            return Err(EditError(format!("unknown item {id}")));
        }
        let mut ops = self.stamp_outgoing(window, Some(id), now);
        ops.extend(self.flip_active(id, now));
        let mut state = self.window_state(window);
        state.select(Some(id.into()));
        state.changed_at = now;
        ops.push(Op::Put(Record::Window(state)));
        for op in &ops { self.apply(op); }
        ops.extend(self.stamp_selection(id, now));
        Ok(ops)
    }

    fn stamp_outgoing(&mut self, window: &str, new: Option<&str>, now: u64) -> Vec<Op> {
        let outgoing = self.selected(window).filter(|selected| Some(*selected) != new).map(str::to_string);
        outgoing.map_or_else(Vec::new, |selected| self.stamp_selection(&selected, now))
    }

    pub fn close_item(&mut self, id: &str) -> Result<Vec<Op>, EditError> {
        self.finish_item(id, false, self.lifecycle_time())
    }

    pub fn archive_item(&mut self, id: &str) -> Result<Vec<Op>, EditError> {
        if !self.items.get(id).is_some_and(|item| matches!(item.kind, ItemKind::Tab { .. })) {
            return Err(EditError(format!("item {id} is not a tab")));
        }
        self.finish_item(id, true, self.lifecycle_time())
    }

    fn finish_item(&mut self, id: &str, archive: bool, changed_at: u64) -> Result<Vec<Op>, EditError> {
        self.check_tree().map_err(EditError)?;
        let item = self.items.get(id).ok_or_else(|| EditError(format!("unknown item {id}")))?;
        if !matches!(item.kind, ItemKind::Tab { .. } | ItemKind::Split { .. }) || !matches!(item.lifecycle, Lifecycle::Open | Lifecycle::Unloaded) {
            return Err(EditError(format!("item {id} is not an open tab or split")));
        }
        let (root, today) = self.list_for(id).ok_or_else(|| EditError(format!("item {id} is not a workspace tab or split")))?;
        if !today && !archive && item.lifecycle == Lifecycle::Unloaded { return Err(EditError(format!("item {id} is already unloaded"))); }
        let today = today || archive;
        let outline = self.outline_entries(root);
        let position = outline.iter().position(|(_, item, _)| item.id == id).unwrap();
        let mut changing = HashSet::from([id.to_string()]);
        if matches!(item.kind, ItemKind::Split { .. }) {
            let depth = outline[position].0;
            changing.extend(outline[position + 1..].iter().take_while(|(d, _, _)| *d > depth).map(|(_, i, _)| i.id.clone()));
        }
        {
            let mut parent = item.membership.parent.as_ref();
            while let Some(ancestor) = parent.and_then(|id| self.items.get(id)) {
                if matches!(ancestor.kind, ItemKind::Split { .. }) && !self.outline_entries(&ancestor.id).iter().any(|(_, i, _)| {
                    matches!(i.kind, ItemKind::Tab { .. }) && (i.lifecycle == Lifecycle::Open || (today && i.lifecycle == Lifecycle::Unloaded)) && !changing.contains(&i.id)
                }) { changing.insert(ancestor.id.clone()); }
                parent = ancestor.membership.parent.as_ref();
            }
        }
        let mut ops: Vec<_> = outline.iter().filter(|(_, item, _)| changing.contains(&item.id) && (item.lifecycle == Lifecycle::Open || (today && item.lifecycle == Lifecycle::Unloaded)))
            .map(|(_, item, _)| {
                let mut changed = (*item).clone();
                changed.lifecycle = if archive { Lifecycle::Archived } else if today { Lifecycle::Closed } else { Lifecycle::Unloaded };
                changed.lifecycle_changed_at = changed_at;
                Op::Put(Record::Item(changed))
            }).collect();
        ops.extend(self.history_purge_ops(&ops));
        let mut windows: Vec<_> = self.windows.values().cloned().collect();
        windows.sort_by(|a, b| a.id.cmp(&b.id));
        for mut state in windows {
            let before = state.clone();
            if state.selected.as_ref().is_some_and(|id| changing.contains(id)) {
                let mut parent = state.selected.as_ref().and_then(|id| self.items.get(id)).and_then(|item| item.membership.parent.as_ref());
                let mut split = None;
                while let Some(ancestor) = parent.and_then(|id| self.items.get(id)) {
                    if matches!(ancestor.kind, ItemKind::Split { .. }) && ancestor.lifecycle == Lifecycle::Open
                        && !changing.contains(&ancestor.id) && self.is_selectable(&ancestor.id) {
                        split = Some(ancestor.id.clone());
                        break;
                    }
                    parent = ancestor.membership.parent.as_ref();
                }
                let in_space = |id: &str| state.shown_space.as_deref().is_some_and(|space| self.is_in_space(id, space));
                let successor = split.or_else(|| state.history.iter().filter(|id| in_space(id)).find_map(|id| self.successor_group(id, &changing)))
                    .or_else(|| outline[position + 1..].iter().chain(outline[..position].iter().rev())
                        .filter(|(_, item, visible)| *visible && matches!(item.kind, ItemKind::Tab { .. }) && in_space(&item.id))
                        .find_map(|(_, item, _)| self.successor_group(&item.id, &changing)));
                state.select(successor);
            }
            if today { state.history.retain(|id| !changing.contains(id)); }
            if state != before {
                state.changed_at = changed_at;
                ops.push(Op::Put(Record::Window(state)));
            }
        }
        let selected: HashSet<_> = ops.iter().filter_map(|op| match op {
            Op::Put(Record::Window(state)) if state.selected.as_deref() != self.selected(&state.id) => state.selected.clone(), _ => None,
        }).collect();
        for op in &ops { self.apply(op); }
        let mut selected: Vec<_> = selected.into_iter().collect();
        selected.sort();
        for id in selected { ops.extend(self.stamp_selection(&id, changed_at)); }
        Ok(ops)
    }

    fn history_purge_ops(&self, changes: &[Op]) -> Vec<Op> {
        use std::hash::BuildHasher;
        changes.iter().filter_map(|op| {
            let (item, changed_at) = match op {
                Op::Put(Record::Item(item)) if item.lifecycle != Lifecycle::Unloaded => (item, item.lifecycle_changed_at),
                Op::Delete(crate::model::Kind::Item, id) => (self.items.get(id)?, self.lifecycle_time()),
                _ => return None,
            };
            if !matches!(item.kind, ItemKind::Tab { .. }) { return None; }
            let profile = self.item_profile(&item.id).or_else(|| self.history_profiles.get(&item.id))?.clone();
            let random = std::collections::hash_map::RandomState::new();
            let id = format!("{:016x}{:016x}", random.hash_one(0u8), random.hash_one(1u8));
            Some((id, profile, item.id.clone(), changed_at))
        }).flat_map(|(id, profile, item, changed_at)| [
            Op::Put(Record::HistoryPurge { id, profile: profile.clone(), item: item.clone(), changed_at }),
            Op::Put(Record::HistoryProfile { item, profile }),
        ]).collect()
    }

    pub(crate) fn list_for(&self, id: &str) -> Option<(&str, bool)> {
        let mut item = self.items.get(id)?;
        for _ in 0..self.items.len() {
            let Some(parent) = &item.membership.parent else { break };
            item = self.items.get(parent)?;
        }
        if item.membership.parent.is_some() { return None; }
        self.spaces.iter().find_map(|space| {
            if space.today == item.id { Some((space.today.as_str(), true)) }
            else if space.pinned == item.id { Some((space.pinned.as_str(), false)) } else { None }
        }).or_else(|| self.favorites.values().find(|root| **root == item.id).map(|root| (root.as_str(), false)))
    }

    fn is_in_space(&self, id: &str, space: &str) -> bool {
        let Some(space) = self.spaces.iter().find(|entry| entry.id == space) else { return false };
        self.list_for(id).is_some_and(|(root, _)| root == space.today || root == space.pinned || self.favorites.get(&space.profile).is_some_and(|id| id == root))
    }

    fn successor_group(&self, id: &str, excluded: &HashSet<Id>) -> Option<Id> {
        if excluded.contains(id) || !self.is_open_visible(id) { return None; }
        if matches!(self.items[id].kind, ItemKind::Split { .. }) && !self.outline(id).iter().any(|(_, item)| {
            matches!(item.kind, ItemKind::Tab { .. }) && item.lifecycle == Lifecycle::Open && !excluded.contains(&item.id)
        }) { return None; }
        let mut item = &self.items[id];
        while let Some(ancestor) = item.membership.parent.as_ref().and_then(|id| self.items.get(id)) {
            if matches!(ancestor.kind, ItemKind::Split { .. }) {
                return (!excluded.contains(&ancestor.id)).then(|| ancestor.id.clone());
            }
            item = ancestor;
        }
        Some(id.into())
    }
}

impl Workspace {
    pub fn set_archive_after(&mut self, profile: crate::model::Profile, value: crate::model::ArchiveAfter) -> Vec<Op> {
        let ops = vec![Op::Put(Record::ArchiveAfter { profile, value })];
        for op in &ops { self.apply(op); }
        ops
    }

    pub fn auto_archive(&mut self, now: u64) -> Result<Vec<Op>, EditError> {
        self.check_tree().map_err(EditError)?;
        let mut protected = HashSet::new();
        for id in self.windows.values().filter_map(|w| w.selected.as_ref()) {
            protected.insert(id.clone());
            if self.items.get(id).is_some_and(|i| matches!(i.kind, ItemKind::Split { .. })) {
                protected.extend(self.outline_entries(id).into_iter().map(|(_, i, _)| i.id.clone()));
            }
        }
        let mut expired = Vec::new();
        let mut ops = Vec::new();
        for space in &self.spaces {
            let threshold = self.archive_after.get(&space.profile).copied().unwrap_or_default().millis();
            for (_, item, _) in self.outline_entries(&space.today) {
                if matches!(item.kind, ItemKind::Tab { .. }) && matches!(item.lifecycle, Lifecycle::Open | Lifecycle::Unloaded)
                {
                    match self.last_selected.get(&item.id) {
                        None => ops.push(Op::Put(Record::LastSelected { item: item.id.clone(), at: now })),
                        Some(at) if !protected.contains(&item.id) && now.saturating_sub(*at) > threshold => expired.push(item.id.clone()),
                        _ => {},
                    }
                }
            }
        }
        if ops.is_empty() && expired.is_empty() { return Ok(ops); }
        let mut next = self.clone();
        for op in &ops { next.apply(op); }
        for id in expired { ops.extend(next.finish_item(&id, true, next.lifecycle_time())?); }
        *self = next;
        Ok(ops)
    }
}

impl Workspace {
    pub fn stamp_selection(&mut self, id: &str, now: u64) -> Vec<Op> {
        let mut ids = vec![id.to_string()];
        if self.items.get(id).is_some_and(|i| matches!(i.kind, ItemKind::Split { .. } | ItemKind::Folder)) {
            ids.extend(self.outline_entries(id).into_iter().map(|(_, item, _)| item.id.clone()));
        }
        let ops: Vec<_> = ids.into_iter().filter(|id| self.items.get(id).is_some_and(|i|
            matches!(i.kind, ItemKind::Tab { .. }) && matches!(i.lifecycle, Lifecycle::Open | Lifecycle::Unloaded))
            && self.last_selected.get(id) != Some(&now))
            .map(|item| Op::Put(Record::LastSelected { item, at: now })).collect();
        for op in &ops { self.apply(op); }
        ops
    }
}

// Air Traffic Control edits. One record per rule, so two devices that add, edit, move or
// delete different rules before they sync both get applied (architecture 8.3 merges per
// record). The rule's order key follows the item keys: a write lands between its
// neighbours' keys, and a move onto a tied run re-keys that run, so the same records give
// every device the same rule order.
impl Workspace {
    // One new key for a rule joining `others` at `index`: between the neighbours' keys, with
    // a tied run at that seam re-keyed first, the way the item moves' `insertion_keys` does,
    // so an equal key is never the gap a later key must fall between — key_between needs
    // lo < hi.
    fn rule_join_keys(others: &[&crate::routing::StoredRule], index: usize) -> (String, Vec<Op>) {
        let before = index.checked_sub(1).and_then(|i| others.get(i)).map(|s| s.order.clone());
        let mut after = others.get(index).map(|s| s.order.clone());
        let mut ops = Vec::new();
        if before.as_ref().zip(after.as_ref()).is_some_and(|(a, b)| a == b) {
            let tied: Vec<_> = others[index..].iter().take_while(|s| Some(&s.order) == before.as_ref()).collect();
            let next = others.get(index + tied.len()).map(|s| s.order.as_str());
            let mut previous = before.clone();
            for (position, stored) in tied.into_iter().enumerate() {
                let mut spaced = (**stored).clone();
                spaced.order = crate::order::key_between(previous.as_deref(), next);
                if position == 0 { after = Some(spaced.order.clone()); }
                previous = Some(spaced.order.clone());
                ops.push(Op::Put(Record::RoutingRule { order: spaced.order, rule: spaced.rule }));
            }
        }
        let key = crate::order::key_between(before.as_deref(), after.as_deref());
        (key, ops)
    }

    pub fn add_rule(&mut self, rule: crate::routing::Rule) -> Result<Vec<Op>, EditError> {
        if rule.id.trim().is_empty() { return Err(EditError("rule id is empty".into())); }
        if self.routing_rules.contains_key(&rule.id) {
            return Err(EditError(format!("rule {} already exists", rule.id)));
        }
        self.check_routing_destination(&rule.destination, Some(&rule.profile))?;
        // New rules join at the end: one key after the last rule in the order now has (the
        // key is independent of how the tied run after it scores, ties fall back to the id).
        let last = self.routing_rules.values().map(|s| s.order.as_str()).max();
        let order = crate::order::key_between(last, None);
        Ok(self.commit_edit(vec![Op::Put(Record::RoutingRule { order, rule })]))
    }

    pub fn edit_rule(&mut self, rule: crate::routing::Rule) -> Result<Vec<Op>, EditError> {
        if rule.id.trim().is_empty() { return Err(EditError("rule id is empty".into())); }
        let Some(stored) = self.routing_rules.get(&rule.id) else {
            return Err(EditError(format!("unknown rule {}", rule.id)));
        };
        // A rule's profile is fixed at its start (add or import): the edit answers to the
        // stored one, not to whatever the caller resent, so a stale row cannot move the
        // rule into another profile by rewriting it whole.
        let mut rule = rule;
        rule.profile = stored.rule.profile.clone();
        // An edit that changes nothing writes nothing.
        if stored.rule == rule { return Ok(Vec::new()); }
        // Only a destination the edit changes to is checked: one keeping the rule's current
        // destination (a text or style change only) still writes, so a rule whose space was
        // deleted can still be fixed.
        if stored.rule.destination != rule.destination {
            self.check_routing_destination(&rule.destination, Some(&rule.profile))?;
        }
        // The order key stays: an edit changes what the rule does, not where it sits.
        let op = Op::Put(Record::RoutingRule { order: stored.order.clone(), rule });
        Ok(self.commit_edit(vec![op]))
    }

    pub fn delete_rule(&mut self, id: &str) -> Result<Vec<Op>, EditError> {
        if !self.routing_rules.contains_key(id) {
            return Err(EditError(format!("unknown rule {id}")));
        }
        let op = Op::Delete(Kind::RoutingRule, id.into());
        Ok(self.commit_edit(vec![op]))
    }

    pub fn move_rule(&mut self, id: &str, index: usize) -> Result<Vec<Op>, EditError> {
        let mut list: Vec<crate::routing::StoredRule> = self.routing_rules.values().cloned().collect();
        list.sort_by(|a, b| (&a.order, &a.rule.id).cmp(&(&b.order, &b.rule.id)));
        let others: Vec<&crate::routing::StoredRule> = list.iter().filter(|s| s.rule.id != id).collect();
        // The range is checked before the id, so a bad index is reported for an unknown one too.
        if index > others.len() { return Err(EditError("rule index out of range".into())); }
        let position = list.iter().position(|s| s.rule.id == id)
            .ok_or_else(|| EditError(format!("unknown rule {id}")))?;
        // A move to the position the rule already holds changes nothing.
        if position == index { return Ok(Vec::new()); }
        let stored = self.routing_rules.get(id).ok_or_else(|| EditError(format!("unknown rule {id}")))?;
        let (key, mut ops) = Self::rule_join_keys(&others, index);
        ops.push(Op::Put(Record::RoutingRule { order: key, rule: stored.rule.clone() }));
        Ok(self.commit_edit(ops))
    }

    // The default destination belongs to no rule, so only existence decides its space; a
    // Little window still names a profile the workspace has.
    fn check_routing_destination(&self, destination: &crate::routing::Destination, profile: Option<&Profile>) -> Result<(), EditError> {
        match destination {
            crate::routing::Destination::Space(crate::routing::SpaceTarget::Space(id)) => {
                let space = self.spaces.iter().find(|space| &space.id == id)
                    .ok_or_else(|| EditError(format!("unknown space {id}")))?;
                if profile.is_some_and(|profile| &space.profile != profile) {
                    return Err(EditError(format!("space {id} belongs to another profile")));
                }
            }
            crate::routing::Destination::LittleWindow(profile) => {
                if let Profile::Named(name) = profile {
                    if !self.space_profiles().any(|candidate| candidate == profile) {
                        return Err(EditError(format!("unknown profile {name}")));
                    }
                }
            }
            crate::routing::Destination::Space(crate::routing::SpaceTarget::MostRecent) => {},
        }
        Ok(())
    }

    // The named profiles the workspace carries, from every record that is per profile: a
    // named profile outlives its spaces (favorites and the archive threshold remain), so
    // the spaces list alone is not the whole answer.
    fn space_profiles(&self) -> impl Iterator<Item = &Profile> {
        self.spaces.iter().map(|s| &s.profile)
            .chain(self.favorites.keys())
            .chain(self.archive_after.keys())
    }

    pub fn set_default_destination(&mut self, destination: crate::routing::Destination) -> Result<Vec<Op>, EditError> {
        self.check_routing_destination(&destination, None)?;
        // An edit that changes nothing writes nothing.
        if self.routing_default == destination { return Ok(Vec::new()); }
        // The built-in default is derived, never stored (like to_ops emits no record for it):
        // a reset deletes the stored record, so the journal replays it as a delete instead of
        // holding a row that only restates the built-in value.
        let id = "workspace".to_string();
        let op = if destination == crate::routing::Destination::default() {
            Op::Delete(Kind::RoutingDefault, id)
        } else {
            Op::Put(Record::RoutingDefault { destination })
        };
        Ok(self.commit_edit(vec![op]))
    }
}
