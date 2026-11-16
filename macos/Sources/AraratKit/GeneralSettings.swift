import Foundation

/// P5b: Settings › General's two engine-backed records in the words the pane, the check and the
/// engine entry share. `StartupBehavior`'s labels are the pane's copy and live in SettingsModel,
/// next to the other panes' labels.
extension DownloadSettings {
    /// Chromium's built-in state: no folder of the app's own (the account's Downloads folder) and
    /// no prompt. A workspace that never touched the rows stores nothing and shows these.
    public static var board: DownloadSettings {
        DownloadSettings(directory: "", askWhereToSave: false)
    }

    /// The record as `AraratApplyDownloadSettings` reads it: the folder (an empty string leaves
    /// Chromium's own default alone) and the ask-each-file pref.
    public var engineRequest: [String: Any] {
        ["directory": directory, "prompt": askWhereToSave]
    }

    /// The folder the row names: the chosen folder's own name, or Chromium's default. A record
    /// written by another Mac may hold a folder this Mac does not have, and the row still names it
    /// as the stored path rather than pretending the default.
    public var folderName: String {
        guard !directory.isEmpty else { return "Downloads" }
        let name = (directory as NSString).lastPathComponent
        return name.isEmpty ? directory : name
    }
}
