import AppKit
import AraratKit
import AraratUI
import Testing
@testable import Ararat

private final class ArcImportDetector: OnboardingSourceDetector {
    let installed: Bool
    private(set) var lookups = 0

    init(installed: Bool) { self.installed = installed }

    func isArcInstalled() -> Bool {
        lookups += 1
        return installed
    }
}

@Test @MainActor
func arcImportEntryChecksForArcOnlyOutsideCheckMode() {
    let absent = ArcImportDetector(installed: false)
    #expect(Runtime.onboardingEntryVisible(checkMode: true, detector: absent))
    #expect(absent.lookups == 0)
    #expect(!Runtime.onboardingEntryVisible(checkMode: false, detector: absent))
    let installed = ArcImportDetector(installed: true)
    #expect(Runtime.onboardingEntryVisible(checkMode: false, detector: installed))
}

@Test @MainActor
func arcImportRetryLoadsFromDiskAndPublishesIntoTheOpenSidebar() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    let runtime = Runtime(windowID: "arc-import")
    let path = directory.appendingPathComponent("workspace.sqlite").path
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: path, windowID: runtime.windowID, card: NSView(), session: session)
    defer { engine.shutdown() }
    runtime.quitPath = path
    runtime.adapter = engine
    runtime.workspace = WorkspaceAdapter(windowID: runtime.windowID, session: session)
    let initial = try session.queue.sync { try #require(session.store).snapshot(windowId: runtime.windowID) }
    let sidebar = SidebarView(snapshot: initial)
    runtime.sidebar = sidebar
    runtime.show(initial)
    engine.onSnapshot = { [weak runtime] in runtime?.show($0) }

    let detector = ArcImportDetector(installed: true)
    let model = try #require(runtime.arcImportModel(directory: directory, detector: detector))
    let controller = OnboardingWindowController(model: model)
    func begin(_ controller: OnboardingWindowController) {
        for id in ["onboarding-next", "onboarding-next", "onboarding-next", "onboarding-not-now"] {
            #expect(controller.checkClick(id))
        }
    }
    func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    begin(controller)
    try await waitFor { model.stage != .progress }
    #expect(model.stage == .error("StorableSidebar.json was not found."))
    #expect(runtime.snapshot.spaces == initial.spaces)

    let file = directory.appendingPathComponent("StorableSidebar.json")
    try "{".write(to: file, atomically: true, encoding: .utf8)
    #expect(controller.checkClick("onboarding-retry"))
    try await waitFor { model.stage != .progress }
    guard case .error(let reason) = model.stage else {
        Issue.record("Invalid JSON did not stop import")
        return
    }
    #expect(reason.hasPrefix("StorableSidebar.json: "))
    #expect(runtime.snapshot.spaces == initial.spaces)

    try OnboardingFixtures.showcaseSidebar.write(to: file, atomically: true, encoding: .utf8)
    #expect(controller.checkClick("onboarding-retry"))
    try await waitFor { model.stage == .done && sidebar.checkDockShowsSpace("space-work") }
    #expect(model.summary?.spaces == 3)
    #expect(model.report?.missingWindows == true)
    #expect(model.passwordProfileNames.isEmpty)
    #expect(runtime.snapshot.spaces.first { $0.id == "space-work" }?.profileName == "University")
    #expect(runtime.snapshot.spaces.count == initial.spaces.count + 3)
    #expect(sidebar.checkDockShowsSpace("space-work"))

    let second = try #require(runtime.arcImportModel(directory: directory, detector: detector))
    begin(OnboardingWindowController(model: second))
    try await waitFor { second.stage == .done }
    #expect(second.summary?.spaces == 3)
    let storedIDs = try session.queue.sync {
        try #require(session.store).snapshot(windowId: runtime.windowID).spaces.map(\.id)
    }
    #expect(storedIDs.count == initial.spaces.count + 3)
    #expect(Set(storedIDs) == Set(initial.spaces.map(\.id) + ["space-work", "space-personal", "space-reading"]))
}
