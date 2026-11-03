use std::collections::HashSet;

use crate::model::{Id, ItemKind, Lifecycle, Op, Record, WindowState, Workspace};

pub const HISTORY_LIMIT: usize = 50;

#[derive(Debug, PartialEq, Eq)]
pub struct EditError(pub String);

impl WindowState {
    fn select(&mut self, id: Option<Id>) {
        if let Some(id) = &id {
            self.history.retain(|entry| entry != id);
            self.history.insert(0, id.clone());
            self.history.truncate(HISTORY_LIMIT);
        }
        self.selected = id;
    }
}

impl Workspace {
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
        let mut windows: Vec<_> = self.windows.values().cloned().collect();
        windows.sort_by(|a, b| a.id.cmp(&b.id));
        for mut state in windows {
            let before = state.clone();
            if self.shown_space(&state.id) == Some(id) { state.shown_space = Some(neighbour.clone()); }
            if state.selected.as_ref().is_some_and(|id| changing.contains(id)) { state.selected = None; }
            state.history.retain(|id| !changing.contains(id));
            if state != before { ops.push(Op::Put(Record::Window(state))); }
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
        let mut state = self.window_state(window);
        state.shown_space = Some(id.into());
        state.select(None);
        let changed_at = self.lifecycle_time();
        let mut ops = vec![Op::Put(Record::Space(space))];
        for id in [pinned, today] {
            ops.push(Op::Put(Record::Item(crate::model::Item {
                id, membership: crate::model::Membership { parent: None, order: crate::order::key_between(None, None), hlc: Default::default(), previous_parent: None },
                title: None, kind: ItemKind::Container, lifecycle: Lifecycle::Open, lifecycle_changed_at: changed_at, collapsed: false,
            })));
        }
        ops.push(Op::Put(Record::Window(state)));
        for op in &ops { self.apply(op); }
        Ok(ops)
    }

    fn window_state(&self, window: &str) -> WindowState {
        self.windows.get(window).cloned().unwrap_or_else(|| WindowState {
            id: window.into(), shown_space: self.spaces.first().map(|space| space.id.clone()), selected: None, history: Vec::new(),
        })
    }

    pub fn show_space(&mut self, window: &str, space: &str) -> Result<Vec<Op>, EditError> {
        if !self.spaces.iter().any(|entry| entry.id == space) { return Err(EditError(format!("unknown space {space}"))); }
        let mut state = self.window_state(window);
        state.shown_space = Some(space.into());
        let ops = vec![Op::Put(Record::Window(state))];
        for op in &ops { self.apply(op); }
        Ok(ops)
    }

    pub fn shown_space(&self, window: &str) -> Option<&str> {
        self.windows.get(window).and_then(|state| state.shown_space.as_deref())
            .filter(|id| self.spaces.iter().any(|space| space.id == *id))
            .or_else(|| self.spaces.first().map(|space| space.id.as_str()))
    }

    fn lifecycle_time(&self) -> u64 {
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis() as u64;
        now.max(self.items.values().map(|item| item.lifecycle_changed_at).max().unwrap_or(0).saturating_add(1))
    }

    pub fn archive(&self) -> Vec<&crate::model::Item> {
        let mut items: Vec<_> = self.items.values().filter(|item| matches!(item.kind, ItemKind::Tab { .. })
            && matches!(item.lifecycle, Lifecycle::Closed | Lifecycle::Archived)).collect();
        items.sort_by(|a, b| b.lifecycle_changed_at.cmp(&a.lifecycle_changed_at).then_with(|| a.id.cmp(&b.id)));
        items
    }

    pub fn delete_archive_item(&mut self, id: &str) -> Result<Vec<Op>, EditError> {
        if !self.items.get(id).is_some_and(|item| matches!(item.kind, ItemKind::Tab { .. })
            && matches!(item.lifecycle, Lifecycle::Closed | Lifecycle::Archived)) {
            return Err(EditError(format!("item {id} is not an archived tab")));
        }
        let mut ops = vec![Op::Delete(crate::model::Kind::Item, id.into())];
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
        let mut state = self.window_state(window);
        state.shown_space = Some(space.id.clone());
        state.select(Some(id.into()));
        let mut parent = item.membership.parent.clone();
        let mut ops = vec![Op::Put(Record::Item(item))];
        for _ in 0..self.items.len() {
            let Some(ancestor) = parent.as_deref().and_then(|id| self.items.get(id)) else { break };
            parent = ancestor.membership.parent.clone();
            if ancestor.collapsed {
                let mut expanded = ancestor.clone();
                expanded.collapsed = false;
                ops.push(Op::Put(Record::Item(expanded)));
            }
        }
        ops.push(Op::Put(Record::Window(state)));
        for op in &ops { self.apply(op); }
        ops.extend(self.stamp_selection(id, self.items[id].lifecycle_changed_at));
        Ok(ops)
    }

    pub fn selected(&self, window: &str) -> Option<&str> {
        self.windows.get(window).and_then(|state| state.selected.as_deref())
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
        if !self.is_selectable(id) { return Err(EditError(format!("item {id} cannot be selected"))); }
        let mut ops = Vec::new();
        let mut loading = vec![self.items[id].clone()];
        if matches!(self.items[id].kind, ItemKind::Split { .. }) {
            loading.extend(self.outline_entries(id).into_iter().map(|(_, item, _)| item.clone()));
        }
        let mut parent = self.items[id].membership.parent.as_ref();
        while let Some(ancestor) = parent.and_then(|id| self.items.get(id)) {
            if matches!(ancestor.kind, ItemKind::Split { .. }) { loading.push(ancestor.clone()); }
            parent = ancestor.membership.parent.as_ref();
        }
        let changed_at = now;
        for mut item in loading {
            let before = item.clone();
            if item.lifecycle == Lifecycle::Unloaded {
                item.lifecycle = Lifecycle::Open;
                item.lifecycle_changed_at = changed_at;
            }
            if item != before { ops.push(Op::Put(Record::Item(item))); }
        }
        let mut state = self.window_state(window);
        state.select(Some(id.into()));
        ops.push(Op::Put(Record::Window(state)));
        for op in &ops { self.apply(op); }
        ops.extend(self.stamp_selection(id, now));
        Ok(ops)
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
            if state != before { ops.push(Op::Put(Record::Window(state))); }
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

    fn list_for(&self, id: &str) -> Option<(&str, bool)> {
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
        for id in expired { ops.extend(next.finish_item(&id, true, now)?); }
        *self = next;
        Ok(ops)
    }
}

impl Workspace {
    pub fn stamp_selection(&mut self, id: &str, now: u64) -> Vec<Op> {
        let mut ids = vec![id.to_string()];
        if self.items.get(id).is_some_and(|i| matches!(i.kind, ItemKind::Split { .. })) {
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
