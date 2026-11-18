import AppKit
import AraratKit
import AraratUI
import Testing
@testable import Ararat

@Test
func incognitoBaselineWaitsForStoredSeedMetadata() {
    let body = #"{"kind":{"Tab":{"url":"about:blank","saved_title":"about:blank"}}}"#
    let ready = [["item", "seed", body]]
    #expect(checkStoredTabMetadata(ready, item: "seed", url: "about:blank", title: "about:blank"))
    #expect(!checkStoredTabMetadata(ready, item: "other", url: "about:blank", title: "about:blank"))
    #expect(!checkStoredTabMetadata(ready, item: "seed", url: "about:blank", title: ""))
    #expect(!checkStoredTabMetadata(ready, item: "seed", url: "other", title: "about:blank"))
    #expect(!checkStoredTabMetadata([["item", "seed", #"{"kind":{"Tab":{"url":"about:blank","saved_title":null}}}"#]], item: "seed", url: "about:blank", title: "about:blank"))
    #expect(!checkStoredTabMetadata([["item", "seed", "invalid"]], item: "seed", url: "about:blank", title: "about:blank"))
}

@Test
func teardownDeadlineRejectsLateCompletion() {
    let onTime = TeardownDeadline()
    onTime.start(seconds: 30)
    #expect(onTime.finish())

    let late = TeardownDeadline()
    late.start(seconds: 0)
    #expect(!late.finish())
}

@MainActor
private func splitValue<T: Sendable>(_ start: (@escaping WorkspaceAdapter.Completion<T>) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in start { continuation.resume(with: $0) } }
}

@Test @MainActor
func organizeSeedKeepsTheFirstFavoriteInASeparateProfile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    _ = try EngineAdapter(path: directory.appendingPathComponent("workspace.sqlite").path, windowID: "organize", card: NSView(), seedOrganize: true, session: session)
    let snapshot = try session.queue.sync { try #require(session.store).snapshot(windowId: "organize") }
    let work = try #require(snapshot.spaces.first { $0.id == "organize-work" })
    let other = try #require(snapshot.spaces.first { $0.id == "organize-other" })
    let first = try #require(snapshot.spaces.first { $0.id == "organize-first" })
    #expect(snapshot.spaces.count == 3)
    #expect(work.profileKey == other.profileKey && snapshot.shownSpaceId == work.id)
    #expect(other.favoritesId == work.favoritesId && work.favoritesId != nil)
    #expect(first.profileKey != work.profileKey && first.favoritesId == nil && first.favorites.isEmpty)
    #expect(first.today.count == 1 && first.today.first?.url == "about:blank?organize-first")
    #expect(work.favorites.count == 2 && work.today.count == 1 && work.pinnedCount == 5)
    #expect(work.pinned.first { $0.id == "organize-inner" }?.collapsed == true)
}

@Test @MainActor
func dialogsSeedUsesTheShownProfilesTab() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    _ = try EngineAdapter(path: directory.appendingPathComponent("workspace.sqlite").path, windowID: "dialogs", card: NSView(), seedProfiles: true, seedSplitCheck: true, session: session)
    try session.queue.sync {
        let store = try #require(session.store)
        let initial = store.snapshot(windowId: "dialogs")
        let defaultRow = try #require(initial.spaces.first(where: { $0.id == "default" })?.today.first)
        #expect(initial.shownSpaceId == "default")
        #expect(defaultRow.url == "about:blank")
        #expect(Runtime.dialogSeedRows(initial).map(\.id) == [defaultRow.id])
        try store.showSpace(windowId: "dialogs", spaceId: "named")
        let named = store.snapshot(windowId: "dialogs")
        #expect(Runtime.dialogSeedRows(named).map(\.id) == named.spaces.first(where: { $0.id == "named" })?.today.map(\.id))
    }
}

