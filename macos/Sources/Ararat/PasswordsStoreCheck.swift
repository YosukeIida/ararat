import AppKit
import AraratEngineAPI

@MainActor
final class PasswordsStoreCheck {
    nonisolated static func validArguments(_ args: [String]) -> Bool {
        let roots = [NSTemporaryDirectory(), "/tmp"].map {
            URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath().path + "/"
        }
        return !args.contains("--") && args.filter { $0.hasPrefix("--ararat-check") } == ["--ararat-check=passwords"]
            && args.contains("--use-mock-keychain") && ["--user-data-dir", "--ararat-db"].allSatisfy { name in
                let matches = args.filter { $0 == name || $0.hasPrefix(name + "=") }
                guard matches.count == 1, matches[0].hasPrefix(name + "=") else { return false }
                let path = String(matches[0].dropFirst(name.count + 1))
                guard path.hasPrefix("/") else { return false }
                let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                return roots.contains { canonical.hasPrefix($0) }
            }
    }

    private enum Phase { case unlock, add, edit, copy, deleted, finished }
    private let handle: any ARPasswordsAPI
    private let finish: (Bool, [String: Bool]) -> Void
    private let website = "https://pwswitch-check.invalid/"
    private let revised = "fixture-revised-42"
    private var phase: Phase = .unlock
    private var pending = false
    private var deletionObserved = false
    private var results: [String: Bool] = [:]

    init(handle: any ARPasswordsAPI, finish: @escaping (Bool, [String: Bool]) -> Void) {
        self.handle = handle
        self.finish = finish
    }

    private func record(_ condition: String, _ passed: Bool) -> Bool {
        results[condition] = passed
        if !passed || phase == .deleted && condition == "deleted" {
            phase = .finished
            handle.invalidate()
            finish(passed, results)
        }
        return passed
    }

    func tick() {
        guard !pending, phase != .finished else { return }
        pending = true
        if phase == .unlock {
            handle.authenticate { [weak self] ok in
                guard let self, self.record("fake_auth", ok) else { return }
                self.phase = .add
                self.pending = false
            }
            return
        }
        handle.snapshot { [weak self] state, rows in
            guard let self else { return }
            if state == .loading { self.pending = false; return }
            guard state == .ready else { _ = self.record("store_ready", false); return }
            self.advance(rows)
        }
    }

    private func advance(_ rows: [any ARPasswordRowAPI]) {
        let row = rows.first(where: { $0.website == website })
        switch phase {
        case .add:
            guard row == nil else { _ = record("added", false); return }
            let initial = Array("fixture-initial-21".utf16)
            let added = initial.withUnsafeBufferPointer {
                handle.addWebsite(website, username: "fixture", password: $0.baseAddress!, length: UInt($0.count))
            }
            guard record("added", added) else { return }
            phase = .edit
        case .edit:
            guard let row else { pending = false; return }
            guard row.username == "fixture" else { _ = record("edited", false); return }
            let replacement = Array(revised.utf16)
            let edited = replacement.withUnsafeBufferPointer {
                handle.editRow(row.rowID, username: "fixture-edited", password: $0.baseAddress, length: UInt($0.count))
            }
            guard record("edited", edited) else { return }
            phase = .copy
        case .copy:
            guard let row, row.username == "fixture-edited" else { pending = false; return }
            handle.revealRow(row.rowID) { [weak self] password, count in
                guard let self else { return }
                let matches = password.map {
                    UnsafeBufferPointer(start: $0, count: Int(count)).elementsEqual(self.revised.utf16)
                } ?? false
                guard self.record("revealed", matches) else { return }
                self.copyAndDelete(row.rowID)
            }
            return
        case .deleted:
            if deletionObserved { _ = record("deleted", row == nil) }
        default:
            break
        }
        pending = false
    }

    private func copyAndDelete(_ rowID: String) {
        handle.copyRow(rowID) { [weak self] copied in
            guard let self else { return }
            let pasteboard = NSPasteboard.general
            let sequence = pasteboard.changeCount
            let matches = copied && pasteboard.string(forType: .string) == self.revised
            let concealed = pasteboard.types?.contains(.init("org.nspasteboard.ConcealedType")) == true
            if matches && pasteboard.changeCount == sequence { pasteboard.clearContents() }
            guard self.record("copied_confidentially", matches && concealed) else { return }
            self.handle.setChangedHandler { [weak self] in self?.deletionObserved = true }
            guard self.record("delete_submitted", self.handle.deleteRow(rowID)) else { return }
            self.phase = .deleted
            self.pending = false
        }
    }
}
