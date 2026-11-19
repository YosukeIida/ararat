import AppKit
import AraratKit
import AraratUI
import Carbon.HIToolbox
import SwiftUI

enum QuitConfirmation {
    enum Source: Equatable {
        case user, sessionEnd, sparkle, check
    }

    enum BrowserWindow {
        case regular, privateWindow, littleWindow
    }

    static func source(poweringOff: Bool, quitReason: OSType?, sparkleRelaunching: Bool,
                       checkBypass: Bool) -> Source {
        if poweringOff || quitReason == kAEReallyLogOut || quitReason == kAELogOut
            || quitReason == kAEShutDown || quitReason == kAERestart {
            return .sessionEnd
        }
        if sparkleRelaunching { return .sparkle }
        return checkBypass ? .check : .user
    }

    static func shouldAsk(source: Source, warn: Bool, visible: [BrowserWindow]) -> Bool {
        source == .user && warn && !visible.isEmpty
    }

    static func message(for open: [BrowserWindow]) -> String {
        let regular = String(localized: "Your tabs will be here when you come back.")
        guard open.contains(.privateWindow) else { return regular }
        let privateWindows = String(localized: "Private windows will close and their tabs will not come back.")
        return open.allSatisfy { $0 == .privateWindow } ? privateWindows : regular + "\n" + privateWindows
    }

    enum ShortcutAction {
        case pass, consumeRepeat, confirm
    }

    static func shortcutAction(for event: NSEvent, binding: KeyCombination?) -> ShortcutAction {
        guard event.type == .keyDown, let binding, WorkspaceCommands.matches(binding, event: event) else {
            return .pass
        }
        return event.isARepeat ? .consumeRepeat : .confirm
    }

    static func disablesWarning(accepted: Bool, checked: Bool) -> Bool {
        accepted && checked
    }
}

@MainActor
final class QuitConfirmationPanel {
    private var pending: UUID?
    private var panel: NSPanel?

    var isPending: Bool { pending != nil }

    func cancel() {
        pending = nil
        answer(.cancel)
    }

    func answer(_ response: NSApplication.ModalResponse) {
        guard let panel, NSApp.modalWindow === panel else { return }
        NSApp.stopModal(withCode: response)
    }

    func show(over window: NSWindow, message: String, quitBinding: @escaping () -> KeyCombination?,
              onModal: ((NSPanel) -> Void)?,
              completion: @escaping (Bool, Bool) -> Void) {
        let ticket = UUID()
        pending = ticket
        RunLoop.main.perform { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard let self, self.pending == ticket else { return }
                guard let window, window.isVisible else {
                    self.pending = nil
                    completion(false, false)
                    return
                }
                let choice = Choice()
                let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView],
                                    backing: .buffered, defer: false)
                panel.title = String(localized: "Quit Ararat?")
                panel.titleVisibility = .hidden
                panel.titlebarAppearsTransparent = true
                panel.standardWindowButton(.closeButton)?.isHidden = true
                panel.isMovable = false
                let content = NSHostingView(rootView: Content(message: message, choice: choice) { response in
                    self.answer(response)
                })
                panel.contentView = content
                let size = content.fittingSize
                panel.setContentSize(size)
                let frame = window.frame
                let visible = window.screen?.visibleFrame ?? frame
                panel.setFrameOrigin(NSPoint(
                    x: max(visible.minX, min(frame.midX - size.width / 2, visible.maxX - size.width)),
                    y: max(visible.minY, min(frame.midY - size.height / 2, visible.maxY - size.height))
                ))
                self.panel = panel
                let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    let binding = MainActor.assumeIsolated { quitBinding() }
                    switch QuitConfirmation.shortcutAction(for: event, binding: binding) {
                    case .pass: return event
                    case .consumeRepeat: return nil
                    case .confirm:
                        MainActor.assumeIsolated { self.answer(.OK) }
                        return nil
                    }
                }
                let inspection = onModal.map { inspect in
                    let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
                        MainActor.assumeIsolated { inspect(panel) }
                    }
                    RunLoop.main.add(timer, forMode: .modalPanel)
                    return timer
                }
                NSApp.activate()
                let response = NSApp.runModal(for: panel)
                inspection?.invalidate()
                if let keys { NSEvent.removeMonitor(keys) }
                self.panel = nil
                panel.orderOut(nil)
                guard self.pending == ticket else { return }
                self.pending = nil
                completion(response == .OK, choice.checked)
            }
        }
    }

    private final class Choice: ObservableObject {
        @Published var checked = false
    }

    private struct Content: View {
        let message: String
        @ObservedObject var choice: Choice
        let answer: (NSApplication.ModalResponse) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().scaledToFit().frame(width: 40, height: 40)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quit Ararat?").font(.system(size: 15, weight: .medium))
                        Text(message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 6) {
                    Toggle("Don’t ask again", isOn: $choice.checked)
                        .toggleStyle(.checkbox).controlSize(.small).font(.system(size: 12.5))
                        .fixedSize()
                    Spacer(minLength: 8)
                    Button { answer(.cancel) } label: { buttonLabel("Cancel", key: "esc") }
                        .keyboardShortcut(.cancelAction)
                    Button { answer(.OK) } label: { buttonLabel("Quit", key: "↩") }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12).frame(width: 380)
        }

        private func buttonLabel(_ title: LocalizedStringKey, key: String) -> some View {
            HStack(spacing: 6) {
                Text(title)
                Text(key).font(.caption.monospaced())
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 3))
                    .accessibilityHidden(true)
            }
        }
    }
}