@Test @MainActor
func splitMemberCanBeSelectedInDestination() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    _ = try EngineAdapter(path: directory.appendingPathComponent("workspace.sqlite").path, windowID: "source", card: NSView(), seedProfiles: true, seedSplitCheck: true, session: session)
    try session.queue.sync { try #require(session.store).showSpace(windowId: "destination", spaceId: "named") }
    let workspace = WorkspaceAdapter(windowID: "destination", session: session)
    let selected = try await splitValue { workspace.select(id: "close-split-b", completion: $0) }
    #expect(selected.shownSpaceId == "named")
    #expect(selected.selectedId == "close-split-b")
    #expect(selected.spaces.first(where: { $0.id == "named" })?.pinned.contains(where: { $0.id == selected.selectedId }) == true)
    #expect(session.queue.sync { session.store?.splitLayout(itemId: "close-split-b") } != nil)
}

@Test @MainActor
func checkSeedSelectionCommitsTheRequestedVisibleRow() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: directory.appendingPathComponent("workspace.sqlite").path, windowID: "check-seed", card: NSView(), seedProfiles: true, session: session)
    let workspace = WorkspaceAdapter(windowID: "check-seed", session: engine.session)
    let before = try await splitValue { workspace.snapshot(completion: $0) }
    let row = try #require(before.spaces.first(where: { $0.id == "default" })?.today.first)
    let other = try await splitValue { workspace.createTab(url: "about:blank?other", completion: $0) }.snapshot
    #expect(other.selectedId != row.id)
    #expect(!Runtime.checkSeedSelectionMatches(other, item: row.id, space: "default"))
    let selected = try await splitValue { workspace.select(id: row.id, completion: $0) }
    #expect(Runtime.checkSeedSelectionMatches(selected, item: row.id, space: "default"))
    #expect(!Runtime.checkSeedSelectionMatches(selected, item: row.id, space: "named"))
    #expect(!Runtime.checkSeedSelectionMatches(selected, item: "missing", space: "default"))
    #expect(try await splitValue { workspace.snapshot(completion: $0) }.selectedId == row.id)
}

