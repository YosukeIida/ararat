import AppKit
import AraratKit
import Carbon.HIToolbox
import SwiftUI

/// U27i O3: the Little Window's global shortcut is a Carbon hot key, not a row in the key-binding
/// table. `RegisterEventHotKey` needs no Accessibility permission (a `CGEventTap` would), so the
/// pane carries no permission copy. This file holds the registrar (with the status the row shows),
/// the recorder's key rules and the one app-wide object that owns the registration.
public enum GlobalHotKeyStatus: Equatable {
    case registered
    case taken
    case failed(String)
}

/// The system side of the shortcut, behind a protocol so the unit tests can answer "registered"
/// and "taken" without registering anything.
@MainActor
public protocol GlobalHotKeyRegistrar: AnyObject {
    /// Registers `hotKey`, replacing the previous one, and calls `handler` when the key is
    /// pressed while Ararat is in the background.
    func register(_ hotKey: LittleWindowHotKey, handler: @escaping () -> Void) -> GlobalHotKeyStatus
    func unregister()
}

/// `eventHotKeyExistsErr`: another hot key (in any app) already owns the combination.
private let hotKeyExists: OSStatus = -9878
/// 'ARRH': our hot key's four-character signature inside the app's event target.
private let hotKeySignature: OSType = 0x4152_5248

/// Carbon's `RegisterEventHotKey`. The application event target receives the press wherever the
/// app is, which is what makes the shortcut work while Ararat is in the background.
@MainActor
public final class CarbonGlobalHotKey: GlobalHotKeyRegistrar {
    private var reference: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?
    private(set) public var status: GlobalHotKeyStatus?

    public init() {}

    isolated deinit {
        // The handler is owned by the application event target, which outlives this object.
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    public func register(_ hotKey: LittleWindowHotKey, handler: @escaping () -> Void) -> GlobalHotKeyStatus {
        unregister()
        action = handler
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: hotKeySignature, id: 1)
        var reference: EventHotKeyRef?
        let osStatus = RegisterEventHotKey(UInt32(hotKey.keyCode), Self.carbonModifiers(hotKey), id,
                                           GetApplicationEventTarget(), 0, &reference)
        self.reference = reference
        let status: GlobalHotKeyStatus
        switch osStatus {
        case noErr where reference != nil: status = .registered
        case hotKeyExists: status = .taken
        default: status = .failed(Self.describe(osStatus))
        }
        self.status = status
        if status != .registered { action = nil }
        return status
    }

    public func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        action = nil
        status = nil
    }

    static func carbonModifiers(_ hotKey: LittleWindowHotKey) -> UInt32 {
        var modifiers: UInt32 = 0
        if hotKey.command { modifiers |= UInt32(cmdKey) }
        if hotKey.control { modifiers |= UInt32(controlKey) }
        if hotKey.option { modifiers |= UInt32(optionKey) }
        if hotKey.shift { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    /// The row's message for a failure that is not "taken": Carbon's own words where it has any.
    static func describe(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? ""
        return message.isEmpty ? "the system refused the shortcut (error \(status))" : message
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard read == noErr, id.signature == hotKeySignature else { return OSStatus(eventNotHandledErr) }
            let registrar = Unmanaged<CarbonGlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { registrar.fire() }
            return noErr
        }, 1, &spec, pointer, &handlerRef)
    }

    private func fire() {
        guard status == .registered else { return }
        action?()
    }
}

/// The app-wide registration: one for the app, whatever window the shortcut is pressed in. The
/// settings pane writes the stored value through it, so a recorded key takes effect at once.
@MainActor
public final class LittleWindowHotKeyCenter {
    public let registrar: GlobalHotKeyRegistrar
    /// Runs when the shortcut is pressed. The app points it at the Little Window's command.
    public var onTrigger: (() -> Void)?
    public private(set) var hotKey: LittleWindowHotKey?
    public private(set) var status: GlobalHotKeyStatus?

    public init(registrar: GlobalHotKeyRegistrar) { self.registrar = registrar }

    /// Applies a stored value: nil unregisters, a key registers and records the status the pane
    /// shows. Called at launch with the device record and by the pane on every change.
    @discardableResult
    public func apply(_ hotKey: LittleWindowHotKey?) -> GlobalHotKeyStatus? {
        self.hotKey = hotKey
        guard let hotKey else {
            registrar.unregister()
            status = nil
            return nil
        }
        let status = registrar.register(hotKey) { [weak self] in self?.onTrigger?() }
        self.status = status
        return status
    }
}

