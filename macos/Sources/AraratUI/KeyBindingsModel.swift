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
    @Published public private(set) var recording: Recording?
    public var onChange: (() -> Void)?
    private let adapter: WorkspaceAdapter
    private let menus = NSHashTable<NSMenu>.weakObjects()

    public init(adapter: WorkspaceAdapter) { self.adapter = adapter }

    public func register(_ menu: NSMenu) {
        menus.add(menu)
        Self.apply(bindings, to: menu)
    }

    public static func apply(_ bindings: [KeyBinding], to menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu { apply(bindings, to: submenu) }
            guard let id = item.identifier?.rawValue, let row = bindings.first(where: { $0.command == id }) else { continue }
            item.keyEquivalent = row.key?.key ?? ""
            var modifiers: NSEvent.ModifierFlags = []
            if row.key?.command == true { modifiers.insert(.command) }
            if row.key?.control == true { modifiers.insert(.control) }
            if row.key?.option == true { modifiers.insert(.option) }
            if row.key?.shift == true { modifiers.insert(.shift) }
            item.keyEquivalentModifierMask = modifiers
        }
    }

    public func load(completion: @escaping WorkspaceAdapter.Completion<Void>) {
        adapter.keyBindings { [weak self] result in self?.receive(result, completion: completion) }
    }

    public func set(command: String, key: KeyCombination?, completion: @escaping WorkspaceAdapter.Completion<Void> = { _ in }) {
        adapter.setKeyBinding(command: command, key: key) { [weak self] result in
            self?.receive(result, completion: completion)
        }
    }

    public func reset(command: String, completion: @escaping WorkspaceAdapter.Completion<Void> = { _ in }) {
        adapter.resetKeyBinding(command: command) { [weak self] result in self?.receive(result, completion: completion) }
    }

    public func resetAll(completion: @escaping WorkspaceAdapter.Completion<Void> = { _ in }) {
        adapter.resetAllKeyBindings { [weak self] result in self?.receive(result, completion: completion) }
    }

    public func binding(command: String) -> KeyBinding? { bindings.first { $0.command == command } }

    public func toggleRecording(_ command: String) {
        if recording?.command == command { recording = nil; return }
        error = nil
        recording = Recording(command: command, candidate: nil, holder: nil)
    }

    public func cancelRecording() { recording = nil }

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
            error = "this shortcut is reserved by the system"
            recording = nil
            return true
        }
        guard let characters = event.characters(byApplyingModifiers: []), characters.unicodeScalars.count == 1, let scalar = characters.unicodeScalars.first else { return true }
        let candidate = KeyCombination(key: String(scalar), command: modifiers.contains(.command), control: modifiers.contains(.control), option: modifiers.contains(.option), shift: modifiers.contains(.shift))
        if let holder = bindings.first(where: { $0.key == candidate && $0.conflicting == false && $0.command != command }) {
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

    private func receive(_ result: Result<[KeyBinding], Error>, completion: WorkspaceAdapter.Completion<Void>) {
        switch result {
        case .success(let bindings):
            error = nil
            self.bindings = bindings
            for menu in menus.allObjects { Self.apply(bindings, to: menu) }
            onChange?()
            completion(.success(()))
        case .failure(let error):
            if let core = error as? CoreError {
                switch core {
                case .Edit(let message), .Import(let message), .Store(let message): self.error = message
                }
            } else { self.error = error.localizedDescription }
            completion(.failure(error))
        }
    }
}
