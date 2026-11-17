import AppKit
import AraratKit
import SwiftUI
import Testing
@testable import AraratUI

@MainActor
private func atcValue<T: Sendable>(_ start: (@escaping WorkspaceAdapter.Completion<T>) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { done in start { done.resume(with: $0) } }
}

private let fixturesRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("core/ararat-core/tests/fixtures")

private func fixture(_ name: String) -> String {
    try! String(contentsOf: fixturesRoot.appendingPathComponent(name), encoding: .utf8)
}

// Only the tests call the no-profile form, the built-in default answer before any space is
// shown.
extension DestinationChoice {
    func destination() -> Destination? { destination(littleWindowProfile: nil) }
}

@MainActor
private func airTrafficDescendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + airTrafficDescendants($0) }
}

// The routing sibling joins the sidebar import: with all three siblings set,
// the file's rules land in the same batch and the counters describe them.
@Test @MainActor
func routingSiblingImportReachesTheStoreWithItsCounters() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = WorkspaceAdapter(windowID: "atc-import")
    let reports = AsyncStream<ImportReport>.makeStream()
    let snapshot = try await atcValue {
        adapter.open(path: directory.appendingPathComponent("atc.sqlite").path, json: { fixture("arc-sidebar-synthetic.json") }, windowsJSON: {
            fixture("StorableWindows.json")
        }, keyBindingsJSON: { #"{"version":1,"userOverrides":[]}"# }, linkRoutingJSON: {
            fixture("link-routing-synthetic.json")
        }, onImport: { reports.continuation.yield($0) }, completion: $0)
    }
    #expect(snapshot.spaces.count == 2)
    var iterator = reports.stream.makeAsyncIterator()
    let report = try #require(await iterator.next())
    #expect(!report.missingLinkRouting)
    #expect(report.linkRoutingError == nil)
    // The mapping table's rows through the wired import: four rules kept, one dropped per reason.
    #expect(report.importedRules == 4)
    #expect(report.skippedProfileDestinations == 1)
    #expect(report.skippedUnknownDestinations == 1)
    #expect(report.skippedUnknownStyles == 1)
    #expect(report.malformedRules == 1)
    let routing = try await atcValue { adapter.routing(completion: $0) }
    #expect(routing.rules.map(\.id) == ["meet", "github-prs", "docs-little", "double-condition"])
    #expect(routing.default == Destination.littleWindow(.default))
    reports.continuation.finish()
    _ = try await atcValue { adapter.shutdown(completion: $0) }
}

// A routing sibling that is absent, unreadable, or full of replacement characters (the harness
// decodes files lossily) still imports the sidebar and only marks the report.
@Test @MainActor
func missingMalformedAndNonUtf8RoutingFilesStillImportTheSidebar() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sidebar = fixture("arc-sidebar-synthetic.json")
    let inputs: [Data?] = [nil, #"(bad json"#.data(using: .utf8), Data([0xff])]
    for (index, data) in inputs.enumerated() {
        let adapter = WorkspaceAdapter(windowID: "atc-broken-\(index)")
        let reports = AsyncStream<ImportReport>.makeStream()
        let snapshot = try await atcValue {
            adapter.open(path: directory.appendingPathComponent("broken-\(index).sqlite").path, json: { sidebar }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: {
                data.map { String(decoding: $0, as: UTF8.self) }
            }, onImport: { reports.continuation.yield($0) }, completion: $0)
        }
        #expect(snapshot.spaces.count == 2)
        var iterator = reports.stream.makeAsyncIterator()
        let report = try #require(await iterator.next())
        #expect(report.missingLinkRouting == (index == 0))
        #expect((report.linkRoutingError != nil) == (index != 0))
        let routing = try await atcValue { adapter.routing(completion: $0) }
        #expect(routing.rules.isEmpty)
        reports.continuation.finish()
        _ = try await atcValue { adapter.shutdown(completion: $0) }
    }
}

