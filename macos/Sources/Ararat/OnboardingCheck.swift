import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

/// U27j's check: the onboarding window opened by the command the File menu and the command bar
/// carry under a check. It walks the eight screens — welcome, source, what to import, default
/// browser, progress, done, the stopped import and the sibling-file warning — captures each, and
/// asserts that the report's numbers are the showcase fixture's (so the import read the injected
/// strings, not the owner's Arc), that the store is the check's `--ararat-db`, that the default
/// browser button went through the fake and the host's handler did not move, and that the
/// sign-in and Passwords rows and line are absent.

/// The screen 4 seam as the check injects it: counts the calls and never touches LaunchServices.
final class FakeDefaultBrowserSetter: DefaultBrowserSetter {
    private(set) var calls = 0
    func requestDefaultBrowser() { calls += 1 }
}

@MainActor
final class OnboardingCheckState {
    static let conditions = [
        "window_open", "window_size", "entry_menu", "entry_command_bar",
        "welcome", "welcome_buttons", "source_rows", "source_later", "space_rows", "also_rows",
        "no_signin_rows", "default_browser", "setter_called", "real_default_unchanged",
        "progress_steps", "report_numbers", "report_lines", "no_signin_line",
        "fixture_store_only", "error_screen", "error_message", "copy_details",
        "sibling_screen", "sibling_message", "sibling_continue",
    ]
    static let screens = ["welcome", "source", "what-to-import", "default-browser", "progress", "done", "error", "sibling-file"]

    var values: [String: Bool] = [:]
    var images: [String: String] = [:]
    var capturing = false
    var lastWait = ""
    var details: [String: Any] = [:]
    var realDefaultBefore = ""
    var errorMessage = ""
    var replayedFirstScreen = false

    func report(_ name: String, _ ok: Bool) {
        values[name] = ok
        FileHandle.standardError.write(Data("ararat-trace: onboarding \(name)=\(ok)\n".utf8))
    }

    static func conditionNames(screen: Bool) -> [String] { conditions + (screen ? ["capture"] : []) }

    func diagnostics(screen: Bool) -> [String: Any] {
        let names = Self.conditionNames(screen: screen)
        return ["conditions": Dictionary(uniqueKeysWithValues: names.map { ($0, values[$0] == true) }),
                "failed_conditions": names.filter { values[$0] != true },
                "wait": lastWait, "images": images, "details": details]
    }
}

extension Runtime {
    /// The entry is a check-only command until the importer reads real files (O7): the menu item
    /// and the command bar row exist only while a check runs, and the flow has no data source
    /// without the fixture. A shipping build therefore cannot reach the window (hide, not disable).
    static var onboardingEntryVisible: Bool {
        CommandLine.arguments.contains { $0.hasPrefix("--ararat-check=") || $0.hasPrefix("--ararat-screen=") }
    }

    /// The command `import_from_arc`: the File menu item and the command bar row both run it.
    func openOnboarding() {
        guard Runtime.onboardingEntryVisible else { return }
        guard let path = (root ?? self).quitPath else { return }
        let owner = root ?? self
        if let existing = owner.onboardingWindow {
            existing.open()
            return
        }
        let setter = FakeDefaultBrowserSetter()
        let model = OnboardingModel(storePath: path, data: OnboardingFixtures.showcase,
                                    detector: OnboardingFixtures.FixtureSourceDetector(), defaultBrowser: setter)
        let controller = OnboardingWindowController(model: model)
        owner.onboardingWindow = controller
        owner.onboardingDefaultBrowser = setter
        controller.open()
        FileHandle.standardError.write(Data("ararat-trace: onboarding opened store=\(path)\n".utf8))
    }

    func onboardingCheckDiagnostics(screen: Bool) -> [String: Any] {
        (onboardingCheck ?? OnboardingCheckState()).diagnostics(screen: screen)
    }

