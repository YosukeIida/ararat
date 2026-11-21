import AppKit
import AraratKit
import SwiftUI

/// U27j: the onboarding flow's data and state. The flow is screens only: the Arc sidebar,
/// windows, key bindings and routing arrive as injected strings, the core's string-based import
/// runs into a store at the path the caller names (the check's `--ararat-db`), and nothing in this
/// file reads `~/Library/Application Support/Arc` or the Keychain. It has no API that takes an Arc
/// path — there is deliberately no "Choose Folder…" seam.
///
/// D10: the report and both error screens print `ImportReport` fields and `ImportError`'s message,
/// nothing else. A line with no producer is dropped, so there is no sign-in line (O5) and the two
/// Passwords / Sign-in state rows are absent rather than disabled (O4, the site-controls rule).

/// One space as the source screen draws it, from the fixture: the core import has not run yet, so
/// these counts come from the fixture's own description of Arc.
public struct OnboardingSpaceSource: Equatable, Sendable {
    public let id: String
    public let title: String
    public let profileName: String
    public let pinnedCount: Int

    public init(id: String, title: String, profileName: String, pinnedCount: Int) {
        self.id = id
        self.title = title
        self.profileName = profileName
        self.pinnedCount = pinnedCount
    }
}

/// The four Arc files, as strings, plus the fixture's description of what is in them.
public struct OnboardingData: Sendable {
    public let sidebar: String
    public let windows: String
    public let keyBindings: String
    public let routing: String
    public let spaces: [OnboardingSpaceSource]
    var fixturePasswordResults: [OnboardingFixturePasswordResult] = []
    /// The importers that are listed dimmed with "Later" (F-Onboarding screen 2).
    public let laterBrowsers: [String]

    public init(sidebar: String, windows: String, keyBindings: String, routing: String,
                spaces: [OnboardingSpaceSource], laterBrowsers: [String] = ["Dia", "Chrome", "Safari", "Firefox"]) {
        self.sidebar = sidebar
        self.windows = windows
        self.keyBindings = keyBindings
        self.routing = routing
        self.spaces = spaces
        self.laterBrowsers = laterBrowsers
    }
}

struct OnboardingFixturePasswordResult: Sendable {
    enum Outcome: Sendable {
        case imported(added: Int, existing: Int, conflicts: Int, neverSaved: Int, undecryptable: Int, invalid: Int)
        case noKey
        case unsupportedVersion
    }

    let profile: String
    let outcome: Outcome

    var reportLines: [OnboardingReportLine] {
        let id = "passwords-" + profile
        switch outcome {
        case let .imported(added, existing, conflicts, neverSaved, undecryptable, invalid):
            return [
                .init(id: id, text: "\(profile) passwords: \(added) added, \(existing) existing, \(conflicts) conflicts."),
                .init(id: id + "-details", text: "\(neverSaved) Never rows skipped, \(undecryptable) unreadable, \(invalid) invalid.")
            ]
        case .noKey:
            return [.init(id: id, text: "\(profile): Access to Arc Safe Storage was not allowed")]
        case .unsupportedVersion:
            return [.init(id: id, text: "\(profile): Unsupported Arc password database version")]
        }
    }
}

/// O6: a shipping build lists Arc as a source only when Arc.app is installed. The lookup is
/// LaunchServices by bundle id and reads no file and no count.
public protocol OnboardingSourceDetector: AnyObject {
    func isArcInstalled() -> Bool
}

public final class LaunchServicesSourceDetector: OnboardingSourceDetector {
    public init() {}
    public func isArcInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "company.thebrowser.Browser") != nil
    }
}

/// Screen 4's one seam: the button asks this setter to make Ararat the default browser. A check
/// injects a fake and asserts the call, so neither the VM nor the host's handler changes.
public protocol DefaultBrowserSetter {
    func requestDefaultBrowser()
}

public struct LaunchServicesDefaultBrowser: DefaultBrowserSetter {
    private let setDefaultApplication: (URL, String, @escaping (Error?) -> Void) -> Void

    public init() {
        self.init(setDefaultApplication: { app, scheme, completion in
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) { completion($0) }
        })
    }

    init(setDefaultApplication: @escaping (URL, String, @escaping (Error?) -> Void) -> Void) {
        self.setDefaultApplication = setDefaultApplication
    }

    public func requestDefaultBrowser() {
        // Why not request https too: macOS changes both handlers with one http confirmation.
        setDefaultApplication(Bundle.main.bundleURL, "http") { _ in }
    }
}

