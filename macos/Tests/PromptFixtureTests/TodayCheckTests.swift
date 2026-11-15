import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI
import ObjectiveC.runtime
import Testing
@testable import Ararat

@MainActor private final class TodayCheckHost: NSObject {
    var entries: [Any] = []
    @objc func tabs() -> [Any] { entries }
}

@MainActor private final class TodayCheckTab: NSObject {
    @objc var itemId: String?
    init(_ item: String) { itemId = item }
}

@Test @MainActor
func todayCheckWaitsForTheRestoredSidebarBeforePressingClearAgain() throws {
    _ = NSApplication.shared
    class_addProtocol(TodayCheckHost.self, objc_getProtocol("ARWindowHostAPI")!)
    class_addProtocol(TodayCheckTab.self, objc_getProtocol("ARTabAPI")!)
    let fake = TodayCheckHost()
    let host = fake as! any ARWindowHostAPI
    let runtime = Runtime(windowID: "today-check")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    let adapter = try EngineAdapter(path: directory.appendingPathComponent("today.sqlite").path,
                                    windowID: runtime.windowID, card: NSView(), session: session)
    runtime.adapter = adapter
    let store = try #require(session.store)
    _ = try store.createSpace(windowId: runtime.windowID, name: "Work", spaceId: "work")
    let kept = try #require(store.createTab(windowId: runtime.windowID, url: "https://stay.example/").selectedId)
    let other = try #require(store.createTab(windowId: runtime.windowID, url: "https://leave.example/").selectedId)
    let live = try store.liveOpen(item: kept, url: "https://stay.example/")
    _ = try store.liveApply(transaction: LiveTransaction(offTheRecord: false, epoch: 1, rev: 0, cause: .engine,
        strips: [LiveStrip(window: runtime.windowID, tabs: [LiveTab(offTheRecord: false, profile: .default,
            liveId: live.id, item: kept, opener: nil, navigated: false, url: nil, title: nil)], active: live.id)]))
    let clear = try store.liveClearToday(windowId: runtime.windowID, spaceId: "work")
    let command = try #require(clear.targets.first { $0.command.item == kept }?.command)
    runtime.snapshot = clear.snapshot
    let sidebar = SidebarView(snapshot: clear.snapshot)
    runtime.sidebar = sidebar
    fake.entries = [TodayCheckTab(kept)]
    let check = SidebarCheck()
    check.mode = .today
    check.phase = 43
    check.commandWId = kept
    check.seen = [kept, other]
    var presses = 0
    var answers = 0
    var waits: [String] = []
    var steps: [Int] = []
    sidebar.onClearToday = { presses += 1 }
    func tick() {
        runtime.todayTickPhase(host, screen: true, check: check, note: { waits.append($0) }, trace: { _ in },
            step: { steps.append($0) }, finish: { Issue.record("Finished before second Clear") },
            capture: { _ in false }, click: { _, _ in false }, row: { _ in nil }, answerDialog: { stay in
                #expect(stay)
                answers += 1
                let cancelled = session.queue.sync { try? store.liveCancelClose(commandId: command.id) }
                #expect(cancelled == true)
                return true
            })
    }
    tick()
    tick()
    #expect(answers == 1)
    #expect(presses == 0)
    #expect(steps.isEmpty)
    #expect(waits == ["wait=clear-stay-sidebar-restore"])
    let restored = session.queue.sync { store.snapshot(windowId: runtime.windowID) }
    runtime.snapshot = restored
    sidebar.update(snapshot: restored)
    tick()
    #expect(presses == 1)
    #expect(steps == [5])
    #expect(check.conditions["divider_back_after_stay"] == true)
    #expect(check.conditions["clear_today_stay_keeps_only_refused_row"] == true)
}

@Test @MainActor
func todayCheckAnswersLeaveBeforeWaitingForTheCoreSnapshot() throws {
    _ = NSApplication.shared
    class_addProtocol(TodayCheckHost.self, objc_getProtocol("ARWindowHostAPI")!)
    let host = TodayCheckHost() as! any ARWindowHostAPI
    let runtime = Runtime(windowID: "today-check")
    runtime.sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []))
    let check = SidebarCheck()
    check.phase = 5
    var answers: [Bool] = []
    var traces: [String] = []
    var waits: [String] = []
    for screen in [false, true] {
        runtime.todayTickPhase(host, screen: screen, check: check, note: { waits.append($0) },
            trace: { traces.append($0) }, step: { _ in Issue.record("Advanced before close settled") },
            finish: { Issue.record("Finished before close settled") }, capture: { _ in false },
            click: { _, _ in false }, row: { _ in nil }, answerDialog: { answers.append($0); return true })
    }
    #expect(answers == [false])
    #expect(traces == ["dialog=clear-after-stay answer=leave"])
    #expect(waits == ["wait=clear-core-snapshot"])
    #expect(check.conditions.isEmpty)
}