    /// What the host's http(s) handler is right now: the check reads it before and after screen 4,
    /// so it can say the fake was called and the handler did not move.
    func onboardingDefaultHandler() -> String {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "http://example.com/")!)?.path ?? ""
    }

    func onboardingCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
        if onboardingCheck == nil { onboardingCheck = OnboardingCheckState() }
        guard let check = onboardingCheck, !check.capturing else { return }
        let owner = root ?? self
        let window = host.window()
        func wait(_ name: String) {
            if check.lastWait != name {
                check.lastWait = name
                FileHandle.standardError.write(Data("ararat-trace: onboarding wait=\(name) phase=\(browserCheckPhase) window=\(owner.onboardingWindow != nil)\n".utf8))
            }
        }
        func capture(_ name: String) -> Bool {
            guard screen else { return true }
            guard let target = owner.onboardingWindow?.window else { return false }
            check.capturing = true
            defer { check.capturing = false }
            guard let path = promptScreenScreenshot(target, name: "onboarding-\(name)", withoutShadow: true) else { return false }
            check.images[name] = path
            return true
        }
        func finish() {
            let result = check.diagnostics(screen: screen)
            finishBrowserCheck(ok: (result["failed_conditions"] as? [String] ?? ["invalid"]).isEmpty, values: result)
        }
        func probe() -> OnboardingCheckProbe? { owner.onboardingWindow?.checkProbe() }
        func mark(_ name: String, _ ok: Bool) { check.report(name, ok) }
        func walkToProgress(_ model: OnboardingModel) {
            model.advance()   // welcome → source
            model.advance()   // source → what to import
            model.advance()   // what to import → default browser
            model.notNow()    // default browser → progress
        }

        switch browserCheckPhase {
        case 0:
            guard workspace != nil, quitPath != nil else { wait("workspace"); return }
            // The entry the check proves: a File menu item and a command bar row, both named.
            let menuItem = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.items.first {
                $0.identifier?.rawValue == OnboardingCommandStore.commandID
            }
            mark("entry_menu", menuItem != nil && menuItem?.action == #selector(Runtime.importFromArc(_:)))
            let store = OnboardingCommandStore(base: StubCommandStore())
            let rows = store.query("import", history: []).rows
            var rowIsEntry = false
            if let target = rows.first?.target {
                if case .command(let id) = target { rowIsEntry = id == OnboardingCommandStore.commandID }
            }
            mark("entry_command_bar", rows.count == 1 && rows.first?.title == "Import from Arc…" && rowIsEntry)
            check.realDefaultBefore = onboardingDefaultHandler()
            openOnboarding()
            browserCheckPhase = 1
        case 1:
            guard let probe = probe() else { wait("onboarding window"); return }
            probe.layout()
            guard probe.isVisible, probe.stage == .welcome else { wait("welcome"); return }
            let size = probe.contentSize
            mark("window_open", true)
            mark("window_size", abs(size.width - OnboardingMetrics.size.width) <= 1
                 && abs(size.height - OnboardingMetrics.size.height) <= 1)
            let start = probe.frame("onboarding-start-fresh")
            let next = probe.frame("onboarding-next")
            mark("welcome", probe.title == "Welcome to Ararat" && probe.subtitle.contains("Vertical tabs")
                 && probe.dots == 5 && probe.filledDot == 0)
            mark("welcome_buttons", start != nil && next != nil && (start?.minX ?? 0) < (next?.minX ?? 0)
                 && abs((next?.height ?? 0) - OnboardingMetrics.buttonHeight) <= 1)
            mark("capture", capture("welcome"))
            probe.click("onboarding-next")
            browserCheckPhase = 2
        case 2:
            guard let probe = probe(), probe.stage == .source else { wait("source"); return }
            probe.layout()
            let rows = probe.sourceRows
            let arc = rows.first { $0.id == "onboarding-source-arc" }
            mark("source_rows", probe.title == "Bring your browser with you" && arc?.text.contains("3 spaces") == true)
            let later = rows.filter(\.later)
            mark("source_later", later.count == 4 && later.allSatisfy { $0.text.contains("Later") }
                 && Set(later.map(\.id)) == Set(["onboarding-source-later-dia", "onboarding-source-later-chrome",
                                                 "onboarding-source-later-safari", "onboarding-source-later-firefox"]))
            mark("capture", capture("source"))
            probe.click("onboarding-next")
            browserCheckPhase = 3
        case 3:
            guard let probe = probe(), probe.stage == .whatToImport else { wait("what to import"); return }
            probe.layout()
            let spaces = probe.spaceRows.map(\.text)
            let expected = ["Work Profile University · 6 pinned",
                            "Personal Profile Default · 4 pinned",
                            "Reading Profile Default · 11 pinned"]
            mark("space_rows", spaces == expected)
            let also = probe.alsoRows.map(\.text)
            mark("also_rows", also == ["Favourites", "Looks", "Air Traffic Control routes", "Folder open states"])
            // O4/O5, the site-controls rule: the rows have no producer, so they are absent.
            let all = (spaces + also).joined(separator: " ").lowercased()
            mark("no_signin_rows", !all.contains("sign-in") && !all.contains("password") && !all.contains("archive") && !all.contains("history"))
            mark("capture", capture("what-to-import"))
            probe.click("onboarding-next")
            browserCheckPhase = 4
        case 4:
            guard let probe = probe(), probe.stage == .defaultBrowser else { wait("default browser"); return }
            probe.layout()
            mark("default_browser", probe.title.contains("default browser")
                 && probe.frame("onboarding-set-default") != nil && probe.frame("onboarding-not-now") != nil)
            guard let model = owner.onboardingWindow?.model else { return }
            let calls = model.defaultBrowserCalls
            probe.click("onboarding-set-default")
            mark("setter_called", model.defaultBrowserCalls == calls + 1
                 && owner.onboardingDefaultBrowser?.calls == 1)
            mark("real_default_unchanged", onboardingDefaultHandler() == check.realDefaultBefore)
            browserCheckPhase = 5
        case 5:
            guard let probe = probe(), probe.stage == .progress, let model = owner.onboardingWindow?.model else {
                wait("progress"); return
            }
            probe.layout()
            let steps = probe.progressRows.map(\.text)
            mark("progress_steps", steps == OnboardingModel.progressSteps && steps.count == 3)
            mark("capture", capture("progress"))
            model.beginImport()
            probe.render()
            guard probe.stage == .progress else { wait("progress stage"); return }
            model.performImport()
            probe.render()
            browserCheckPhase = 6
        case 6:
            guard let probe = probe(), probe.stage == .done, let model = owner.onboardingWindow?.model else {
                wait("done"); return
            }
            probe.layout()
            let line = OnboardingFixtureLine(OnboardingFixtures.expected).line
            mark("report_numbers", probe.summaryLine == line
                 && model.summary?.line == line && probe.title == "Your spaces are here")
            // Every row has a producer in the report; the sign-in line and the unread look have
            // none in this fixture and are dropped (D10, O5).
            let ids = probe.reportLines
            mark("report_lines", ids.count == 4
                 && ids.contains { $0.contains("2 folders were peeked") }
                 && ids.contains { $0.contains("2 folders were open in one Arc window") }
                 && ids.contains { $0.contains("1 route sent links to a profile") }
                 && ids.contains { $0.contains("3 custom keyboard shortcuts") })
            mark("no_signin_line", !ids.contains { $0.lowercased().contains("sign-in") })
            // The store the flow wrote is the check's database, and the numbers are this fixture's,
            // so no other store and no other sidebar fed it.
            var reopened = 0
            if let path = quitPath, let store = try? WorkspaceStore.open(path: path) {
                reopened = store.snapshot(windowId: "onboarding-check").spaces.count
            }
            mark("fixture_store_only", model.storePath == quitPath && reopened == OnboardingFixtures.expected.spaces
                 && model.data.sidebar == OnboardingFixtures.showcaseSidebar)
            check.details["summary"] = probe.summaryLine
            check.details["lines"] = ids
            mark("capture", capture("done"))
            // Screen 7: the malformed sidebar. The same window walks the second fixture; its
            // ImportError text is the whole of the screen's detail.
            model.restart()
            model.data = OnboardingFixtures.malformedSidebar
            walkToProgress(model)
            model.performImport()
            probe.render()
            guard case .error(let message) = probe.stage else { wait("error stage"); return }
            check.errorMessage = message
            mark("error_screen", probe.title == "The import stopped")
            mark("error_message", message.contains("sidebar.containers has no container with spaces"))
            check.details["error"] = message
            mark("capture", capture("error"))
            model.copyDetails()
            mark("copy_details", NSPasteboard.general.string(forType: .string) == message)
            // Screen 8: the sibling file. The import finished and the report names the file.
            model.restart()
            model.data = OnboardingFixtures.badKeyBindings
            walkToProgress(model)
            model.performImport()
            probe.render()
            browserCheckPhase = 7
        case 7:
            guard let probe = probe(), case .siblingFile(let message) = probe.stage,
                  let model = owner.onboardingWindow?.model else { wait("sibling-file stage"); return }
            probe.layout()
            mark("sibling_screen", probe.title == "One file could not be read")
            mark("sibling_message", message == "StorableKeyBindings.json: unsupported key bindings version"
                 && probe.warningMessage.contains("unsupported key bindings version"))
            check.details["sibling"] = message
            mark("capture", capture("sibling-file"))
            probe.click("onboarding-continue")
            guard probe.stage == .done else { wait("sibling continue"); return }
            mark("sibling_continue", model.summary?.spaces == OnboardingFixtures.expected.spaces
                 && probe.summaryLine == OnboardingFixtureLine(OnboardingFixtures.expected).line)
            finish()
        default:
            break
        }
    }
}

/// The check's empty command-bar base: the decorator only needs to prove the row it adds.
@MainActor
final class StubCommandStore: CommandBarStore {
    func query(_ text: String, history: [HistoryEntry]) -> CommandBarResult {
        CommandBarResult(rows: [], privateWindow: false)
    }
    func searchURL(_ text: String) -> String { "https://www.google.com/search?q=" }
}

/// The board's six counts as the fixture declares them, so the check has a second, independent
/// statement of F-Import screen 6's line (the first is what the core import produced).
struct OnboardingFixtureLine {
    private let expectation: OnboardingFixtures.Expectation
    init(_ expectation: OnboardingFixtures.Expectation) { self.expectation = expectation }
    var line: String {
        OnboardingSummary(spaces: expectation.spaces, pinnedTabs: expectation.pinnedTabs,
                          folders: expectation.folders, favourites: expectation.favourites,
                          looks: expectation.looks, routes: expectation.routes).line
    }
}