// The pane model's every change goes through the core and survives a reopen; the test field
// shows the core's route answer, and a default reset leaves the built-in default after reopen.
@Test @MainActor
func thePaneModelWritesItsWayThroughTheCoreAndSurvivesAReopen() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("pane.sqlite").path
    let adapter = WorkspaceAdapter(windowID: "pane")
    let sidebar = fixture("arc-sidebar-synthetic.json")
    _ = try await atcValue { adapter.open(path: path, json: { sidebar }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    let model = AirTrafficModel(adapter: adapter)
    model.load()
    try await waitUntil { model.routing != nil }
    #expect(model.routing?.rules.isEmpty == true)

    try await atcValue { model.add(destination: .space(.space("space-work")), profile: .`default`, completion: $0) }
    try await atcValue { model.add(destination: .littleWindow(.default), profile: .`default`, completion: $0) }
    var rules = try #require(model.routing?.rules)
    let a = rules[0].id
    let b = rules[1].id
    #expect(a != b)

    // Edit: the condition text and destination are what the core stores back.
    try await atcValue { model.editCondition(a, style: .contains, text: "meet.google.com", completion: $0) }
    try await atcValue { model.editCondition(b, style: .contains, text: "unmatched.example", completion: $0) }
    try await atcValue { model.editDestination(a, choice: .mostRecent, completion: $0) }
    rules = try #require(model.routing?.rules)
    #expect(rules[0].id == a && rules[0].conditions == [UrlCondition(style: .contains, text: "meet.google.com")])
    #expect(rules[0].destination == Destination.space(.mostRecent))

    // Reorder through the model's API (tests never drag): the reorder reaches the core.
    try await atcValue { model.move(a, to: 1, completion: $0) }
    rules = try #require(model.routing?.rules)
    #expect(rules.map(\.id) == [b, a])
    try await atcValue { model.move(a, to: 0, completion: $0) }
    rules = try #require(model.routing?.rules)
    #expect(rules.map(\.id) == [a, b])

    // The test field equals the core's route: the model stores exactly what the store answers.
    let storeAnswer = try await atcValue { adapter.route(url: "https://www.meet.google.com/x", completion: $0) }
    try await atcValue { model.decide("https://www.meet.google.com/x", completion: $0) }
    #expect(model.testAnswer?.url == "https://www.meet.google.com/x")
    #expect(model.testAnswer?.decision == storeAnswer)
    #expect(model.testAnswer?.decision.ruleId == a)
    #expect(model.testAnswer?.decision.destination == Destination.space(.space("space-work")))

    // The default destination is the pane's Little Window choice until a space is picked.
    try await atcValue { model.setDefault(.space("space-home"), littleWindowProfile: nil, completion: $0) }
    #expect(model.routing?.default == Destination.space(.space("space-home")))
    // Picking the built-in default back resets it: after a reopen the built-in value stands.
    try await atcValue { model.setDefault(.littleWindowChoice, littleWindowProfile: nil, completion: $0) }
    #expect(model.routing?.default == Destination.littleWindow(.default))

    // Delete: the rule and the test answer's rule id go together.
    try await atcValue { model.delete(a, completion: $0) }
    rules = try #require(model.routing?.rules)
    #expect(rules.map(\.id) == [b])
    try await atcValue { model.decide("https://www.meet.google.com/x", completion: $0) }
    #expect(model.testAnswer?.decision.ruleId == nil)
    #expect(model.testAnswer?.decision.destination == Destination.littleWindow(.default))

    _ = try await atcValue { adapter.shutdown(completion: $0) }
    // Every change above is in the store, not only in memory.
    let reopened = try WorkspaceStore.open(path: path)
    let persisted = reopened.routing()
    #expect(persisted.rules.map(\.id) == [b])
    #expect(persisted.default == Destination.littleWindow(.default))
    #expect(persisted.rules.first?.destination == Destination.littleWindow(.default))
}

// The test field's plain answer and the destination menus' fallbacks (pure helpers).
@Test @MainActor
func testAnswersAndChoiceFallbacksUseTheirPlainWords() throws {
    let space = SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "space-work", title: "Work", icon: nil, look: nil, favorites: [], pinned: [], today: [])
    let rules = [Rule(id: "meet", conditions: [UrlCondition(style: .contains, text: "meet.google.com")], destination: .space(.mostRecent), profile: .`default`)]
    let ruleAnswer = AirTrafficModel.answerLabel(url: "https://www.meet.google.com/x",
        decision: RoutingDecision(ruleId: "meet", destination: .space(.mostRecent)), rules: rules, spaces: [space])
    #expect(ruleAnswer == "“https://www.meet.google.com/x” → route “meet.google.com” opens it in the most recent space")
    let defaultAnswer = AirTrafficModel.answerLabel(url: "https://other.example.org",
        decision: RoutingDecision(ruleId: nil, destination: .littleWindow(.default)), rules: rules, spaces: [space])
    #expect(defaultAnswer == "“https://other.example.org” → the default opens it in the Little window")
    #expect(AirTrafficModel.answerLabel(url: "  ", decision: RoutingDecision(ruleId: nil, destination: .space(.mostRecent)), rules: rules, spaces: [space]).hasPrefix("An empty link"))
    // A destination the core answered as lost reads as the deleted-space choice (its menu
    // shows a disabled "Deleted space" item, selected), and the space coming back reads as
    // it again once the core's set follows (the untouched row is not rewritten).
    let lost = Destination.space(.space("space-gone"))
    #expect(DestinationChoice(lost, deletedSpaces: ["space-gone"]) == .deletedSpace("space-gone"))
    #expect(DestinationChoice(lost, deletedSpaces: []) == .space("space-gone"))
    // A Little-window destination reads as the one choice whatever profile it names, and a
    // fresh pick rides the profile handed in — a rule edit hands the rule's own, the shown
    // space's covers the default and New Route; a rule already at a Little window keeps its
    // imported profile through the model's editDestination.
    #expect(DestinationChoice(Destination.littleWindow(.named("Profile 1"))) == .littleWindow)
    #expect(DestinationChoice.littleWindow.destination(littleWindowProfile: .named("Profile 1")) == Destination.littleWindow(.named("Profile 1")))
    #expect(DestinationChoice.littleWindowChoice.destination() == Destination.littleWindow(.default))
    #expect(DestinationChoice.littleWindow.destination(littleWindowProfile: .`default`) == Destination.littleWindow(.`default`))
    // The menu tags every destination the rows and the default can carry.
    #expect(DestinationChoice.menuTags(spaces: [space]) == [.mostRecent, .space("space-work"), .littleWindow])
}

