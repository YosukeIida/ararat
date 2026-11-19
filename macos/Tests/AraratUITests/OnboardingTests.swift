import AppKit
import AraratKit
import Testing
@testable import AraratUI

// U27j: the onboarding model. The fixture's numbers must be what the core import produces, the
// report's lines must come from its counters, the two error screens from its two kinds of error,
// and the default-browser button from the injected setter.

@MainActor
private func onboardingTestModel(_ data: OnboardingData = OnboardingFixtures.showcase,
                                 setter: DefaultBrowserSetter = FakeSetter()) throws -> (OnboardingModel, URL) {
    let directory = try testTemporaryDirectory()
    let model = OnboardingModel(storePath: directory.appendingPathComponent("onboarding.sqlite").path,
                                data: data, detector: OnboardingFixtures.FixtureSourceDetector(),
                                defaultBrowser: setter)
    return (model, directory)
}

/// Walks screens 1–4 through the model's own steps, then lets the run loop turn so the import the
/// progress screen scheduled runs; the caller never calls the import.
@MainActor
private func runImport(_ model: OnboardingModel) {
    model.advance()   // welcome → source
    model.advance()   // source → what to import
    model.advance()   // what to import → default browser
    model.notNow()    // default browser → progress; the import is scheduled
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
}

final class FakeSetter: DefaultBrowserSetter {
    private(set) var calls = 0
    func requestDefaultBrowser() { calls += 1 }
}

@Test @MainActor
func theDefaultBrowserSetterRequestsHTTPExactlyOnce() {
    var apps: [URL] = []
    var schemes: [String] = []
    let setter = LaunchServicesDefaultBrowser(setDefaultApplication: { app, scheme, completion in
        apps.append(app)
        schemes.append(scheme)
        completion(nil)
    })

    setter.requestDefaultBrowser()

    #expect(apps == [Bundle.main.bundleURL])
    #expect(schemes == ["http"])
}

/// F-Import screen 6's numbers are the fixture's: the report counts what the import produced, not
/// the store's totals. The summary text is the board's line.
@Test @MainActor
func theShowcaseFixtureImportsTheBoardsNumbers() throws {
    let (model, directory) = try onboardingTestModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    runImport(model)
    let expectation = OnboardingFixtures.expected
    let summary = try #require(model.summary)
    #expect(summary.spaces == expectation.spaces)
    #expect(summary.pinnedTabs == expectation.pinnedTabs)
    #expect(summary.folders == expectation.folders)
    #expect(summary.favourites == expectation.favourites)
    #expect(summary.looks == expectation.looks)
    #expect(summary.routes == expectation.routes)
    #expect(summary.line == "3 spaces · 21 pinned tabs · 5 folders · 8 favourites · 3 looks · 6 routes")
    #expect(model.stage == .done)
    // The report's own counters are the fixture's too.
    let report = try #require(model.report)
    #expect(Int(report.peekedFolders) == expectation.peekedFolders)
    #expect(Int(report.differingFolderStates) == expectation.differingFolderStates)
    #expect(Int(report.skippedKeyBindings) == expectation.skippedKeyBindings)
    #expect(Int(report.skippedProfileDestinations) == expectation.skippedProfileDestinations)
    #expect(report.windowsError == nil && report.keyBindingsError == nil && report.linkRoutingError == nil)
}

/// A store that already held a space does not change the done line, and the check's store
/// keeps both spaces — the report counts the import, never the store.
@Test @MainActor
func theDoneLineCountsOnlyWhatTheImportBrought() throws {
    let (model, directory) = try onboardingTestModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    let before = try WorkspaceStore.open(path: model.storePath)
    _ = try before.createSpace(windowId: "before", name: "Before the import", spaceId: "before-space")
    runImport(model)
    #expect(model.summary?.line == "3 spaces · 21 pinned tabs · 5 folders · 8 favourites · 3 looks · 6 routes")
    let reopened = try WorkspaceStore.open(path: model.storePath)
    let titles = Set(reopened.snapshot(windowId: "after").spaces.map(\.title))
    #expect(titles == Set(["Before the import", "Work", "Personal", "Reading"]))
}

