use ararat_core::{import::arc_sidebar, model::{Lifecycle, Workspace}};

pub fn arc_workspace_with_open_tabs() -> Workspace {
    let mut workspace = arc_sidebar(include_str!("arc-sidebar-synthetic.json"), None, None, None, None).unwrap().0;
    for item in workspace.items.values_mut().filter(|item| item.lifecycle == Lifecycle::Unloaded) {
        item.lifecycle = Lifecycle::Open;
    }
    workspace
}