// The pane's views build unordered (no window is ever ordered, no event posted): the section
// hosts its fields and the test field answers through the model, all without ordering a window.
@Test @MainActor
func theAirTrafficPaneViewsBuildWithoutOrderingAWindow() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = WorkspaceAdapter(windowID: "atc-view")
    let sidebar = fixture("arc-sidebar-synthetic.json")
    let snapshot = try await atcValue { adapter.open(path: directory.appendingPathComponent("view.sqlite").path, json: { sidebar }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    let airTraffic = AirTrafficModel(adapter: adapter)
    let model = SettingsModel(snapshot: snapshot, adapter: adapter, publish: { _ in }, resetWidth: {}, keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: airTraffic)
    let controller = SettingsWindowController(model: model)
    let window = try #require(controller.window)
    defer { window.contentViewController = nil }
    model.navigate(.airTraffic)
    #expect(model.title == "Air Traffic Control")
    airTraffic.load()
    try await waitUntil { airTraffic.routing != nil }
    try await atcValue { airTraffic.add(destination: .space(.space("space-work")), profile: .`default`, completion: $0) }
    let id = try #require(airTraffic.routing?.rules.first?.id)
    try await atcValue { airTraffic.editCondition(id, style: .contains, text: "meet.google.com", completion: $0) }
    window.contentView?.layoutSubtreeIfNeeded()
    let content = airTrafficDescendants(window.contentView!)
    // The row's URL text field and the pane's test link field bridge into AppKit here.
    #expect(content.compactMap { $0 as? NSTextField }.count >= 2)
    // The test field answers through the core, and the pane reads the rule back out.
    try await atcValue { airTraffic.decide("https://www.meet.google.com/x", completion: $0) }
    #expect(airTraffic.testAnswer?.decision.ruleId == id)
    let label = AirTrafficModel.answerLabel(url: "https://www.meet.google.com/x",
        decision: try #require(airTraffic.testAnswer?.decision), rules: airTraffic.routing?.rules ?? [], spaces: snapshot.spaces)
    #expect(label == "“https://www.meet.google.com/x” → route “meet.google.com” opens it in space Work")
    #expect(!window.isVisible)
    model.navigate(.tabs)
    #expect(model.highlighted == nil)
    window.contentView = nil
    _ = try await atcValue { adapter.shutdown(completion: $0) }
}

// The destination menus offer a tag for every destination a row or the default can carry.
// The check reads the menu through `menuTags` — the helper `pickerContext` is built from —
// so what it covers is what the menus show. A destination naming a lost space is covered by
// the disabled "Deleted space" item menuTags adds for its id.
@Test @MainActor
func theDestinationMenusOfferATagForEveryDestination() {
    let space = SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "space-work", title: "Work", icon: nil, look: nil, favorites: [], pinned: [], today: [])
    let menu = DestinationChoice.menuTags(spaces: [space], deletedSpaceIds: ["space-gone"])
    let destinations: [Destination?] = [Destination.littleWindow(.`default`), Destination.littleWindow(.named("Profile 1")), Destination.space(.mostRecent), Destination.space(.space("space-work")), Destination.space(.space("space-gone")), nil]
    for destination in destinations {
        let choice = DestinationChoice(destination, deletedSpaces: ["space-gone"])
        #expect(menu.contains(choice), "\(String(describing: destination)) has no menu tag")
    }
}

// A rule (or the default) whose space was deleted keeps its
// destination, the model names the lost space for the menus, and picking another destination
// replaces the deleted one. Read through the model and the menu tags; no menu is popped.
@Test @MainActor
func theModelNamesTheLostSpaceAndAPickReplacesTheDeletedDestination() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = WorkspaceAdapter(windowID: "atc-deleted")
    let sidebar = fixture("arc-sidebar-synthetic.json")
    let snapshot = try await atcValue { adapter.open(path: directory.appendingPathComponent("deleted.sqlite").path, json: { sidebar }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    let model = AirTrafficModel(adapter: adapter)
    // The pane reads the core's deleted-space answer: nothing is lost yet.
    try await atcValue { model.load(completion: $0) }
    #expect(model.deletedSpaces.isEmpty)
    // A rule at one space and the default at the other: nothing is lost yet after the edits.
    try await atcValue { model.add(destination: .space(.space("space-work")), profile: .`default`, completion: $0) }
    try await atcValue { model.setDefault(.space("space-home"), littleWindowProfile: nil, completion: $0) }
    let persistedID = try #require(model.routing?.rules.first?.id)
    try await atcValue { model.editCondition(persistedID, style: .contains, text: "example.com", completion: $0) }
    #expect(model.deletedSpaces.isEmpty)
    // The space the rule points at is deleted; the rule keeps its destination and the core
    // answers the lost one (the default still names a living space).
    try await atcValue { adapter.deleteSpace(id: "space-work", completion: $0) }
    let after = try await atcValue { adapter.snapshot(completion: $0) }
    try await atcValue { model.load(completion: $0) }
    #expect(model.routing?.rules.first?.destination == Destination.space(.space("space-work")))
    #expect(model.routing?.default == Destination.space(.space("space-home")))
    #expect(model.deletedSpaceIds == ["space-work"])
    #expect(DestinationChoice(model.routing?.rules.first?.destination, deletedSpaces: model.deletedSpaces) == .deletedSpace("space-work"))
    // The menu the pane builds carries one disabled item for that id and nothing else.
    let tags = DestinationChoice.menuTags(spaces: after.spaces, deletedSpaceIds: model.deletedSpaceIds)
    #expect(tags.filter(\.isDeletedSpace) == [.deletedSpace("space-work")])
    // Picking another destination replaces the deleted one, and no id is lost any more: the
    // core's answer follows the edit, not the old routing snapshot.
    let ruleId = try #require(model.routing?.rules.first?.id)
    try await atcValue { model.editDestination(ruleId, choice: .mostRecent, completion: $0) }
    #expect(model.routing?.rules.first?.destination == Destination.space(.mostRecent))
    #expect(model.deletedSpaces.isEmpty)
    _ = try await atcValue { adapter.shutdown(completion: $0) }
}

// Editing keeps every condition a rule came in with: rewriting only the first condition
// would let one menu pick delete an imported rule's conditions.
@Test @MainActor
func editingARuleKeepsEveryConditionItCameInWith() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = WorkspaceAdapter(windowID: "atc-conditions")
    let sidebar = fixture("arc-sidebar-synthetic.json")
    _ = try await atcValue { adapter.open(path: directory.appendingPathComponent("conditions.sqlite").path, json: { sidebar }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { fixture("link-routing-synthetic.json") }, completion: $0) }
    let model = AirTrafficModel(adapter: adapter)
    model.load()
    try await waitUntil { model.routing != nil }
    let imported = try #require(model.routing?.rules.first { $0.id == "double-condition" })
    #expect(imported.conditions == [UrlCondition(style: .contains, text: "a.example"), UrlCondition(style: .equals, text: "https://b.example/")])
    // A destination change keeps every condition and the imported rule's shape.
    try await atcValue { model.editDestination(imported.id, choice: .mostRecent, completion: $0) }
    var rules = try #require(model.routing?.rules)
    var edited = try #require(rules.first { $0.id == imported.id })
    #expect(edited.conditions == imported.conditions)
    #expect(edited.destination == Destination.space(.mostRecent))
    // A style (or text) change rewrites the first condition and keeps the rest.
    try await atcValue { model.editCondition(imported.id, style: .equals, text: "a.example", completion: $0) }
    rules = try #require(model.routing?.rules)
    edited = try #require(rules.first { $0.id == imported.id })
    #expect(edited.conditions == [UrlCondition(style: .equals, text: "a.example"), UrlCondition(style: .equals, text: "https://b.example/")])
    #expect(edited.destination == Destination.space(.mostRecent))
    _ = try await atcValue { adapter.shutdown(completion: $0) }
}

// A Little Window pick rides the profile of what receives it: the default card takes the
// shown space's (the built-in default one cannot open a workspace whose spaces live in a
// named profile), while a rule's own pick — fresh or re-picked — stays the rule's own.
@Test @MainActor
func aLittleWindowPickRidesTheProfileOfWhatReceivesIt() async throws {
    #expect(DestinationChoice.littleWindow.destination(littleWindowProfile: .named("Profile 1")) == Destination.littleWindow(.named("Profile 1")))
    #expect(DestinationChoice.littleWindowChoice.destination() == Destination.littleWindow(.default))
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = WorkspaceAdapter(windowID: "atc-little")
    let sidebar = fixture("arc-sidebar-synthetic.json")
    _ = try await atcValue { adapter.open(path: directory.appendingPathComponent("little.sqlite").path, json: { sidebar }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { fixture("link-routing-synthetic.json") }, completion: $0) }
    let model = AirTrafficModel(adapter: adapter)
    model.load()
    try await waitUntil { model.routing != nil }
    // The default card's pick writes the shown profile, and it is in the store (not only in
    // memory); a rule already opening a Little window keeps its own profile when re-picked.
    try await atcValue { model.setDefault(.littleWindow, littleWindowProfile: .named("Profile 1"), completion: $0) }
    #expect(model.routing?.default == Destination.littleWindow(.named("Profile 1")))
    let imported = try #require(model.routing?.rules.first { $0.id == "docs-little" })
    #expect(imported.destination == Destination.littleWindow(.default))
    try await atcValue { model.editDestination(imported.id, choice: .littleWindow, completion: $0) }
    var rules = try #require(model.routing?.rules)
    #expect(rules.first { $0.id == imported.id }?.destination == Destination.littleWindow(.default))
    // A fresh pick on a rule writes the rule's own profile, not the shown space's: `meet`
    // rides in the first space's (the built-in one), whatever profile the pane shows.
    try await atcValue { model.editDestination("meet", choice: .littleWindow, completion: $0) }
    rules = try #require(model.routing?.rules)
    #expect(rules.first { $0.id == "meet" }?.destination == Destination.littleWindow(.`default`))
    // And a rule of the named profile keeps it on a fresh pick, while the pane shows the
    // built-in profile's space: the shown one never reaches a rule's pick.
    try await atcValue { model.add(destination: .space(.space("space-home")), profile: .named("Profile 1"), completion: $0) }
    let named = try #require(model.routing?.rules.first { $0.profile == .named("Profile 1") })
    try await atcValue { model.editDestination(named.id, choice: .littleWindow, completion: $0) }
    rules = try #require(model.routing?.rules)
    #expect(rules.first { $0.id == named.id }?.destination == Destination.littleWindow(.named("Profile 1")))
    _ = try await atcValue { adapter.shutdown(completion: $0) }
}

// The default's and New Route's Little-window picks name the shown space's own `Profile`
// from the FFI snapshot, not the display name mapped back: a named profile called "Default"
// would read as the built-in one.
@Test @MainActor
func theShownSpacesOwnProfileCoversTheDefaultAndNewRoutePicks() {
    let adapter = WorkspaceAdapter(windowID: "atc-profile")
    let space = SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: #"Named("Default")"#, pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .named("Default"), id: "space-work", title: "Work", icon: nil, look: nil, favorites: [], pinned: [], today: [])
    let model = SettingsModel(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "space-work", selectedId: nil, spaces: [space]),
        adapter: adapter, publish: { _ in }, resetWidth: {}, keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: AirTrafficModel(adapter: adapter))
    #expect(model.airTrafficLittleWindowProfile == .named("Default"))
}

