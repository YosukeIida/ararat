// Repair runs on the merged state on every device and must give every device the same tree, so
// it reads nothing but that state and visits ids in sorted order (architecture 6.1). Why not
// persist its ops after a sync merge: rewritten registers make the result depend on the order
// moves arrived in; there it is a view, and only an import writes repaired registers.

use std::collections::BTreeSet;

use crate::model::{Id, ItemKind, Op, Record, Workspace};

enum Walk {
    Root(Id),
    Cycle(Vec<Id>),
    Orphan(Id),
}

impl Workspace {
    // Containers are the roots; every other item must reach one through its parents. One parent
    // per item makes "reachable at most once" hold by construction.
    pub fn check_tree(&self) -> Result<(), String> {
        for id in self.sorted_ids() {
            if self.is_root(&id) && self.items[&id].membership.parent.is_some() {
                return Err(format!("container {id} has a parent"));
            }
            match self.walk(&id) {
                Walk::Root(_) => {}
                Walk::Cycle(ids) => return Err(format!("cycle {ids:?}")),
                Walk::Orphan(at) => return Err(format!("{id} is cut off at {at}")),
            }
        }
        Ok(())
    }

    // Returns the repaired items as ops for the store.
    pub fn repair_tree(&mut self) -> Vec<Op> {
        let mut changed = BTreeSet::new();
        let mut reverted = BTreeSet::new();
        for id in self.sorted_ids() {
            if self.is_root(&id) && self.items[&id].membership.parent.is_some() {
                let m = &mut self.items.get_mut(&id).unwrap().membership;
                m.previous_parent = m.parent.take();
                changed.insert(id);
            }
        }
        loop {
            // Why not move archived descendants of deleted spaces: their original parents are kept for restore.
            let broken = self.sorted_ids().into_iter().find_map(|id| match self.walk(&id) {
                Walk::Root(root) if !self.is_root(&id)
                    && matches!(self.items[&id].lifecycle, crate::model::Lifecycle::Open | crate::model::Lifecycle::Unloaded)
                    && self.items[&id].membership.parent.as_ref().is_some_and(|parent|
                        parent == &root || !matches!(self.items[parent].lifecycle, crate::model::Lifecycle::Open | crate::model::Lifecycle::Unloaded))
                    && !self.spaces.iter().any(|s| s.pinned == root || s.today == root)
                    && !self.favorites.values().any(|id| *id == root) => Some(Walk::Orphan(id)),
                Walk::Root(_) => None,
                broken => Some(broken),
            });
            let (id, target) = match broken {
                None => break,
                Some(Walk::Cycle(ids)) => {
                    // The move with the lower HLC loses and is undone; undone twice, it goes to Today.
                    let loser = ids
                        .into_iter()
                        .min_by(|a, b| {
                            (&self.items[a].membership.hlc, a).cmp(&(&self.items[b].membership.hlc, b))
                        })
                        .unwrap();
                    let previous = self.items[&loser].membership.previous_parent.clone();
                    let target = match previous {
                        Some(p) if reverted.insert(loser.clone()) => Some(p),
                        _ => self.today_for(&loser),
                    };
                    (loser, target)
                }
                Some(Walk::Orphan(id)) => {
                    let target = self.today_for(&id);
                    (id, target)
                }
                Some(Walk::Root(_)) => unreachable!(),
            };
            // No space with a Today container to fall back to: leave the tree as it is.
            let Some(target) = target else { break };
            let m = &mut self.items.get_mut(&id).unwrap().membership;
            m.previous_parent = m.parent.replace(target);
            changed.insert(id);
        }
        changed.into_iter().map(|id| Op::Put(Record::Item(self.items[&id].clone()))).collect()
    }

    fn sorted_ids(&self) -> Vec<Id> {
        let mut ids: Vec<_> = self.items.keys().cloned().collect();
        ids.sort();
        ids
    }

    fn is_root(&self, id: &str) -> bool {
        self.items.get(id).is_some_and(|i| matches!(i.kind, ItemKind::Container))
    }

    fn walk(&self, start: &str) -> Walk {
        let mut path: Vec<&str> = Vec::new();
        let mut id = start;
        loop {
            if self.is_root(id) {
                return Walk::Root(id.to_string());
            }
            if let Some(pos) = path.iter().position(|p| *p == id) {
                return Walk::Cycle(path[pos..].iter().map(|s| s.to_string()).collect());
            }
            path.push(id);
            match self.items[id].membership.parent.as_deref().and_then(|p| self.items.get_key_value(p)) {
                Some((parent, _)) => id = parent,
                None => return Walk::Orphan(id.to_string()),
            }
        }
    }

    // The item's own chain is broken, so its space comes from where it was moved from; failing
    // that, the first space.
    fn today_for(&self, id: &str) -> Option<Id> {
        let root = self.items[id]
            .membership
            .previous_parent
            .as_deref()
            .filter(|p| self.items.contains_key(*p))
            .and_then(|p| match self.walk(p) {
                Walk::Root(root) => Some(root),
                _ => None,
            });
        let usable = || self.spaces.iter().filter(|s| self.is_root(&s.today));
        root.and_then(|r| usable().find(|s| s.pinned == r || s.today == r))
            .or_else(|| usable().next())
            .map(|s| s.today.clone())
    }
}