/// The progress screen hands the import to the injected scheduler, so a caller can
/// draw (and screenshot) the progress screen before the import runs. The default scheduler is the
/// next main run-loop turn.
@Test @MainActor
func theProgressImportWaitsForTheScheduler() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var held: (@MainActor () -> Void)?
    let model = OnboardingModel(storePath: directory.appendingPathComponent("held.sqlite").path,
                                data: OnboardingFixtures.showcase,
                                detector: OnboardingFixtures.FixtureSourceDetector(),
                                defaultBrowser: FakeSetter(), schedule: { held = $0 })
    model.advance(); model.advance(); model.advance()
    model.notNow()
    #expect(model.stage == .progress)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    #expect(model.stage == .progress && model.summary == nil)
    let block = try #require(held)
    block()
    #expect(model.stage == .done)
    #expect(model.summary?.spaces == 3)
}

/// The progress screen draws one row per step, named exactly as the model's step list, in order;
/// the probe's read is the text the VM check compares.
@Test @MainActor
func theProgressScreenDrawsTheFourStepsAsTheirNames() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = OnboardingModel(storePath: directory.appendingPathComponent("rows.sqlite").path,
                                data: OnboardingFixtures.showcase,
                                detector: OnboardingFixtures.FixtureSourceDetector(),
                                defaultBrowser: FakeSetter(), schedule: { _ in })
    let controller = OnboardingWindowController(model: model)
    controller.checkRender()
    model.advance(); model.advance(); model.advance()
    model.notNow()
    controller.checkRender()
    let probe = try #require(controller.checkProbe())
    probe.layout()
    #expect(probe.progressRows.map(\.text) == OnboardingModel.progressSteps)
}

/// The store the flow wrote is the one it was given: a fresh open at the same path reads the three
/// spaces back, so a check's `--ararat-db` is the destination and nothing else is.
@Test @MainActor
func theImportWritesTheStoreAtTheGivenPath() throws {
    let (model, directory) = try onboardingTestModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    runImport(model)
    #expect(model.storePath == directory.appendingPathComponent("onboarding.sqlite").path)
    let reopened = try WorkspaceStore.open(path: model.storePath)
    let snapshot = reopened.snapshot(windowId: "onboarding-test")
    #expect(snapshot.spaces.map(\.title) == ["Work", "Personal", "Reading"])
    #expect(snapshot.spaces.map(\.profileName) == ["University", "Default", "Default"])
}

/// The done screen's report lines stay inside the card and each row is the height its text needs:
/// 31 pt for one line and 48 for two, as F-Import's "Imported differently" card draws them.
@Test @MainActor
func theCompletionReportRowsWrapInsideTheCardAndSizeToTheirText() throws {
    let (model, directory) = try onboardingTestModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    runImport(model)
    let controller = OnboardingWindowController(model: model)
    controller.checkRender()
    let probe = try #require(controller.checkProbe())
    probe.render()
    probe.layout()
    #expect(!model.lines.isEmpty)
    var frames: [(row: NSRect, title: NSRect)] = []
    for line in model.lines {
        let rowID = "onboarding-line-\(line.id)"
        let row = try #require(probe.frame(rowID))
        let title = try #require(probe.titleFrame(of: rowID))
        // The drawn label, not a string measurement, says how many lines it took.
        let wraps = title.height > 17
        #expect(abs(title.width - (row.width - 32)) <= 1)
        #expect(title.maxX <= row.maxX - 15, "the line stops inside the card: \(title) in \(row)")
        #expect(abs(title.minX - (row.minX + 16)) <= 1)
        #expect(abs(title.minY - (row.minY + 7)) <= 1, "the text starts at the board's 7 pt padding")
        // The row and the label are the board's heights for the line count the text needs.
        #expect(abs(row.height - (wraps ? OnboardingRowView.twoLineHeight : OnboardingRowView.oneLineHeight)) <= 1,
                "\(line.id): \(row.height) for \(wraps ? 2 : 1) line(s)")
        #expect(abs(title.height - (wraps ? 34 : 17)) <= 1)
        frames.append((row, title))
    }
    // The rows share edges inside the card, so no gap and no overlap is left between them.
    #expect(zip(frames, frames.dropFirst()).allSatisfy { abs($0.row.maxY - $1.row.minY) <= 1 })
    let longest = try #require(model.lines.max { $0.text.count < $1.text.count })
    let longestIndex = try #require(model.lines.firstIndex { $0.id == longest.id })
    #expect(frames[longestIndex].row.height == OnboardingRowView.twoLineHeight, "the longest line wraps onto a second line")
    #expect(frames.contains { $0.row.height == OnboardingRowView.oneLineHeight }, "a short line keeps the one-line row")
}