@Test @MainActor
func multipleQuitUsesCapturedSeedWithCombinedProfileAndSingleCheck() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    _ = try EngineAdapter(path: directory.appendingPathComponent("workspace.sqlite").path, windowID: "root", card: NSView(), seedSingleCheck: true, seedProfiles: true, session: session)
    let (snapshot, first, named, child, second, old) = try session.queue.sync { () -> (WorkspaceSnapshot, String, String, String, String, String) in
        let store = try #require(session.store)
        let seeded = store.snapshot(windowId: "root")
        let defaultRows = try #require(seeded.spaces.first(where: { $0.id == "default" })).today
        let first = try #require(defaultRows.first).id
        let old = try #require(defaultRows.first(where: { $0.url == "about:blank" })).id
        let named = try #require(seeded.spaces.first(where: { $0.id == "named" })?.today.first).id
        #expect(defaultRows.first?.url == "data:text/html,<title>Ararat One</title>")
        try store.showSpace(windowId: "child", spaceId: "default")
        let child = try #require(try store.createTab(windowId: "child", url: "about:blank?unrelated").selectedId)
        let second = try #require(try store.createTab(windowId: "root", url: "about:blank?multiple").selectedId)
        return (store.snapshot(windowId: "root"), first, named, child, second, old)
    }
    let tabs: [(item: String?, live: String, loading: Bool)] = [(first, "l1", false), (second, "l2", false), (named, "l3", false)]
    let mappings = [first: "l1", second: "l2", named: "l3", child: "lc"]
    let reverse = ["l1": first, "l2": second, "l3": named, "lc": child]
    let profiles = [first: "Default", second: "Default", named: "Profile 1", child: "Default"]
    func check(_ actual: [(item: String?, live: String, loading: Bool)] = tabs,
               expected: [String: String]? = nil, actualMappings: [String: String]? = nil,
               actualReverse: [String: String]? = nil, actualProfiles: [String: String]? = nil,
               childItem: String? = nil, childLive: String = "lc") -> [String]? {
        Runtime.multipleQuitSetupItems(snapshot: snapshot, expected: expected ?? ["Default": first, "Profile 1": named],
          rootTabs: actual, childItem: childItem ?? child, childLive: childLive, mappings: actualMappings ?? mappings,
          reverse: actualReverse ?? reverse, profiles: actualProfiles ?? profiles)
    }
    #expect(check() == [first, second])
    #expect(!tabs.contains(where: { $0.item == old }))
    #expect(check(expected: ["Default": old, "Profile 1": named]) == nil)
    #expect(check(Array(tabs.dropLast())) == nil)
    #expect(check(tabs + [("unexpected", "extra", false)]) == nil)
    #expect(check([(child, "lc", false), (second, "l2", false), (named, "l3", false)]) == nil)
    #expect(check([(first, "l1", false), (first, "l2", false), (named, "l3", false)]) == nil)
    #expect(check([(first, "l1", true), (second, "l2", false), (named, "l3", false)]) == nil)
    #expect(check(actualMappings: [first: "other", second: "l2", named: "l3", child: "lc"]) == nil)
    #expect(check(actualReverse: ["l1": first, "l2": second, "l3": named, "lc": first]) == nil)
    #expect(check(actualProfiles: [first: "Profile 1", second: "Default", named: "Profile 1", child: "Default"]) == nil)
    #expect(check(actualProfiles: [first: "Default", second: "Default", named: "Default", child: "Default"]) == nil)
    #expect(check(childItem: first) == nil)
    #expect(check(childLive: "l1") == nil)
    let runtime = Runtime(windowID: "root")
    runtime.multiCloseDefaultItems = Set(try #require(check()))
    runtime.splitCloseExpected = ["Default": first, "Profile 1": named]
    let pages: [[String: Any]] = [["profile": "Default", "item": first, "active": true, "presented": true],
      ["profile": "Default", "item": second, "active": true, "presented": true],
      ["profile": "Profile 1", "item": named, "active": true, "presented": true]]
    #expect(runtime.multipleClosePagesValid(pages, defaultCount: 2, namedCount: 1))
    #expect(!runtime.multipleClosePagesValid([pages[0], pages[0], pages[2]], defaultCount: 2, namedCount: 1))
}