/// The done screen's six counts. Five come from the imported snapshot, the routes from the
/// report's `imported_rules`, so the line can only say what the import produced.
public struct OnboardingSummary: Equatable, Sendable {
    public let spaces: Int
    public let pinnedTabs: Int
    public let folders: Int
    public let favourites: Int
    public let looks: Int
    public let routes: Int

    public init(spaces: Int, pinnedTabs: Int, folders: Int, favourites: Int, looks: Int, routes: Int) {
        self.spaces = spaces
        self.pinnedTabs = pinnedTabs
        self.folders = folders
        self.favourites = favourites
        self.looks = looks
        self.routes = routes
    }

    /// The report alone: the import counts these from the workspace it produced, so a store that
    /// held spaces before the import cannot inflate them. Routes are the routing import's
    /// `imported_rules`.
    init(report: ImportReport) {
        spaces = Int(report.spaces)
        pinnedTabs = Int(report.pinnedTabs)
        folders = Int(report.folders)
        favourites = Int(report.favouriteTabs)
        looks = Int(report.spacesWithLook)
        routes = Int(report.importedRules)
    }

    /// F-Import screen 6's line, with each count's noun.
    public var line: String {
        "\(spaces) \(spaces == 1 ? "space" : "spaces") · \(pinnedTabs) pinned tabs · "
            + "\(folders) \(folders == 1 ? "folder" : "folders") · \(favourites) favourites · "
            + "\(looks) \(looks == 1 ? "look" : "looks") · \(routes) \(routes == 1 ? "route" : "routes")"
    }
}

/// One "Imported differently" row. Only the report's own counters produce one.
public struct OnboardingReportLine: Equatable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

@MainActor
public final class OnboardingModel: NSObject, ObservableObject {
    public enum Stage: Equatable {
        case welcome
        case source
        case whatToImport
        case defaultBrowser
        case progress
        /// Screen 8: the import finished but a sibling file could not be read. The message is the
        /// report's error field verbatim.
        case siblingFile(String)
        case done
        /// Screen 7: the import itself stopped. The message is `ImportError`'s own text.
        case error(String)
    }

    @Published public private(set) var stage: Stage = .welcome {
        didSet { onChange?() }
    }
    @Published public private(set) var summary: OnboardingSummary?
    @Published public private(set) var lines: [OnboardingReportLine] = []
    public private(set) var report: ImportReport?
    /// Screen 4's fake-call count: the model counts the setter it was given, so the check reads
    /// one number whether the setter is the fake or the LaunchServices one.
    public private(set) var defaultBrowserCalls = 0

    /// `var`: the check walks a second and third fixture through the same window; a shipping
    /// build is only ever given the one its entry supplies.
    public var data: OnboardingData
    public let storePath: String
    public let detector: OnboardingSourceDetector
    public let defaultBrowser: DefaultBrowserSetter
    /// The window redraws when the stage moves; the check calls the same path directly.
    public var onChange: (() -> Void)?
    /// Where the progress screen hands its one import. The default is the next main run-loop turn;
    /// a check injects a holding scheduler, because a screenshot's `waitUntilExit()` spins the
    /// default run loop and would otherwise run the import under the capture.
    public typealias ImportScheduler = @MainActor (@escaping @MainActor () -> Void) -> Void
    public let schedule: ImportScheduler
    /// "Start Fresh", a done window's "Continue" and the close button all end here.
    public var onFinish: (() -> Void)?

    public init(storePath: String, data: OnboardingData,
                detector: OnboardingSourceDetector = LaunchServicesSourceDetector(),
                defaultBrowser: DefaultBrowserSetter = LaunchServicesDefaultBrowser(),
                schedule: @escaping ImportScheduler = OnboardingModel.runLoopScheduler) {
        self.storePath = storePath
        self.data = data
        self.detector = detector
        self.defaultBrowser = defaultBrowser
        self.schedule = schedule
        super.init()
    }

    /// The shipping path: the import runs on the next main run-loop turn, so the window can draw
    /// the progress screen first. Not a timer.
    @MainActor
    public static func runLoopScheduler(_ block: @escaping @MainActor () -> Void) {
        RunLoop.main.perform(inModes: [.common, .modalPanel]) {
            MainActor.assumeIsolated { block() }
        }
    }

