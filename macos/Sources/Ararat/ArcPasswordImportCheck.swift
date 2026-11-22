import Foundation
import AraratEngineAPI

@MainActor
final class ArcPasswordImportCheck {
    nonisolated static let mode = "arc-password-import"

    private enum Phase { case ready, seed, imported, pending, finished }
    private let handle: any ARPasswordsAPI
    private let finish: (Bool, [String: Any]) -> Void
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ararat-arc-passwords-" + UUID().uuidString, isDirectory: true)
    private var phase = Phase.ready
    private var conditions = ["store_opened": true]
    private var counts: [String: [String: UInt]] = [:]
    private var createdDirectory = false
    private var snapshotPending = false

    private let expectations = [
        ("https://arc-fixture-1.invalid/", "ann", "arc-fixture-11"),
        ("https://arc-fixture-2.invalid/", "zoë", "arc \"fixture\", 12 é"),
        ("https://arc-fixture-3.invalid/", "carl", "ararat-own-31"),
    ]

    init(handle: any ARPasswordsAPI, finish: @escaping (Bool, [String: Any]) -> Void) {
        self.handle = handle
        self.finish = finish
    }

    func tick() {
        guard phase != .finished, phase != .pending, !snapshotPending else { return }
        snapshotPending = true
        handle.snapshot { [weak self] state, rows in
            guard let self, self.phase != .finished else { return }
            self.snapshotPending = false
            if state == .loading { return }
            guard self.record("store_ready", state == .ready) else { return }
            self.advance(rows)
        }
    }

    func timeOut() {
        _ = record("completed_before_timeout", false)
    }

    private var fixturePath: String { directory.appendingPathComponent("Login Data").path }

    private func advance(_ rows: [any ARPasswordRowAPI]) {
        let (website, username, password) = expectations[2]
        switch phase {
        case .ready:
            guard record("fixture_guard", handle.checkUsesFakeAuthentication) else { return }
            phase = .pending
            handle.authenticate { [weak self] authorized in
                guard let self, self.record("fake_auth", authorized) else { return }
                let password = Array(password.utf16)
                let added = password.withUnsafeBufferPointer {
                    self.handle.addWebsite(website, username: username, password: $0.baseAddress!, length: UInt($0.count))
                }
                if self.record("seed_submitted", added) { self.phase = .seed }
            }
        case .seed:
            guard rows.contains(where: { $0.website == website && $0.username == username }) else { return }
            _ = record("seed_observed", true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                createdDirectory = true
            } catch {
                _ = record("fixture_directory", false)
                return
            }
            guard record("fixture_written", handle.checkWriteArcFixture(fixturePath)) else { return }
            runImport(retry: false)
        case .imported:
            let matches = expectations.compactMap { website, username, _ in
                rows.first { $0.website == website && $0.username == username }
            }
            guard matches.count == expectations.count else { return }
            _ = record("store_updated", true)
            phase = .pending
            reveal(matches, index: 0)
        case .pending, .finished:
            break
        }
    }

    private func reveal(_ rows: [any ARPasswordRowAPI], index: Int) {
        guard index < rows.count else { runImport(retry: true); return }
        handle.revealRow(rows[index].rowID) { [weak self] password, count in
            guard let self else { return }
            let matches = password.map {
                UnsafeBufferPointer(start: $0, count: Int(count)).elementsEqual(self.expectations[index].2.utf16)
            } ?? false
            if self.record(["first_password", "utf8_password", "conflict_preserved"][index], matches) {
                self.reveal(rows, index: index + 1)
            }
        }
    }

    private func runImport(retry: Bool) {
        phase = .pending
        handle.importArcPasswords(from: fixturePath) { [weak self] status, result in
            guard let self else { return }
            let label = retry ? "retry" : "initial"
            guard self.phase != .finished else { return }
            self.counts[label] = ["added": result.added, "existing": result.existing,
                                  "conflicts": result.conflicts, "neverSaved": result.neverSaved,
                                  "undecryptable": result.undecryptable, "invalid": result.invalid]
            guard self.record(label + "_status", status == .imported),
                  self.record(label + "_counts", result.added == (retry ? 0 : 2)
                    && result.existing == (retry ? 3 : 1) && result.conflicts == 1
                    && result.neverSaved == 1 && result.undecryptable == 2 && result.invalid == 1)
            else { return }
            if retry {
                self.handle.importArcPasswords(from: self.directory.appendingPathComponent("missing").path) { [weak self] status, _ in
                    guard let self, self.record("missing_unreadable", status == .unreadable) else { return }
                    self.complete()
                }
            } else {
                self.phase = .imported
            }
        }
    }

    @discardableResult
    private func record(_ condition: String, _ passed: Bool) -> Bool {
        guard phase != .finished else { return false }
        conditions[condition] = passed
        if !passed { complete() }
        return passed
    }

    private func complete() {
        phase = .finished
        handle.invalidate()
        if createdDirectory {
            do {
                try FileManager.default.removeItem(at: directory)
                conditions["fixture_removed"] = true
            } catch {
                conditions["fixture_removed"] = false
            }
        }
        finish(!conditions.values.contains(false), ["check": Self.mode, "conditions": conditions, "counts": counts])
    }
}
