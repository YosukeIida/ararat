import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

/// U27j's check: the onboarding window opened by the command the File menu and the command bar
/// carry under a check. It walks the eight screens — welcome, source, what to import, default
/// browser, progress, done, the stopped import and the sibling-file warning — through the
/// window's own buttons, captures each, and asserts that the report's numbers are the showcase
/// fixture's (so the import read the injected strings, not the owner's Arc), that the store is the
/// check's `--ararat-db`, that the default browser button went through the fake and the host's
/// handler did not move, and that the sign-in and Passwords rows and line are absent.

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
    /// Every screen the check captures. `capture` is set once at the end from this list (L8).
    static let screens = ["welcome", "source", "what-to-import", "default-browser", "progress", "done", "error", "sibling-file"]

    var values: [String: Bool] = [:]
    var images: [String: String] = [:]
    var capturing = false
    var lastWait = ""
    var details: [String: Any] = [:]
    var realDefaultBefore = ""
    var errorMessage = ""

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
        func wait(_ name: String) {
            if check.lastWait != name {
                check.lastWait = name
                FileHandle.standardError.write(Data("ararat-trace: onboarding wait=\(name) phase=\(browserCheckPhase) window=\(owner.onboardingWindow != nil) stage=\(owner.onboardingWindow.map { String(describing: $0.model.stage) } ?? "nil")\n".utf8))
            }
        }
        func capture(_ name: String) -> Bool {
            guard screen else { return true }
            guard let target = owner.onboardingWindow?.window else { wait("capture \(name): no window"); return false }
            check.capturing = true
            defer { check.capturing = false }
            guard let path = promptScreenScreenshot(target, name: "onboarding-\(name)", withoutShadow: true) else {
                wait("capture \(name)")
                return false
            }
            check.images[name] = path
            return true
        }
        func finish() {
            if screen { check.report("capture", Set(check.images.keys) == Set(OnboardingCheckState.screens)) }
            let result = check.diagnostics(screen: screen)
            finishBrowserCheck(ok: (result["failed_conditions"] as? [String] ?? ["invalid"]).isEmpty, values: result)
        }
        func probe() -> OnboardingCheckProbe? {
            guard let probe = owner.onboardingWindow?.checkProbe() else { wait("onboarding window"); return nil }
            probe.layout()
            return probe
        }
        func mark(_ name: String, _ ok: Bool) { check.report(name, ok) }
        /// The flow's own buttons, so the check proves the window rather than the model.
        func walkToProgressThroughTheWindow(_ model: OnboardingModel, probe: OnboardingCheckProbe) {
            model.restart()
            probe.render()
            _ = probe.click("onboarding-next")        // welcome → source
            _ = probe.click("onboarding-next")        // source → what to import
            _ = probe.click("onboarding-next")        // what to import → default browser
            _ = probe.click("onboarding-not-now")     // default browser → progress; its import is scheduled
        }

        switch browserCheckPhase {
        case 0:
            guard workspace != nil, quitPath != nil else { wait("workspace"); return }
            let menuItem = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.items.first {
                $0.identifier?.rawValue == OnboardingCommandStore.commandID
            }
            mark("entry_menu", menuItem != nil && menuItem?.action == #selector(Runtime.importFromArc(_:)))
            check.realDefaultBefore = onboardingDefaultHandler()
            // The command bar's own path, so removing the decorator line in main.swift fails here.
            openCommandBar(.newTab)
            browserCheckPhase = 1
        case 1:
            guard let presenter = commandPresenter, presenter.controller.isOpen else { wait("command bar"); return }
            presenter.controller.update(query: "import")
            let rows = presenter.controller.result.rows
            guard rows.contains(where: {
                if case .command(let id) = $0.target { return id == OnboardingCommandStore.commandID }
                return false
            }) else {
                wait("command bar row")
                return
            }
            mark("entry_command_bar", rows.contains { $0.title == "Import from Arc…" })
            presenter.close()
            openOnboarding()
            browserCheckPhase = 2
        case 2:
            guard let probe = probe(), probe.stage == .welcome else { wait("welcome"); return }
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
            guard capture("welcome") else { wait("capture welcome"); return }
            probe.click("onboarding-next")
            browserCheckPhase = 3
        case 3:
            guard let probe = probe(), probe.stage == .source else { wait("source"); return }
            let rows = probe.sourceRows
            let arc = rows.first { $0.id == "onboarding-source-arc" }
            mark("source_rows", probe.title == "Bring your browser with you" && arc?.text.contains("3 spaces") == true)
            let later = rows.filter(\.later)
            mark("source_later", later.count == 4 && later.allSatisfy { $0.text.contains("Later") }
                 && Set(later.map(\.id)) == Set(["onboarding-source-later-dia", "onboarding-source-later-chrome",
                                                 "onboarding-source-later-safari", "onboarding-source-later-firefox"]))
            guard capture("source") else { wait("capture source"); return }
            probe.click("onboarding-next")
            browserCheckPhase = 4
        case 4:
            guard let probe = probe(), probe.stage == .whatToImport else { wait("what to import"); return }
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
            guard capture("what-to-import") else { wait("capture what to import"); return }
            probe.click("onboarding-next")
            browserCheckPhase = 5
        case 5:
            guard let probe = probe(), probe.stage == .defaultBrowser else { wait("default browser"); return }
            mark("default_browser", probe.title.contains("default browser")
                 && probe.frame("onboarding-set-default") != nil && probe.frame("onboarding-not-now") != nil)
            guard let model = owner.onboardingWindow?.model else { wait("model"); return }
            guard capture("default-browser") else { wait("capture default browser"); return }
            let calls = model.defaultBrowserCalls
            probe.click("onboarding-set-default")
            mark("setter_called", model.defaultBrowserCalls == calls + 1
                 && owner.onboardingDefaultBrowser?.calls == 1)
            mark("real_default_unchanged", onboardingDefaultHandler() == check.realDefaultBefore)
            // The window moved to screen 5 and the model scheduled the import for the next run-loop
            // turn, so this tick can still read and capture the progress screen.
            guard probe.stage == .progress else { wait("progress after set as default"); return }
            let steps = probe.progressRows.map(\.text)
            mark("progress_steps", steps == OnboardingModel.progressSteps && steps.count == 4)
            guard capture("progress") else { wait("capture progress"); return }
            browserCheckPhase = 6
        case 6:
            guard let probe = probe(), probe.stage == .done, let model = owner.onboardingWindow?.model else {
                wait("done")
                return
            }
            let line = OnboardingFixtureLine(OnboardingFixtures.expected).line
            mark("report_numbers", probe.summaryLine == line
                 && model.summary?.line == line && probe.title == "Your spaces are here")
            // Every row has a producer in the report; the sign-in line and the unread look have
            // none in this fixture and are dropped (D10, O5).
            let texts = probe.reportLines
            mark("report_lines", texts.count == 4
                 && texts.contains { $0.contains("2 folders were peeked") }
                 && texts.contains { $0.contains("2 folders were open in one Arc window") }
                 && texts.contains { $0.contains("1 route sent links to a profile") }
                 && texts.contains { $0.contains("3 custom keyboard shortcuts") })
            mark("no_signin_line", !texts.contains { $0.lowercased().contains("sign-in") })
            // The store the flow wrote is the check's database and its fixture's spaces are in it.
            // The store may hold the empty-check space EngineAdapter makes before the window opens:
            // the imported counts come from the report, not from this reopen (H1).
            var titles = Set<String>()
            if let path = quitPath, let store = try? WorkspaceStore.open(path: path) {
                titles = Set(store.snapshot(windowId: "onboarding-check").spaces.map(\.title))
            }
            mark("fixture_store_only", model.storePath == quitPath
                 && Set(["Work", "Personal", "Reading"]).isSubset(of: titles)
                 && model.data.sidebar == OnboardingFixtures.showcaseSidebar)
            check.details["summary"] = probe.summaryLine
            check.details["lines"] = texts
            check.details["store_titles"] = titles.sorted()
            guard capture("done") else { wait("capture done"); return }
            // Screen 7: the malformed sidebar, walked through the window with "Not Now".
            model.data = OnboardingFixtures.malformedSidebar
            walkToProgressThroughTheWindow(model, probe: probe)
            browserCheckPhase = 7
        case 7:
            guard let probe = probe(), let model = owner.onboardingWindow?.model else { wait("error model"); return }
            guard case .error(let message) = probe.stage else { wait("error stage"); return }
            check.errorMessage = message
            mark("error_screen", probe.title == "The import stopped")
            mark("error_message", message.contains("sidebar.containers has no container with spaces"))
            check.details["error"] = message
            guard capture("error") else { wait("capture error"); return }
            model.copyDetails()
            mark("copy_details", NSPasteboard.general.string(forType: .string) == message)
            // Screen 8: the sibling file, through the window's "Not Now" again.
            model.data = OnboardingFixtures.badKeyBindings
            walkToProgressThroughTheWindow(model, probe: probe)
            browserCheckPhase = 8
        case 8:
            guard let probe = probe(), let model = owner.onboardingWindow?.model else { wait("sibling model"); return }
            guard case .siblingFile(let message) = probe.stage else { wait("sibling-file stage"); return }
            mark("sibling_screen", probe.title == "One file could not be read")
            mark("sibling_message", message == "StorableKeyBindings.json: unsupported key bindings version"
                 && probe.warningMessage.contains("unsupported key bindings version"))
            check.details["sibling"] = message
            guard capture("sibling-file") else { wait("capture sibling"); return }
            probe.click("onboarding-continue")
            browserCheckPhase = 9
        case 9:
            guard let probe = probe(), let model = owner.onboardingWindow?.model else { wait("sibling continue"); return }
            guard probe.stage == .done else { wait("sibling continue stage"); return }
            mark("sibling_continue", model.summary?.spaces == OnboardingFixtures.expected.spaces
                 && probe.summaryLine == OnboardingFixtureLine(OnboardingFixtures.expected).line)
            finish()
        default:
            break
        }
    }
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