// The row's URL field holds its text as a draft and writes once at commit: typing must not
// drive straight into edit — that would write one synced record per keystroke.
@Test @MainActor
func ruleUrlFieldWritesOnlyAtCommit() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = WorkspaceAdapter(windowID: "atc-urlfield")
    let sidebar = fixture("arc-sidebar-synthetic.json")
    _ = try await atcValue { adapter.open(path: directory.appendingPathComponent("url.sqlite").path, json: { sidebar }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    let snapshot = try await atcValue { adapter.snapshot(completion: $0) }
    let airTraffic = AirTrafficModel(adapter: adapter)
    let model = SettingsModel(snapshot: snapshot, adapter: adapter, publish: { _ in }, resetWidth: {}, keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: airTraffic)
    let controller = SettingsWindowController(model: model)
    let window = try #require(controller.window)
    defer { window.contentViewController = nil }
    model.navigate(.airTraffic)
    airTraffic.load()
    try await waitUntil { airTraffic.routing != nil }
    try await atcValue { airTraffic.add(destination: .space(.space("space-work")), profile: .`default`, completion: $0) }
    // The row's URL field is the one the URL placeholder tags (the bridge shows placeholders,
    // not accessibility overrides).
    let rowField = { airTrafficDescendants(window.contentView!).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "URL" } }
    try await waitUntil { window.contentView?.layoutSubtreeIfNeeded(); return rowField() != nil }
    let probe = try #require(controller.checkProbe())
    for id in ["atc-new-route", "atc-route-1-destination", "atc-default-destination"] {
        let frame = try #require(probe.marker(id))
        #expect(frame.width > 0 && frame.height > 0)
    }
    let field = try #require(rowField())
    #expect(window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? NSTextView)
    editor.insertText("meet.google.com", replacementRange: editor.selectedRange())
    let afterTyping = try await atcValue { adapter.routing(completion: $0) }
    #expect(afterTyping.rules.isEmpty)
    let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
        isARepeat: false, keyCode: 36))
    editor.keyDown(with: enter)
    try await waitUntil { airTraffic.routing?.rules.first?.conditions.first?.text == "meet.google.com" }
    let afterCommit = try await atcValue { adapter.routing(completion: $0) }
    #expect(afterCommit.rules.first?.conditions == [UrlCondition(style: .contains, text: "meet.google.com")])
    #expect(!window.isVisible)
    window.contentView = nil
    _ = try await atcValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func storedEmptyRoutesAcceptDestinationAndStyleEdits() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = WorkspaceAdapter(windowID: "atc-stored-empty")
    _ = try await atcValue {
        adapter.open(path: directory.appendingPathComponent("empty.sqlite").path,
            json: { fixture("arc-sidebar-synthetic.json") }, windowsJSON: { nil },
            keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0)
    }
    let rule = Rule(id: "empty", conditions: [UrlCondition(style: .contains, text: "")],
        destination: .space(.space("space-work")), profile: .default)
    _ = try await atcValue { adapter.addRule(rule, completion: $0) }
    let model = AirTrafficModel(adapter: adapter)
    try await atcValue { model.load(completion: $0) }
    try await atcValue { model.editDestination(rule.id, choice: .mostRecent, completion: $0) }
    model.editStyle(rule.id, style: .equals)
    let stored = try await atcValue { adapter.routing(completion: $0) }
    #expect(stored.rules.first?.destination == .space(.mostRecent))
    #expect(stored.rules.first?.conditions == [UrlCondition(style: .equals, text: "")])
    _ = try await atcValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func refusedFirstRouteAddKeepsItsDraftAndText() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = WorkspaceAdapter(windowID: "atc-refused-add")
    _ = try await atcValue {
        adapter.open(path: directory.appendingPathComponent("refused.sqlite").path,
            json: { fixture("arc-sidebar-synthetic.json") }, windowsJSON: { nil },
            keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0)
    }
    let model = AirTrafficModel(adapter: adapter)
    try await atcValue { model.load(completion: $0) }
    try await atcValue { model.add(destination: .space(.space("space-home")), profile: .default, completion: $0) }
    let id = try #require(model.routing?.rules.first?.id)
    let refused = try? await atcValue { model.editCondition(id, style: .contains, text: "example.com", completion: $0) }
    #expect(refused == nil)
    #expect(model.error?.contains("another profile") == true)
    let stored = try await atcValue { adapter.routing(completion: $0) }
    #expect(stored.rules.isEmpty)
    try await atcValue { model.load(completion: $0) }
    #expect(model.routing?.rules.first?.id == id)
    #expect(model.routing?.rules.first?.conditions.first?.text == "example.com")
    try await atcValue { model.editDestination(id, choice: .mostRecent, completion: $0) }
    let retried = try await atcValue { adapter.routing(completion: $0) }
    #expect(retried.rules.first?.id == id)
    #expect(retried.rules.first?.conditions.first?.text == "example.com")
    _ = try await atcValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func routeDraftsStayLocalAndOverlappingRowEditsKeepEveryChange() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = WorkspaceAdapter(windowID: "atc-overlap")
    let sidebar = fixture("arc-sidebar-synthetic.json")
    let snapshot = try await atcValue {
        adapter.open(path: directory.appendingPathComponent("overlap.sqlite").path, json: { sidebar },
            windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0)
    }
    let airTraffic = AirTrafficModel(adapter: adapter)
    try await atcValue { airTraffic.load(completion: $0) }
    try await atcValue { airTraffic.add(destination: .space(.space("space-work")), profile: .default, completion: $0) }
    let id = try #require(airTraffic.routing?.rules.first?.id)
    airTraffic.editStyle(id, style: .equals)
    airTraffic.editText(id, text: " \u{10}\t ")
    airTraffic.editDestination(id, choice: .mostRecent)
    var stored = try await atcValue { adapter.routing(completion: $0) }
    #expect(stored.rules.isEmpty)
    try await atcValue { airTraffic.load(completion: $0) }
    #expect(airTraffic.routing?.rules.first?.id == id)
    airTraffic.editText(id, text: "example.com")
    airTraffic.editDestination(id, choice: .space("space-work"))
    airTraffic.editStyle(id, style: .contains)
    #expect(airTraffic.routing?.rules.first?.conditions == [UrlCondition(style: .contains, text: "example.com")])
    stored = try await atcValue { adapter.routing(completion: $0) }
    #expect(stored.rules.first?.conditions == [UrlCondition(style: .contains, text: "example.com")])
    #expect(stored.rules.first?.destination == .space(.space("space-work")))
    airTraffic.editText(id, text: "")
    airTraffic.editDestination(id, choice: .mostRecent)
    stored = try await atcValue { adapter.routing(completion: $0) }
    #expect(stored.rules.first?.conditions.first?.text == "example.com")
    #expect(stored.rules.first?.destination == .space(.mostRecent))

    let model = SettingsModel(snapshot: snapshot, adapter: adapter, publish: { _ in }, resetWidth: {},
        keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: airTraffic)
    let section = SettingsAirTrafficSection(model: model, airTraffic: airTraffic)
    section.defaultSelection.wrappedValue = .mostRecent
    try await waitUntil { airTraffic.routing?.default == .space(.mostRecent) }
    let reopened = try WorkspaceStore.open(path: directory.appendingPathComponent("overlap.sqlite").path)
    #expect(reopened.routing().default == .space(.mostRecent))
    #expect(section.defaultSelection.wrappedValue == .mostRecent)
    _ = try await atcValue { adapter.shutdown(completion: $0) }
}

