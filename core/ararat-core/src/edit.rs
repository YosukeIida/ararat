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
        for mut item in loading {
            if item.lifecycle == Lifecycle::Unloaded {
                item.lifecycle = Lifecycle::Open;
                ops.push(Op::Put(Record::Item(item)));
            }
        }
        let mut state = self.window_state(window);
        state.select(Some(id.into()));
        ops.push(Op::Put(Record::Window(state)));
        for op in &ops { self.apply(op); }
        Ok(ops)
    }

    pub fn close_item(&mut self, id: &str) -> Result<Vec<Op>, EditError> {
        self.check_tree().map_err(EditError)?;
        let item = self.items.get(id).ok_or_else(|| EditError(format!("unknown item {id}")))?;
        if !matches!(item.kind, ItemKind::Tab { .. } | ItemKind::Split { .. }) || !matches!(item.lifecycle, Lifecycle::Open | Lifecycle::Unloaded) {
            return Err(EditError(format!("item {id} is not an open tab or split")));
        }
        let (root, today) = self.list_for(id).ok_or_else(|| EditError(format!("item {id} is not a workspace tab or split")))?;
        if !today && item.lifecycle == Lifecycle::Unloaded { return Err(EditError(format!("item {id} is already unloaded"))); }
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
                changed.lifecycle = if today { Lifecycle::Closed } else { Lifecycle::Unloaded };
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
        for op in &ops { self.apply(op); }
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
