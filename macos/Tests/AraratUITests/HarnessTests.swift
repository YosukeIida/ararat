import Darwin
import Foundation
import Testing

private struct HarnessRun {
    let status: Int32
    let output: String
    let error: String
    let databasesBeforeQuit: [String]
    let runningBeforeStop: Bool
    var diagnostics: [Substring] { harnessDiagnostics(error) }
}

private func harnessDiagnostics(_ error: String) -> [Substring] {
    error.split(separator: "\n").filter {
        !($0.hasPrefix("hitch ") && $0.hasSuffix(" ms") && UInt64($0.dropFirst(6).dropLast(3)) != nil)
    }
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
    #expect(replies.contains("state space 0 selected pinned library closed spaces 1"))
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
    #expect(!temporary.diagnostics.isEmpty)
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
        "state space 0 selected tab-mail library closed spaces 2", "state space 0 selected tab-spec library closed spaces 2",
        "state space 0 selected tab-spec library closed spaces 2", "state space 0 selected tab-spec library closed spaces 2",
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
    #expect(run.diagnostics.isEmpty)
    #expect(run.output.split(separator: "\n").filter { $0.hasPrefix("state ") }.map(String.init) == [
        "state space 1 selected tab-a library closed spaces 2", "state space 1 selected tab-spec library closed spaces 2", "state space 1 selected - library closed spaces 2", "state space 1 selected - library closed spaces 2",
    ])
}

@Test
func harnessReopensOnTheStoredSpaceWithItsCloseSuccessor() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json")
    let json = try String(contentsOf: source, encoding: .utf8)
        .replacingOccurrences(of: "\"parentID\": \"split-1\"", with: "\"parentID\": \"today-home\"")
    let fixture = directory.appendingPathComponent("sidebar.json")
    try json.write(to: fixture, atomically: true, encoding: .utf8)
    let arguments = [fixture.path, "--db", directory.appendingPathComponent("workspace.sqlite").path]
    let first = try runHarness(in: directory, arguments: arguments, commands: "space 1\nselect tab-a\nselect tab-b\nclose tab-b\n")
    #expect(first.status == 0)
    let reopened = try runHarness(in: directory, arguments: arguments)
    #expect(reopened.status == 0, "\(reopened.error)")
    #expect(reopened.output.contains("state space 1 selected tab-a library closed spaces 2"))
}

@Test
func harnessLibraryRestoreClosesTheLibraryAndPersistsTheRestoredTab() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json")
    let json = try String(contentsOf: source, encoding: .utf8)
        .replacingOccurrences(of: "\"parentID\": \"split-1\"", with: "\"parentID\": \"today-home\"")
    let fixture = directory.appendingPathComponent("sidebar.json")
    try json.write(to: fixture, atomically: true, encoding: .utf8)
    let args = [fixture.path, "--db", directory.appendingPathComponent("workspace.sqlite").path]
    let run = try runHarness(in: directory, arguments: args, commands:
        "space 1\nselect tab-a\nclose tab-a\nspace 0\nlibrary\nstate\nlibrary close\nlibrary\nrestore tab-a\nstate\n")
    #expect(run.status == 0, "\(run.error)")
    #expect(run.output.contains("library open"))
    #expect(run.output.contains("ok restore tab-a"))
    #expect(run.output.contains("state space 1 selected tab-a library closed spaces 2"))
    let reopened = try runHarness(in: directory, arguments: args)
    #expect(reopened.status == 0)
    #expect(reopened.output.contains("state space 1 selected tab-a library closed spaces 2"))
}

@Test
func harnessCreatesAndReopensANamedSpaceAfterTheExistingSpaces() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let arguments = ["--db", directory.appendingPathComponent("workspace.sqlite").path]
    let created = try runHarness(in: directory, arguments: arguments, commands: "create-space   Project Notes   \nstate\n")
    #expect(created.status == 0, "\(created.error)")
    #expect(created.output.contains("ok create-space Project Notes"))
    #expect(created.output.contains("state space 2 selected - library closed spaces 3"))
    let reopened = try runHarness(in: directory, arguments: arguments)
    #expect(reopened.status == 0, "\(reopened.error)")
    #expect(reopened.output.contains("state space 2 selected - library closed spaces 3"))
}