// The test field's answer carries the url it asked about trimmed: a raw string with a
// trailing space would leave the placeholder up while the label itself already trims.
@Test @MainActor
func theTestFieldAnswersItsTrimmedUrl() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = WorkspaceAdapter(windowID: "atc-trim")
    let sidebar = fixture("arc-sidebar-synthetic.json")
    _ = try await atcValue { adapter.open(path: directory.appendingPathComponent("trim.sqlite").path, json: { sidebar }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    let model = AirTrafficModel(adapter: adapter)
    try await atcValue { model.decide("  https://www.meet.google.com/x  ", completion: $0) }
    #expect(model.testAnswer?.url == "https://www.meet.google.com/x")
    #expect(model.testAnswer?.decision.ruleId == nil)
    _ = try await atcValue { adapter.shutdown(completion: $0) }
}

// The search result for the pane and the card it scrolls to and fills carry the same id: a
// card id no search row sets would never be filled.
@Test @MainActor
func theAirTrafficSearchResultFillsItsRow() throws {
    let snapshot = WorkspaceSnapshot(archive: [], shownSpaceId: "space-work", selectedId: nil, spaces: [SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "space-work", title: "Work", icon: nil, look: nil, favorites: [], pinned: [], today: [])])
    let adapter = WorkspaceAdapter(windowID: "atc-search")
    let model = SettingsModel(snapshot: snapshot, adapter: adapter, publish: { _ in }, resetWidth: {}, keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: AirTrafficModel(adapter: adapter))
    let row = try #require(model.rows.first { $0.pane == .airTraffic })
    model.select(row)
    #expect(model.highlighted == row.id)
    #expect(row.id == SettingsModel.airTrafficCardId)
}

