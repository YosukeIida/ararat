use std::collections::HashSet;

use crate::model::{Id, ItemKind, Lifecycle, Op, Record, Workspace};

#[derive(Debug, PartialEq, Eq)]
pub struct EditError(pub String);

impl Workspace {
    pub fn is_selectable(&self, id: &str) -> bool {
        let Some(item) = self.items.get(id) else { return false };
        if !matches!(item.kind, ItemKind::Tab { .. } | ItemKind::Split { .. }) {
            return false;
        }
        self.spaces.iter().flat_map(|s| [&s.pinned, &s.today]).chain(self.favorites.values())
            .any(|root| self.outline(root).iter().any(|(_, item)| item.id == id))
    }

    pub fn select_item(&mut self, id: &str) -> Result<Vec<Op>, EditError> {
        self.check_tree().map_err(EditError)?;
        if !self.is_selectable(id) {
            return Err(EditError(format!("item {id} cannot be selected")));
        }
        self.selected = Some(id.into());
        Ok(vec![Op::Put(Record::Selection(self.selected.clone()))])
    }

    pub fn close_today_tab(&mut self, id: &str) -> Result<Vec<Op>, EditError> {
        self.check_tree().map_err(EditError)?;
        let item = self.items.get(id).ok_or_else(|| EditError(format!("unknown item {id}")))?;
        if !matches!(item.kind, ItemKind::Tab { .. } | ItemKind::Split { .. }) || !matches!(item.lifecycle, Lifecycle::Open | Lifecycle::Unloaded) {
            return Err(EditError(format!("item {id} is not an open Today tab or split")));
        }
        let (outline, position) = self.spaces.iter().find_map(|space| {
            let outline = self.outline_entries(&space.today);
            let position = outline.iter().position(|(_, item, _)| item.id == id)?;
            Some((outline, position))
        }).ok_or_else(|| EditError(format!("item {id} is not a Today tab or split")))?;
        let mut closing = HashSet::from([id.to_string()]);
        if matches!(item.kind, ItemKind::Split { .. }) {
            let depth = outline[position].0;
            closing.extend(outline[position + 1..].iter().take_while(|(d, _, _)| *d > depth).map(|(_, i, _)| i.id.clone()));
        }
        let mut parent = item.membership.parent.as_ref();
        while let Some(ancestor) = parent.and_then(|id| self.items.get(id)) {
            if matches!(ancestor.kind, ItemKind::Split { .. }) && !self.outline_entries(&ancestor.id).iter().any(|(_, i, _)| {
                matches!(i.kind, ItemKind::Tab { .. }) && matches!(i.lifecycle, Lifecycle::Open | Lifecycle::Unloaded) && !closing.contains(&i.id)
            }) {
                closing.insert(ancestor.id.clone());
            }
            parent = ancestor.membership.parent.as_ref();
        }
        let successor = outline[position + 1..].iter().chain(outline[..position].iter().rev())
            .find(|(_, item, visible)| *visible && item.lifecycle == Lifecycle::Open && matches!(item.kind, ItemKind::Tab { .. }) && !closing.contains(&item.id))
            .map(|(_, item, _)| self.selection_group(item));
        let mut ops: Vec<_> = outline.iter().filter(|(_, item, _)| closing.contains(&item.id) && matches!(item.lifecycle, Lifecycle::Open | Lifecycle::Unloaded))
            .map(|(_, item, _)| {
                let mut closed = (*item).clone();
                closed.lifecycle = Lifecycle::Closed;
                Op::Put(Record::Item(closed))
            }).collect();
        if self.selected.as_ref().is_some_and(|id| closing.contains(id)) {
            ops.push(Op::Put(Record::Selection(successor)));
        }
        for op in &ops { self.apply(op); }
        Ok(ops)
    }

    fn selection_group(&self, item: &crate::model::Item) -> Id {
        let mut parent = item.membership.parent.as_ref();
        while let Some(ancestor) = parent.and_then(|id| self.items.get(id)) {
            if matches!(ancestor.kind, ItemKind::Split { .. }) { return ancestor.id.clone(); }
            parent = ancestor.membership.parent.as_ref();
        }
        item.id.clone()
    }
}