    /// The five step dots: welcome through progress. The done and error screens carry none of
    /// their own (the board repeats the last footer as decoration).
    public var dotIndex: Int? {
        switch stage {
        case .welcome: return 0
        case .source: return 1
        case .whatToImport: return 2
        case .defaultBrowser: return 3
        case .progress: return 4
        default: return nil
        }
    }

    // MARK: - Screen 2's rows

    /// Arc is listed when LaunchServices finds Arc.app (O6); the fixture detector says so under a
    /// check. The count is the fixture's; a shipping build has no fixture, so no count is drawn.
    public var arcInstalled: Bool { detector.isArcInstalled() }
    public var arcSpaceCount: Int { data.spaces.count }
    public var laterBrowsers: [String] { data.laterBrowsers }

    // MARK: - Screen 3's rows

    public var spaceRows: [OnboardingSpaceSource] { data.spaces }

    /// What the core importer actually carries (import.rs): favourites, looks, Air Traffic Control
    /// routes and folder open states.
    public var alsoRows: [String] { ["Favourites", "Looks", "Air Traffic Control routes", "Folder open states"] }
    public var passwordProfileNames: [String] { data.fixturePasswordResults.map(\.profile) }

    // MARK: - Navigation

    public func advance() {
        switch stage {
        case .welcome: stage = .source
        case .source: stage = .whatToImport
        case .whatToImport: stage = .defaultBrowser
        case .defaultBrowser: enterProgress()
        default: break
        }
    }

    public func goBack() {
        switch stage {
        case .source: stage = .welcome
        case .whatToImport: stage = .source
        case .defaultBrowser: stage = .whatToImport
        default: break
        }
    }

    /// "Start Fresh" and a done window's "Continue": the flow ends without an import (or after
    /// one), the window closes, and the browser stays as it was.
    public func startFresh() { onFinish?() }

    /// Back to the first screen with nothing imported. A shipping build never calls it; the check
    /// uses it to walk a second fixture through the same window.
    public func restart() {
        stage = .welcome
        summary = nil
        lines = []
        report = nil
        onChange?()
    }

    /// Screen 4's button: one call through the injected setter, then the flow moves on.
    public func setAsDefault() {
        defaultBrowser.requestDefaultBrowser()
        defaultBrowserCalls += 1
        advance()
    }

    /// The same advance for "Not Now", without touching the setter.
    public func notNow() { advance() }

    // MARK: - The import (screen 5)

    /// Screen 5's stage, then the one synchronous core call on the next run-loop turn, so the
    /// progress screen is drawn first. Not a timer: `RunLoop.main.perform` is the same turn the
    /// workspace writes use. The rows are the four files the call reads, in its order.
    private func enterProgress() {
        stage = .progress
        summary = nil
        lines = []
        report = nil
        onChange?()
        schedule { [weak self] in self?.performImport() }
    }

    /// One row per file the import consumes, in the order `arc_sidebar` reads them.
    public static let progressSteps = ["Spaces, tabs, folders and looks", "Folder states", "Keyboard shortcuts", "Air Traffic Control routes"]

    /// Runs the core's string-based import into the store at `storePath`. The error is the
    /// ImportError message; a sibling file's error is a report field and becomes screen 8.
    private func performImport() {
        guard case .progress = stage else { return }
        do {
            let store = try WorkspaceStore.open(path: storePath)
            let result = try store.importArcSidebar(windowId: "onboarding", json: data.sidebar,
                                                    windowsJson: data.windows, keyBindingsJson: data.keyBindings,
                                                    linkRoutingJson: data.routing, ownerProfile: nil)
            report = result.report
            summary = OnboardingSummary(report: result.report)
            lines = Self.reportLines(result.report) + data.fixturePasswordResults.flatMap(\.reportLines)
            stage = Self.siblingError(result.report).map { .siblingFile($0) } ?? .done
        } catch {
            stage = .error(Self.errorText(error))
        }
    }

    /// Screen 7's "Try Again": the same fixture, a fresh progress stage, and the import runs again
    /// on the next turn. Importing the same strings twice is the core's idempotent override path.
    public func retry() {
        guard case .error = stage else { return }
        enterProgress()
    }