// A destination the core answers as lost reads as the deleted-space
// choice (the menu shows a disabled "Deleted space" item, selected, not Most Recent Space),
// the choice writes nothing while it is selected, and the id keeps its tag so an untouched
// row is not rewritten (a space the core no longer flags reads as it again).
@Test @MainActor
func aDestinationNamingALostSpaceReadsAsTheDeletedSpaceChoice() {
    let space = SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "space-work", title: "Work", icon: nil, look: nil, favorites: [], pinned: [], today: [])
    let lost = Destination.space(.space("space-gone"))
    #expect(DestinationChoice(lost, deletedSpaces: ["space-gone"]) == .deletedSpace("space-gone"))
    #expect(DestinationChoice(lost, deletedSpaces: []) == .space("space-gone"))
    // The disabled item writes nothing: a pick never carries it, so the menu "answered nothing".
    #expect(DestinationChoice.deletedSpace("space-gone").destination(littleWindowProfile: nil) == nil)
    #expect(DestinationChoice.deletedSpace("space-gone").menuTitle(spaces: [space]) == "Deleted space")
    #expect(DestinationChoice.deletedSpace("space-gone").isDeletedSpace)
    #expect(!DestinationChoice.mostRecent.isDeletedSpace)
}

// The route rows are labeled by position at the helper the fields carry, so a screen reader
// reads what the pane reads — "URL text of route 1", "Delete route 2" — and no label ever
// carries a rule id. The bridged pane does not surface SwiftUI accessibility overrides outside
// a live AX runtime, so the label texts are pinned where the view reads them from.
@Test @MainActor
func theRouteAccessibilityLabelsNameThePositionAndNeverTheRuleId() throws {
    #expect(SettingsModel.routeUrlAccessibilityLabel(1) == "URL text of route 1")
    #expect(SettingsModel.routeUrlAccessibilityLabel(2) == "URL text of route 2")
    #expect(SettingsModel.routeDeleteAccessibilityLabel(1) == "Delete route 1")
    #expect(SettingsModel.routeDeleteAccessibilityLabel(2) == "Delete route 2")
    let uuid = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    for position in [1, 2, 3, 4] {
        #expect(SettingsModel.routeUrlAccessibilityLabel(position).range(of: uuid, options: .regularExpression) == nil)
        #expect(SettingsModel.routeDeleteAccessibilityLabel(position).range(of: uuid, options: .regularExpression) == nil)
    }
}

