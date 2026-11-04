import AppKit
import AraratKit

/// The Air Traffic Control pane's model: the rules in match order, the default
/// destination, and the test field's answer. Everything the user changes goes through the core
/// (the same ops the App's other edits write), so a reopen reads the pane's own state back; the
/// matcher, order semantics and persistence all live in Rust. The row editing flow (one
/// two-line route per row, the destination menu with a Little Window entry, New Route) is
/// reused from Cra's MIT `Sources/Cra/UI/Settings/AirTrafficControlView.swift`.
@MainActor
public final class AirTrafficModel: ObservableObject {
    /// The store's routing (rules in order plus the default), nil until it has answered once.
    @Published public private(set) var routing: Routing?
    @Published public private(set) var error: String?
    /// What the test field typed and what the core routed it to.
    @Published public private(set) var testAnswer: TestAnswer?

    public struct TestAnswer: Equatable {
        public let url: String
        public let decision: RoutingDecision
    }

    private let adapter: WorkspaceAdapter

    public init(adapter: WorkspaceAdapter) { self.adapter = adapter }

    public func load(completion: @escaping WorkspaceAdapter.Completion<Void> = { _ in }) {
        adapter.routing { [weak self] in self?.receive($0, completion: completion) }
    }

    /// Adds an empty rule: `contains` with no text yet (an empty condition matches nothing,
    /// the same way Arc's fresh route behaves) and the destination reached on the pane.
    public func add(destination: Destination, completion: @escaping WorkspaceAdapter.Completion<Void> = { _ in }) {
        let rule = Rule(id: UUID().uuidString,
                        conditions: [UrlCondition(style: .contains, text: "")],
                        destination: destination)
        adapter.addRule(rule) { [weak self] in self?.receive($0, completion: completion) }
    }

    /// Rewrites one rule's first condition (the style and text a row edits) and keeps the rest
    /// of its conditions and its destination: an Arc rule is imported whole (a condition per
    /// `sourceComponents` entry), and one menu pick must not delete what it brought.
    public func editCondition(_ id: String, style: MatchStyle, text: String, completion: @escaping WorkspaceAdapter.Completion<Void> = { _ in }) {
        guard let routing, let rule = routing.rules.first(where: { $0.id == id }) else {
            return completion(.failure(CoreError.Edit(message: "unknown rule \(id)")))
        }
        var conditions = rule.conditions
        let condition = UrlCondition(style: style, text: text)
        if conditions.isEmpty { conditions = [condition] } else { conditions[0] = condition }
        adapter.editRule(Rule(id: id, conditions: conditions, destination: rule.destination)) { [weak self] in
            self?.receive($0, completion: completion)
        }
    }

    /// Moves one rule to another destination and keeps every condition. A Little-window pick
    /// on a rule whose destination is already a Little window keeps that rule's own profile —
    /// the pane's Little Window choice means "this rule's Little window as imported"; a fresh
    /// pick (from any other destination) writes `littleWindowProfile`, the shown space's, the
    /// way the import takes the first space's when the file carries no profile.
    public func editDestination(_ id: String, choice: DestinationChoice, littleWindowProfile: Profile?, completion: @escaping WorkspaceAdapter.Completion<Void> = { _ in }) {
        guard let routing, let rule = routing.rules.first(where: { $0.id == id }) else {
            return completion(.failure(CoreError.Edit(message: "unknown rule \(id)")))
        }
        guard let destination = Self.destination(for: choice, from: rule.destination, littleWindowProfile: littleWindowProfile) else {
            return completion(.failure(CoreError.Edit(message: "the destination menu answered nothing")))
        }
        adapter.editRule(Rule(id: id, conditions: rule.conditions, destination: destination)) { [weak self] in
            self?.receive($0, completion: completion)
        }
    }

    private static func destination(for choice: DestinationChoice, from current: Destination, littleWindowProfile: Profile?) -> Destination? {
        var destination = choice.destination(littleWindowProfile: littleWindowProfile)
        if case .littleWindow = choice, case .littleWindow(let imported) = current { destination = .littleWindow(imported) }
        return destination
    }

    public func delete(_ id: String, completion: @escaping WorkspaceAdapter.Completion<Void> = { _ in }) {
        adapter.deleteRule(id: id) { [weak self] in self?.receive($0, completion: completion) }
    }

