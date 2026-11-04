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
    /// on this macOS to let it through, so our windows return NO from their own
    /// `performKeyEquivalent` pass and hand the key to the field.
    public static func yieldsToOwnField(_ bindings: [KeyBinding], event: NSEvent, in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder, !allowsPageCommand(responder) else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Keys with Command never yield: they cannot be typed into a field anyway.
        guard !flags.contains(.command) else { return false }
        let characters = [event.charactersIgnoringModifiers, event.characters(byApplyingModifiers: [])]
            .compactMap { $0?.lowercased() }
        for binding in bindings {
            guard let key = binding.key, !key.command else { continue }
            guard key.control == flags.contains(.control),
                  key.option == flags.contains(.option),
                  key.shift == flags.contains(.shift) else { continue }
            if characters.contains(where: { $0 == key.key.lowercased() }) { return true }
        }
        return false
    }

    public static let showSpace = NSSelectorFromString("showSpace:")
}