// Two named rules read back as two URL fields in the rows' order, and the values follow the
// rows through a move and a delete: each field carries its rule's text, so what the
// positional labels stand for is the row order itself, not a rule's founding slot.
@Test @MainActor
func theUrlFieldsReadTheirRulesBackInRowOrderThroughAMoveAndADelete() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = WorkspaceAdapter(windowID: "atc-rowfields")
    let sidebar = fixture("arc-sidebar-synthetic.json")
    let snapshot = try await atcValue { adapter.open(path: directory.appendingPathComponent("rowfields.sqlite").path, json: { sidebar }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    let airTraffic = AirTrafficModel(adapter: adapter)
    let model = SettingsModel(snapshot: snapshot, adapter: adapter, publish: { _ in }, resetWidth: {}, keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: airTraffic)
    let controller = SettingsWindowController(model: model)
    let window = try #require(controller.window)
    defer { window.contentViewController = nil }
    model.navigate(.airTraffic)
    airTraffic.load()
    try await waitUntil { airTraffic.routing != nil }
    func urlTexts() -> [String] {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let content = window.contentView else { return [] }
        return airTrafficDescendants(content).compactMap { $0 as? NSTextField }.filter { $0.placeholderString == "URL" }.map(\.stringValue)
    }
    try await atcValue { airTraffic.add(destination: .space(.space("space-work")), profile: .`default`, completion: $0) }
    try await atcValue { airTraffic.add(destination: .space(.mostRecent), profile: .`default`, completion: $0) }
    let rules = try #require(airTraffic.routing?.rules)
    #expect(rules.count == 2)
    let firstId = try #require(rules.first?.id)
    let secondId = try #require(rules.last?.id)
    try await atcValue { airTraffic.editCondition(firstId, style: .contains, text: "alpha", completion: $0) }
    try await atcValue { airTraffic.editCondition(secondId, style: .contains, text: "beta", completion: $0) }
    // The fields carry the rule texts in the rows' order.
    try await waitUntil { urlTexts() == ["alpha", "beta"] }
    #expect(try #require(urlTexts().first) == "alpha")
    #expect(try #require(urlTexts().last) == "beta")
    // The row move rebinds what each positional field stands for.
    try await atcValue { airTraffic.move(secondId, to: 0, completion: $0) }
    try await waitUntil { urlTexts() == ["beta", "alpha"] }
    #expect(try #require(urlTexts().first) == "beta")
    #expect(try #require(urlTexts().last) == "alpha")
    // The delete takes the field with it and leaves the other rule's row intact.
    try await atcValue { airTraffic.delete(secondId, completion: $0) }
    try await waitUntil { urlTexts().count == 1 }
    #expect(try #require(urlTexts().first) == "alpha")
    #expect(!window.isVisible)
    window.contentView = nil
    _ = try await atcValue { adapter.shutdown(completion: $0) }
}

// The test field asks while the text changes — not only at Return — and an empty or
// whitespace-only field asks nothing: after both clears, a route round trip queued behind
// them (the adapter's queue is serial, so a stray ask would have answered first and either
// replaced the answer with the emptiness or set an error) still finds the older answer
// standing with no error.
@Test @MainActor
func theTestFieldAnswersWhileTheTextChangesAndAnEmptyFieldAsksNothing() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = WorkspaceAdapter(windowID: "atc-probe")
    let sidebar = fixture("arc-sidebar-synthetic.json")
    let snapshot = try await atcValue { adapter.open(path: directory.appendingPathComponent("probe.sqlite").path, json: { sidebar }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    let airTraffic = AirTrafficModel(adapter: adapter)
    let model = SettingsModel(snapshot: snapshot, adapter: adapter, publish: { _ in }, resetWidth: {}, keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: airTraffic)
    let controller = SettingsWindowController(model: model)
    let window = try #require(controller.window)
    defer { window.contentViewController = nil }
    model.navigate(.airTraffic)
    airTraffic.load()
    try await waitUntil { airTraffic.routing != nil }
    let testField = { window.contentView?.layoutSubtreeIfNeeded(); return airTrafficDescendants(window.contentView!).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "https://…" } }
    try await waitUntil { testField() != nil }
    let field = try #require(testField())
    // Typing alone (nothing was submitted) asks, and the stored answer matches the field's url.
    field.stringValue = "good.example"
    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    try await waitUntil { airTraffic.testAnswer?.url == "good.example" }
    let answer = AirTrafficModel.answerLabel(url: "good.example", decision: try #require(airTraffic.testAnswer?.decision), rules: airTraffic.routing?.rules ?? [], spaces: snapshot.spaces)
    #expect(answer.hasPrefix("“good.example”"))
    // Clearing — whitespace only first, then fully — leaves the stored answer untouched.
    field.stringValue = " "
    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    field.stringValue = ""
    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    _ = try await atcValue { adapter.route(url: "https://good.example", completion: $0) }
    #expect(airTraffic.testAnswer?.url == "good.example")
    #expect(airTraffic.error == nil)
    #expect(!window.isVisible)
    window.contentView = nil
    _ = try await atcValue { adapter.shutdown(completion: $0) }
}

// A route answer is a query, not an edit: answering the test field must not clear the banner
// a refused edit shows — the pane reads the one `error` for both. An applied edit still
// clears a stale refusal through the same receive the edits answer on.
@Test @MainActor
func aRouteAnswerLeavesARefusedEditsMessageStanding() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = WorkspaceAdapter(windowID: "atc-refusal")
    let sidebar = fixture("arc-sidebar-synthetic.json")
    _ = try await atcValue { adapter.open(path: directory.appendingPathComponent("refusal.sqlite").path, json: { sidebar }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { fixture("link-routing-synthetic.json") }, completion: $0) }
    let airTraffic = AirTrafficModel(adapter: adapter)
    try await atcValue { airTraffic.load(completion: $0) }
    #expect(airTraffic.routing?.rules.contains { $0.id == "meet" } == true)
    // The core refuses an edit whose destination names a space the workspace does not have,
    // and the refusal sets the banner's message.
    let refused = try? await atcValue { airTraffic.editDestination("meet", choice: .space("space-gone"), completion: $0) }
    #expect(refused == nil)
    let refusal = try #require(airTraffic.error)
    // Answering the test field (a keystroke's ask routes and lands) answers — and the
    // refusal keeps standing.
    try await atcValue { airTraffic.decide("good.example", completion: $0) }
    #expect(airTraffic.testAnswer?.url == "good.example")
    #expect(airTraffic.error == refusal)
    // An applied edit goes through the same receive and clears the stale refusal.
    try await atcValue { airTraffic.editDestination("meet", choice: .mostRecent, completion: $0) }
    #expect(airTraffic.error == nil)
    _ = try await atcValue { adapter.shutdown(completion: $0) }
}

// The core refuses a destination the pane's own profile does not carry, and the refusal is
// the message the pane shows: the rule's row keeps its destination and the banner names the
// pane's profile as the reason.
@Test @MainActor
func aCrossProfileDestinationEditRefusalShowsItsReasonInThePane() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = WorkspaceAdapter(windowID: "atc-cross-profile")
    let sidebar = fixture("arc-sidebar-synthetic.json")
    let snapshot = try await atcValue { adapter.open(path: directory.appendingPathComponent("cross.sqlite").path, json: { sidebar }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    let airTraffic = AirTrafficModel(adapter: adapter)
    let model = SettingsModel(snapshot: snapshot, adapter: adapter, publish: { _ in }, resetWidth: {}, keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: airTraffic)
    // The pane's context is the shown space's profile (space-work, the default one).
    #expect(model.airTrafficLittleWindowProfile == .`default`)
    try await atcValue { airTraffic.load(completion: $0) }
    try await atcValue { airTraffic.add(destination: .space(.space("space-work")), profile: model.airTrafficLittleWindowProfile, completion: $0) }
    let id = try #require(airTraffic.routing?.rules.first?.id)
    // space-home rides in the named "Profile 1": the pick is refused and the banner says so.
    try await atcValue { airTraffic.editCondition(id, style: .contains, text: "example.com", completion: $0) }
    let refused = try? await atcValue { airTraffic.editDestination(id, choice: .space("space-home"), completion: $0) }
    #expect(refused == nil)
    let reason = try #require(airTraffic.error)
    #expect(reason.contains("another profile"))
    #expect(airTraffic.routing?.rules.first?.destination == Destination.space(.space("space-work")))
    // The refused banner clears with an applied edit (most recent) through the same receive.
    try await atcValue { airTraffic.editDestination(id, choice: .mostRecent, completion: $0) }
    #expect(airTraffic.error == nil)
    _ = try await atcValue { adapter.shutdown(completion: $0) }
}

// The pane's deleted-space set is the core's one answer covering every destination (a rule's
// and the default's), not a Swift-side compare against the shown spaces.
@Test @MainActor
func thePaneReadsTheCoreSDeletedSpaceSet() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = WorkspaceAdapter(windowID: "atc-core-set")
    let sidebar = fixture("arc-sidebar-synthetic.json")
    let snapshot = try await atcValue { adapter.open(path: directory.appendingPathComponent("coreset.sqlite").path, json: { sidebar }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { fixture("link-routing-synthetic.json") }, completion: $0) }
    let airTraffic = AirTrafficModel(adapter: adapter)
    try await atcValue { airTraffic.load(completion: $0) }
    #expect(airTraffic.deletedSpaces.isEmpty)
    // A rule rides at space-work (github-prs) and the default lands at space-home; a third
    // space keeps the deletions above the last-space refusal.
    _ = try await atcValue { adapter.createSpace(name: "Spare", completion: $0) }
    try await atcValue { airTraffic.setDefault(.space("space-home"), littleWindowProfile: nil, completion: $0) }
    try await atcValue { adapter.deleteSpace(id: "space-work", completion: $0) }
    try await atcValue { adapter.deleteSpace(id: "space-home", completion: $0) }
    let after = try await atcValue { adapter.snapshot(completion: $0) }
    try await atcValue { airTraffic.load(completion: $0) }
    // The core's answer covers the rule and the default: the pane reads it, sorted as the
    // menus show it.
    #expect(airTraffic.deletedSpaceIds == ["space-home", "space-work"])
    #expect(airTraffic.routing?.default == Destination.space(.space("space-home")))
    // The tags the menus carry: the two disabled items for the core's answer and the living
    // space's tag, nothing else.
    let tags = DestinationChoice.menuTags(spaces: after.spaces, deletedSpaceIds: airTraffic.deletedSpaceIds)
    #expect(tags.filter(\.isDeletedSpace) == [.deletedSpace("space-home"), .deletedSpace("space-work")])
    _ = try await atcValue { adapter.shutdown(completion: $0) }
}

// A space deleted while the window is open moves its destination into the pane's set
// through the snapshot the deletion returns: the set follows the spaces without another
// `load`, so the picker matches the selection instead of showing none.
@Test @MainActor
func deletingASpaceWithThePaneLoadedMovesItsDestinationIntoTheSetWithoutAReload() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = WorkspaceAdapter(windowID: "atc-refresh")
    let sidebar = fixture("arc-sidebar-synthetic.json")
    let snapshot = try await atcValue { adapter.open(path: directory.appendingPathComponent("refresh.sqlite").path, json: { sidebar }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { fixture("link-routing-synthetic.json") }, completion: $0) }
    let airTraffic = AirTrafficModel(adapter: adapter)
    let model = SettingsModel(snapshot: snapshot, adapter: adapter, publish: { _ in }, resetWidth: {}, keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: airTraffic)
    try await atcValue { airTraffic.load(completion: $0) }
    #expect(airTraffic.deletedSpaces.isEmpty)
    // A third space keeps the deletion above the last-space refusal; the rule rides at
    // space-work (github-prs).
    _ = try await atcValue { adapter.createSpace(name: "Spare", completion: $0) }
    model.requestDelete("space-work")
    model.confirmDelete()
    try await waitUntil { airTraffic.deletedSpaceIds == ["space-work"] }
    _ = try await atcValue { adapter.shutdown(completion: $0) }
}

