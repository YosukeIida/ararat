import AppKit
import AraratKit

/// The Air Traffic Control pane's model: the rules in match order, the default
/// destination, and the test field's answer. Persisted changes go through the core
/// (the same ops the App's other edits write), so a reopen reads the pane's own state back; the
/// matcher, order semantics and persistence all live in Rust. The row editing flow (one
/// two-line route per row, the destination menu with a Little Window entry, New Route) is
/// reused from Cra's MIT `Sources/Cra/UI/Settings/AirTrafficControlView.swift`.
@MainActor
public final class AirTrafficModel: ObservableObject {
    /// Why not expose only store snapshots: local drafts and pending edits must stay visible.
    @Published public private(set) var routing: Routing?
    @Published public private(set) var error: String?
    /// The space ids the core answers as gone for this pane's destinations (rules and the
    /// default): the disabled "Deleted space" menu items build from it, and a row whose
    /// destination names one reads as that choice.
    @Published public private(set) var deletedSpaces: Set<String> = []
    /// What the test field typed and what the core routed it to.
    @Published public private(set) var testAnswer: TestAnswer?

    /// The core answer as the menus read it: the lost ids in a stable order.
    public var deletedSpaceIds: [String] { deletedSpaces.sorted() }

    public struct TestAnswer: Equatable {
        public let url: String
        public let decision: RoutingDecision
    }

    private let adapter: WorkspaceAdapter
    private var storedRouting: Routing?
    private var drafts: [Rule] = []
    private var pendingRules: [String: (rule: Rule, token: UUID, adding: Bool)] = [:]

    public init(adapter: WorkspaceAdapter) { self.adapter = adapter }

    public func load(completion: @escaping WorkspaceAdapter.Completion<Void> = { _ in }) {
        adapter.routing { [weak self] in self?.receive($0, completion: completion) }
    }

    public func add(destination: Destination, profile: Profile?, completion: @escaping WorkspaceAdapter.Completion<Void> = { _ in }) {
        let rule = Rule(id: UUID().uuidString,
                        conditions: [UrlCondition(style: .contains, text: "")],
                        destination: destination,
                        profile: profile ?? .`default`)
        drafts.append(rule)
        error = nil
        publishRouting()
        completion(.success(()))
    }

    /// Rewrites one rule's first condition (the style and text a row edits) and keeps the rest
    /// of its conditions, its destination and its profile: an Arc rule is imported whole (a
    /// condition per `sourceComponents` entry), and one menu pick must not delete what it
    /// brought.
    public func editCondition(_ id: String, style: MatchStyle, text: String, completion: @escaping WorkspaceAdapter.Completion<Void> = { _ in }) {
        guard let routing, let rule = routing.rules.first(where: { $0.id == id }) else {
            return completion(.failure(CoreError.Edit(message: "unknown rule \(id)")))
        }
        var conditions = rule.conditions
        let condition = UrlCondition(style: style, text: text)
        if conditions.isEmpty { conditions = [condition] } else { conditions[0] = condition }
        save(Rule(id: id, conditions: conditions, destination: rule.destination, profile: rule.profile), completion: completion)
    }

    func editStyle(_ id: String, style: MatchStyle) {
        guard let rule = routing?.rules.first(where: { $0.id == id }) else { return }
        editCondition(id, style: style, text: rule.conditions.first?.text ?? "")
    }

    func editText(_ id: String, text: String) {
        guard let rule = routing?.rules.first(where: { $0.id == id }) else { return }
        editCondition(id, style: rule.conditions.first?.style ?? .contains, text: text)
    }

    /// Moves one rule to another destination and keeps every condition and the rule's own
    /// profile. A Little-window pick rides the rule's own profile — the shown space's stays
    /// for the default destination and New Route, which name no rule — and a pick on a rule
    /// whose destination is already a Little window keeps the profile it was imported with.
    public func editDestination(_ id: String, choice: DestinationChoice, completion: @escaping WorkspaceAdapter.Completion<Void> = { _ in }) {
        guard let routing, let rule = routing.rules.first(where: { $0.id == id }) else {
            return completion(.failure(CoreError.Edit(message: "unknown rule \(id)")))
        }
        guard let destination = Self.destination(for: choice, from: rule.destination, littleWindowProfile: rule.profile) else {
            return completion(.failure(CoreError.Edit(message: "the destination menu answered nothing")))
        }
        save(Rule(id: id, conditions: rule.conditions, destination: destination, profile: rule.profile), completion: completion)
    }