@Test @MainActor
func matrixCompletionRequiresAppliedMatchingCommandAndIdentity() {
    let target = Runtime.MatrixTarget(space: "named", item: "item", profile: "Profile 1", url: "about:blank")
    let tab = LiveTab(offTheRecord: false, profile: .named("Profile 1"), liveId: "live", item: "item", opener: nil, navigated: false, url: nil, title: nil)
    let transaction = LiveTransaction(offTheRecord: false, epoch: 1, rev: 1, cause: .command("command"),
        strips: [LiveStrip(window: "window", tabs: [tab], active: "live")])
    #expect(Runtime.matrixAcceptedLive(transaction, applied: false, command: "command", window: "window", target: target) == nil)
    #expect(Runtime.matrixAcceptedLive(transaction, applied: true, command: "other", window: "window", target: target) == nil)
    #expect(Runtime.matrixAcceptedLive(transaction, applied: true, command: "command", window: "other", target: target) == nil)
    #expect(Runtime.matrixAcceptedLive(transaction, applied: true, command: "command", window: "window", target: target) == "live")
    var wrong = transaction
    wrong.strips[0].tabs[0].profile = .default
    #expect(Runtime.matrixAcceptedLive(wrong, applied: true, command: "command", window: "window", target: target) == nil)
    wrong = transaction
    wrong.strips[0].active = nil
    #expect(Runtime.matrixAcceptedLive(wrong, applied: true, command: "command", window: "window", target: target) == nil)
    let runtime = Runtime(windowID: "window")
    runtime.matrixTargets = [target]
    runtime.spaceMatrixPhase = 10
    runtime.matrixSetupGeneration = 2
    runtime.selectionGeneration = 2
    runtime.matrixCommand = "command"
    runtime.matrixCommandOpens = true
    runtime.recordMatrixTransaction(transaction, applied: true, usableHost: true)
    #expect(runtime.matrixAcknowledgedLive == nil)
    runtime.matrixCommandOpens = false
    runtime.recordMatrixTransaction(transaction, applied: false, usableHost: true)
    #expect(runtime.matrixAcknowledgedLive == nil)
    runtime.recordMatrixTransaction(transaction, applied: true, usableHost: false)
    #expect(runtime.matrixAcknowledgedLive == nil)
    runtime.selectionGeneration = 3
    runtime.recordMatrixTransaction(transaction, applied: true, usableHost: true)
    #expect(runtime.matrixAcknowledgedLive == nil)
    runtime.selectionGeneration = 2
    runtime.recordMatrixTransaction(transaction, applied: true, usableHost: true)
    #expect(runtime.matrixAcknowledgedLive == "live")
    runtime.matrixAcknowledgedLive = nil
    runtime.matrixSetupGeneration = 3
    runtime.selectionGeneration = 3
    runtime.matrixCommand = "next-command"
    runtime.recordMatrixTransaction(transaction, applied: true, usableHost: true)
    #expect(runtime.matrixAcknowledgedLive == nil)
    var nextEpoch = transaction
    nextEpoch.epoch = 2
    runtime.recordMatrixTransaction(nextEpoch, applied: true, usableHost: true)
    #expect(runtime.matrixEpochChanged)
}

@Test @MainActor
func matrixDiagnosticsDescribeSnapshotWithoutMutatingStore() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: directory.appendingPathComponent("workspace.sqlite").path, windowID: "matrix", card: NSView(), seedProfiles: true, session: session)
    let before: WorkspaceSnapshot = try session.queue.sync {
        let store = try #require(session.store)
        for number in 3...9 {
            _ = try store.createSpace(windowId: "matrix", name: "Matrix \(number)", spaceId: "matrix-\(number)")
            _ = try store.createTab(windowId: "matrix", url: "about:blank?matrix=\(number)")
        }
        let before = store.snapshot(windowId: "matrix")
        let diagnostic = Runtime.matrixSnapshotDiagnostics(before)
        #expect(diagnostic["shown"] as? String == "matrix-9")
        #expect(diagnostic["selected"] as? String == before.selectedId)
        #expect(diagnostic["space_count"] as? Int == 9)
        #expect(store.snapshot(windowId: "matrix") == before)
        return before
    }
    let runtime = Runtime(windowID: "matrix")
    runtime.adapter = engine
    runtime.snapshot = before
    runtime.spaceMatrixIDs = before.spaces.map(\.id)
    runtime.spaceMatrixNumber = 1
    runtime.spaceMatrixPhase = 1
    runtime.spaceMatrixSetup = Runtime.matrixSnapshotDiagnostics(before)
    let diagnostic = runtime.matrixDiagnostics()
    #expect(diagnostic["phase"] as? Int == 1 && diagnostic["waiting_for"] as? String == "last_space_and_active")
    #expect(diagnostic["target_space"] as? String == "matrix-9")
    let store = try #require(diagnostic["store"] as? [String: Any])
    let storeSnapshot = try #require(store["snapshot"] as? [String: Any])
    #expect(storeSnapshot["selected"] as? String == before.selectedId)
    #expect(JSONSerialization.isValidJSONObject(diagnostic))
    #expect(session.queue.sync { session.store?.snapshot(windowId: "matrix") } == before)
}

