import Foundation
import Testing
@testable import AraratUI

@Test
func arcImportReadsOnlyTheFourKnownFilesAndAllowsMissingSiblings() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = OnboardingFixtures.showcase
    try fixture.sidebar.write(to: directory.appendingPathComponent("StorableSidebar.json"), atomically: true, encoding: .utf8)

    let sidebarOnly = try ArcImportFiles(directory: directory)
    #expect(sidebarOnly.sidebar == fixture.sidebar)
    #expect(sidebarOnly.windows == nil && sidebarOnly.keyBindings == nil && sidebarOnly.routing == nil)
    #expect(sidebarOnly.warning == nil)

    for (name, value) in [("StorableWindows.json", fixture.windows),
                          ("StorableKeyBindings.json", fixture.keyBindings),
                          ("StorableLinkRouting.json", fixture.routing)] {
        try value.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let complete = try ArcImportFiles(directory: directory)
    #expect(complete.sidebar == fixture.sidebar)
    #expect(complete.windows == fixture.windows && complete.keyBindings == fixture.keyBindings && complete.routing == fixture.routing)
    #expect(complete.warning == nil)

    try Data([0xff]).write(to: directory.appendingPathComponent("StorableWindows.json"))
    let unreadableSibling = try ArcImportFiles(directory: directory)
    #expect(unreadableSibling.windows == nil)
    #expect(unreadableSibling.warning == "StorableWindows.json: The file is not UTF-8.")
}

@Test
func arcImportReportsMissingAndUnreadableSidebar() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        _ = try ArcImportFiles(directory: directory)
        Issue.record("Missing sidebar was accepted")
    } catch let error as ArcImportFiles.ReadError {
        #expect(error.message == "StorableSidebar.json was not found.")
    }

    let sidebar = directory.appendingPathComponent("StorableSidebar.json")
    try FileManager.default.createDirectory(at: sidebar, withIntermediateDirectories: false)
    #expect(throws: ArcImportFiles.ReadError.self) { _ = try ArcImportFiles(directory: directory) }
    try FileManager.default.removeItem(at: sidebar)
    try Data([0xff]).write(to: sidebar)
    do {
        _ = try ArcImportFiles(directory: directory)
        Issue.record("Non-UTF-8 sidebar was accepted")
    } catch let error as ArcImportFiles.ReadError {
        #expect(error.message == "StorableSidebar.json: The file is not UTF-8.")
    }
}
