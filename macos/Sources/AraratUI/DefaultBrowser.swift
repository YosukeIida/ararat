import AppKit

/// P5b: Settings › General's default-browser row. Two seams, because the row both reads and
/// writes: the status is what LaunchServices answers for https right now, and the button asks the
/// same setter onboarding's screen 4 uses. A check injects a fake for both, so no check changes the
/// host's handler and the row's own copy is what the scenario reads.
public protocol DefaultBrowserStatus {
    func isDefaultBrowser() -> Bool
}

/// The shipping status: the application LaunchServices opens https with, compared with this app.
/// Resolved through symlinks and standardized, so the path compare is between the same files; a
/// second copy of the app at another path (a build tree beside /Applications) reads as not default,
/// which is what LaunchServices would say.
public struct LaunchServicesDefaultBrowserStatus: DefaultBrowserStatus {
    public init() {}

    public func isDefaultBrowser() -> Bool {
        guard let probe = URL(string: "https://example.com/"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        let app = Bundle.main.bundleURL
        return handler.standardizedFileURL.resolvingSymlinksInPath().path
            == app.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
