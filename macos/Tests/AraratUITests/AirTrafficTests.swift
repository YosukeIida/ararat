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

    try await atcValue { model.add(destination: .space(.space("space-work")), completion: $0) }
    try await atcValue { model.add(destination: .littleWindow(.default), completion: $0) }
    var rules = try #require(model.routing?.rules)
    let a = rules[0].id
    let b = rules[1].id
    #expect(a != b)

    // Edit: the condition text and destination are what the core stores back.
    try await atcValue { model.editCondition(a, style: .contains, text: "meet.google.com", completion: $0) }
    try await atcValue { model.editDestination(a, choice: .mostRecent, littleWindowProfile: nil, completion: $0) }
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
    #expect(model.testAnswer?.decision.destination == Destination.space(.mostRecent))

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
    let rules = [Rule(id: "meet", conditions: [UrlCondition(style: .contains, text: "meet.google.com")], destination: .space(.mostRecent))]
    let ruleAnswer = AirTrafficModel.answerLabel(url: "https://www.meet.google.com/x",
        decision: RoutingDecision(ruleId: "meet", destination: .space(.mostRecent)), rules: rules, spaces: [space])
    #expect(ruleAnswer == "“https://www.meet.google.com/x” → rule “meet.google.com” opens it in the most recent space")
    let defaultAnswer = AirTrafficModel.answerLabel(url: "https://other.example.org",
        decision: RoutingDecision(ruleId: nil, destination: .littleWindow(.default)), rules: rules, spaces: [space])
    #expect(defaultAnswer == "“https://other.example.org” → the default opens it in the Little window")
    #expect(AirTrafficModel.answerLabel(url: "  ", decision: RoutingDecision(ruleId: nil, destination: .space(.mostRecent)), rules: rules, spaces: [space]).hasPrefix("An empty link"))
    // A destination naming a lost space reads as the deleted-space choice (its menu shows a
    // disabled "Deleted space" item, selected), and the space coming back reads as it again
    // in the model (the untouched row is not rewritten).
    let lost = Destination.space(.space("space-gone"))
    #expect(DestinationChoice(lost, spaces: [space]) == .deletedSpace("space-gone"))
    #expect(DestinationChoice(lost, spaces: [space, SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "space-gone", title: "Gone", icon: nil, look: nil, favorites: [], pinned: [], today: [])]) == .space("space-gone"))
    // A Little-window destination reads as the one choice whatever profile it names, and a
    // fresh pick writes the profile handed in (the shown space's); an imported rule keeps its
    // own profile through the model's editDestination.
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
    try await atcValue { airTraffic.add(destination: .space(.space("space-work")), completion: $0) }
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
    #expect(label == "“https://www.meet.google.com/x” → rule “meet.google.com” opens it in space Work")
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
        let choice = DestinationChoice(destination, spaces: [space])
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
    model.load()
    try await waitUntil { model.routing != nil }
    #expect(model.deletedSpaceIds(spaces: snapshot.spaces).isEmpty)
    // A rule at one space and the default at the other: nothing is lost yet.
    try await atcValue { model.add(destination: .space(.space("space-work")), completion: $0) }
    try await atcValue { model.setDefault(.space("space-home"), littleWindowProfile: nil, completion: $0) }
    #expect(model.deletedSpaceIds(spaces: snapshot.spaces).isEmpty)
    // The space the rule points at is deleted; the rule keeps its destination and the model
    // names the lost one (the default still names a living space).
    try await atcValue { adapter.deleteSpace(id: "space-work", completion: $0) }
    let after = try await atcValue { adapter.snapshot(completion: $0) }
    try await atcValue { model.load(completion: $0) }
    #expect(model.routing?.rules.first?.destination == Destination.space(.space("space-work")))
    #expect(model.routing?.default == Destination.space(.space("space-home")))
    #expect(model.deletedSpaceIds(spaces: after.spaces) == ["space-work"])
    #expect(DestinationChoice(model.routing?.rules.first?.destination, spaces: after.spaces) == .deletedSpace("space-work"))
    // The menu pickerContext builds carries one disabled item for that id and nothing else.
    let tags = DestinationChoice.menuTags(spaces: after.spaces, deletedSpaceIds: model.deletedSpaceIds(spaces: after.spaces))
    #expect(tags.filter(\.isDeletedSpace) == [.deletedSpace("space-work")])
    // Picking another destination replaces the deleted one, and no id is lost any more.
    let ruleId = try #require(model.routing?.rules.first?.id)
    try await atcValue { model.editDestination(ruleId, choice: .mostRecent, littleWindowProfile: nil, completion: $0) }
    #expect(model.routing?.rules.first?.destination == Destination.space(.mostRecent))
    #expect(model.deletedSpaceIds(spaces: after.spaces).isEmpty)
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
    try await atcValue { model.editDestination(imported.id, choice: .mostRecent, littleWindowProfile: nil, completion: $0) }
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

