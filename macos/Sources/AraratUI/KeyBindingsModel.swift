import AppKit
import AraratKit
import SwiftUI

@MainActor
public final class KeyBindingsModel: ObservableObject {
    /// Recorder state for one command; candidate and holder stay until a confirmed take-over.
    /// The flow (Press keys…, Esc cancels, ⌫ removes, a conflicting key shows the holder and a second
    /// press takes it) is reused from Cra's MIT `Sources/Cra/UI/Settings/ShortcutsPane.swift`.
    public struct Recording: Equatable {
        public let command: String
        public let candidate: KeyCombination?
        public let holder: String?
    }
    @Published public private(set) var bindings = defaultKeyBindings()
    @Published public private(set) var error: String?
    @Published public private(set) var errorCommand: String?
    @Published public private(set) var recording: Recording?
    public var onChange: (() -> Void)?
    private let adapter: WorkspaceAdapter
    private let menus = NSHashTable<NSMenu>.weakObjects()
    private let mainMenu: () -> NSMenu?
    private let nonMenuShortcutHolder: (NSEvent) -> String?

    public init(
        adapter: WorkspaceAdapter,
        mainMenu: @escaping () -> NSMenu? = { NSApp?.mainMenu },
        nonMenuShortcutHolder: @escaping (NSEvent) -> String? = { _ in nil }
    ) {
        self.adapter = adapter
        self.mainMenu = mainMenu
        self.nonMenuShortcutHolder = nonMenuShortcutHolder
    }

    public func register(_ menu: NSMenu) {
        menus.add(menu)
        Self.apply(bindings, to: menu)
    }

    public static func setCoreMenuShortcut(_ key: KeyCombination?, on item: NSMenuItem) {
        var modifiers: NSEvent.ModifierFlags = []
        if key?.command == true { modifiers.insert(.command) }
        if key?.control == true { modifiers.insert(.control) }
        if key?.option == true { modifiers.insert(.option) }
        let character = key?.key ?? ""
        let upper = character.uppercased()
        let shiftedLetter = key?.shift == true && character != upper && upper.count == 1
        if key?.shift == true && !shiftedLetter { modifiers.insert(.shift) }
        item.keyEquivalent = shiftedLetter ? upper : character
        item.keyEquivalentModifierMask = modifiers
    }

