import Darwin
import Foundation
import Testing

private struct HarnessRun {
    let status: Int32
    let output: String
    let error: String
    let databasesBeforeQuit: [String]
    let runningBeforeStop: Bool
}

private final class HarnessTestBundle: NSObject {}

private func runHarness(in directory: URL, arguments: [String] = [], commands: String = "", stopSignal: Int32? = nil, nullInput: Bool = false) throws -> HarnessRun {
    let process = Process()
    process.executableURL = Bundle(for: HarnessTestBundle.self).bundleURL.deletingLastPathComponent().appendingPathComponent("AraratHarness")
    process.arguments = ["--headless"] + arguments
    var environment = ProcessInfo.processInfo.environment
    environment["TMPDIR"] = directory.path + "/"
    process.environment = environment
    let input = Pipe()
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    let output = Pipe()
    let error = Pipe()
    process.standardInput = nullInput ? FileHandle(forReadingAtPath: "/dev/null")! : input
    process.standardOutput = output
    process.standardError = error
    try process.run()
    let timeout = DispatchSource.makeTimerSource(queue: .global())
    timeout.schedule(deadline: .now() + 8)
    timeout.setEventHandler { if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) } }
    timeout.resume()
    defer {
        timeout.cancel()
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
    }
    let interactive = !arguments.contains("--check")
    var stdout = Data()
    if nullInput {
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    } else if interactive {
        try input.fileHandleForWriting.write(contentsOf: Data((commands + "state\n").utf8))
        while !String(decoding: stdout, as: UTF8.self).contains("state space ") {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            stdout.append(chunk)
        }
    }
    let databasesBeforeQuit = try harnessDatabaseFiles(in: directory)
    let runningBeforeStop = process.isRunning
    if let stopSignal {
        if process.isRunning { _ = kill(process.processIdentifier, stopSignal) }
    } else if interactive {
        try input.fileHandleForWriting.write(contentsOf: Data("quit\n".utf8))
    }
    try input.fileHandleForWriting.close()
    stdout.append(output.fileHandleForReading.readDataToEndOfFile())
    let stderr = error.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return HarnessRun(status: process.terminationStatus,
                      output: String(decoding: stdout, as: UTF8.self), error: String(decoding: stderr, as: UTF8.self),
                      databasesBeforeQuit: databasesBeforeQuit, runningBeforeStop: runningBeforeStop)
}

func testTemporaryDirectory() throws -> URL {
    let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory(), isDirectory: true)
    let directory = base.appendingPathComponent("ararat-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func harnessDatabaseFiles(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("ararat-harness-") }
}

@Test
func harnessSelectRepliesReflectCoreAcceptance() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = directory.appendingPathComponent("sidebar.json")
    let json = #"{"sidebar":{"containers":[{}, {"spaces":["work", {"id":"work","title":"Work","profile":{"default":true},"containerIDs":["pinned","pin","unpinned","today"]}],"items":["pin",{"id":"pin","parentID":null,"childrenIds":["folder-docs","pinned"],"data":{"itemContainer":{}}},"folder-docs",{"id":"folder-docs","parentID":"pin","childrenIds":[],"data":{"list":{}}},"pinned",{"id":"pinned","parentID":"pin","childrenIds":[],"data":{"tab":{"savedURL":"https://pinned.example"}}},"today",{"id":"today","parentID":null,"childrenIds":["live"],"data":{"itemContainer":{}}},"live",{"id":"live","parentID":"today","childrenIds":[],"data":{"tab":{"savedURL":"https://live.example"}}}]}]}}"#
    try json.write(to: fixture, atomically: true, encoding: .utf8)
    let run = try runHarness(in: directory, arguments: [fixture.path], commands:
        "select folder-docs\nselect missing\nselect live\nclose live\nselect live\nselect pinned\nstate\n")
    let replies = run.output.split(separator: "\n").map(String.init)
    #expect(replies.contains { $0.hasPrefix("error ") && $0.contains("folder-docs") })
    #expect(!replies.contains("ok select folder-docs"))
    #expect(replies.contains { $0.hasPrefix("error ") && $0.contains("missing") })
    #expect(replies.contains("ok select live"))
    #expect(replies.contains("ok close live"))
    #expect(replies.contains { $0.hasPrefix("error ") && $0.contains("live") })
    #expect(replies.contains("ok select pinned"))
    #expect(replies.contains("state space 0 selected pinned"))
}

