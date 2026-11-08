import AppKit

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

    /// ⌘Return arrives in the key-equivalent pass, before the editor's bindings; it commits
    /// through the same completion step as Return does (CommandBarView takes it).
    func commitReturn(forceNewTab: Bool) {
        coordinator.commitReturn(forceNewTab: forceNewTab)
    }

    func update() {
        Self.update(field, controller: controller, coordinator: coordinator)
        // A completion needs the field's editor.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Self.update(self.field, controller: self.controller, coordinator: self.coordinator)
        }
    }

    private static func makeField(controller: CommandBarController, coordinator: Coordinator) -> NSTextField {
        let field = NSTextField(string: controller.fieldText)
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
            coord.lastTyped = controller.fieldText
            coord.suppressChange = false
            let selected = controller.fieldTextSelected
            if selected { editor.selectAll(nil) } else { editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0) }
        }
        if coord.appliedPreview != controller.previewVersion {
            coord.appliedPreview = controller.previewVersion
            coord.showPreview(controller.previewText)
        }
        if controller.previewText != nil {
            // Arrowed onto a row; the field shows that row, not a completion.
        } else if let completion = controller.result.inlineCompletion, controller.allowCompletion, coord.pendingCompletion != completion {
            coord.applyCompletion(completion)
        } else if controller.result.inlineCompletion == nil {
            coord.pendingCompletion = nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let controller: CommandBarController
        weak var field: NSTextField?
        var appliedVersion = 0
        var appliedPreview = 0
        var lastTyped = ""
        var suppressChange = false
        var pendingCompletion: String?

        init(controller: CommandBarController) { self.controller = controller }

        func applyCompletion(_ completion: String) {
            guard let field, let editor = field.currentEditor() else { return }
            let typed = lastTyped
            guard completion.lowercased().hasPrefix(typed.lowercased()), completion.count > typed.count else { return }
            let remainder = String(completion.dropFirst(typed.count))
            pendingCompletion = completion
            suppressChange = true
            field.stringValue = typed + remainder
            editor.selectedRange = NSRange(location: (typed as NSString).length, length: (remainder as NSString).length)
            suppressChange = false
        }

        /// Show the arrowed-to row's text, or restore what was typed.
        func showPreview(_ text: String?) {
            guard let field else { return }
            let shown = text ?? controller.query
            suppressChange = true
            field.stringValue = shown
            lastTyped = shown
            pendingCompletion = nil
            field.currentEditor()?.selectedRange = NSRange(location: (shown as NSString).length, length: 0)
            suppressChange = false
        }

        func controlTextDidChange(_ obj: Notification) {
            guard !suppressChange, let field else { return }
            let text = field.stringValue
            let deleting = text.count < lastTyped.count || (pendingCompletion != nil && text == lastTyped)
            lastTyped = text
            pendingCompletion = nil
            controller.update(query: text, allowCompletion: !deleting)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if textView.hasMarkedText() && (selector == #selector(NSResponder.insertNewline(_:))
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
                commitReturn(forceNewTab: NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                controller.close()
                return true
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveToEndOfLine(_:)):
                if pendingCompletion != nil, textView.selectedRange.length > 0 {
                    // Tab and → accept the inline completion (Cra F:139-148).
                    let text = textView.string
                    textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
                    lastTyped = text
                    pendingCompletion = nil
                    controller.update(query: text, allowCompletion: false)
                    return true
                }
                return selector == #selector(NSResponder.insertTab(_:))
            case #selector(NSResponder.deleteBackward(_:)):
                if pendingCompletion != nil, textView.selectedRange.length > 0 {
                    // Remove the suggestion, keep what was typed.
                    let typed = lastTyped
                    pendingCompletion = nil
                    suppressChange = true
                    textView.string = typed
                    textView.setSelectedRange(NSRange(location: (typed as NSString).length, length: 0))
                    suppressChange = false
                    controller.update(query: typed, allowCompletion: false)
                    return true
                }
                return false
            default:
                return false
            }
        }

        /// The step Return and ⌘Return share: with a shown completion whose suffix is selected,
        /// the full text re-queries as the commit happens (Cra F:126-135).
        func commitReturn(forceNewTab: Bool) {
            var completion: String?
            if let view = field?.currentEditor() as? NSTextView, pendingCompletion != nil, view.selectedRange.length > 0 {
                lastTyped = view.string
                completion = view.string
            }
            controller.commit(forceNewTab: forceNewTab, applyingCompletion: completion)
        }
    }
}