    private func save(_ rule: Rule, completion: @escaping WorkspaceAdapter.Completion<Void>) {
        let draftIndex = drafts.firstIndex { $0.id == rule.id }
        let empty = rule.conditions.first?.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).isEmpty ?? true
        if let draftIndex {
            drafts[draftIndex] = rule
            if empty {
                error = nil
                publishRouting()
                return completion(.success(()))
            }
            drafts.remove(at: draftIndex)
        } else if empty {
            return completion(.success(()))
        }
        let token = UUID()
        let adding = draftIndex != nil || pendingRules[rule.id]?.adding == true
        pendingRules[rule.id] = (rule, token, adding)
        publishRouting()
        let reply: WorkspaceAdapter.Completion<Routing> = { [weak self] result in
            guard let self else { return }
            if self.pendingRules[rule.id]?.token == token {
                if case .failure = result, adding,
                   self.storedRouting?.rules.contains(where: { $0.id == rule.id }) != true { self.drafts.append(rule) }
                self.pendingRules.removeValue(forKey: rule.id)
            }
            self.receive(result, completion: completion)
        }
        if draftIndex != nil { adapter.addRule(rule, completion: reply) }
        else { adapter.editRule(rule, completion: reply) }
    }

    private func publishRouting() {
        var next = storedRouting ?? Routing(rules: [], default: .littleWindow(.default))
        next.rules = next.rules.map { pendingRules[$0.id]?.rule ?? $0 }
        let storedIDs = Set(next.rules.map(\.id))
        // Why not drop pending additions: an older reply may arrive before their add completes.
        next.rules += routing?.rules.compactMap { storedIDs.contains($0.id) ? nil : pendingRules[$0.id]?.rule } ?? []
        next.rules += drafts
        routing = next
    }

    /// The destination a pick writes: a fresh Little-window pick pairs the profile handed
    /// in (a rule edit hands the rule's own), and a pick on a destination that is already a
    /// Little window keeps the imported profile instead.
    private static func destination(for choice: DestinationChoice, from current: Destination, littleWindowProfile: Profile?) -> Destination? {
        var destination = choice.destination(littleWindowProfile: littleWindowProfile)
        if case .littleWindow = choice, case .littleWindow(let imported) = current { destination = .littleWindow(imported) }
        return destination
    }

    public func delete(_ id: String, completion: @escaping WorkspaceAdapter.Completion<Void> = { _ in }) {
        if drafts.contains(where: { $0.id == id }) {
            drafts.removeAll { $0.id == id }
            publishRouting()
            return completion(.success(()))
        }
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
        guard !drafts.contains(where: { $0.id == id }) else {
            return completion(.failure(CoreError.Edit(message: "enter a URL before moving this route")))
        }
        let position = min(target, max(0, routing.rules.count - drafts.count - 1))
        adapter.moveRule(id: id, to: position) { [weak self] in self?.receive($0, completion: completion) }
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

    private func receive(_ result: Result<Routing, Error>, completion: @escaping WorkspaceAdapter.Completion<Void>) {
        // The routing answer changes which destinations are lost, so the deleted-space set
        // rides the same turn: the completion answers with the set already in, or the
        // refusal stands, and a failed reload is the banner the pane shows.
        switch result {
        case .success(let routing):
            error = nil
            storedRouting = routing
            publishRouting()
            reloadDeletedSpaces(completion: completion)
        case .failure(let failure):
            error = Self.errorText(failure)
            publishRouting()
            completion(.failure(failure))
        }
    }

    /// The core's deleted-space answer for the destinations the pane shows: the "Deleted
    /// space" menu items read it. A completion given here answers with the set already in
    /// (or the reload's refusal), so a caller reading right after this reads fresh.
    /// `SettingsModel.update` calls it again when the spaces change under an open window,
    /// so a deletion reaches the set without a full routing reload.
    func reloadDeletedSpaces(completion: WorkspaceAdapter.Completion<Void>? = nil) {
        adapter.deletedSpaces { [weak self] in
            guard let self else {
                completion?(.failure(CoreError.Store(message: "the workspace behind the pane is gone")))
                return
            }
            switch $0 {
            case .success(let lost):
                self.deletedSpaces = Set(lost.map(\.spaceId))
                completion?(.success(()))
            case .failure(let failure):
                self.error = Self.errorText(failure)
                completion?(.failure(failure))
            }
        }
    }

    private static func errorText(_ error: Error) -> String {
        if let core = error as? CoreError {
            switch core {
            case .Edit(let message), .Import(let message), .Store(let message), .Live(let message): return message
            }
        }
        return error.localizedDescription
    }
}

/// What the destination menus can pick: the most recent space, one of the workspace's spaces,
/// the Little window, and one disabled "Deleted space" item per lost space id a destination
/// (a rule's or the default's) still names. The Little window carries no payload: the menu
/// item is one tag whatever profile a destination names, and a pick rides the edited rule's
/// own profile, the shown space's where no rule is named (the default and New Route).
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
    /// A destination among the ones the core answered as gone (the model's `deletedSpaces`)
    /// reads as the deleted-space choice (its id is kept in the tag above, so the untouched
    /// row is not rewritten).
    public init(_ destination: Destination?, deletedSpaces: Set<String>) {
        self.init(destination)
        if case .space(let id) = self, deletedSpaces.contains(id) { self = .deletedSpace(id) }
    }

    /// The destination a pick writes. A fresh Little-window pick uses the Little window of
    /// the profile handed in — a rule edit hands the rule's own, the shown space's covers
    /// the default and New Route — and without one it keeps the built-in default profile.
    /// The deleted-space item is disabled, so a pick never carries it; nil reads as "the
    /// destination menu answered nothing".
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
    /// The one-line answer the test field shows, in plain words about the rule (or the
    /// default) and where it opens. `decision` is the core's route answer; `rules` is how
    /// the pane reads a rule's text back out.
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
