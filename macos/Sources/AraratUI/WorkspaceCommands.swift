import AppKit
import AraratKit

@MainActor
public protocol MenuCommandHost: AnyObject {
    /// The effective key bindings table the menu bar is built from.
    var menuCommandBindings: [KeyBinding] { get }
}

public enum WorkspaceCommands {
    public static func allowsPageCommand(_ responder: NSResponder?) -> Bool {
        !(responder is NSTextView) && !(responder is NSTextField)
    }

    /// A command rebound without Command must not fire while one of our own text fields (the
    /// rename field, the Create Space name, the settings search) has keyboard focus: the key
    /// types there instead. AppKit sinks the matching key equivalent at the menu pass even when
    /// the item is disabled by validation, and `NSMenuDelegate.menuHasKeyEquivalent` never ran
    /// on this macOS to let it through, so our windows hand the key to the field and return
    /// true from their own `performKeyEquivalent` pass.
    public static func yieldsToOwnField(_ bindings: [KeyBinding], event: NSEvent, in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder, !allowsPageCommand(responder) else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Keys with Command never yield: they cannot be typed into a field anyway.
        guard !flags.contains(.command) else { return false }
        return bindings.contains { binding in
            binding.key.map { matches($0, event: event) } ?? false
        }
    }

    public static func matches(_ key: KeyCombination, event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        guard key.command == flags.contains(.command),
              key.control == flags.contains(.control),
              key.option == flags.contains(.option),
              key.shift == flags.contains(.shift) else { return false }
        return event.characters(byApplyingModifiers: [])?.lowercased() == key.key.lowercased()
            || event.charactersIgnoringModifiers?.lowercased() == key.key.lowercased()
    }

    public static let showSpace = NSSelectorFromString("showSpace:")
}