    public static func apply(_ bindings: [KeyBinding], to menu: NSMenu) {
        var shortcuts: [(NSMenuItem, KeyCombination?)] = []
        func collectShortcuts(in menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { collectShortcuts(in: submenu) }
                guard let id = chromiumAliasCommand(for: item) ?? item.identifier?.rawValue,
                      let row = bindings.first(where: { $0.command == id }) else { continue }
                shortcuts.append((item, row.key))
            }
        }
        collectShortcuts(in: menu)
        // AppKit can reject an equivalent that another item still holds during a takeover or reset.
        for (item, _) in shortcuts { item.keyEquivalent = "" }
        for (item, key) in shortcuts {
            setCoreMenuShortcut(key, on: item)
        }
    }

    private static func chromiumAliasCommand(for item: NSMenuItem) -> String? {
        if item.identifier?.rawValue == "close_tab" { return "close_tab" }
        return switch item.tag {
        case 34014: "new_tab" // IDC_NEW_TAB
        case 34015: "close_tab" // IDC_CLOSE_TAB
        case 34031: "quit" // IDC_EXIT
        case 39001: "edit_url" // IDC_FOCUS_LOCATION
        default: nil
        }
    }

    @discardableResult
    public static func clearCollisions(_ bindings: [KeyBinding], in menu: NSMenu) -> [String: NSMenuItem] {
        var collisions: [String: NSMenuItem] = [:]
        for item in menu.items {
            if let submenu = item.submenu { collisions.merge(clearCollisions(bindings, in: submenu)) { first, _ in first } }
            for binding in bindings {
                guard let key = binding.key else { continue }
                var flags: NSEvent.ModifierFlags = []
                if key.command { flags.insert(.command) }
                if key.control { flags.insert(.control) }
                if key.option { flags.insert(.option) }
                if key.shift { flags.insert(.shift) }
                var itemFlags = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                let equivalent = item.keyEquivalent
                if equivalent != equivalent.lowercased() && equivalent == equivalent.uppercased() { itemFlags.insert(.shift) }
                if equivalent.lowercased() == key.key.lowercased(), itemFlags == flags {
                    collisions[binding.command] = item
                    item.keyEquivalent = ""
                }
            }
        }
        return collisions
    }

    public func load(completion: @escaping WorkspaceAdapter.Completion<Void>) {
        adapter.keyBindings { [weak self] result in self?.receive(result, completion: completion) }
    }

    public func set(command: String, key: KeyCombination?, completion: @escaping WorkspaceAdapter.Completion<Void> = { _ in }) {
        adapter.setKeyBinding(command: command, key: key) { [weak self] result in
            self?.receive(result, command: command, completion: completion)
        }
    }

    public func reset(command: String, completion: @escaping WorkspaceAdapter.Completion<Void> = { _ in }) {
        adapter.resetKeyBinding(command: command) { [weak self] result in self?.receive(result, command: command, completion: completion) }
    }

    public func resetAll(completion: @escaping WorkspaceAdapter.Completion<Void> = { _ in }) {
        adapter.resetAllKeyBindings { [weak self] result in self?.receive(result, completion: completion) }
    }

    public func binding(command: String) -> KeyBinding? { bindings.first { $0.command == command } }

    public func toggleRecording(_ command: String) {
        if recording?.command == command { recording = nil; return }
        clearError()
        recording = Recording(command: command, candidate: nil, holder: nil)
    }

    public func cancelRecording() { recording = nil }

    public func clearError() {
        error = nil
        errorCommand = nil
    }

    /// Processes one key event for the recording row. Returns true when the event was consumed
    /// (so it neither reaches the menus nor moves on), false when nothing is being recorded.
    public func handle(_ event: NSEvent) -> Bool {
        guard let command = recording?.command else { return false }
        if event.isARepeat { return true }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let anchored = modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option)
        switch event.keyCode {
        case 53 where !anchored: recording = nil; return true // Esc cancels without touching the table.
        case 51 where !anchored, 117 where !anchored: // ⌫ and forward-delete clear the row to none.
            set(command: command, key: nil)
            recording = nil
            return true
        default: break
        }
        // ⇧⌘3/4/5 (screenshots) are reserved by position: key codes 20, 21, 23 are the keys that
        // print 3/4/5 on every layout, so layouts whose characters are " ' ( (AZERTY) cannot slip
        // past the core's character-based reserved list.
        if modifiers.contains(.command), modifiers.contains(.shift), !modifiers.contains(.control), !modifiers.contains(.option), [20, 21, 23].contains(Int(event.keyCode)) {
            errorCommand = command
            error = "this shortcut is reserved by the system"
            recording = nil
            return true
        }
        let menuCharacters = event.charactersIgnoringModifiers
        // Stripping modifiers can replace AppKit function-key characters with C0 control characters.
        let characters = switch menuCharacters?.unicodeScalars.first?.value {
        case let value? where (0xF700...0xF8FF).contains(value): menuCharacters
        default: event.characters(byApplyingModifiers: [])
        }
        guard let characters, characters.unicodeScalars.count == 1, let scalar = characters.unicodeScalars.first else { return true }
        let candidate = KeyCombination(key: String(scalar), command: modifiers.contains(.command), control: modifiers.contains(.control), option: modifiers.contains(.option), shift: modifiers.contains(.shift))
        let coreHolder = bindings.first { $0.key == candidate && !$0.conflicting }
        let checkNonMenu = coreHolder == nil && candidate != binding(command: command)?.defaultKey
        if let holder = menuShortcutHolder(in: mainMenu(), event: event, candidate: candidate, command: command, coreHolder: coreHolder?.command)
            ?? (checkNonMenu ? nonMenuShortcutHolder(event) : nil) {
            errorCommand = command
            error = String(localized: "This shortcut is used by \(holder).")
            recording = nil
            return true
        }
        if let holder = coreHolder, holder.command != command {
            if recording?.candidate == candidate {
                set(command: command, key: candidate)
                recording = nil
            } else {
                recording = Recording(command: command, candidate: candidate, holder: holder.title)
            }
        } else {
            set(command: command, key: candidate)
            recording = nil
        }
        return true
    }

    private func menuShortcutHolder(in menu: NSMenu?, event: NSEvent, candidate: KeyCombination, command: String, coreHolder: String?) -> String? {
        guard let menu, let key = event.charactersIgnoringModifiers else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let shifted = candidate.shift && key != candidate.key
        for item in menu.items {
            if let submenu = item.submenu {
                if let holder = menuShortcutHolder(in: submenu, event: event, candidate: candidate, command: command, coreHolder: coreHolder) { return holder }
                continue
            }
            let alias = Self.chromiumAliasCommand(for: item)
            if alias == nil, let id = item.identifier?.rawValue, binding(command: id) != nil { continue }
            let equivalent = item.keyEquivalent
            guard !equivalent.isEmpty else { continue }
            let itemModifiers = item.keyEquivalentModifierMask
            let matches = equivalent == key && (itemModifiers == modifiers || (shifted && itemModifiers == modifiers.subtracting(.shift)))
            let deleteMatches = (key == "\u{7F}" && equivalent == "\u{08}") || (key == "\u{F728}" && equivalent == "\u{7F}")
            guard matches || (deleteMatches && itemModifiers == modifiers) else { continue }
            // The recorder also recognizes Chromium's contextual ⌘W Close Window item.
            let contextualAlias = item.tag == 34012 && key == "w" && modifiers == .command // IDC_CLOSE_WINDOW
                ? "close_tab" : alias
            guard let contextualAlias, contextualAlias == command || contextualAlias == coreHolder else { return item.title }
        }
        return nil
    }

    private func receive(_ result: Result<[KeyBinding], Error>, command: String? = nil, completion: WorkspaceAdapter.Completion<Void>) {
        switch result {
        case .success(let bindings):
            error = nil
            errorCommand = nil
            self.bindings = bindings
            for menu in menus.allObjects { Self.apply(bindings, to: menu) }
            onChange?()
            completion(.success(()))
        case .failure(let error):
            errorCommand = command
            if let core = error as? CoreError {
                switch core {
                case .Edit(let message), .Import(let message), .Store(let message), .Live(let message): self.error = message
                }
            } else { self.error = error.localizedDescription }
            completion(.failure(error))
        }
    }
}