/// A row whose string just fits its label still wraps, because the cell breaks earlier than the
/// string's own width: the row height has to come from the cell, or the second line is clipped.
@Test @MainActor
func aReportRowAtTheCellsWrapPointTakesTheTwoLineHeight() throws {
    _ = NSApplication.shared
    let text = "2 folders were open in one Arc window and closed in another. Here they follow the first window."
    let stringWidth = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
    var wrapped = 0
    for extra in stride(from: CGFloat(0), through: 4, by: 0.5) {
        let fieldWidth = stringWidth + extra
        let row = OnboardingRowView(id: "band", title: text, subtitle: "", dimmed: false, wraps: true)
        let rowWidth = fieldWidth + 32
        row.frame = NSRect(x: 0, y: 0, width: rowWidth, height: row.height(forWidth: rowWidth))
        row.layoutSubtreeIfNeeded()
        let field = try #require(row.subviews.compactMap { $0 as? NSTextField }.first)
        // The cell's own answer for this width is the independent measure the row must follow.
        let cellHeight = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: fieldWidth,
                                                               height: .greatestFiniteMagnitude)).height ?? 0
        let wraps = cellHeight > 17
        if wraps { wrapped += 1 }
        #expect(abs(row.bounds.height - (wraps ? OnboardingRowView.twoLineHeight : OnboardingRowView.oneLineHeight)) <= 1,
                "extra \(extra): row \(row.bounds.height), cell \(cellHeight)")
        #expect(abs(field.frame.height - (wraps ? 34 : 17)) <= 1, "extra \(extra): field \(field.frame.height)")
        #expect(field.frame.maxY <= row.bounds.maxY - 7 + 1, "extra \(extra): the field stays inside the row")
    }
    // The band exists: inside the first 4 pt past the string's width the cell already wraps.
    #expect(wrapped > 0)
}

/// The done screen's rows each have a producer: the showcase fixture produces exactly four, the
/// sign-in line (O5) and the unread-look line (no unknown look here) are dropped.
@Test @MainActor
func theReportLinesComeOnlyFromTheReportsCounters() throws {
    let (model, directory) = try onboardingTestModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    runImport(model)
    let texts = model.lines.map(\.text)
    #expect(texts == [
        "2 folders were peeked in Arc. They are closed here.",
        "2 folders were open in one Arc window and closed in another. Here they follow the first window.",
        "1 route sent links to a profile. It was skipped.",
        "3 custom keyboard shortcuts were not imported.",
    ])
    #expect(!texts.contains { $0.lowercased().contains("sign-in") })
    #expect(!texts.contains { $0.lowercased().contains("password") })
    // A zero counter draws no row, and every counter has its own wording.
    let empty = ImportReport(missingLinkRouting: false, linkRoutingError: nil, importedRules: 0,
                             skippedProfileDestinations: 0, skippedUnknownDestinations: 0,
                             skippedUnknownStyles: 0, malformedRules: 0,
                             missingKeyBindings: false, keyBindingsError: nil, skippedKeyBindings: 0,
                             unknownSpaceLooks: 0, missingWindows: false, windowsError: nil,
                             differingFolderStates: 0, skippedDates: 0, peekedFolders: 0,
                             unknownWindowIds: 0, malformedWindowEntries: 0,
                             spaces: 0, pinnedTabs: 0, folders: 0, favouriteTabs: 0, spacesWithLook: 0)
    #expect(OnboardingModel.reportLines(empty).isEmpty)
}

/// Screen 3: the fixture's spaces with their profiles and pinned counts, and the Also list is only
/// what the core importer carries.
@Test @MainActor
func theImportScreenListsTheFixturesSpacesAndWhatTheImporterCarries() throws {
    let (model, directory) = try onboardingTestModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(model.spaceRows.map { "\($0.title) · \($0.profileName) · \($0.pinnedCount)" }
            == ["Work · University · 6", "Personal · Default · 4", "Reading · Default · 11"])
    #expect(model.alsoRows == ["Favourites", "Looks", "Air Traffic Control routes", "Folder open states"])
    // The fixture says Arc is installed; the source screen counts its spaces.
    #expect(model.arcInstalled)
    #expect(model.arcSpaceCount == 3)
    #expect(model.laterBrowsers == ["Dia", "Chrome", "Safari", "Firefox"])
}

