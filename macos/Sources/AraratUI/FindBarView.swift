import AppKit

@MainActor
public final class FindBarView: NSView, NSTextFieldDelegate {
    public let field = NSTextField()
    private let count = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private let close = NSButton()
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
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        field.placeholderString = "Find in page"
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.setAccessibilityLabel("Find in page")
        count.identifier = NSUserInterfaceItemIdentifier("find-match-count")
        count.font = .systemFont(ofSize: 12)
        count.alignment = .right
        count.lineBreakMode = .byTruncatingTail
        field.delegate = self
        for (button, symbol, label) in [(previous, "chevron.up", "Previous match"),
                                        (next, "chevron.down", "Next match"), (close, "xmark", "Close find")] {
            let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(configuration)
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel(label)
            button.toolTip = label
            button.target = self
            button.isBordered = false
        }
        previous.action = #selector(previousMatch)
        next.action = #selector(nextMatch)
        close.action = #selector(closeFind)
        for view in [field, count, previous, next, close] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    public override func layout() {
        super.layout()
        let inset: CGFloat = bounds.width < 168 ? 4 : 8
        let buttonWidth = min(25, max(0, (bounds.width - 2 * inset) / 5))
        let controlsX = bounds.width - inset - (3 * buttonWidth + 4)
        let countWidth = min(64, max(0, (controlsX - inset) / 2))
        let countX = controlsX - countWidth - 2
        let fieldHeight = field.intrinsicContentSize.height
        let countHeight = count.intrinsicContentSize.height
        field.frame = NSRect(x: inset, y: (bounds.height - fieldHeight) / 2,
                             width: max(0, countX - inset - 4), height: fieldHeight)
        count.frame = NSRect(x: countX, y: (bounds.height - countHeight) / 2, width: countWidth, height: countHeight)
        for (index, button) in [previous, next, close].enumerated() {
            button.frame = NSRect(x: controlsX + CGFloat(index) * (buttonWidth + 2), y: 6, width: buttonWidth, height: 24)
        }
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
        let hasQuery = !field.stringValue.isEmpty
        let notFound = hasQuery && matches == 0 && finalUpdate
        count.stringValue = notFound ? "Not found" : (hasQuery && matches > 0 ? "\(max(0, ordinal)) of \(matches)" : "")
        count.textColor = notFound ? .systemRed : .secondaryLabelColor
        previous.isEnabled = !notFound
        next.isEnabled = !notFound
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
