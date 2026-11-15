import AppKit
import AraratKit

/// The command bar's NSTextField with Chrome/Arc-style inline completion, adapted from Cra's
/// MIT `Sources/Cra/UI/CommandBar/CommandTextField.swift`: the completed suffix is inserted
/// selected, so typing replaces it and Backspace removes it without re-completing. The
/// completion itself comes from the core with each query. While the field has marked text
/// (IME), editing keys go to the input method, never to the bar (ours; Cra lacks it).
@MainActor
public final class CommandTextField {
    let controller: CommandBarController
    let field: NSTextField
    private let coordinator: Coordinator

    init(controller: CommandBarController) {
        self.controller = controller
        coordinator = Coordinator(controller: controller)
        field = Self.makeField(controller: controller, coordinator: coordinator)
    }

    /// ⌘Return arrives in the key-equivalent pass, before the editor's bindings; CommandBarView
    /// takes it and commits here (U23 D3: no inline completion to accept first).
    func commitReturn(forceNewTab: Bool) {
        controller.commit(forceNewTab: forceNewTab)
    }

    func update() {
        Self.update(field, controller: controller, coordinator: coordinator)
        // The editor settles a turn after the field takes the text.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Self.update(self.field, controller: self.controller, coordinator: self.coordinator)
        }
    }

    private static func makeField(controller: CommandBarController, coordinator: Coordinator) -> NSTextField {
        let field = NSTextField()
        field.cell = CommandFieldCell(textCell: controller.fieldText)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .regular) // 20 pt regular [Cra, F:35]
        field.placeholderString = controller.placeholder
        field.delegate = coordinator
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setAccessibilityLabel("Command bar")
        coordinator.field = field
        return field
    }

    private static func update(_ field: NSTextField, controller: CommandBarController, coordinator coord: Coordinator) {
        field.placeholderString = controller.placeholder
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() == true { return }
        if coord.appliedVersion != controller.fieldTextVersion {
            guard let editor = field.currentEditor() else { return }
            coord.appliedVersion = controller.fieldTextVersion
            coord.suppressChange = true
            field.stringValue = controller.fieldText
            coord.suppressChange = false
            let selected = controller.fieldTextSelected
            if selected { editor.selectAll(nil) } else { editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0) }
        }
        if coord.appliedPreview != controller.previewVersion {
            coord.appliedPreview = controller.previewVersion
            coord.showPreview(controller.previewText)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let controller: CommandBarController
        weak var field: NSTextField?
        var appliedVersion = 0
        var appliedPreview = 0
        var suppressChange = false

        init(controller: CommandBarController) { self.controller = controller }

        /// Show the arrowed-to row's text, or restore what was typed.
        func showPreview(_ text: String?) {
            guard let field else { return }
            let shown = text ?? controller.query
            suppressChange = true
            field.stringValue = shown
            field.currentEditor()?.selectedRange = NSRange(location: (shown as NSString).length, length: 0)
            suppressChange = false
        }

        func controlTextDidChange(_ obj: Notification) {
            guard !suppressChange, let field else { return }
            controller.update(query: field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if (textView.hasMarkedText() || (textView as? CommandFieldEditor)?.wasMarkedBeforeKeyDown == true) && (selector == #selector(NSResponder.insertNewline(_:))
                || selector == #selector(NSResponder.moveUp(_:)) || selector == #selector(NSResponder.moveDown(_:))
                || selector == #selector(NSResponder.cancelOperation(_:))) {
                return false
            }
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                controller.moveSelection(by: 1); return true
            case #selector(NSResponder.moveUp(_:)):
                controller.moveSelection(by: -1); return true
            case #selector(NSResponder.insertNewline(_:)):
                // ⌘Return arrives in the key-equivalent pass (CommandBarView takes it) and
                // shares the same step; nothing is written twice.
                controller.commit(forceNewTab: NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                controller.close()
                return true
            case #selector(NSResponder.insertTab(_:)):
                // Tab no longer accepts a completion (U23 D3); it stays in the field.
                return true
            default:
                return false
            }
        }
    }
}

@MainActor
final class CommandFieldCell: NSTextFieldCell {
    private let editor = CommandFieldEditor()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        editor.isFieldEditor = true
        return editor
    }
}

@MainActor
final class CommandFieldEditor: NSTextView {
    var wasMarkedBeforeKeyDown = false

    override func keyDown(with event: NSEvent) {
        wasMarkedBeforeKeyDown = hasMarkedText()
        defer { wasMarkedBeforeKeyDown = false }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        // The input method can clear the mark before forwarding the same Return.
        if wasMarkedBeforeKeyDown && selector == #selector(NSResponder.insertNewline(_:)) { return }
        super.doCommand(by: selector)
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let text = pasteboard.string(forType: .string) else {
            return super.readSelection(from: pasteboard, type: type)
        }
        insertText(commandBarPastedText(text: text), replacementRange: selectedRange())
        return true
    }
}