// New Route does not ask for a destination the core refuses: the default destination is
// judged on existence only, so it may name another profile's space — a rule cannot — and
// such a New Route starts at the most recent space of the rule's profile instead.
@Test @MainActor
func aNewRouteWithADefaultOfAnotherProfileStartsAtAUsableDestination() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = WorkspaceAdapter(windowID: "atc-newroute")
    let sidebar = fixture("arc-sidebar-synthetic.json")
    let snapshot = try await atcValue { adapter.open(path: directory.appendingPathComponent("newroute.sqlite").path, json: { sidebar }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    let airTraffic = AirTrafficModel(adapter: adapter)
    let model = SettingsModel(snapshot: snapshot, adapter: adapter, publish: { _ in }, resetWidth: {}, keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: airTraffic)
    try await atcValue { airTraffic.load(completion: $0) }
    // The default lands at space-home, which rides in the named profile; the pane shows
    // space-work, the built-in profile's space.
    try await atcValue { airTraffic.setDefault(.space("space-home"), littleWindowProfile: nil, completion: $0) }
    #expect(model.defaultChoice == .space("space-home"))
    // A default of the pane's own profile starts the rule there unchanged.
    try await atcValue { airTraffic.setDefault(.space("space-work"), littleWindowProfile: nil, completion: $0) }
    #expect(model.newRouteDestination() == Destination.space(.space("space-work")))
    // Another profile's default starts the rule at the most recent space instead, and the
    // rule the button adds is accepted (the banner stays empty).
    try await atcValue { airTraffic.setDefault(.space("space-home"), littleWindowProfile: nil, completion: $0) }
    #expect(model.defaultChoice == .space("space-home"))
    let destination = model.newRouteDestination()
    #expect(destination == .space(.mostRecent))
    try await atcValue { airTraffic.add(destination: destination, profile: model.airTrafficLittleWindowProfile, completion: $0) }
    #expect(airTraffic.error == nil)
    #expect(airTraffic.routing?.rules.first?.destination == .space(.mostRecent))
    _ = try await atcValue { adapter.shutdown(completion: $0) }
}

// A default that names a deleted space answers nil as a destination choice: New Route still
// starts somewhere usable — the shown profile's Little window, so the rule's Little window
// stays inside the profile the rule rides in.
@Test @MainActor
func aNewRouteWithADeletedSpaceDefaultStartsAtTheShownProfilesLittleWindow() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = WorkspaceAdapter(windowID: "atc-newroute-deleted")
    let sidebar = fixture("arc-sidebar-synthetic.json")
    let opened = try await atcValue { adapter.open(path: directory.appendingPathComponent("newroute-deleted.sqlite").path, json: { sidebar }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    let airTraffic = AirTrafficModel(adapter: adapter)
    // The pane shows the named profile's space: the rule the button adds rides in it.
    let shown = WorkspaceSnapshot(archive: opened.archive, shownSpaceId: "space-home", selectedId: opened.selectedId, spaces: opened.spaces)
    let model = SettingsModel(snapshot: shown, adapter: adapter, publish: { _ in }, resetWidth: {}, keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: airTraffic)
    try await atcValue { airTraffic.load(completion: $0) }
    #expect(model.airTrafficLittleWindowProfile == .named("Profile 1"))
    // The default names space-work, which is then deleted under the open pane.
    try await atcValue { airTraffic.setDefault(.space("space-work"), littleWindowProfile: nil, completion: $0) }
    model.requestDelete("space-work")
    model.confirmDelete()
    try await waitUntil { airTraffic.deletedSpaceIds == ["space-work"] }
    #expect(model.defaultChoice.isDeletedSpace)
    #expect(model.newRouteDestination() == Destination.littleWindow(.named("Profile 1")))
    // The rule the button adds is accepted and its Little window keeps the rule's profile.
    try await atcValue { airTraffic.add(destination: model.newRouteDestination(), profile: model.airTrafficLittleWindowProfile, completion: $0) }
    #expect(airTraffic.error == nil)
    #expect(airTraffic.routing?.rules.first?.destination == Destination.littleWindow(.named("Profile 1")))
    _ = try await atcValue { adapter.shutdown(completion: $0) }
}