/// Screen 7: a malformed sidebar stops the import with `ImportError`'s own message; nothing is
/// summarised, and the message is the only detail. "Try Again" runs the same walk again.
@Test @MainActor
func aMalformedSidebarLandsOnTheStoppedImportScreen() throws {
    let (model, directory) = try onboardingTestModel(OnboardingFixtures.malformedSidebar)
    defer { try? FileManager.default.removeItem(at: directory) }
    runImport(model)
    guard case .error(let message) = model.stage else {
        Issue.record("expected the error stage, got \(model.stage)")
        return
    }
    #expect(message == "sidebar.containers has no container with spaces")
    #expect(model.summary == nil && model.lines.isEmpty)
    model.retry()
    #expect(model.stage == .progress)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    guard case .error(let again) = model.stage else {
        Issue.record("expected the error stage again, got \(model.stage)")
        return
    }
    #expect(again == message)
}

/// Screen 8: the sidebar imports and the sibling file's error is a report field; the screen names
/// the field, and Continue reaches the done screen with the counts.
@Test @MainActor
func aSiblingFileErrorLandsOnTheWarningScreen() throws {
    let (model, directory) = try onboardingTestModel(OnboardingFixtures.badKeyBindings)
    defer { try? FileManager.default.removeItem(at: directory) }
    runImport(model)
    guard case .siblingFile(let message) = model.stage else {
        Issue.record("expected the sibling-file stage, got \(model.stage)")
        return
    }
    #expect(message == "StorableKeyBindings.json: unsupported key bindings version")
    #expect(model.summary?.spaces == 3)
    model.continueAfterSiblingWarning()
    #expect(model.stage == .done)
}

/// Screen 4: the button calls the injected setter once and moves on; "Not Now" never calls it.
@Test @MainActor
func theDefaultBrowserButtonUsesTheInjectedSetter() throws {
    let setter = FakeSetter()
    let (model, directory) = try onboardingTestModel(setter: setter)
    defer { try? FileManager.default.removeItem(at: directory) }
    model.advance(); model.advance(); model.advance()
    #expect(model.stage == .defaultBrowser)
    model.notNow()
    #expect(setter.calls == 0 && model.stage == .progress)
    model.restart()
    model.advance(); model.advance(); model.advance()
    model.setAsDefault()
    #expect(setter.calls == 1 && model.defaultBrowserCalls == 1 && model.stage == .progress)
}

/// Screens 1–5 walk in the board's order, back works, and screen 5 runs the import itself on
/// the next run-loop turn — no caller reaches into the model.
@Test @MainActor
func theFlowWalksTheBoardsScreensAndTheProgressScreenRunsTheImport() throws {
    let (model, directory) = try onboardingTestModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(model.stage == .welcome)
    model.advance(); #expect(model.stage == .source)
    model.advance(); #expect(model.stage == .whatToImport)
    model.goBack(); #expect(model.stage == .source)
    model.goBack(); #expect(model.stage == .welcome)
    model.advance(); model.advance(); model.advance()
    #expect(model.stage == .defaultBrowser)
    model.advance()
    #expect(model.stage == .progress)
    #expect(model.dotIndex == 4)
    #expect(model.summary == nil)
    // Nothing else calls the import: the progress screen scheduled it.
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    #expect(model.stage == .done)
    #expect(model.summary?.spaces == 3)
    #expect(model.dotIndex == nil)
    // A second run over the same store is the core's idempotent override path.
    model.restart()
    runImport(model)
    #expect(model.summary?.spaces == 3)
}

/// O7: the command bar row is the app's, not the core table's, so a shipping build can hide it.
/// Its matcher is the core's (title prefix or word prefix), not a substring.
@Test @MainActor
func theCommandBarRowMatchesItsWordsAndOnlyCarriesTheCommand() {
    let store = OnboardingCommandStore(base: StubStore())
    #expect(OnboardingCommandStore.commandID == "import_from_arc")
    for query in ["import", "arc", "from", "Import from Arc…"] {
        let rows = store.query(query, history: []).rows
        #expect(rows.count == 1)
        #expect(rows.first?.title == "Import from Arc…")
        if case .command(let id)? = rows.first?.target { #expect(id == "import_from_arc") }
        else { Issue.record("row is not the command") }
    }
    #expect(store.query("settings", history: []).rows.isEmpty)
    #expect(store.query("", history: []).rows.isEmpty)
    // A substring the core would not match stays out.
    #expect(store.query("rom", history: []).rows.isEmpty)
    #expect(store.query("port", history: []).rows.isEmpty)
}

@MainActor
private final class StubStore: CommandBarStore {
    func query(_ text: String, history: [HistoryEntry]) -> CommandBarResult {
        CommandBarResult(rows: [], privateWindow: false)
    }
    func searchURL(_ text: String) -> String { "https://www.google.com/search?q=" }
}
