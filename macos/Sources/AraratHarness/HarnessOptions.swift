import Foundation

struct HarnessOptions {
    var checkOnly = false
    var headless = false
    let databasePath: String
    let fixturePath: String?
    private let temporaryDatabasePath: String?

    init(checkOnly: Bool = false, headless: Bool = false, databasePath: String? = nil, fixturePath: String? = nil) {
        self.checkOnly = checkOnly
        self.headless = headless
        self.fixturePath = fixturePath
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory(), isDirectory: true)
        temporaryDatabasePath = databasePath == nil ? directory.appendingPathComponent("ararat-harness-\(UUID().uuidString).sqlite").path : nil
        self.databasePath = databasePath ?? temporaryDatabasePath!
    }

    func removeTemporaryDatabase() -> Bool {
        guard let temporaryDatabasePath else { return true }
        var removed = true
        for suffix in ["", "-wal", "-shm"] {
            let file = temporaryDatabasePath + suffix
            guard FileManager.default.fileExists(atPath: file) else { continue }
            do { try FileManager.default.removeItem(atPath: file) } catch {
                FileHandle.standardError.write(Data("cannot remove temporary database \(file): \(error)\n".utf8))
                removed = false
            }
        }
        return removed
    }
}
