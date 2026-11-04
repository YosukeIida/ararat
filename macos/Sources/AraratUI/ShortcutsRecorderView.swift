import AppKit
import AraratKit
import SwiftUI

/// The recorder's NSView side: tests feed NSEvents straight into `keyDown`/`performKeyEquivalent`
/// (nothing is posted), and the mounted view takes first responder while a row records, so ⌘-keys
/// are captured before they reach the menus. The click-to-record flow is reused from Cra's MIT
/// `Sources/Cra/UI/Settings/ShortcutsPane.swift`.
@MainActor
public final class ShortcutsRecorderView: NSView {
    public weak var bindings: KeyBindingsModel?
    /// The command whose recording took first responder here; the take happens once per recording.
    var focusedCommand: String?

    override public var acceptsFirstResponder: Bool { true }
    override public var canBecomeKeyView: Bool { true }

    override public func keyDown(with event: NSEvent) { _ = bindings?.handle(event) }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard bindings?.recording != nil else { return false }
        return bindings?.handle(event) ?? false
    }

    override public func resignFirstResponder() -> Bool {
        // Leaving the recorder (clicking the search field, another row) ends the recording, so
        // the bridge never pulls focus back and typed keys stay in the field.
        if let bindings, bindings.recording != nil { bindings.cancelRecording() }
        return super.resignFirstResponder()
    }
}

public struct ShortcutsRecorderBridge: NSViewRepresentable {
    let keyBindings: KeyBindingsModel
    /// SwiftUI re-runs `updateNSView` only when this value changes (a reference alone never
    /// differs), so the recording command has to travel with the bridge.
    let recordingCommand: String?

    public init(keyBindings: KeyBindingsModel) {
        self.keyBindings = keyBindings
        self.recordingCommand = keyBindings.recording?.command
    }

    public func makeNSView(context: Context) -> ShortcutsRecorderView {
        let view = ShortcutsRecorderView()
        view.bindings = keyBindings
        return view
    }

    public func updateNSView(_ view: ShortcutsRecorderView, context: Context) {
        guard let command = keyBindings.recording?.command else {
            view.focusedCommand = nil
            if view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
            return
        }
        // Taken only when the recording starts: SwiftUI passes while the same row records (a
        // candidate arriving, an error) never pull focus back from a field the user clicked.
        guard view.focusedCommand != command, let window = view.window else { return }
        view.focusedCommand = command
        window.makeFirstResponder(view)
    }
}