@Test
func harnessPermanentlyDeletesOnlyAnArchivedTab() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json")
    let json = try String(contentsOf: source, encoding: .utf8)
        .replacingOccurrences(of: "\"parentID\": \"split-1\"", with: "\"parentID\": \"today-work\"")
    let fixture = directory.appendingPathComponent("sidebar.json")
    try json.write(to: fixture, atomically: true, encoding: .utf8)
    let arguments = [fixture.path, "--db", directory.appendingPathComponent("workspace.sqlite").path]
    let deleted = try runHarness(in: directory, arguments: arguments, commands:
        "close tab-a\narchive-search A.EXAMPLE\narchive-search no-match\narchive-delete tab-a\narchive-search A.EXAMPLE\nrestore tab-a\narchive-delete missing\narchive-delete tab-mail\n")
    #expect(deleted.status == 0, "\(deleted.error)")
    #expect(deleted.output.contains("ok archive-delete tab-a"))
    #expect(deleted.output.contains("ok archive-search count 1"))
    #expect(deleted.output.contains("ok archive-search count 0"))
    #expect(deleted.output.contains("error restore tab-a"))
    #expect(deleted.output.contains("error archive-delete missing"))
    #expect(deleted.output.contains("error archive-delete tab-mail"))
    let reopened = try runHarness(in: directory, arguments: arguments, commands: "restore tab-a\n")
    #expect(reopened.output.contains("error restore tab-a"))
}

@Test
func harnessRejectsMalformedCommandsAndKeepsProcessing() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let malformed = [
        "", " ", "\t\t", "unknown", "unknown extra", "input", "input menu", "input key",
        "quit extra", "state extra", "width 1", "reset-width 1", "sidebar extra", "toggle-sidebar extra",
        "select", "select \t", "select tab-mail extra", "close", "close tab-mail extra",
        "restore", "restore tab-a extra", "archive-delete", "archive-delete tab-a extra",
        "space", "space +1", "space x", "space 1.5", "space 0 extra", "space 99999999999999999999999999999999",
        "library invalid", "library close extra", "create-space", "create-space \t  ",
    ]
    let run = try runHarness(in: directory, commands: malformed.joined(separator: "\n") + "\n")
    #expect(run.status == 0, "\(run.error)")
    #expect(run.runningBeforeStop)
    let replies = run.output.split(separator: "\n").map(String.init)
    #expect(replies.count == malformed.count + 2)
    let known = Set(["quit", "state", "width", "reset-width", "sidebar", "toggle-sidebar", "select", "close", "restore", "archive-delete", "space", "library", "create-space"])
    for (command, reply) in zip(malformed, replies) {
        #expect(reply.hasPrefix("error "), "\(command.debugDescription) answered \(reply)")
        if let verb = command.split(whereSeparator: \.isWhitespace).first, known.contains(String(verb)) {
            #expect(reply.hasPrefix("error \(verb): usage "), "\(command.debugDescription) answered \(reply)")
        }
    }
    #expect(replies.dropFirst(malformed.count).first?.hasPrefix("state space ") == true)
    #expect(replies.last == "ok quit")
}

@Test
func harnessValidatedCommandsKeepTheirRepliesAndFreeTextArguments() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let run = try runHarness(in: directory, commands:
        "\twidth \t\nreset-width\nsidebar\ntoggle-sidebar\nlibrary\nlibrary close\narchive-search \t\narchive-search Mixed query words\nspace 0000\nselect tab-mail\nclose tab-spec\nrestore tab-spec\narchive-delete missing\ncreate-space   Project  Notes   \n")
    #expect(run.status == 0, "\(run.error)")
    #expect(run.runningBeforeStop)
    let lines = run.output.split(separator: "\n").map(String.init)
    #expect(Array(lines.prefix(11)) == ["ok 240", "ok 240", "ok docked", "ok floating", "ok library", "ok library close",
        "ok archive-search count 0", "ok archive-search count 0", "ok space 0", "ok select tab-mail", "ok close tab-spec"])
    #expect(lines.contains { $0.hasPrefix("error restore tab-spec:") })
    #expect(lines.contains { $0.hasPrefix("error archive-delete missing:") })
    #expect(lines.contains("ok create-space Project  Notes"))
    #expect(lines.last == "ok quit")
}

@Test
func harnessDiagnosticsIgnoreOnlyHitchMeasurements() {
    #expect(harnessDiagnostics("hitch 160 ms\nhitch 101 ms\n").isEmpty)
    #expect(harnessDiagnostics("hitch 160 ms\nstore failed\n") == ["store failed"])
    #expect(harnessDiagnostics("hitch unexpected ms\nhitch 160 ms extra") == ["hitch unexpected ms", "hitch 160 ms extra"])
}
