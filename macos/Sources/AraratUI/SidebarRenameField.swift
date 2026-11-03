import AppKit

@MainActor
final class SidebarRenameField: NSTextField, NSTextFieldDelegate {
    private let originalTitle: String
    private let save: (String, @escaping (Bool) -> Void) -> Void
    private let ended: () -> Void
    private var submitting = false
    private var finished = false

    init(title: String, save: @escaping (String, @escaping (Bool) -> Void) -> Void, ended: @escaping () -> Void) {
        self.originalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.save = save
        self.ended = ended
        super.init(frame: .zero)
        stringValue = title
        font = .systemFont(ofSize: 14)
        isBordered = false
        drawsBackground = true
        delegate = self
        setAccessibilityLabel("Rename")
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func finish(commit: Bool) {
        guard !finished, !submitting else { return }
        if !commit || stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == originalTitle { dismiss(); return }
        submitting = true
        save(stringValue) { [weak self] success in
            guard let self else { return }
            self.submitting = false
            if success { self.dismiss() }
            else { self.window?.makeFirstResponder(self) }
        }
    }

    private func dismiss() {
        finished = true
        removeFromSuperview()
        ended()
    }

    func controlTextDidEndEditing(_ notification: Notification) { finish(commit: true) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { finish(commit: false); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { finish(commit: true); return true }
        return false
    }
}
