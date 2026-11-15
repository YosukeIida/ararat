import AppKit
import AraratKit
import Testing
@testable import AraratUI

@Suite @MainActor
struct CommandFieldInputTests {
    @Test func theFieldUsesItsOwnEditor() throws {
        let field = CommandTextField(controller: CommandBarController()).field
        let editor = try #require(field.cell?.fieldEditor(for: field) as? CommandFieldEditor)
        #expect(editor.isFieldEditor)
        #expect(field.cell?.fieldEditor(for: field) === editor)
        // The custom cell starts non-editable and non-selectable, so the field sets both itself.
        #expect(field.isEditable)
        #expect(field.isSelectable)
        #expect(field.alignment == .natural)
    }

    @Test func pasteReplacesTheSelectionAndRejoinsAddressesOnly() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = CommandFieldEditor()
        for (pasted, expected) in [
            ("\u{10}https://exa\r\nmple.com/", "https://example.com/"),
            ("foo\nbar", "foo\nbar"),
            ("hello \nworld", "hello \nworld"),
        ] {
            editor.string = "before old after"
            editor.setSelectedRange(NSRange(location: 7, length: 3))
            pasteboard.clearContents()
            pasteboard.setString(pasted, forType: .string)
            #expect(editor.readSelection(from: pasteboard, type: .string))
            #expect(editor.string == "before \(expected) after")
        }
    }

    @Test func returnForwardedAfterTheIMEUnmarksDoesNotSubmit() {
        let editor = CommandFieldEditor()
        let recorder = CommandRecorder()
        editor.delegate = recorder
        editor.setMarkedText("こん", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.wasMarkedBeforeKeyDown = editor.hasMarkedText()
        editor.unmarkText()
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(recorder.commands.isEmpty)
        #expect(editor.string == "こん" && !editor.hasMarkedText())
        editor.wasMarkedBeforeKeyDown = false
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(recorder.commands == [#selector(NSResponder.insertNewline(_:))])
    }

    @Test func markedReturnAndArrowsStayWithTheInputMethod() {
        let controller = CommandBarController()
        controller.open(mode: .newTab, prefill: nil, store: nil)
        let coordinator = CommandTextField.Coordinator(controller: controller)
        let editor = CommandFieldEditor()
        editor.setMarkedText("こん", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        for selector in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveUp(_:)),
                         #selector(NSResponder.moveDown(_:)), #selector(NSResponder.cancelOperation(_:))] {
            #expect(!coordinator.control(NSTextField(), textView: editor, doCommandBy: selector))
        }
        #expect(controller.isOpen && controller.selectedIndex == 0 && editor.hasMarkedText())
    }
}

@MainActor
private final class CommandRecorder: NSObject, NSTextViewDelegate {
    var commands: [Selector] = []
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        commands.append(commandSelector)
        return true
    }
}