// A fresh Little Window pick writes the Little window of the shown space's profile, not the
// built-in default one: a workspace whose spaces live in a named profile cannot open the
// built-in default.
@Test @MainActor
func aFreshLittleWindowPickCarriesTheShownSpacesProfile() async throws {
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
    // memory); the imported Little-window rule keeps its own profile when re-picked.
    try await atcValue { model.setDefault(.littleWindow, littleWindowProfile: .named("Profile 1"), completion: $0) }
    #expect(model.routing?.default == Destination.littleWindow(.named("Profile 1")))
    let imported = try #require(model.routing?.rules.first { $0.id == "docs-little" })
    #expect(imported.destination == Destination.littleWindow(.default))
    try await atcValue { model.editDestination(imported.id, choice: .littleWindow, littleWindowProfile: .named("Profile 1"), completion: $0) }
    var rules = try #require(model.routing?.rules)
    #expect(rules.first { $0.id == imported.id }?.destination == Destination.littleWindow(.default))
    // A fresh pick on a rule from another destination writes the shown profile.
    try await atcValue { model.editDestination("meet", choice: .littleWindow, littleWindowProfile: .named("Profile 1"), completion: $0) }
    rules = try #require(model.routing?.rules)
    #expect(rules.first { $0.id == "meet" }?.destination == Destination.littleWindow(.named("Profile 1")))
    _ = try await atcValue { adapter.shutdown(completion: $0) }
}

// The pane's fresh Little-window pick names the shown space's own `Profile` from the FFI
// snapshot, not the display name mapped back: a named profile called "Default" would read
// as the built-in one.
@Test @MainActor
func theFreshLittleWindowPickNamesTheShownSpacesOwnProfile() {
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
    try await atcValue { airTraffic.add(destination: .space(.space("space-work")), completion: $0) }
    let id = try #require(airTraffic.routing?.rules.first?.id)
    // The row's URL field is the one the URL placeholder tags (the bridge shows placeholders,
    // not accessibility overrides).
    let rowField = { airTrafficDescendants(window.contentView!).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "URL" } }
    try await waitUntil { window.contentView?.layoutSubtreeIfNeeded(); return rowField() != nil }
    let field = try #require(rowField())
    // Two keystrokes: the store learns nothing until the commit (what Return fires).
    field.stringValue = "meet.google"
    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    field.stringValue = "meet.google.com"
    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    let afterTyping = try await atcValue { adapter.routing(completion: $0) }
    #expect(afterTyping.rules.first?.conditions == [UrlCondition(style: .contains, text: "")])
    // The commit lets the field's text through exactly once and is what the pane reads back.
    try await atcValue { airTraffic.editCondition(id, style: .contains, text: "meet.google.com", completion: $0) }
    let afterCommit = try await atcValue { adapter.routing(completion: $0) }
    #expect(afterCommit.rules.first?.conditions == [UrlCondition(style: .contains, text: "meet.google.com")])
    #expect(!window.isVisible)
    window.contentView = nil
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

// A destination naming a lost space reads as the deleted-space
// choice (the menu shows a disabled "Deleted space" item, selected, not Most Recent Space),
// the choice writes nothing while it is selected, and the id survives the workspace losing
// the space so an untouched row is not rewritten (the space coming back reads as it again).
@Test @MainActor
func aDestinationNamingALostSpaceReadsAsTheDeletedSpaceChoice() {
    let space = SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "space-work", title: "Work", icon: nil, look: nil, favorites: [], pinned: [], today: [])
    let lost = Destination.space(.space("space-gone"))
    #expect(DestinationChoice(lost, spaces: [space]) == .deletedSpace("space-gone"))
    #expect(DestinationChoice(lost, spaces: [space, SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "space-gone", title: "Gone", icon: nil, look: nil, favorites: [], pinned: [], today: [])]) == .space("space-gone"))
    // The disabled item writes nothing: a pick never carries it, so the menu "answered nothing".
    #expect(DestinationChoice.deletedSpace("space-gone").destination(littleWindowProfile: nil) == nil)
    #expect(DestinationChoice.deletedSpace("space-gone").menuTitle(spaces: [space]) == "Deleted space")
    #expect(DestinationChoice.deletedSpace("space-gone").isDeletedSpace)
    #expect(!DestinationChoice.mostRecent.isDeletedSpace)
}
