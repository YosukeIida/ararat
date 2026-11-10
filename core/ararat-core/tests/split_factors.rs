use ararat_core::{import::arc_sidebar, model::{ItemKind, Lifecycle, Op, Record}};

#[test]
fn factors_are_normalized_without_changing_imported_data_and_edits_are_validated() {
    let (mut ws, _) = arc_sidebar(include_str!("fixtures/arc-sidebar-synthetic.json"), None, None, None, None).unwrap();
    let ItemKind::Split { width_factors, .. } = &mut ws.items.get_mut("split-1").unwrap().kind else { panic!() };
    *width_factors = vec![("tab-a".into(), 2.0), ("tab-b".into(), 3.0), ("tab-b".into(), 4.0), ("foreign".into(), 9.0)];
    let before = ws.clone();
    assert_eq!(ws.split_factors("split-1").unwrap(), vec![("tab-a".into(), 0.5), ("tab-b".into(), 0.5)]);
    assert_eq!(ws, before);
    assert!(ws.set_split_factors("split-1", vec![("tab-a".into(), f64::NAN)]).is_err());
    assert_eq!(ws, before);
    ws.items.get_mut("tab-b").unwrap().lifecycle = Lifecycle::Closed;
    let ops = ws.set_split_factors("split-1", vec![("tab-a".into(), 1.0)]).unwrap();
    assert!(matches!(&ops[..], [Op::Put(Record::Item(_))]));
    let ItemKind::Split { width_factors, .. } = &ws.items["split-1"].kind else { panic!() };
    assert!(width_factors.iter().any(|(id, _)| id == "tab-b"));
}
