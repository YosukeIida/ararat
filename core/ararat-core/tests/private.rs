use ararat_core::model::{Profile, Workspace};
use ararat_core::storage::Store;

#[test]
fn private_workspace_never_retains_archives_or_selection_recency() {
    let store = Store::private();
    let mut workspace = Workspace::private(Profile::Default);
    store.write(workspace.create_tab("w", "https://one.example/").unwrap());
    let first = workspace.selected("w").unwrap().to_string();
    store.write(workspace.create_tab("w", "https://two.example/").unwrap());
    workspace.select_item("w", &first).unwrap();
    assert!(workspace.last_selected.is_empty());
    assert!(workspace.windows.values().all(|window| window.history.is_empty()));
    store.write(workspace.archive_item(&first).unwrap());
    assert!(!workspace.items.contains_key(&first));
    assert!(workspace.archive().is_empty());
    assert!(workspace.history_purges.is_empty());
    store.flush().unwrap();
}
