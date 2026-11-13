import Foundation

/// U26f pass 3 M5: the after-exit half of the private disk inspection. The in-app check opens a
/// private tab with a unique title and records the scratch paths; this step runs after the
/// process exits and proves the title never reached the profile directory or the DB/WAL.
enum PrivateDiskCheck {
    static func run(db: String, profileDir: String, title: String) -> Int32 {
        let manager = FileManager.default
        var conditions: [String: Bool] = [:]
        var failed: [String] = []
        var files: [String] = []
        var hits: [String] = []
        let needle = Data(title.utf8)
        func search(_ path: String) -> Bool {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]) else { return false }
            return data.range(of: needle) != nil
        }
        // The DB and its WAL are the workspace sink; the profile directory is Chromium's.
        conditions["private_disk_db_clean"] = !search(db)
        conditions["private_disk_wal_clean"] = !search(db + "-wal")
        if let enumerator = manager.enumerator(atPath: profileDir) {
            while let entry = enumerator.nextObject() as? String {
                let path = (profileDir as NSString).appendingPathComponent(entry)
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                files.append(entry)
                if !hits.contains(entry), search(path) { hits.append(entry) }
            }
        }
        conditions["private_disk_profile_clean"] = hits.isEmpty
        conditions["private_disk_listed"] = !files.isEmpty
        for (name, value) in conditions where !value { failed.append(name) }
        let result: [String: Any] = [
            "check": "private-disk", "ok": failed.isEmpty,
            "conditions": conditions, "failed_conditions": failed,
            "db": db, "profile_dir": profileDir, "title": title,
            "files": files.count, "hits": hits,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0a]))
        }
        return failed.isEmpty ? 0 : 1
    }
}