@Test @MainActor
func popupNewTabRequiresAnAdoptedSelectedTabInTheExistingWindow() {
    let oldTabs: [(live: String, item: String?)] = [("old-live", "old-item")]
    let oldRows: Set<String> = ["old-item"]
    let tabs: [(live: String, item: String?)] = [("old-live", "old-item"), ("new-live", "new-item")]
    let rows: Set<String> = ["old-item", "new-item"]
    let presentation: [String: Any] = ["compositor": "c1", "live": "new-live", "target": true, "host": true, "visible": true, "presented": true]
    let mappings = ["old-item": "old-live", "new-item": "new-live"]
    func check(_ actualTabs: [(live: String, item: String?)] = tabs, _ actualRows: Set<String> = rows,
               selected: String? = "new-item", nativeActive: String? = "new-item",
               actualPresentation: [String: Any] = presentation, actualMappings: [String: String] = mappings) -> Bool {
        Runtime.checkPopupNewTabInExistingWindow(previousTabs: oldTabs, previousRows: oldRows, currentTabs: actualTabs,
            currentRows: actualRows, selected: selected, nativeActive: nativeActive, compositor: "c1",
            presentation: actualPresentation, storeMappings: actualMappings)
    }
    #expect(check())
    #expect(!check(selected: "old-item"))
    #expect(!check(nativeActive: "old-item"))
    #expect(!check([("new-live", "new-item")]))
    #expect(!check([("old-live", "new-item"), ("new-live", "new-item")]))
    #expect(!check([("old-live", "changed-item"), ("new-live", "new-item")]))
    #expect(!check([("old-live", "old-item"), ("new-live", nil)]))
    #expect(!check(tabs, oldRows))
    #expect(!check(tabs + [("other-live", "other-item")]))
    #expect(!check(actualMappings: ["old-item": "different-live", "new-item": "new-live"]))
    #expect(!check(actualMappings: ["old-item": "old-live"]))
    #expect(!check(actualPresentation: ["compositor": "c1", "live": "old-live", "target": true, "host": true, "visible": true, "presented": true]))
    #expect(!check(actualPresentation: ["compositor": "c1", "live": "new-live", "target": false, "host": true, "visible": true, "presented": true]))
    var c2 = presentation
    c2["compositor"] = "c2"
    c2["window"] = true
    c2["bounds"] = true
    #expect(Runtime.checkPopupNewTabInExistingWindow(previousTabs: oldTabs, previousRows: oldRows, currentTabs: tabs,
        currentRows: rows, selected: "new-item", nativeActive: "new-item", compositor: "c2", presentation: c2, storeMappings: mappings))
    c2["bounds"] = false
    #expect(!Runtime.checkPopupNewTabInExistingWindow(previousTabs: oldTabs, previousRows: oldRows, currentTabs: tabs,
        currentRows: rows, selected: "new-item", nativeActive: "new-item", compositor: "c2", presentation: c2, storeMappings: mappings))
}

@Test @MainActor
func popupDispatchReachesAdoptionAndRootlessDevTools() {
    var phase = 20
    var rootPresent = true
    var devtoolsPhases: [Int] = []
    func tick() {
        Runtime.dispatchPopupCheck(mode: "popup", phase: phase) {
            devtoolsPhases.append(phase)
            #expect(!rootPresent)
            phase += 1
        } regular: {
            guard rootPresent, phase == 20 else { return }
            let presentation: [String: Any] = ["compositor": "c1", "live": "new", "target": true,
                                                "host": true, "visible": true, "presented": true]
            if Runtime.checkPopupNewTabInExistingWindow(previousTabs: [("old", "old-item")], previousRows: ["old-item"],
                currentTabs: [("old", "old-item"), ("new", "new-item")], currentRows: ["old-item", "new-item"],
                selected: "new-item", nativeActive: "new-item", compositor: "c1", presentation: presentation,
                storeMappings: ["old-item": "old", "new-item": "new"]) { phase = 21 }
        }
    }
    tick()
    #expect(phase == 21)
    rootPresent = false
    phase = 6
    for _ in 6...10 { tick() }
    #expect(devtoolsPhases == [6, 7, 8, 9, 10])
    #expect(phase == 11)
}

