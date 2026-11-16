import Foundation

/// P5b: Settings › General's downloads record in the words the pane and the engine entry share.
/// `StartupBehavior`'s labels are the pane's copy and live in SettingsModel, next to the other
/// panes' labels.
extension DownloadDevice {
    /// Chromium's built-in state: no folder of the app's own (the account's Downloads folder) and
    /// no prompt. A workspace that never touched the rows stores nothing and shows these.
    public static var board: DownloadDevice {
        DownloadDevice(directory: "", askWhereToSave: false)
    }

    /// The folder the row names: the chosen folder's own name, or Chromium's default. A record
    /// written on another Mac may hold a folder this Mac does not have — the record is per
    /// device, so it does not travel — and a chosen folder still reads by its own name.
    public var folderName: String {
        guard !directory.isEmpty else { return "Downloads" }
        let name = (directory as NSString).lastPathComponent
        return name.isEmpty ? directory : name
    }
}
