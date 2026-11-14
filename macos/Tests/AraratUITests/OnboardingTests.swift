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

@MainActor
private func runImport(_ model: OnboardingModel) {
    model.advance()   // welcome → source
    model.advance()   // source → what to import
    model.advance()   // what to import → default browser
    model.notNow()    // default browser → progress
    model.beginImport()
    model.performImport()
}

final class FakeSetter: DefaultBrowserSetter {
    private(set) var calls = 0
    func requestDefaultBrowser() { calls += 1 }
}

/// F-Import screen 6's numbers are the fixture's: five counts from the imported snapshot and the
/// routes from the report. The summary text is the board's line.
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
                             unknownWindowIds: 0, malformedWindowEntries: 0)
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
/// summarised, and the message is the only detail.
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

/// Screens 1–5 and the back path: each step is the board's order and the progress screen's rows are
/// the steps the one synchronous call runs.
@Test @MainActor
func theFlowWalksTheBoardsScreensInOrder() throws {
    let (model, directory) = try onboardingTestModel()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(model.stage == .welcome)
    model.advance(); #expect(model.stage == .source)
    model.advance(); #expect(model.stage == .whatToImport)
    model.goBack(); #expect(model.stage == .source)
    model.goBack(); #expect(model.stage == .welcome)
    model.advance(); model.advance(); model.advance()
    #expect(model.stage == .defaultBrowser)
    model.advance(); #expect(model.stage == .progress)
    #expect(OnboardingModel.progressSteps == ["Spaces, tabs and folders", "Looks", "Air Traffic Control routes"])
    // The dots mark the five screens that have them; the done and error screens draw none.
    #expect(model.dotIndex == 4)
    model.beginImport()
    model.performImport()
    #expect(model.dotIndex == nil)
    // A second run over the same store is the core's idempotent override path.
    model.restart()
    runImport(model)
    #expect(model.summary?.spaces == 3)
    #expect(model.importCount == 2)
}

/// O7: the command bar row is the app's, not the core table's, so a shipping build can hide it.
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
}

@MainActor
private final class StubStore: CommandBarStore {
    func query(_ text: String, history: [HistoryEntry]) -> CommandBarResult {
        CommandBarResult(rows: [], privateWindow: false)
    }
    func searchURL(_ text: String) -> String { "https://www.google.com/search?q=" }
}
