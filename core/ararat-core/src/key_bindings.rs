use serde::{Deserialize, Serialize};

use crate::edit::EditError;
use crate::model::{Kind, Op, Record, Workspace};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeyCombination {
    pub key: String,
    pub command: bool,
    pub control: bool,
    pub option: bool,
    pub shift: bool,
}

impl KeyCombination {
    fn validated(mut self, default_key: Option<&Self>) -> Result<Self, EditError> {
        self.key = self.key.to_lowercase();
        if self.key.chars().count() != 1 || self.key.chars().any(|c| c.is_control() && !matches!(c, '\t' | '\r' | '\u{1b}' | '\u{7f}')) {
            return Err(EditError("a shortcut needs one key".into()));
        }
        if !self.command && !self.control && !self.option {
            return Err(EditError("a shortcut needs Command, Control or Option".into()));
        }
        let reserved = matches!((self.command, self.control, self.option, self.shift, self.key.as_str()),
            (true, false, false, false, "q" | "h" | "\t" | " " | "`") |
            (true, false, false, true, "3" | "4" | "5" | "#" | "$" | "%" | "\t" | "`") |
            (true, false, true, false, "h" | "\u{1b}") |
            (true, true, false, false, "q"));
        if reserved && Some(&self) != default_key {
            return Err(EditError("this shortcut is reserved by the system".into()));
        }
        Ok(self)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Command {
    pub id: String,
    pub title: String,
    pub menu: String,
    pub description: String,
    pub default_key: Option<KeyCombination>,
}

pub fn commands() -> Vec<Command> {
    let key = |key: &str, command, control, shift| Some(KeyCombination { key: key.into(), command, control, option: false, shift });
    let mut commands: Vec<_> = [
        ("settings", "Settings…", "Ararat", "Open settings for the shown space.", key(",", true, false, false)),
        ("quit", "Quit Ararat Harness", "Ararat", "Close all windows and quit Ararat.", key("q", true, false, false)),
        ("close_tab", "Close Tab", "File", "Close the selected tab in the browser window.", key("w", true, false, false)),
        ("new_tab", "New Tab", "Tabs", "Open a new tab from the command bar.", key("t", true, false, false)),
        ("edit_url", "Edit URL", "Tabs", "Edit the current tab's URL in the command bar.", key("l", true, false, false)),
        ("pin_tab", "Pin Tab", "Tabs", "Pin or unpin the selected tab.", key("d", true, false, false)),
        ("duplicate", "Duplicate", "Tabs", "Duplicate the selected row.", None),
        ("new_folder", "New Folder", "Tabs", "Create a folder in pinned.", None),
        ("rename", "Rename", "Tabs", "Rename the selected row.", None),
        ("delete_folder", "Delete Folder", "Tabs", "Delete the selected folder.", None),
        ("toggle_sidebar", "Toggle Sidebar", "View", "Show or hide the sidebar.", key("s", true, false, false)),
        ("toggle_library", "Toggle Library", "View", "Show or hide the Library.", key("l", true, false, true)),
        // Chrome already performs the cache-bypassing reload at this key (IDC_RELOAD_BYPASSING_CACHE,
        // accelerators_cocoa.mm:95-97); the entry exists so the pane lists and rebinds it (U23 D6).
        ("force_reload", "Force Reload", "View", "Reload the page, ignoring the cache.", key("r", true, false, true)),
        ("reset_sidebar_width", "Reset Sidebar Width", "View", "Reset the sidebar width.", None),
    ].into_iter().map(|(id, title, menu, description, default_key)| Command {
        id: id.into(), title: title.into(), menu: menu.into(), description: description.into(), default_key,
    }).collect();
    commands.extend((1..=9).map(|n| Command {
        id: format!("show_space_{n}"), title: format!("Show Space {n}"), menu: "View".into(),
        description: format!("Show space {n} in sidebar order."), default_key: key(&n.to_string(), false, true, false),
    }));
    commands.extend((1..=9).map(|n| Command {
        id: format!("move_to_space_{n}"), title: format!("Move to Space {n}"), menu: "Tabs".into(),
        description: format!("Move the selected row to space {n}."), default_key: None,
    }));
    commands
}

fn command(id: &str) -> Result<Command, EditError> {
    commands().into_iter().find(|c| c.id == id).ok_or_else(|| EditError(format!("unknown command {id}")))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyBinding {
    pub command: Command,
    pub key: Option<KeyCombination>,
    pub conflicting: bool,
}

impl Workspace {
    pub fn key_bindings(&self) -> Vec<KeyBinding> {
        let mut claimed = Vec::new();
        commands().into_iter().map(|command| {
            let key = self.assigned_key(&command);
            let conflicting = key.as_ref().is_some_and(|key| claimed.contains(key));
            if let Some(key) = &key {
                if !conflicting { claimed.push(key.clone()); }
            }
            KeyBinding { command, key: if conflicting { None } else { key }, conflicting }
        }).collect()
    }

    fn assigned_key(&self, command: &Command) -> Option<KeyCombination> {
        self.key_binding_overrides.get(&command.id).cloned().unwrap_or_else(|| command.default_key.clone())
    }

    pub fn key_binding(&self, id: &str) -> Result<Option<KeyCombination>, EditError> {
        self.key_bindings().into_iter().find(|binding| binding.command.id == id)
            .map(|binding| binding.key).ok_or_else(|| EditError(format!("unknown command {id}")))
    }

    pub fn set_key_binding(&mut self, id: &str, key: Option<KeyCombination>) -> Result<Vec<Op>, EditError> {
        let command = command(id)?;
        let key = key.map(|key| key.validated(command.default_key.as_ref())).transpose()?;
        Ok(self.assign_key_binding(command, key))
    }

    pub fn reset_key_binding(&mut self, id: &str) -> Result<Vec<Op>, EditError> {
        let command = command(id)?;
        let key = command.default_key.clone();
        Ok(self.assign_key_binding(command, key))
    }

    fn assign_key_binding(&mut self, command: Command, key: Option<KeyCombination>) -> Vec<Op> {
        let mut ops = Vec::new();
        if let Some(key) = &key {
            for other in commands().into_iter().filter(|c| c.id != command.id) {
                if self.assigned_key(&other).as_ref() == Some(key) {
                    ops.push(Op::Put(Record::KeyBinding { command: other.id, key: None }));
                }
            }
        }
        if key == command.default_key {
            if self.key_binding_overrides.contains_key(&command.id) {
                ops.push(Op::Delete(Kind::KeyBinding, command.id));
            }
        } else if self.key_binding_overrides.get(&command.id) != Some(&key) {
            ops.push(Op::Put(Record::KeyBinding { command: command.id, key }));
        }
        for op in &ops { self.apply(op); }
        ops
    }

    pub fn reset_all_key_bindings(&mut self) -> Vec<Op> {
        let mut ids: Vec<_> = self.key_binding_overrides.keys().cloned().collect();
        ids.sort();
        let ops: Vec<_> = ids.into_iter().map(|id| Op::Delete(Kind::KeyBinding, id)).collect();
        for op in &ops { self.apply(op); }
        ops
    }
}