    /// A drop target row becomes the position the rule takes: the drag displaces that row (the
    /// rule takes the target's slot, the target keeps the other side), the same reading the
    /// Spaces pane's drop has. The core counts the index in the list without the rule, and the
    /// slot number answers both directions unchanged. Tests feed reorders through here, never
    /// a real drag.
    public func move(_ id: String, to target: Int, completion: @escaping WorkspaceAdapter.Completion<Void> = { _ in }) {
        guard let routing, routing.rules.indices.contains(target),
              let current = routing.rules.firstIndex(where: { $0.id == id }) else {
            return completion(.failure(CoreError.Edit(message: "rule \(id) is not among the current rules")))
        }
        if current == target { return completion(.success(())) }
        adapter.moveRule(id: id, to: target) { [weak self] in self?.receive($0, completion: completion) }
    }

    /// Picking the built-in default (the Little window) back reaches the core as a reset: the
    /// store deletes the saved default (a tombstone) instead of restating the built-in value.
    public func setDefault(_ choice: DestinationChoice, littleWindowProfile: Profile?, completion: @escaping WorkspaceAdapter.Completion<Void> = { _ in }) {
        guard let destination = choice.destination(littleWindowProfile: littleWindowProfile) else {
            return completion(.failure(CoreError.Edit(message: "the destination menu answered nothing")))
        }
        adapter.setDefaultDestination(destination) { [weak self] in self?.receive($0, completion: completion) }
    }

    /// Asks the core where a link goes now; the pane shows the answer under the field. The url
    /// is trimmed once here: the answer is stored against the same string the label compares
    /// with, so spaces around the text do not hide it again.
    public func decide(_ url: String, completion: @escaping WorkspaceAdapter.Completion<Void> = { _ in }) {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        adapter.route(url: url) { [weak self] in self?.receive($0, url: url, completion: completion) }
    }

    private func receive(_ result: Result<RoutingDecision, Error>, url: String, completion: WorkspaceAdapter.Completion<Void>) {
        switch result {
        case .success(let decision):
            // This is a query, not an edit: clearing `error` here would let the test field's
            // keystrokes hide a refused edit's banner (the pane reads the same `error`).
            testAnswer = TestAnswer(url: url, decision: decision)
            completion(.success(()))
        case .failure(let failure):
            error = Self.errorText(failure)
            completion(.failure(failure))
        }
    }

    private func receive(_ result: Result<Routing, Error>, completion: WorkspaceAdapter.Completion<Void>) {
        switch result {
        case .success(let routing):
            error = nil
            self.routing = routing
            completion(.success(()))
        case .failure(let failure):
            error = Self.errorText(failure)
            completion(.failure(failure))
        }
    }

    private static func errorText(_ error: Error) -> String {
        if let core = error as? CoreError {
            switch core {
            case .Edit(let message), .Import(let message), .Store(let message): return message
            }
        }
        return error.localizedDescription
    }
}

/// What the destination menus can pick: the most recent space, one of the workspace's spaces,
/// the Little window, and one disabled "Deleted space" item per lost space id a destination
/// (a rule's or the default's) still names. The Little window carries no payload: the menu
/// item is one tag whatever profile a destination names, and a pick writes the pane's own
/// Little window (the shown space's profile).
public enum DestinationChoice: Hashable, Sendable {
    case mostRecent
    case space(String)
    case littleWindow
    /// A destination naming a space the workspace no longer has. The menu shows it as one
    /// disabled "Deleted space" item, selected, instead of silently reading Most Recent
    /// Space; picking another destination replaces it. The id stays in
    /// the tag so the picker matches the selection, and an untouched row keeps its
    /// destination unrewritten.
    case deletedSpace(String)

    public static let littleWindowChoice = Self.littleWindow

    public init(_ destination: Destination?) {
        switch destination {
        case .space(.mostRecent): self = .mostRecent
        case .space(.space(let id)): self = .space(id)
        case .littleWindow: self = .littleWindow
        default: self = Self.littleWindowChoice
        }
    }
    /// A space the menu's spaces list no longer carries reads as the deleted-space choice
    /// (its id is kept in the tag above, so the untouched row is not rewritten).
    public init(_ destination: Destination?, spaces: [SpaceSnapshot]) {
        self.init(destination)
        if case .space(let id) = self, !spaces.contains(where: { $0.id == id }) { self = .deletedSpace(id) }
    }