@Test
func harnessQuitRemovesOnlyItsTemporaryDatabase() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let run = try runHarness(in: directory)
    #expect(run.status == 0, "\(run.error)")
    #expect(run.output.contains("ok quit"))
    #expect(!run.databasesBeforeQuit.isEmpty)
    #expect(try harnessDatabaseFiles(in: directory).isEmpty)
    let otherFiles = ["ararat-harness-other.sqlite", "ararat-harness-other.sqlite-wal", "ararat-harness-other.sqlite-shm"]
    for name in otherFiles {
        try Data("other run".utf8).write(to: directory.appendingPathComponent(name))
    }
    let second = try runHarness(in: directory)
    #expect(second.status == 0, "\(second.error)")
    #expect(second.databasesBeforeQuit.count > otherFiles.count)
    #expect(try harnessDatabaseFiles(in: directory).sorted() == otherFiles.sorted())
}

@Test
func harnessCheckCleansTemporaryDatabasesAndKeepsExplicitDatabases() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let temporary = try runHarness(in: directory, arguments: ["--check"])
    #expect(temporary.status == 0, "\(temporary.error)")
    #expect(try harnessDatabaseFiles(in: directory).isEmpty)
    let database = directory.appendingPathComponent("ararat-harness-explicit.sqlite")
    let persistent = try runHarness(in: directory, arguments: ["--check", "--db", database.path])
    #expect(persistent.status == 0, "\(persistent.error)")
    #expect(FileManager.default.fileExists(atPath: database.path))
    let reopened = try runHarness(in: directory, arguments: ["--db", database.path])
    #expect(reopened.status == 0, "\(reopened.error)")
    #expect(FileManager.default.fileExists(atPath: database.path))
}

@Test
func harnessStartupFailureCleansTemporaryFilesAndKeepsExplicitDatabase() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = directory.appendingPathComponent("invalid.json")
    try "invalid".write(to: fixture, atomically: true, encoding: .utf8)
    let temporary = try runHarness(in: directory, arguments: ["--check", fixture.path])
    #expect(temporary.status == 1)
    #expect(!temporary.error.isEmpty)
    #expect(try harnessDatabaseFiles(in: directory).isEmpty)
    let database = directory.appendingPathComponent("ararat-harness-explicit.sqlite")
    let persistent = try runHarness(in: directory, arguments: ["--check", "--db", database.path, fixture.path])
    #expect(persistent.status == 1)
    #expect(FileManager.default.fileExists(atPath: database.path))
}

@Test
func harnessNullStdinKeepsRunningUntilStoppedAndThenCleansUp() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let run = try runHarness(in: directory, stopSignal: SIGTERM, nullInput: true)
    #expect(run.runningBeforeStop)
    #expect(!run.databasesBeforeQuit.isEmpty)
    #expect(run.status == 0, "\(run.error)")
    #expect(try harnessDatabaseFiles(in: directory).isEmpty)
}

@Test
func harnessTerminationSignalsUseNormalCleanup() throws {
    for number in [SIGTERM, SIGINT] {
        let directory = try testTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = try runHarness(in: directory, stopSignal: number)
        #expect(run.runningBeforeStop)
        #expect(!run.databasesBeforeQuit.isEmpty)
        #expect(run.status == 0, "signal \(number): \(run.error)")
        #expect(try harnessDatabaseFiles(in: directory).isEmpty)
    }
}

@Test
func harnessRepliesWaitForMRUUnloadsAndReselections() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let run = try runHarness(in: directory, commands:
        "select tab-mail\nselect tab-spec\nclose tab-spec\nstate\nselect tab-spec\nstate\nclose tab-mail\nstate\n")
    #expect(run.status == 0, "\(run.error)")
    let lines = run.output.split(separator: "\n").map(String.init)
    #expect(lines.contains("ok close tab-spec"))
    #expect(lines.contains("ok close tab-mail"))
    #expect(lines.filter { $0.hasPrefix("state ") } == [
        "state space 0 selected tab-mail", "state space 0 selected tab-spec",
        "state space 0 selected tab-spec", "state space 0 selected tab-spec",
    ])
}

@Test
func harnessCloseUsesTheShownSpaceWithoutPagingBackThroughHistory() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json")
    let json = try String(contentsOf: source, encoding: .utf8)
        .replacingOccurrences(of: "\"parentID\": \"split-1\"", with: "\"parentID\": \"today-home\"")
        .replacingOccurrences(of: "\"parentID\": \"folder-docs\"", with: "\"parentID\": \"today-home\"")
    let fixture = directory.appendingPathComponent("sidebar.json")
    try json.write(to: fixture, atomically: true, encoding: .utf8)
    let run = try runHarness(in: directory, arguments: [fixture.path], commands:
        "select tab-mail\nspace 1\nselect tab-a\nselect tab-b\nclose tab-b\nstate\nclose tab-a\nstate\nclose tab-spec\nstate\n")
    #expect(run.status == 0, "\(run.error)")
    #expect(run.error.isEmpty)
    #expect(run.output.split(separator: "\n").filter { $0.hasPrefix("state ") }.map(String.init) == [
        "state space 1 selected tab-a", "state space 1 selected tab-spec", "state space 1 selected -", "state space 1 selected -",
    ])
}