/// What one key event means to the recorder. Esc cancels and ⌫/⌦ turn the shortcut off, as the
/// Shortcuts pane's recorder does; a combination without Command, Control or Option would steal a
/// bare key from every app, and the system's own shortcuts are refused.
public enum LittleWindowHotKeyEntry: Equatable {
    case key(LittleWindowHotKey)
    case cleared
    case cancelled
    case refused(String)
    case ignored
}

public enum LittleWindowHotKeyRecorder {
    public static let refusedMessage = "this shortcut is reserved by the system"
    public static let noModifierMessage = "a global shortcut needs Command, Control or Option"

    public static func entry(for event: NSEvent) -> LittleWindowHotKeyEntry {
        if event.isARepeat { return .ignored }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let anchored = modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option)
        switch event.keyCode {
        case 53 where !anchored: return .cancelled
        case 51 where !anchored, 117 where !anchored: return .cleared
        default: break
        }
        guard anchored else { return .refused(noModifierMessage) }
        // The same reserved set the Shortcuts pane refuses, by character and by key position
        // (⇧⌘3/4/5 are the screenshot keys on every layout).
        let key = event.characters(byApplyingModifiers: []) ?? ""
        let command = modifiers.contains(.command), control = modifiers.contains(.control)
        let option = modifiers.contains(.option), shift = modifiers.contains(.shift)
        if command && !control && !option {
            if ["q", "h", "`"].contains(key) || (shift && ["3", "4", "5", "#", "$", "%"].contains(key)) { return .refused(refusedMessage) }
            if command && shift && [20, 21, 23].contains(Int(event.keyCode)) { return .refused(refusedMessage) }
        }
        if command && option && !shift && key == "h" { return .refused(refusedMessage) }
        if command && control && key == "q" { return .refused(refusedMessage) }
        guard key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first else { return .ignored }
        return .key(LittleWindowHotKey(keyCode: event.keyCode, key: String(scalar).lowercased(), command: command,
                                       control: control, option: option, shift: shift))
    }

    /// The candidate's keycaps, e.g. ⌥, ⌘, N, through the same display rule the Shortcuts pane uses.
    @MainActor public static func caps(_ hotKey: LittleWindowHotKey?) -> [String] {
        guard let hotKey else { return [] }
        return SidebarTooltip.caps(for: KeyCombination(key: hotKey.key, command: hotKey.command,
                                                       control: hotKey.control, option: hotKey.option, shift: hotKey.shift))
    }

    /// The default the pane shows before the device record arrives: ⌥⌘N, the board's key and the
    /// core's built-in `LittleWindowHotKey::default_shortcut`.

    public static var defaultHotKey: LittleWindowHotKey {
        LittleWindowHotKey(keyCode: 45, key: "n", command: true, control: false, option: true, shift: false)
    }
}

/// The recorder's NSView side: while a row records it takes first responder so the keys arrive
/// here rather than at the menus (⌘-combinations included), and leaving it cancels.
@MainActor
public final class LittleWindowHotKeyRecorderView: NSView {
    public var onEvent: ((NSEvent) -> Void)?
    public var onCancel: (() -> Void)?
    public private(set) var recording = false

    override public var acceptsFirstResponder: Bool { true }
    override public var canBecomeKeyView: Bool { recording }

    public func setRecording(_ recording: Bool) {
        self.recording = recording
        if !recording, window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    override public func keyDown(with event: NSEvent) { onEvent?(event) }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return false }
        onEvent?(event)
        return true
    }

    override public func resignFirstResponder() -> Bool {
        if recording { onCancel?() }
        return super.resignFirstResponder()
    }
}

/// Mounts the recorder: `recording` true takes first responder once, false gives it back.
public struct LittleWindowHotKeyRecorderBridge: NSViewRepresentable {
    let recording: Bool
    let onEvent: (NSEvent) -> Void
    let onCancel: () -> Void

    public init(recording: Bool, onEvent: @escaping (NSEvent) -> Void, onCancel: @escaping () -> Void) {
        self.recording = recording
        self.onEvent = onEvent
        self.onCancel = onCancel
    }

    public func makeNSView(context: Context) -> LittleWindowHotKeyRecorderView {
        let view = LittleWindowHotKeyRecorderView()
        view.onEvent = onEvent
        view.onCancel = onCancel
        return view
    }

    public func updateNSView(_ view: LittleWindowHotKeyRecorderView, context: Context) {
        view.onEvent = onEvent
        view.onCancel = onCancel
        view.setRecording(recording)
        guard recording, let window = view.window, window.firstResponder !== view else { return }
        window.makeFirstResponder(view)
    }
}