    /// Screen 8's "Continue": the counts the import produced.
    public func continueAfterSiblingWarning() {
        guard case .siblingFile = stage else { return }
        stage = .done
    }

    /// Screen 7's "Copy Details": the ImportError's message, the only detail there is (D10).
    public func copyDetails() {
        guard case .error(let message) = stage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
    }

    // MARK: - The report (screens 6 and 8)

    /// The first sibling-file error the report carries, named by its file. A missing sibling file
    /// is not an error: the core imports what it has and the report says what was missing.
    static func siblingError(_ report: ImportReport) -> String? {
        if let error = report.windowsError { return "StorableWindows.json: \(error)" }
        if let error = report.keyBindingsError { return "StorableKeyBindings.json: \(error)" }
        if let error = report.linkRoutingError { return "StorableLinkRouting.json: \(error)" }
        return nil
    }

    /// The "Imported differently" rows, in the board's order, each from its own counter. A zero
    /// counter draws nothing.
    static func reportLines(_ report: ImportReport) -> [OnboardingReportLine] {
        var lines: [OnboardingReportLine] = []
        func add(_ id: String, _ count: Int, _ text: (Int) -> String) {
            guard count > 0 else { return }
            lines.append(OnboardingReportLine(id: id, text: text(count)))
        }
        add("peeked", Int(report.peekedFolders)) {
            "\($0) \($0 == 1 ? "folder was" : "folders were") peeked in Arc. They are closed here."
        }
        add("folder-states", Int(report.differingFolderStates)) {
            "\($0) \($0 == 1 ? "folder was" : "folders were") open in one Arc window and closed in another. "
                + "Here \($0 == 1 ? "it follows" : "they follow") the first window."
        }
        add("looks", Int(report.unknownSpaceLooks)) {
            "\($0) \($0 == 1 ? "space had a look" : "spaces had looks") Ararat could not read, so "
                + ($0 == 1 ? "it was" : "they were") + " left out."
        }
        for (profile, count) in report.skippedFavouritesByProfile.sorted(by: { $0.key < $1.key }) {
            add("favourites-\(profile)", Int(count)) {
                "\($0) \($0 == 1 ? "favourite was" : "favourites were") skipped from “\(profile)” because the profile had no imported space."
            }
        }
        add("profile-routes", Int(report.skippedProfileDestinations)) {
            "\($0) \($0 == 1 ? "route sent" : "routes sent") links to a profile. "
                + ($0 == 1 ? "It was" : "They were") + " skipped."
        }
        add("unknown-routes", Int(report.skippedUnknownDestinations)) {
            "\($0) \($0 == 1 ? "route had" : "routes had") a destination Ararat does not know. "
                + ($0 == 1 ? "It was" : "They were") + " skipped."
        }
        add("unknown-styles", Int(report.skippedUnknownStyles)) {
            "\($0) \($0 == 1 ? "route used a match style" : "routes used match styles") Ararat does not know. "
                + ($0 == 1 ? "It was" : "They were") + " skipped."
        }
        add("malformed-rules", Int(report.malformedRules)) {
            "\($0) \($0 == 1 ? "route was" : "routes were") malformed and left out."
        }
        add("key-bindings", Int(report.skippedKeyBindings)) {
            "\($0) custom \($0 == 1 ? "keyboard shortcut was" : "keyboard shortcuts were") not imported."
        }
        add("dates", Int(report.skippedDates)) {
            "\($0) \($0 == 1 ? "date was" : "dates were") out of range and not kept."
        }
        add("window-ids", Int(report.unknownWindowIds)) {
            "\($0) \($0 == 1 ? "id in the windows file named" : "ids in the windows file named") no known row and "
                + ($0 == 1 ? "was" : "were") + " ignored."
        }
        add("window-entries", Int(report.malformedWindowEntries)) {
            "\($0) \($0 == 1 ? "entry in the windows file was" : "entries in the windows file were") malformed and ignored."
        }
        // `imported_rules` is the summary's route count, not a difference.
        return lines
    }

    static func errorText(_ error: Error) -> String {
        if let core = error as? CoreError {
            switch core {
            case .Edit(let message), .Import(let message), .Store(let message), .Live(let message): return message
            }
        }
        return error.localizedDescription
    }
}
