use ararat_core::{import::arc_sidebar, model::{ItemKind, Kind, Lifecycle, Op, Record, Workspace}, storage::Store};
fn workspace() -> Workspace { arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json"), None, None, None).unwrap().0 }
fn duplicate(ws: &mut Workspace, id: &str, parent: &str, root: &str) -> String {
    let before = ws.clone();
    let siblings = ws.children(parent);
    let position = siblings.iter().position(|i| i.id == root).unwrap();
    let next = siblings.get(position + 1).map(|i| i.id.clone());
    let ops = ws.duplicate_item(id).unwrap();
    let mut replay = before.clone(); for op in ops { replay.apply(&op); } assert_eq!(replay, *ws);
    ws.check_tree().unwrap();
    let siblings = ws.children(parent); let copy = siblings[position + 1];
    assert!(!before.items.contains_key(&copy.id));
    assert_eq!(siblings.get(position + 2).map(|i| i.id.clone()), next);
    assert_eq!(ws.windows, before.windows);
    copy.id.clone()
}
#[test]
fn tabs_duplicate_in_each_list_at_start_middle_end_with_titles_and_fresh_age() {
    for parent in ["today-work", "pin-work", "fav-default"] {
        for index in 0..3 {
            let mut ws = workspace();
            for n in 0..3 { let mut item = ws.items["tab-spec"].clone(); item.id = format!("sibling-{n}"); item.membership.parent = Some(parent.into()); item.membership.order = format!("a{n}"); ws.items.insert(item.id.clone(), item); }
            let index = if index == 2 { ws.children(parent).iter().filter(|item| item.id != "tab-spec").count() } else { index };
            ws.move_item("tab-spec", parent, index, false).unwrap();
            ws.rename_tab("tab-spec", "Custom").unwrap(); ws.select_item("window", "tab-spec").unwrap();
            let id = duplicate(&mut ws, "tab-spec", parent, "tab-spec");
            let item = &ws.items[&id]; assert_eq!(item.kind, ws.items["tab-spec"].kind); assert_eq!(item.title.as_deref(), Some("Custom"));
            assert_eq!(item.lifecycle, Lifecycle::Unloaded); assert!(item.lifecycle_changed_at > 1);
            assert_eq!(ws.last_selected[&id], item.lifecycle_changed_at); assert_eq!(item.membership.previous_parent.as_deref(), Some(parent));
            let now = item.lifecycle_changed_at; ws.auto_archive(now).unwrap(); assert_eq!(ws.items[&id].lifecycle, Lifecycle::Unloaded);
        }
    }
}
#[test]
fn nested_folders_keep_order_folding_and_every_id_is_fresh() {
    let mut ws = workspace(); ws.create_folder("inner", "Inner", "folder-docs", 0, &[]).unwrap();
    ws.move_item("tab-spec", "inner", 0, false).unwrap();
    ws.set_folder_collapsed("folder-docs", true).unwrap(); ws.set_folder_collapsed("inner", false).unwrap();
    let before = ws.clone(); let id = duplicate(&mut ws, "folder-docs", "pin-work", "folder-docs");
    let inner = ws.children(&id)[0].id.clone(); let tab = ws.children(&inner)[0].id.clone();
    for copy in [&id, &inner, &tab] { assert!(!before.items.contains_key(copy)); }
    assert!(ws.folder_collapsed[&id]); assert!(!ws.folder_collapsed[&inner]);
    assert_eq!(ws.items[&tab].kind, before.items["tab-spec"].kind);
    assert_eq!(ws.items[&inner].membership.order, before.items["inner"].membership.order);
    assert_eq!(ws.items[&tab].membership.order, before.items["tab-spec"].membership.order);
}
#[test]
fn split_and_its_child_duplicate_the_whole_split_and_remap_widths() {
    for source in ["split-1", "tab-a"] {
        let mut ws = workspace(); let before = ws.clone();
        let id = duplicate(&mut ws, source, "pin-work", "split-1");
        let old = before.children("split-1"); let new = ws.children(&id);
        assert_eq!(old.len(), new.len());
        for (a,b) in old.iter().zip(&new) { assert_ne!(a.id,b.id); assert_eq!(a.kind,b.kind); assert_eq!(a.membership.order,b.membership.order); assert_eq!(b.lifecycle,Lifecycle::Unloaded); }
        let ItemKind::Split { orientation, width_factors } = &ws.items[&id].kind else { panic!("not split") };
        let ItemKind::Split { orientation: original, width_factors: widths } = &before.items["split-1"].kind else { unreachable!() };
        assert_eq!(orientation, original); assert_eq!(width_factors.len(),widths.len());
        for ((id,width),(_,original)) in width_factors.iter().zip(widths) { assert!(new.iter().any(|item| &item.id==id)); assert_eq!(width,original); }
    }
}
#[test]
fn refusals_leave_state_unchanged() {
    let mut ws = workspace();
    for id in ["missing", "pin-work"] { let before=ws.clone(); assert!(ws.duplicate_item(id).is_err()); assert_eq!(ws,before); }
    for state in [Lifecycle::Archived,Lifecycle::Closed] {
        for id in ["tab-mail","folder-docs","split-1"] { let mut ws=workspace(); ws.items.get_mut(id).unwrap().lifecycle=state; let before=ws.clone(); assert!(ws.duplicate_item(id).is_err()); assert_eq!(ws,before); }
    }
}
#[test]
fn duplicate_persists_and_journal_replays_synced_state_without_local_records() {
    let path=std::env::temp_dir().join(format!("ararat-duplicate-{}.sqlite",std::process::id())); assert!(!path.exists());
    let (store,_) = Store::open(&path).unwrap(); let mut ws=workspace();
    ws.set_folder_collapsed("folder-docs", true).unwrap();
    store.write(ws.to_ops()); let ops=ws.duplicate_item("folder-docs").unwrap(); store.write(ops); store.flush().unwrap(); drop(store);
    let (store,loaded)=Store::open(&path).unwrap(); assert_eq!(loaded,ws); drop(store);
    let conn=rusqlite::Connection::open(&path).unwrap();
    let rows: Vec<(String,String,String)>=conn.prepare("SELECT kind,id,body FROM journal ORDER BY seq").unwrap().query_map([],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).unwrap().map(Result::unwrap).collect();
    let mut synced=Workspace::default();
    for (kind,id,body) in rows { let kind=Kind::parse(&kind).unwrap(); assert!(!matches!(kind,Kind::Window|Kind::LastSelected|Kind::FolderState)); synced.apply(&Op::Put(Record::parse(kind,&id,&body).unwrap())); }
    ws.folder_collapsed.clear(); ws.last_selected.clear(); ws.windows.clear(); assert_eq!(synced,ws); drop(conn);
    for suffix in ["","-wal","-shm"] { let _=std::fs::remove_file(format!("{}{suffix}",path.display())); }
}

#[test]
fn folder_copy_excludes_inactive_descendants_and_preserves_active_order() {
    let mut ws = workspace();
    ws.create_folder("inner", "Inner", "folder-docs", 0, &[]).unwrap();
    let mut closed = ws.items["tab-spec"].clone(); closed.id = "closed".into(); closed.lifecycle = Lifecycle::Closed; ws.items.insert(closed.id.clone(), closed);
    let mut archived = ws.items["tab-spec"].clone(); archived.id = "archived".into(); archived.lifecycle = Lifecycle::Archived; ws.items.insert(archived.id.clone(), archived);
    let before = ws.clone();
    let id = duplicate(&mut ws, "folder-docs", "pin-work", "folder-docs");
    assert_eq!(ws.children(&id).len(), 2);
    assert_eq!(ws.children(&id).iter().map(|i| i.display_title()).collect::<Vec<_>>(), ["Inner", before.items["tab-spec"].display_title()]);
    for id in ["closed", "archived"] { assert_eq!(ws.items[id], before.items[id]); }
    assert_eq!(ws.items.len(), before.items.len() + 3);
}

#[test]
fn duplicate_sorts_after_original_even_when_sibling_keys_tie() {
    let mut ws = workspace();
    let order = ws.items["folder-docs"].membership.order.clone();
    ws.items.get_mut("split-1").unwrap().membership.order = order;
    duplicate(&mut ws, "folder-docs", "pin-work", "folder-docs");
}

#[test]
fn unloaded_sources_stay_unloaded_and_inactive_ancestors_refuse() {
    let mut ws = workspace(); ws.items.get_mut("tab-mail").unwrap().lifecycle = Lifecycle::Unloaded;
    let original = ws.items["tab-mail"].clone();
    duplicate(&mut ws, "tab-mail", "fav-default", "tab-mail");
    assert_eq!(ws.items["tab-mail"], original);
    for state in [Lifecycle::Closed, Lifecycle::Archived] {
        let mut ws = workspace(); ws.items.get_mut("folder-docs").unwrap().lifecycle = state;
        let before = ws.clone(); assert!(ws.duplicate_item("tab-spec").is_err()); assert_eq!(ws, before);
    }
}

fn creation_racing_parent_delete_keeps_source_space(create_folder: bool) {
    let mut base = workspace();
    base.create_folder("home-parent", "Parent", "pin-home", 0, &[]).unwrap();
    let mut tab = base.items["tab-mail"].clone();
    tab.id = "home-tab".into(); tab.membership.parent = Some("home-parent".into());
    base.items.insert(tab.id.clone(), tab);
    let mut creator = base.clone();
    let ops = if create_folder {
        creator.create_folder("home-child", "Child", "home-parent", 0, &[]).unwrap()
    } else { creator.duplicate_item("home-tab").unwrap() };
    let copy = creator.items.keys().find(|id| !base.items.contains_key(*id)).unwrap().clone();
    let deletion = base.clone().delete_folder("home-parent").unwrap();
    for batches in [[&ops, &deletion], [&deletion, &ops]] {
        let mut merged = base.clone();
        for batch in batches { for op in batch { merged.apply(op); } }
        merged.repair_tree(); merged.check_tree().unwrap();
        assert_eq!(merged.items[&copy].membership.parent.as_deref(), Some("today-home"));
        assert_ne!(base.spaces[0].profile, base.spaces[1].profile);
    }
}

#[test]
fn duplicate_racing_parent_delete_repairs_into_source_space_in_both_orders() {
    creation_racing_parent_delete_keeps_source_space(false);
}

#[test]
fn create_folder_racing_parent_delete_repairs_into_source_space_in_both_orders() {
    creation_racing_parent_delete_keeps_source_space(true);
}