    /// The destination a pick writes. A fresh Little-window pick uses the Little window of the
    /// profile handed in (the shown space's, as `AirTrafficModel` documents); without one it
    /// keeps the built-in default profile. The deleted-space item is disabled, so a pick never
    /// carries it; nil reads as "the destination menu answered nothing".
    public func destination(littleWindowProfile: Profile?) -> Destination? {
        switch self {
        case .mostRecent: return .space(.mostRecent)
        case .space(let id): return .space(.space(id))
        case .littleWindow: return littleWindowProfile.map { Destination.littleWindow($0) } ?? Destination.littleWindow(.`default`)
        case .deletedSpace: return nil
        }
    }
    /// Whether the choice is the disabled "Deleted space" item: the menus separate it from
    /// the pickable tags (`SettingsWindow`'s `pickerContext`).
    public var isDeletedSpace: Bool {
        if case .deletedSpace = self { return true }
        return false
    }
    /// The tags the destination menus offer, in menu order (`SettingsWindow`'s
    /// `pickerContext` is built from this, so the tag-coverage test reads the real menu):
    /// one disabled "Deleted space" item per lost space id the section's destinations name,
    /// then the most recent space, each workspace space, and the one Little Window entry
    /// last, after the divider the picker draws.
    public static func menuTags(spaces: [SpaceSnapshot], deletedSpaceIds: [String] = []) -> [DestinationChoice] {
        deletedSpaceIds.map { .deletedSpace($0) } + [.mostRecent] + spaces.map { .space($0.id) } + [.littleWindow]
    }

    /// A tag's title in the destination menus: the space's name for a space tag, the plain
    /// words otherwise (`destinationLabel` repeats them in the test field's sentence case).
    func menuTitle(spaces: [SpaceSnapshot]) -> String {
        switch self {
        case .mostRecent: return "Most Recent Space"
        case .space(let id): return spaces.first { $0.id == id }?.title ?? id
        case .littleWindow: return "Little Window"
        case .deletedSpace: return "Deleted space"
        }
    }
}

extension AirTrafficModel {
    /// Space ids the routing's destinations (every rule's and the default's) name that the
    /// workspace does not have: the destination menus build their disabled "Deleted space"
    /// items from this, so only the ids this pane's own destinations lost appear.
    public func deletedSpaceIds(spaces: [SpaceSnapshot]) -> [String] {
        var destinations = routing?.rules.map(\.destination) ?? []
        if let routing { destinations.append(routing.default) }
        var ids: [String] = []
        for destination in destinations {
            if case .space(.space(let id)) = destination, !spaces.contains(where: { $0.id == id }), !ids.contains(id) {
                ids.append(id)
            }
        }
        return ids
    }
}

extension AirTrafficModel {
    /// The one-line answer the test field shows, in plain words about the rule (or the default)
    /// and where it opens. `decision` is the core's route answer; `rules` is how the pane reads
    /// a rule's text back out.
    public static func answerLabel(url: String, decision: RoutingDecision, rules: [Rule], spaces: [SpaceSnapshot]) -> String {
        let place = destinationLabel(decision.destination, spaces: spaces)
        let rule = decision.ruleId.flatMap { id in rules.first { $0.id == id } }
        let url = answerURL(url)
        if let rule, let text = rule.conditions.map(\.text).first(where: { !$0.isEmpty }) {
            return "\(url) → route “\(text)” opens it in \(place)"
        }
        if let rule, let index = rules.firstIndex(where: { $0.id == rule.id }) {
            return "\(url) → route \(index + 1) opens it in \(place)"
        }
        return "\(url) → the default opens it in \(place)"
    }

    static func answerURL(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "An empty link" }
        return "“\(trimmed)”"
    }

    static func destinationLabel(_ destination: Destination, spaces: [SpaceSnapshot]) -> String {
        switch destination {
        case .space(.mostRecent): return "the most recent space"
        case .space(.space(let id)):
            if let space = spaces.first(where: { $0.id == id }) { return "space \(space.title)" }
            return "space \(id)"
        case .littleWindow(_): return "the Little window"
        }
    }
}
