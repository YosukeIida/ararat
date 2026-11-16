use ararat_core::import::arc_sidebar;
use ararat_core::model::{Hlc, Item, ItemKind, Membership, Op, Record, Workspace};

const FIXTURE: &str = include_str!("fixtures/arc-sidebar-synthetic.json");

fn imported() -> Workspace {
    arc_sidebar(FIXTURE, None, None, None, None).unwrap().0
}

fn hlc(millis: u64) -> Hlc {
    Hlc { millis, ..Hlc::default() }
}

fn mv(ws: &mut Workspace, id: &str, parent: Option<&str>, millis: u64) {
    let m = &mut ws.items.get_mut(id).unwrap().membership;
    m.previous_parent = std::mem::replace(&mut m.parent, parent.map(str::to_string));
    m.hlc = hlc(millis);
}

fn parent(ws: &Workspace, id: &str) -> Option<String> {
    ws.items[id].membership.parent.clone()
}

// Every repair test ends here: the tree is valid, a second repair has nothing to do, and the
// returned ops alone turn the broken state into the repaired one.
fn repair_and_check(ws: &mut Workspace) {
    let before = ws.clone();
    let ops = ws.repair_tree();
    ws.check_tree().unwrap();
    assert!(ws.clone().repair_tree().is_empty());
    let mut replayed = before;
    for op in &ops {
        replayed.apply(op);
    }
    assert_eq!(&replayed, ws);
}

#[test]
fn the_imported_tree_is_valid() {
    imported().check_tree().unwrap();
    assert!(imported().repair_tree().is_empty());
}

#[test]
fn concurrent_moves_into_each_other_keep_the_later_move() {
    let mut ws = imported();
    mv(&mut ws, "split-1", Some("folder-docs"), 2);
    mv(&mut ws, "folder-docs", Some("split-1"), 1);
    assert!(ws.check_tree().is_err());

    repair_and_check(&mut ws);
    assert_eq!(parent(&ws, "split-1").as_deref(), Some("folder-docs"));
    assert_eq!(parent(&ws, "folder-docs").as_deref(), Some("pin-work"));
}

#[test]
fn a_three_item_cycle_undoes_only_the_oldest_move() {
    let mut ws = imported();
    mv(&mut ws, "folder-docs", Some("split-1"), 1);
    mv(&mut ws, "split-1", Some("tab-mail"), 3);
    mv(&mut ws, "tab-mail", Some("folder-docs"), 2);

    repair_and_check(&mut ws);
    assert_eq!(parent(&ws, "folder-docs").as_deref(), Some("pin-work"));
    assert_eq!(parent(&ws, "split-1").as_deref(), Some("tab-mail"));
    assert_eq!(parent(&ws, "tab-mail").as_deref(), Some("folder-docs"));
}

#[test]
fn a_cycle_with_nowhere_to_go_back_to_ends_in_today() {
    let mut ws = imported();
    for id in ["folder-docs", "split-1"] {
        ws.items.get_mut(id).unwrap().membership.previous_parent = None;
    }
    ws.items.get_mut("folder-docs").unwrap().membership.parent = Some("split-1".into());
    ws.items.get_mut("split-1").unwrap().membership.parent = Some("folder-docs".into());
    ws.items.get_mut("split-1").unwrap().membership.hlc = hlc(1);
    ws.items.get_mut("folder-docs").unwrap().membership.hlc = hlc(2);

    repair_and_check(&mut ws);
    assert_eq!(parent(&ws, "folder-docs").as_deref(), Some("split-1"));
    assert_eq!(parent(&ws, "split-1").as_deref(), Some("today-work"));
}

#[test]
fn orphans_go_to_the_today_of_the_space_they_came_from() {
    let mut ws = imported();
    ws.items.remove("folder-docs");
    let spec = &mut ws.items.get_mut("tab-spec").unwrap().membership;
    spec.previous_parent = Some("pin-home".into());

    repair_and_check(&mut ws);
    assert_eq!(parent(&ws, "tab-spec").as_deref(), Some("today-home"));
}

#[test]
fn a_cut_off_subtree_moves_as_a_whole() {
    let mut ws = imported();
    mv(&mut ws, "split-1", Some("gone"), 1);

    repair_and_check(&mut ws);
    assert_eq!(parent(&ws, "split-1").as_deref(), Some("today-work"));
    assert_eq!(parent(&ws, "tab-a").as_deref(), Some("split-1"));
}

#[test]
fn a_container_given_a_parent_becomes_a_root_again() {
    let mut ws = imported();
    mv(&mut ws, "today-home", Some("folder-docs"), 1);

    repair_and_check(&mut ws);
    assert_eq!(parent(&ws, "today-home"), None);
}

// Deterministic pseudo-random parents, timestamps and move origins over a bigger tree.
#[test]
fn random_damage_always_repairs_to_a_valid_tree() {
    let mut seed: u64 = 0x2545_f491_4f6c_dd1d;
    let mut next = |n: usize| {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        (seed % n as u64) as usize
    };
    let mut base = imported();
    for i in 0..40 {
        let id = format!("t{i}");
        let tab = Item {
            id: id.clone(),
            membership: Membership {
                parent: Some("today-work".into()),
                order: "V".into(),
                hlc: Hlc::default(),
                previous_parent: None,
            },
            title: None,
            lifecycle: ararat_core::model::Lifecycle::Open, lifecycle_changed_at: 0, archive: None,
            kind: if i % 4 == 0 { ItemKind::Folder } else { ItemKind::Tab { url: id.clone(), saved_title: None } },
        };
        base.apply(&Op::Put(Record::Item(tab)));
    }
    let mut ids: Vec<String> = base.items.keys().cloned().collect();
    ids.sort();
    let mut targets: Vec<Option<String>> = ids.iter().cloned().map(Some).collect();
    targets.extend([None, Some("missing".into())]);

    let mut broken = 0;
    for _ in 0..300 {
        let mut ws = base.clone();
        for _ in 0..next(12) + 1 {
            let id = &ids[next(ids.len())];
            let m = &mut ws.items.get_mut(id).unwrap().membership;
            m.parent = targets[next(targets.len())].clone();
            m.previous_parent = targets[next(targets.len())].clone();
            m.hlc = hlc(next(5) as u64);
        }
        broken += ws.check_tree().is_err() as usize;
        repair_and_check(&mut ws);
    }
    assert!(broken > 150, "only {broken} of 300 damaged trees were invalid");
}