@Test @MainActor
func regularWindowRowsPreserveAllUnrelatedRecords() {
    let before = [["item", "existing", "unchanged"], ["window", "root", "unchanged"]]
    let item = ["item", "new", #"{"id":"new","lifecycle":"Open","membership":{"parent":"today-default"},"kind":{"Tab":{"url":"chrome://newtab/"}}}"#]
    let selected = ["last_selected", "new", "123"]
    let window = ["window", "child", #"{"id":"child","shown_space":"default","selected":"new"}"#]
    let during = before + [item, selected, window]
    let after = before + [item, selected]
    func check(_ open: [[String]], _ closed: [[String]]) -> Bool {
        Runtime.checkIncognitoRegularWindowRows(before: before, during: open, after: closed, window: "child", item: "new")
    }
    #expect(check(during, after))
    #expect(!check(during + [["item", "private", "leaked"]], after))
    #expect(!check(during, after + [window]))
    #expect(!check(during, [["item", "existing", "changed"]] + Array(after.dropFirst())))
    #expect(!check(during, before + [item]))
    #expect(!check(during + [window], after))
}

@Test @MainActor
func regularWindowClosePreservesExactPrivateStateAndClearsMapping() {
    let browser: [String: Any] = ["off_the_record": true, "profile_pointer": "profile", "browser_pointer": "browser"]
    let tab: [(live: String, item: String?)] = [("private", nil)]
    func check(_ tabs: [(live: String, item: String?)] = tab, _ browsers: [[String: Any]]? = nil,
               mapping: String? = nil, reverse: String? = nil) -> Bool {
        Runtime.checkIncognitoCloseState(tabs: tabs, browsers: browsers ?? [browser], privateLive: "private",
            privateProfile: "profile", privateBrowser: "browser", childLive: "child", childMapping: mapping, childReverseMapping: reverse)
    }
    #expect(check())
    #expect(!check(tab + [("extra", nil)]))
    #expect(!check([("replacement", nil)]))
    #expect(!check([("private", "item")]))
    #expect(!check(tab, [browser, browser]))
    #expect(!check(tab, [["off_the_record": true, "profile_pointer": "other", "browser_pointer": "browser"]]))
    #expect(!check(tab, [["off_the_record": true, "profile_pointer": "profile", "browser_pointer": "other"]]))
    #expect(!check(tab, [["off_the_record": false, "profile_pointer": "profile", "browser_pointer": "browser"]]))
    #expect(!check(mapping: "child"))
    #expect(!check(mapping: "replacement-live"))
    #expect(!check(reverse: "other-item"))
}

@Test
func incognitoFailureScopeUsesInvocationFlags() {
    let privateCase = incognitoResultIdentity(check: "incognito", arguments: [])
    #expect(privateCase["case"] as? String == "incognito-private")
    #expect(privateCase["check_flags"] as? [String] == [])
    let regularCase = incognitoResultIdentity(check: "incognito", arguments: ["--ararat-incognito-window-check", "--ararat-compositor=c2"])
    #expect(regularCase["case"] as? String == "incognito-regular-window")
    #expect(regularCase["check_flags"] as? [String] == ["--ararat-incognito-window-check"])
    #expect(regularCase["compositor"] as? String == "c2")
    #expect(regularCase["phase"] == nil && regularCase["attempts"] == nil)
    #expect(incognitoResultIdentity(check: "incognito", arguments: ["--ararat-incognito-window-check", "--ararat-page-only-menu-check"])["check_flags"] as? [String] == ["--ararat-incognito-window-check", "--ararat-page-only-menu-check"])
    #expect(incognitoResultIdentity(check: "keyboard", arguments: []).isEmpty)
}

@Test @MainActor
func splitSwitchReturnsTheFocusedMember() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let json = try String(contentsOf: root.appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), encoding: .utf8)
    let adapter = WorkspaceAdapter(windowID: "split-switch")
    _ = try await splitValue { adapter.open(path: directory.appendingPathComponent("workspace.sqlite").path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    try await splitValue { adapter.showSpace(id: "space-work", completion: $0) }
    _ = try await splitValue { adapter.select(id: "split-1", completion: $0) }
    let before = try await splitValue { adapter.showSpaceSelecting(id: "space-home", completion: $0) }
    #expect(before.shownSpaceId == "space-home")
    let runtime = Runtime(windowID: "split-switch")
    runtime.workspace = adapter
    runtime.snapshot = before
    let sidebar = SidebarView(snapshot: before)
    runtime.sidebar = sidebar
    sidebar.onShowSpace = { [weak runtime] in runtime?.switchWorkspaceSpace($0) }
    let target = try #require(before.spaces.firstIndex { $0.id == "space-work" })
    sidebar.showSpace(at: target)
    for _ in 0..<100 {
        if try await splitValue({ adapter.snapshot(completion: $0) }).shownSpaceId == "space-work" { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let selected = try await splitValue { adapter.snapshot(completion: $0) }
    #expect(selected.shownSpaceId == "space-work" && selected.selectedId == "tab-a")
    #expect(sidebar.spaceShown == target)
}

@Test @MainActor
func secondSwitchSelectsTheSplitMember() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let json = try String(contentsOf: root.appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), encoding: .utf8)
    let adapter = WorkspaceAdapter(windowID: "split-race")
    _ = try await splitValue { adapter.open(path: directory.appendingPathComponent("workspace.sqlite").path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    try await splitValue { adapter.showSpace(id: "space-work", completion: $0) }
    let initial = try await splitValue { adapter.select(id: "split-1", completion: $0) }
    #expect(initial.selectedId == "tab-a")
    let committed = try await splitValue { adapter.showSpaceSelecting(id: "space-home", completion: $0) }
    #expect(committed.shownSpaceId == "space-home")
    let current = try await splitValue { adapter.showSpaceSelecting(id: "space-work", completion: $0) }
    #expect(current.shownSpaceId == "space-work" && current.selectedId == "tab-a")
}

@Test @MainActor
func pendingSpaceSwitchIsCancelledBeforeClose() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let json = try String(contentsOf: root.appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), encoding: .utf8)
    let session = WorkspaceSession()
    let adapter = WorkspaceAdapter(windowID: "cancel-switch", session: session)
    let before = try await splitValue { adapter.open(path: directory.appendingPathComponent("workspace.sqlite").path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    let cancelled = await withCheckedContinuation { continuation in
        session.queue.suspend()
        adapter.showSpaceSelecting(id: "space-home") { result in
            if case .failure = result { continuation.resume(returning: true) }
            else { continuation.resume(returning: false) }
        }
        adapter.cancelPendingSpaceSwitches()
        session.queue.resume()
    }
    #expect(cancelled)
    #expect(try await splitValue { adapter.snapshot(completion: $0) } == before)
}

@Test @MainActor
func pendingExplicitTabSwitchIsCancelledBeforeClose() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let json = try String(contentsOf: root.appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), encoding: .utf8)
    let session = WorkspaceSession()
    let adapter = WorkspaceAdapter(windowID: "cancel-tab-switch", session: session)
    _ = try await splitValue { adapter.open(path: directory.appendingPathComponent("workspace.sqlite").path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    let before = try await splitValue { adapter.showSpaceSelecting(id: "space-home", completion: $0) }
    let cancelled = await withCheckedContinuation { continuation in
        session.queue.suspend()
        adapter.showSpaceSelectingTab(id: "space-work", item: "tab-spec") { result in
            if case .failure = result { continuation.resume(returning: true) }
            else { continuation.resume(returning: false) }
        }
        adapter.cancelPendingSpaceSwitches()
        session.queue.resume()
    }
    #expect(cancelled)
    #expect(try await splitValue { adapter.snapshot(completion: $0) } == before)
}

@Test @MainActor
func committedSwitchCheckDelaysOnlyTheCompletion() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let json = try String(contentsOf: root.appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), encoding: .utf8)
    let adapter = WorkspaceAdapter(windowID: "committed-switch")
    _ = try await splitValue { adapter.open(path: directory.appendingPathComponent("workspace.sqlite").path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    var held: (() -> Void)?
    var completed = false
    adapter.checkSpaceSwitchCompletion = { kind, resume in
        #expect(kind == "tab")
        held = resume
    }
    adapter.showSpaceSelectingTab(id: "space-work", item: "tab-spec") { result in
        if case .success = result { completed = true }
    }
    for _ in 0..<100 where held == nil { try await Task.sleep(for: .milliseconds(10)) }
    let resume = try #require(held)
    let committed = try await splitValue { adapter.snapshot(completion: $0) }
    #expect(committed.shownSpaceId == "space-work" && committed.selectedId == "tab-spec")
    #expect(!completed)
    adapter.cancelPendingSpaceSwitches()
    adapter.checkSpaceSwitchCompletion = nil
    resume()
    #expect(completed)
    #expect(try await splitValue { adapter.snapshot(completion: $0) } == committed)
    held = nil
    completed = false
    adapter.checkSpaceSwitchCompletion = { kind, resume in
        #expect(kind == "space")
        held = resume
    }
    adapter.showSpaceSelecting(id: "space-home") { result in
        if case .success = result { completed = true }
    }
    for _ in 0..<100 where held == nil { try await Task.sleep(for: .milliseconds(10)) }
    let resumeSpace = try #require(held)
    let committedSpace = try await splitValue { adapter.snapshot(completion: $0) }
    #expect(committedSpace.shownSpaceId == "space-home")
    #expect(!completed)
    adapter.cancelPendingSpaceSwitches()
    adapter.checkSpaceSwitchCompletion = nil
    resumeSpace()
    #expect(completed)
    #expect(try await splitValue { adapter.snapshot(completion: $0) } == committedSpace)
}

@Test @MainActor
func cancellingOneWindowsQueuedSwitchDoesNotCancelTheOtherWindow() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let json = try String(contentsOf: root.appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), encoding: .utf8)
    let session = WorkspaceSession()
    let first = WorkspaceAdapter(windowID: "first", session: session)
    let second = WorkspaceAdapter(windowID: "second", session: session)
    _ = try await splitValue { first.open(path: directory.appendingPathComponent("workspace.sqlite").path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    for cancelledFirst in [true, false] {
        try await splitValue { first.showSpace(id: "space-work", completion: $0) }
        try await splitValue { second.showSpace(id: "space-work", completion: $0) }
        var firstSucceeded: Bool?
        var secondSucceeded: Bool?
        session.queue.suspend()
        first.showSpaceSelecting(id: "space-home") { result in
            if case .success = result { firstSucceeded = true } else { firstSucceeded = false }
        }
        second.showSpaceSelecting(id: "space-home") { result in
            if case .success = result { secondSucceeded = true } else { secondSucceeded = false }
        }
        if cancelledFirst { first.cancelPendingSpaceSwitches() } else { second.cancelPendingSpaceSwitches() }
        session.queue.resume()
        for _ in 0..<100 where firstSucceeded == nil || secondSucceeded == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(firstSucceeded == !cancelledFirst && secondSucceeded == cancelledFirst)
        #expect(try await splitValue { first.snapshot(completion: $0) }.shownSpaceId == (cancelledFirst ? "space-work" : "space-home"))
        #expect(try await splitValue { second.snapshot(completion: $0) }.shownSpaceId == (cancelledFirst ? "space-home" : "space-work"))
    }
}
