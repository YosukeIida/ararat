import AppKit

@MainActor
public final class FindBarView: NSView, NSTextFieldDelegate {
    public let field = NSTextField()
    private let count = NSTextField(labelWithString: "")
    private let previous = NSButton(title: "↑", target: nil, action: nil)
    private let next = NSButton(title: "↓", target: nil, action: nil)
    private let close = NSButton(title: "×", target: nil, action: nil)
    public var onAction: (String, String, NSRange, String, String) -> Void = { _, _, _, _, _ in }
    private var updating = false
    private var live = ""
    private var profile = ""
    public private(set) var matches = 0
    public private(set) var ordinal = 0
    public private(set) var requestID = 0
    public private(set) var finalUpdate = false
    public var hasFocus: Bool { field.currentEditor() != nil && window?.firstResponder === field.currentEditor() }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 8
        field.placeholderString = "Find in page"
        field.setAccessibilityLabel("Find in page")
        count.identifier = NSUserInterfaceItemIdentifier("find-match-count")
        field.delegate = self
        previous.setAccessibilityLabel("Previous match")
        next.setAccessibilityLabel("Next match")
        close.setAccessibilityLabel("Close find")
        for button in [previous, next, close] { button.target = self; button.isBordered = false }
        previous.action = #selector(previousMatch)
        next.action = #selector(nextMatch)
        close.action = #selector(closeFind)
        for view in [field, count, previous, next, close] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func layout() {
        super.layout()
        field.frame = NSRect(x: 8, y: 6, width: max(0, bounds.width - 166), height: 24)
        count.frame = NSRect(x: bounds.width - 153, y: 8, width: 64, height: 20)
        previous.frame = NSRect(x: bounds.width - 88, y: 6, width: 25, height: 24)
        next.frame = NSRect(x: bounds.width - 61, y: 6, width: 25, height: 24)
        close.frame = NSRect(x: bounds.width - 34, y: 6, width: 25, height: 24)
    }

    public func update(state: [String: Any]) {
        live = state["live"] as? String ?? ""
        profile = state["profile"] as? String ?? ""
        isHidden = !(state["visible"] as? Bool ?? false)
        let marked = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if !marked, let text = state["text"] as? String, field.stringValue != text {
            updating = true
            field.stringValue = text
            updating = false
        }
        matches = state["matches"] as? Int ?? 0
        ordinal = state["ordinal"] as? Int ?? 0
        requestID = state["request_id"] as? Int ?? 0
        finalUpdate = state["final_update"] as? Bool ?? false
        count.stringValue = matches > 0 ? "\(max(0, ordinal)) of \(matches)" : "0 of 0"
        if !isHidden && (state["focus"] as? Bool ?? false) {
            window?.makeFirstResponder(field)
            if !marked, let editor = field.currentEditor(), let start = state["start"] as? Int,
               let end = state["end"] as? Int, start >= 0, end >= start, end <= (field.stringValue as NSString).length {
                editor.selectedRange = NSRange(location: start, length: end - start)
            }
        }
    }

    public func controlTextDidChange(_ obj: Notification) {
        if !updating { send("change") }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.characters == "\r", event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() == true { return false }
        send("next")
        return true
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) { closeFind(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            send(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? "previous" : "next")
            return true
        }
        return false
    }

    private func send(_ action: String) {
        let range = field.currentEditor()?.selectedRange ?? NSRange(location: (field.stringValue as NSString).length, length: 0)
        onAction(action, field.stringValue, range, live, profile)
    }
    @objc private func previousMatch() { send("previous") }
    @objc private func nextMatch() { send("next") }
    @objc private func closeFind() { send("close") }
}
